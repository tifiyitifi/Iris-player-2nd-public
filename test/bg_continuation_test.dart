import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/model/enum/bg_align_mode.dart';
import 'package:iris/features/background_playback/services/background_alignment.dart';
import 'package:iris/features/background_playback/services/background_lock_mapping.dart';

/// The cross-file continuation under `BgExhaustedAction.nextBg`: when a 副音
/// file ends (or an alignment leaves the current fg position without bg) the
/// queue must be walked as ONE looping timeline and continue at the entry that
/// carries the SAME virtual position — never restart the next index at 00:00,
/// which would silently re-anchor a non-zero alignment.
void main() {
  BgQueueTimeline timeline(List<int> durs) => BgQueueTimeline(durs);

  group('resolveAlignmentOffsetMs', () {
    test('00:00↔00:00 anchors at zero', () {
      expect(
        resolveAlignmentOffsetMs(
          mode: BgAlignMode.sameClock,
          currentFgMs: 5000,
          bgDurMs: 10000,
          percent: 30,
        ),
        0,
      );
    });

    test('bg 00:00 at the current fg moment uses the fg moment as offset', () {
      expect(
        resolveAlignmentOffsetMs(
          mode: BgAlignMode.bgHeadAtFg,
          currentFgMs: 5000,
          bgDurMs: 10000,
          percent: 30,
        ),
        5000,
      );
    });

    test('percent mode folds the remembered share into the offset', () {
      expect(
        resolveAlignmentOffsetMs(
          mode: BgAlignMode.bgPercent,
          currentFgMs: 5000,
          bgDurMs: 10000,
          percent: 30,
        ),
        5000 - 3000,
      );
    });
  });

  group('resolveBgContinuation', () {
    test('null for an empty / all-zero timeline', () {
      expect(
        resolveBgContinuation(
            fgMs: 1000, offsetMs: 0, timeline: timeline(const [])),
        isNull,
      );
      expect(
        resolveBgContinuation(
            fgMs: 1000, offsetMs: 0, timeline: timeline(const [0, 0])),
        isNull,
      );
    });

    test('offset 0: the next file at the matching local position', () {
      final t = resolveBgContinuation(
        fgMs: 3500,
        offsetMs: 0,
        timeline: timeline(const [3000, 4000]),
      );
      expect(t, (index: 1, localMs: 500));
    });

    test('offset 0: past the queue total wraps to the head', () {
      final t = resolveBgContinuation(
        fgMs: 8000,
        offsetMs: 0,
        timeline: timeline(const [3000, 4000]),
      );
      // 8000 - 0 = 8000; total 7000 → wrap → 1000.
      expect(t, (index: 0, localMs: 1000));
    });

    test('offset 0: EXACTLY the queue total wraps to the head (loop-all)', () {
      final t = resolveBgContinuation(
        fgMs: 7000,
        offsetMs: 0,
        timeline: timeline(const [3000, 4000]),
      );
      // 7000 - 0 == total → wrap to the head, NOT the last file's end (which
      // would re-select and re-complete that same file forever).
      expect(t, (index: 0, localMs: 0));
    });

    test('non-zero offset is preserved across the boundary', () {
      // Anchored "bg 00:00 at fg 2000"; at fg 6500 the virtual position is 4500
      // → the second file at local 1500 (NOT its own 0).
      final t = resolveBgContinuation(
        fgMs: 6500,
        offsetMs: 2000,
        timeline: timeline(const [3000, 4000]),
      );
      expect(t, (index: 1, localMs: 1500));
    });

    test('a single-item queue loops onto itself', () {
      final t = resolveBgContinuation(
        fgMs: 5000,
        offsetMs: 0,
        timeline: timeline(const [3000]),
      );
      expect(t, (index: 0, localMs: 2000));
    });

    test('without the loop mode a past-the-list target CLAMPS onto its tail',
        () {
      // `wrap: false` (the list repeat is not `all`) has nowhere to continue to,
      // so the mapping can only clamp onto the LAST entry's end. The caller reads
      // the UNCLAMPED virtual target to tell that state apart from a landing and
      // stops there instead of resuming onto the same tail (which would
      // re-complete forever).
      final t = resolveBgContinuation(
        fgMs: 8000,
        offsetMs: 0,
        timeline: timeline(const [3000, 4000]),
        wrap: false,
      );
      expect(t, (index: 1, localMs: 4000));
      expect(
        bgVirtualTargetMs(fgMs: 8000, offsetMs: 0),
        greaterThanOrEqualTo(7000),
      );
    });

    test('bgVirtualTargetMs is the unclamped fg − offset', () {
      expect(bgVirtualTargetMs(fgMs: 8000, offsetMs: 2000), 6000);
      expect(bgVirtualTargetMs(fgMs: 0, offsetMs: 5000), -5000);
    });
  });
}
