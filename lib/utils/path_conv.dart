import 'package:iris/utils/logger.dart';
import 'package:path/path.dart' as p;
final areaKeyLog = AreaKeyLog(LogKeys.legacyUtil);

/// Android SAF tree-URI prefix: `content://<authority>/tree/<encodedTreeId>`.
///
/// The tree id is `/`-encoded (`primary%3ADownload`), so it never contains a
/// literal `/`; the authority is `[^/]+`. This makes the prefix boundary
/// unambiguous and lets a storage-relative path be expressed as
/// `<treePrefix>/<rel1>/<rel2>` with the scheme intact.
final RegExp _kSafTreePrefix = RegExp(r'^content://[^/]+/tree/[^/]+');

/// True when [raw] is an Android SAF content URI / content-prefixed path.
bool isSafPath(String raw) => raw.startsWith('content://');

/// Percent-decodes one SAF path segment, falling back to the raw text when it
/// is not valid percent-encoding.
///
/// The `%` guard is not an optimisation: a literal `%` in a real name (or a
/// half-typed segment) makes `Uri.decodeComponent` throw, and a decode failure
/// here must never take the whole path down.
String _decodeSafSegment(String s) {
  if (!s.contains('%')) return s;
  try {
    return Uri.decodeComponent(s);
  } on FormatException {
    return s;
  } on ArgumentError {
    return s;
  }
}

/// The readable identity of a SAF tree id: its percent-decoded form, with no
/// volume-prefix stripping (`primary:Download`, `ABCD-1234:Download/Sub`).
String _decodedTreeId(String treePrefix) {
  final head = treePrefix.substring(0, treePrefix.lastIndexOf('/'));
  return _decodeSafSegment(treePrefix.substring(head.length + 1));
}

/// The literal relative segments that ride AFTER the matched tree prefix, with
/// empty / `.` / `..` segments dropped.
///
/// A scanner/browser-built SAF path is `<treePrefix>/<rel1>/<rel2>` (the tree
/// id is percent-encoded, the relative names are LITERAL — the same form
/// `safSegmentsOf`/`canonicalDbPath` store and `safJoin` round-trips). The
/// prefix regex stops at the encoded id, so these segments are NOT part of the
/// match and must be read separately — dropping them collapsed every descendant
/// of a storage root to the root itself.
///
/// They are deliberately NOT percent-decoded: a real file named `a%20b.mp4`
/// would become `a b.mp4`, and `a%2Fb` would grow a path level. Only the tree
/// id itself is encoded and decoded (see [_decodedTreeId]).
List<String> _safTailSegments(String raw, String treePrefix) => <String>[
      for (final part in raw.substring(treePrefix.length).split('/'))
        if (part.isNotEmpty && part != '.' && part != '..') part,
    ];

/// Whether the first segment already embeds the full `content://` tree
/// prefix (segment 0 == tree URI), i.e. a SAF-path segment list.
bool isSafPathSegments(List<String> segments) =>
    segments.isNotEmpty && isSafPath(segments.first);

/// Splits a SAF path string into [treePrefix, ...relativeNames].
///
/// Input may be the bare tree URI (`content://a/tree/x`) or a deeper
/// storage-relative path (`content://a/tree/x/Movies/a.mp4`). The first
/// segment is ALWAYS the full tree prefix; the remainder are literal
/// (un-encoded) relative names split on '/'. Rejects `.`/`..`.
///
/// A `content://` document URI WITHOUT a `/tree/` segment (an
/// `ACTION_OPEN_DOCUMENT` single pick, e.g. `.../document/video%3A101`) is NOT
/// split: it is returned verbatim as a single segment so its scheme stays
/// reversible (splitting collapsed `content://` into `content:/`).
///
/// For non-SAF input falls back to the legacy `pathConv`-style split.
List<String> safSegmentsOf(String raw) {
  if (!isSafPath(raw)) return pathConv(raw);
  final prefix = _kSafTreePrefix.stringMatch(raw) ?? '';
  if (prefix.isEmpty) {
    // A `content://` URI without a `/tree/` segment is a SAF document URI
    // (ACTION_OPEN_DOCUMENT single pick) — NOT a malformed tree URI. Splitting
    // it on `/` collapses `content://` into `content:/` (see v23 repair) and
    // breaks every downstream identity (media_nodes path, progress key, the
    // queue highlight). Preserve it verbatim as a single segment so it stays
    // reversible, exactly like a tree prefix.
    if (isSafPath(raw)) {
      return <String>[raw];
    }
    // Genuinely malformed `content://...` (missing /tree/) — keep the legacy
    // lossy split so nothing downstream crashes on a stray string.
    areaKeyLog.w('safSegmentsOf: no /tree/ prefix in $raw');
    return raw.split('/').where((e) => e.isNotEmpty).toList();
  }
  final rest = raw.substring(prefix.length);
  final segs = <String>[prefix];
  for (final part in rest.split('/')) {
    if (part.isEmpty || part == '.' || part == '..') continue;
    segs.add(part);
  }
  return segs;
}

/// Joins a SAF segment list (segment 0 == full tree prefix) back into the
/// canonical `content://.../rel1/rel2` string WITHOUT collapsing the `//`.
String safJoin(List<String> segments) {
  final s = segments.where((e) => e.isNotEmpty).toList();
  if (s.isEmpty) return '';
  return s.join('/');
}

/// The LEGACY scheme-collapsed form of a SAF path (`content://a/b` →
/// `content:/a/b`), or null when [path] is not a `content://` path.
///
/// The old canonicalization split the scheme on `/` and rejoined it, so rows
/// written before the scheme was preserved (and repaired once by
/// `MigrationV23`) still live under this key. Lookups accept both forms so a
/// migrated single pick is never orphaned.
String? collapsedSafSchemePath(String path) {
  const prefix = 'content://';
  if (!path.startsWith(prefix)) return null;
  return 'content:/${path.substring(prefix.length)}';
}

/// Resolves a picked SAF tree URI ([raw]) to a HUMAN-READABLE
/// storage-relative directory path under the storage rooted at [treeBase].
///
/// Android's `ACTION_OPEN_DOCUMENT_TREE` returns a tree URI whose encoded
/// tree id carries the FULL provider path of the picked directory
/// (`.../tree/primary%3ADownload%2FMovies` for `Download/Movies` under a
/// `primary:Download` root). This function compares the DECODED tree ids:
///
/// - equal → `''` (the picked directory IS the storage root);
/// - `raw` under `[treeBase]` → the remaining decoded relative path
///   (`Movies` / `Movies/sub` — readable, no `content://`, no `%2F`);
/// - different tree roots / non-SAF inputs → `null` (not under this storage).
///
/// [raw] may be the bare tree URI OR a deeper path whose tail rides literally
/// after the prefix (`<treePrefix>/Movies/sub`, the scanner/browser shape):
/// the tail is part of [raw]'s identity, so a descendant is never mistaken for
/// [treeBase] itself (which returned `''` and silently targeted the root).
String? safTreeRelativeTo(String raw, String treeBase) {
  if (!isSafPath(raw) || !isSafPath(treeBase)) return null;
  final rawPrefix = _kSafTreePrefix.stringMatch(raw) ?? '';
  final basePrefix = _kSafTreePrefix.stringMatch(treeBase) ?? '';
  if (rawPrefix.isEmpty || basePrefix.isEmpty) return null;

  // Same `content://<authority>/tree/` head, then compare decoded tree ids.
  // The authority is case-INSENSITIVE (RFC 3986): `COM.Android...` and
  // `com.android...` are the same provider.
  final rawHead = rawPrefix.substring(0, rawPrefix.lastIndexOf('/'));
  final baseHead = basePrefix.substring(0, basePrefix.lastIndexOf('/'));
  if (rawHead.toLowerCase() != baseHead.toLowerCase()) return null;

  // Compare the FULL readable identity (decoded tree id + literal tail), with
  // the volume prefix kept so `primary:` vs `ABCD-1234:` stays distinct.
  final rawDecoded = <String>[
    _decodedTreeId(rawPrefix),
    ..._safTailSegments(raw, rawPrefix),
  ].join('/');
  final baseDecoded = _decodedTreeId(basePrefix);
  if (rawDecoded == baseDecoded) return '';
  if (!rawDecoded.startsWith('$baseDecoded/')) return null;
  return rawDecoded.substring(baseDecoded.length + 1);
}

/// Decodes any SAF tree URI into its readable directory tail, dropping the
/// `content://<authority>/tree/` head and the provider volume prefix
/// (`primary:` / `0000-0000:`), e.g.:
///
/// `content://com.android.externalstorage.documents/tree/primary%3ADownload%2FMovies`
/// → `Download/Movies`.
///
/// A literal tail after the tree prefix is kept too:
/// `.../tree/primary%3ADownload/Movies/a.mp4` → `Download/Movies/a.mp4`.
///
/// Used as a LAST-RESORT fallback when a pick is not under any registered
/// storage — rules store storage-relative directory paths, never a raw
/// `content://...` string. Returns null for non-tree / malformed input.
String? safReadableRelative(String raw) {
  if (!isSafPath(raw)) return null;
  final prefix = _kSafTreePrefix.stringMatch(raw) ?? '';
  if (prefix.isEmpty) return null;
  final decoded = _decodedTreeId(prefix);
  // Strip the volume prefix (`primary:`, `ABCD-1234:`, ...). No colon → the
  // whole decoded id is the path.
  final sep = decoded.indexOf(':');
  final path = sep < 0 ? decoded : decoded.substring(sep + 1);
  final segs = <String>[
    ...path.split('/').where((e) => e.isNotEmpty && e != '.' && e != '..'),
    ..._safTailSegments(raw, prefix),
  ];
  return segs.join('/');
}

/// Whether [s] sits under [normBase] as a whole PATH SEGMENT, not merely as a
/// raw string prefix.
///
/// A bare `startsWith` would treat `E:/media2/x` as being under `E:/media`
/// (stripping to the wrong `2/x`). The match only holds when the base ends
/// exactly at a `/` boundary (or the strings are equal); a base that already
/// ends with `/` embeds its own boundary.
bool _underBase(String s, String normBase) {
  if (!s.toLowerCase().startsWith(normBase.toLowerCase())) return false;
  if (s.length == normBase.length) return true;
  if (normBase.endsWith('/')) return true;
  return s[normBase.length] == '/';
}

/// Normalises [raw] (an absolute path or a browser-joined storage path) to the
/// STORAGE-RELATIVE directory form rules store, by stripping the LONGEST
/// registered storage base path it sits under.
///
/// Mirrors the editors' pick-time relativisation: SAF tree URIs decode to their
/// readable relative tail ([safTreeRelativeTo]), non-SAF bases are stripped
/// case-insensitively, and input under no base falls through (SAF input still
/// decodes via [safReadableRelative]). `''` means the storage root.
///
/// LONGEST match (not first): overlapping bases are legal (`E:/media` and
/// `E:/media/sub`), and taking the first would leave an `E:/media/sub` path
/// relative to the shorter base (`sub/x` instead of `x`).
///
/// [storageBasePaths] are the joined `Storage.basePath` strings; taking plain
/// strings keeps this util free of the model layer.
String relativeToStoragePath(String raw, Iterable<String> storageBasePaths) {
  var s = raw.trim().replaceAll('\\', '/');
  if (s.isEmpty) return '';
  // SAF tree bases yield a decoded relative tail; a base that matches exactly
  // returns '' (the storage root). Keep the MOST SPECIFIC match: a longer
  // decoded tail means a shorter (more specific) relative path.
  String? safRel;
  int bestBaseLen = -1;
  String? bestBase;
  for (final base in storageBasePaths) {
    if (base.isEmpty) continue;
    // Android SAF storage: resolve the encoded tree id to a readable relative
    // directory (`Movies`, not the whole `content://...` URI).
    if (base.startsWith('content://')) {
      final rel = safTreeRelativeTo(s, base);
      if (rel != null && (safRel == null || rel.length < safRel.length)) {
        safRel = rel;
      }
      continue;
    }
    final normBase = base
        .replaceAll('\\', '/')
        .replaceAllMapped(RegExp(r'^file:///'), (m) => '');
    if (normBase.isNotEmpty &&
        _underBase(s, normBase) &&
        normBase.length > bestBaseLen) {
      bestBaseLen = normBase.length;
      bestBase = normBase;
    }
  }
  if (bestBase != null) {
    s = s.substring(bestBase.length);
  } else if (safRel != null) {
    return safRel;
  }
  while (s.startsWith('/')) {
    s = s.substring(1);
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  s = s.trim();
  if (isSafPath(s)) return safReadableRelative(s) ?? s;
  return s;
}

/// Reversible canonical form for SAF content-prefixed input (scheme intact,
/// empty/`..` segments dropped). Non-SAF input keeps the legacy behavior.
String _canonicalSafOrLegacy(String raw) {
  if (isSafPath(raw)) return safJoin(safSegmentsOf(raw));
  var s = raw.replaceAll(RegExp(r'^[/\\]+'), '').replaceAll(RegExp(r'/+'), '/');
  if (s.isEmpty) return s;
  final segs = s.split('/').where((e) => e.isNotEmpty).toList();
  if (segs.any((e) => e == '..' || e == '.')) return '';
  return segs.join('/');
}

List<String> pathConv(String path) {
  // SAF content-prefixed paths must NOT be split on the scheme — segment 0
  // stays the full tree prefix so the path stays reversible.
  if (isSafPath(path)) return safSegmentsOf(path);
  try {
    String normalizedPath = p.normalize(path.trim());

    if (normalizedPath.isEmpty || normalizedPath == '.') {
      return [];
    }

    if (normalizedPath == '/' || normalizedPath == '\\') {
      return ['/'];
    }

    final List<String> result = normalizedPath
        .replaceAll('\\', '/')
        .split('/')
        .where((element) => element.isNotEmpty)
        .toList();

    // Reject traversal segments — they would escape the storage basePath.
    if (result.any((s) => s == '..' || s == '.')) {
      areaKeyLog.w('pathConv rejected traversal: $path');
      return [];
    }

    if (path.startsWith('\\\\')) {
      if (result.isEmpty) return [];
      return ['\\\\${result[0]}', ...result.sublist(1)];
    }

    if (path.startsWith('/')) {
      return ['/', ...result];
    }

    return result;
  } on FormatException catch (e) {
    areaKeyLog.e('Error decoding: $e');
    return [];
  }
}

/// Renders [raw] as the canonical occurrence path used by playback keys.
///
/// Follows the earliest/legacy standard produced by the [pathConv] round-trip:
/// a rooted path like `/storage/emulated/0/x` becomes `//storage/emulated/0/x`
/// (the resolver's item rendering). Idempotent. SAF content-prefixed paths
/// keep their scheme intact (`content://...`), never gaining a leading `/`.
String canonicalOccurrencePath(String raw) => pathConv(raw).join('/');

/// Input-independent canonical form of [raw] for key comparisons: strips a
/// leading `/` or `//` (or `\`) and collapses repeated slashes, so `/a/b`,
/// `//a/b` and `a/b` all compare equal. Rejects `.`/`..` traversal.
/// SAF content-prefixed paths keep the `content://` scheme (no collapse).
String canonicalPath(String raw) => _canonicalSafOrLegacy(raw);

/// Canonical media key `storageId:canonicalPath` used at match time so
/// producers with different slash conventions still resolve the same file.
String canonicalKey(String storageId, String path) =>
    '$storageId:${canonicalPath(path)}';

/// Canonical occurrence key `storageId:canonicalPath#occurrenceIndex` — the
/// form the playback mirror and queue highlight compare against.
String canonicalOccurrenceKey(String storageId, String path, int occurrenceIndex) =>
    '${canonicalKey(storageId, path)}#$occurrenceIndex';

/// Canonical progress-store key `storageId:canonicalPath(segment path joined)`.
///
/// Unlike [FileItem.getID] (`'$storageId:$uri'`), which keys by the
/// surface-dependent native `uri` (Windows backslash paths, Android rooted
/// `/storage/...`), this routes the clean segment path through [canonicalKey]
/// so every surface (scenario queue / storage browser / player hooks) and
/// platform yields the same key for the same file. Used by
/// [PlaybackProgressStore] and HistoryStore.
///
/// When the segment [path] is empty (e.g. SAF single-picked files), falls back
/// to the canonicalized [uri] so distinct files never collide on `storageId:`.
String canonicalProgressKey(String storageId, List<String> path, {String? uri}) {
  if (path.isEmpty && uri != null && uri.isNotEmpty) {
    return canonicalKey(storageId, canonicalOccurrencePath(uri));
  }
  return canonicalKey(storageId, path.join('/'));
}

/// Canonical DB path column form (no leading/trailing slashes, no repeated
/// slashes, forward slashes). Applied at the DAO/adapters so stored and
/// queried paths are uniform regardless of the caller's slash convention.
String canonicalDbPath(String raw) => canonicalPath(raw);

/// [canonicalDbPath] for nullable paths (null stays null).
String? canonicalDbPathOrNull(String? raw) =>
    raw == null ? null : canonicalDbPath(raw);

/// Builds a player-openable local URI from canonical DB path segments.
///
/// Shape-driven, not platform-driven, so it behaves identically on every host
/// and in tests:
/// - SAF content-prefixed segments (segment 0 == `content://.../tree/...`)
///   are joined back verbatim — no leading '/' is prepended and the `//` in
///   the scheme is preserved;
/// - drive-letter (`E:/a/b`) and explicit UNC forms are returned untouched;
/// - an inner backslash can only be a UNC base mangled by [canonicalDbPath]
///   ('\\server\share' -> 'server\share'), because '\' is illegal inside NTFS
///   file names — rebuilt as forward-slash UNC ('//server/share/...'), which
///   Win32/mpv both accept;
/// - POSIX-family segments (Android 'storage/emulated/0/...', Linux mount
///   remnants) get exactly one leading '/'.
String playableUri(List<String> segments) {
  final s = segments.where((e) => e.isNotEmpty).toList();
  if (s.isEmpty) return '';
  // SAF segment list → content:// prefix intact.
  if (isSafPathSegments(s)) return safJoin(s);
  final joined = s.join('/');
  if (RegExp(r'^[A-Za-z]:[/\\]').hasMatch(joined)) return joined;
  if (joined.startsWith('//') || joined.startsWith(r'\\')) return joined;
  if (joined.contains(r'\')) {
    return '//${joined.replaceAll(r'\', '/')}';
  }
  if (joined.startsWith('/')) return joined;
  return '/$joined';
}

/// Real playable/probe URI for a media file: prefers the persisted SAF
/// document [uri] when present (Android `content://` rows), else falls back
/// to [playableUri] over the canonical path segments.
///
/// All MediaNode→FileItem producers and probe/open target builders should use
/// this so SAF rows never degrade into a `/content:/...` path string.
String nodePlayableUri(List<String> path, {String? uri}) {
  if (uri != null && uri.isNotEmpty) return uri;
  return playableUri(path);
}

/// Whether a persisted media URI is an Android SAF `content://` document URI.
bool isSafMediaUri(String uri) => uri.startsWith('content://');

/// Whether a storage path rides a case-insensitive filesystem: Windows
/// drive-letter (`E:/…`) and UNC (`//server/share/…` or `\\server\share\…`)
/// forms ride NTFS/SMB.
///
/// POSIX paths, Android SAF tree prefixes (`content://…`) and remote-server
/// paths are case-sensitive. Folding them would collapse two genuinely distinct
/// entries differing only by case — the "one dropped folder is never scanned"
/// and "stale node after a case-only rename" hazards.
bool pathRidesCaseInsensitiveFs(String path) {
  if (path.isEmpty) return false;
  if (path.startsWith('//') || path.startsWith(r'\\')) return true; // UNC share
  return RegExp(r'^[A-Za-z]:([/\\]|$)').hasMatch(path);
}

/// Whether two LOCAL paths name the same file, tolerating separator and — on a
/// case-insensitive filesystem — case differences.
///
/// A picker-returned path and a `Directory.list()` entry for the SAME file can
/// differ in `\` vs `/` (or a drive-letter case), so an identity comparison must
/// normalize first: comparing raw strings turned a real match into a
/// not-found. POSIX / SAF paths stay case-sensitive, where folding would merge
/// two genuinely distinct entries.
bool sameLocalPath(String a, String b) {
  final pa = p.normalize(a);
  final pb = p.normalize(b);
  return pathRidesCaseInsensitiveFs(pa)
      ? pa.toLowerCase() == pb.toLowerCase()
      : pa == pb;
}

/// Replaces the leading [oldSegments] of [segments] with [newSegments] when
/// they match; returns null when the prefix does not match.
///
/// Used when a volume is re-mounted under a new drive letter and every stored
/// segment path under the old root must move to the new one (favorites, history
/// keys) without touching paths outside the root.
List<String>? remapLeadingSegments(
  List<String> segments,
  List<String> oldSegments,
  List<String> newSegments,
) {
  if (oldSegments.isEmpty || segments.length < oldSegments.length) return null;
  for (var i = 0; i < oldSegments.length; i++) {
    if (segments[i] != oldSegments[i]) return null;
  }
  return [...newSegments, ...segments.sublist(oldSegments.length)];
}

/// Hook-level fallback for already-built URIs of local-family files only
/// ([DataSourceType.file]): repairs the single known-broken shape '/E:/...'
/// produced before the producer fix, and folds Windows backslashes into the
/// canonical forward-slash form (equivalent on Windows, and the form every
/// identity key uses). URI schemes (http/https/ftp/file/content) and UNC heads
/// pass through untouched, so remote addresses are never mangled.
String sanitizePlayableUri(String uri) => normalizePathText(uri);

/// Text-level normalization for LOCAL path identity.
///
/// Every path-keyed operation (delete, merge, progress key) must run the caller
/// string through this before comparing, because the same file has historically
/// arrived in several shapes:
/// - Windows backslashes (`E:\yb\a.mp4`);
/// - the legacy `/E:/…` drive form (a producer bug that reached the DB);
/// - duplicated / trailing slashes (`E://yb//a.mp4/`);
/// - UNC heads (`\\server\share\…`), whose literal `//` is identity.
///
/// SAF (`content://…`) input is returned UNTOUCHED: the scheme and the encoded
/// tree id are identity, not formatting. A POSIX root (`/storage/emulated/0`)
/// keeps its leading `/`; the legacy repair only fires for a real `X:` segment.
String normalizePathText(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || isSafPath(trimmed)) return trimmed;
  // Any other scheme (http/https/ftp/file/…) is a URI, not a path: collapsing
  // its '//' would silently rewrite a remote address. Two or more scheme chars
  // on purpose — `E://…` is the doubled legacy drive form, not a scheme.
  if (RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]+://').hasMatch(trimmed)) {
    return trimmed;
  }

  var s = trimmed.replaceAll(r'\', '/');
  // `//E:/…` is the doubled legacy drive form, not a UNC share (a share head
  // is `//server/share`); treating it as UNC left the extra slash in place.
  final isUnc = s.startsWith('//') && !RegExp(r'^//[A-Za-z]:').hasMatch(s);
  if (isUnc) {
    // Keep the literal UNC head: a filesystem `\\server\share` path is not a
    // rooted POSIX path, and collapsing the head loses the server segment.
    s = '//${s.substring(2).replaceAll(RegExp(r'/+'), '/')}';
  } else {
    s = s.replaceAll(RegExp(r'/+'), '/');
    // '/E:/…' → 'E:/…'. Only a drive letter is repaired; '/storage/…' keeps its
    // POSIX root because it has no `X:` segment.
    if (RegExp(r'^/+[A-Za-z]:(/|$)').hasMatch(s)) {
      s = s.replaceFirst(RegExp(r'^/+'), '');
    }
  }
  var end = s.length;
  while (end > 1 && s.codeUnitAt(end - 1) == 0x2F) {
    end--;
  }
  return end == s.length ? s : s.substring(0, end);
}

/// Percent-encodes an FTP proxy `path=` value, keeping `/` separators literal.
///
/// `Uri.encodeFull` leaves `&`, `#` and `=` untouched, so a file name carrying
/// them truncated the query (`ftp?host=h&port=21&path=/a&b.srt` parsed back as
/// `path=/a`). Component encoding escapes them, and restoring `%2F` keeps the
/// `/a/b.srt` shape the proxy's `queryParameters` accessor (and `changeDirectory`)
/// expects.
String encodeFtpProxyPath(String path) =>
    Uri.encodeComponent(path).replaceAll('%2F', '/');
