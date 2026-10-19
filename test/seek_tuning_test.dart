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

    test('agrees with the delta handed to the engine for every sample', () {
      const int dur = 60000;
      for (final int reported in [-9000, -1, 0, 1000, 30000, 59000, 60000, 61000]) {
        for (final int delta in [-8000, -3000, 3000, 8000]) {
          final int nominal = stepSeekTargetMs(
              reportedMs: reported, deltaMs: delta, durationMs: dur);
          final int sent = stepSeekSentDelta(
              reportedMs: reported, deltaMs: delta, durationMs: dur);
          expect(
            nominal - reported.clamp(0, dur),
            sent,
            reason: 'reported=$reported delta=$delta',
          );
        }
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

    test('never sends the engine past the end', () {
      expect(
        stepSeekSentDelta(reportedMs: 59000, deltaMs: 3000, durationMs: 60000),
        1000,
      );
    });

    test('is 0 while the duration is unknown', () {
      expect(
        stepSeekSentDelta(reportedMs: 5000, deltaMs: 3000, durationMs: 0),
        0,
      );
    });
  });

  group('single-file tail step (lastSeekableMs)', () {
    test('is one ms short of the media duration', () {
      expect(lastSeekableMs(60000), 59999);
    });

    test('a zero/unknown duration has no seekable ms', () {
      expect(lastSeekableMs(0), 0);
      expect(lastSeekableMs(null), 0);
    });

    test('a forward step at the tail never lands on the duration', () {
      const dur = 10000;
      final bound = lastSeekableMs(dur);
      final sent =
          stepSeekSentDelta(reportedMs: 9500, deltaMs: 5000, durationMs: bound);
      final landing = 9500 + sent;
      expect(landing, bound);
      expect(landing, lessThan(dur),
          reason: 'landing ON duration fires an instant completed');
    });

    test('the OSD target agrees with the sent landing at the tail', () {
      const dur = 10000;
      final bound = lastSeekableMs(dur);
      final sent =
          stepSeekSentDelta(reportedMs: 9000, deltaMs: 5000, durationMs: bound);
      final osd =
          stepSeekTargetMs(reportedMs: 9000, deltaMs: 5000, durationMs: bound);
      expect(osd, 9000 + sent);
      expect(osd, lessThan(dur));
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
