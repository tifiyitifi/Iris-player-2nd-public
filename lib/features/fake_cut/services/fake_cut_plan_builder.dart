import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';
import 'package:iris/features/fake_cut/services/llc_parser.dart';
import 'package:path/path.dart' as p;

/// A segment shorter than this is kept (silently dropping user data is worse)
/// but flagged: a single seek takes longer than the range, so the viewer may see
/// one frame or none.
const int kFakeCutMinUsableSegmentMs = 200;

/// Turns a parsed project into a playback plan, applying LosslessCut's own
/// export semantics:
///
///  * a segment without `end` is a MARKER and never plays
///    (`filterNonMarkers`);
///  * `selected: false` ranges are excluded;
///  * if NOTHING is selected, every non-marker range is used
///    (`selectedSegmentsWithFallback` in `useSegments.tsx`);
///  * the array order is kept verbatim — repeated, overlapping and out-of-order
///    source ranges are legal and play in that order.
///
/// [sourceDurationMs] (when known) only clamps ranges that run past the end; the
/// result is a warning, never a silent change.
FakeCutPlan buildFakeCutPlan({
  required String planPath,
  required LlcProject project,
  String? sourceFileName,
  int? sourceDurationMs,
}) {
  final List<LlcSegment> nonMarkers =
      project.segments.where((LlcSegment s) => !s.isMarker).toList();
  final int markerCount = project.segments.length - nonMarkers.length;

  final List<LlcSegment> selected =
      nonMarkers.where((LlcSegment s) => s.selected).toList();
  final int deselectedCount = nonMarkers.length - selected.length;
  final bool usedSelectedFallback =
      selected.isEmpty && nonMarkers.isNotEmpty && deselectedCount > 0;
  final List<LlcSegment> candidates =
      selected.isNotEmpty ? selected : nonMarkers;

  final List<FakeCutSegment> kept = <FakeCutSegment>[];
  int invalid = 0;
  int clamped = 0;
  int tooShort = 0;

  for (final LlcSegment raw in candidates) {
    int startMs = raw.startMs;
    int endMs = raw.endMs!;

    if (startMs < 0 || endMs <= startMs) {
      invalid++;
      continue;
    }
    if (sourceDurationMs != null && sourceDurationMs > 0) {
      if (startMs >= sourceDurationMs) {
        invalid++;
        continue;
      }
      if (endMs > sourceDurationMs) {
        endMs = sourceDurationMs;
        clamped++;
        if (endMs <= startMs) {
          invalid++;
          continue;
        }
      }
    }
    if (endMs - startMs < kFakeCutMinUsableSegmentMs) tooShort++;

    kept.add(FakeCutSegment(
      index: kept.length,
      startMs: startMs,
      endMs: endMs,
      name: raw.name,
    ));
  }

  return FakeCutPlan(
    planPath: planPath,
    displayName: p.basenameWithoutExtension(planPath),
    version: project.version,
    segments: kept,
    mediaFileName: project.mediaFileName,
    sourceFileName: sourceFileName,
    markerCount: markerCount,
    deselectedCount: deselectedCount,
    invalidCount: invalid,
    clampedCount: clamped,
    tooShortCount: tooShort,
    usedSelectedFallback: usedSelectedFallback,
  );
}
