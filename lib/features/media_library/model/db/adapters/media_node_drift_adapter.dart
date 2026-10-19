import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/db/storage_scope.dart';
import 'package:iris/models/file.dart' show Subtitle;
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

extension MediaNodeDriftAdapter on MediaNode {
  static MediaNode fromDb(MediaNodesTableData row) {
    // Stored path is relative to the storage base (schema v38); rebuild the
    // absolute domain path so every consumer keeps working unchanged.
    final storageId = row.storageId;
    final pathList = pathConv(StoragePathCodec.absolutize(storageId, row.path));
    final parentPath = row.parentPath == null
        ? null
        : StoragePathCodec.absolutize(storageId, row.parentPath!);

    if (row.nodeKind == MediaNodeKind.directory) {
      return MediaNode.directory(
        id: row.id.toString(),
        storageId: row.storageId,
        path: pathList,
        parentPath: parentPath,
        pathDepth: row.pathDepth,
        name: row.name,
        normalizedName: row.normalizedName,
        //
        directMediaCount: row.directMediaCount,
        directDirCount: row.directDirCount,
        directItemCount: row.directItemCount,
        //
        totalMediaCount: row.totalMediaCount,
        totalDirCount: row.totalDirCount,
        totalItemCount: row.totalItemCount,
        //
        totalSizeInBytes: row.totalSizeInBytes,
        totalDurationMs: row.totalDurationMs,
        //
        modifiedAt: row.modifiedAt,
        createdAt: row.createdAt,
        isPresent: row.isPresent,
        lastSeenAt: row.lastSeenAt,
      );
    }

    return MediaNode.file(
      id: row.id.toString(),
      storageId: row.storageId,
      path: pathList,
      parentPath: parentPath,
      pathDepth: row.pathDepth,
      name: row.name,
      normalizedName: row.normalizedName,
      mediaType: row.mediaType ?? MediaType.unknown,
      sizeInBytes: row.sizeInBytes,
      durationMs: row.durationMs,
      uri: row.uri,
      subtitles: _decodeSubtitles(row.subtitlesJson),
      width: row.width,
      height: row.height,
      modifiedAt: row.modifiedAt,
      createdAt: row.createdAt,
      isPresent: row.isPresent,
      lastSeenAt: row.lastSeenAt,
      // Global per-file playback progress (uniform across all scenarios).
      playbackPositionMs: row.playbackPositionMs,
      playbackCompleted: row.playbackCompleted,
      lastPlayedAt: row.lastPlayedAt,
      playCount: row.playCount,
      historyRestoreBudget: row.historyRestoreBudget ?? 0,
    );
  }

  /// Canonical parent path with the storage root normalised to NULL.
  ///
  /// The read side (`MediaNodesDao.getPagedNodesForSources`) identifies the
  /// storage root as `parent_path IS NULL`, but `canonicalDbPathOrNull('/')`
  /// yields an EMPTY string — so a producer passing the raw "/" form wrote rows
  /// no root query could ever match ("no playable media in folder '/'").
  static String? _canonicalParentOrNull(String? raw) {
    final canonical = canonicalDbPathOrNull(raw);
    return (canonical == null || canonical.isEmpty) ? null : canonical;
  }

  /// The `media_nodes.path` value for a FILE node: the storage-relative path, or
  /// the document `uri` when the path is EMPTY.
  ///
  /// A SAF single-picked file (`ACTION_OPEN_DOCUMENT`) is NOT under a tree, so it
  /// has no segment path and its only stable identity is the persisted document
  /// uri — which [MediaNode.occurrencePath] already uses. The DB's
  /// `UNIQUE(data_scope_id, path)` is what every upsert and path-keyed lookup is
  /// built on, so writing `path = ''` for it made the SECOND single pick of a
  /// storage overwrite the first (only the last one survived) and let a duration
  /// write-back address whichever single pick happened to own the empty path.
  /// Storing the uri as the canonical path gives each single pick its own row
  /// while keeping `occurrencePath` (and every media key derived from it)
  /// unchanged: a uri canonicalizes to itself.
  static String canonicalFilePath({
    required String storageId,
    required List<String> path,
    String? uri,
  }) {
    final domain = canonicalDbPath(path.join('/'));
    // Prefer the real segment path; fall back to the uri ONLY when there is no
    // path to speak of (a path-less SAF single pick, or any uri-only row).
    final resolved = domain.isNotEmpty ? domain : canonicalDbPath(uri ?? '');
    return StoragePathCodec.relativize(storageId, resolved);
  }

  /// Parent path in the canonical DB form, with the storage root normalised to
  /// NULL. Must be applied AFTER [StoragePathCodec.relativize]: a parent that IS
  /// the storage base relativizes to an EMPTY string, which every
  /// `parent_path IS NULL` root read cannot see (the "root folder shows media
  /// but resolves to no playable content" bug). See also [_canonicalParentOrNull],
  /// which catches the raw `'/'` form before relativization.
  static String? _relativizedParentOrNull(String storageId, String? parentRaw) {
    if (parentRaw == null) return null;
    final rel = StoragePathCodec.relativize(storageId, parentRaw);
    return rel.isEmpty ? null : rel;
  }

  MediaNodesTableCompanion toCompanion() {
    return map(
      directory: (dir) {
        final path = StoragePathCodec.relativize(
            dir.storageId, canonicalDbPath(dir.path.join('/')));
        final parentRaw =
            _canonicalParentOrNull(dir.parentPath ?? _calcParentPath(dir.path));
        final parent = _relativizedParentOrNull(dir.storageId, parentRaw);
        return MediaNodesTableCompanion.insert(
          // Canonical scope is the node identity: two linked entries always
          // report the same owner, so ids/keys (progress, history) stay stable
          // whoever scanned. Playback resolution handles a removed owner via
          // resolveStorageForNodeId (a surviving scope member is used).
          storageId: StorageScope.of(dir.storageId),
          dataScopeId: Value(StorageScope.of(dir.storageId)),
          // path: dir.path.join('/'),  // legacy: caller-slash-dependent
          path: path, // unified canonical form
          parentPath: Value(parent),
          pathDepth: Value(dir.pathDepth),
          name: dir.name,
          normalizedName: Value(dir.normalizedName ?? dir.name.toLowerCase()),
          nodeKind: MediaNodeKind.directory,
          mediaType: const Value(null),
          sizeInBytes: const Value(null),
          durationMs: const Value(null),
          //
          directMediaCount: Value(dir.directMediaCount),
          directDirCount: Value(dir.directDirCount),
          directItemCount: Value(dir.directItemCount),
          //
          totalMediaCount: Value(dir.totalMediaCount),
          totalDirCount: Value(dir.totalDirCount),
          totalItemCount: Value(dir.totalItemCount),
          totalSizeInBytes: Value(dir.totalSizeInBytes),
          totalDurationMs: Value(dir.totalDurationMs),
          //
          modifiedAt: Value(dir.modifiedAt),
          createdAt: Value(dir.createdAt),
          isPresent: Value(dir.isPresent),
          lastSeenAt: Value(dir.lastSeenAt),
        );
      },
      file: (file) {
        // The uri is the identity of a path-less SAF single pick, so it becomes
        // the canonical path (see [canonicalFilePath]).
        final path = canonicalFilePath(
          storageId: file.storageId,
          path: file.path,
          uri: file.uri,
        );
        final parentRaw = _canonicalParentOrNull(
            file.parentPath ?? _calcParentPath(file.path));
        final parent = _relativizedParentOrNull(file.storageId, parentRaw);
        return MediaNodesTableCompanion.insert(
          // Canonical scope is the node identity (see directory branch).
          storageId: StorageScope.of(file.storageId),
          dataScopeId: Value(StorageScope.of(file.storageId)),
          // path: file.path.join('/'),  // legacy: caller-slash-dependent
          path: path, // unified canonical form
          parentPath: Value(parent),
          pathDepth: Value(file.pathDepth),
          name: file.name,
          normalizedName: Value(file.normalizedName ?? file.name.toLowerCase()),
          nodeKind: MediaNodeKind.file,
          mediaType: Value(file.mediaType),
          sizeInBytes: Value(file.sizeInBytes),
          // Deep-probe fields are written ONLY when the incoming node
          // actually carries values; absent keeps whatever is already stored
          // (rescan-preserving rule — a plain rescan never wipes probe data).
          durationMs: _probeValue(file.durationMs),
          uri: _probeTextValue(file.uri),
          subtitlesJson: _subtitlesValue(file.subtitles),
          width: _probeValue(file.width),
          height: _probeValue(file.height),
          pixelCount: _probeValue(_pixelCountOf(file.width, file.height)),
          //
          directMediaCount: const Value(0),
          directDirCount: const Value(0),
          directItemCount: const Value(0),
          //
          totalMediaCount: const Value(0),
          totalDirCount: const Value(0),
          totalItemCount: const Value(0),
          totalSizeInBytes: const Value(0),
          totalDurationMs: const Value(0),
          //
          modifiedAt: Value(file.modifiedAt),
          createdAt: Value(file.createdAt),
          isPresent: Value(file.isPresent),
          lastSeenAt: Value(file.lastSeenAt),
          // playback_* progress columns stay intentionally absent here so
          // scanner/sync upserts never overwrite them. Progress is written
          // only via MediaNodesDao.updatePlaybackProgress.
        );
      },
    );
  }

  /// Absent when [v] is null (keeps the stored value on upsert); present
  /// otherwise. This lets probed scanner nodes persist their values while
  /// plain rescans never clobber existing ones.
  static Value<int?> _probeValue(int? v) =>
      v == null ? const Value.absent() : Value(v);

  /// Text counterpart of [_probeValue] (keeps a stored SAF document URI
  /// across rescans that cannot see it).
  static Value<String?> _probeTextValue(String? v) =>
      v == null ? const Value.absent() : Value(v);

  /// Whether a stored `subtitles_json` payload and a freshly listed set carry
  /// the same external tracks — the comparison the incremental scan needs.
  ///
  /// Adding or deleting a subtitle BESIDE a video leaves the video's own size
  /// and mtime untouched, so a size/mtime-only skip predicate keeps serving the
  /// stale set forever: a deleted track is offered (and fails to load) on every
  /// open, and a new one never appears.
  ///
  /// NULL [storedJson] (never captured — a pre-v50 row) is deliberately NOT
  /// "same": the row is re-upserted once so it converges on a known list. NULL
  /// [listed] means the caller's lane cannot see subtitles at all, so there is
  /// nothing to converge and the upsert would carry `Value.absent()` anyway.
  static bool sameSubtitles(String? storedJson, List<Subtitle>? listed) {
    if (storedJson == null) return false;
    if (listed == null) return true;
    // Fast path for the overwhelmingly common "no external tracks" row: one
    // string compare instead of a JSON decode on every file of a 500k scan.
    if (storedJson == '[]') return listed.isEmpty;
    if (listed.isEmpty) return false;
    final stored = _decodeSubtitles(storedJson);
    if (stored == null) return false;
    return sameSubtitleLists(stored, listed);
  }

  /// Order-insensitive equality of two decoded association sets.
  static bool sameSubtitleLists(List<Subtitle>? a, List<Subtitle>? b) {
    if (a == null || b == null) return a == null && b == null;
    if (a.length != b.length) return false;
    return a.toSet().containsAll(b);
  }

  /// JSON-encodes [subtitles] for the `subtitles_json` column.
  ///
  /// NULL (unknown) writes ABSENT so an upsert from a lane that cannot see
  /// subtitles never clears the stored associations; a known list — including
  /// the empty one — is written verbatim (`[]` records "known to have none").
  static Value<String?> _subtitlesValue(List<Subtitle>? subtitles) {
    if (subtitles == null) return const Value.absent();
    return Value(jsonEncode([for (final s in subtitles) s.toJson()]));
  }

  /// Decodes `subtitles_json`. NULL stays NULL (unknown); a malformed value
  /// degrades to the empty list rather than failing the row read.
  static List<Subtitle>? _decodeSubtitles(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <Subtitle>[];
      return [
        for (final entry in decoded)
          if (entry is Map) Subtitle.fromJson(entry.cast<String, dynamic>()),
      ];
    } catch (e) {
      _log.w('MediaNodeDriftAdapter: bad subtitles_json, ignoring: $e');
      return const <Subtitle>[];
    }
  }

  /// Cached resolution metric; derived at write time so ORDER BY stays a
  /// plain column.
  static int? _pixelCountOf(int? width, int? height) =>
      width == null || height == null ? null : width * height;

  /// Internal helper to calculate parent path if not provided
  static String? _calcParentPath(List<String> path) {
    if (path.isEmpty || path.length == 1) return null;
    return path.sublist(0, path.length - 1).join('/');
  }
}
