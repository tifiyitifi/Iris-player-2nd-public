/// Funnel-level playback-progress write protection.
///
/// Pure decision layer with zero project imports so BOTH the media-library
/// write funnel ([MediaNodeRepository.updatePlaybackProgress]) and the
/// player-side save helpers (playback_progress.dart, re-exported) share one
/// source of truth without a layering cycle.
///
/// Head-window guard thresholds: after an open, the player reports a small
/// head position (log: t=1 pos=533ms) for ~1-2s before the duration-arrival
/// resume seek lands. A save in that window must never clobber a large
/// stored progress (上集/下集时丢时不丢). The zero-write guard only stops an
/// exact 0 — a 533ms head sails through it, so this guard stops
/// small-positive heads over large stored positions instead.
const int headGuardStoredMinMs = 10000;
const int headGuardIncomingMaxMs = 3000;
const double headGuardIncomingRatio = 0.05;

/// Incoming-sample cap for a media of [durationMs]: the static cap narrowed
/// by a 5%-of-duration ratio for short files. Unknown duration (0) keeps the
/// static cap.
int headWriteCapMs(int durationMs) {
  final ratioCap = durationMs > 0
      ? (durationMs * headGuardIncomingRatio).floor()
      : headGuardIncomingMaxMs;
  return ratioCap < headGuardIncomingMaxMs
      ? ratioCap
      : headGuardIncomingMaxMs;
}

/// Pure decision for the head-window guard: true when [incomingPosMs] looks
/// like a pre-seek head sample (small) over a real stored progress (large).
/// Explicit finishes ([forceClear]) and user-initiated seeks back to the
/// head ([userSeekToHead]) always pass through.
bool shouldGuardHeadWrite({
  required int? existingPosMs,
  required int incomingPosMs,
  required int durationMs,
  bool forceClear = false,
  bool userSeekToHead = false,
}) {
  if (forceClear || userSeekToHead) return false;
  if (existingPosMs == null || existingPosMs < headGuardStoredMinMs) {
    return false;
  }
  if (durationMs <= 0) return false;
  return incomingPosMs < headWriteCapMs(durationMs);
}

/// Why a caller writes progress through the funnel. Only [live] samples
/// (periodic ticks, switch cleanup, save-on-pause) are value-guarded; every
/// other intent is an explicit user/controller decision that must land
/// verbatim.
enum ProgressWriteIntent {
  /// Ordinary live playback sample — guarded against head-sample clobbers.
  live,

  /// The user deliberately seeked (possibly back to the head) — verbatim.
  userSeek,

  /// An explicit controller decision to clear/finish (completed:true,
  /// VM stop-to-first) — verbatim.
  explicitClear,

  /// A targeted landing decision (VM pre-write: jump target or sequential
  /// advance 0) — verbatim.
  targeted,

  /// Progress ownership was just taken over from another IRIS window that was
  /// playing the same file (see `MediaProgressClaim`). A live takeover write
  /// may only move the stored position FORWARD
  /// ([resolveTakeoverPositionMs]); an explicit rewind is declared as
  /// [userSeek] and stays verbatim.
  takeover,
}

/// Backward tolerance for a NATURAL ([ProgressWriteIntent.live]) write.
///
/// In the natural state a live sample must never LOWER the stored progress
/// (the "greater-than lock"): a report that jumps backward and then plays the
/// file from the head is the stored progress having been overwritten by a
/// stale/pre-seek position. Engine jitter and millisecond rounding are
/// absorbed by this tolerance; anything larger is treated as a regression and
/// dropped. Only explicit intents ([userSeek]/[explicitClear]/[targeted]) may
/// write a smaller value — that is the user's slider tap/drag, rewind, chapter
/// jump, VM sequential advance, or an explicit finish.
///
/// Matches the player hooks' position-sanitizer tolerance (`_sanePos`, 2s) so
/// the hook and the funnel agree on what counts as a glitch.
const int liveWriteBackwardToleranceMs = 2000;

/// Pure decision for the write funnel: true when a [ProgressWriteIntent.live]
/// write must be dropped.
///
/// Two compounding protections, both subsumed by the monotonic rule below:
///   * the 第8次 repro — a small pre-seek head sample (log: `pos=533ms`) over
///     a large stored progress (`42833`) — is now just the extreme case of a
///     regression;
///   * the general case — ANY live sample below `existing - tolerance`,
///     including a small stored row over which the old head-window guard did
///     nothing (它只保护 existing >= 10s).
///
/// Non-live intents and explicit finishes are never blocked; a null
/// [incomingPosMs] leaves the column untouched and never blocks. A stored
/// position that cannot apply to this media ([durationMs] known and smaller
/// than the stored value — e.g. the file was re-encoded shorter) is stale, not
/// a regression, so it must not permanently freeze writes.
bool shouldBlockFunnelWrite({
  required int? existingPosMs,
  required int? incomingPosMs,
  required int? durationMs,
  required bool? completed,
  required ProgressWriteIntent intent,
}) {
  if (intent != ProgressWriteIntent.live) return false;
  if (completed == true) return false;
  if (incomingPosMs == null) return false;
  if (existingPosMs == null || existingPosMs <= 0) return false;
  if (durationMs != null &&
      durationMs > 0 &&
      existingPosMs > durationMs) {
    return false;
  }
  return incomingPosMs < existingPosMs - liveWriteBackwardToleranceMs;
}

/// Resolves the position a [ProgressWriteIntent.takeover] write may store.
///
/// WHY: takeover exists so the newly-active window can flush the position it
/// kept while it was denied — but that live sample can be BEHIND the value the
/// previous owner stored (the waiting window played on from its own resume
/// point). A handover is not a rewind request: after the owner closed at 90%,
/// the waiting window's 10% tick must not overwrite 90%. Explicit intents
/// ([ProgressWriteIntent.userSeek] / [ProgressWriteIntent.explicitClear]) stay
/// verbatim so a deliberate rewind or finish still lands.
int? resolveTakeoverPositionMs({
  required int? existingPosMs,
  required int? incomingPosMs,
  required bool? completed,
  required ProgressWriteIntent intent,
}) {
  if (intent != ProgressWriteIntent.takeover) return incomingPosMs;
  if (completed == true || incomingPosMs == null) return incomingPosMs;
  if (existingPosMs == null || existingPosMs <= 0) return incomingPosMs;
  return incomingPosMs < existingPosMs ? existingPosMs : incomingPosMs;
}
