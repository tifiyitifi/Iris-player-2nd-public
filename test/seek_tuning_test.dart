import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/meta_settings/contributions/settings_catalog.dart';
import 'package:iris/features/meta_settings/engine/step_tail_finish_mode.dart';
import 'package:iris/features/meta_settings/engine/video_cache_preset.dart';
import 'package:iris/hooks/player/live_progress_attribution.dart';
import 'package:iris/hooks/player/seek_tuning.dart';
import 'package:iris/models/enums/step_tail_finish_mode.dart';
import 'package:iris/models/enums/video_cache_preset.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/utils/live_seek_throttle.dart';
import 'package:iris/utils/seek_tail_guard.dart';

void main() {
  group('resolveRelativeBaseMs', () {
    test('uses the reported position when no intent is armed', () {
      expect(
        resolveRelativeBaseMs(reportedMs: 1000, pendingIntentMs: null),
        1000,
      );
    });

    test('accumulates onto the armed intent while a seek is in flight', () {
      expect(
        resolveRelativeBaseMs(reportedMs: 1000, pendingIntentMs: 5000),
        5000,
      );
    });
  });

  group('StepIntent', () {
    const int step = 4000;

    test('falls back to the reported position while nothing is recorded', () {
      expect(
        StepIntent().baseFor(reportedMs: 1000, lockIntentMs: null, deltaMs: step),
        1000,
      );
    });

    test('prefers the step intent over the position-lock intent', () {
      // The lock unlocks on the first ±2s landing sample, so during a rapid
      // burst its target is often already gone; the step intent must keep
      // accumulating regardless.
      final i = StepIntent()..note(5000, deltaMs: step);
      expect(
        i.baseFor(reportedMs: 1000, lockIntentMs: 5000, deltaMs: step),
        5000,
      );
      expect(i.baseFor(reportedMs: 1000, lockIntentMs: null, deltaMs: step), 5000);
    });

    test('keeps the lock intent when no step has been recorded yet', () {
      expect(
        StepIntent().baseFor(reportedMs: 1000, lockIntentMs: 7000, deltaMs: step),
        7000,
      );
    });

    test('N presses advance exactly N steps while the reported position '
        'sits still', () {
      final i = StepIntent();
      // The engine reports an unmoved position while a seek is still decoding;
      // the accumulation must keep every press.
      const int reported = 541233;
      int target = reported;
      for (int press = 1; press <= 5; press++) {
        target =
            i.baseFor(reportedMs: reported, lockIntentMs: null, deltaMs: step) +
                step;
        i.note(target, deltaMs: step);
        expect(target, reported + step * press, reason: 'press $press');
      }
    });

    test('a lock that unlocks mid-burst does not rewind the accumulation', () {
      final i = StepIntent()..note(489583, deltaMs: step);
      // Lock already unlocked and the engine is still sitting on its previous
      // landing.
      expect(
        i.baseFor(reportedMs: 485566, lockIntentMs: null, deltaMs: step) + step,
        493583,
      );
      i.note(493583, deltaMs: step);
      expect(
        i.baseFor(reportedMs: 485583, lockIntentMs: null, deltaMs: step) + step,
        497583,
      );
    });

    test('reset drops the accumulation so an absolute seek restarts it', () {
      final i = StepIntent()..note(9000, deltaMs: step);
      i.reset();
      expect(i.lastMs, isNull);
      expect(
        i.baseFor(reportedMs: 1200, lockIntentMs: null, deltaMs: step),
        1200,
      );
    });

    test('an inactive burst ignores the stale accumulation', () {
      // Burst ended (no press inside the window): the engine has played past
      // the recorded target, so the next press must anchor on the live
      // position — the default (active) would jump back to the old target.
      final i = StepIntent()..note(9000, deltaMs: step);
      expect(
        i.baseFor(
            reportedMs: 400000, lockIntentMs: null, deltaMs: step, active: false),
        400000,
      );
      expect(i.baseFor(reportedMs: 400000, lockIntentMs: null, deltaMs: step),
          400000);
    });

    test('an inactive burst still honours the in-flight lock intent', () {
      // The lock target is the seek actually in flight, so it stays the base
      // even once the burst flag has cleared.
      final i = StepIntent()..note(9000, deltaMs: step);
      expect(
        i.baseFor(
            reportedMs: 1000, lockIntentMs: 5000, deltaMs: step, active: false),
        5000,
      );
    });

    test('note replaces the previous target', () {
      final i = StepIntent()
        ..note(9000, deltaMs: step)
        ..note(13000, deltaMs: step);
      expect(i.lastMs, 13000);
    });

    test('a forward press never anchors BEHIND the picture (tail rewind)', () {
      // The field log this pins: the accumulator was at 962 017 ms while the
      // engine already sat at 974 271 ms (the seek landed on the next key
      // frame), so judging the tail by the sum alone seeked BACK to 966 017 ms.
      final i = StepIntent()..note(962017, deltaMs: step);
      expect(
        i.baseFor(reportedMs: 974271, lockIntentMs: null, deltaMs: step),
        974271,
      );
      // …and the press then reaches the end instead of stepping to 966 017.
      expect(
        decideStepTail(
          reportedMs:
              i.baseFor(reportedMs: 974271, lockIntentMs: null, deltaMs: step),
          deltaMs: step,
          durationMs: 974271,
          mode: StepTailFinishMode.strict,
          playing: true,
        ),
        StepTailAction.finishItem,
      );
    });

    test('a backward burst keeps accumulating while the engine lags', () {
      const int reported = 500000;
      final i = StepIntent();
      int target = reported;
      for (int press = 1; press <= 3; press++) {
        target =
            i.baseFor(reportedMs: reported, lockIntentMs: null, deltaMs: -step) -
                step;
        i.note(target, deltaMs: -step);
        expect(target, reported - step * press, reason: 'press $press');
      }
    });

    test('a reversal re-anchors on the picture instead of the other direction', () {
      // Forward burst heading to 400 s, engine still at 396 s; pressing ← must
      // rewind one step from the PICTURE (392 s), not from the pending 400 s
      // (396 s would "rewind" nothing) and never from a stale 5 s target.
      final i = StepIntent()..note(400000, deltaMs: step);
      expect(
        i.baseFor(reportedMs: 396000, lockIntentMs: null, deltaMs: -step),
        396000,
      );
      // The reverse: a backward burst then a forward press.
      final j = StepIntent()..note(392000, deltaMs: -step);
      expect(
        j.baseFor(reportedMs: 396000, lockIntentMs: null, deltaMs: step),
        396000,
      );
    });
  });

  group('stepSeekArgs', () {
    test('is a relative seek with explicit keyframe precision', () {
      // mpv's own ←/→ issue a RELATIVE seek, and relative seeks default to
      // keyframes; the explicit flag also short-circuits `hr-seek=yes`.
      expect(stepSeekArgs(5000), ['seek', '5.0000', 'relative+keyframes']);
    });

    test('keeps the sign so backward steps rewind', () {
      expect(stepSeekArgs(-5000), ['seek', '-5.0000', 'relative+keyframes']);
    });

    test('preserves sub-second deltas with 4 decimals', () {
      expect(stepSeekArgs(500), ['seek', '0.5000', 'relative+keyframes']);
      expect(stepSeekArgs(-250), ['seek', '-0.2500', 'relative+keyframes']);
    });

    test('a zero delta is a no-op seek', () {
      expect(stepSeekArgs(0), ['seek', '0.0000', 'relative+keyframes']);
    });
  });

  group('stepSeekTargetMs', () {
    test('advances / rewinds by the delta inside the media', () {
      expect(
        stepSeekTargetMs(reportedMs: 10000, deltaMs: 3000, durationMs: 60000),
        13000,
      );
      expect(
        stepSeekTargetMs(reportedMs: 10000, deltaMs: -3000, durationMs: 60000),
        7000,
      );
    });

    test('clamps into [0, duration]', () {
      expect(
        stepSeekTargetMs(reportedMs: 1000, deltaMs: -3000, durationMs: 60000),
        0,
      );
      expect(
        stepSeekTargetMs(reportedMs: 59000, deltaMs: 3000, durationMs: 60000),
        60000,
      );
    });

    test('falls back to 0 while the duration is unknown', () {
      expect(
        stepSeekTargetMs(reportedMs: 5000, deltaMs: 3000, durationMs: 0),
        0,
      );
    });

    test('clamps the anchor first, so a stale out-of-range reported position '
        'does not land one press away from the engine', () {
      // The reported position can sit past the duration (a stale sample after
      // the duration was revised down). Clamping only the SUM landed the OSD /
      // progress write 3s ahead of the delta actually handed to mpv.
      expect(
        stepSeekTargetMs(reportedMs: 61000, deltaMs: -3000, durationMs: 60000),
        57000,
      );
      // Same defect below zero, in the forward direction.
      expect(
        stepSeekTargetMs(reportedMs: -5000, deltaMs: 3000, durationMs: 60000),
        3000,
      );
    });

    test('a backward press never lands off the front, whatever the sample', () {
      // The OSD/persist target is always inside the media, and a rewind is the
      // only direction the delta itself is bounded in.
      const int dur = 60000;
      for (final int reported in [-9000, -1, 0, 1000, 30000, 59000, 60000, 61000]) {
        final int sent = stepSeekSentDelta(
            reportedMs: reported, deltaMs: -8000, durationMs: dur);
        expect(
          reported.clamp(0, dur) + sent,
          greaterThanOrEqualTo(0),
          reason: 'reported=$reported',
        );
      }
    });
  });

  group('stepSeekSentDelta', () {
    test('passes the delta through inside the media', () {
      expect(
        stepSeekSentDelta(reportedMs: 10000, deltaMs: 3000, durationMs: 60000),
        3000,
      );
      expect(
        stepSeekSentDelta(reportedMs: 10000, deltaMs: -3000, durationMs: 60000),
        -3000,
      );
    });

    test('never sends the engine past the start (negative position defect)', () {
      // Pressing rewind at the very start used to emit -3000 and mpv reported
      // a negative time-pos; the anchor is clamped first so this is a no-op.
      expect(
        stepSeekSentDelta(reportedMs: 0, deltaMs: -3000, durationMs: 60000),
        0,
      );
      expect(
        stepSeekSentDelta(reportedMs: 1000, deltaMs: -3000, durationMs: 60000),
        -1000,
      );
      // Already off the front (a legacy negative sample): pull back to 0 only.
      expect(
        stepSeekSentDelta(reportedMs: -12000, deltaMs: -3000, durationMs: 60000),
        0,
      );
    });

    test('a forward step forwards the raw delta, even at the tail', () {
      // mpv adds the delta to its own playback time and never clamps the target
      // (`player/playloop.c`), and a forward seek carries SEEK_FORWARD ("prefer
      // later time if not exact"), so it lands at or AFTER the target; a target
      // past the end makes the demuxer seek fail, which mpv answers by abandoning
      // the seek so the file plays out to EOF. Clamping here to `duration - 1`
      // pinned the target inside the final GOP — the tail rollback that then
      // repeated on every further press.
      //
      // A Virtual-Media segment follows the SAME rule: a target belonging to
      // another segment never reaches this path (`resolveRelativeSeek` resolves
      // it and the hook opens it through `jumpToSegment`), so running past the
      // current file's end just ends that file.
      expect(
        stepSeekSentDelta(reportedMs: 59000, deltaMs: 3000, durationMs: 60000),
        3000,
      );
      expect(
        stepSeekSentDelta(reportedMs: 59999, deltaMs: 5000, durationMs: 60000),
        5000,
      );
    });

    test('an unknown duration forwards the raw delta', () {
      // Unreachable in practice — both hooks drop the press before calling when
      // the duration is unknown — but the helper must not fabricate a no-op.
      expect(
        stepSeekSentDelta(reportedMs: 5000, deltaMs: 3000, durationMs: 0),
        3000,
      );
      expect(
        stepSeekSentDelta(reportedMs: 5000, deltaMs: -3000, durationMs: 0),
        0,
      );
    });
  });

  group('single-file tail step (lastSeekableMs)', () {
    test('keeps the shared guard distance from the media end', () {
      expect(lastSeekableMs(60000), 60000 - kSeekTailGuardMs);
    });

    test('a zero or guard-sized duration stays seekable only when short', () {
      expect(lastSeekableMs(0), 0);
      expect(lastSeekableMs(null), 0);
      // A guard-sized clip keeps its full range instead of collapsing to 0.
      expect(lastSeekableMs(kSeekTailGuardMs), kSeekTailGuardMs);
    });

    test('the OSD target is bounded by the media, not by the tail guard', () {
      // Display only: a step seek forwards an unclamped delta, so the HUD target
      // is clamped to the media — clamping it to `lastSeekableMs` would claim a
      // landing 100 ms before the one the engine may actually take.
      const dur = 10000;
      expect(
        stepSeekTargetMs(reportedMs: 9500, deltaMs: 5000, durationMs: dur),
        dur,
      );
      expect(
        stepSeekTargetMs(reportedMs: 9000, deltaMs: -2000, durationMs: dur),
        7000,
      );
      expect(lastSeekableMs(dur), lessThan(dur));
    });
  });

  group('TrailingCoalescer', () {
    test('keeps only the newest value and clears on flush', () {
      final c = TrailingCoalescer<int>();
      expect(c.hasPending, isFalse);
      c.record(1);
      expect(c.hasPending, isTrue);
      c.record(2);
      expect(c.flush(), 2);
      expect(c.hasPending, isFalse);
      expect(c.flush(), isNull);
    });
  });

  group('LiveSeekThrottle', () {
    test('allows one seek per interval and re-arms on reset', () {
      final t = LiveSeekThrottle(minInterval: const Duration(milliseconds: 120));
      final DateTime t0 = DateTime(2026);
      expect(t.allow(t0), isTrue);
      expect(t.allow(t0.add(const Duration(milliseconds: 60))), isFalse);
      expect(t.allow(t0.add(const Duration(milliseconds: 130))), isTrue);
      t.reset();
      expect(t.allow(t0.add(const Duration(milliseconds: 140))), isTrue);
    });
  });

  group('VideoCachePreset', () {
    test('every preset keeps the backward cache within the forward one', () {
      for (final VideoCachePreset p in VideoCachePreset.values) {
        expect(p.backBytes <= p.maxBytes, isTrue, reason: '$p');
        expect(p.backBytes, greaterThan(0));
      }
    });

    test('presets grow monotonically and balanced is the tuned default', () {
      expect(
        VideoCachePreset.low.maxBytes < VideoCachePreset.balanced.maxBytes,
        isTrue,
      );
      expect(
        VideoCachePreset.balanced.maxBytes < VideoCachePreset.high.maxBytes,
        isTrue,
      );
      // balanced == the values the media_kit hook asserts by default.
      expect(VideoCachePreset.balanced.maxBytes, 150 * 1024 * 1024);
      expect(VideoCachePreset.balanced.backBytes, 64 * 1024 * 1024);
    });
  });

  group('resolveVideoCachePreset', () {
    test('returns the stored preset while the metadata gate is ON', () {
      const AppState s = AppState(videoCachePreset: VideoCachePreset.high);
      expect(
        resolveVideoCachePreset(s, metadataEnabled: true),
        VideoCachePreset.high,
      );
    });

    test('degrades to balanced while the gate is OFF', () {
      const AppState s = AppState(videoCachePreset: VideoCachePreset.high);
      expect(
        resolveVideoCachePreset(s, metadataEnabled: false),
        VideoCachePreset.balanced,
      );
    });
  });

  group('decideStepTail / stepFinishesItem (tail-step policy)', () {
    // 322.293 s container, the failing tail press from the measured log: the
    // last decodable frame sits ~321.7 s, so every target from there on is
    // unreachable and the engine parks/rolls back inside the final GOP.
    const int dur = 322293;

    test('mid-file presses stay ordinary steps in both modes', () {
      for (final mode in StepTailFinishMode.values) {
        expect(
          decideStepTail(
            reportedMs: 17816,
            deltaMs: 4000,
            durationMs: dur,
            mode: mode,
            playing: true,
          ),
          StepTailAction.step,
        );
      }
    });

    test('a backward press is never a finish', () {
      for (final mode in StepTailFinishMode.values) {
        expect(
          decideStepTail(
            reportedMs: 321456,
            deltaMs: -4000,
            durationMs: dur,
            mode: mode,
            playing: true,
          ),
          StepTailAction.step,
        );
      }
    });

    test('an unknown duration never finishes', () {
      for (final mode in StepTailFinishMode.values) {
        expect(
          stepFinishesItem(
              reportedMs: 1000, deltaMs: 4000, durationMs: 0, mode: mode),
          isFalse,
        );
      }
    });

    test('strict finishes a target that reaches the media end', () {
      // `target == duration` is as unreachable through a relative keyframe
      // seek as a target past it (mpv rolls back into the final GOP and never
      // raises `completed`), so reaching the end must finish.
      expect(
        stepFinishesItem(
            reportedMs: dur - 4000,
            deltaMs: 4000,
            durationMs: dur,
            mode: StepTailFinishMode.strict),
        isTrue,
      );
      expect(
        stepFinishesItem(
            reportedMs: dur - 4001,
            deltaMs: 4000,
            durationMs: dur,
            mode: StepTailFinishMode.strict),
        isFalse,
      );
      expect(
        stepFinishesItem(
            reportedMs: dur - 3999,
            deltaMs: 4000,
            durationMs: dur,
            mode: StepTailFinishMode.strict),
        isTrue,
      );
    });

    test('window also finishes inside the final unreachable GOP', () {
      // 0.8 s before the end, inside one 4 s step: still unreachable, so the
      // press must finish instead of rolling the picture back.
      expect(
        stepFinishesItem(
            reportedMs: 321500,
            deltaMs: 4000,
            durationMs: dur,
            mode: StepTailFinishMode.window),
        isTrue,
      );
      // Just outside the FINISH window (4 s step => 4 s window): it is still
      // inside the 10 s EXACT window, so the press must not roll back — it
      // takes the exact path instead of a keyframe step.
      expect(
        stepFinishesItem(
            reportedMs: dur - 9000,
            deltaMs: 4000,
            durationMs: dur,
            mode: StepTailFinishMode.window),
        isFalse,
      );
      expect(
        decideStepTail(
            reportedMs: dur - 9000,
            deltaMs: 4000,
            durationMs: dur,
            mode: StepTailFinishMode.window,
            playing: true),
        StepTailAction.exactStep,
      );
    });

    test('the window never shrinks below its floor for short steps', () {
      // A 500 ms step would leave the long final GOP unreachable; the 2 s floor
      // still catches it.
      expect(
        stepFinishesItem(
            reportedMs: dur - 1000,
            deltaMs: 500,
            durationMs: dur,
            mode: StepTailFinishMode.window),
        isTrue,
      );
      expect(
        stepFinishesItem(
            reportedMs: dur - 3000,
            deltaMs: 500,
            durationMs: dur,
            mode: StepTailFinishMode.window),
        isFalse,
      );
      // Outside the finish window but inside the exact one: exact step.
      expect(
        decideStepTail(
            reportedMs: dur - 3000,
            deltaMs: 500,
            durationMs: dur,
            mode: StepTailFinishMode.window,
            playing: true),
        StepTailAction.exactStep,
      );
    });

    test('window never finishes from the head of a short clip', () {
      // 1.5 s clip + 0.5 s step: the 2 s floor used to put the threshold at
      // `1500 - 2000` (negative), so the FIRST press — at 0 — finished the item
      // and the clip could not be stepped at all.
      for (final bool playing in [true, false]) {
        expect(
          decideStepTail(
              reportedMs: 0,
              deltaMs: 500,
              durationMs: 1500,
              mode: StepTailFinishMode.window,
              playing: playing),
          StepTailAction.step,
          reason: 'playing=$playing',
        );
      }
      // The reachable head region stays steppable ...
      expect(
        stepFinishesItem(
            reportedMs: 0,
            deltaMs: 500,
            durationMs: 1500,
            mode: StepTailFinishMode.window),
        isFalse,
      );
      // ... while the unreachable tail still finishes.
      expect(
        stepFinishesItem(
            reportedMs: 1000,
            deltaMs: 500,
            durationMs: 1500,
            mode: StepTailFinishMode.window),
        isTrue,
      );
    });

    test('the window is capped at half the media, not just at the 2 s floor',
        () {
      // 2.4 s clip + 0.5 s step: the duration exceeds the 2 s floor, so a
      // `duration <= kStepTailFinishWindowMs` fallback would leave this
      // boundary finishing on the head press. The half-media cap covers it.
      expect(
        stepFinishesItem(
            reportedMs: 0,
            deltaMs: 500,
            durationMs: 2400,
            mode: StepTailFinishMode.window),
        isFalse,
      );
      expect(
        stepFinishesItem(
            reportedMs: 1900,
            deltaMs: 500,
            durationMs: 2400,
            mode: StepTailFinishMode.window),
        isTrue,
      );
      // Exactly twice the floor: capped to duration/2, the head still steps.
      expect(
        stepFinishesItem(
            reportedMs: 0,
            deltaMs: 500,
            durationMs: 4000,
            mode: StepTailFinishMode.window),
        isFalse,
      );
    });

    test('a short clip keeps the strict outcome for a step past the end', () {
      // 3 s clip + 4 s step: the landing is past the end, which strict finishes
      // too — the cap must not turn a "reached the end" press into a step.
      expect(
        stepFinishesItem(
            reportedMs: 0,
            deltaMs: 4000,
            durationMs: 3000,
            mode: StepTailFinishMode.window),
        isTrue,
      );
      expect(
        stepFinishesItem(
            reportedMs: 0,
            deltaMs: 4000,
            durationMs: 3000,
            mode: StepTailFinishMode.strict),
        isTrue,
      );
    });

    test('an out-of-range sample anchors on the media bounds first', () {
      // A stale sample past the end must not turn a rewind into a finish.
      expect(
        stepFinishesItem(
            reportedMs: dur + 5000,
            deltaMs: -1000,
            durationMs: dur,
            mode: StepTailFinishMode.strict),
        isFalse,
      );
      expect(
        stepFinishesItem(
            reportedMs: -5000,
            deltaMs: 4000,
            durationMs: dur,
            mode: StepTailFinishMode.strict),
        isFalse,
      );
    });

    test('playing finishes the item, paused holds the press', () {
      for (final mode in StepTailFinishMode.values) {
        expect(
          decideStepTail(
            reportedMs: 321656,
            deltaMs: 4000,
            durationMs: dur,
            mode: mode,
            playing: true,
          ),
          StepTailAction.finishItem,
        );
        expect(
          decideStepTail(
            reportedMs: 321656,
            deltaMs: 4000,
            durationMs: dur,
            mode: mode,
            playing: false,
          ),
          StepTailAction.hold,
        );
      }
    });
  });

  group('tail exact seek (final-GOP landing)', () {
    // 322.293 s container; the last key frame of the measured file sat at
    // 321.336 s, so a keyframe step from there can only land BACK on 321.336.
    const int dur = 322293;

    test('a mid-file step keeps the native keyframe path', () {
      expect(
        stepNeedsExactSeek(targetMs: 17816 + 3000, durationMs: dur, deltaMs: 3000),
        isFalse,
      );
    });

    test('a step inside the final GOP switches to the exact path', () {
      expect(
        stepNeedsExactSeek(
            targetMs: dur - 100, durationMs: dur, deltaMs: 3000),
        isTrue,
      );
      // Just inside / just outside the 10 s window.
      expect(
        stepNeedsExactSeek(targetMs: 313000, durationMs: dur, deltaMs: 3000),
        isTrue,
      );
      expect(
        stepNeedsExactSeek(targetMs: 310000, durationMs: dur, deltaMs: 3000),
        isFalse,
      );
    });

    test('the window is at least one step long', () {
      // A 12 s step reaches 12 s back, not just 10 s.
      expect(
        stepNeedsExactSeek(targetMs: 311000, durationMs: dur, deltaMs: 12000),
        isTrue,
      );
      expect(
        stepNeedsExactSeek(targetMs: 309000, durationMs: dur, deltaMs: 12000),
        isFalse,
      );
    });

    test('a short step next to a long final GOP still switches', () {
      // 1 s step at 315 s: the 10 s floor covers the default x264 GOP.
      expect(
        stepNeedsExactSeek(targetMs: 315000, durationMs: dur, deltaMs: 1000),
        isTrue,
      );
      expect(kStepTailExactWindowMs, 10000);
    });

    test('the window is capped at half the media', () {
      // A 4 s clip cannot exact-seek every press from its head.
      expect(
        stepNeedsExactSeek(targetMs: 1000, durationMs: 4000, deltaMs: 500),
        isFalse,
      );
      expect(
        stepNeedsExactSeek(targetMs: 3000, durationMs: 4000, deltaMs: 500),
        isTrue,
      );
    });

    test('a backward step is judged by distance', () {
      expect(
        stepNeedsExactSeek(targetMs: 318000, durationMs: dur, deltaMs: -5000),
        isTrue,
      );
      expect(
        stepNeedsExactSeek(targetMs: 200000, durationMs: dur, deltaMs: -5000),
        isFalse,
      );
    });

    test('an unknown duration never forces the exact path', () {
      expect(
        stepNeedsExactSeek(targetMs: 1000, durationMs: 0, deltaMs: 3000),
        isFalse,
      );
    });

    test('a press inside the final GOP exact-steps instead of rolling back', () {
      // `reported + delta` stays inside the media, so this is not a finish —
      // but a keyframe seek cannot land there.
      expect(
        decideStepTail(
          reportedMs: 310000,
          deltaMs: 3000,
          durationMs: dur,
          mode: StepTailFinishMode.strict,
          playing: true,
        ),
        StepTailAction.exactStep,
      );
    });

    test('a press that reaches the end still finishes first', () {
      expect(
        decideStepTail(
          reportedMs: dur - 2000,
          deltaMs: 3000,
          durationMs: dur,
          mode: StepTailFinishMode.strict,
          playing: true,
        ),
        StepTailAction.finishItem,
      );
    });

    test('a backward press in the final GOP is never an exact finish', () {
      expect(
        decideStepTail(
          reportedMs: 321000,
          deltaMs: -3000,
          durationMs: dur,
          mode: StepTailFinishMode.strict,
          playing: true,
        ),
        StepTailAction.step,
      );
    });
  });

  group('shouldAcceptStepPress (media must be open before stepping)', () {
    const String a = 'file:///media/a.mp4';
    const String b = 'file:///media/b.mp4';

    test('accepts a press for the media whose open completed', () {
      expect(shouldAcceptStepPress(mediaUri: a, openedUri: a), isTrue);
    });

    test('drops a press during the switch window (the skipped-episode defect)', () {
      // The hook already holds the NEXT entry while the engine still describes
      // the previous one: `file`=b, `opened`=a. Step math would use b's identity
      // with a's duration/position (log: `end=312106ms` on the new file).
      expect(shouldAcceptStepPress(mediaUri: b, openedUri: a), isFalse);
      // Open not finished at all (first open / failure): no current demuxer.
      expect(shouldAcceptStepPress(mediaUri: a, openedUri: null), isFalse);
    });

    test('drops an empty / null media instead of stepping into nothing', () {
      expect(shouldAcceptStepPress(mediaUri: null, openedUri: null), isFalse);
      expect(shouldAcceptStepPress(mediaUri: '', openedUri: ''), isFalse);
    });
  });

  group('gateStepPress (tail finish latch)', () {
    const String a = 'file:///media/a.mp4';
    const String b = 'file:///media/b.mp4';

    test('accepts a press for the current, open media', () {
      expect(
        gateStepPress(mediaUri: a, openedUri: a, dispatchInFlight: false),
        StepPressGate.accept,
      );
    });

    test('drops every press of a burst that already finished this media', () {
      // Field log: `finish now` twice for the same file — the first dispatch
      // returned, the hook still held the old media, and the second finish
      // advanced once more (`wrapToFirst` then `provider.next`): one entry
      // skipped.
      for (int i = 0; i < 10; i++) {
        expect(
          gateStepPress(
            mediaUri: a,
            openedUri: a,
            dispatchInFlight: false,
            finishedUri: a,
          ),
          StepPressGate.dropTailFinished,
          reason: 'press ${i + 1} of the burst',
        );
      }
    });

    test('the latch belongs to ONE media', () {
      expect(
        gateStepPress(
          mediaUri: b,
          openedUri: b,
          dispatchInFlight: false,
          finishedUri: a,
        ),
        StepPressGate.accept,
      );
    });

    test('a switching media still wins over the latch check', () {
      expect(
        gateStepPress(
          mediaUri: b,
          openedUri: a,
          dispatchInFlight: false,
          finishedUri: a,
        ),
        StepPressGate.dropMediaSwitching,
      );
      expect(
        gateStepPress(
          mediaUri: a,
          openedUri: a,
          dispatchInFlight: true,
          finishedUri: null,
        ),
        StepPressGate.dropMediaSwitching,
      );
    });
  });

  group('stepTailLatchReusable (leaving the tail again)', () {
    test('keeps the latch while the picture is still at the tail', () {
      expect(stepTailLatchReusable(reportedMs: 974017, durationMs: 974271),
          isFalse);
      expect(stepTailLatchReusable(reportedMs: 974271, durationMs: 974271),
          isFalse);
    });

    test('releases it once the picture is outside the tail window', () {
      // Repeat-one restart / scrub back / jump: the same media may be finished
      // again, so the latch must not pin it forever.
      expect(stepTailLatchReusable(reportedMs: 0, durationMs: 974271), isTrue);
      expect(stepTailLatchReusable(reportedMs: 800000, durationMs: 974271),
          isTrue);
    });

    test('an unknown duration keeps the latch (nothing to compare)', () {
      expect(stepTailLatchReusable(reportedMs: 0, durationMs: 0), isFalse);
    });

    test('a short clip releases inside its OWN (capped) window', () {
      // 6 s clip: an uncapped `duration - 10 s` is negative, so position 0 was
      // "inside" the window forever and a finished short clip could never be
      // stepped or rewound again. The window is the same one the exact-seek
      // path uses — capped at half the media (3 s here).
      expect(stepTailLatchReusable(reportedMs: 0, durationMs: 6000), isTrue);
      expect(stepTailLatchReusable(reportedMs: 2900, durationMs: 6000), isTrue);
      expect(
          stepTailLatchReusable(reportedMs: 3000, durationMs: 6000), isFalse);
      expect(
          stepTailLatchReusable(reportedMs: 5900, durationMs: 6000), isFalse);
    });
  });

  group('shouldAttributeLiveProgress', () {
    const String a = 'file:///media/a.mp4';
    const String b = 'file:///media/b.mp4';

    test('accepts a sample from the media whose open completed', () {
      expect(
        shouldAttributeLiveProgress(sampleUri: a, openUri: a, latestUri: a),
        isTrue,
      );
    });

    test('drops a sample of the media being LEFT (the 串集 defect)', () {
      // Log evidence: `liveProgress key=…[ZMSFM]… hit pos=381141` right after
      // `[sodeno19]` ended there, and `progress-write [timer] 44152->6958
      // BLOCKED` — the previous file's tail would be persisted onto the next.
      expect(
        shouldAttributeLiveProgress(sampleUri: a, openUri: a, latestUri: b),
        isFalse,
        reason: 'a newer media is already bound to the hook',
      );
      expect(
        shouldAttributeLiveProgress(sampleUri: b, openUri: a, latestUri: b),
        isFalse,
        reason: 'the new media\'s open has not completed yet',
      );
    });

    test('drops a sample before any open completed', () {
      expect(
        shouldAttributeLiveProgress(sampleUri: a, openUri: null, latestUri: a),
        isFalse,
      );
    });

    test('drops an empty / null uri instead of keying on it', () {
      expect(
        shouldAttributeLiveProgress(sampleUri: null, openUri: null, latestUri: null),
        isFalse,
      );
      expect(
        shouldAttributeLiveProgress(sampleUri: '', openUri: '', latestUri: ''),
        isFalse,
      );
    });
  });

  group('playback.stepTailFinish catalog def', () {
    final def = SettingsCatalog.defs
        .singleWhere((d) => d.key == 'playback.stepTailFinish');

    test('enum values mirror the Dart enum names', () {
      expect(
          def.enumValues, StepTailFinishMode.values.map((v) => v.name).toList());
    });

    test('default is the strict (past-the-end) policy', () {
      expect(def.defaultValue, StepTailFinishMode.strict.name);
      expect(const AppState().stepTailFinishMode, StepTailFinishMode.strict);
    });

    test('is a custom row (out-of-domain AUX) with an editor key', () {
      expect(def.editorKey, isNotNull);
    });
  });

  group('resolveStepTailFinishMode', () {
    test('returns the stored mode while the metadata gate is ON', () {
      const AppState s =
          AppState(stepTailFinishMode: StepTailFinishMode.window);
      expect(
        resolveStepTailFinishMode(s, metadataEnabled: true),
        StepTailFinishMode.window,
      );
    });

    test('degrades to strict while the gate is OFF', () {
      const AppState s =
          AppState(stepTailFinishMode: StepTailFinishMode.window);
      expect(
        resolveStepTailFinishMode(s, metadataEnabled: false),
        StepTailFinishMode.strict,
      );
    });
  });

  group('playback.videoCachePreset catalog def', () {
    final def = SettingsCatalog.defs
        .singleWhere((d) => d.key == 'playback.videoCachePreset');

    test('enum values mirror the Dart enum names', () {
      expect(def.enumValues, VideoCachePreset.values.map((v) => v.name).toList());
    });

    test('default is the balanced preset', () {
      expect(def.defaultValue, VideoCachePreset.balanced.name);
    });

    test('is a custom row (out-of-domain AUX) with an editor key', () {
      expect(def.editorKey, isNotNull);
    });
  });
}
