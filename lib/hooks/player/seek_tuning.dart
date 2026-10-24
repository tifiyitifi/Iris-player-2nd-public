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
/// Used by the fvp backend: it has no relative seek, so each press becomes an
/// ABSOLUTE seek (on the keyframe path — see `fvpStepUsesKeyframeSeek`) and the
/// engine does NOT coalesce presses the way mpv's `queue_seek` does. The class
/// therefore keeps the Dart side coherent across a burst: the OSD shows where
/// the burst is heading, and the progress write records the burst's target
/// instead of a pre-seek sample. (The media_kit backend instead hands mpv a
/// native relative keyframe seek — [stepSeekArgs] — and keeps no accumulator.)
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

  /// The most recently requested step target, in the caller's coordinate axis
  /// (segment-local while a VM session is active), or null when none/reset.
  int? get lastMs => _lastMs;

  /// Records the target a step seek is heading to.
  void note(int targetMs) => _lastMs = targetMs;

  /// Drops the accumulation (absolute seek / media change / burst end).
  void reset() => _lastMs = null;

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
  int baseFor({
    required int reportedMs,
    required int? lockIntentMs,
    bool active = true,
  }) =>
      (active ? _lastMs : null) ??
      resolveRelativeBaseMs(reportedMs: reportedMs, pendingIntentMs: lockIntentMs);
}

/// Trailing window that collapses a user-seek progress-write burst into the
/// leading target (written immediately) plus one trailing write.
const Duration kUserSeekWriteDebounce = Duration(milliseconds: 350);

/// Floor for the [StepTailFinishMode.window] threshold (ms).
///
/// 2 s — the same value the fvp backend already used for its own tail window
/// (`kFvpStepTailExactWindowMs`), and for the same reason: the container
/// duration overshoots the last decodable frame, and the last key frame sits up
/// to a whole GOP before that, so a target inside that gap is unreachable no
/// matter how small the step is. Short steps would otherwise leave the final
/// GOP unprotected (a 500 ms step can never reach the end of a 2 s GOP).
///
/// The EFFECTIVE window is additionally capped at half the media (see
/// [stepFinishesItem]): a window as long as the clip would put the finish
/// threshold at/below the head and finish the very first press.
const int kStepTailFinishWindowMs = 2000;

/// What a step press must do once the tail policy has been applied.
enum StepTailAction {
  /// Ordinary relative keyframe step — the mpv-parity path used everywhere
  /// except the tail ([stepSeekArgs] / [fvpStepUsesKeyframeSeek]).
  step,

  /// Finish this item: keep stepping FORWARD (the ordinary relative keyframe
  /// seek, exactly like any other press) and let the engine reach EOF, with
  /// mpv's collapse rule as the backstop ([MpvSeekTailState]): the first press
  /// arms the media, later presses are swallowed so a held key cannot keep
  /// deferring `handle_eof` (`player/playloop.c:1247-1250`), and if the engine
  /// has not raised `completed` within [kMpvSeekEofWindow] the press is
  /// collapsed to EOF and the queue advances.
  ///
  /// Only while PLAYING — a paused tail press is [hold].
  finishItem,

  /// Swallow the press (「暂停时保留」). While PAUSED the item must not advance,
  /// and the step itself cannot land either: the keyframe seek has no key frame
  /// after the target inside the final GOP, so it would only roll the picture
  /// back to that GOP's key frame and leave a bogus backward progress write.
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
/// [StepTailAction.finishItem], which is mpv's own tail handling (the ordinary
/// relative seek plus the playloop's EOF collapse, see [MpvSeekTailState]) —
/// NOT an absolute `seek <duration>`. That distinction is what fixes a held key:
/// the old per-repeat absolute seek kept `handle_eof()` deferring, so the
/// picture parked at the tail until the key was released.
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

/// The full tail-step policy for one press: step / finish / hold.
///
/// [playing] splits the two tail outcomes: while playing the item is finished
/// through the mpv-parity path — the ordinary relative keyframe seek, later
/// presses swallowed, and an EOF collapse when the engine does not report the
/// end within [kMpvSeekEofWindow] (see [MpvSeekTailState]); while paused the
/// press is held — nothing advances and nothing is written, because a paused
/// tail seek can only roll the picture back inside the final GOP.
StepTailAction decideStepTail({
  required int reportedMs,
  required int deltaMs,
  required int durationMs,
  required StepTailFinishMode mode,
  required bool playing,
}) {
  if (!stepFinishesItem(
    reportedMs: reportedMs,
    deltaMs: deltaMs,
    durationMs: durationMs,
    mode: mode,
  )) {
    return StepTailAction.step;
  }
  return playing ? StepTailAction.finishItem : StepTailAction.hold;
}


/// Idle window that ends a rapid step burst (a press arriving inside it keeps
/// the burst — and the [StepIntent] accumulation — alive).
const Duration kStepBurstWindow = Duration(milliseconds: 400);

/// How long a tail step waits for the engine to prove that EOF happened.
///
/// mpv's own window for one seek is `MPSEEK_FLAG_DELAY`'s 0.3 s
/// (`player/playloop.c:521-525`: "If the user seeks continuously (keeps arrow
/// key down) try to finish showing a frame from one location before doing
/// another seek"), and its EOF verdict after a seek past the end arrives on
/// the playback restart, i.e. within the same window. IRIS therefore gives the
/// engine exactly that long before applying the playloop's own collapse rule
/// ([MpvSeekTailState] / `playloop.c:1240-1243`).
const Duration kMpvSeekEofWindow = Duration(milliseconds: 300);

/// mpv-parity state for ONE media whose step has reached the tail.
///
/// IRIS used to turn a tail press into an absolute `seek <duration>` on EVERY
/// repeat. mpv never does that — `→` is `seek 5 relative+keyframes`
/// (`etc/input.conf:47`) and the raw target past the end is forwarded as-is —
/// and it is exactly this per-press absolute seek that broke the tail:
///
///  * `handle_eof()` returns while a seek is queued (`playloop.c:1247-1250`,
///    "if (mpctx->seek.type) return; // for proper keep-open operation"), so a
///    new seek on every repeat pushes EOF away forever;
///  * an in-flight A/V hr-seek past EOF must not be overwritten
///    (`playloop.c:530-535`: "we want it to determine that EOF actually
///    happened, instead of overwriting it with the new seek");
///  * continuous forward relative seeks that leave the streams at EOF are
///    dropped instead of repeated (`playloop.c:1240-1243`, "Continuous seeks
///    past EOF => treat as EOF instead of repeating seek").
///
/// This class is the Dart side of that state machine: the FIRST tail press
/// issues the ordinary relative keyframe seek and arms the media; every
/// further press is swallowed instead of queueing another seek (mpv drops the
/// queued one); and if the engine has not raised `completed` within
/// [kMpvSeekEofWindow] the caller collapses the press to EOF — the playloop's
/// own verdict, applied by IRIS because it owns the queue advance.
///
/// Clock-free: the caller owns the timer, so the semantics are unit-testable.
class MpvSeekTailState {
  int? _endMs;
  String? _mediaUri;
  bool _collapsed = false;

  /// Whether a tail press already owns this media's finish.
  bool get armed => _endMs != null;

  /// The media end the state is armed for, or null.
  int? get endMs => _endMs;

  /// The media the arm belongs to, or null.
  String? get armedUri => _mediaUri;

  /// Registers a tail press for [endMs] of [mediaUri].
  ///
  /// Returns true for the FIRST press of this media (the caller must issue the
  /// relative seek and arm the EOF window) and false for every later press
  /// (swallow it: mpv drops the queued seek instead of repeating it, whatever
  /// its target — `player/playloop.c:1240-1243`).
  ///
  /// The media identity is part of the arm because a finish MUST NOT survive
  /// the queue advance it triggers: mpv clears the queued seek inside
  /// `play_current_file` (`player/loadfile.c:1825-1826`), while IRIS's advance
  /// is async, so a press landing in that window used to re-arm with the
  /// PREVIOUS duration and collapse the entry that had just been opened
  /// (`.ai_knowledge/tmp/seeK/seekaftempvlog.txt`: first Evelyn's tail arm
  /// advanced to the next entry, then the same window's re-arm collapsed that
  /// entry before it ever played).
  bool armFirstPress(String mediaUri, int endMs) {
    if (_endMs != null) return false;
    _mediaUri = mediaUri;
    _endMs = endMs;
    _collapsed = false;
    return true;
  }

  /// Takes the one-shot EOF collapse for [mediaUri].
  ///
  /// Returns true at most once per armed media; false when nothing is armed,
  /// the collapse already ran (a second advance must never happen), or the arm
  /// belongs to a DIFFERENT media (the press that armed it was overtaken by the
  /// queue advance — mpv's `seek = {0}` equivalent).
  bool consumeCollapse({required String mediaUri}) {
    if (_endMs == null || _collapsed) return false;
    if (_mediaUri != mediaUri) return false;
    _collapsed = true;
    return true;
  }

  /// Drops the arm: media change, a seek away from the tail, a rewind, or a
  /// `completed` that already finished the item (repeat-one loops keep the
  /// same media, so the next press must be able to arm again).
  void reset() {
    _endMs = null;
    _mediaUri = null;
    _collapsed = false;
  }
}

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

/// Engine-anchored target position (ms) for one step press.
///
/// The media_kit backend accumulates the presses itself ([stepSeekArgs]), so
/// the Dart side tracks only the nominal next land point for the OSD and the
/// progress write — anchored on the engine's last reported position instead of
/// a long-lived accumulator. That is what bounds the OSD / persisted value to a
/// single press even during a held burst, instead of drifting tens of seconds
/// behind the picture.
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
/// The tail press uses this same raw delta. A target that reaches the end is
/// first classified by [decideStepTail] (finish the item while playing / hold
/// the press while paused), but the seek it issues is still the ordinary
/// relative one — mpv forwards the past-the-end target too and only then
/// decides, on the playback restart, that EOF happened
/// (`player/playloop.c:530-535`, `1240-1243`; see [MpvSeekTailState]).
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
/// item, so the press teleports into an early segment and the armed EOF window
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

