import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';

/// One place the SOURCE timeline maps into the VIRTUAL (cut) timeline.
///
/// Overlapping / repeated plan segments legitimately produce several hits for
/// one source position, which is why the mapping is a list and never a single
/// value.
class FakeCutSourceHit {
  const FakeCutSourceHit({required this.segmentIndex, required this.fakeMs});

  final int segmentIndex;

  /// The virtual position this source point plays at.
  final int fakeMs;

  @override
  bool operator ==(Object other) =>
      other is FakeCutSourceHit &&
      other.segmentIndex == segmentIndex &&
      other.fakeMs == fakeMs;

  @override
  int get hashCode => Object.hash(segmentIndex, fakeMs);

  @override
  String toString() => 'FakeCutSourceHit(seg=$segmentIndex fake=$fakeMs)';
}

/// Prefix-sum map between the virtual (cut) timeline and the source timeline.
///
/// The timeline is what mpv reports while an EDL is open: `duration` and
/// `time-pos` are virtual, while the persisted progress columns stay in source
/// milliseconds. Every conversion between the two axes goes through here.
///
/// Segment order is the plan order — never sorted, never de-duplicated — because
/// a LosslessCut project may repeat and reorder ranges.
class FakeCutTimeline {
  FakeCutTimeline(List<FakeCutSegment> segments)
      : segments = List<FakeCutSegment>.unmodifiable(segments),
        _fakeStarts = _prefixStarts(segments),
        totalMs = _total(segments),
        sourceSpanEndMs = _spanEnd(segments);

  static List<int> _prefixStarts(List<FakeCutSegment> segments) {
    final List<int> starts = List<int>.filled(segments.length, 0);
    int acc = 0;
    for (int i = 0; i < segments.length; i++) {
      starts[i] = acc;
      acc += segments[i].durationMs;
    }
    return starts;
  }

  static int _total(List<FakeCutSegment> segments) {
    int acc = 0;
    for (final FakeCutSegment segment in segments) {
      acc += segment.durationMs;
    }
    return acc;
  }

  static int _spanEnd(List<FakeCutSegment> segments) {
    int end = 0;
    for (final FakeCutSegment segment in segments) {
      if (segment.endMs > end) end = segment.endMs;
    }
    return end;
  }

  /// Segments in plan order.
  final List<FakeCutSegment> segments;

  /// Virtual start of each segment (same index as [segments]).
  final List<int> _fakeStarts;

  /// Total virtual duration (sum of segment durations).
  final int totalMs;

  /// Highest source end among the included segments. A LOWER BOUND of the real
  /// source duration (used only for display/fallbacks, never written to the DB
  /// duration column).
  final int sourceSpanEndMs;

  bool get isEmpty => segments.isEmpty;

  int fakeStartOf(int index) => _fakeStarts[index];

  int fakeEndOf(int index) =>
      _fakeStarts[index] + segments[index].durationMs;

  /// Virtual position → `(segmentIndex, offsetInsideSegment)`.
  ///
  /// Clamps: before the start → first segment at 0; at/after the end → last
  /// segment at its end (mpv reports the tail this way while a tail seek is in
  /// flight). An empty timeline yields `(0, 0)` and must be guarded by callers.
  (int, int) locate(int fakeMs) {
    if (segments.isEmpty) return (0, 0);
    if (fakeMs <= 0) return (0, 0);
    if (fakeMs >= totalMs) {
      final int last = segments.length - 1;
      return (last, segments[last].durationMs);
    }
    // Binary search for the last segment whose virtual start <= fakeMs.
    int lo = 0;
    int hi = segments.length - 1;
    while (lo < hi) {
      final int mid = (lo + hi + 1) >> 1;
      if (_fakeStarts[mid] <= fakeMs) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return (lo, fakeMs - _fakeStarts[lo]);
  }

  /// Virtual position → SOURCE position (what gets persisted).
  int toSourceMs(int fakeMs) {
    if (segments.isEmpty) return 0;
    final (int index, int localMs) = locate(fakeMs);
    final FakeCutSegment segment = segments[index];
    final int clamped = localMs.clamp(0, segment.durationMs);
    return segment.startMs + clamped;
  }

  /// Every virtual position that plays [sourceMs], in plan order.
  ///
  /// A position exactly on a boundary between two contiguous segments belongs to
  /// the LATER one only (half-open `[start, end)`), so a saved progress sitting
  /// on a cut boundary is not reported as ambiguous.
  List<FakeCutSourceHit> sourceHits(int sourceMs) {
    final List<FakeCutSourceHit> hits = <FakeCutSourceHit>[];
    for (int i = 0; i < segments.length; i++) {
      final FakeCutSegment segment = segments[i];
      if (sourceMs >= segment.startMs && sourceMs < segment.endMs) {
        hits.add(FakeCutSourceHit(
          segmentIndex: i,
          fakeMs: _fakeStarts[i] + (sourceMs - segment.startMs),
        ));
      }
    }
    return hits;
  }

  /// Virtual start of the first segment (in PLAYBACK order) whose source range
  /// begins AFTER [sourceMs] — the "resume from the next kept range" rule when
  /// the saved progress fell in a removed gap. Null when no later range exists.
  ///
  /// Plan order, not source order: the array order is what playback follows, and
  /// for a normally ascending project both readings are identical.
  int? nextFakeStartAfterSource(int sourceMs) {
    for (int i = 0; i < segments.length; i++) {
      if (segments[i].startMs > sourceMs) return _fakeStarts[i];
    }
    return null;
  }
}
