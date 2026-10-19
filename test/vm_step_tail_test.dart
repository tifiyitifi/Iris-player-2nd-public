import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/hooks/player/seek_tuning.dart';

/// The VM step seek must share the segment's "last SEEKABLE ms" contract with
/// [clampVmLocalMs]: landing ON `segDur` fires an instant `completed`.
///
/// The OSD (virtual axis) and the persisted target (segment-local) both go
/// through `clampVmLocalMs` (`segDur - 1`), while the delta handed to the engine
/// used to be bounded by the raw `segDur` — a tail step could therefore land on
/// the end the other two deliberately avoid.
void main() {
  group('vmLastSeekableMs', () {
    test('is one ms short of the segment duration', () {
      expect(vmLastSeekableMs(600000), 599999);
    });

    test('a zero/unknown duration has no seekable ms', () {
      expect(vmLastSeekableMs(0), 0);
      expect(vmLastSeekableMs(null), 0);
    });

    test('agrees with clampVmLocalMs at the tail', () {
      const segDur = 10000;
      expect(clampVmLocalMs(segDur, 1 << 30), vmLastSeekableMs(segDur));
    });
  });

  group('a VM tail step never lands on segDur', () {
    const segDur = 10000;
    final bound = vmLastSeekableMs(segDur);

    test('a forward step at the tail stays inside the segment', () {
      final sent = stepSeekSentDelta(
          reportedMs: 9500, deltaMs: 5000, durationMs: bound);
      // The engine lands where the OSD / persisted target do: segDur - 1.
      expect(9500 + sent, bound);
      expect(9500 + sent, lessThan(segDur));
    });

    test('a step exactly onto the end is clamped one ms short', () {
      final sent = stepSeekSentDelta(
          reportedMs: 9000, deltaMs: 1000, durationMs: bound);
      expect(9000 + sent, bound);
    });

    test('the OSD target agrees with the sent landing', () {
      final sent = stepSeekSentDelta(
          reportedMs: 9000, deltaMs: 1000, durationMs: bound);
      final osd = stepSeekTargetMs(
          reportedMs: 9000, deltaMs: 1000, durationMs: bound);
      expect(osd, 9000 + sent);
    });
  });
}
