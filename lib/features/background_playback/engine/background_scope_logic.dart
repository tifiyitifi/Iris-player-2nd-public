/// Activation scope of one 副音 run, as pure functions.
///
/// The 作用范围 ([BgApplyScope]) decides what happens to 副音 when the
/// foreground media changes:
/// - [BgApplyScope.all]: keeps playing its own queue (nothing to do).
/// - [BgApplyScope.currentOnly]: anchored to the media the run was started on —
///   leaving it pauses 副音 while the subsystem stays alive; returning resumes.
/// - [BgApplyScope.smart]: a newly opened media defaults to off, but a media
///   with a saved 副音 pairing auto-starts 副音 ("已保存副音 fg 自动播放").
///
/// Independently of the scope, a media the user explicitly closed 副音 for
/// lives in `offMediaKeys` and never plays 副音 — it always wins.
library;

import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/model/enum/bg_cross_action.dart';

/// What the scope observer must do when the foreground media changes.
enum BgScopeAction {
  /// Nothing changes (副音 off, scope=all, or no new media).
  none,

  /// 副音 left a media it must not play — stop playing, keep the subsystem.
  pauseBg,

  /// 副音 returned to its anchored media — resume playing.
  resumeBg,

  /// The new media has a saved 副音 pairing (smart scope) — start 副音 for it.
  /// Fires from a cold (disabled) run too, so "已保存副音自动播放" can begin.
  startBg,
}

/// Decides the [BgScopeAction] for a foreground media switch.
///
/// [newFgHasSavedMapping] is only consulted for [BgApplyScope.smart].
BgScopeAction resolveBgScopeOnFgChange({
  required bool enabled,
  required BgApplyScope applyScope,
  required String? anchorKey,
  required String? newFgKey,
  Set<String> offMediaKeys = const <String>{},
  bool newFgHasSavedMapping = false,
  bool gateOpen = true,
  bool fakeCutActive = false,
  bool exhausted = false,
}) {
  final key = newFgKey;
  if (key == null) return BgScopeAction.none;
  if (offMediaKeys.contains(key)) return BgScopeAction.pauseBg;
  // 简播 (fake cut): the cut owns the picture and a virtual timeline the 副音
  // pairing cannot describe, so 副音 pauses for THIS media under every scope —
  // the same shape as a user opt-out, but temporary and resolved by the caller
  // (`BackgroundPlaybackStore.resumeAfterFakeCut`) when the foreground leaves.
  // Checked before the scope switch so 「全部」also stands down here instead of
  // playing an untethered track against the cut.
  if (fakeCutActive) return BgScopeAction.pauseBg;
  // An explicit gate stop (quick-bar gate OFF / bg stop button) wins over every
  // scope: no auto-resume or auto-start until the user opens the gate again.
  if (!gateOpen) return BgScopeAction.none;
  // stopRestoreFg terminal state: the run is over and must stay silent. Without
  // this, leaving the media and coming back resolved to `resumeBg`, and the
  // resume set `bgAutoPlay` true on a run whose 副音 track is muted to 0 — a
  // silent engine occupying the bar until a manual activation cleared it.
  if (exhausted) return BgScopeAction.none;

  switch (applyScope) {
    case BgApplyScope.all:
      return BgScopeAction.none;
    case BgApplyScope.currentOnly:
      if (!enabled) return BgScopeAction.none;
      final anchor = anchorKey;
      // No anchor = nothing to leave, so a media switch must not stop 副音.
      if (anchor == null) return BgScopeAction.none;
      return anchor == key ? BgScopeAction.resumeBg : BgScopeAction.pauseBg;
    case BgApplyScope.smart:
      // The auto-start must survive the disabled case: the observer only
      // reaches an enabled run through other means, so gating it here would
      // make [BgScopeAction.startBg] unreachable (and the callee a no-op).
      if (newFgHasSavedMapping) return BgScopeAction.startBg;
      return enabled ? BgScopeAction.pauseBg : BgScopeAction.none;
  }
}

/// Whether a foreground media switch may advance 副音's OWN queue
/// ([BgCrossAction.newBg]).
///
/// 简播 suspends the pair for the whole cut, so a step taken while the cut is
/// active only moves the queue behind a silent engine: the resume then restores
/// the transport onto a DIFFERENT track (the "队列位置丢了" report), and the step
/// races the suspend in the same commit. Both DIRECTIONS of the transition are
/// exempt — entering a cut must not advance either — which is why the caller
/// passes the previous frame's [prevFakeCutActive].
///
/// [BgApplyScope] wins over the cross setting: only a plain [BgScopeAction.none]
/// (全部 with no opt-out) is a "plain switch" that advances the track. A scope
/// transition (pause / resume / start) must never do it too.
bool bgCrossStepAllowed({
  required bool enabled,
  required bool vmSessionActive,
  required bool gateOpen,
  required BgCrossAction itemSwitch,
  required bool fakeCutActive,
  required bool prevFakeCutActive,
  required bool fgChanged,
  required BgScopeAction scopeAction,
}) {
  if (!enabled || vmSessionActive) return false;
  // Gate closed: an explicit stop must never be undone by a track switch.
  if (!gateOpen) return false;
  if (itemSwitch != BgCrossAction.newBg) return false;
  if (!fgChanged) return false;
  if (fakeCutActive || prevFakeCutActive) return false;
  return scopeAction == BgScopeAction.none;
}

/// Whether the E 节 saved-timeline driver may own 副音 right now.
///
/// The mapping layer is a SECOND owner of the 副音 runtime (it opens files,
/// holds silence, mirrors play/pause). It must stand down whenever the pair
/// itself is not in effect: a media outside the 作用范围 (仅当前 left its
/// anchor / 智能 has no pairing / user opt-out), a terminal exhausted run, a gate
/// that has run off the end of its queue, or a closed gate. Otherwise it
/// re-entered mapped segments and played `bgAutoPlay: true` on a media the scope
/// had just paused, and its per-tick transport mirror pulled the pause back
/// every frame.
///
/// [queueEnded] is the 队尾 hand-back: `enterMappedSegment` sets `bgAutoPlay:
/// true`, which the engine's autoplay sync turns into a real `play()` — 副音
/// would sound while every reader (duck, title, controls, transport mirror)
/// treats the pair as inactive.
bool mappingMayDrive({
  required bool enabled,
  required bool gateOpen,
  required bool mappingEnabled,
  required bool scopeApplied,
  required bool exhausted,
  bool queueEnded = false,
}) =>
    enabled &&
    gateOpen &&
    mappingEnabled &&
    scopeApplied &&
    !exhausted &&
    !queueEnded;

/// Whether an enabled-but-targetless scope must stop the stale audio.
///
/// The open target already folds the mapped override over the natural queue
/// entry, so a missing target means an empty/out-of-range queue: without an
/// explicit stop the engine keeps playing its previous file. The disabled
/// path is excluded — it has its own stop effect.
bool shouldStopStaleEngine({
  required bool enabled,
  required bool hasOpenTarget,
}) =>
    enabled && !hasOpenTarget;

/// Whether 副音 is currently applied to the playing foreground media — the
/// quick-bar "对当前 / 不对当前" switch state.
///
/// [fakeCutActive] is the 简播 exclusion: while a cut is on screen the pair is
/// not a pair (no alignment, no transport mirror, gate greyed), and this runs
/// before the scope rules so it holds under 「全部」as well as 「仅当前」.
bool resolveApplyToCurrent({
  required bool enabled,
  required BgApplyScope applyScope,
  required String? anchorKey,
  required Set<String> offMediaKeys,
  required String? fgKey,
  bool fakeCutActive = false,
}) {
  if (!enabled || fgKey == null || fgKey.isEmpty) return false;
  if (offMediaKeys.contains(fgKey)) return false;
  if (fakeCutActive) return false;
  if (applyScope == BgApplyScope.currentOnly) return anchorKey == fgKey;
  return true;
}

/// Direction of a foreground queue move, for stepping 副音 the same way.
///
/// 副音 used to ALWAYS step forward on a foreground switch, so 「上一集」 pushed
/// the 副音 queue forward. The move is judged from the play queue's item ids
/// (`PlayQueueItem.index`), which are monotonic with the list order but NOT
/// dense — an insert takes `maxIndex + 1` and a removal leaves a hole, so
/// `playQueue.length - 1` is NOT the last entry's id.
///
/// [firstIndex] / [lastIndex] are the ids of the queue's first and last entry.
/// The only wrap the ids can recognise on their own is `next()`'s last → head.
///
/// [moveWasForward] is the stamp `UnifiedPlayQueueStore.next()` / `previous()`
/// leaves for the move it just performed, and it WINS whenever present. Ids
/// cannot separate the remaining cases: 「上一集」 at the head and a tap on the
/// last row both arrive as `first → last`, and on a two-entry queue 「下一集」 at
/// the head and 「上一集」 at the head produce the very same pair. Only the queue
/// knows which function ran, so a stamped move is never re-derived from the ids.
bool isForwardQueueMove({
  required int? previousIndex,
  required int currentIndex,
  required int firstIndex,
  required int lastIndex,
  bool? moveWasForward,
}) {
  if (moveWasForward != null) return moveWasForward;
  final previous = previousIndex;
  if (previous == null || previous < 0 || currentIndex < 0) return true;
  // `next()` wrapped off the end: the target is the head, which reads as a
  // BACKWARD jump by id.
  if (firstIndex != lastIndex &&
      currentIndex == firstIndex &&
      previous == lastIndex) {
    return true;
  }
  return currentIndex > previous;
}
