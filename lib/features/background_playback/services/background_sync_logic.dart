import 'package:iris/features/background_playback/model/enum/bg_seek_link.dart';
import 'package:iris/features/background_playback/model/enum/bg_step_mode.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';

/// Pure decision helpers for the 进度锁定 (progress lock) — how much of the two
/// runtimes' transport is shared.
///
/// Kept free of player/store types so every rule is directly unit-testable; the
/// runtime observer (`BackgroundRuntimeScope`) only wires these to the engines.
abstract final class BackgroundSyncLogic {
  /// Position drift tolerated before a mirror is issued, in milliseconds.
  static const int kPositionToleranceMs = 250;

  /// Drift beyond the wall-clock window before a sample counts as a seek,
  /// in milliseconds.
  static const int kJumpSlackMs = 1200;

  /// Guard band at the foreground file tail, in milliseconds.
  ///
  /// A bg-master mirror target landing inside this band must never be issued
  /// as a raw seek: parking the player exactly at (or within quantization
  /// noise of) its duration raises a genuine `completed` and auto-advances
  /// the queue — the "enabling 副音 skips the episode" report. Larger than
  /// position-sample jitter, far smaller than any meaningful tail.
  static const int kBgMasterTailGuardMs = 750;

  /// Drift tolerated on a settled (no-jump) sample before 高同步 pulls the
  /// follower back, in milliseconds.
  ///
  /// 高同步 (`linked` + `high`) means the two timelines advance TOGETHER, not
  /// merely mirror discrete jumps. When one runtime stalls (a pause the other
  /// side never mirrored, a VM transition, a decoder hiccup) the master's
  /// position runs ahead and the counter on the follower freezes — the
  /// "开启副音后 fg 计数不变" report. This tolerance is deliberately larger
  /// than [kPositionToleranceMs] (sample jitter / re-anchor noise) and than a
  /// single notify tick, so a healthy pair never seeks and only a genuine
  /// divergence is corrected.
  static const int kContinuousDriftToleranceMs = 500;
}

/// Maps the pre-split single-value 进度锁定 row (`full` | `playPauseOnly` |
/// `independent`) onto the two orthogonal axes. Null for an unknown/absent
/// value so the caller keeps its defaults.
({BgSeekLink link, BgLockLevel level})? migrateLegacyProgressLock(
    String? name) {
  switch (name) {
    case 'full':
      return (link: BgSeekLink.linked, level: BgLockLevel.high);
    case 'playPauseOnly':
      return (link: BgSeekLink.linked, level: BgLockLevel.low);
    case 'independent':
      return (link: BgSeekLink.independent, level: BgLockLevel.high);
  }
  return null;
}

/// Which runtime the shared controls currently drive — the mirror MASTER.
///
/// The master's transport/position state is copied onto the other side, so the
/// pair follows whichever player the panel is controlling. Copying in one
/// direction only (master → other) is what makes the mirror loop-free.
bool mirrorSourceIsBackground({
  required bool bgEnabled,
  required ControlTarget target,
}) =>
    bgEnabled && target == ControlTarget.background;

/// Whether the runtime observer must stand down entirely — no fg↔bg transport
/// or position mirror and no seek-window publish.
///
/// A run that is off, whose user gate is shut, or that reached its terminal
/// stopRestoreFg state must not move either runtime. The exhausted case is the
/// subtle one: its terminal pause is NOT a transport disagreement, so the
/// transport mirror must not read it as "the follower should be playing" and
/// resume (and replay) the dead run.
bool bgMirrorStandsDown({
  required bool enabled,
  required bool gateOpen,
  required bool exhausted,
}) =>
    !enabled || !gateOpen || exhausted;

/// Whether play/pause and stop are shared (`linked`, at either level).
///
/// Fully [BgSeekLink.independent] shares nothing at all.
bool shouldSyncTransport(BgSeekLink link) => link != BgSeekLink.independent;

/// Whether seeks are mirrored too — `linked` AND the high level.
///
/// The low level deliberately leaves seeks free so the user can slide either
/// axis to fine-tune alignment; fully independent overrides both.
bool shouldSyncPosition({
  required BgSeekLink link,
  required BgLockLevel level,
}) =>
    link == BgSeekLink.linked && level == BgLockLevel.high;

/// Whether the two play/pause flags disagree — i.e. a mirror is needed.
bool shouldMirrorTransport({
  required bool fgPlaying,
  required bool bgPlaying,
}) =>
    fgPlaying != bgPlaying;

/// How the 副音 pair cooperates with an in-flight FOREGROUND scrub drag.
///
/// A scrub pauses the foreground and issues live seeks. That pause is a
/// GESTURE artifact, not a user transport change, so the mirror must not treat
/// it as one — and the drag's per-tick seeks must never drag the 副音 timeline
/// (the two sliders then fight and the thumb snaps back).
enum BgScrubPolicy {
  /// The pair is off or fully unlinked: a drag never touches 副音.
  none,

  /// linked + low (仅播放暂停): only the PAUSE follows the drag; on release 副音
  /// resumes playing at its OWN position (seeks are never mirrored).
  pauseBgFollows,

  /// linked + high (高同步): the pause follows AND the pair must land aligned.
  /// On release the 高同步 drift correction re-aligns once; if the landing maps
  /// outside any valid bg rule (no mapping / offset not ready / past the 仅当前
  /// window) the 副音 stays stopped rather than playing at a wrong position.
  followWithProgress,
}

/// Resolves [BgScrubPolicy] from the live link axes (see [BackgroundSyncLogic]).
BgScrubPolicy resolveBgScrubPolicy({
  required bool enabled,
  required BgSeekLink link,
  required BgLockLevel level,
}) {
  if (!enabled || link == BgSeekLink.independent) return BgScrubPolicy.none;
  return level == BgLockLevel.high
      ? BgScrubPolicy.followWithProgress
      : BgScrubPolicy.pauseBgFollows;
}

/// Whether two positions drifted past [toleranceMs] — i.e. a seek landed on one
/// side and the other should catch up.
bool shouldMirrorPosition({
  required int fgMs,
  required int bgMs,
  int toleranceMs = BackgroundSyncLogic.kPositionToleranceMs,
}) =>
    (fgMs - bgMs).abs() > toleranceMs;

/// Whether a natural 副音 position has run past the foreground window end.
///
/// The window end B is the bg position mapped to fg 100%: `fgDurMs - offsetMs`
/// (the fixed offset is `fg - bg`). Folding [offsetMs] in is what keeps a
/// non-zero alignment offset from pausing 副音 late (still sounding past the
/// video) or early. [guardMs] keeps the pause off the exact tail.
bool shouldPauseBgPastWindow({
  required int bgVirtualMs,
  required int fgDurMs,
  required int offsetMs,
  int guardMs = BackgroundSyncLogic.kBgMasterTailGuardMs,
}) =>
    bgVirtualMs + offsetMs > fgDurMs + guardMs;

/// Whether a discrete 副音 STEP (next/prev) may be mirrored onto the foreground.
///
/// Deliberately separate from [shouldSyncPosition]: the seek-link axis governs
/// continuous slider mirroring, while stepping is a user ACTION that most users
/// want to confine to the 副音 track. Only `followLink` + a position-sharing
/// link mirrors it; the default `swapOnly` leaves the foreground untouched.
bool shouldMirrorStep({
  required BgStepMode stepMode,
  required BgSeekLink link,
  required BgLockLevel level,
}) =>
    stepMode == BgStepMode.followLink &&
    shouldSyncPosition(link: link, level: level);

/// Whether the bg-master position mirror may touch the foreground AT ALL.
///
/// Outside 高同步 (linked + high) a bg-side jump is never mirrored — not even
/// clamped: low-linkage modes only share play/pause, so any foreground seek
/// or queue roll from a 副音 jump would be an uncommanded episode move. The
/// observer re-anchors its offset instead. Same predicate as
/// [shouldSyncPosition], named for the call site's intent.
bool bgMasterMayTouchFg({
  required BgSeekLink link,
  required BgLockLevel level,
}) =>
    shouldSyncPosition(link: link, level: level);

/// What the bg-master mirror should do with one mapped foreground target.
enum BgMasterFgAction {
  /// Seek inside the current foreground file (partial reverse control).
  seek,

  /// The target leaves the current file: roll the foreground queue (high
  /// sync only — the caller gates on [bgMasterMayTouchFg] first).
  roll,

  /// The target leaves the current file and no cross-file move is warranted:
  /// leave the foreground alone. A roll is a real queue advance (the reported
  /// "开启副音跳到下一集"), so it must be earned by a REAL 副音 move — the
  /// continuous 高同步 drift correction lands here too, and a drifted pair
  /// mapping outside the file is exactly the state that must not move the
  /// video.
  hold,
}

/// Resolves one bg-master mirror target against the foreground file tail.
///
/// A target inside `[0, fgDurMs - tailGuardMs]` seeks in place; anything at
/// or past the tail (including exactly `fgDurMs`, which would park the
/// player at its end and raise a genuine completion) rolls instead, as does
/// a negative target. An unknown duration (`<= 0`) cannot judge the tail,
/// so it seeks and lets the player clamp.
///
/// [allowRoll] gates the cross-file move: with it off, a target that leaves
/// the file becomes [BgMasterFgAction.hold] instead of rolling the queue, so a
/// mirror sample that was not caused by a real 副音 move (the 高同步 drift
/// correction) can never advance the foreground onto another episode.
BgMasterFgAction resolveBgMasterFgAction({
  required int fgTarget,
  required int fgDurMs,
  int tailGuardMs = BackgroundSyncLogic.kBgMasterTailGuardMs,
  bool allowRoll = true,
}) {
  if (fgDurMs <= 0) return BgMasterFgAction.seek;
  final bool leavesFile =
      fgTarget < 0 || fgTarget > fgDurMs - tailGuardMs;
  if (!leavesFile) return BgMasterFgAction.seek;
  return allowRoll ? BgMasterFgAction.roll : BgMasterFgAction.hold;
}

/// Clamps a bg-master mirror target into the foreground's playable window
/// under 仅当前: 副音 exists only inside the fg file, so a target before 0 or
/// at/past the tail must never roll the foreground onto another episode. The
/// result stays inside `[0, fgDur - tailGuard]` (a known duration); an unknown
/// duration only floors at 0.
int clampScopedFgTarget({
  required int fgTarget,
  required int fgDurMs,
  int tailGuardMs = BackgroundSyncLogic.kBgMasterTailGuardMs,
}) =>
    clampFgTargetToWindow(
      fgTarget: fgTarget,
      windowStartMs: 0,
      windowDurMs: fgDurMs,
      tailGuardMs: tailGuardMs,
    );

/// Clamps a bg-master mirror target into ONE physical foreground window.
///
/// Under 仅当前 on a Virtual Media session the foreground "file" is the
/// segment playing right now, not the merged total: clamping against the total
/// still lets a bg-master target land on another segment (a cross-segment jump
/// the scope forbids). [windowStartMs] is the window's virtual start and
/// [windowDurMs] its length, so the result stays inside
/// `[start, start + dur - tailGuard]`; an unknown length only floors at the
/// start. A non-Virtual foreground passes `start = 0`, reproducing the
/// single-file behavior.
int clampFgTargetToWindow({
  required int fgTarget,
  required int windowStartMs,
  required int windowDurMs,
  int tailGuardMs = BackgroundSyncLogic.kBgMasterTailGuardMs,
}) {
  if (windowDurMs <= 0) {
    return fgTarget < windowStartMs ? windowStartMs : fgTarget;
  }
  final int windowEnd = windowStartMs + windowDurMs;
  final int maxTarget =
      (windowEnd - tailGuardMs).clamp(windowStartMs, windowEnd);
  return fgTarget.clamp(windowStartMs, maxTarget);
}

/// The runtime observer's mirror decision for ONE position sample.
///
/// Extracted from `BackgroundRuntimeScope` so every scope × link × control
/// combination is directly unit-testable. The caller owns the side effects
/// (anchoring, seeking, rolling); this returns only WHAT to do.
enum BgMirrorAction {
  /// Nothing: the pair is off, unlinked, or another subsystem owns the
  /// position (align editor, E-节 mapping, an opening file).
  none,

  /// Re-anchor the fixed offset from this sample.
  anchor,

  /// Consume our own bg system seek's landing: swallow it, re-anchor, never
  /// mirror it onto the foreground.
  stayBg,

  /// Consume our own fg system seek's landing: swallow it, re-anchor, never
  /// mirror it onto the 副音 queue. Without this the bg-master mirror's own
  /// foreground seek is read back as a user fg seek and rolls the bg queue.
  stayFg,

  /// The 副音 side moved and is the control master: drive the foreground.
  bgDrivesFg,

  /// The foreground moved: map it onto the 副音 queue.
  fgDrivesBg,
}

/// Decides the mirror action. Pure; see [BgMirrorAction].
///
/// Order matters: a landing of our own system seek
/// ([fgSystemSeekLanding]/[bgSystemSeekLanding]) is swallowed BEFORE any jump
/// is interpreted, which is what breaks the fg↔bg ping-pong. An ambiguous
/// (both moved) sample anchors. A settled sample anchors too — UNLESS 高同步
/// has let the two positions drift past [driftToleranceMs], which is corrected
/// in the MASTER's direction so both counters keep advancing together. Only the
/// master side's jump drives the other (`bgJump` → fg when the panel controls
/// 副音); a foreground-only move always maps, because that is a user gesture
/// (a natural advance is continuous, never a jump).
///
/// A system seek that is still IN FLIGHT (issued, landing not observed yet) is
/// handled by the caller as a hold — it must not anchor and must not mirror
/// (see the runtime observer's latch refs).
BgMirrorAction resolveBgMirrorAction({
  required bool enabled,
  required bool positionSync,
  required bool standDown,
  required bool bgIsMaster,
  required bool fgJump,
  required bool bgJump,
  required bool fgSystemSeekLanding,
  required bool bgSystemSeekLanding,
  required bool pendingStep,
  required bool mirrorStep,
  required bool lockOffsetReady,
  int driftMs = 0,
  int driftToleranceMs = BackgroundSyncLogic.kContinuousDriftToleranceMs,
}) {
  if (!enabled || !positionSync || standDown) return BgMirrorAction.none;
  // Our own landings: swallow before interpreting any jump (the loop-break).
  if (bgSystemSeekLanding) return BgMirrorAction.stayBg;
  if (fgSystemSeekLanding) return BgMirrorAction.stayFg;
  // Settled sample. 高同步 locks the two positions onto the fixed offset, so a
  // gap past the tolerance is corrected in the MASTER's direction instead of
  // merely re-anchoring — otherwise a stalled follower is left behind forever.
  // A pending step owns its landing and must never be fought by this branch.
  if (!fgJump && !bgJump) {
    if (!pendingStep && lockOffsetReady && driftMs > driftToleranceMs) {
      return bgIsMaster ? BgMirrorAction.bgDrivesFg : BgMirrorAction.fgDrivesBg;
    }
    return BgMirrorAction.anchor;
  }
  if (fgJump && bgJump) return BgMirrorAction.anchor;

  if (bgJump) {
    // A 副音 jump only moves the foreground while the panel controls 副音.
    if (!bgIsMaster) return BgMirrorAction.anchor;
    // swapOnly: a discrete step stays on the 副音 side.
    if (pendingStep && !mirrorStep) return BgMirrorAction.anchor;
    if (!lockOffsetReady) return BgMirrorAction.anchor;
    return BgMirrorAction.bgDrivesFg;
  }

  // A foreground-only jump is a user gesture: map it onto the 副音 queue.
  if (!lockOffsetReady) return BgMirrorAction.anchor;
  return BgMirrorAction.fgDrivesBg;
}

/// Whether an ARMED system-seek latch may be consumed on this sample.
///
/// The latch is armed when a system bg seek is ISSUED; it must only be
/// consumed once the native seek has actually LANDED — a bg jump observed on a
/// later sample, or the deadline fallback for a seek that lands on the same
/// position and never reports a jump. Consuming it earlier (on the first
/// sample after the bump, before the position updates) misread the landing as
/// a user jump and mirrored it onto the foreground — the "enabling 副音 skips
/// the episode" report.
bool shouldConsumeSystemSeekLatch({
  required bool armed,
  required bool bgJump,
  required bool deadlineExpired,
}) =>
    armed && (bgJump || deadlineExpired);

/// Whether a position sample represents a deliberate jump (seek) rather than
/// normal playback advance.
///
/// A backward move is always a seek; a forward move is a seek when it exceeds
/// what the elapsed wall time could have produced at [rate], plus a slack for
/// sampling jitter. A null [prevMs] is the first sample and never a jump.
bool isPositionJump({
  required int? prevMs,
  required int posMs,
  required int elapsedMs,
  required double rate,
}) {
  final prev = prevMs;
  if (prev == null) return false;
  if (posMs < prev) return true;
  final int safeElapsed = elapsedMs < 0 ? 0 : elapsedMs;
  final double effectiveRate = rate <= 0 ? 1.0 : rate;
  final double expected = safeElapsed * effectiveRate;
  final double advance = (posMs - prev).toDouble();
  return advance > expected + BackgroundSyncLogic.kJumpSlackMs;
}
