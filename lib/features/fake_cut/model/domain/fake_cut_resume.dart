import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_timeline.dart';

/// What the saved SOURCE progress means on the virtual timeline.
enum FakeCutResumeKind {
  /// No usable source progress: start at the beginning.
  none,

  /// Exactly one segment plays that source position.
  exact,

  /// Several segments play it (overlap / repeat): the user picks the sync point.
  ambiguous,

  /// The saved position was cut away: resume at the next kept range's start.
  gapNext,

  /// The saved position is past every kept range: treat as watched, start over.
  afterEnd,
}

class FakeCutResume {
  const FakeCutResume({
    required this.kind,
    this.fakeMs,
    this.candidates = const <FakeCutSourceHit>[],
  });

  final FakeCutResumeKind kind;

  /// Target virtual position for [FakeCutResumeKind.exact] / `gapNext`.
  final int? fakeMs;

  /// Candidates for [FakeCutResumeKind.ambiguous] (never empty for it).
  final List<FakeCutSourceHit> candidates;

  bool get needsChoice => kind == FakeCutResumeKind.ambiguous;

  @override
  String toString() =>
      'FakeCutResume(${kind.name}, fake=$fakeMs, candidates=${candidates.length})';
}

/// Maps a SOURCE resume position onto the virtual timeline.
///
/// Rules (agreed product behaviour):
///  * one hit → use it;
///  * several hits → ask ([FakeCutResumeKind.ambiguous]);
///  * none, with a later kept range → that range's start (gap→next);
///  * none, and every range starts before it → treated as finished.
FakeCutResume resolveFakeCutResume(FakeCutPlan plan, int? sourceMs) {
  if (sourceMs == null || sourceMs <= 0 || plan.isEmpty) {
    return const FakeCutResume(kind: FakeCutResumeKind.none);
  }
  final FakeCutTimeline timeline = plan.timeline;
  final List<FakeCutSourceHit> hits = timeline.sourceHits(sourceMs);
  if (hits.length == 1) {
    return FakeCutResume(kind: FakeCutResumeKind.exact, fakeMs: hits.first.fakeMs);
  }
  if (hits.length > 1) {
    return FakeCutResume(
      kind: FakeCutResumeKind.ambiguous,
      candidates: hits,
    );
  }
  final int? next = timeline.nextFakeStartAfterSource(sourceMs);
  if (next != null) {
    return FakeCutResume(kind: FakeCutResumeKind.gapNext, fakeMs: next);
  }
  return const FakeCutResume(kind: FakeCutResumeKind.afterEnd);
}

/// Chooses the landing target of [resume], optionally without a prompt.
///
/// [autoResolve] is for a merged cut segment's auto-advance: it must never block
/// on a dialog, so an ambiguous (repeated / overlapping) source point takes the
/// FIRST hit in plan order — exactly what the merge timeline does (ADR 0037).
/// With [autoResolve] false an ambiguous resume still
/// reports [needsChoice] so the caller can show the sync dialog.
///
/// A `fakeMs == null` with `needsChoice == false` means "start at the head".
({int? fakeMs, bool needsChoice}) decideFakeCutResume(
  FakeCutResume resume, {
  bool autoResolve = false,
}) {
  switch (resume.kind) {
    case FakeCutResumeKind.none:
    case FakeCutResumeKind.afterEnd:
      return (fakeMs: null, needsChoice: false);
    case FakeCutResumeKind.exact:
    case FakeCutResumeKind.gapNext:
      return (fakeMs: resume.fakeMs, needsChoice: false);
    case FakeCutResumeKind.ambiguous:
      if (autoResolve) {
        return (fakeMs: resume.candidates.first.fakeMs, needsChoice: false);
      }
      return (fakeMs: null, needsChoice: true);
  }
}
