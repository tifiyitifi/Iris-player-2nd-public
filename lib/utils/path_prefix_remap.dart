import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:iris/utils/escape_like.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Builds a single-statement leading-prefix rewrite for a table whose `path`
/// column (and optionally `parent_path`) currently begins with [oldBase].
///
/// Used when a volume is re-mounted under a new drive letter: every stored
/// path that was `<oldBase>/...` becomes `<newBase>/...` in one SQL pass, with
/// no filesystem access and no loss of the row's other columns (probe data,
/// aggregates, playback progress, …).
///
/// `UPDATE OR REPLACE` is intentional: unique-constrained tables (media_nodes,
/// scan_states, scan_queue, scenario_sources, …) must not abort when a stale
/// row already sits at the destination path — the moved row replaces it.
///
/// Rows outside the prefix are untouched; an empty [oldBase] is the caller's
/// responsibility to reject (it would match every row).
({String sql, List<Variable> variables}) buildPathPrefixRemap({
  required String table,
  required String keyColumn,
  required String keyValue,
  required String oldBase,
  required String newBase,
  bool hasParentPath = false,
}) {
  final cut = Variable.withInt(oldBase.length + 1);
  final variables = <Variable>[
    Variable.withString(oldBase),
    Variable.withString(newBase),
    Variable.withString(newBase),
    cut,
  ];
  final pathExpr =
      'path = CASE WHEN path = ? THEN ? ELSE ? || substr(path, ?) END';
  var parentExpr = '';
  if (hasParentPath) {
    parentExpr =
        ', parent_path = CASE WHEN parent_path IS NULL THEN NULL '
        // A legacy EMPTY parent is the storage root (see `_rootParent`): the
        // ELSE branch would rewrite it to `newBase`, stranding the row outside
        // the root level. Keep it empty; only a real `oldBase` prefix moves.
        "WHEN parent_path = '' THEN '' "
        'WHEN parent_path = ? THEN ? ELSE ? || substr(parent_path, ?) END';
    variables.addAll([
      Variable.withString(oldBase),
      Variable.withString(newBase),
      Variable.withString(newBase),
      Variable.withInt(oldBase.length + 1),
    ]);
  }
  variables.addAll([
    Variable.withString(keyValue),
    Variable.withString(oldBase),
    Variable.withString('${escapeLike(oldBase)}/%'),
  ]);
  return (
    sql: 'UPDATE OR REPLACE $table SET $pathExpr$parentExpr '
        'WHERE $keyColumn = ? AND (path = ? OR path LIKE ?)',
    variables: variables,
  );
}

/// Rewrites a LOCAL absolute path that lives under [oldBase] to [newBase].
///
/// Returns null when [uri] is not under the prefix (or is not a local path at
/// all) so a caller can leave the value untouched. Separators are preserved:
/// a subtitle captured on Windows is stored as `D:\Movies\a.srt`, while the
/// storage base is the canonical `D:/Movies`.
String? remapLocalPathPrefix(
  String uri, {
  required String oldBase,
  required String newBase,
}) {
  if (uri.isEmpty || oldBase.isEmpty || newBase.isEmpty) return null;
  // A stored subtitle can be a content:// document or a remote proxy address;
  // only filesystem paths carry the storage base we are rewriting.
  const remoteSchemes = ['content://', 'http://', 'https://', 'ftp://'];
  final lowerUri = uri.toLowerCase();
  for (final scheme in remoteSchemes) {
    if (lowerUri.startsWith(scheme)) return null;
  }
  final normalized = uri.replaceAll(r'\', '/');
  final oldNorm = oldBase.replaceAll(r'\', '/');
  final newNorm = newBase.replaceAll(r'\', '/');
  final bool foldCase = pathRidesCaseInsensitiveFs(normalized);
  final String haystack = foldCase ? normalized.toLowerCase() : normalized;
  final String needle = foldCase ? oldNorm.toLowerCase() : oldNorm;
  final bool exact = haystack == needle;
  final bool under = haystack.startsWith('$needle/');
  if (!exact && !under) return null;
  final rest = normalized.substring(oldNorm.length);
  final replaced = '$newNorm$rest';
  return uri.contains(r'\') ? replaced.replaceAll('/', r'\') : replaced;
}

/// Rewrites the absolute local URIs inside one `media_nodes.subtitles_json`
/// payload. Returns the new JSON only when at least one URI moved; null means
/// "no change" (the caller skips the write).
///
/// Why this exists: the video's address is REBUILT from its storage-relative
/// path at open time, so a drive-letter remap heals it automatically. An
/// external subtitle was captured as an absolute snapshot, so without this it
/// kept pointing at the old drive while the video played from the new one.
String? remapSubtitleJsonUris(
  String rawJson, {
  required String oldBase,
  required String newBase,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(rawJson);
  } on FormatException catch (error) {
    // One row's corrupt payload is that row's problem: the caller runs this in
    // a shared transaction across eight tables, and throwing here used to abort
    // the whole drive-letter rewrite.
    _log.w('remapSubtitleJsonUris: unreadable subtitles_json: $error');
    return null;
  }
  if (decoded is! List) return null;
  var changed = false;
  final next = <dynamic>[];
  for (final entry in decoded) {
    if (entry is! Map) {
      next.add(entry);
      continue;
    }
    final map = entry.cast<String, dynamic>();
    final uri = map['uri'];
    if (uri is String) {
      final replaced = remapLocalPathPrefix(
        uri,
        oldBase: oldBase,
        newBase: newBase,
      );
      if (replaced != null && replaced != uri) {
        map['uri'] = replaced;
        changed = true;
      }
    }
    next.add(map);
  }
  return changed ? jsonEncode(next) : null;
}
