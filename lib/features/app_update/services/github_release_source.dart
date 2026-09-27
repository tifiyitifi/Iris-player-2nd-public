import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:iris/features/app_update/model/app_version.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.appUpdate);

/// Where update information comes from.
///
/// The public repository, never the development one: a build installed from a
/// public release must be told about public releases, or it would be offered a
/// "newer" version that is in fact older. Kept as constants so a future
/// self-hosted mirror is a one-line change.
class UpdateSource {
  const UpdateSource._();

  static const String repoSlug = 'tifiyiti/Iris-player-2nd-public';

  /// The HTML release list. Its `/latest` URL answers with a 302 to the newest
  /// release's page, so the tag can be read from a redirect target without
  /// touching the API and without spending any of the 60/hour anonymous quota.
  static const String latestReleaseUrl =
      'https://github.com/$repoSlug/releases/latest';

  /// Per-tag release payload: assets, notes, timestamps.
  static const String releaseApiUrl =
      'https://api.github.com/repos/$repoSlug/releases/tags';

  static String tagUrl(String tag) =>
      'https://github.com/$repoSlug/releases/tag/$tag';

  static const Duration connectTimeout = Duration(seconds: 8);
  static const Duration readTimeout = Duration(seconds: 10);
}

/// Reads the newest published tag without spending API quota.
///
/// Follows no redirect: the 302 `Location` carries `/releases/tag/<tag>`, which
/// is all the version comparison needs. A 404 means the repository has no
/// published release at all.
Future<String?> fetchLatestReleaseTag({
  Duration connectTimeout = UpdateSource.connectTimeout,
  Duration readTimeout = UpdateSource.readTimeout,
}) async {
  final client = HttpClient()..connectionTimeout = connectTimeout;
  try {
    final request = await client.getUrl(Uri.parse(UpdateSource.latestReleaseUrl));
    // Redirects are the payload here, not something to follow: the 302 target
    // names the newest published tag.
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent());
    final response = await request.close().timeout(readTimeout);
    // Drain so the connection can be released promptly.
    await response.drain<void>();
    return latestTagFromResponse(
      status: response.statusCode,
      location: response.headers.value(HttpHeaders.locationHeader),
    );
  } on TimeoutException {
    throw const UpdateFetchException(UpdateFailure.timeout);
  } on SocketException {
    throw const UpdateFetchException(UpdateFailure.network);
  } on HandshakeException {
    throw const UpdateFetchException(UpdateFailure.network);
  } on HttpException {
    throw const UpdateFetchException(UpdateFailure.network);
  } finally {
    client.close(force: true);
  }
}

/// The tag named by a `/releases/latest` answer, or null when the repository
/// has never published one.
///
/// Split out of [fetchLatestReleaseTag] because the whole decision is about two
/// values, and two values are testable without a socket. A null here is one
/// answer and one answer only: "nothing has ever been published". Every other
/// outcome throws, because "I could not find out" and "there is nothing new"
/// must never reach the user wearing the same sentence.
@visibleForTesting
String? latestTagFromResponse({required int status, String? location}) {
  if (status == 404) {
    // 404 is safe to read as "nothing published" and 404 alone: GitHub answers a
    // renamed or transferred repository with a 301 to its new home, so a 404 is
    // never a moved repository in disguise, and never a failure to report.
    return null;
  }

  if (status >= 300 && status < 400) {
    final tag =
        location == null || location.isEmpty ? null : _tagFromLocation(location);
    if (tag != null) return tag;
    // The redirect is the payload, so a redirect that does not carry a tag is a
    // failure rather than an absence: GitHub's sign-in challenge and the
    // repository root both land here, as does a blocking page put in the way by
    // the local network.
    throw UpdateFetchException(
      UpdateFailure.unreadableReleasePage,
      detail: location ?? 'status $status',
    );
  }

  if (status != 200) {
    // 403 (refused as a bot), 429 (anonymous rate limit), 5xx (GitHub down) and
    // a proxy's own error page all end up here, still carrying their status so
    // the report can say which of those it was.
    throw UpdateFetchException(UpdateFailure.http, detail: '$status');
  }

  // 200 with no redirect target: either GitHub served the page itself, or
  // something on the network answered in its place. Reading that as "nothing
  // published" is what reported a blocked network as "you are up to date", so
  // it fails instead — visibly, and with the answer in the log.
  throw const UpdateFetchException(
    UpdateFailure.unreadableReleasePage,
    detail: 'status 200',
  );
}

/// Extracts `<tag>` from a `/releases/tag/<tag>` URL, or null when the
/// redirect pointed somewhere else (e.g. the repository root).
String? _tagFromLocation(String location) {
  final uri = Uri.tryParse(location);
  if (uri == null) return null;
  final segments = uri.pathSegments;
  final index = segments.indexOf('tag');
  if (index < 0 || index + 1 >= segments.length) return null;
  final tag = segments[index + 1];
  return tag.isEmpty ? null : tag;
}

/// Fetches one release payload and normalizes it.
///
/// The `User-Agent` header is mandatory, not politeness: GitHub's REST API
/// answers 403 to anonymous requests that omit it, which is why the legacy
/// updater could never succeed — `package:http` sends no UA by default.
Future<ReleaseInfo> fetchReleaseInfo(
  String tag, {
  Duration connectTimeout = UpdateSource.connectTimeout,
  Duration readTimeout = UpdateSource.readTimeout,
}) async {
  final client = HttpClient()..connectionTimeout = connectTimeout;
  try {
    final request = await client
        .getUrl(Uri.parse('${UpdateSource.releaseApiUrl}/$tag'));
    request.headers
      ..set(HttpHeaders.userAgentHeader, _userAgent())
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close().timeout(readTimeout);
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(readTimeout);
    if (response.statusCode != 200) {
      _log.w('release fetch for $tag returned ${response.statusCode}');
      throw UpdateFetchException(
        UpdateFailure.http,
        detail: '${response.statusCode}',
      );
    }
    return parseReleaseInfo(body, fallbackTag: tag);
  } on TimeoutException {
    throw const UpdateFetchException(UpdateFailure.timeout);
  } on SocketException {
    throw const UpdateFetchException(UpdateFailure.network);
  } on HandshakeException {
    throw const UpdateFetchException(UpdateFailure.network);
  } on FormatException catch (error) {
    _log.w('release payload for $tag is not JSON: $error');
    throw const UpdateFetchException(UpdateFailure.http, detail: 'malformed');
  } finally {
    client.close(force: true);
  }
}

/// Parses a GitHub release payload into [ReleaseInfo].
///
/// Defensive by construction: a release with no assets, no body, no tag or an
/// unparseable date still yields a usable object, because a partial answer
/// beats a crash in a dialog.
ReleaseInfo parseReleaseInfo(String body, {String? fallbackTag}) {
  final decoded = json.decode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const UpdateFetchException(UpdateFailure.http, detail: 'malformed');
  }
  final tag = (decoded['tag_name'] as String?)?.trim();
  final resolvedTag = (tag == null || tag.isEmpty) ? fallbackTag : tag;
  if (resolvedTag == null || resolvedTag.isEmpty) {
    throw const UpdateFetchException(UpdateFailure.http, detail: 'malformed');
  }
  final rawAssets = decoded['assets'];
  final assets = <ReleaseAsset>[];
  if (rawAssets is List) {
    for (final entry in rawAssets) {
      if (entry is! Map<String, dynamic>) continue;
      final name = entry['name'];
      final url = entry['browser_download_url'];
      if (name is! String || name.isEmpty) continue;
      if (url is! String || url.isEmpty) continue;
      final size = entry['size'];
      assets.add(ReleaseAsset(
        name: name,
        downloadUrl: url,
        size: size is int ? size : 0,
      ));
    }
  }
  return ReleaseInfo(
    tag: resolvedTag,
    version: stripTagPrefix(resolvedTag),
    pageUrl: (decoded['html_url'] as String?) ??
        UpdateSource.tagUrl(resolvedTag),
    notes: (decoded['body'] as String?) ?? '',
    publishedAt: _parseTimestamp(decoded['published_at']),
    assets: List.unmodifiable(assets),
  );
}

DateTime? _parseTimestamp(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}

/// Drops a leading `v` so display strings and comparison use the same form.
String stripTagPrefix(String tag) {
  var text = tag.trim();
  if (text.startsWith('v') || text.startsWith('V')) {
    text = text.substring(1);
  }
  return text;
}

/// Whether [tag] names a version this app can reason about. A leftover
/// local-build tag such as `2.0.0.local` is neither draft nor prerelease, so
/// GitHub may report it as the latest release; treating that as "up to date"
/// would silently disable updates.
bool isUsableReleaseTag(String tag) => parseVersion(tag) != null;

String _userAgent() => 'IRIS/${_currentVersion ?? '0.0.0'} (${UpdateSource.repoSlug})';

String? _currentVersion;

/// Lets the app inject its own version so the User-Agent identifies the build
/// making the request (and so tests stay deterministic).
void setUpdateUserAgentVersion(String version) {
  _currentVersion = version;
}

/// Transport-level failure, carrying the user-facing reason.
class UpdateFetchException implements Exception {
  const UpdateFetchException(this.reason, {this.detail});

  final UpdateFailure reason;
  final String? detail;

  @override
  String toString() => 'UpdateFetchException($reason, $detail)';
}
