/// Shared media-tail seek policy.
///
/// Every seek path used to carry its own idea of "the end": the ring dial
/// stopped at `duration - 100 ms`, a step seek at `duration - 1 ms`, the shared
/// absolute clamp allowed landing exactly ON `duration`, resume at
/// `duration - 5000 ms`. Those are not flavours of one rule — they are separate
/// behaviours that disagree by up to 5 s, and the 1 ms one is a rounding error,
/// not a guard.
///
/// Root cause of the "fast-forward at the tail rolls the time back" report:
/// `duration` is the CONTAINER duration, so the last decodable frame sits at
/// `duration - lastFrameDuration` and the last key frame usually one whole GOP
/// earlier. A target of `duration - 1 ms` is therefore still inside the final
/// GOP (often already past the last frame): the engine cannot land there, it
/// clamps to whatever it can decode, and the position snaps backwards.
///
/// This module holds the one guard both layers share.
library;

/// Distance kept between a seek landing and the media end.
///
/// 100 ms is the value the ring dial's `endGuardMs` already used: larger than a
/// typical frame duration (25 fps = 40 ms, 30 fps = 33 ms, so the landing stays
/// on the LAST frame instead of falling off it) and far smaller than the
/// shortest useful seek step, so a tail landing still plays the final moment
/// and completes naturally.
const int kSeekTailGuardMs = 100;

/// Fraction of the media at which a scrub RELEASE counts as "finish this item".
///
/// A drag that merely touches the end must not advance (the user may drag back);
/// releasing there is the explicit intent. Shared by the linear slider and the
/// circle slider so both agree.
const double kSeekReleaseFinishFraction = 0.99;

/// What the caller wants to happen at the media end.
///
/// mpv splits these two intents with `--keep-open` (`player/playloop.c`): reaching
/// EOF and moving to the next playlist entry are separate decisions. IRIS has no
/// such switch, so every caller states the intent instead of the difference being
/// encoded as an accidental 1 ms / 100 ms offset in scattered places.
enum SeekIntent {
  /// Stop short of the tail (drag residency, jump dialog, a step press that is
  /// NOT at the end). The landing can never raise `completed`.
  ///
  /// A step press that DOES reach the end is not a `stopAtTail` caller: while
  /// playing it is a tail finish (`decideStepTail` in
  /// `hooks/player/seek_tuning.dart` — the ordinary relative keyframe seek plus
  /// mpv's EOF collapse) and while paused it is swallowed.
  stopAtTail,

  /// Land on the end (release at 100%): the user explicitly finished this
  /// item, so `completed` fires and playback advances. Single absolute seek —
  /// the engine can honour it exactly once, so there is nothing to collapse.
  ///
  /// A tail STEP is NOT a caller any more: mpv answers it with the ordinary
  /// relative keyframe seek plus the playloop's EOF collapse (see
  /// `MpvSeekTailState` in `hooks/player/seek_tuning.dart`).
  finishAtEnd,
}

/// Highest reachable seek target (ms) for a media of [durationMs].
///
/// A zero/unknown duration yields 0: callers drop such seeks before clamping
/// (a fabricated target would be written over the file's saved progress).
int seekTailMaxMs(
  int durationMs, {
  SeekIntent intent = SeekIntent.stopAtTail,
}) {
  if (durationMs <= 0) return 0;
  if (intent == SeekIntent.finishAtEnd) return durationMs;
  // A clip no longer than the guard has no room to keep a 100 ms tail: the
  // naive `duration - guard` would collapse to 0 and pin every stopAtTail seek
  // to the head (a 50 ms clip became unseekable). Short media therefore keeps
  // its full reachable range; the landing is the last decodable frame anyway.
  if (durationMs <= kSeekTailGuardMs) return durationMs;
  return durationMs - kSeekTailGuardMs;
}

/// Clamps a seek target (ms) into `[0, seekTailMaxMs(durationMs)]`.
int clampSeekTargetMs(
  int targetMs,
  int durationMs, {
  SeekIntent intent = SeekIntent.stopAtTail,
}) {
  if (targetMs <= 0) return 0;
  if (durationMs <= 0) return targetMs;
  final int maxMs = seekTailMaxMs(durationMs, intent: intent);
  return targetMs > maxMs ? maxMs : targetMs;
}

/// Whether a scrub release at [rawMs] means "finish this item".
///
/// [rawMs] is the UNCLAMPED drag value: the live ticks stop [kSeekTailGuardMs]
/// short of the end, so only the raw value can tell a release at the end from one
/// that was merely clamped there.
///
/// The threshold is the 99% fraction EXCEPT for a clip no longer than twice the
/// guard: there the clamp itself already sits well below 99%, so any release
/// past the reachable tail counts as "finish". Without that, a 150 ms clip would
/// accept only >= 99% as finish and snap every other release in the final third
/// back to `duration - 100 ms` — a visible jump backwards of a third of the
/// clip. Normal-length media keep the historical 99% rule.
bool isSeekReleaseFinish(int rawMs, int durationMs) {
  if (durationMs <= 0) return false;
  if (rawMs <= 0) return false;
  if (durationMs <= 2 * kSeekTailGuardMs) {
    return rawMs >= seekTailMaxMs(durationMs);
  }
  return rawMs >= durationMs * kSeekReleaseFinishFraction;
}

/// Seek intent for a Virtual-Media drag release.
///
/// The merged item's total is the caller axis: the same 99% / short-media rule
/// decides whether the release is the explicit "finish this item". Without it a
/// VM release at 100% stayed `stopAtTail` and was clamped `segDur - guard`, so
/// the linear bar could never advance while the circle slider did.
SeekIntent vmReleaseSeekIntent(int rawMs, int virtualTotalMs) =>
    isSeekReleaseFinish(rawMs, virtualTotalMs)
        ? SeekIntent.finishAtEnd
        : SeekIntent.stopAtTail;
