import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/utils/seek_tail_guard.dart';

VirtualMediaItem _twoSeg() => VirtualMediaItem(
      ruleId: 'r',
      scopeKey: 's',
      rootPath: '/',
      displayIndex: 1,
      displayName: 'v',
      segments: const [
        VirtualSegment(
          mediaKey: 'a',
          storageId: 's',
          path: ['a.mp4'],
          name: 'a.mp4',
          parentPath: '',
          durationMs: 10000,
        ),
        VirtualSegment(
          mediaKey: 'b',
          storageId: 's',
          path: ['b.mp4'],
          name: 'b.mp4',
          parentPath: '',
          durationMs: 20000,
        ),
      ],
    );

void main() {
  group('vm past-end clamp', () {
    test('locate(total) past-end local is clamped by helper', () {
      final item = _twoSeg();
      final (idx, local) = item.locate(item.totalDurationMs);
      expect(idx, 1);
      // locate itself returns segDur at the very end; sinks must clamp.
      expect(local, 20000);
      expect(
        clampVmLocalMs(item.segments[idx].durationMs, local),
        20000 - kSeekTailGuardMs,
      );
    });

    test('helper keeps in-range values exact', () {
      expect(clampVmLocalMs(10000, 0), 0);
      expect(clampVmLocalMs(10000, 5000), 5000);
      expect(clampVmLocalMs(10000, 9899), 9899);
    });

    test('helper handles zero/unknown duration', () {
      expect(clampVmLocalMs(0, 0), 0);
      expect(clampVmLocalMs(0, 50), 0);
      expect(clampVmLocalMs(null, 50), 0);
    });

    test('helper clamps over-range to the shared tail guard', () {
      expect(clampVmLocalMs(10000, 10000), 10000 - kSeekTailGuardMs);
      expect(clampVmLocalMs(10000, 1 << 30), 10000 - kSeekTailGuardMs);
      // A value inside the guard band is pulled back to it as well.
      expect(clampVmLocalMs(10000, 9950), 10000 - kSeekTailGuardMs);
    });

    test('finishAtEnd may land ON the segment end (tail step / release)', () {
      // The one intent that must raise `completed` to advance the session: a
      // tail step while playing, or a scrub release at 100%.
      expect(
        clampVmLocalMs(20000, 20000, intent: SeekIntent.finishAtEnd),
        20000,
      );
      expect(
        clampVmLocalMs(20000, 1 << 30, intent: SeekIntent.finishAtEnd),
        20000,
      );
      // Every other caller keeps the guard, including the default.
      expect(clampVmLocalMs(20000, 1 << 30), 20000 - kSeekTailGuardMs);
    });
  });
}
