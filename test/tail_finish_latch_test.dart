import 'package:flutter_test/flutter_test.dart';
import 'package:iris/hooks/player/tail_finish_latch.dart';

/// One finish per ITEM, not per file: a Virtual-Media session plays several
/// segments of the same physical file, so a uri-only latch swallowed the next
/// segment's `completed` (the session stalled). The latch must also be released
/// on the CALLER axis — it is armed by a press judged against the merged
/// timeline.
void main() {
  const String a = 'content://v/a.mp4';
  const String b = 'content://v/b.mp4';

  group('TailFinishLatch', () {
    test('an unarmed latch covers nothing', () {
      final latch = TailFinishLatch();
      expect(latch.isArmed, isFalse);
      expect(latch.covers(uri: a, segmentIndex: null), isFalse);
      expect(latch.uriFor(uri: a, segmentIndex: null), isNull);
    });

    test('covers exactly the item that was finished', () {
      final latch = TailFinishLatch()..arm(uri: a, segmentIndex: 2);
      expect(latch.covers(uri: a, segmentIndex: 2), isTrue);
      expect(latch.uriFor(uri: a, segmentIndex: 2), a);
      // Same file, next VM segment: a DIFFERENT item (its completed must pass).
      expect(latch.covers(uri: a, segmentIndex: 3), isFalse);
      // Leaving the session: the physical item is the file itself again.
      expect(latch.covers(uri: a, segmentIndex: null), isFalse);
      expect(latch.covers(uri: b, segmentIndex: 2), isFalse);
    });

    test('a rewind off the tail releases it (caller axis)', () {
      final latch = TailFinishLatch()..arm(uri: a, segmentIndex: 0);
      // Merged item: 600 s total, this press finished the tail.
      expect(
        latch.releaseIfSpent(
          uri: a,
          segmentIndex: 0,
          positionMs: 598000,
          durationMs: 600000,
        ),
        isFalse,
      );
      // Rewound to 10 s of the merged timeline → outside the tail window.
      expect(
        latch.releaseIfSpent(
          uri: a,
          segmentIndex: 0,
          positionMs: 10000,
          durationMs: 600000,
        ),
        isTrue,
      );
      expect(latch.isArmed, isFalse);
    });

    test('an item change releases it', () {
      final latch = TailFinishLatch()..arm(uri: a, segmentIndex: 1);
      expect(
        latch.releaseIfSpent(
          uri: a,
          segmentIndex: 2,
          positionMs: 0,
          durationMs: 600000,
        ),
        isTrue,
      );
    });

    test('a short item is released by geometry too (capped window)', () {
      final latch = TailFinishLatch()..arm(uri: a, segmentIndex: null);
      // 6 s item, rewind to the head: the uncapped 10 s window never released
      // it, so the finished clip could not be stepped or rewound again.
      expect(
        latch.releaseIfSpent(
          uri: a,
          segmentIndex: null,
          positionMs: 0,
          durationMs: 6000,
        ),
        isTrue,
      );
    });
  });
}
