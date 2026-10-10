import 'dart:math' as m;

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_ring_dial_math.dart';

void main() {
  group('VM chunk tick geometry', () {
    const Offset c = Offset(100, 50);
    const double r = 40.0;

    double radiusOf(Offset p) => (p - c).distance;

    test('extent is the per-side reach past the band centreline', () {
      // The regression this locks: the dial used to hardcode +/-9 and never read
      // `virtualmedia.markTickExtent`, so the length setting did nothing here
      // while it worked on the linear and circle sliders.
      for (final int e in <int>[0, 2, 7, 15]) {
        final ({Offset from, Offset to}) span =
            PhoneRingDialMath.vmChunkTickSpan(
          center: c,
          radius: r,
          angleRad: 0.7,
          extentPx: e,
        );
        expect(radiusOf(span.from), closeTo(r - e, 1e-9));
        expect(radiusOf(span.to), closeTo(r + e, 1e-9));
      }
    });

    test('a longer setting produces a strictly longer bar', () {
      double lengthOf(int e) {
        final ({Offset from, Offset to}) s =
            PhoneRingDialMath.vmChunkTickSpan(
                center: c, radius: r, angleRad: 0.7, extentPx: e);
        return (s.to - s.from).distance;
      }

      expect(lengthOf(4), closeTo(8, 1e-9));
      expect(lengthOf(15), greaterThan(lengthOf(4)));
      expect(lengthOf(0), closeTo(0, 1e-9));
    });

    test('out-of-range extent clamps to the setting bounds', () {
      final Offset high = PhoneRingDialMath.vmChunkTickSpan(
              center: c, radius: r, angleRad: 0.7, extentPx: 99)
          .to;
      final ({Offset from, Offset to}) low = PhoneRingDialMath.vmChunkTickSpan(
          center: c, radius: r, angleRad: 0.7, extentPx: -5);
      expect(radiusOf(high), closeTo(r + 15, 1e-9));
      expect((low.to - low.from).distance, closeTo(0, 1e-9));
    });

    test('inner end never crosses the dial centre', () {
      // radius - extent would go negative on a tiny ring; the bar must stay a
      // single ray instead of mirroring through the centre.
      final ({Offset from, Offset to}) s = PhoneRingDialMath.vmChunkTickSpan(
          center: c, radius: 3, angleRad: 0.7, extentPx: 15);
      expect(radiusOf(s.from), closeTo(0, 1e-9));
      expect(radiusOf(s.to), closeTo(18, 1e-9));
    });

    test('endpoints lie on the requested ray', () {
      const double rad = 2.1;
      final ({Offset from, Offset to}) s = PhoneRingDialMath.vmChunkTickSpan(
          center: c, radius: r, angleRad: rad, extentPx: 5);
      for (final Offset p in <Offset>[s.from, s.to]) {
        final Offset d = p - c;
        expect(m.atan2(d.dy, d.dx), closeTo(rad, 1e-9));
      }
    });
  });

  group('block count (round semantics)', () {
    test('below derived floor stays unchunked', () {
      expect(PhoneRingDialMath.blockCountFor(const Duration(seconds: 0)), 1);
      expect(PhoneRingDialMath.blockCountFor(const Duration(milliseconds: 1)), 1);
      expect(PhoneRingDialMath.blockCountFor(const Duration(seconds: 179)), 1);
      expect(PhoneRingDialMath.blockCountFor(const Duration(seconds: 269)), 1);
    });

    test('boundary anchors', () {
      expect(PhoneRingDialMath.blockCountFor(const Duration(seconds: 270)), 2);
      expect(PhoneRingDialMath.blockCountFor(const Duration(seconds: 271)), 2);
      expect(PhoneRingDialMath.blockCountFor(const Duration(seconds: 449)), 2);
      expect(PhoneRingDialMath.blockCountFor(const Duration(seconds: 450)), 3);
      expect(PhoneRingDialMath.blockCountFor(const Duration(seconds: 899)), 5);
      expect(PhoneRingDialMath.blockCountFor(const Duration(seconds: 900)), 5);
      expect(PhoneRingDialMath.blockCountFor(const Duration(minutes: 36)), 11);
    });

    test('cap boundary and saturation', () {
      // round(dur/180s) reaches the 11 cap at 10.5 x 180s = 1890s.
      expect(PhoneRingDialMath.blockCountFor(const Duration(seconds: 1889)), 10);
      expect(PhoneRingDialMath.blockCountFor(const Duration(seconds: 1890)), 11);
      expect(
        PhoneRingDialMath.blockCountFor(const Duration(hours: 10)),
        PhoneRingDialMath.maxBlocks,
      );
    });

    test('derived floor equals 1.5 x idealBlock', () {
      expect(PhoneRingDialMath.noChunkFloor, const Duration(seconds: 270));
    });

    test('uniform block starts cover the timeline', () {
      // 33 min = 11 x 3 min: the block count saturates exactly and divides
      // evenly, so the integer-exact block start contract can be asserted.
      const d = Duration(minutes: 33);
      final n = PhoneRingDialMath.blockCountFor(d);
      final step = PhoneRingDialMath.blockDurationOf(d);
      for (var i = 0; i < n; i++) {
        expect(PhoneRingDialMath.blockStart(i, d), step * i);
      }
      expect(step * n, d);
    });

    test('index for position', () {
      const d = Duration(minutes: 33);
      expect(PhoneRingDialMath.blockIndexForPosition(Duration.zero, d), 0);
      expect(PhoneRingDialMath.blockIndexForPosition(const Duration(seconds: 179), d), 0);
      expect(PhoneRingDialMath.blockIndexForPosition(const Duration(seconds: 180), d), 1);
      expect(
        PhoneRingDialMath.blockIndexForPosition(const Duration(minutes: 32, seconds: 59), d),
        10,
      );
    });
  });

  group('inversion contract properties', () {
    const samples = <Duration>[
      Duration(seconds: 30),
      Duration(seconds: 90),
      Duration(seconds: 179),
      Duration(seconds: 250),
      Duration(seconds: 269),
      Duration(seconds: 270),
      Duration(seconds: 300),
      Duration(seconds: 450),
      Duration(minutes: 10),
      Duration(minutes: 20),
      Duration(minutes: 36),
      Duration(seconds: 2250),
      Duration(hours: 1),
      Duration(hours: 2),
    ];

    double revMs(Duration d) {
      final n = PhoneRingDialMath.blockCountFor(d);
      if (n <= 1) return d.inMilliseconds.toDouble();
      return d.inMilliseconds / n;
    }

    /// Granularity (seconds per ring revolution) may rise freely with length
    /// but any drop between successively longer videos stays within 2x —
    /// the structural 1->2 seam is the only place it approaches that bound.
    test('P1 granularity drop between longer videos <= 2x', () {
      final sorted = <Duration>[...samples]..sort();
      for (var i = 1; i < sorted.length; i++) {
        final lo = revMs(sorted[i - 1]);
        final hi = revMs(sorted[i]);
        expect(hi, greaterThanOrEqualTo(lo / 2 - 1e-6),
            reason: 'seam ${sorted[i - 1]} -> ${sorted[i]} '
                'drops ${(lo / hi).toStringAsFixed(2)}x');
      }
    });

    test('P2 pre-cap blocks stay within +/-25% of ideal', () {
      const capMs = 1980 * 1000; // 11 x idealBlock: the block-count cap
      for (final d in samples) {
        final n = PhoneRingDialMath.blockCountFor(d);
        if (n < 2) continue;
        if (d.inMilliseconds >= capMs) continue; // cap zone: P5's domain
        final blockSec = d.inMilliseconds / n / 1000;
        expect(blockSec, greaterThanOrEqualTo(135),
            reason: 'dur=$d block=${blockSec}s below band');
        expect(blockSec, lessThanOrEqualTo(225),
            reason: 'dur=$d block=${blockSec}s above band');
      }
    });

    test('P3 monotonic non-decreasing with duration', () {
      Duration prev = const Duration(seconds: 10);
      var prevN = PhoneRingDialMath.blockCountFor(prev);
      for (var s = 20; s <= 7200; s += 10) {
        final d = Duration(seconds: s);
        final n = PhoneRingDialMath.blockCountFor(d);
        expect(n, greaterThanOrEqualTo(prevN), reason: 'regression at ${d}s');
        prevN = n;
      }
    });

    test('P5 cap zone grows unit linearly (accepted inversion class)', () {
      // Use durations that divide evenly by the 11 cap so the linear relation
      // is exact (integer-ms division otherwise lands 1ms short of 2x).
      final b1 = PhoneRingDialMath.blockDurationOf(const Duration(hours: 11)).inMilliseconds;
      final b2 = PhoneRingDialMath.blockDurationOf(const Duration(hours: 22)).inMilliseconds;
      expect(b2, greaterThan(b1));
      expect(b2, 2 * b1);
    });
  });

  group('virtual-media equal-division model', () {
    test('vmBlockCountFor is exactly the segment count (no 11-cap)', () {
      expect(PhoneRingDialMath.vmBlockCountFor(0), 1, reason: 'defensive');
      expect(PhoneRingDialMath.vmBlockCountFor(1), 1);
      expect(PhoneRingDialMath.vmBlockCountFor(3), 3);
      expect(PhoneRingDialMath.vmBlockCountFor(12), 12,
          reason: 'VM is not capped at the wayfinding slot cap');
      expect(PhoneRingDialMath.vmBlockCountFor(20), 20);
    });

    test('vmSectorFraction maps index to equal-arc spans', () {
      expect(PhoneRingDialMath.vmSectorFraction(0, 3), 0.0);
      expect(PhoneRingDialMath.vmSectorFraction(1, 3), closeTo(1 / 3, 1e-9));
      expect(PhoneRingDialMath.vmSectorFraction(2, 3), closeTo(2 / 3, 1e-9));
      expect(PhoneRingDialMath.vmSectorFraction(3, 3), 1.0);
      expect(PhoneRingDialMath.vmSectorFraction(-1, 3), 0.0, reason: 'defensive');
      expect(PhoneRingDialMath.vmSectorFraction(9, 3), 1.0, reason: 'clamped');
      expect(PhoneRingDialMath.vmSectorFraction(1, 0), 0.0, reason: 'defensive');
    });

    test('gapCenterClockForBlock sits at the 30° wedge midpoint', () {
      // Block 0 notch spans [330°,360°), midpoint 345°.
      expect(PhoneRingDialMath.gapCenterClockForBlock(0), 345);
      // Block k start = (-30k)%360; gap = [start+330, start+360), mid = start+345.
      for (final k in <int>[0, 1, 2, 5, 11]) {
        final start = (-30.0 * k) % 360 < 0
            ? (-30.0 * k) % 360 + 360
            : (-30.0 * k) % 360;
        expect(
          PhoneRingDialMath.gapCenterClockForBlock(k),
          closeTo((start + 345) % 360, 1e-9),
        );
      }
    });

    test('positionForOuterTap honors the blockCount override', () {
      const d = Duration(minutes: 33); // time-derived count would be 11.
      // With blockCount: 3, each block spans 11 minutes. Block 1 spans
      // [11, 22) min, its notch start(1)=330°, sweep 330°. Tap at the arc
      // midpoint (clockDeg 135°, fraction 0.5) → 11 + 5.5 = 16.5 min.
      final hit = PhoneRingDialMath.positionForOuterTap(
        clockDeg: 135.0,
        blockIndex: 1,
        duration: d,
        blockCount: 3,
      );
      expect(hit, const Duration(minutes: 16, seconds: 30));
      // No override keeps the time-derived count (11 blocks, 3min each).
      final hitDefault = PhoneRingDialMath.positionForOuterTap(
        clockDeg: 82.5,
        blockIndex: 0,
        duration: d,
      );
      expect(hitDefault, const Duration(seconds: 45));
    });

    test('positionForInnerTap honors the slotCount override (no 11-cap)', () {
      const d = Duration(minutes: 36); // time-derived → 11 slots.
      // slotCount: 5 splits the whole timeline into 5 equal slots (432s each).
      final int slots = 5;
      final double slotMs = d.inMilliseconds / slots;
      for (var k = 0; k < slots; k++) {
        final t = PhoneRingDialMath.positionForInnerTap(
          index: k,
          sectorFraction: 0.5,
          duration: d,
          rng: m.Random(k),
          slotCount: slots,
        );
        final double lo = k * slotMs + slotMs * 0.10 - 0.5;
        final double hi = (k + 1) * slotMs - slotMs * 0.10 + 0.5;
        expect(t.inMilliseconds.toDouble(), greaterThanOrEqualTo(lo));
        expect(t.inMilliseconds.toDouble(), lessThanOrEqualTo(hi));
      }
    });

    test('PhoneRingDialSession honors the blockCount override', () {
      const d = Duration(minutes: 36);
      final s = PhoneRingDialSession(
        duration: d,
        start: Duration.zero,
        blockCount: 3,
      );
      s.update(0); // prime
      // 3 blocks → 12min per 330° revolution.
      expect(s.update(165), const Duration(minutes: 6),
          reason: '165/330 of a 12-min block = 6 min');
      s.update(330); // one full revolution = one block (12 min).
      expect(s.target, const Duration(minutes: 12));
    });
  });

  group('ring geometry', () {
    test('kind assignment', () {
      expect(PhoneRingDialMath.kindFor(index: 0, count: 1), RingBlockKind.first);
      expect(PhoneRingDialMath.kindFor(index: 0, count: 12), RingBlockKind.first);
      expect(PhoneRingDialMath.kindFor(index: 5, count: 12), RingBlockKind.middle);
      expect(PhoneRingDialMath.kindFor(index: 11, count: 12), RingBlockKind.last);
      expect(PhoneRingDialMath.kindFor(index: 0, count: 2), RingBlockKind.first);
      expect(PhoneRingDialMath.kindFor(index: 1, count: 2), RingBlockKind.last);
      expect(PhoneRingDialMath.kindFor(index: 0, count: 3), RingBlockKind.first);
      expect(PhoneRingDialMath.kindFor(index: 1, count: 3), RingBlockKind.middle);
      expect(PhoneRingDialMath.kindFor(index: 2, count: 3), RingBlockKind.last);
    });

    test('first block notch occupies 11..12 oclock', () {
      const k = RingBlockKind.first;
      expect(PhoneRingDialMath.fractionForClock(0, k).fraction, 0);
      expect(PhoneRingDialMath.fractionForClock(165, k).fraction, closeTo(0.5, 1e-9));
      expect(PhoneRingDialMath.fractionForClock(330, k).fraction, 1);
      expect(PhoneRingDialMath.fractionForClock(331, k).inGap, isTrue);
      expect(PhoneRingDialMath.fractionForClock(350, k).inGap, isTrue);
      expect(PhoneRingDialMath.fractionForClock(359.9, k).inGap, isTrue);
    });

    // Middle 360° 全圆已废弃（scheme A）：所有块固定 330°，缺口逐块旋转。
    // Why: 物理死区本身即"第几块"的视觉编码，首/末不再特殊；Boundary: 任意
    // blockIndex 的 [start, start+330°] 为有效，(start+330°, start+360°) 为 gap。
    test('middle block is now also 330° with a rotating notch (retired 360°)', () {
      const k = RingBlockKind.middle;
      expect(PhoneRingDialMath.ringSweepClock(k), 330,
          reason: 'scheme A: middle 360° retired, all blocks 330°');
      // Legacy kind-based API仍以 0° 起点，故 350° 落入 gap（330° 后死区）。
      expect(PhoneRingDialMath.fractionForClock(350, k).inGap, isTrue);
      expect(PhoneRingDialMath.fractionForClock(10, k).inGap, isFalse);
      // 新按块 API：block 5 缺口 6→7 点（180→210°），350° 反而在有效区间内。
      expect(PhoneRingDialMath.fractionForOuterClock(350, 5).inGap, isFalse);
      expect(PhoneRingDialMath.fractionForOuterClock(190, 5).inGap, isTrue);
    });

    test('last block notch occupies 10..11 oclock', () {
      const k = RingBlockKind.last;
      expect(PhoneRingDialMath.fractionForClock(330, k).fraction, 0);
      expect(PhoneRingDialMath.fractionForClock(135, k).fraction, closeTo(0.5, 1e-9));
      expect(PhoneRingDialMath.fractionForClock(300, k).fraction, 1);
      expect(PhoneRingDialMath.fractionForClock(310, k).inGap, isTrue);
      expect(PhoneRingDialMath.fractionForClock(315, k).inGap, isTrue);
      expect(PhoneRingDialMath.fractionForClock(299.9, k).inGap, isFalse);
    });

    // 逐块旋转不变量：start = (-30·index)%360，sweep 固定 330°。
    // Why: 每块回退 1 小时=30°=4×15 min，外环首块 11→12、次块 10→11…；Boundary:
    // 任意 index 的 dead wedge 为 [start+330°, start+360°) mod 360 恰 1 小时。
    test('outer per-block notch rotates 30° per index (scheme A)', () {
      expect(PhoneRingDialMath.outerStartClockForBlock(0), 0);
      expect(PhoneRingDialMath.outerStartClockForBlock(1), 330);
      expect(PhoneRingDialMath.outerStartClockForBlock(2), 300);
      expect(PhoneRingDialMath.outerSweepClockForBlock(2), 330);
      // block 0 gap 11→12 (330→360)，block 1 gap 10→11 (300→330)
      expect(PhoneRingDialMath.fractionForOuterClock(350, 0).inGap, isTrue);
      expect(PhoneRingDialMath.fractionForOuterClock(340, 0).inGap, isTrue);
      expect(PhoneRingDialMath.fractionForOuterClock(329, 0).inGap, isFalse);
      expect(PhoneRingDialMath.fractionForOuterClock(315, 1).inGap, isTrue);
      expect(PhoneRingDialMath.fractionForOuterClock(305, 1).inGap, isTrue);
      expect(PhoneRingDialMath.fractionForOuterClock(340, 1).inGap, isFalse);
      // block 5 start 210°，gap 180→210° (6→7 点)
      expect(PhoneRingDialMath.outerStartClockForBlock(5), 210);
      expect(PhoneRingDialMath.fractionForOuterClock(190, 5).inGap, isTrue);
      expect(PhoneRingDialMath.fractionForOuterClock(220, 5).inGap, isFalse);
    });

    test('clock angle for fraction wraps correctly', () {
      expect(PhoneRingDialMath.clockForFraction(0, RingBlockKind.first), 0);
      expect(PhoneRingDialMath.clockForFraction(1, RingBlockKind.first), 330);
      // Middle 亦 330°（不再 360° 回绕到 0°）。
      expect(PhoneRingDialMath.clockForFraction(1, RingBlockKind.middle), closeTo(330, 1e-9));
      expect(PhoneRingDialMath.clockForFraction(0, RingBlockKind.last), 330);
      expect(PhoneRingDialMath.clockForFraction(1, RingBlockKind.last), 300);
      // 新按块 API：fraction 1 落在 start+330°，fraction 0 落在 start。
      expect(PhoneRingDialMath.clockForOuterFraction(0, 0), 0);
      expect(PhoneRingDialMath.clockForOuterFraction(1, 0), 330);
      expect(PhoneRingDialMath.clockForOuterFraction(0, 1), 330);
      expect(PhoneRingDialMath.clockForOuterFraction(0, 5), 210);
    });

    test('outer tap maps clock to absolute time inside block', () {
      const d = Duration(minutes: 33);
      final hit = PhoneRingDialMath.positionForOuterTap(
          clockDeg: 82.5, blockIndex: 0, duration: d);
      expect(hit, const Duration(seconds: 45));
      expect(
        PhoneRingDialMath.positionForOuterTap(
            clockDeg: 350, blockIndex: 0, duration: d),
        isNull,
        reason: 'notch taps are dead zones',
      );
      // block 5 start 210°，弧 [210°,180°) 330°，gap (180°,210°) 30°；
      // 取 195°（gap 中点）应判 null；250°（有效区）应命中该块约 40% 处。
      expect(
        PhoneRingDialMath.positionForOuterTap(
            clockDeg: 195, blockIndex: 5, duration: d),
        isNull,
        reason: 'block 5 gap (180°,210°) (scheme A), 195° is inside gap',
      );
      final hit5 = PhoneRingDialMath.positionForOuterTap(
          clockDeg: 250, blockIndex: 5, duration: d);
      // 250° - start 210° = 40° offset /330 ≈0.121 → 0.121·180s≈21s into block 5
      expect(hit5, isNotNull);
    });

    test('inner tap returns a position inside the tapped SLOT band (区间随机)', () {
      // 36 min → 11 blocks → 11 wayfinding slots (1:1, no aggregation); each
      // tap samples a random instant inside the tapped SLOT span (slot k covers
      // [k..k+1)/11 of the whole media), margins kept off the seams.
      const d = Duration(minutes: 36);
      final int slots = PhoneRingDialMath.innerSlotCount(
          PhoneRingDialMath.blockCountFor(d));
      expect(slots, 11);
      final double slotMs = d.inMilliseconds / slots;
      for (final frac in <double>[0.0, 0.5, 1.0]) {
        for (int k = 0; k < slots; k++) {
          final rng = m.Random(1000 * k + (frac * 10).round());
          final Duration t = PhoneRingDialMath.positionForInnerTap(
            index: k,
            sectorFraction: frac,
            duration: d,
            rng: rng,
          );
          final double ms = t.inMilliseconds.toDouble();
          final double lo = k * slotMs + slotMs * 0.10 - 0.5;
          final double hi = (k + 1) * slotMs - slotMs * 0.10 + 0.5;
          expect(ms, greaterThanOrEqualTo(lo),
              reason: 'k=$k frac=$frac below lower margin');
          expect(ms, lessThanOrEqualTo(hi),
              reason: 'k=$k frac=$frac above upper margin');
        }
      }
      // Same slot reuse: draws vary within the permissible band.
      final Set<int> draws = <int>{};
      for (int i = 0; i < 40; i++) {
        draws.add(PhoneRingDialMath.positionForInnerTap(
          index: 5,
          sectorFraction: 0.5,
          duration: d,
          rng: m.Random(i),
        ).inMilliseconds);
      }
      expect(draws.length, greaterThan(5),
          reason: 'same slot samples a band, not a single point');
    });
  });

  group('chunk hit slots (VM uncapped, single capped)', () {
    test('chunkSlotCount passes through VM segment count without cap', () {
      expect(PhoneRingDialMath.chunkSlotCount(3, isVm: true), 3);
      expect(PhoneRingDialMath.chunkSlotCount(11, isVm: true), 11);
      expect(PhoneRingDialMath.chunkSlotCount(13, isVm: true), 13,
          reason: 'VM dial chunks by file count, no 11-cap (off-by-two fix)');
      expect(PhoneRingDialMath.chunkSlotCount(20, isVm: true), 20);
      expect(PhoneRingDialMath.chunkSlotCount(0, isVm: true), 1,
          reason: 'defensive');
    });

    test('chunkSlotCount keeps the 11-cap for single media', () {
      expect(PhoneRingDialMath.chunkSlotCount(5), 5);
      expect(PhoneRingDialMath.chunkSlotCount(11), 11);
      expect(PhoneRingDialMath.chunkSlotCount(12), 11);
      expect(PhoneRingDialMath.chunkSlotCount(13), 11);
      expect(PhoneRingDialMath.chunkSlotCount(200), 11);
    });

    test('inner tap stays on the classifier grid for real media', () {
      // Unification contract: maxBlocks == kMaxInnerSlots, so for real media
      // chunkSlotCount(blockCount) == blockCount and the dial's hit.sector grid
      // is the block grid itself. The dial must still feed that same grid into
      // positionForInnerTap (never a raw rescale) so the seek stays inside the
      // tapped slot; this was flaky when 12 blocks were squeezed into 11 slots.
      const d = Duration(minutes: 36);
      final int blockCount = PhoneRingDialMath.blockCountFor(d);
      final int slots = PhoneRingDialMath.chunkSlotCount(blockCount);
      expect(blockCount, 11);
      expect(slots, blockCount, reason: 'no aggregation for real media');

      final double slotMs = d.inMilliseconds / slots;
      for (int k = 0; k < slots; k++) {
        for (final frac in <double>[0.0, 0.25, 0.5, 0.75, 1.0]) {
          final Duration t = PhoneRingDialMath.positionForInnerTap(
            index: k,
            sectorFraction: frac,
            duration: d,
            rng: m.Random(k * 31 + 7),
            slotCount: slots,
          );
          final double ms = t.inMilliseconds.toDouble();
          expect(ms, greaterThanOrEqualTo(k * slotMs + slotMs * 0.10 - 0.5),
              reason: 'index $k frac $frac below slot $k lower margin');
          expect(ms,
              lessThanOrEqualTo((k + 1) * slotMs - slotMs * 0.10 + 0.5),
              reason: 'index $k frac $frac above slot $k upper margin');
        }
      }
    });
  });

  group('inner-ring slot capping (≤11 clock-aligned wayfinding slots)', () {
    test('innerSlotCount passes through below the cap and caps above it', () {
      expect(PhoneRingDialMath.innerSlotCount(-3), 1, reason: 'defensive');
      expect(PhoneRingDialMath.innerSlotCount(0), 1, reason: 'defensive');
      expect(PhoneRingDialMath.innerSlotCount(1), 1);
      expect(PhoneRingDialMath.innerSlotCount(5), 5);
      expect(PhoneRingDialMath.innerSlotCount(11), 11);
      expect(PhoneRingDialMath.innerSlotCount(12), 11);
      expect(PhoneRingDialMath.innerSlotCount(200), 11);
    });

    test('cap equals the 330° sweep divided into whole clock hours', () {
      expect(PhoneRingDialMath.kMaxInnerSlots, 11);
    });

    test('block cap is unified with the visible slot cap', () {
      // Single-file chunk ring must stay 1:1 with the block model: the
      // time-derived block count may never exceed the renderable slot count.
      expect(PhoneRingDialMath.maxBlocks, PhoneRingDialMath.kMaxInnerSlots);
      for (final d in <Duration>[
        const Duration(minutes: 36),
        const Duration(hours: 1),
        const Duration(hours: 10),
      ]) {
        final int blocks = PhoneRingDialMath.blockCountFor(d);
        expect(blocks, lessThanOrEqualTo(PhoneRingDialMath.kMaxInnerSlots));
        expect(PhoneRingDialMath.chunkSlotCount(blocks), blocks);
      }
    });
  });

  group('canvas arc radians (painter contract)', () {
    // Canvas.drawArc measures from the +x axis (3 o'clock) clockwise while
    // ring geometry speaks clock degrees from 12 o'clock; the painter must
    // consume this pre-shifted span or every outer band renders rotated
    // +90 deg away from the (correctly converted) thumb tip.
    double d2r(double deg) => deg * m.pi / 180;

    test('first block: notch stays at 11..12 oclock', () {
      final arc = PhoneRingDialMath.outerArcRad(RingBlockKind.first);
      expect(arc.startRad, closeTo(d2r(-90), 1e-9), reason: 'starts at 12 oclock');
      expect(arc.sweepRad, closeTo(d2r(330), 1e-9), reason: 'ends at 11 oclock');
    });

    // Middle 360° retired: per-block outer arc now 330° rotating via index.
    test('per-block outer arc rotates 30° per index (scheme A)', () {
      final a0 = PhoneRingDialMath.outerArcRadForBlock(0);
      expect(a0.startRad, closeTo(d2r(-90), 1e-9));
      expect(a0.sweepRad, closeTo(d2r(330), 1e-9));
      final a1 = PhoneRingDialMath.outerArcRadForBlock(1);
      expect(a1.startRad, closeTo(d2r(240), 1e-9),
          reason: 'block 1 start 330° == canvas 240°');
      expect(a1.sweepRad, closeTo(d2r(330), 1e-9));
      final a5 = PhoneRingDialMath.outerArcRadForBlock(5);
      expect(a5.startRad, closeTo(d2r(120), 1e-9),
          reason: 'block 5 start 210° == canvas 120° (210-90)');
    });

    test('last block: notch stays at 10..11 oclock', () {
      final arc = PhoneRingDialMath.outerArcRad(RingBlockKind.last);
      expect(arc.startRad, closeTo(d2r(240), 1e-9),
          reason: 'clock 330 == canvas 240 (11 oclock)');
      expect(arc.sweepRad, closeTo(d2r(330), 1e-9),
          reason: 'ends at clock 300 == canvas 210 (10 oclock)');
    });
  });

  group('outer dial drag session', () {
    // 33 min → 11 blocks of exactly 180s, so the per-degree rates below are the
    // clean legacy numbers (+33deg == +18s).
    const d = Duration(minutes: 33);

    test('starts anchored and applies relative deltas', () {
      final s = PhoneRingDialSession(duration: d, start: const Duration(seconds: 90));
      expect(s.target, const Duration(seconds: 90));
      // First update only primes the angle reference.
      s.update(165);
      expect(s.target, const Duration(seconds: 90));
      expect(s.update(198), const Duration(seconds: 108),
          reason: '+33deg on a 330deg first block of 180s = +18s');
    });

    // 跨块速率恒定 330°（scheme A），不再 330°→360° 跳变。
    test('crosses block boundary continuously with fixed 330° rate', () {
      const d = Duration(minutes: 33);
      // Anchor at f=0.9 of block 0 (162s -> clock 297deg on the notched ring).
      final s = PhoneRingDialSession(duration: d, start: const Duration(seconds: 162));
      s.update(297);
      expect(s.target, const Duration(seconds: 162));
      // One +33deg lands exactly on the first/middle seam.
      expect(s.update(330), const Duration(seconds: 180));
      // 固定 330°：+33deg 仍为 +18s（不再 360° 的 16.5s）。
      expect(s.update(3), const Duration(seconds: 198));
    });

    test('handles shortest-path wrap between updates', () {
      final s = PhoneRingDialSession(duration: d, start: const Duration(seconds: 90));
      s.update(350);
      expect(s.update(12), const Duration(seconds: 102),
          reason: '350->12 deg wraps to +22deg = +12s on the first block');
    });

    test('clamps to media range', () {
      final s = PhoneRingDialSession(duration: d, start: const Duration(minutes: 32));
      s.update(100);
      var ang = 100.0;
      // 150 steps of +/-50..100deg comfortably saturate both ends at the
      // slowest per-block rate (middle rings: 25s per 50deg).
      for (var i = 0; i < 150; i++) {
        ang += 100;
        s.update(ang);
      }
      expect(s.target, d);
      for (var i = 0; i < 150; i++) {
        ang -= 50;
        s.update(ang);
      }
      expect(s.target, Duration.zero);
    });

    test('short video single block uses notched sweep', () {
      const short = Duration(minutes: 3);
      final s = PhoneRingDialSession(duration: short, start: Duration.zero);
      s.update(0);
      // Ten +33deg steps cover the full 330deg notch sweep = all 180s.
      for (var i = 1; i <= 10; i++) {
        s.update(33.0 * i);
      }
      expect(s.target, short);
    });
  });

  group('end guard', () {
    test('commit target never reaches exact duration', () {
      const d = Duration(minutes: 5);
      expect(
        PhoneRingDialMath.clampSeekTarget(d, d),
        d - const Duration(milliseconds: 100),
      );
      expect(
        PhoneRingDialMath.clampSeekTarget(const Duration(minutes: 4), d),
        const Duration(minutes: 4),
      );
      expect(PhoneRingDialMath.clampSeekTarget(const Duration(seconds: -3), d), Duration.zero);
    });

    test('ultra-short media collapses to zero', () {
      const tiny = Duration(milliseconds: 50);
      expect(PhoneRingDialMath.clampSeekTarget(tiny, tiny), Duration.zero);
    });
  });

  group('random jump', () {
    test('disabled under 10s', () {
      expect(PhoneRingDialMath.randomEnabled(const Duration(seconds: 9)), isFalse);
      expect(PhoneRingDialMath.randomEnabled(const Duration(seconds: 10)), isTrue);
    });

    test('stays inside [0, dur-5s] and respects min gap', () {
      const d = Duration(minutes: 30);
      final rng = m.Random(42);
      for (var i = 0; i < 200; i++) {
        final t = PhoneRingDialMath.randomTarget(
          duration: d,
          current: const Duration(minutes: 15),
          rng: rng,
        );
        expect(t, greaterThanOrEqualTo(Duration.zero));
        expect(t, lessThanOrEqualTo(d - const Duration(seconds: 5)));
        final gap = (t - const Duration(minutes: 15)).abs();
        expect(gap, greaterThanOrEqualTo(const Duration(seconds: 30)));
      }
    });

    test('min gap scales with long media (5%)', () {
      const d = Duration(hours: 2);
      final rng = m.Random(7);
      for (var i = 0; i < 100; i++) {
        final t = PhoneRingDialMath.randomTarget(
          duration: d,
          current: Duration.zero,
          rng: rng,
        );
        // 5% of 2h = 6min dominates the 30s floor.
        expect(t, greaterThanOrEqualTo(const Duration(minutes: 6)));
      }
    });

    test('degrades gracefully when feasible set is empty', () {
      // 35s media: tail guard leaves [0,30s]; current 15s with 30s gap makes
      // the strict set empty -> must still return an in-range value.
      const d = Duration(seconds: 35);
      final rng = m.Random(3);
      for (var i = 0; i < 50; i++) {
        final t = PhoneRingDialMath.randomTarget(
          duration: d,
          current: const Duration(seconds: 15),
          rng: rng,
        );
        expect(t, lessThanOrEqualTo(const Duration(seconds: 30)));
        expect(t, greaterThanOrEqualTo(Duration.zero));
      }
    });
  });
}
