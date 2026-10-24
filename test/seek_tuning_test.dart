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
        StepIntent().baseFor(reportedMs: 1000, lockIntentMs: null),
        1000,
      );
    });

    test('prefers the step intent over the position-lock intent', () {
      // The lock unlocks on the first ±2s landing sample, so during a rapid
      // burst its target is often already gone; the step intent must keep
      // accumulating regardless.
      final i = StepIntent()..note(5000);
      expect(i.baseFor(reportedMs: 1000, lockIntentMs: 5000), 5000);
      expect(i.baseFor(reportedMs: 1000, lockIntentMs: null), 5000);
    });

    test('keeps the lock intent when no step has been recorded yet', () {
      expect(
        StepIntent().baseFor(reportedMs: 1000, lockIntentMs: 7000),
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
        target = i.baseFor(reportedMs: reported, lockIntentMs: null) + step;
        i.note(target);
        expect(target, reported + step * press, reason: 'press $press');
      }
    });

    test('a lock that unlocks mid-burst does not rewind the accumulation', () {
      final i = StepIntent()..note(489583);
      // Lock already unlocked and the engine is still sitting on its previous
      // landing.
      expect(i.baseFor(reportedMs: 485566, lockIntentMs: null) + step, 493583);
      i.note(493583);
      expect(i.baseFor(reportedMs: 485583, lockIntentMs: null) + step, 497583);
    });

    test('reset drops the accumulation so an absolute seek restarts it', () {
      final i = StepIntent()..note(9000);
      i.reset();
      expect(i.lastMs, isNull);
      expect(i.baseFor(reportedMs: 1200, lockIntentMs: null), 1200);
    });

    test('an inactive burst ignores the stale accumulation', () {
      // Burst ended (no press inside the window): the engine has played past
      // the recorded target, so the next press must anchor on the live
      // position — the default (active) would jump back to the old target.
      final i = StepIntent()..note(9000);
      expect(i.baseFor(reportedMs: 400000, lockIntentMs: null, active: false),
          400000);
      expect(i.baseFor(reportedMs: 400000, lockIntentMs: null), 9000);
    });

    test('an inactive burst still honours the in-flight lock intent', () {
      // The lock target is the seek actually in flight, so it stays the base
      // even once the burst flag has cleared.
      final i = StepIntent()..note(9000);
      expect(
        i.baseFor(reportedMs: 1000, lockIntentMs: 5000, active: false),
        5000,
      );
    });

    test('note replaces the previous target', () {
      final i = StepIntent()..note(9000)..note(13000);
      expect(i.lastMs, 13000);
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
      // Just outside the window (4 s step => 4 s window) stays a step.
      expect(
        stepFinishesItem(
            reportedMs: dur - 9000,
            deltaMs: 4000,
            durationMs: dur,
            mode: StepTailFinishMode.window),
        isFalse,
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

  group('MpvSeekTailState (mpv playloop parity for a tail press)', () {
    const int end = 381141;
    const String evelyn = 'file:///media/evelyn.mp4';
    const String next = 'file:///media/next.mp4';

    test('the first tail press owns the finish', () {
      final s = MpvSeekTailState();
      expect(s.armed, isFalse);
      expect(s.armFirstPress(evelyn, end), isTrue);
      expect(s.armed, isTrue);
      expect(s.endMs, end);
      expect(s.armedUri, evelyn);
    });

    test('a held key / rapid taps do NOT queue another seek', () {
      // The regression this class exists for: every repeat used to issue an
      // absolute `seek <duration>`, and mpv's `handle_eof()` returns while a
      // seek is queued (`player/playloop.c:1247-1250`), so EOF never happened
      // and the picture parked at the tail until the key was released.
      final s = MpvSeekTailState();
      expect(s.armFirstPress(evelyn, end), isTrue);
      for (int i = 0; i < 40; i++) {
        expect(s.armFirstPress(evelyn, end), isFalse,
            reason: 'press ${i + 2} must be swallowed (mpv drops the queued seek)');
      }
    });

    test('the EOF collapse runs exactly once per armed media', () {
      final s = MpvSeekTailState()..armFirstPress(evelyn, end);
      expect(s.consumeCollapse(mediaUri: evelyn), isTrue);
      // A late second caller (timer + a racing press) must not advance again.
      expect(s.consumeCollapse(mediaUri: evelyn), isFalse);
      expect(s.consumeCollapse(mediaUri: evelyn), isFalse);
    });

    test('a finish never collapses the entry that replaced it', () {
      // `.ai_knowledge/tmp/seeK/seekaftempvlog.txt`: the arm belonged to the
      // previous file, the queue advanced, and the same window's re-arm collapsed
      // the freshly opened entry (pos=311750/dur=312106 were the OLD file's).
      final s = MpvSeekTailState()..armFirstPress(evelyn, end);
      expect(s.consumeCollapse(mediaUri: next), isFalse,
          reason: 'the arm belongs to another media — mpv cleared it at the switch');
      // …and the legitimate owner still collapses.
      expect(s.consumeCollapse(mediaUri: evelyn), isTrue);
    });

    test('nothing collapses while no tail press is armed', () {
      expect(MpvSeekTailState().consumeCollapse(mediaUri: evelyn), isFalse);
    });

    test('a reset (media change / rewind / completed) re-arms the same media', () {
      final s = MpvSeekTailState()..armFirstPress(evelyn, end);
      expect(s.consumeCollapse(mediaUri: evelyn), isTrue);
      s.reset();
      expect(s.armed, isFalse);
      expect(s.armedUri, isNull);
      // Repeat-one loops the SAME media: a reset must allow a new finish.
      expect(s.armFirstPress(evelyn, end), isTrue);
      expect(s.consumeCollapse(mediaUri: evelyn), isTrue);
    });

    test('a second tail press with a revised end is still swallowed', () {
      // The duration stream can be revised while the finish is pending; mpv
      // drops the queued seek regardless of its new target, so the arm must
      // survive a changed caller-axis end (a re-arm would queue a second
      // finish for the same media).
      final s = MpvSeekTailState()..armFirstPress(evelyn, end);
      expect(s.armFirstPress(evelyn, end + 5000), isFalse);
      expect(s.endMs, end);
    });

    test('the EOF window is mpv\'s 0.3 s seek window', () {
      // `MPSEEK_FLAG_DELAY` (player/playloop.c:521-525) waits for one frame /
      // one seek result before the next seek; the EOF verdict arrives on that
      // same restart.
      expect(kMpvSeekEofWindow, const Duration(milliseconds: 300));
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
