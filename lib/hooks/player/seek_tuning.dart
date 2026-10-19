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
/// The target is clamped into the media, but the delta must never drive the
/// engine *past* 0 or the duration — mpv otherwise seeks off the front of the
/// file and the position stream reports out-of-range (negative) samples, and
/// the progress write lands on the wrong side. Hence the anchor is clamped
/// before the delta is derived: a press at the very start that asks to rewind
/// three seconds emits 0, not -3000. [stepSeekTargetMs] clamps the same way, so
/// the nominal OSD target and the delta handed to the engine agree.
int stepSeekSentDelta({
  required int reportedMs,
  required int deltaMs,
  required int durationMs,
}) {
  final int bound = durationMs < 0 ? 0 : durationMs;
  final int anchor = reportedMs.clamp(0, bound);
  final int target = (anchor + deltaMs).clamp(0, bound);
  return target - anchor;
}

/// Last SEEKABLE millisecond of a single (non-VM) media of [durationMs].
///
/// The same "one ms short of the end" contract as `vmLastSeekableMs` (in
/// `vm_item.dart`): landing ON `durationMs` fires an instant `completed`, so a
/// step seek must be bounded by THIS, not the raw duration. Zero/unknown
/// durations yield 0.
int lastSeekableMs(int? durationMs) {
  final d = durationMs ?? 0;
  return d <= 0 ? 0 : d - 1;
}

