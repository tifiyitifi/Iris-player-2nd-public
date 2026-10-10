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
/// The position-lock intent (`resolveRelativeBaseMs`) cannot anchor a step
/// burst on its own: the lock unlocks as soon as one sample lands within its
/// ±2s tolerance (`isLandingAt`), and there are further fail-open
/// `unlock()` paths (open error, lock timeout). Once unlocked the step base
/// falls back to the REPORTED position — which does not advance while a seek
/// is still decoding toward its target, so consecutive presses would recompute
/// the same target and N presses would advance one step.
///
/// `hr-seek=no` used to widen that window dramatically (the engine parked on
/// the keyframe before the target, so the reported position never moved; see
/// [kStepBurstRelaxesPreciseSeek], now off). The accumulation remains necessary
/// either way: it is what keeps a press that [StepSeekChain] has not issued yet
/// from being lost, and what makes a held key advance exactly one step per
/// press.
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

  /// Drops the accumulation (absolute seek / media change / backend reset).
  void reset() => _lastMs = null;

  /// Base position the next relative step must add its delta to:
  /// step intent → position-lock intent → reported position. The last two
  /// are the [resolveRelativeBaseMs] fallback chain, which only covers a
  /// seek that is still IN FLIGHT — hence the step intent above it.
  int baseFor({required int reportedMs, required int? lockIntentMs}) =>
      _lastMs ??
      resolveRelativeBaseMs(reportedMs: reportedMs, pendingIntentMs: lockIntentMs);
}

/// Trailing window that collapses a user-seek progress-write burst into the
/// leading target (written immediately) plus one trailing write.
const Duration kUserSeekWriteDebounce = Duration(milliseconds: 350);

/// Idle window that ends a rapid step burst (a press arriving inside it keeps
/// the burst alive).
const Duration kStepBurstWindow = Duration(milliseconds: 400);

/// Landing tolerance for a step seek: the position stream may report a little
/// past the target (the decoder/playback advanced before the sample was taken).
/// The smallest step the UI can produce is 1s, so a 400ms window can never
/// mistake the PREVIOUS step's position for the current target.
const int kStepLandingToleranceMs = 400;

/// How long a landed step frame is shown before the next queued step seek is
/// issued. Without it the next seek freezes the picture within a frame or two,
/// and the user never actually perceives the intermediate position.
/// Measured on 4K: the ~330ms precise seek dwarfs this dwell; ~60ms buys
/// roughly 10% more paints/s, raising it makes each step easier to see.
const Duration kStepLandedDwell = Duration(milliseconds: 90);

/// Escape hatch for a step seek whose landing is never observed (stalled
/// decode, position-stream hiccup): the chain must not wedge.
/// Never fired in the measured 205 landings (the position stream always
/// reported the landing well inside it) — pure insurance.
const Duration kStepSeekHardTimeout = Duration(milliseconds: 1200);

/// Pending targets a [StepSeekChain] keeps while one seek is in flight. The
/// input can outpace the painter (a held key repeats ~30/s; a precise 4K seek
/// takes hundreds of ms), so the OLDEST pending target is dropped first and the
/// picture keeps advancing through the freshest ones.
/// Measured: at ~5 presses/s on 4K the queue sits at this cap and dropped 10 of
/// 216 presses; at <=3 presses/s nothing is dropped. Raising it honours more
/// presses and grows the post-release trailing walk by ~330ms per extra step.
const int kStepChainMaxPending = 3;

/// Whether a position report satisfies a step seek heading to [targetMs].
/// A forward step is satisfied by anything at/past the target (playback simply
/// continued after landing), a backward step by anything at/before it.
bool isStepLanded({
  required int posMs,
  required int targetMs,
  required bool forward,
}) {
  const int tol = kStepLandingToleranceMs;
  return forward ? posMs >= targetMs - tol : posMs <= targetMs + tol;
}

/// Dwell before the next queued step is issued, given how many targets wait.
///
/// The landed-frame dwell only exists so a LONE step's frame is actually
/// perceived before the next seek freezes the picture. While a backlog is
/// waiting the eye is already chasing, so the dwell is dropped and the queue is
/// pumped as fast as the engine reports each landing (adaptive mode). The
/// original serialized mode keeps the constant dwell (see [StepSeekChain]).
Duration stepLandingDwell(int pendingCount) =>
    pendingCount == 0 ? kStepLandedDwell : Duration.zero;

/// Monotonic display guard for a precise step burst.
///
/// While a ←/→ press is heading to [targetMs] the engine reports PRE-LAND
/// samples (the previous frame / keyframe) before the target arrives. The
/// position sanitizer historically bypassed itself for any user seek
/// (`userSeeked`), so those samples leaked to the UI as a visible rewind (回退
/// 时间) and to the DB. This holds the shown position until the engine reports
/// at/after the last shown value in the burst direction.
///
/// Released by the caller as soon as [isStepLanded] fires (playback may then
/// legitimately continue past the target); a direction flip must reset
/// [lastShown] to null so the reversal is not pinned.
int saneStepBurstPos({
  required int raw,
  required int? lastShown,
  required bool forward,
  required int durationMs,
}) {
  final int clamped = durationMs > 0 ? raw.clamp(0, durationMs) : raw;
  final int? shown = lastShown;
  if (shown == null) return clamped;
  if (forward && clamped < shown) return shown;
  if (!forward && clamped > shown) return shown;
  return clamped;
}

/// One queued step seek.
///
/// [targetMs] is the caller's axis (virtual while a VM session is active) and
/// is what the caller re-enters `seek()` with; [engineTargetMs] is the
/// segment-local/absolute position the engine was actually told, which is what
/// the landing check compares against the raw position stream.
typedef StepSeekRequest = ({int targetMs, int engineTargetMs, bool forward});

/// One-at-a-time step-seek chain for ← / → (keyboard / double-tap) bursts.
///
/// WHY (2026-09-29): mpv keeps only the NEWEST seek target while a seek is in
/// flight, so a fixed-cadence burst painted nothing but the last target — the
/// picture sat on the previous frame and then jumped straight to the final
/// position ("+3+6+9+12 中间的没显示"). A cadence throttle cannot fix that: the
/// next request just supersedes the one that was still decoding. Instead this
/// chain issues exactly ONE engine seek at a time and releases the next one
/// only after the previous target was OBSERVED in the position stream (or
/// [hardTimeout] elapsed), so every issued step really does land — and paint —
/// in order.
///
/// MEASURED (2026-09-29, local 4K H.264 `sodeno19-…-2160p.mp4`, media_kit +
/// libmpv, `hwdec-current=d3d11va-copy`): ONE precise step seek costs ~330ms
/// and a rapid burst arrives at ~5 presses/s, so at most ~3 steps/s can be
/// painted. The queue therefore saturates and drops its OLDEST target: 216
/// presses -> 206 issued -> 205 landed (95% of presses got their own frame).
/// On lighter content the same gesture painted 5-6 steps/s and the queue never
/// reached its cap, i.e. nothing was dropped.
///
/// The residual ~330ms is NOT a software-decode fallback (mpv is already on a
/// hardware decoder): it is copy-back frame download + demux repositioning +
/// audio-output restart + presenting the target frame on the audio clock.
/// Recorded so this is not re-litigated:
///  * forcing `hwdec=d3d11va` (zero-copy) for speed is not worth it — this
///    render path consumes system-memory frames, which is why mpv's `auto`
///    picked the copy variant; forcing it risks black/green video;
///  * `hr-seek=no` (see [kStepBurstRelaxesPreciseSeek]) is only faster because
///    it lands on the PREVIOUS keyframe — the 回跳重播 defect;
///  * the remaining knobs are [kStepLandedDwell] (paint rate) and
///    [kStepChainMaxPending] (completeness vs a longer trailing walk).
///
/// Pure clock-injected logic: unit-testable without a player.
class StepSeekChain {
  StepSeekChain({
    this.maxPending = kStepChainMaxPending,
    this.hardTimeout = kStepSeekHardTimeout,
  });

  /// How many targets may wait while one is in flight (see [kStepChainMaxPending]).
  final int maxPending;

  /// How long an unobserved in-flight target may block the chain.
  final Duration hardTimeout;

  /// While true the OLDEST pending target is dropped once the queue exceeds
  /// [maxPending] (the original serialized behaviour: keep the freshest
  /// targets). Set false in adaptive mode so NO press is swallowed — the queue
  /// drains in order after the burst.
  bool dropOldest = true;

  final List<StepSeekRequest> _pending = <StepSeekRequest>[];
  StepSeekRequest? _inFlight;
  DateTime? _inFlightSince;

  int? get inFlightMs => _inFlight?.targetMs;
  bool get hasInFlight => _inFlight != null;
  int get pendingCount => _pending.length;
  bool get isEmpty => _inFlight == null && _pending.isEmpty;

  /// Wall-clock instant the in-flight target was handed to the engine, or null
  /// when nothing is in flight — lets the caller report issue->landed latency.
  DateTime? get inFlightSince => _inFlightSince;

  /// Records a requested step target. When [dropOldest] is true and the queue is
  /// already full the OLDEST pending target is dropped: the input is outpacing
  /// the painter, and the freshest targets are the ones worth painting. When
  /// [dropOldest] is false nothing is dropped (no press is swallowed).
  void push(int targetMs,
      {required int engineTargetMs, required bool forward}) {
    _pending.add(
      (targetMs: targetMs, engineTargetMs: engineTargetMs, forward: forward),
    );
    if (!dropOldest) return;
    while (_pending.length > maxPending) {
      _pending.removeAt(0);
    }
  }

  /// The request to hand to the engine now, or null while one is in flight (or
  /// nothing is queued).
  StepSeekRequest? takeNext(DateTime now) {
    if (_inFlight != null || _pending.isEmpty) return null;
    final StepSeekRequest next = _pending.removeAt(0);
    _inFlight = next;
    _inFlightSince = now;
    return next;
  }

  /// Reports an observed engine position; returns true when it satisfies the
  /// in-flight target (which is then cleared so [takeNext] can issue the next).
  bool notePosition(int posMs) {
    final StepSeekRequest? flight = _inFlight;
    if (flight == null) return false;
    if (!isStepLanded(
      posMs: posMs,
      targetMs: flight.engineTargetMs,
      forward: flight.forward,
    )) {
      return false;
    }
    _inFlight = null;
    _inFlightSince = null;
    return true;
  }

  /// Hard-timeout escape: drops an in-flight target whose landing was never
  /// observed. Returns true when it released one (the caller then pumps the
  /// next target).
  bool tickTimeout(DateTime now) {
    final DateTime? since = _inFlightSince;
    if (_inFlight == null || since == null) return false;
    if (now.difference(since) < hardTimeout) return false;
    _inFlight = null;
    _inFlightSince = null;
    return true;
  }

  /// Key/gesture release: collapse a held step burst to its FINAL target.
  ///
  /// WHY: a held ←/→ auto-repeats (~30/s) far faster than a precise seek lands
  /// (~330ms each), so in `dropOldest = false` (adaptive) mode the pending queue
  /// grows without bound. Without this the release would keep walking the whole
  /// backlog for tens of seconds ("松手不能停止"). Once the key is released the
  /// burst is over, so only the LAST pressed target still matters.
  ///
  /// Returns the target the caller must hand to the engine at once: mpv keeps
  /// only the newest seek target, so re-issuing it supersedes the in-flight seek
  /// and the chain lands exactly once more before normal playback resumes. The
  /// returned [StepSeekRequest.targetMs] is the same value `noteStepSeek` armed
  /// and the OSD reads, so the shown time matches the resting position.
  ///
  /// Null when nothing is newer than the in-flight target (or the chain is
  /// empty): the in-flight seek already is the release position and is left to
  /// land on its own.
  StepSeekRequest? collapseOnRelease() {
    if (_pending.isEmpty) return null;
    final StepSeekRequest finalTarget = _pending.last;
    _pending
      ..clear()
      ..add(finalTarget);
    // The in-flight (older) seek is superseded by the re-issue, so its landing
    // expectation is dropped with it.
    _inFlight = null;
    _inFlightSince = null;
    return finalTarget;
  }

  void reset() {
    _pending.clear();
    _inFlight = null;
    _inFlightSince = null;
  }
}

/// Whether a step burst may relax mpv's seek precision (`hr-seek=no`).
///
/// DISABLED (2026-09-29). An inexact seek lands on the keyframe BEFORE the
/// target, so a held / continuously re-tapped ←/→ re-showed the same GOP from
/// its keyframe instead of advancing the progress: the picture "played a
/// little, then jumped back" (回跳重播). [StepSeekChain] plus
/// `hr-seek-framedrop=yes` already solve the original "frozen, then one big
/// jump" symptom, so the toggle is kept in place — gated by this constant for
/// an easy A/B rollback — but never fires.
///
/// Flip to `true` only to reproduce/measure the old keyframe-seek behaviour;
/// doing so re-introduces the settle's "restore `hr-seek=yes` before the seek"
/// ordering race.
const bool kStepBurstRelaxesPreciseSeek = false;

/// Rapid-step burst detector for keyboard / double-tap fast-forward & rewind.
///
/// A single deliberate press stays on the default (exact) seek path. Once a
/// SECOND step lands within [window] the burst counts as "rapid": the caller
/// then knows the idle settle must hand over to [StepSeekChain] (which lands
/// every requested step in order) instead of trusting the per-press cadence.
///
/// Pure clock-injected logic: unit-testable without a player.
class StepBurst {
  StepBurst({this.window = kStepBurstWindow});

  final Duration window;

  DateTime? _lastAt;
  bool _rapid = false;

  bool get isRapid => _rapid;

  /// Records a step at [now]; returns true once the burst counts as rapid.
  bool note(DateTime now) {
    final DateTime? last = _lastAt;
    _lastAt = now;
    if (last != null && now.difference(last) < window) _rapid = true;
    return _rapid;
  }

  void reset() {
    _lastAt = null;
    _rapid = false;
  }
}

/// Trailing-edge coalescer: keeps only the newest value of a burst.
///
/// Used for user-seek PROGRESS WRITES only — during a held-key / drag burst just
/// the first target (leading edge, persisted immediately for kill-safety) and
/// the last one (trailing flush) reach the UI-isolate Drift.
///
/// Deliberately NOT applied to the seeks themselves: collapsing engine seeks
/// would make a held arrow key stand still and then jump once, instead of
/// advancing frame by frame.
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
