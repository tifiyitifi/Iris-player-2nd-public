/// Clamps an intra-segment seek target so a virtual-total (100%) seek never
/// lands past the segment end (`localMs == segDur` fires an instant
/// `completed`). Segments report `segDur - 1` as the last seekable ms;
/// zero/unknown durations clamp to 0.
int clampVmLocalMs(int? segDurMs, int localMs) {
  final segDur = segDurMs ?? 0;
  if (segDur <= 0) return 0;
  return localMs.clamp(0, segDur - 1);
}

/// Last SEEKABLE millisecond inside a segment: `segDur - 1`.
///
/// The same "one ms short of the end" contract as [clampVmLocalMs]: landing ON
/// `segDur` fires an instant `completed`. A step seek therefore has to be bounded
/// by THIS, not by the raw duration, or it hands the engine a delta whose landing
/// the OSD and the persisted position deliberately avoid.
int vmLastSeekableMs(int? segDurMs) {
  final segDur = segDurMs ?? 0;
  return segDur <= 0 ? 0 : segDur - 1;
}

/// One physical video inside a Virtual Media item.
class VirtualSegment {
  /// Canonical media key `storageId:path` (the system-wide identity used by
  /// progress / tags / history).
  final String mediaKey;
  final String storageId;
  final List<String> path;
  final String name;

  /// Parent directory canonical path ('' when at storage root).
  final String parentPath;

  /// Full canonical path of the file (`parentPath/name`).
  String get fullPath =>
      parentPath.isEmpty ? name : '$parentPath/$name';

  /// Real playable/probe URI for Android SAF rows (`content://` document
  /// URI); NULL for ordinary filesystem rows (read side falls back to
  /// `playableUri(path)`).
  final String? uri;

  final int? durationMs;
  final int? width;
  final int? height;

  /// Size of the physical file in bytes; NULL when the scan did not record it.
  /// Consumed by merged-item totals (queue subtitle); never affects feasibility.
  final int? sizeInBytes;

  /// True when [durationMs] is NOT the real duration but the nominal
  /// "failed-probe" unit assigned after a probe attempt failed. Such
  /// segments render as a red bar on scrubber marks.
  final bool durationEstimated;

  /// The segment file's occurrence index within the source stream.
  ///
  /// Only meaningful when the SAME file can appear more than once in the
  /// effective stream (the scenario's `allowDuplicate` policy). A per-context
  /// bookmark stores `(storageId, path, occurrenceIndex)`; duplicate-bearing
  /// no-tag streams need this to resume the exact occurrence instead of the
  /// first one. Tag views deduplicate, so their segments are always 0.
  final int occurrenceIndex;

  const VirtualSegment({
    required this.mediaKey,
    required this.storageId,
    required this.path,
    required this.name,
    required this.parentPath,
    this.uri,
    this.durationMs,
    this.width,
    this.height,
    this.sizeInBytes,
    this.durationEstimated = false,
    this.occurrenceIndex = 0,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VirtualSegment &&
          other.mediaKey == mediaKey &&
          other.storageId == storageId &&
          other.name == name &&
          other.parentPath == parentPath &&
          other.uri == uri &&
          other.durationMs == durationMs &&
          other.width == width &&
          other.height == height &&
          other.sizeInBytes == sizeInBytes &&
          other.durationEstimated == durationEstimated &&
          other.occurrenceIndex == occurrenceIndex &&
          _pathsEqual(other.path, path);

  @override
  int get hashCode => Object.hash(
        mediaKey,
        storageId,
        name,
        parentPath,
        uri,
        durationMs,
        width,
        height,
        sizeInBytes,
        durationEstimated,
        occurrenceIndex,
        Object.hashAll(path),
      );

  static bool _pathsEqual(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Returns a copy with a new duration (and estimated flag); identity
  /// fields are untouched. Null [durationMs] clears it back to unknown.
  VirtualSegment withDuration(int? durationMs,
      {bool durationEstimated = false}) {
    return VirtualSegment(
      mediaKey: mediaKey,
      storageId: storageId,
      path: path,
      name: name,
      parentPath: parentPath,
      uri: uri,
      durationMs: durationMs,
      width: width,
      height: height,
      sizeInBytes: sizeInBytes,
      durationEstimated: durationEstimated,
      occurrenceIndex: occurrenceIndex,
    );
  }
}

/// One resolved Virtual Media item: an ordered, prefix-sum-indexed list of
/// segments presented to the player as a single playable unit.
///
/// Position mapping contract (spec §4.2):
/// - `locate(virtualPosMs)` is O(log n) binary search over [prefixMs].
/// - `offsetOf(segmentIndex)` / total duration are O(1).
/// - The playback controller caches the current segment index so per-tick
///   translation is O(1); only seeks re-run the binary search.
class VirtualMediaItem {
  final String ruleId;
  final String scopeKey;
  final String rootPath;

  /// Display chunk number within the resolve (1-based); presentation only.
  final int displayIndex;
  final String displayName;

  final List<VirtualSegment> segments;

  /// prefixMs[i] = virtual start offset of segment i. Length == n + 1.
  final List<int> prefixMs;

  VirtualMediaItem({
    required this.ruleId,
    required this.scopeKey,
    required this.rootPath,
    required this.displayIndex,
    required this.displayName,
    required List<VirtualSegment> segments,
  })  : segments = List.unmodifiable(segments),
        prefixMs = _buildPrefix(segments);

  static List<int> _buildPrefix(List<VirtualSegment> segments) {
    final out = List<int>.filled(segments.length + 1, 0);
    for (var i = 0; i < segments.length; i++) {
      out[i + 1] = out[i] + (segments[i].durationMs ?? 0);
    }
    return out;
  }

  int get totalDurationMs => prefixMs.isEmpty ? 0 : prefixMs.last;

  /// Summed byte size of the segments; unknown sizes count as 0.
  int get totalSizeBytes {
    var sum = 0;
    for (final s in segments) {
      sum += s.sizeInBytes ?? 0;
    }
    return sum;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VirtualMediaItem &&
          other.ruleId == ruleId &&
          other.scopeKey == scopeKey &&
          other.rootPath == rootPath &&
          other.displayIndex == displayIndex &&
          other.displayName == displayName &&
          _segmentsEqual(other.segments, segments);

  @override
  int get hashCode => Object.hash(
        ruleId,
        scopeKey,
        rootPath,
        displayIndex,
        displayName,
        Object.hashAll(segments),
      );

  static bool _segmentsEqual(
      List<VirtualSegment> a, List<VirtualSegment> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  int offsetOf(int segmentIndex) =>
      (segmentIndex < 0 || segmentIndex >= segments.length)
          ? 0
          : prefixMs[segmentIndex];

  /// Maps a position on the virtual timeline to `(segmentIndex, localMs)`.
  ///
  /// Positions past the end clamp to the last segment's end; unknown
  /// durations count as 0 in the timeline (their real extent resolves at
  /// playback time via lazy correction).
  (int, int) locate(int virtualPosMs) {
    if (segments.isEmpty) return (0, 0);
    final pos = virtualPosMs.clamp(0, totalDurationMs);
    var lo = 0;
    var hi = segments.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (prefixMs[mid] <= pos) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return (lo, pos - prefixMs[lo]);
  }

  /// Segment index matching [mediaKey], or null. When [occurrenceIndex] is
  /// given the match is exact on (mediaKey, occurrenceIndex), so a file that
  /// appears more than once (scenario `allowDuplicate`) resolves to the tapped
  /// occurrence instead of collapsing to the first one.
  int? indexOfSegment(String mediaKey, [int? occurrenceIndex]) {
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      if (seg.mediaKey != mediaKey) continue;
      if (occurrenceIndex == null || seg.occurrenceIndex == occurrenceIndex) {
        return i;
      }
    }
    return null;
  }

  /// Segment containing [mediaKey], or null.
  int? indexOfSegmentKey(String mediaKey) => indexOfSegment(mediaKey);
}
