import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/meta_settings/contributions/settings_catalog.dart';
import 'package:iris/features/meta_settings/engine/video_cache_preset.dart';
import 'package:iris/hooks/player/seek_tuning.dart';
import 'package:iris/models/enums/video_cache_preset.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/utils/live_seek_throttle.dart';

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
      // The lock unlocks on the first ±2s landing sample (isLandingAt), so
      // during a rapid burst its target is often already gone; the step
      // intent must keep accumulating regardless.
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
        'sits still (hr-seek=no keyframe snap-back)', () {
      final i = StepIntent();
      // 60fps file, keyint=250 → ~4.17s GOP: every 4s step lands on the SAME
      // keyframe, so the engine reports an unmoved position on every repeat.
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
      // Lock already unlocked (landing tolerance fired) and the engine is
      // still sitting on the previous keyframe.
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

    test('note replaces the previous target', () {
      final i = StepIntent()..note(9000)..note(13000);
      expect(i.lastMs, 13000);
    });
  });

  group('StepBurst', () {
    test('a lone press never counts as rapid', () {
      final b = StepBurst(window: const Duration(milliseconds: 400));
      final DateTime t0 = DateTime(2026);
      expect(b.note(t0), isFalse);
      expect(b.isRapid, isFalse);
    });

    test('a second press inside the window makes the burst rapid', () {
      final b = StepBurst(window: const Duration(milliseconds: 400));
      final DateTime t0 = DateTime(2026);
      b.note(t0);
      expect(b.note(t0.add(const Duration(milliseconds: 120))), isTrue);
      expect(b.isRapid, isTrue);
    });

    test('a slow follow-up press stays on the exact path', () {
      final b = StepBurst(window: const Duration(milliseconds: 400));
      final DateTime t0 = DateTime(2026);
      b.note(t0);
      expect(b.note(t0.add(const Duration(milliseconds: 900))), isFalse);
    });

    test('reset clears the burst so the next press is a fresh start', () {
      final b = StepBurst(window: const Duration(milliseconds: 400));
      final DateTime t0 = DateTime(2026);
      b.note(t0);
      b.note(t0.add(const Duration(milliseconds: 50)));
      expect(b.isRapid, isTrue);
      b.reset();
      expect(b.isRapid, isFalse);
      expect(b.note(t0.add(const Duration(milliseconds: 60))), isFalse);
    });
  });

  group('burst seek precision', () {
    test('a step burst never relaxes mpv precise seeking', () {
      // mpv's keyframe seek (`hr-seek=no`) lands on the keyframe BEFORE the
      // target, so a held / continuously re-tapped ←/→ replays the previous
      // GOP in place instead of advancing the progress (the 回跳重播 defect).
      // The 120ms engine-seek throttle + hr-seek-framedrop=yes already fix the
      // original "frozen, then one big jump" symptom, so the toggle stays off.
      expect(kStepBurstRelaxesPreciseSeek, isFalse);
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

  group('isStepLanded', () {
    test('forward: at/past the target within tolerance counts as landed', () {
      expect(isStepLanded(posMs: 3000, targetMs: 3000, forward: true), isTrue);
      expect(isStepLanded(posMs: 2600, targetMs: 3000, forward: true), isTrue);
      expect(isStepLanded(posMs: 2599, targetMs: 3000, forward: true), isFalse);
      // Playback continued past the target after the seek landed.
      expect(isStepLanded(posMs: 9000, targetMs: 3000, forward: true), isTrue);
    });

    test('backward: at/before the target within tolerance counts as landed', () {
      expect(isStepLanded(posMs: 3000, targetMs: 3000, forward: false), isTrue);
      expect(isStepLanded(posMs: 3400, targetMs: 3000, forward: false), isTrue);
      expect(isStepLanded(posMs: 3401, targetMs: 3000, forward: false), isFalse);
      expect(isStepLanded(posMs: 0, targetMs: 3000, forward: false), isTrue);
    });
  });

  group('StepSeekChain', () {
    final DateTime t0 = DateTime(2026);

    test('issues one target at a time', () {
      final c = StepSeekChain();
      expect(c.takeNext(t0), isNull);
      c.push(1000, engineTargetMs: 1000, forward: true);
      final first = c.takeNext(t0);
      expect(first?.targetMs, 1000);
      expect(c.hasInFlight, isTrue);
      // A queued target never goes out while one is still in flight.
      c.push(2000, engineTargetMs: 2000, forward: true);
      expect(c.pendingCount, 1);
      expect(c.takeNext(t0), isNull);
    });

    test('a landed target releases the next queued one in order', () {
      final c = StepSeekChain();
      c.push(1000, engineTargetMs: 1000, forward: true);
      c.push(2000, engineTargetMs: 2000, forward: true);
      expect(c.takeNext(t0)?.targetMs, 1000);
      expect(c.notePosition(1000), isTrue);
      expect(c.hasInFlight, isFalse);
      expect(c.takeNext(t0)?.targetMs, 2000);
    });

    test('a pre-landing report does not count', () {
      final c = StepSeekChain();
      c.push(6000, engineTargetMs: 6000, forward: true);
      c.takeNext(t0);
      expect(c.notePosition(3000), isFalse);
      expect(c.inFlightMs, 6000);
      expect(c.notePosition(6000), isTrue);
    });

    test('backward steps land on the lower side', () {
      final c = StepSeekChain();
      c.push(4000, engineTargetMs: 4000, forward: false);
      c.takeNext(t0);
      expect(c.notePosition(4401), isFalse);
      expect(c.notePosition(4000), isTrue);
    });

    test('the landing check uses the ENGINE axis, not the virtual one', () {
      // Virtual media: the caller re-enters seek() with the VIRTUAL target
      // while the engine lands on the segment-local position.
      final c = StepSeekChain();
      c.push(60000, engineTargetMs: 5000, forward: true);
      expect(c.takeNext(t0)?.targetMs, 60000);
      expect(c.notePosition(5000), isTrue);
    });

    test('the oldest pending target is dropped when the input outpaces', () {
      final c = StepSeekChain(maxPending: 3);
      c.push(1000, engineTargetMs: 1000, forward: true);
      expect(c.takeNext(t0)?.targetMs, 1000);
      for (int i = 2; i <= 5; i++) {
        c.push(i * 1000, engineTargetMs: i * 1000, forward: true);
      }
      expect(c.pendingCount, 3);
      c.notePosition(1000);
      // 2000 (the oldest queue entry) was dropped; 3000 goes out next.
      expect(c.takeNext(t0)?.targetMs, 3000);
    });

    test('a landing is only reported once', () {
      final c = StepSeekChain();
      c.push(1000, engineTargetMs: 1000, forward: true);
      c.takeNext(t0);
      expect(c.notePosition(1000), isTrue);
      expect(c.notePosition(1200), isFalse);
    });

    test('the hard timeout releases a landing that never arrives', () {
      final c = StepSeekChain(hardTimeout: const Duration(milliseconds: 1200));
      c.push(1000, engineTargetMs: 1000, forward: true);
      c.push(2000, engineTargetMs: 2000, forward: true);
      c.takeNext(t0);
      expect(c.tickTimeout(t0.add(const Duration(milliseconds: 900))), isFalse);
      expect(c.tickTimeout(t0.add(const Duration(milliseconds: 1200))), isTrue);
      expect(c.hasInFlight, isFalse);
      expect(c.takeNext(t0)?.targetMs, 2000);
    });

    test('isEmpty tracks the queue and the in-flight target', () {
      final c = StepSeekChain();
      expect(c.isEmpty, isTrue);
      c.push(1000, engineTargetMs: 1000, forward: true);
      expect(c.isEmpty, isFalse);
      c.takeNext(t0);
      expect(c.isEmpty, isFalse);
      c.notePosition(1000);
      expect(c.isEmpty, isTrue);
    });

    test('reset clears the queue and the in-flight expectation', () {
      final c = StepSeekChain();
      c.push(1000, engineTargetMs: 1000, forward: true);
      c.push(2000, engineTargetMs: 2000, forward: true);
      c.takeNext(t0);
      c.reset();
      expect(c.isEmpty, isTrue);
      expect(c.notePosition(1000), isFalse);
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

  group('saneStepBurstPos', () {
    test('seeds from raw when nothing was shown yet', () {
      expect(
        saneStepBurstPos(
            raw: 1000, lastShown: null, forward: true, durationMs: 10000),
        1000,
      );
    });

    test('a forward burst never moves the shown position backwards', () {
      // Engine reports the previous frame while decoding toward the target.
      expect(
        saneStepBurstPos(
            raw: 2000, lastShown: 5000, forward: true, durationMs: 20000),
        5000,
      );
    });

    test('a forward burst accepts forward progress (playback past target)', () {
      expect(
        saneStepBurstPos(
            raw: 8000, lastShown: 5000, forward: true, durationMs: 20000),
        8000,
      );
    });

    test('a backward burst never moves the shown position forwards', () {
      expect(
        saneStepBurstPos(
            raw: 9000, lastShown: 5000, forward: false, durationMs: 20000),
        5000,
      );
      expect(
        saneStepBurstPos(
            raw: 2000, lastShown: 5000, forward: false, durationMs: 20000),
        2000,
      );
    });

    test('clamps into the media when the duration is known', () {
      expect(
        saneStepBurstPos(
            raw: 30000, lastShown: 5000, forward: true, durationMs: 20000),
        20000,
      );
    });
  });

  group('stepLandingDwell', () {
    test('keeps the landed-frame dwell while nothing is queued', () {
      expect(stepLandingDwell(0), kStepLandedDwell);
    });

    test('drops the dwell the moment a backlog is waiting', () {
      expect(stepLandingDwell(1), Duration.zero);
      expect(stepLandingDwell(3), Duration.zero);
    });
  });

  group('StepSeekChain no-drop mode', () {
    final DateTime t0 = DateTime(2026);

    test('adaptive (dropOldest=false) swallows no press', () {
      final c = StepSeekChain(maxPending: 3)..dropOldest = false;
      c.push(1000, engineTargetMs: 1000, forward: true);
      expect(c.takeNext(t0)?.targetMs, 1000);
      for (int i = 2; i <= 8; i++) {
        c.push(i * 1000, engineTargetMs: i * 1000, forward: true);
      }
      expect(c.pendingCount, 7, reason: 'nothing dropped');
      // Drain in order: 2000 first.
      expect(c.takeNext(t0), isNull, reason: 'one in flight');
      c.notePosition(1000);
      expect(c.takeNext(t0)?.targetMs, 2000);
    });

    test('serialized (dropOldest=true) still drops the oldest', () {
      final c = StepSeekChain(maxPending: 3);
      c.push(1000, engineTargetMs: 1000, forward: true);
      c.takeNext(t0);
      for (int i = 2; i <= 5; i++) {
        c.push(i * 1000, engineTargetMs: i * 1000, forward: true);
      }
      expect(c.pendingCount, 3);
      c.notePosition(1000);
      expect(c.takeNext(t0)?.targetMs, 3000);
    });

    test('exposes inFlightSince for issue->landed latency', () {
      final c = StepSeekChain();
      expect(c.inFlightSince, isNull);
      c.push(1000, engineTargetMs: 1000, forward: true);
      c.takeNext(t0);
      expect(c.inFlightSince, t0);
      c.notePosition(1000);
      expect(c.inFlightSince, isNull);
    });
  });

  group('StepSeekChain release collapse', () {
    final DateTime t0 = DateTime(2026);

    test('collapses a held burst to its newest target', () {
      final c = StepSeekChain(maxPending: 3)..dropOldest = false;
      c.push(1000, engineTargetMs: 1000, forward: true);
      c.takeNext(t0);
      for (int i = 2; i <= 8; i++) {
        c.push(i * 1000, engineTargetMs: i * 1000, forward: true);
      }
      final collapsed = c.collapseOnRelease();
      // The returned target is the LAST press on the caller axis — the exact
      // value noteStepSeek armed and the OSD reads. This is the OSD invariant.
      expect(collapsed?.targetMs, 8000);
      expect(collapsed?.engineTargetMs, 8000);
      expect(c.pendingCount, 1, reason: 'only the final target survives');
      expect(c.isEmpty, isFalse);
    });

    test('the collapsed target is handed out once so the walk ends', () {
      final c = StepSeekChain()..dropOldest = false;
      c.push(1000, engineTargetMs: 1000, forward: true);
      c.takeNext(t0);
      c.push(2000, engineTargetMs: 2000, forward: true);
      c.push(3000, engineTargetMs: 3000, forward: true);
      expect(c.collapseOnRelease()?.targetMs, 3000);
      // Re-issued immediately (supersedes the in-flight older target).
      expect(c.takeNext(t0)?.targetMs, 3000);
      expect(c.pendingCount, 0);
      // Landing clears the chain -> normal playback resumes.
      expect(c.notePosition(3000), isTrue);
      expect(c.isEmpty, isTrue);
    });

    test('null when the in-flight target already is the newest', () {
      final c = StepSeekChain();
      expect(c.collapseOnRelease(), isNull, reason: 'empty chain');
      c.push(1000, engineTargetMs: 1000, forward: true);
      c.takeNext(t0);
      expect(c.collapseOnRelease(), isNull,
          reason: 'nothing newer queued than the in-flight target');
      // The in-flight seek is left alone to land.
      expect(c.inFlightMs, 1000);
      expect(c.notePosition(1000), isTrue);
    });

    test('works in serialized (dropOldest=true) mode too', () {
      final c = StepSeekChain(maxPending: 3);
      c.push(1000, engineTargetMs: 1000, forward: true);
      c.takeNext(t0);
      for (int i = 2; i <= 5; i++) {
        c.push(i * 1000, engineTargetMs: i * 1000, forward: true);
      }
      expect(c.pendingCount, 3);
      expect(c.collapseOnRelease()?.targetMs, 5000);
      expect(c.pendingCount, 1);
      expect(c.takeNext(t0)?.targetMs, 5000);
    });

    test('keeps the final VIRTUAL target while the engine axis stays local', () {
      // Virtual media: the collapse re-issues the caller (virtual) target so
      // seek() re-decomposes it; the landing check keeps the engine axis.
      final c = StepSeekChain()..dropOldest = false;
      c.push(60000, engineTargetMs: 5000, forward: true);
      c.takeNext(t0);
      c.push(70000, engineTargetMs: 6000, forward: true);
      expect(c.collapseOnRelease()?.targetMs, 70000);
      expect(c.takeNext(t0)?.engineTargetMs, 6000);
      expect(c.notePosition(6000), isTrue);
    });
  });
}
