import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/model/enum/bg_align_default.dart';
import 'package:iris/features/background_playback/model/enum/bg_align_mode.dart';
import 'package:iris/features/background_playback/services/background_alignment.dart';
import 'package:iris/features/background_playback/services/background_lock_mapping.dart';

/// 对齐锚点模型 (P1): `(fgAnchor, bgAnchor)` → offset `fg - bg`, and the
/// 仅当前 floor paired with the existing ceiling. bg positions are always
/// derived from the fg progress and the anchor — never stored progress.
void main() {
  group('resolveAlignmentAnchor / alignmentOffsetMs', () {
    test('same-clock mode maps both origins (offset 0)', () {
      final a = resolveAlignmentAnchor(
        mode: BgAlignMode.sameClock,
        currentFgMs: 120000,
        bgDurMs: 300000,
        percent: 30,
      );
      expect(a.fgAnchorMs, 0);
      expect(a.bgAnchorMs, 0);
      expect(
          alignmentOffsetMs(fgAnchorMs: a.fgAnchorMs, bgAnchorMs: a.bgAnchorMs),
          0);
    });

    test('bg-head mode anchors bg 00:00 at the current fg moment', () {
      final a = resolveAlignmentAnchor(
        mode: BgAlignMode.bgHeadAtFg,
        currentFgMs: 120000,
        bgDurMs: 300000,
        percent: 30,
      );
      expect(a.fgAnchorMs, 120000);
      expect(a.bgAnchorMs, 0);
      expect(
          alignmentOffsetMs(fgAnchorMs: a.fgAnchorMs, bgAnchorMs: a.bgAnchorMs),
          120000);
    });

    test('bg-percent mode anchors the current fg moment at 30% of the bg', () {
      final a = resolveAlignmentAnchor(
        mode: BgAlignMode.bgPercent,
        currentFgMs: 120000,
        bgDurMs: 300000,
        percent: 30,
      );
      expect(a.fgAnchorMs, 120000);
      expect(a.bgAnchorMs, 90000);
      // bg target for the current fg = fgPos - offset = 90000 (the share).
      final offset =
          alignmentOffsetMs(fgAnchorMs: a.fgAnchorMs, bgAnchorMs: a.bgAnchorMs);
      expect(120000 - offset, 90000);
    });

    test('a negative fg moment floors at 0', () {
      final a = resolveAlignmentAnchor(
        mode: BgAlignMode.bgHeadAtFg,
        currentFgMs: -5,
        bgDurMs: 300000,
        percent: 30,
      );
      expect(a.fgAnchorMs, 0);
    });
  });

  group('alignmentVirtualOffsetMs', () {
    test('subtracts the aligned file prefix so the mirror sees the queue axis',
        () {
      // sameClock on the SECOND queue file: file-local offset 0, but the file
      // starts 10min into the virtual axis, so the virtual offset is -600000.
      // Publishing the file-local 0 was the 对齐偏颇: the mirror compared it
      // against a virtual position and "fixed" the phantom 10min drift.
      expect(
        alignmentVirtualOffsetMs(
          fileLocalOffsetMs: 0,
          fileVirtualStartMs: 600000,
        ),
        -600000,
      );
      // bgHeadAtFg on the same file: fg 10:20 ↔ bg(0) ⇒ virtual offset is the
      // fg moment minus the file's start.
      expect(
        alignmentVirtualOffsetMs(
          fileLocalOffsetMs: 620000,
          fileVirtualStartMs: 600000,
        ),
        20000,
      );
    });

    test('the first file needs no conversion', () {
      expect(
        alignmentVirtualOffsetMs(
          fileLocalOffsetMs: 120000,
          fileVirtualStartMs: 0,
        ),
        120000,
      );
    });
  });

  group('resolveAlignmentAnchor (尾部锚定)', () {
    test('anchors the 副音 END on the video END', () {
      final a = resolveAlignmentAnchor(
        mode: BgAlignMode.tailAtFg,
        currentFgMs: 600000,
        bgDurMs: 1800000,
        percent: 30,
        fgDurMs: 3600000,
      );
      expect(a.fgAnchorMs, 3600000);
      expect(a.bgAnchorMs, 1800000);
      expect(
        alignmentOffsetMs(fgAnchorMs: a.fgAnchorMs, bgAnchorMs: a.bgAnchorMs),
        1800000,
      );
      // The seek target is the 副音's end minus the video's remainder.
      expect(
        bgAlignTargetMs(
          mode: BgAlignMode.tailAtFg,
          fgPosMs: 2400000,
          bgDurMs: 1800000,
          percent: 30,
          fgDurMs: 3600000,
        ),
        600000,
      );
    });

    test('degrades to the 同刻度 anchor when the fg duration is unknown', () {
      final a = resolveAlignmentAnchor(
        mode: BgAlignMode.tailAtFg,
        currentFgMs: 600000,
        bgDurMs: 1800000,
        percent: 30,
      );
      expect(a.fgAnchorMs, 0);
      expect(a.bgAnchorMs, 0);
    });
  });

  group('bgAlignDefaultFromName (legacy migration)', () {
    test('a legacy ask keeps the new default (sameClock)', () {
      expect(bgAlignDefaultFromName('ask'), BgAlignDefault.sameClock);
    });

    test('legacy fromHead/fromMid map onto the new modes', () {
      expect(bgAlignDefaultFromName('fromHead'), BgAlignDefault.bgHead);
      expect(bgAlignDefaultFromName('fromMid'), BgAlignDefault.bgPercent);
    });

    test('the frozen persisted keys and the current names both decode', () {
      expect(bgAlignDefaultFromName('fgHead'), BgAlignDefault.sameClock);
      expect(bgAlignDefaultFromName('fgPosition'), BgAlignDefault.bgHead);
      expect(bgAlignDefaultFromName('bgPercent'), BgAlignDefault.bgPercent);
      expect(bgAlignDefaultFromName('sameClock'), BgAlignDefault.sameClock);
      expect(bgAlignDefaultFromName('nonsense'), isNull);
      expect(bgAlignDefaultFromName(null), isNull);
    });
  });

  group('bgSeekFloorLocalMs', () {
    test('a positive offset floors inside the first bg file', () {
      // offset 120000 (fg runs ahead by 2min): fg 00:00 maps to bg virtual
      // -120000, i.e. 2min before the head → no lower room.
      final timeline = BgQueueTimeline(const [600000]);
      expect(
        bgSeekFloorLocalMs(
          timeline: timeline,
          currentIndex: 0,
          offsetMs: 120000,
        ),
        0,
      );
    });

    test('a negative offset floors at the mapped fg head', () {
      // offset -120000: fg 00:00 maps to bg virtual +120000 → bg local 2min.
      final timeline = BgQueueTimeline(const [600000]);
      expect(
        bgSeekFloorLocalMs(
          timeline: timeline,
          currentIndex: 0,
          offsetMs: -120000,
        ),
        120000,
      );
    });

    test('the floor accounts for the queue prefix of later files', () {
      final timeline = BgQueueTimeline(const [300000, 300000]);
      // Second file starts at virtual 5min; fg 00:00 maps to virtual 5min.
      expect(
        bgSeekFloorLocalMs(
          timeline: timeline,
          currentIndex: 1,
          offsetMs: -300000,
        ),
        0,
      );
      // fg 00:00 maps to virtual 6min → second file local 1min.
      expect(
        bgSeekFloorLocalMs(
          timeline: timeline,
          currentIndex: 1,
          offsetMs: -360000,
        ),
        60000,
      );
    });

    test('unknown timeline yields no floor', () {
      expect(
        bgSeekFloorLocalMs(
          timeline: BgQueueTimeline(const []),
          currentIndex: 0,
          offsetMs: 0,
        ),
        isNull,
      );
      expect(
        bgSeekFloorLocalMs(
          timeline: BgQueueTimeline(const [0]),
          currentIndex: 0,
          offsetMs: 0,
        ),
        isNull,
      );
    });
  });
}
