import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_timeline.dart';

/// Everything the UI needs to explain what the plan did to the project file.
///
/// These are PRODUCT TRADEOFFS, not defects: each one mirrors a documented
/// LosslessCut rule or a v1 scope decision, and the tab renders them instead of
/// hiding them.
enum FakeCutNoticeKind {
  /// Segments without `end` are LosslessCut markers, not ranges.
  markersIgnored,

  /// `selected: false` segments do not participate in an export.
  deselectedIgnored,

  /// Every segment was deselected, so all non-marker segments were used
  /// (LosslessCut's `selectedSegmentsWithFallback`).
  selectedFallback,

  /// `end <= start`, or the range starts past the source duration.
  invalidDropped,

  /// `end` was past the source duration and was clamped.
  clampedToSource,

  /// Shorter than the player can meaningfully show (a seek alone takes longer).
  tooShort,

  /// `mediaFileName` in the project differs from the playing file.
  fileMismatch,
}

class FakeCutNotice {
  const FakeCutNotice({required this.kind, this.count = 0, this.detail});

  final FakeCutNoticeKind kind;

  /// Number of affected segments (0 for [FakeCutNoticeKind.fileMismatch]).
  final int count;

  /// File name for [FakeCutNoticeKind.fileMismatch]; null otherwise.
  final String? detail;
}

/// An immutable, playback-ready fake-cut plan built from one `.llc` file.
class FakeCutPlan {
  FakeCutPlan({
    required this.planPath,
    required this.displayName,
    required this.version,
    required List<FakeCutSegment> segments,
    this.mediaFileName,
    this.sourceFileName,
    this.markerCount = 0,
    this.deselectedCount = 0,
    this.invalidCount = 0,
    this.clampedCount = 0,
    this.tooShortCount = 0,
    this.usedSelectedFallback = false,
  }) : segments = List<FakeCutSegment>.unmodifiable(segments) {
    timeline = FakeCutTimeline(this.segments);
  }

  /// Absolute path of the `.llc`. Identity of the plan (two projects may have
  /// the same display name and the same segments).
  final String planPath;

  /// File name without the `.llc` suffix, shown in the tab.
  final String displayName;

  /// Project file version (1/2/3) — informational.
  final int version;

  /// Ordered, filtered source ranges.
  final List<FakeCutSegment> segments;

  late final FakeCutTimeline timeline;

  /// `mediaFileName` recorded in the project.
  final String? mediaFileName;

  /// Name of the file currently playing (for the mismatch notice).
  final String? sourceFileName;

  final int markerCount;
  final int deselectedCount;
  final int invalidCount;
  final int clampedCount;
  final int tooShortCount;
  final bool usedSelectedFallback;

  int get totalMs => timeline.totalMs;

  bool get isEmpty => segments.isEmpty;

  /// Lower bound of the source duration: the highest included `end`. Never
  /// written to `media_nodes.duration_ms` (it is not the container duration).
  int get sourceSpanEndMs => timeline.sourceSpanEndMs;

  List<FakeCutNotice> get notices {
    final List<FakeCutNotice> out = <FakeCutNotice>[];
    if (markerCount > 0) {
      out.add(FakeCutNotice(
          kind: FakeCutNoticeKind.markersIgnored, count: markerCount));
    }
    if (deselectedCount > 0) {
      out.add(FakeCutNotice(
          kind: FakeCutNoticeKind.deselectedIgnored, count: deselectedCount));
    }
    if (usedSelectedFallback) {
      out.add(const FakeCutNotice(kind: FakeCutNoticeKind.selectedFallback));
    }
    if (invalidCount > 0) {
      out.add(FakeCutNotice(
          kind: FakeCutNoticeKind.invalidDropped, count: invalidCount));
    }
    if (clampedCount > 0) {
      out.add(FakeCutNotice(
          kind: FakeCutNoticeKind.clampedToSource, count: clampedCount));
    }
    if (tooShortCount > 0) {
      out.add(FakeCutNotice(
          kind: FakeCutNoticeKind.tooShort, count: tooShortCount));
    }
    if (mediaFileName != null &&
        sourceFileName != null &&
        mediaFileName != sourceFileName) {
      out.add(FakeCutNotice(
          kind: FakeCutNoticeKind.fileMismatch, detail: mediaFileName));
    }
    return out;
  }

  @override
  String toString() => 'FakeCutPlan($displayName, '
      '${segments.length} segments, ${totalMs}ms)';
}
