import 'package:iris/models/enums/step_tail_finish_mode.dart';
import 'package:iris/utils/seek_tail_guard.dart';
import 'package:media_kit/media_kit.dart';

/// media_kit (mpv) seek / cache tuning.
///
/// media_kit overrides several mpv defaults with values that make precise
/// seeking visibly slower (see
/// `media_kit/lib/src/player/native/player/real.dart`):
///
///  * `hr-seek=yes` + `hr-seek-framedrop=no` — a precise seek DECODES AND
///    DISPLAYS every frame between the previous keyframe and the target. mpv's
///    own default is `hr-seek-framedrop=yes` (drop those frames), so this
///    single override is what turns a keyframe-distant seek into a visible
///    "catch-up"/lag on fast-forward / rewind.
///  * `demuxer-max-bytes` / `demuxer-max-back-bytes` pinned to
///    `PlayerConfiguration.bufferSize` (32MiB) — below mpv's upstream
///    150MiB/75MiB, so rewinding high-bitrate media re-demuxes constantly.
///
/// Re-assert the values after `Player` construction so both the frame drop and
/// the cache sizing are under IRIS's control (and user-tunable via the
/// `playback.videoCachePreset` meta-setting).
///
/// `hr-seek=yes` applies to ABSOLUTE seeks (scrub / dial / resume). A step seek
/// does NOT go through it: [stepSeekArgs] sets `keyframes` explicitly, which
/// short-circuits mpv's `hr-seek` selection and keeps the step fast.
Future<void> applyMpvSeekTuning(
  NativePlayer player, {
  required int cacheMaxBytes,
  required int cacheBackBytes,
}) async {
  // mpv requires the backward cache to be <= the forward one.
  final int back =
      cacheBackBytes > cacheMaxBytes ? cacheMaxBytes : cacheBackBytes;
  try {
    await player.setProperty('hr-seek', 'yes');
    await player.setProperty('hr-seek-framedrop', 'yes');
    await player.setProperty('demuxer-max-bytes', '$cacheMaxBytes');
    await player.setProperty('demuxer-max-back-bytes', '$back');
  } catch (_) {
    // A backend without these properties keeps mpv's own defaults; seeking
    // must never break because tuning failed.
  }
}

/// Base position (ms) a RELATIVE step must add its delta to, while no step
/// accumulation is in flight — see [StepIntent], which layers the step
/// intent on top of this fallback.
///
/// While a user seek is still in flight the reported position lags the intent
/// (mpv is still decoding toward the target), so chaining `+N` onto it drifts
/// backwards — a held arrow key would then advance by less than one step per
/// press, or by nothing at all. When an intent target is armed, accumulate onto
/// that so every press lands exactly one step further.
int resolveRelativeBaseMs({
  required int reportedMs,
  required int? pendingIntentMs,
}) =>
    pendingIntentMs ?? reportedMs;

/// Lock-independent accumulator for relative STEP seeks (← / → fast-forward).
///
/// Used by BOTH player hooks, for two different reasons:
///
///  * fvp has no relative seek, so each press becomes an ABSOLUTE seek (on the
///    keyframe path — see `fvpStepUsesKeyframeSeek`) and the engine does NOT
///    coalesce presses the way mpv's `queue_seek` does. The accumulator keeps
///    the burst coherent: the OSD shows where it is heading and every press
///    lands one step further.
///  * media_kit hands mpv a native relative keyframe seek ([stepSeekArgs]) and
///    lets the ENGINE accumulate the delta (`queue_seek`), but the tail
///    decision still needs the same sum: `time-pos` only reports an executed
///    seek, so a rapid burst would otherwise be judged against a stale
///    position and the press that crosses the end would be missed. The
///    accumulator here mirrors mpv's sum for [decideStepTail] only — the seek
///    itself is still handed to mpv unchanged.
///
/// The position-lock intent (`resolveRelativeBaseMs`) cannot anchor a step
/// burst on its own: the lock unlocks as soon as one sample lands within its
/// ±2s tolerance, and there are further fail-open `unlock()` paths (open error,
/// lock timeout). Once unlocked the step base falls back to the REPORTED
/// position — which does not advance while a seek is still decoding toward its
/// target, so consecutive presses would recompute the same target and N presses
/// would advance one step.
///
/// Recording the last requested target here keeps the accumulation alive for
/// the whole burst, independent of the lock's phase and of what the engine
/// reports. Callers reset it when the base axis changes (absolute seek,
/// media change) so the next step re-anchors on the fresh position.
///
/// Pure clock-free logic: unit-testable without a player.
class StepIntent {
  int? _lastMs;

  /// Sign of the press that recorded [_lastMs] (+1 forward, -1 backward, 0 when
  /// the caller did not say). A press in the OPPOSITE direction re-anchors on
  /// the picture instead of chaining onto this target: the recorded target is
  /// the sum of a burst in ONE direction, and chaining a reversal onto it would
  /// teleport the picture (burst forward to 400 s, press ← → 5 s).
  int _direction = 0;

  /// The most recently requested step target, in the caller's coordinate axis
  /// (segment-local while a VM session is active), or null when none/reset.
  int? get lastMs => _lastMs;

  /// Records the target a step seek is heading to.
  ///
  /// [deltaMs] is the signed press that produced it; omit it when the caller
  /// only knows the absolute landing (the direction is then kept as-is).
  void note(int targetMs, {int? deltaMs}) {
    _lastMs = targetMs;
    if (deltaMs != null && deltaMs != 0) {
      _direction = deltaMs > 0 ? 1 : -1;
    }
  }

  /// Drops the accumulation (absolute seek / media change / burst end).
  void reset() {
    _lastMs = null;
    _direction = 0;
  }

  /// Base position the next relative step must add its delta to:
  /// step intent → position-lock intent → reported position. The last two
  /// are the [resolveRelativeBaseMs] fallback chain, which only covers a
  /// seek that is still IN FLIGHT — hence the step intent above it.
  ///
  /// [active] is the caller's answer to "is a step burst still in flight" (a
  /// press inside [kStepBurstWindow]). The accumulation exists only to keep
  /// presses from being lost while the engine catches up; once the burst is
  /// over the recorded target is STALE — the engine has kept playing past it —
  /// and anchoring the next press on it would jump backwards (e.g. burst to
  /// 350s, play to 400s, next +10s lands at 360s instead of 410s). So an
  /// inactive burst ignores [_lastMs] and re-anchors on the live position.
  ///
  /// [deltaMs] does two things:
  ///
  ///  * a press that REVERSES the recorded burst direction re-anchors on the
  ///    picture (the sum belongs to the other direction);
  ///  * the base is then kept on the side the press travels to — forward takes
  ///    the larger of intent and live position, backward the smaller. The
  ///    accumulator alone is NOT safe, because a keyframe seek lands on the
  ///    NEXT key frame: the picture runs AHEAD of the nominal sum, so a tail
  ///    press judged against the sum would ask to land BEHIND the current
  ///    frame. That was the field "the tail jumps back and forth": on a
  ///    974 271 ms file the accumulator said 962 017 ms while the engine was
  ///    already at 974 271 ms, so the exact tail step seeked BACK to 966 017 ms
  ///    (an 8.2 s rewind) and the burst had to climb forward again. mpv has the
  ///    same rule implicitly — `queue_seek` adds the amount to
  ///    `get_current_time()`, so a forward `→` never resolves behind the
  ///    current frame.
  int baseFor({
    required int reportedMs,
    required int? lockIntentMs,
    required int deltaMs,
    bool active = true,
  }) {
    final int fallback =
        resolveRelativeBaseMs(reportedMs: reportedMs, pendingIntentMs: lockIntentMs);
    final int? intent = active ? _lastMs : null;
    if (intent == null) return fallback;
    if (deltaMs == 0) return fallback;
    if (_direction != 0 && _direction != (deltaMs > 0 ? 1 : -1)) {
      return fallback;
    }
    if (deltaMs > 0) return intent > fallback ? intent : fallback;
    return intent < fallback ? intent : fallback;
  }
}

/// Trailing window that collapses a user-seek progress-write burst into the
/// leading target (written immediately) plus one trailing write.
const Duration kUserSeekWriteDebounce = Duration(milliseconds: 350);

/// Floor for the [StepTailFinishMode.window] threshold (ms).
///
/// 2 s — the container duration overshoots the last decodable frame, and the
/// last key frame sits up to a whole GOP before that, so a target inside that
/// gap is unreachable no matter how small the step is. Short steps would
/// otherwise leave the final GOP unprotected (a 500 ms step can never reach the
/// end of a 2 s GOP).
///
/// The EFFECTIVE window is additionally capped at half the media (see
/// [stepFinishesItem]): a window as long as the clip would put the finish
/// threshold at/below the head and finish the very first press.
const int kStepTailFinishWindowMs = 2000;

/// Floor for the EXACT-seek window (ms) — see [stepNeedsExactSeek].
///
/// 10 s is the default x264/ffmpeg keyframe interval (`keyint=250`; at 25 fps
/// that is one GOP of 10 s), i.e. the largest "final GOP" an ordinary encode
/// puts between the last key frame and the container duration. Inside that
/// window a relative keyframe seek cannot land where it asked.
const int kStepTailExactWindowMs = 10000;

/// What a step press must do once the tail policy has been applied.
enum StepTailAction {
  /// Ordinary relative keyframe step — the mpv-parity path used everywhere
  /// except the tail ([stepSeekArgs] / [fvpStepUsesKeyframeSeek]).
  step,

  /// The target is still INSIDE the media but lies in the final GOP, where a
  /// keyframe seek cannot land (the demuxer answers with the last key frame —
  /// the visible rollback). The press therefore takes the EXACT path instead
  /// (`hr-seek=yes` on media_kit, `seekTo` on fvp) and stays a step: the item
  /// is not finished yet.
  exactStep,

  /// Finish this item NOW: the caller advances the queue without seeking.
  ///
  /// mpv reaches the same outcome through its playlist: a past-EOF seek ends
  /// the entry (`handle_eof` / `playloop.c:1247-1250`) and the next playlist
  /// entry is loaded in the same instance. media_kit always has a single-entry
  /// playlist and `--keep-open=yes` only holds the LAST entry
  /// (`DOCS/man/options.rst`), so EOF there only pauses and the host owns the
  /// advance. Sending a past-EOF seek first is what used to park the picture on
  /// the last key frame and delay the queue by an invented EOF window.
  ///
  /// Only while PLAYING — a paused tail press is [hold].
  finishItem,

  /// Swallow the press (「暂停时保留」). While PAUSED the item must not advance,
  /// and a keyframe step cannot land either: it would only roll the picture
  /// back to the final GOP's key frame and leave a bogus backward progress
  /// write.
  hold,
}

/// Whether a FORWARD step press means "finish this item" (see [StepTailAction]).
///
/// The threshold is decided in Dart because the engine cannot express it: mpv's
/// relative `keyframes` seek resolves the target to a decodable key frame, and
/// the final GOP has none at/after the target. Measured on a 322.293 s
/// container with a 4 s step, the tail presses kept the position between
/// 321.336 s and 321.736 s — rolling back between presses — and never raised
/// `completed`, so the queue never advanced.
///
/// This predicate only says WHEN the tail is reached; the action it maps to is
/// [StepTailAction.finishItem] — the caller advances the queue WITHOUT seeking.
/// Sending a seek first is what used to park the picture on the last key frame
/// and delay the advance by a made-up EOF window.
///
/// [StepTailFinishMode.strict] (default) finishes a target that REACHES the
/// end (`anchor + delta >= duration`); [StepTailFinishMode.window] also
/// finishes a target inside `max(delta, kStepTailFinishWindowMs)` of the end,
/// which covers the unreachable final GOP. "Reaches" (not "passes") is
/// deliberate: `target == duration` is exactly as unreachable through a
/// relative keyframe seek as a target past it — the engine rolls back into the
/// final GOP — so that press must finish instead of parking the decoder one
/// press short of the end. Backward presses and an unknown duration are never a
/// finish. [reportedMs] is clamped into the media first, so a stale
/// out-of-range sample cannot turn a rewind into a finish.
///
/// The window is capped at half the media: the finish threshold must stay
/// above the head, otherwise the FIRST press (target = delta from 0) of a clip
/// no longer than the window finishes the item and the clip cannot be stepped
/// at all (a 1.5 s clip with a 0.5 s step did exactly that). With the cap, a
/// step smaller than half the media always steps from the head.
bool stepFinishesItem({
  required int reportedMs,
  required int deltaMs,
  required int durationMs,
  required StepTailFinishMode mode,
}) {
  if (deltaMs <= 0 || durationMs <= 0) return false;
  final int anchor = reportedMs.clamp(0, durationMs);
  final int target = anchor + deltaMs;
  switch (mode) {
    case StepTailFinishMode.strict:
      return target >= durationMs;
    case StepTailFinishMode.window:
      final int floor =
          deltaMs > kStepTailFinishWindowMs ? deltaMs : kStepTailFinishWindowMs;
      final int window = floor * 2 > durationMs ? durationMs ~/ 2 : floor;
      return target >= durationMs - window;
  }
}

/// The exact-seek window (ms) for a media of [durationMs] at [deltaMs].
///
/// `max(|step|, kStepTailExactWindowMs)` capped at half the media: the floor
/// covers the default encode's final GOP, one step covers "this press reaches
/// the end", and the half-media cap keeps a short clip steppable from its head
/// (the same reason [stepFinishesItem] caps its own window).
int stepTailExactWindowMs({required int durationMs, required int deltaMs}) {
  if (durationMs <= 0) return 0;
  final int step = deltaMs < 0 ? -deltaMs : deltaMs;
  final int floor = step > kStepTailExactWindowMs ? step : kStepTailExactWindowMs;
  return floor * 2 > durationMs ? durationMs ~/ 2 : floor;
}

/// Whether a STEP seek must take the EXACT path because its target lies inside
/// the media's final GOP.
///
/// A relative keyframe seek can only land on a key frame. The LAST key frame
/// usually sits a whole GOP before the container duration, and a forward target
/// past it makes the engine answer with that last key frame — the visible
/// "step at the tail rolls the picture back", which is also why a strict
/// `target >= duration` predicate can never be satisfied after such a landing:
/// every further press re-anchors on the rolled-back position and lands there
/// again.
///
/// mpv documents the same limitation (`etc/input.conf`: "Seek units are in
/// seconds, but note that these are limited by keyframes") and only steps
/// exactly through an explicit `exact` flag. IRIS applies it automatically
/// inside the tail window so a press lands where it asked; outside the window
/// the ordinary native keyframe step is untouched.
///
/// Direction-agnostic on purpose: the fvp backend already judged backward
/// steps by distance, and an exact landing is never wrong there — only
/// slightly slower. [decideStepTail] asks for it on forward presses only.
bool stepNeedsExactSeek({
  required int targetMs,
  required int durationMs,
  required int deltaMs,
}) {
  if (durationMs <= 0 || deltaMs == 0) return false;
  final int window =
      stepTailExactWindowMs(durationMs: durationMs, deltaMs: deltaMs);
  return targetMs >= durationMs - window;
}

/// Whether a media the tail step already finished has left its tail again, so
/// a later press may finish it a second time (repeat-one looped back to the
/// head, a scrub/jump dialog moved away, a Virtual-Media segment loop).
///
/// The finish is dispatched asynchronously and the hook keeps the SAME media
/// until the queue actually rebinds it, so a second press in that window used
/// to dispatch a SECOND finish. Field log: `finish now` twice for the same file
/// and the queue advanced twice (one episode skipped). The gate therefore holds
/// a per-media latch (`dropped (tail finished)`); this predicate releases it as
/// soon as the picture demonstrably sits outside the tail window again.
///
/// The window is the SHARED exact-seek window ([stepTailExactWindowMs]), i.e.
/// capped at half the media — a fixed 10 s made `duration - 10 s` negative for
/// a clip shorter than that, so `reportedMs < negative` was never true and a
/// finished 6 s clip could never be stepped or rewound again (the latch also
/// kept `gateStepPress` dropping every press).
///
/// An unknown duration keeps the latch: without a length there is no way to
/// tell "still at the tail", so the conservative answer is to leave it alone.
bool stepTailLatchReusable({
  required int reportedMs,
  required int durationMs,
}) {
  if (durationMs <= 0) return false;
  final int window = stepTailExactWindowMs(durationMs: durationMs, deltaMs: 0);
  return reportedMs < durationMs - window;
}

/// The full tail-step policy for one press: step / exact step / finish / hold.
///
/// The finish predicate ([stepFinishesItem]) is unchanged; the exact-seek
/// window is layered on top for presses that stay inside the media but cannot
/// be reached through a keyframe seek ([stepNeedsExactSeek]).
///
/// [playing] splits the two end-of-item outcomes: while playing the queue
/// advances immediately (`finishItem`); while paused the press is held —
/// nothing advances and nothing is written.
///
/// The finish predicate is tested FIRST, so "paused is held" only covers presses
/// that reach the end. A paused press that stays inside the media but lands in
/// the final-GOP window still returns [StepTailAction.exactStep] and really
/// seeks (see [stepNeedsExactSeek]) — the two windows overlap, the order decides.
StepTailAction decideStepTail({
  required int reportedMs,
  required int deltaMs,
  required int durationMs,
  required StepTailFinishMode mode,
  required bool playing,
}) {
  if (stepFinishesItem(
    reportedMs: reportedMs,
    deltaMs: deltaMs,
    durationMs: durationMs,
    mode: mode,
  )) {
    return playing ? StepTailAction.finishItem : StepTailAction.hold;
  }
  if (durationMs > 0 && deltaMs > 0) {
    final int anchor = reportedMs.clamp(0, durationMs);
    if (stepNeedsExactSeek(
      targetMs: anchor + deltaMs,
      durationMs: durationMs,
      deltaMs: deltaMs,
    )) {
      return StepTailAction.exactStep;
    }
  }
  return StepTailAction.step;
}

/// Idle window that ends a rapid step burst (a press arriving inside it keeps
/// the burst — and the [StepIntent] accumulation — alive).
const Duration kStepBurstWindow = Duration(milliseconds: 400);

/// mpv input arguments for ONE native RELATIVE keyframe step seek.
///
/// This is exactly what mpv's own ←/→ key bindings issue: `seek <delta>` is a
/// `relative` seek, and relative seeks default to `keyframes`
/// (`DOCS/man/input.rst`: "By default, keyframes is used for relative ...
/// while exact is used for absolute seeks"). Keyframe precision is why a step
/// costs about a frame decode instead of decoding every frame from the previous
/// keyframe up to an exact target, and it is why mpv's own stepping feels
/// instant. The explicit `keyframes` flag also short-circuits mpv's `--hr-seek`
/// choice (`player/playloop.c`: `seek.exact != MPSEEK_KEYFRAME`), so IRIS's
/// `hr-seek=yes` cannot turn a step back into a precise seek.
///
/// mpv coalesces a held-key burst itself: `queue_seek` sums the relative
/// amounts and `execute_queued_seek` paces the execution, so IRIS must NOT
/// serialize the presses in Dart.
///
/// The value is seconds with 4 decimals — the same shape media_kit uses for
/// `Player.seek` — so a fractional step (e.g. 0.5s) survives.
///
/// Pure so the argument shape is unit-testable.
List<String> stepSeekArgs(int deltaMs) => <String>[
      'seek',
      (deltaMs / 1000.0).toStringAsFixed(4),
      'relative+keyframes',
    ];

/// Trailing-edge coalescer: keeps only the newest value of a burst.
///
/// Used for user-seek PROGRESS WRITES only — during a held-key / drag burst just
/// the first target (leading edge, persisted immediately for kill-safety) and
/// the last one (trailing flush) reach the UI-isolate Drift.
///
/// Deliberately NOT applied to the seeks themselves: mpv coalesces relative
/// seeks natively, and collapsing on the Dart side would make a held arrow key
/// stand still and then jump once instead of advancing continuously.
class TrailingCoalescer<T> {
  T? _pending;

  bool get hasPending => _pending != null;

  void record(T value) => _pending = value;

  /// Takes the newest pending value and clears it. Null when nothing pending.
  T? flush() {
    final T? p = _pending;
    _pending = null;
    return p;
  }
}

/// Target position (ms) for one step press, anchored on the caller's base.
///
/// [reportedMs] is that base: the live position for a lone press, or the
/// [StepIntent] target while a burst is in flight. The media_kit backend lets
/// mpv accumulate the relative deltas itself ([stepSeekArgs]), so this is the
/// nominal landing the OSD may show — the engine's landing is still the
/// keyframe it can decode.
///
/// The anchor is clamped into [0, durationMs] FIRST, exactly like
/// [stepSeekSentDelta]: the reported position can sit outside the media (a
/// stale sample after the duration is revised down), and clamping only the sum
/// then made this a step off the delta actually handed to the engine — the OSD
/// and the progress write landed one press away from the picture.
///
/// Returns the requested landing clamped into [0, durationMs].
int stepSeekTargetMs({
  required int reportedMs,
  required int deltaMs,
  required int durationMs,
}) {
  final int bound = durationMs < 0 ? 0 : durationMs;
  final int anchor = reportedMs.clamp(0, bound);
  return (anchor + deltaMs).clamp(0, bound);
}

/// The SIGNED DELTA (ms) actually handed to mpv for one step press.
///
/// FORWARD is deliberately NOT clamped to the media end. mpv adds the raw delta
/// to `get_playback_time()` and never clamps the target itself
/// (`player/playloop.c`, `MPSEEK_RELATIVE`), so the press keeps its nominal
/// landing and the engine decides what it can decode.
///
/// Only an ordinary [StepTailAction.step] press reaches this helper: a target
/// that reaches the end is finished by [decideStepTail] without a seek, and a
/// target inside the final GOP takes the [StepTailAction.exactStep] path. The
/// raw delta is kept here for the mpv-parity case, where the engine owns the
/// landing.
///
/// Clamping here instead would pin the target to `duration - 1` — the rollback
/// one GOP earlier, and it can never raise `completed`.
///
/// BACKWARD stays bounded: mpv clamps only the base (inside
/// `get_playback_time()`), and a relative seek off the front makes the position
/// stream report out-of-range negative samples.
int stepSeekSentDelta({
  required int reportedMs,
  required int deltaMs,
  required int durationMs,
}) {
  // [durationMs] bounds the ANCHOR only: a stale sample past the media end must
  // not turn a rewind into a bigger one than the media can hold.
  final int anchorBound = durationMs < 0 ? 0 : durationMs;
  final int anchor = reportedMs.clamp(0, anchorBound);
  if (deltaMs >= 0) return deltaMs;
  return deltaMs < -anchor ? -anchor : deltaMs;
}

/// The landing a VM tail STEP must hand to the absolute-seek path: the CALLER
/// (merged) axis.
///
/// The step accumulator and the press's target are SEGMENT-LOCAL (see
/// [StepIntent]: "segment-local while a VM session is active"), while the
/// hook's `seek()` resolves its argument on the VIRTUAL timeline
/// (`item.locate`). The segment's virtual offset therefore has to be added
/// back. Passing the local ms straight through — as the fvp tail path did —
/// re-reads e.g. `5 500 ms` of the third segment as `5 500 ms` of the merged
/// item, so the press teleports into an early segment and the pending finish
/// is dropped by the resulting media change (the item never finishes).
///
/// Accountancy lives here so the coordinate contract is unit-testable without
/// a player. [baseMs] + [deltaMs] is clamped into the segment first (a stale
/// past-the-end sample must not overflow the segment), then offset.
int vmTailStepTargetMs({
  required int segmentOffsetMs,
  required int baseMs,
  required int deltaMs,
  required int segmentDurationMs,
}) {
  final int bound = segmentDurationMs < 0 ? 0 : segmentDurationMs;
  final int local = (baseMs + deltaMs).clamp(0, bound);
  return segmentOffsetMs + local;
}

/// Last SEEKABLE millisecond of a single (non-VM) media of [durationMs].
///
/// The shared `kSeekTailGuardMs` contract (see `utils/seek_tail_guard.dart`):
/// landing ON `durationMs` fires an instant `completed`, and landing 1 ms short
/// of it is no guard at all — `durationMs` is the container duration, so the
/// requested millisecond is usually past the last decodable frame. Zero/unknown
/// durations yield 0.
int lastSeekableMs(int? durationMs) {
  final d = durationMs ?? 0;
  return d <= 0 ? 0 : seekTailMaxMs(d);
}

