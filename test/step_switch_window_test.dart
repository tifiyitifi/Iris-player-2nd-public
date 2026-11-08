import 'package:flutter_test/flutter_test.dart';
import 'package:iris/hooks/player/live_progress_attribution.dart';
import 'package:iris/hooks/player/seek_tuning.dart';
import 'package:iris/models/enums/step_tail_finish_mode.dart';

/// Regression test for the "rapid → at the tail parks / rewinds / skips an
/// episode" family.
///
/// The hooks cannot be exercised without a real engine, so the ORDERING of the
/// production path is reproduced here with the real decision helpers:
///
/// ```
/// seekRelative → (release a spent tail latch) → gateStepPress
///              → decideStepTail (base = StepIntent.baseFor)
///              → finishItem: dispatchItemFinished (NO seek) + tail latch
///              → exactStep : one absolute seek, burst stays alive
///              → step      : one native relative keyframe seek
/// ```
///
/// Two field defects are pinned here:
///
///  * the exact tail step seeked BACKWARDS, because the tail was judged against
///    the nominal burst sum while the picture (keyframe landings round forward)
///    was already further ahead — `base=962017ms reported=974271ms` produced a
///    seek to 966017 ms on a 974 271 ms file;
///  * a second press after the dispatch returned but before the hook rebound
///    the next media dispatched a SECOND finish (`finish now` twice) and
///    advanced twice, skipping one entry.
void main() {
  const int stepMs = 4000;
  const String evelyn = 'file:///media/evelyn.mp4';
  const String nightParty = 'file:///media/night-party.mp4';

  group('a tail press across a queue advance', () {
    late _StepHarness h;

    setUp(() {
      h = _StepHarness(
        fileUri: evelyn,
        openedUri: evelyn,
        durationMs: 312106,
        positionMs: 309550,
      );
    });

    test('the crossing press finishes ONCE, without a seek', () {
      // 309.55 s + 4 s >= 312.106 s: the press asks to go past the end.
      h.press(stepMs);
      expect(h.finishes, 1);
      expect(h.seeks, 0,
          reason: 'a finish must never be turned into a keyframe seek');
      expect(h.exactSteps, 0);

      // The dispatch is in flight: a held key keeps arriving, every repeat is
      // dropped (the engine's seek queue is left alone).
      for (int i = 0; i < 20; i++) {
        h.press(stepMs);
      }
      expect(h.finishes, 1);
      expect(h.seeks, 0);

      // Dispatch returned; the queue moved on but the next open is still in
      // flight (the hook holds the new file with the OLD engine state).
      h.advanceQueueWillOpen(nextUri: nightParty);
      for (int i = 0; i < 5; i++) {
        h.press(stepMs);
      }
      expect(h.finishes, 1, reason: 'the next episode must not be collapsed');
      expect(h.seeks, 0, reason: 'no seek may resolve against the old state');

      // Open completed: the burst resumes on the NEW media, from its head.
      h.openCompleted(uri: nightParty, durationMs: 644928, positionMs: 0);
      h.press(stepMs);
      expect(h.finishes, 1);
      expect(h.seeks, 1);
      expect(h.lastSeekWasOn, nightParty);
    });

    test('a press after the dispatch returns does NOT finish twice', () {
      // The exact field sequence: `[step-tail] finish now` → `completed advance
      // handled=true` → another → `[step-tail] finish now` again →
      // `provider.next` (seg1 skipped to seg2). `finishedDispatchInFlight` is
      // already cleared at that point, and the hook still holds the old media,
      // so ONLY the per-media tail latch can stop the second advance.
      h.press(stepMs);
      expect(h.finishes, 1);
      h.dispatchReturned(); // finally: in-flight latch cleared, queue advanced
      for (int i = 0; i < 8; i++) {
        h.press(stepMs);
      }
      expect(h.finishes, 1, reason: 'one advance per media');
      expect(h.dropped, 8);
      expect(h.seeks, 0);
      expect(h.exactSteps, 0);
    });

    test('the latch is released when the media actually changes', () {
      h.press(stepMs);
      h.dispatchReturned();
      h.advanceQueueWillOpen(nextUri: nightParty);
      h.openCompleted(uri: nightParty, durationMs: 644928, positionMs: 644000);
      // Same burst, new media: the tail press finishes THAT entry.
      h.press(stepMs);
      expect(h.finishes, 2);
      expect(h.finishedUri, nightParty);
    });

    test('a rewind off the tail releases the latch so it can finish again', () {
      h.press(stepMs);
      h.dispatchReturned();
      // Repeat-one style restart of the SAME media: back at the head.
      h.positionMs = 1000;
      h.press(stepMs);
      expect(h.seeks, 1, reason: 'a fresh step, not a dropped press');
    });

    test('a no-op advance releases the latch (single-item queue)', () {
      // The most common setup: ONE entry, repeat off (watching a movie). The
      // tail press finishes it, `advancePlayQueueOnCompleted` has nowhere to go,
      // and playback keeps running to the real EOF. With the latch left armed on
      // the tail, the gate dropped EVERY later press in both directions — the
      // only way out was an absolute scrub.
      h.press(stepMs);
      expect(h.finishes, 1);
      h.dispatchReturned(advanced: false);

      h.press(-stepMs);
      expect(h.dropped, 0);
      expect(h.seeks, 1, reason: 'a rewind must always work');

      h.press(stepMs);
      expect(h.dropped, 0, reason: 'the forward press is alive again');
    });

    test('a backward press alone releases an armed latch', () {
      // The advance is in flight (the hook still holds the OLD media), so the
      // latch must keep dropping a second FINISH. It must not also drop a
      // rewind: a rewind demonstrably leaves the tail, and `resetStepBurst`
      // clears the latch before the gate ever sees the press.
      h.press(stepMs);
      h.dispatchReturned(); // queue advanced, the hook is not rebound yet
      h.press(-stepMs);
      expect(h.dropped, 0);
      expect(h.seeks, 1);

      // The latch is gone, so a press that sits back inside the final GOP takes
      // the exact path instead of being swallowed.
      h.positionMs = h.durationMs - 10000;
      h.press(stepMs);
      expect(h.dropped, 0);
      expect(h.exactSteps, 1);
    });

    test('the tail is judged from the PICTURE, never from the stale sum', () {
      // The field log, press by press: the accumulator chained +4 s nominal
      // steps while the engine's keyframe landings ran far ahead, until the
      // picture sat ON the end (974271 == duration) with the sum still at
      // 962017. That press must finish — not exact-seek back to 966017.
      final h2 = _StepHarness(
        fileUri: evelyn,
        openedUri: evelyn,
        durationMs: 974271,
        positionMs: 890017,
      );
      for (int i = 0; i < 20; i++) {
        h2.press(stepMs, pictureAhead: 974271);
      }
      expect(h2.finishes, 1);
      expect(h2.exactSteps, 0,
          reason: 'the crossing press must never exact-seek backwards');
      expect(h2.lastExactTarget, isNull);
    });

    test('an exact tail step never lands behind the picture', () {
      // Inside the final GOP but not the end: 310 s + 3 s of a 322.293 s file.
      final h2 = _StepHarness(
        fileUri: evelyn,
        openedUri: evelyn,
        durationMs: 322293,
        positionMs: 310000,
      );
      h2.press(3000);
      expect(h2.exactSteps, 1);
      expect(h2.finishes, 0);
      expect(h2.seeks, 0,
          reason: 'the exact path replaces the relative keyframe seek');
      expect(h2.lastExactTarget, 313000);

      // A later press while the picture already jumped ahead (keyframe landing
      // of the previous exact seek) must seek FORWARD from the picture.
      h2.positionMs = 318000;
      h2.press(3000);
      expect(h2.lastExactTarget, 321000);
      expect(h2.lastExactTarget! >= h2.positionMs, isTrue);
    });

    test('presses during the advance dispatch are dropped too', () {
      // The narrow window between `finishedDispatchInFlight = true` and the
      // queue actually changing: `file`/`opened` still describe Evelyn.
      h.advancing = true;
      for (int i = 0; i < 5; i++) {
        h.press(stepMs);
      }
      expect(h.seeks, 0);
      expect(h.exactSteps, 0);
      expect(h.finishes, 0);
      expect(h.dropped, 5);
    });

    test('a paused tail press is held (no advance, no seek)', () {
      h.playing = false;
      h.press(stepMs);
      expect(h.finishes, 0);
      expect(h.seeks, 0);
      expect(h.exactSteps, 0);
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

  String fileUri;
  String? openedUri;
  int durationMs;
  int positionMs;
  bool playing = true;
  bool advancing = false;

  /// The hook's burst accumulator ([StepIntent]).
  final StepIntent intent = StepIntent();

  /// The hook's per-media tail finish latch.
  String? finishedUri;

  int seeks = 0;
  int exactSteps = 0;
  int finishes = 0;
  int dropped = 0;
  String? lastSeekWasOn;
  int? lastExactTarget;

  /// One ←/→ press, mirroring `seekRelative` → `applyTailStep`.
  ///
  /// [pictureAhead] lets a test model the engine's keyframe landing running
  /// ahead of the nominal sum (the position the picture is really on).
  void press(int deltaMs, {int? pictureAhead}) {
    final int reportedMs = pictureAhead ?? positionMs;
    // A rewind leaves the tail, so `seekRelative` resets the burst (which also
    // clears the tail latch) BEFORE the gate. The gate itself is what drops
    // presses while a latch is armed, so a backward press could never release
    // it — the finished item stayed un-steppable until an absolute seek.
    if (deltaMs < 0) {
      intent.reset();
      finishedUri = null;
    }
    // seekRelative releases a spent latch BEFORE the gate.
    if (finishedUri != null &&
        (finishedUri != fileUri ||
            stepTailLatchReusable(
              reportedMs: reportedMs,
              durationMs: durationMs,
            ))) {
      finishedUri = null;
    }
    // The gate the hooks call (same function, same latch semantics).
    if (gateStepPress(
          mediaUri: fileUri,
          openedUri: openedUri,
          dispatchInFlight: advancing,
          finishedUri: finishedUri,
        ) !=
        StepPressGate.accept) {
      dropped++;
      return;
    }
    final int baseMs = intent.baseFor(
      reportedMs: reportedMs,
      lockIntentMs: null,
      deltaMs: deltaMs,
    );
    final StepTailAction action = decideStepTail(
      reportedMs: baseMs,
      deltaMs: deltaMs,
      durationMs: durationMs,
      mode: StepTailFinishMode.strict,
      playing: playing,
    );
    switch (action) {
      case StepTailAction.step:
        seeks++;
        lastSeekWasOn = fileUri;
        intent.note((baseMs + deltaMs).clamp(0, durationMs), deltaMs: deltaMs);
        return;
      case StepTailAction.exactStep:
        exactSteps++;
        lastSeekWasOn = fileUri;
        lastExactTarget = stepSeekTargetMs(
          reportedMs: baseMs,
          deltaMs: deltaMs,
          durationMs: durationMs,
        );
        intent.note(lastExactTarget!, deltaMs: deltaMs);
        return;
      case StepTailAction.hold:
        intent.reset();
        return;
      case StepTailAction.finishItem:
        finishes++;
        // `dispatchItemFinished` sets the latch and the in-flight flag
        // synchronously, before its first await.
        finishedUri = fileUri;
        advancing = true;
        return;
    }
  }

  /// The dispatch's `finally`: `finishedDispatchInFlight = false`. The queue has
  /// advanced, but the hook still holds the OLD media until it rebinds.
  ///
  /// [advanced] is false when the advance door had nowhere to go (single-entry
  /// queue with repeat off, scenario tail, a VM segment that was already
  /// advancing): the hook then drops the latch, because nothing is coming to
  /// rebind the media and a latch at the tail would swallow every later press.
  void dispatchReturned({bool advanced = true}) {
    advancing = false;
    if (!advanced) finishedUri = null;
  }

  /// The "queue advanced, next open in flight" leg.
  void advanceQueueWillOpen({required String nextUri}) {
    advancing = false;
    fileUri = nextUri;
    openedUri = null;
    intent.reset();
    finishedUri = null;
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
