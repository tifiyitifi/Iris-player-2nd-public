import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/services/background_lock_mapping.dart';

/// 进度锁定 (`full`) foreground→副音 mapping: a fixed offset over the
/// concatenated 副音 queue, with rollover/wrap on overflow.
void main() {
  // Queue: A 3:00, B 3:00, C 3:00  (total 9:00).
  const threeMinutes = 3 * 60 * 1000;
  final timeline = BgQueueTimeline(
    const [threeMinutes, threeMinutes, threeMinutes],
  );

  group('BgQueueTimeline', () {
    test('prefix sums and offsets', () {
      expect(timeline.totalMs, 9 * 60 * 1000);
      expect(timeline.offsetOf(0), 0);
      expect(timeline.offsetOf(1), threeMinutes);
      expect(timeline.offsetOf(2), 2 * threeMinutes);
      expect(timeline.offsetOf(99), 0);
    });

    test('locate maps a virtual position to (index, local)', () {
      expect(timeline.locate(0), (0, 0));
      expect(timeline.locate(1000), (0, 1000));
      expect(timeline.locate(threeMinutes), (1, 0),
          reason: 'boundary resolves to the later entry');
      expect(timeline.locate(threeMinutes + 500), (1, 500));
      expect(timeline.locate(9 * 60 * 1000), (2, threeMinutes),
          reason: 'past-end clamps to the last file end');
    });

    test('virtualPositionOf is the inverse of locate', () {
      expect(timeline.virtualPositionOf(1, 500), threeMinutes + 500);
      expect(timeline.virtualPositionOf(0, threeMinutes), threeMinutes);
    });

    test('unknown (zero) durations collapse without breaking offsets', () {
      final t = BgQueueTimeline(const [threeMinutes, 0, threeMinutes]);
      expect(t.totalMs, 6 * 60 * 1000);
      expect(t.locate(threeMinutes), (2, 0),
          reason: 'the 0-length entry is skipped at the boundary');
    });

    test('bgContinuationPublishable refuses an unresolved prefix', () {
      // Known through index 0 → publishable there; an unknown/zero entry inside
      // the prefix makes offsetOf() understated, so a pin built from it would be
      // WRONG — refuse until the durations resolve.
      final full = BgQueueTimeline(
        const [threeMinutes, threeMinutes, threeMinutes],
      );
      expect(bgContinuationPublishable(full, 0), isTrue);
      expect(bgContinuationPublishable(full, 2), isTrue);

      final hole = BgQueueTimeline(
        const [threeMinutes, 0, threeMinutes],
        unknownIndices: const {1},
      );
      expect(bgContinuationPublishable(hole, 0), isTrue);
      expect(bgContinuationPublishable(hole, 1), isFalse,
          reason: 'the open entry itself has no resolved duration');
      expect(bgContinuationPublishable(hole, 2), isFalse,
          reason: 'an unresolved entry sits inside the prefix');

      expect(bgContinuationPublishable(full, -1), isFalse);
    });

    test('empty timeline degrades to (0,0)', () {
      final t = BgQueueTimeline(const []);
      expect(t.isEmpty, isTrue);
      expect(t.totalMs, 0);
      expect(t.locate(1234), (0, 0));
      expect(t.virtualPositionOf(3, 999), 0);
    });
  });

  group('resolveLockTarget (fixed offset)', () {
    test('same-file seek keeps the offset', () {
      // fg 10:00, a 6:00 offset -> bg virtual 4:00 -> file B at 1:00.
      final target = resolveLockTarget(
        fgMs: 10 * 60 * 1000,
        offsetMs: 6 * 60 * 1000,
        timeline: timeline,
      );
      expect(target.fileIndex, 1);
      expect(target.localMs, 1 * 60 * 1000);
      expect(target.wrapped, isFalse);
    });

    test('a +10s/-10s skip shifts by the same amount', () {
      const offset = 6 * 60 * 1000;
      final fwd = resolveLockTarget(
        fgMs: 10 * 60 * 1000 + 10000,
        offsetMs: offset,
        timeline: timeline,
      );
      final back = resolveLockTarget(
        fgMs: 10 * 60 * 1000 - 10000,
        offsetMs: offset,
        timeline: timeline,
      );
      expect(fwd.localMs, 1 * 60 * 1000 + 10000);
      expect(back.localMs, 1 * 60 * 1000 - 10000);
    });

    test('overflow rolls forward into the next file', () {
      // fg 10:00, offset 0 -> bg virtual 10:00 -> file 3... only 3 files.
      final target = resolveLockTarget(
        fgMs: 8 * 60 * 1000,
        offsetMs: 0,
        timeline: timeline,
      );
      expect(target.fileIndex, 2);
      expect(target.localMs, 2 * 60 * 1000);
    });

    test('negative target clamps to the queue head by default', () {
      final target = resolveLockTarget(
        fgMs: 1000,
        offsetMs: 10 * 60 * 1000,
        timeline: timeline,
      );
      expect(target.fileIndex, 0);
      expect(target.localMs, 0);
      expect(target.wrapped, isFalse);
    });

    test('negative target counts BACK through the list under wrapBackward', () {
      // "fg 退格回 0" with a 5:00 offset: virtual −5:00, counted back from the
      // 9:00 list end → 4:00 → file B at 1:00 (NOT the queue head).
      final target = resolveLockTarget(
        fgMs: 0,
        offsetMs: 5 * 60 * 1000,
        timeline: timeline,
        wrapBackward: true,
      );
      expect(target.wrapped, isTrue);
      expect(target.virtualMs, 4 * 60 * 1000);
      expect(target.fileIndex, 1);
      expect(target.localMs, 1 * 60 * 1000);
    });

    test('wrapBackward is inert on a zero-length timeline', () {
      final target = resolveLockTarget(
        fgMs: 0,
        offsetMs: 1000,
        timeline: BgQueueTimeline(const [0, 0]),
        wrapBackward: true,
      );
      // No positive total to count back through: the head clamp stands.
      expect(target.virtualMs, 0);
      expect(target.wrapped, isFalse);
      expect(target.localMs, 0);
    });

    test('overflow clamps to the tail without wrap', () {
      final target = resolveLockTarget(
        fgMs: 20 * 60 * 1000,
        offsetMs: 0,
        timeline: timeline,
      );
      expect(target.fileIndex, 2);
      expect(target.localMs, threeMinutes, reason: 'clamped to the end');
      expect(target.wrapped, isFalse);
    });

    test('overflow wraps to the head under repeat-all', () {
      final target = resolveLockTarget(
        fgMs: 10 * 60 * 1000,
        offsetMs: 0,
        timeline: timeline,
        wrap: true,
      );
      expect(target.wrapped, isTrue);
      expect(target.virtualMs, 60 * 1000);
      expect(target.fileIndex, 0);
      expect(target.localMs, 60 * 1000);
    });

    test('empty timeline never throws', () {
      final target = resolveLockTarget(
        fgMs: 1234,
        offsetMs: 5678,
        timeline: BgQueueTimeline(const []),
      );
      expect(target, const BgLockTarget(0, 0, 0, false));
    });
  });

  test('bgLockTargetRolls reports a file change', () {
    const t = BgLockTarget(1, 0, 0, false);
    expect(bgLockTargetRolls(t, 1), isFalse);
    expect(bgLockTargetRolls(t, 0), isTrue);
  });
}
