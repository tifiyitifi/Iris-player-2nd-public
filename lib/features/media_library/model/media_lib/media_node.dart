import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:iris/models/file.dart' show Subtitle;

part 'media_node.freezed.dart';
part 'media_node.g.dart';

/// Note on sizeInBytes / totalSizeInBytes:
///
/// Dart int is 64-bit signed. SQLite INTEGER is also 64-bit signed.
/// Max value: 9,223,372,036,854,775,807 bytes (~8 EiB).
///
/// 9.2 million TB.
///
/// This is more than enough for any realistic media library (even petabyte-scale).
@freezed
abstract class MediaNode with _$MediaNode {
  const MediaNode._();

  const factory MediaNode.directory({
    required String id,
    required String storageId,
    required List<String> path,
    String? parentPath,

    /// 0=root
    /// 1=Movies
    /// 2=Movies/Action
    @Default(0) int pathDepth,
    required String name,
    @Default(null) String? normalizedName,
    // Directory-specific aggregates
    @Default(0) int directMediaCount,
    @Default(0) int directDirCount,
    @Default(0) int directItemCount,
    @Default(0) int totalMediaCount,
    @Default(0) int totalDirCount,
    @Default(0) int totalItemCount,
    @Default(0) int totalSizeInBytes,
    @Default(0) int totalDurationMs,
    //
    @Default(null) DateTime? modifiedAt,

    /// Filesystem creation time.
    ///
    /// May be unavailable on some Android providers.
    @Default(null) DateTime? createdAt,
    //
    //
    @Default(true) bool isPresent,
    @Default(null) DateTime? lastSeenAt,
  }) = MediaDirectory;

  const factory MediaNode.file({
    required String id,
    required String storageId,
    required List<String> path,
    String? parentPath,
    @Default(0) int pathDepth,
    required String name,
    String? normalizedName,
    required MediaType mediaType,

    /// File size in bytes.
    int? sizeInBytes,

    /// Media duration in milliseconds.
    int? durationMs,

    /// Real playable/probe URI for Android SAF rows (`content://` document
    /// URI) captured at browse/scan time. NULL for ordinary filesystem rows —
    /// read side falls back to [MediaNodePlayableUriX] on [path].
    String? uri,

    /// External subtitle associations captured at browse/scan time.
    ///
    /// NULL = UNKNOWN (the row predates schema v50, or a lane that cannot see
    /// the listing wrote it); `[]` = KNOWN to have none. The two are kept
    /// distinct so an upsert from a lane that does not know never clears the
    /// stored associations. Display names carry the subtitle's own file name.
    @Default(null) List<Subtitle>? subtitles,

    /// Deep-probe video frame dimensions in pixels.
    ///
    /// NULL until filled by an optional scan-time probe or the lazy
    /// playback backfill. Never wiped by rescans.
    int? width,
    int? height,
    //
    @Default(null) DateTime? modifiedAt,
    @Default(null) DateTime? createdAt,
    @Default(true) bool isPresent,
    @Default(null) DateTime? lastSeenAt,
    // ── Global per-file playback progress (uniform across all scenarios) ──
    @Default(null) int? playbackPositionMs,
    @Default(false) bool playbackCompleted,
    @Default(null) DateTime? lastPlayedAt,
    @Default(0) int playCount,

    /// Remaining history-restore budget for this file (see
    /// MediaNodesTable.historyRestoreBudget). Not part of the domain API —
    /// consumed only by the player hooks' open-resume decision.
    @Default(0) int historyRestoreBudget,
  }) = MediaFile;

  factory MediaNode.fromJson(Map<String, dynamic> json) => _$MediaNodeFromJson(json);

  // Compatibility with legacy FileItem
  bool get isDir => this is MediaDirectory;
  bool get isFile => this is MediaFile;
  // Helpers
  String get displayPath => path.join('/');
  String get fullPath => [storageId, ...path].join('/');
  String get normalizedNameValue => normalizedName ?? name.toLowerCase();

  /// The occurrence path of this node — the `path` half of a file's
  /// [PlaybackOccurrenceId].
  ///
  /// Normally the storage-relative path. A SAF single-picked file has an EMPTY
  /// path, so its only stable identity is its persisted document `uri`; keeping
  /// the empty string would collapse every such file of one storage onto the
  /// same occurrence, breaking breakpoint recovery and the queue highlight.
  /// EVERY producer and consumer of a file occurrence must agree on this form
  /// (see `scenario_resolver`, the 副音 position store and `canonicalProgressKey`).
  String get occurrencePath {
    final self = this;
    if (self is MediaFile) {
      return self.path.isNotEmpty ? self.path.join('/') : (self.uri ?? '');
    }
    return path.join('/');
  }
}

enum MediaType {
  video,
  audio,
  unknown,
}
