import 'package:flutter_test/flutter_test.dart';
import 'package:iris/hooks/player/seek_clamp.dart';
import 'package:iris/utils/seek_tail_guard.dart';

void main() {
  group('clampSeekTarget', () {
    test('negative sub-second seek clamps to zero', () {
      expect(
        clampSeekTarget(
          const Duration(milliseconds: -500),
          const Duration(seconds: 100),
        ),
        Duration.zero,
      );
    });

    test('seek beyond total stops at the shared tail guard', () {
      expect(
        clampSeekTarget(
          const Duration(milliseconds: 100501),
          const Duration(milliseconds: 100000),
        ),
        Duration(milliseconds: 100000 - kSeekTailGuardMs),
      );
    });

    test('in-range seek keeps millisecond precision', () {
      expect(
        clampSeekTarget(
          const Duration(milliseconds: 12345),
          const Duration(milliseconds: 100000),
        ),
        const Duration(milliseconds: 12345),
      );
    });

    test('sub-second negative near zero does not leak through', () {
      // Regression for the inSeconds bug: Duration(-500ms).inSeconds == 0,
      // so a seconds-based comparison missed it entirely.
      final target = clampSeekTarget(
        const Duration(milliseconds: -1),
        const Duration(milliseconds: 60000),
      );
      expect(target, Duration.zero);
    });

    test('an exact-total seek stops short by default', () {
      // Landing exactly ON the duration raises `completed` immediately. Only an
      // explicit "finish this item" may do that.
      expect(
        clampSeekTarget(
          const Duration(milliseconds: 60000),
          const Duration(milliseconds: 60000),
        ),
        Duration(milliseconds: 60000 - kSeekTailGuardMs),
      );
    });

    test('finishAtEnd keeps an exact-total seek intact', () {
      expect(
        clampSeekTarget(
          const Duration(milliseconds: 60000),
          const Duration(milliseconds: 60000),
          intent: SeekIntent.finishAtEnd,
        ),
        const Duration(milliseconds: 60000),
      );
    });
  });

  group('clampPositionToMedia', () {
    test('an in-range position is untouched', () {
      expect(
        clampPositionToMedia(
          const Duration(milliseconds: 12000),
          const Duration(milliseconds: 60000),
        ),
        const Duration(milliseconds: 12000),
      );
    });

    test('a position past the media is bounded', () {
      // mpv reports the seek target as `time-pos` while a seek is in flight, and
      // a step seek forwards an unclamped delta.
      expect(
        clampPositionToMedia(
          const Duration(milliseconds: 64500),
          const Duration(milliseconds: 60000),
        ),
        const Duration(milliseconds: 60000),
      );
    });

    test('a negative position clamps to zero', () {
      expect(
        clampPositionToMedia(
          const Duration(milliseconds: -10),
          const Duration(milliseconds: 60000),
        ),
        Duration.zero,
      );
    });

    test('an unknown duration leaves the position alone', () {
      expect(
        clampPositionToMedia(
          const Duration(milliseconds: 10),
          Duration.zero,
        ),
        const Duration(milliseconds: 10),
      );
    });
  });
}
