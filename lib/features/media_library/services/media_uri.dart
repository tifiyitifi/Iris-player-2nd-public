import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/storages/webdav.dart'
    show isIPv4WildcardHost, webdavUriForEndpoint;
import 'package:iris/utils/path_conv.dart';

/// Whether [storage]'s host pattern still has to be resolved before it can be
/// dialled.
///
/// A wildcard entry with an empty cache would otherwise produce a URL carrying
/// `192.168.*.*`, which no player can open — callers resolve once (recording the
/// host) and rebuild the address.
bool webdavNeedsResolution(WebDAVStorage storage) =>
    isIPv4WildcardHost(storage.host) && storage.resolvedHosts.isEmpty;

/// Playable/probe URL for a WebDAV node, built from the entry's CURRENT
/// endpoint.
///
/// The host is `resolvedHost ?? host`, so a wildcard entry follows its most
/// recent resolution: neither a DHCP change nor a different resolved candidate
/// leaves a stale address baked into the database. Scheme, port and the
/// storage-relative path come from the entry, and credentials are NOT embedded
/// — the player hooks attach `storage.getAuth()` as a request header.
String webdavPlayableUri(
  WebDAVStorage storage,
  List<String> canonicalSegments,
) {
  final canonical = canonicalDbPath(canonicalSegments.join('/'));
  final segments = canonical.isEmpty ? const <String>[] : pathConv(canonical);
  return webdavUriForEndpoint(
    https: storage.https,
    host: storage.resolvedHost ?? storage.host,
    port: storage.port,
    segments: segments,
  );
}

/// The address handed to the player for an external [subtitle].
///
/// One place owns the per-storage shaping, so the track panel (media_kit and
/// fvp) and the auto-select path can never drift apart:
///
///  * **WebDAV** — the authority is rebuilt from the CURRENT storage record and
///    the path is re-encoded with the canonical builder, PRESERVING any query /
///    fragment the listing carried (a signed `?token=…` URL lost it on rebuild
///    and 404'd). A host baked into the entry when the folder was LISTED (a DHCP
///    move or a different resolved candidate since) therefore cannot outlive the
///    listing, and the subtitle address always matches the video's — which is
///    itself rebuilt from the storage record at open time
///    ([webdavPlayableUri]).
///  * **FTP** — the same rule: the stored proxy address baked the host/port in
///    at list time, so the CURRENT storage record is used to rebuild it (a
///    changed endpoint used to leave the subtitle dialling the old host while
///    the video followed the storage). The result is the relative proxy form;
///    the player prepends [mediaStreamUrl] (credentials ride the request
///    header, never the URL).
///  * **local** — the stored [Subtitle.uri] verbatim. It is an absolute path
///    captured at scan time, and the media's storage-relative directory is not
///    part of this interface ([FileItem.path] is surface-dependent: relative for
///    a live listing, absolute for a DB-resolved row), so there is nothing to
///    rebuild it from here.
String subtitlePlayableUri(
  Storage? storage,
  Subtitle subtitle, {
  required String mediaStreamUrl,
}) {
  switch (storage) {
    case FTPStorage():
      final storedPath = _ftpStoredPath(subtitle.uri);
      if (storedPath == null || storedPath.isEmpty) {
        return '$mediaStreamUrl/${subtitle.uri}';
      }
      return '$mediaStreamUrl/${ftpPlayableUri(storage, pathConv(storedPath))}';
    case WebDAVStorage():
      final parts = _webdavAddressParts(subtitle.uri);
      if (parts == null || parts.segments.isEmpty) return subtitle.uri;
      return webdavUriForEndpoint(
        https: storage.https,
        host: storage.resolvedHost ?? storage.host,
        port: storage.port,
        segments: parts.segments,
        // A query (signed URL) or fragment is part of the ADDRESS: rebuilding
        // without it changed the request and 404'd.
        query: parts.query,
        fragment: parts.fragment,
      );
    default:
      return subtitle.uri;
  }
}

/// The pieces of a stored WebDAV subtitle address the rebuild needs, or null
/// when the address cannot be read.
///
/// The path/query/fragment accessors are LAZY: a malformed percent-escape
/// (`%FF`, a truncated `%`) makes them throw [FormatException] instead of
/// returning. The track panel builds straight from this, so the failure has to
/// come back as "nothing to rebuild" (the caller keeps the stored address)
/// rather than as an exception that tears the build down.
({List<String> segments, String? query, String? fragment})? _webdavAddressParts(
  String uri,
) {
  try {
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return null;
    return (
      segments: parsed.pathSegments,
      query: parsed.query.isEmpty ? null : parsed.query,
      fragment: parsed.hasFragment ? parsed.fragment : null,
    );
  } on FormatException {
    return null;
  }
}

/// The FTP `path=` a stored proxy address carries (`ftp?host=…&path=/a/b.srt`),
/// or null when it cannot be parsed. Used to rebuild the address against the
/// CURRENT storage record.
String? _ftpStoredPath(String uri) {
  try {
    final parsed = Uri.tryParse(uri);
    if (parsed == null || !parsed.hasQuery) return null;
    final path = parsed.queryParameters['path'];
    // A legacy stored address may carry an unencoded `&` inside the `path=`
    // value (e.g. `/a&b.srt`), which `queryParameters` truncates at the `&`.
    // The path is the last parameter in an FTP stored address, so prefer the
    // raw tail after the first `path=` (decoded) when it contains an `&`.
    var candidate = path;
    var decode = false;
    final idx = parsed.query.indexOf('path=');
    if (idx >= 0) {
      final rawTail = parsed.query.substring(idx + 'path='.length);
      if (rawTail.contains('&') && rawTail.length > (path?.length ?? 0)) {
        candidate = rawTail;
        decode = true;
      }
    }
    if (candidate == null || candidate.isEmpty) return null;
    return decode ? Uri.decodeComponent(candidate) : candidate;
  } on FormatException {
    // Same lazy-accessor trap as [_webdavAddressParts]: an unparseable `path=`
    // leaves the stored address as the only thing we have.
    return null;
  }
}

/// Relative playable address for an FTP node.
///
/// FTP playback goes through the local `MediaStream` proxy: producers put this
/// RELATIVE form into `FileItem.uri` and the player entry points prepend
/// `MediaStream().url` (see `use_media_kit_player`, `use_fvp_player` and
/// `background_playback_engine`). Credentials travel as the `getAuth()` request
/// header, never in the URL. The shape matches `getFTPFiles`' listing URIs
/// (leading `/` inside `path`), so live and DB-resolved items agree. The `path`
/// value is percent-encoded via [encodeFtpProxyPath], so a name containing
/// `&` / `#` / `=` can no longer truncate the query the proxy parses.
String ftpPlayableUri(FTPStorage storage, List<String> canonicalSegments) {
  final canonical = canonicalDbPath(canonicalSegments.join('/'));
  return 'ftp?host=${storage.host}&port=${storage.port}'
      '&path=${encodeFtpProxyPath('/$canonical')}';
}

/// Playable/probe address for a `media_nodes` row.
///
/// The DB stores the storage-relative PATH as the identity; a remote address is
/// DERIVED here so the list keeps the DB as its single source while staying
/// valid when the host moves. Precedence:
///
///  1. a persisted [uri] (SAF `content://` documents — the path alone cannot
///     rebuild them);
///  2. a remote entry — WebDAV via [webdavPlayableUri] (absolute), FTP via
///     [ftpPlayableUri] (relative, proxy-prefixed by the player);
///  3. otherwise the local path form ([playableUri]).
String mediaNodePlayableUri(
  Storage? storage,
  List<String> segments, {
  String? uri,
}) {
  if (uri != null && uri.isNotEmpty) return uri;
  if (storage is WebDAVStorage) return webdavPlayableUri(storage, segments);
  if (storage is FTPStorage) return ftpPlayableUri(storage, segments);
  return playableUri(segments);
}
