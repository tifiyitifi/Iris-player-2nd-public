import 'package:flutter_test/flutter_test.dart';
import 'package:iris/utils/seek_tail_guard.dart';

/// One media-tail policy for every seek path.
///
/// Why this exists: the ring dial stopped at `duration - 100 ms`, a step seek at
/// `duration - 1 ms`, and the shared absolute clamp allowed landing exactly ON
/// `duration`. The 1 ms figure is a rounding error, not a guard — `duration` is
/// the container duration, so `duration - 1 ms` is still inside the final GOP and
/// the engine clamps the landing backwards ("fast-forward at the tail rolls the
/// time back").
void main() {
  group('seekTailMaxMs', () {
    test('stopAtTail keeps the shared guard distance', () {
      expect(seekTailMaxMs(60000), 60000 - kSeekTailGuardMs);
    });

    test('finishAtEnd may land exactly on the duration', () {
      expect(seekTailMaxMs(60000, intent: SeekIntent.finishAtEnd), 60000);
    });

    test('an unknown duration has no reachable target', () {
      expect(seekTailMaxMs(0), 0);
      expect(seekTailMaxMs(-1), 0);
    });

    test('a media shorter than the guard keeps its full range', () {
      // Regression: 50 ms clips used to collapse to 0 and became unseekable.
      expect(seekTailMaxMs(50), 50);
      expect(seekTailMaxMs(kSeekTailGuardMs), kSeekTailGuardMs);
      expect(seekTailMaxMs(kSeekTailGuardMs + 1), 1);
    });
  });

  group('clampSeekTargetMs', () {
    test('an in-range target keeps millisecond precision', () {
      expect(clampSeekTargetMs(12345, 60000), 12345);
    });

    test('a target past the tail stops at the guard', () {
      expect(clampSeekTargetMs(60000, 60000), 60000 - kSeekTailGuardMs);
      expect(clampSeekTargetMs(1 << 30, 60000), 60000 - kSeekTailGuardMs);
    });

    test('finishAtEnd lets the exact end through', () {
      expect(
        clampSeekTargetMs(60000, 60000, intent: SeekIntent.finishAtEnd),
        60000,
      );
      expect(
        clampSeekTargetMs(1 << 30, 60000, intent: SeekIntent.finishAtEnd),
        60000,
      );
    });

    test('negative sub-second targets clamp to zero', () {
      // Regression for the inSeconds bug: Duration(-500ms).inSeconds == 0.
      expect(clampSeekTargetMs(-500, 60000), 0);
      expect(clampSeekTargetMs(-1, 60000), 0);
    });

    test('an unknown duration leaves the target alone', () {
      // Callers drop these before seeking; fabricating 0 would write a bogus
      // position over the file's saved progress.
      expect(clampSeekTargetMs(4321, 0), 4321);
      expect(clampSeekTargetMs(4321, -1), 4321);
    });

    test('a short clip is seekable inside its own range', () {
      expect(clampSeekTargetMs(40, 50), 40);
      expect(clampSeekTargetMs(999, 50), 50);
    });
  });

  group('isSeekReleaseFinish', () {
    test('a release at the very end finishes the item', () {
      expect(isSeekReleaseFinish(60000, 60000), isTrue);
    });

    test('a release just inside the 99% line finishes too', () {
      expect(isSeekReleaseFinish((60000 * 0.99).round(), 60000), isTrue);
    });

    test('a release before the 99% line does not', () {
      expect(isSeekReleaseFinish(50000, 60000), isFalse);
      expect(isSeekReleaseFinish((60000 * 0.98).round(), 60000), isFalse);
    });

    test('the head never finishes the item', () {
      expect(isSeekReleaseFinish(0, 60000), isFalse);
      expect(isSeekReleaseFinish(-10, 60000), isFalse);
    });

    test('an unknown duration never finishes the item', () {
      expect(isSeekReleaseFinish(60000, 0), isFalse);
    });

    test('a short clip finishes from its reachable tail, not 99%', () {
      // 150 ms: the live ticks stop at 50 ms (duration - guard), so anything a
      // user can actually release at would otherwise be clamped back to 50 —
      // a visible jump backwards. The release counts as "finish" instead.
      expect(isSeekReleaseFinish(50, 150), isTrue);
      expect(isSeekReleaseFinish(149, 150), isTrue);
      expect(isSeekReleaseFinish(49, 150), isFalse,
          reason: 'releasing before the reachable tail is still a normal seek');
    });

    test('normal-length media keep the 99% rule', () {
      // 1 s is above the 2x guard window, so its threshold stays 990 ms.
      expect(isSeekReleaseFinish(989, 1000), isFalse);
      expect(isSeekReleaseFinish(990, 1000), isTrue);
    });
  });

  group('vmReleaseSeekIntent (VM drag release)', () {
    test('a release at the merged item end finishes it', () {
      expect(vmReleaseSeekIntent(120000, 120000), SeekIntent.finishAtEnd);
      expect(vmReleaseSeekIntent((120000 * 0.99).round(), 120000),
          SeekIntent.finishAtEnd);
    });

    test('an ordinary VM release stays inside the tail guard', () {
      expect(vmReleaseSeekIntent(60000, 120000), SeekIntent.stopAtTail);
      expect(vmReleaseSeekIntent(0, 120000), SeekIntent.stopAtTail);
    });

    test('the virtual total is the caller axis (short merged item)', () {
      expect(vmReleaseSeekIntent(150, 150), SeekIntent.finishAtEnd);
      expect(vmReleaseSeekIntent(49, 150), SeekIntent.stopAtTail);
    });
  });
}
