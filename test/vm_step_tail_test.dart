import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/hooks/player/seek_tuning.dart';
import 'package:iris/models/enums/step_tail_finish_mode.dart';
import 'package:iris/utils/seek_tail_guard.dart';

/// A Virtual-Media item is ONE file to the user: stepping must never be pinned
/// inside a segment, and a press that reaches the merged item's END must finish
/// the item (the tail policy) instead of being parked in the last segment's
/// final GOP.
///
/// The segment tail still bounds what the OSD and the persisted position may
/// claim ([clampVmLocalMs] → `segDur - kSeekTailGuardMs`, so nothing lands ON
/// `segDur` and fires an instant `completed`) for every caller EXCEPT an
/// explicit `finishAtEnd` — the tail step while playing is exactly that caller.
/// A target belonging to ANOTHER segment never reaches the relative path
/// anyway: `resolveRelativeSeek` resolves it and the hook opens it through
/// `jumpToSegment`.
void main() {
  group('clampVmLocalMs (segment tail landing)', () {
    test('keeps the shared guard distance from the segment end', () {
      const segDur = 600000;
      expect(clampVmLocalMs(segDur, 1 << 30), segDur - kSeekTailGuardMs);
    });

    test('a zero duration collapses, a guard-sized one keeps its range', () {
      expect(clampVmLocalMs(0, 0), 0);
      expect(clampVmLocalMs(0, 50), 0);
      expect(clampVmLocalMs(null, 50), 0);
      // Short segment: the local target clamps to the segment end, not to 0.
      expect(clampVmLocalMs(kSeekTailGuardMs, 50), 50);
    });

    test('in-range values stay exact', () {
      expect(clampVmLocalMs(10000, 0), 0);
      expect(clampVmLocalMs(10000, 5000), 5000);
    });

    test('finishAtEnd is the one caller allowed ON the segment end', () {
      expect(
        clampVmLocalMs(10000, 10000, intent: SeekIntent.finishAtEnd),
        10000,
      );
      expect(
        clampVmLocalMs(10000, 1 << 30, intent: SeekIntent.finishAtEnd),
        10000,
      );
    });
  });

  group('a VM tail step finishes the item (virtual-axis policy)', () {
    // Two 10 s segments => a 20 s merged item. The last segment's tail press is
    // judged on the VIRTUAL axis (offset + local), which is the axis the hook
    // feeds `decideStepTail`.
    const int total = 20000;
    const int lastOffset = 10000;

    test('a press inside the item stays an ordinary step', () {
      expect(
        decideStepTail(
          reportedMs: lastOffset + 4000,
          deltaMs: 5000,
          durationMs: total,
          mode: StepTailFinishMode.strict,
          playing: true,
        ),
        StepTailAction.step,
      );
    });

    test('a press reaching the item end finishes it while playing', () {
      // 15 s + 5 s = 20 s == total: the merged item is finished, so the last
      // physical file may run to EOF (`maybeHandleCompleted` advances the
      // session) instead of the press being clamped to `segDur - guard`.
      expect(
        decideStepTail(
          reportedMs: lastOffset + 5000,
          deltaMs: 5000,
          durationMs: total,
          mode: StepTailFinishMode.window,
          playing: true,
        ),
        StepTailAction.finishItem,
      );
      expect(
        decideStepTail(
          reportedMs: lastOffset + 9000,
          deltaMs: 5000,
          durationMs: total,
          mode: StepTailFinishMode.strict,
          playing: true,
        ),
        StepTailAction.finishItem,
      );
    });

    test('the same press is held while paused (no advance, no write)', () {
      expect(
        decideStepTail(
          reportedMs: lastOffset + 9000,
          deltaMs: 5000,
          durationMs: total,
          mode: StepTailFinishMode.strict,
          playing: false,
        ),
        StepTailAction.hold,
      );
    });

    test('a mid-item press into the next segment is not a finish', () {
      // Segment 0's tail (10 s) is not the ITEM's tail: the hook resolves it
      // through `jumpToSegment`, never through the finish path.
      expect(
        decideStepTail(
          reportedMs: 9000,
          deltaMs: 5000,
          durationMs: total,
          mode: StepTailFinishMode.window,
          playing: true,
        ),
        StepTailAction.step,
      );
    });
  });

  group('the VM tail target is expressed on the VIRTUAL axis', () {
    // Two 10 s segments: the last one starts at 10 s. The step accumulator is
    // SEGMENT-LOCAL, while the fvp tail path hands its target to `seek()`,
    // which resolves VM targets on the merged timeline. Without the offset a
    // 9.6 s local landing is read as 9.6 s of the whole item — an early-segment
    // teleport that also drops the armed EOF window (the item never finishes).
    test('adds the segment offset to the local landing', () {
      expect(
        vmTailStepTargetMs(
          segmentOffsetMs: 10000,
          baseMs: 9600,
          deltaMs: 5000,
          segmentDurationMs: 10000,
        ),
        20000,
      );
    });

    test('clamps the local landing into the segment BEFORE offsetting', () {
      expect(
        vmTailStepTargetMs(
          segmentOffsetMs: 10000,
          baseMs: 9000,
          deltaMs: 5000,
          segmentDurationMs: 10000,
        ),
        20000,
      );
      expect(
        vmTailStepTargetMs(
          segmentOffsetMs: 30000,
          baseMs: 100,
          deltaMs: -5000,
          segmentDurationMs: 10000,
        ),
        30000,
      );
    });

    test('the first segment keeps its identity (offset 0)', () {
      expect(
        vmTailStepTargetMs(
          segmentOffsetMs: 0,
          baseMs: 5000,
          deltaMs: 5000,
          segmentDurationMs: 10000,
        ),
        10000,
      );
    });
  });

  group('the mid-file delta contract is unchanged (mpv parity)', () {
    const segDur = 10000;

    test('a backward step still never rewinds past the segment start', () {
      expect(
        stepSeekSentDelta(reportedMs: 0, deltaMs: -3000, durationMs: segDur),
        0,
      );
      expect(
        stepSeekSentDelta(reportedMs: 1000, deltaMs: -3000, durationMs: segDur),
        -1000,
      );
    });

    test('a stale sample past the segment end anchors on the segment end', () {
      // `reportedMs` is segment-local, so the segment duration is the anchor
      // bound: a backward press from an out-of-range sample must not rewind by
      // more than the segment allows.
      expect(
        stepSeekSentDelta(reportedMs: 15000, deltaMs: -3000, durationMs: segDur),
        -3000,
      );
      expect(
        stepSeekSentDelta(reportedMs: -5000, deltaMs: 3000, durationMs: segDur),
        3000,
      );
    });

    test('the delta never lands the OSD past the media', () {
      // Display stays bounded even though the delta is raw.
      expect(
        stepSeekTargetMs(reportedMs: 9500, deltaMs: 5000, durationMs: segDur),
        segDur,
      );
    });
  });
}
