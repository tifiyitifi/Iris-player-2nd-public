import 'package:flutter_test/flutter_test.dart';
import 'package:iris/hooks/player/use_fvp_player.dart';

/// The fvp backend has no mpv-native relative keyframe seek, so a STEP seek
/// (← / → / double-tap) must go through the fvp controller extension's
/// per-seek keyframe path (`fastSeekTo`, mdk `SeekFlag.keyFrame`). Every other
/// caller (scrub / dial / resume / lock-retry) needs the exact landing.
void main() {
  test('step seeks use the fvp keyframe ("fast") seek', () {
    expect(fvpStepUsesKeyframeSeek('step'), isTrue);
  });

  test('every other caller keeps the exact seek', () {
    for (final src in <String>[
      'player',
      'dial-tap',
      'dial-commit',
      'release-commit',
      'resume',
      'lock-retry',
      '',
    ]) {
      expect(fvpStepUsesKeyframeSeek(src), isFalse, reason: 'src=$src');
    }
  });

  // A step must NOT arm the position-intent lock. The lock demands the player be
  // OBSERVED within ±2s of the requested target before writes resume, but a
  // keyframe landing deliberately differs from it — on a long GOP by seconds.
  // Missing that window made the 1s tick re-issue an EXACT seek 5s later (a
  // visible jump) and held the progress write for up to 10s. media_kit already
  // skips the lock for a step; fvp armed it unconditionally.
  test('a step seek does not arm the position lock', () {
    expect(fvpShouldArmPositionLock('step'), isFalse);
  });

  test('every absolute seek still arms the position lock', () {
    for (final src in <String>[
      'player',
      'dial-tap',
      'dial-commit',
      'release-commit',
      'resume',
      'lock-retry',
      '',
    ]) {
      expect(fvpShouldArmPositionLock(src), isTrue, reason: 'src=$src');
    }
  });

  // The persisted position must never run ahead of the picture. fvp's step
  // uses a KEYFRAME seek, so it lands BEHIND the requested target; persisting
  // the target (the old behavior) made a kill inside a step burst resume to a
  // frame that was never shown. media_kit already persists the observed
  // position for a step, so fvp must match it.
  test('a step persists the observed position, not the requested target', () {
    expect(
      fvpPersistedSeekMs(src: 'step', targetMs: 90000, observedMs: 84000),
      84000,
    );
  });

  test('every other seek persists its requested target', () {
    for (final src in <String>[
      'player',
      'dial-tap',
      'dial-commit',
      'release-commit',
      'resume',
      'lock-retry',
      '',
    ]) {
      expect(
        fvpPersistedSeekMs(src: src, targetMs: 90000, observedMs: 84000),
        90000,
        reason: 'src=$src',
      );
    }
  });

  // mdk keeps mpv's forward-only contract for an IN-RANGE key-frame target, but
  // answers a target it cannot reach with "the last key frame of media"
  // (`generated_bindings` `seek` doc). That substitution is the visible tail
  // rollback, so a step landing in the tail must take the EXACT path instead.
  group('fvp step tail (fvpStepNeedsExactSeek)', () {
    const int dur = 60000;

    test('a mid-file step keeps the fast key-frame seek', () {
      expect(
        fvpStepNeedsExactSeek(targetMs: 30000, durationMs: dur, deltaMs: 5000),
        isFalse,
      );
    });

    test('a step reaching the tail switches to the exact seek', () {
      // 55s + 5s lands on the final second: a key-frame landing there can only be
      // the media's last key frame.
      expect(
        fvpStepNeedsExactSeek(targetMs: 59900, durationMs: dur, deltaMs: 5000),
        isTrue,
      );
      expect(
        fvpStepNeedsExactSeek(targetMs: 58000, durationMs: dur, deltaMs: 5000),
        isTrue,
      );
    });

    test('the window is at least one step long', () {
      // A large step reaches further back: 45s + 12s → 57s, still "this press
      // reaches the end area", so it must not be served from a key frame.
      expect(
        fvpStepNeedsExactSeek(targetMs: 57000, durationMs: dur, deltaMs: 12000),
        isTrue,
      );
    });

    test('a short step next to a long final GOP still switches', () {
      // Floor of kFvpStepTailExactWindowMs: a 1 s step at 58.5 s.
      expect(
        fvpStepNeedsExactSeek(targetMs: 58500, durationMs: dur, deltaMs: 1000),
        isTrue,
      );
      expect(kFvpStepTailExactWindowMs, greaterThan(1000));
    });

    test('a backward step is judged by distance, not direction', () {
      expect(
        fvpStepNeedsExactSeek(targetMs: 59200, durationMs: dur, deltaMs: -5000),
        isTrue,
      );
      expect(
        fvpStepNeedsExactSeek(targetMs: 20000, durationMs: dur, deltaMs: -5000),
        isFalse,
      );
    });

    test('an unknown duration never forces the exact path', () {
      expect(
        fvpStepNeedsExactSeek(targetMs: 1000, durationMs: 0, deltaMs: 5000),
        isFalse,
      );
    });
  });
}
