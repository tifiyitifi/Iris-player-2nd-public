import 'package:flutter_test/flutter_test.dart';
import 'package:iris/hooks/player/live_progress_attribution.dart';
import 'package:iris/hooks/player/seek_tuning.dart';
import 'package:iris/models/enums/step_tail_finish_mode.dart';

/// Regression test for the "a held step key skips an episode" defect.
///
/// The hooks cannot be exercised without a real engine, so the ORDERING of the
/// production path is reproduced here with the real decision helpers:
///
/// ```
/// seekRelative → shouldAcceptStepPress → decideStepTail → armFirstPress
///              → publish → armTailEofWindow → (300 ms) collapseTailStepToEof
///              → consumeCollapse(mediaUri) → dispatchItemFinished
/// ```
///
/// Every gate this harness models is load-bearing: removing one makes a real
/// episode get skipped in the field
/// (`.ai_knowledge/tmp/seeK/seekaftempvlog.txt`: Evelyn's tail finish advanced
/// the queue, then presses arriving before the next open completed re-armed
/// with Evelyn's duration and collapsed the new entry — `pos=311750ms
/// dur=312106ms` logged against a 644 928 ms file).
void main() {
  const int stepMs = 4000;
  const int eofWindowMs = 300;
  const String evelyn = 'file:///media/evelyn.mp4';
  const String nightParty = 'file:///media/night-party.mp4';

  group('step burst across a queue advance', () {
    late _StepHarness h;

    setUp(() {
      h = _StepHarness(
        fileUri: evelyn,
        openedUri: evelyn,
        durationMs: 312106,
        positionMs: 309550,
      );
    });

    test('a held key finishes the item ONCE and never skips the next one', () {
      // 1. The user holds → at the tail: the first press arms, the rest are
      //    swallowed (mpv drops the queued seek, `playloop.c:1240-1243`).
      for (int i = 0; i < 21; i++) {
        h.press(stepMs, nowMs: i * 10);
      }
      expect(h.seeks, 1, reason: 'only the first tail press may seek');
      expect(h.advances, 0, reason: 'the finish waits for the EOF window');

      // 2. The window expires: exactly one advance.
      h.tick(nowMs: eofWindowMs);
      expect(h.advances, 1);
      final int writesBeforeSwitch = h.progressWrites;

      // 3. The queue advanced; the next media's open is still in flight, so the
      //    hook still holds Evelyn's duration/position (the field log's shape).
      h.advanceQueueWillOpen(nextUri: nightParty);
      for (int i = 0; i < 20; i++) {
        h.press(stepMs, nowMs: eofWindowMs + 10 + i * 10);
      }
      expect(h.seeks, 1,
          reason: 'presses during the switch must not seek with stale state');
      expect(h.advances, 1, reason: 'the next episode must not be collapsed');
      expect(h.progressWrites, writesBeforeSwitch,
          reason: 'no progress write may be attributed across the switch');

      // 4. A stray timer from the switch window cannot fire either.
      h.tick(nowMs: eofWindowMs * 3);
      expect(h.advances, 1);

      // 5. Open completed: the burst continues on the NEW media, from its head.
      h.openCompleted(uri: nightParty, durationMs: 644928, positionMs: 0);
      h.press(stepMs, nowMs: 2000);
      expect(h.seeks, 2, reason: 'presses resume on the new media');
      expect(h.advances, 1);
      expect(h.lastSeekWasOn, nightParty);
    });

    test('presses during the advance dispatch are dropped too', () {
      // The narrow window between `finishedDispatchInFlight = true` and the
      // queue actually changing: `file`/`opened` still describe Evelyn.
      h.advancing = true;
      for (int i = 0; i < 5; i++) {
        h.press(stepMs, nowMs: i * 10);
      }
      expect(h.seeks, 0);
      expect(h.progressWrites, 0);
      expect(h.advances, 0);
    });

    test('an abandoned arm cannot collapse the entry that replaced it', () {
      // Defense in depth: even if a press slipped past the gate, the arm carries
      // the media it was raised for (mpv clears the queued seek at the switch,
      // `player/loadfile.c:1825-1826`).
      expect(h.tail.armFirstPress(evelyn, 312106), isTrue);
      h.advanceQueueWillOpen(nextUri: nightParty);
      h.tick(nowMs: eofWindowMs);
      expect(h.advances, 0);
      expect(h.tail.consumeCollapse(mediaUri: nightParty), isFalse);
    });

    test('an absolute seek inside the EOF window drops the pending finish', () {
      // Tail press → the arm + its 300 ms window. The user drags back to the
      // middle before it expires: the hooks' `seek()` (src != 'step') drops the
      // whole step bookkeeping, so the timer must find nothing to collapse.
      // Without it the armed press advanced the queue from a position the user
      // had already left (the fvp hook clears only the OSD/intent before this
      // parity fix).
      h.press(stepMs, nowMs: 0);
      expect(h.seeks, 1);
      h.absoluteSeek();
      h.tick(nowMs: eofWindowMs);
      expect(h.advances, 0,
          reason: 'a seek away from the tail cancels the finish it armed');
    });
  });
}

/// Minimal stand-in for the two player hooks' step path.
class _StepHarness {
  _StepHarness({
    required this.fileUri,
    required this.openedUri,
    required this.durationMs,
    required this.positionMs,
  });

  final MpvSeekTailState tail = MpvSeekTailState();

  String fileUri;
  String? openedUri;
  int durationMs;
  int positionMs;
  bool advancing = false;

  int seeks = 0;
  int progressWrites = 0;
  int advances = 0;
  int dropped = 0;
  int? _collapseDueMs;
  String? _armedUri;
  String? lastSeekWasOn;

  /// One ←/→ press, mirroring `seekRelative` + `applyTailStep`.
  void press(int deltaMs, {required int nowMs}) {
    // seekRelative's first gate (the SAME function the hooks call).
    if (gateStepPress(
          mediaUri: fileUri,
          openedUri: openedUri,
          dispatchInFlight: advancing,
        ) ==
        StepPressGate.dropMediaSwitching) {
      dropped++;
      return;
    }
    if (deltaMs < 0) tail.reset();
    final StepTailAction action = decideStepTail(
      reportedMs: positionMs,
      deltaMs: deltaMs,
      durationMs: durationMs,
      mode: StepTailFinishMode.strict,
      playing: true,
    );
    switch (action) {
      case StepTailAction.hold:
        return;
      case StepTailAction.step:
        seeks++;
        lastSeekWasOn = fileUri;
        progressWrites++;
        return;
      case StepTailAction.finishItem:
        if (!tail.armFirstPress(fileUri, durationMs)) return;
        seeks++;
        lastSeekWasOn = fileUri;
        progressWrites++;
        // armTailEofWindow captures the media the arm belongs to.
        _armedUri = fileUri;
        _collapseDueMs = nowMs + 300;
        return;
    }
  }

  /// Fires the EOF window (mirrors `armTailEofWindow`'s Timer callback and
  /// `collapseTailStepToEof`).
  void tick({required int nowMs}) {
    final int? due = _collapseDueMs;
    if (due == null || nowMs < due) return;
    _collapseDueMs = null;
    final String? uri = _armedUri;
    _armedUri = null;
    if (uri == null) return;
    if (fileUri != uri || openedUri != uri) return;
    if (!tail.consumeCollapse(mediaUri: uri)) return;
    // dispatchItemFinished resets the arm before advancing (so a repeat-one
    // loop of the SAME media can arm again).
    tail.reset();
    advances++;
  }

  /// An ABSOLUTE seek (`src != 'step'`): both hooks drop the whole step
  /// bookkeeping, tail arm and its EOF window included (media_kit already did;
  /// the fvp hook clears them through the same `resetStepBurst`).
  void absoluteSeek() {
    tail.reset();
    _armedUri = null;
    _collapseDueMs = null;
  }

  /// The queue advanced but the new media's open is still in flight: the hook
  /// keeps the PREVIOUS duration/position (the field log's `end=312106ms`).
  void advanceQueueWillOpen({required String nextUri}) {
    fileUri = nextUri;
    openedUri = null;
  }

  void openCompleted({
    required String uri,
    required int durationMs,
    required int positionMs,
  }) {
    openedUri = uri;
    this.durationMs = durationMs;
    this.positionMs = positionMs;
  }
}
