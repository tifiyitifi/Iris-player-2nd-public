import 'package:iris/utils/seek_tail_guard.dart';

/// Clamps an intra-segment seek target so a virtual-total (100%) seek never
/// lands past the segment end (`localMs == segDur` fires an instant
/// `completed`). Segments report `segDur - kSeekTailGuardMs` as the last
/// seekable ms — the same guard an ordinary single file uses, because `segDur`
/// is the container duration too: its last decodable frame sits a frame duration
/// earlier and its last key frame up to a whole GOP before that. Zero/unknown
/// durations clamp to 0.
///
/// [intent] is the one exception: a caller that explicitly means "finish this
/// item" ([SeekIntent.finishAtEnd] — a scrub release at 100%) may land ON
/// `segDur`, which is what raises the `completed` that advances the virtual
/// session. A tail STEP is not such a caller: the hooks finish the item
/// directly, without a seek. The guard stays for every other caller.
int clampVmLocalMs(
  int? segDurMs,
  int localMs, {
  SeekIntent intent = SeekIntent.stopAtTail,
}) {
  final segDur = segDurMs ?? 0;
  if (segDur <= 0) return 0;
  final int maxMs = seekTailMaxMs(segDur, intent: intent);
  return localMs.clamp(0, maxMs);
}

/// One kept source range of a 虚拟剪播 plan, on the SOURCE timeline.
class VmCutKeep {
  const VmCutKeep({required this.sourceStartMs, required this.durationMs});

  /// First source millisecond this keep plays.
  final int sourceStartMs;

  /// Length of the kept range.
  final int durationMs;

  @override
  bool operator ==(Object other) =>
      other is VmCutKeep &&
      other.sourceStartMs == sourceStartMs &&
      other.durationMs == durationMs;

  @override
  int get hashCode => Object.hash(sourceStartMs, durationMs);

  @override
  String toString() => 'VmCutKeep($sourceStartMs+$durationMs)';
}

/// The kept ranges of a 虚拟剪播 plan, in PLAN order (never sorted, never
/// de-duplicated) — a LosslessCut project may reorder, repeat or overlap ranges.
///
/// WHY a plan and not one range: a merge segment is opened as ONE EDL whose
/// timeline is the CONCATENATION of the kept ranges, and its local offset is a
/// position on that cut timeline. Mapping therefore walks the ordered ranges:
/// cut → source picks the range the position falls in, while source → cut picks
/// the FIRST range that plays that source point (ADR 0037) — a repeated or
/// overlapping range legitimately has several hits, and playback resumes from
/// the earliest one without a prompt (auto-advance must not block on a dialog).
///
/// This mirrors `FakeCutTimeline`, the mapping the standalone cut playback uses,
/// so a merged segment and a standalone open agree column for column.
class VmCutRange {
  const VmCutRange({
    required this.planPath,
    this.planSignature = '',
    required this.keeps,
  });

  /// Convenience for the overwhelmingly common one-range plan.
  factory VmCutRange.single({
    required String planPath,
    String planSignature = '',
    required int sourceStartMs,
    required int durationMs,
  }) =>
      VmCutRange(
        planPath: planPath,
        planSignature: planSignature,
        keeps: <VmCutKeep>[
          VmCutKeep(sourceStartMs: sourceStartMs, durationMs: durationMs),
        ],
      );

  /// Absolute `.llc` path the group resolved. The player opens THIS plan, so
  /// the displayed duration and the played EDL can never describe two plans
  /// (ADR 0032).
  final String planPath;

  /// Content signature of the plan this range was built from
  /// (`fakeCutPlanSignature`). The player compares it with the signature of the
  /// plan it actually opened, so an edit on disk requests one live re-derive
  /// (ADR 0034). Deliberately NOT part of [==]: path + geometry identify the
  /// range, the signature is advisory freshness.
  final String planSignature;

  /// Kept ranges in plan order.
  final List<VmCutKeep> keeps;

  /// Total cut length (the segment's playback duration).
  int get durationMs {
    var total = 0;
    for (final VmCutKeep keep in keeps) {
      total += keep.durationMs;
    }
    return total;
  }

  /// First kept source millisecond (display/back-compat; the plan may keep more).
  int get sourceStartMs =>
      keeps.isEmpty ? 0 : keeps.first.sourceStartMs;

  /// Cut position → source position (what `media_nodes` stores).
  ///
  /// Clamps like `FakeCutTimeline`: before the head → the first keep's start;
  /// at/after the tail → the last keep's end (mpv reports a tail seek that way).
  int toSourceMs(int cutMs) {
    if (keeps.isEmpty) return 0;
    if (cutMs <= 0) return keeps.first.sourceStartMs;
    var acc = 0;
    for (final VmCutKeep keep in keeps) {
      if (cutMs < acc + keep.durationMs) {
        return keep.sourceStartMs + (cutMs - acc);
      }
      acc += keep.durationMs;
    }
    final VmCutKeep last = keeps.last;
    return last.sourceStartMs + last.durationMs;
  }

  /// Source position → cut position, or null when the source point was cut
  /// away (the caller then treats it as "from head").
  ///
  /// FIRST hit in plan order: a repeated/overlapping range has several hits and
  /// the earliest is the deterministic resume point (ADR 0037).
  int? toCutMs(int sourceMs) {
    var acc = 0;
    for (final VmCutKeep keep in keeps) {
      if (sourceMs >= keep.sourceStartMs &&
          sourceMs < keep.sourceStartMs + keep.durationMs) {
        return acc + (sourceMs - keep.sourceStartMs);
      }
      acc += keep.durationMs;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is VmCutRange &&
      other.planPath == planPath &&
      other.keeps.length == keeps.length &&
      _sameKeeps(other.keeps);

  bool _sameKeeps(List<VmCutKeep> other) {
    for (var i = 0; i < keeps.length; i++) {
      if (other[i] != keeps[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(planPath, Object.hashAll(keeps));

  @override
  String toString() => 'VmCutRange($planPath, keeps=[${keeps.join(', ')}], '
      'dur=$durationMs, sig=$planSignature)';
}

/// One physical video inside a Virtual Merge item.
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

  /// Non-null when this segment plays a 虚拟剪播 plan instead of the whole
  /// source. [durationMs] is then the plan's total CUT length and every local
  /// offset is a position on the concatenated cut timeline (see ADR 0037).
  final VmCutRange? cutRange;

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
    this.cutRange,
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
          other.cutRange == cutRange &&
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
        cutRange,
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
      cutRange: cutRange,
    );
  }

  /// Returns a copy that plays [cut] (or the whole source when null). A cut's
  /// length becomes the segment duration, matching the runtime derivation.
  ///
  /// When [cut] is null the SOURCE duration is restored from [sourceDurationMs].
  /// Passing it is required to undo a cut on a receiver that already carries
  /// one (its [durationMs] is then the CUT length, not the source). On a fresh
  /// DB segment the current duration is already the source, so the argument is
  /// optional and the historical behaviour is preserved when omitted.
  VirtualSegment withCutRange(VmCutRange? cut, {int? sourceDurationMs}) {
    return VirtualSegment(
      mediaKey: mediaKey,
      storageId: storageId,
      path: path,
      name: name,
      parentPath: parentPath,
      uri: uri,
      durationMs: cut?.durationMs ?? sourceDurationMs ?? durationMs,
      width: width,
      height: height,
      sizeInBytes: sizeInBytes,
      durationEstimated: durationEstimated,
      occurrenceIndex: occurrenceIndex,
      cutRange: cut,
    );
  }
}

/// One resolved Virtual Merge item: an ordered, prefix-sum-indexed list of
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
