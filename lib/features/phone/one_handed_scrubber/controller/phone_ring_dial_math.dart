import 'dart:math' as m;
import 'dart:ui' show Offset, Size;

import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/rule/vm_tick_extent.dart';
import 'package:iris/models/store/app_state.dart' show DialSide;

/// Dual-ring dial scrubber math ("Ring dial" one-handed design).
///
/// Timeline model: the video is split into equal blocks whose count adapts to
/// duration (`round(dur / idealBlock)`, capped at [maxBlocks]). The inner ring
/// renders blocks as fixed-color sectors (wayfinding); the outer ring renders
/// the CURRENT block's time span as one revolution (precision within block).
///
/// Inversion contract (property-tested):
/// - Pre-cap revolution times of any two videos differ by at most 2x unless
///   their durations differ by more than an order of magnitude. The single
///   structural seam sits at [noChunkFloor] (whole ring -> two half-size
///   blocks); every later seam shrinks geometrically.
/// - Pre-cap blocks stay within +/-25% of [idealBlock].
/// - Beyond the cap the unit grows linearly with duration — the one accepted
///   inversion class (longer media legitimately use larger navigation units).
///
/// Terminal rings are physically notched (first: 11-12 o'clock, last:
/// 10-11 o'clock) so circular wrap ambiguity near the seams cannot occur;
/// middle rings are complete circles and rely on relative-dial deltas, hence
/// no quadrant edge-lock port is needed here (supersedes the old circle
/// slider's quadrant lock).
enum RingBlockKind { first, middle, last }

/// Functional band a ring-dial DRAG scrubs on (see
/// [PhoneRingDialMath.resolveDragBand]). `chunk` maps the whole timeline
/// (whole media for a real file, file-index equal arcs for VM); `progress`
/// maps the current block / current VM file local 0–100%.
enum RingDialDragBand { progress, chunk }

class PhoneRingDialMath {
  const PhoneRingDialMath._();

  /// Target time span of one block / one outer-ring revolution.
  static const Duration idealBlock = Duration(minutes: 3);

  /// Upper bound on block count; beyond it the outer ring precision coarsens
  /// instead of multiplying sectors.
  ///
  /// Unified with [kMaxInnerSlots] (11): a real single file never has more
  /// blocks than the chunk ring can render as distinct 30° sectors, so the
  /// chunk ring is always 1:1 with the block model (no block aggregation) and
  /// its notch label, the sector count and the progress-ring lap count agree.
  static const int maxBlocks = 11;

  /// Committed seeks never land on the exact media end, so touching the ring
  /// end cannot fire completion while pulling back stays risk-free; playing
  /// through the remaining tail completes naturally (release-at-end advances
  /// only when autoplay allows).
  static const int endGuardMs = 100;

  /// Random jump avoids the media tail so it can never trigger completion.
  static const Duration randomTailGuard = Duration(seconds: 5);

  /// Minimum distance from the current position when re-rolling a random
  /// target (music-shuffle convention; scales up to 5% of long media).
  static const Duration randomMinGapFloor = Duration(seconds: 30);

  static const int randomMinDisabledSeconds = 10;

  static const int _maxRandomAttempts = 24;

  // ── Layout constants (moved from the view so geometry is testable) ───────

  /// Outer band stroke width — matches the legacy slider's 4px track.
  static const double kOuterBandW = 4;

  /// Inner wayfinding band stroke width.
  static const double kInnerBandW = 7;

  /// Radial slack of the progress-band hit test: the band accepts a press from
  /// [kProgressHitInnerSlack] inside to [kProgressHitOuterSlack] outside its
  /// stroke centre. Shared by taps and drags so the two can never drift apart.
  static const double kProgressHitInnerSlack = 6;
  static const double kProgressHitOuterSlack = 16;

  /// Ideal corner-button hit radius (44px-equivalent touch target).
  static const double kCornerHitIdealR = 22;

  static const double kMinDiameter = 150;

  /// Minimum visual clearance between the two bands (half outer band +
  /// breathing room + half inner band).
  static const double _kMinRingClearance = 13.5;

  /// Videos shorter than this render as the legacy single-notch ring.
  /// Derived — never set independently of [idealBlock].
  static Duration get noChunkFloor => idealBlock * 1.5;

  // ── Block model ──────────────────────────────────────────────────────────

  static int blockCountFor(Duration duration) {
    if (duration.inMilliseconds <= 0) return 1;
    final double raw = duration.inMilliseconds / idealBlock.inMilliseconds;
    return raw.round().clamp(1, maxBlocks);
  }

  static Duration blockDurationOf(Duration duration) {
    final int n = blockCountFor(duration);
    return Duration(milliseconds: duration.inMilliseconds ~/ n);
  }

  static int blockIndexForPosition(Duration position, Duration duration) {
    final int n = blockCountFor(duration);
    final double blockMs = duration.inMilliseconds / n;
    final int idx = (position.inMilliseconds / blockMs).floor();
    return idx.clamp(0, n - 1);
  }

  static Duration blockStart(int index, Duration duration) {
    final int i = index.clamp(0, blockCountFor(duration));
    return Duration(
        milliseconds: blockDurationOf(duration).inMilliseconds * i);
  }

  // ── Virtual-media equal-division model ─────────────────────────────────
  // Virtual content merges several short files into one logical video. The dial
  // partitions that timeline by FILE COUNT, not by elapsed time: two concentric
  // rings where the chunk wayfinding band and the block-local progress ring both
  // treat "one block = one real file", each file occupying an EQUAL arc. Long
  // files are thus slightly over- or under-weighted visually, which is the
  // accepted precision trade-off of continuous cross-file viewing (spec).

  /// Block count for a virtual session: exactly the number of constituent
  /// files, uncapped (a virtual body may legitimately hold >12 files).
  static int vmBlockCountFor(int segmentCount) =>
      segmentCount < 1 ? 1 : segmentCount;

  /// Start fraction of segment [index] within the equal-division timeline
  /// (index / segmentCount). Falls back to 0.0 for empty/defensive input.
  static double vmSectorFraction(int index, int segmentCount) {
    if (segmentCount < 1) return 0.0;
    return index.clamp(0, segmentCount) / segmentCount;
  }

  /// Radial endpoints of one VM segment boundary tick on the chunk ring.
  ///
  /// [extentPx] is the per-side reach past the band centreline — the SAME
  /// `virtualmedia.markTickExtent` value the linear slider and the circle
  /// slider consume, so one setting drives all three surfaces. Extent clamps
  /// to the setting's own range and the inner end floors at 0, so a degenerate
  /// radius can never mirror the bar across the dial centre.
  static ({Offset from, Offset to}) vmChunkTickSpan({
    required Offset center,
    required double radius,
    required double angleRad,
    required int extentPx,
  }) {
    final double e =
        extentPx.clamp(kVmTickExtentMinPx, kVmTickExtentMaxPx).toDouble();
    final double rIn = (radius - e).clamp(0.0, double.infinity);
    final double rOut = radius + e;
    return (
      from: center + Offset(rIn * m.cos(angleRad), rIn * m.sin(angleRad)),
      to: center + Offset(rOut * m.cos(angleRad), rOut * m.sin(angleRad)),
    );
  }

  /// Clock degree at the CENTRE of the 30° dead wedge of block [index] — the
  /// gap spans [start+330°, start+360°), so its midpoint sits at start+345°.
  /// Pure placement helper for the numeric gap labels.
  static double gapCenterClockForBlock(int index) =>
      (outerStartClockForBlock(index) + kOuterSweepDeg +
              (360 - kOuterSweepDeg) / 2) %
          360;

  // ── Virtual-media per-file progress mapping ─────────────────────────────
  //
  // The progress ring paints the CURRENT file's local 0–100% on its real
  // duration (see the dial painter): fraction f of block idx means
  // offsetOf(idx) + f * segDur(idx) on the virtual timeline. Taps and drags
  // MUST use this same axis — the duration-weighted equal-split axis
  // (total/count) is a different function and lands up to a whole slot away
  // for unequal files.
  //
  // All helpers are pure and defensive: unknown/zero durations count as a
  // 1ms unit (matching the painter), out-of-range indices clamp.

  static double _vmSegDurMs(VirtualMediaItem item, int index) {
    if (item.segments.isEmpty) return 1.0;
    final int i = index.clamp(0, item.segments.length - 1);
    final int dur = item.segments[i].durationMs ?? 0;
    return (dur <= 0 ? 1 : dur).toDouble();
  }

  /// Progress-ring tap: angle fraction [fraction] inside file [index] maps to
  /// the virtual seek target on that file's REAL span.
  static int vmVirtualForOuterFraction({
    required VirtualMediaItem item,
    required int index,
    required double fraction,
  }) {
    if (item.segments.isEmpty) return 0;
    final int i = index.clamp(0, item.segments.length - 1);
    final double f = fraction.clamp(0.0, 1.0).toDouble();
    final double segDur = _vmSegDurMs(item, i);
    return (item.offsetOf(i) + f * segDur)
        .round()
        .clamp(0, m.max(0, item.totalDurationMs));
  }

  /// Inverse of the painter: virtual position → (file index, file-local
  /// fraction). Single source of truth shared by tap round-trips and the
  /// chunk ring's current-file detection.
  static (int, double) vmFractionForVirtual(
      VirtualMediaItem item, int virtualMs) {
    if (item.segments.isEmpty) return (0, 0.0);
    final (int idx, int local) = item.locate(virtualMs);
    final double segDur = _vmSegDurMs(item, idx);
    return (idx, (local / segDur).clamp(0.0, 1.0).toDouble());
  }

  // ── Virtual-media equal-division (chunk ring) mapping ───────────────────
  //
  // The chunk ring partitions by FILE COUNT: file i owns the equal sector
  // [i/count, (i+1)/count). Equal fraction eq = (idx + localF) / count where
  // localF is the file-local 0–100%. Drawing, taps and drags all share it.

  /// Virtual position → (file index, file-local fraction, equal fraction).
  static (int, double, double) vmEqualFraction(
      VirtualMediaItem item, int virtualMs) {
    if (item.segments.isEmpty) return (0, 0.0, 0.0);
    final int count = item.segments.length;
    final (int idx, double localF) = vmFractionForVirtual(item, virtualMs);
    return (idx, localF, ((idx + localF) / count).clamp(0.0, 1.0).toDouble());
  }

  /// Inverse: equal fraction → virtual position. Sector i always resolves
  /// inside file i (sector-local fraction scales onto that file's real
  /// duration).
  static int vmVirtualForEqualFraction(VirtualMediaItem item, double equalF) {
    if (item.segments.isEmpty) return 0;
    final int count = item.segments.length;
    final double eq = equalF.clamp(0.0, 1.0).toDouble();
    final int idx = (eq * count).floor().clamp(0, count - 1);
    final double sectorFrac = (eq * count - idx).clamp(0.0, 1.0);
    final double segDur = _vmSegDurMs(item, idx);
    return (item.offsetOf(idx) + sectorFrac * segDur)
        .round()
        .clamp(0, m.max(0, item.totalDurationMs));
  }

  /// Chunk-ring tap: tapped [sector] IS file [sector]; [sectorFraction] is
  /// the intra-sector angle scaled onto that file's real span, kept off the
  /// exact seams by the shared inner-tap margins.
  static int vmVirtualForChunkTap({
    required VirtualMediaItem item,
    required int sector,
    required double sectorFraction,
  }) {
    if (item.segments.isEmpty) return 0;
    final int i = sector.clamp(0, item.segments.length - 1);
    final double segDur = _vmSegDurMs(item, i);
    final double margin = segDur * innerTapMarginFrac;
    final double absLo = margin;
    final double absHi = segDur - margin;
    final double f = sectorFraction.clamp(0.0, 1.0).toDouble();
    final double centre = f * segDur;
    final double half = segDur * innerTapBandHalfFrac;
    double bLo = (centre - half).clamp(absLo, absHi);
    double bHi = (centre + half).clamp(absLo, absHi);
    if (bHi - bLo < margin * 0.5) {
      bLo = absLo;
      bHi = absHi;
    }
    if (bLo > bHi) {
      final double tmp = bLo;
      bLo = bHi;
      bHi = tmp;
    }
    final double local = ((bLo + bHi) / 2).clamp(0.0, segDur);
    return (item.offsetOf(i) + local)
        .round()
        .clamp(0, m.max(0, item.totalDurationMs));
  }

  // ── Ring geometry ────────────────────────────────────────────────────────
  // Angles are "clock degrees": measured clockwise from 12 o'clock in [0,360).
  // The view layer converts canvas radians via deg(atan2(dy,dx)) + 90 mod 360.

  static RingBlockKind kindFor({required int index, required int count}) {
    if (count <= 1 || index <= 0) return RingBlockKind.first;
    if (index >= count - 1) return RingBlockKind.last;
    return RingBlockKind.middle;
  }

  // ── Outer notch rotation — scheme A (current) ────────────────────────────
  //
  // Why 외环逐块回退: each block's physical dead wedge must sit on a different
  // clock-hour so the notch itself becomes a wayfinding cue for "which lap
  // I'm on" and so circular-wrap ambiguity cannot be hand-waved away by a
  // full-circle middle ring. The old middle==360° branch therefore is retired
  // (user-confirmed: "中段无缺口是废弃方案，删除它").
  //
  // Invariant 外环: block k starts at (12h − k·30°) mod 360 and sweeps a FIXED
  // 330°, so the dead wedge rotates one hour counter-clockwise per block:
  // k=0 misses 11→12, k=1 misses 10→11, k=2 misses 9→10 … With [maxBlocks]==11
  // the block count never exceeds the 11 distinct clock-hour positions, so the
  // pattern never wraps and every lap keeps a unique notch. 30° = 1h = 4×15 min;
  // change kOuterNotchStepDeg to 7.5° for literal 15 min granularity without
  // touching callers.
  //
  // Invariant 内环 (wayfinding, level 1): pinned at 11→12 (0°) forever, aligned
  // with outer k=0 for at-a-glance parity. This is the sole exception and is
  // the only caller of arcStartClockForLevel(1)==0 after the retirement.
  static const double kOuterNotchStepDeg = 30;
  static const double kOuterSweepDeg = 330;

  // Legacy kind-based helpers — kept for call-site compatibility but now
  // degenerate to the same 330° sweep (middle 360° retired). New code must use
  // the block-index variants below.
  static double ringSweepClock(RingBlockKind kind) => 330.0;

  static double ringStartClock(RingBlockKind kind) =>
      kind == RingBlockKind.last ? 330.0 : 0.0;

  /// Outer start clock for block [index] — the per-block rotating notch.
  static double outerStartClockForBlock(int index) {
    final double raw = (-kOuterNotchStepDeg * index) % 360;
    return raw < 0 ? raw + 360 : raw;
  }

  /// Outer sweep is fixed 330° for every block (middle 360° retired).
  static double outerSweepClockForBlock(int index) => kOuterSweepDeg;

  // ── Counter-clockwise notch rotation (inner wayfinding levels) ───────────
  //
  // Inner level 1 is pinned at 0°; outer no longer uses kind-specific arcs
  // (see outerStartClockForBlock). kRingLevelSweepDeg aliases kOuterSweepDeg
  // for inner callers that historically referenced it.

  static const double kRingLevelSweepDeg = kOuterSweepDeg;

  /// Maximum visible wayfinding slots on the inner ring: the 330° sweep fits
  /// exactly eleven whole clock-hour positions beside the rotating notch.
  /// Human angular discrimination bottoms out well below that anyway — more
  /// sectors would render as indistinguishable slivers (see innerSlotCount).
  ///
  /// This is also the block-count ceiling: [maxBlocks] is defined equal to it,
  /// so for real single media `innerSlotCount` never has to aggregate and the
  /// chunk ring stays 1:1 with the block model.
  static const int kMaxInnerSlots = kRingLevelSweepDeg ~/ 30;

  /// Visible inner-ring granularity: blocks aggregate into at most
  /// [kMaxInnerSlots] equal slots so every sector stays ≥30° and
  /// colour-identifiable. Below the cap slots == blocks (1:1 hues). Since
  /// [maxBlocks] == [kMaxInnerSlots], real media always stays at 1:1; the cap
  /// remains as a defensive guard for any caller passing a raw count.
  static int innerSlotCount(int blockCount) {
    final int n = blockCount < 1 ? 1 : blockCount;
    return n < kMaxInnerSlots ? n : kMaxInnerSlots;
  }

  /// Chunk hit-test slot count: virtual media splits by FILE COUNT with no
  /// cap (one equal sector per file, matching the VM chunk painter); single
  /// media keeps the [innerSlotCount] cap, which [maxBlocks] never exceeds so
  /// the real-media result is simply the block count.
  static int chunkSlotCount(int blockCount, {bool isVm = false}) {
    if (isVm) return blockCount < 1 ? 1 : blockCount;
    return innerSlotCount(blockCount);
  }

  static double arcStartClockForLevel(int level) {
    // Inner wayfinding ring (level 1) is pinned to 11→12 (0°) for UX parity
    // with the outer first-block gap — see notch spec above.
    if (level == 1) return 0;
    final double raw = (-30.0 * level) % 360;
    return raw < 0 ? raw + 360 : raw;
  }

  /// Inner-ring fraction for a clock angle: [0,1] along the level-1 arc,
  /// `inGap` inside the notch (11–12 o'clock).
  static ({double fraction, bool inGap}) fractionForInnerClock(
      double clockDeg) {
    final double offset =
        ((clockDeg - arcStartClockForLevel(1)) % 360 + 360) % 360;
    if (offset > kRingLevelSweepDeg) {
      return (fraction: 1.0, inGap: true);
    }
    return (fraction: offset / kRingLevelSweepDeg, inGap: false);
  }

  /// Shared inner notch spec: both rings now miss 11→12, so outer first and
  /// inner share the same gap. Kept as a derived getter for painter symmetry.

  /// Global cross-block position for inner-ring drags: the full 330° sweep
  /// maps onto the WHOLE media duration (outer ring covers one block only).
  /// Gap angles resolve to the wrapped end — callers keep dragging seamlessly.
  static Duration positionForInnerDragClock(double clockDeg, Duration duration) {
    final double f = fractionForInnerClock(clockDeg).fraction;
    final int ms = (f * duration.inMilliseconds).round();
    return Duration(milliseconds: ms.clamp(0, duration.inMilliseconds));
  }

  /// Pre-shifted canvas-radian span of the inner (level-1) arc for painters.
  static ({double startRad, double sweepRad}) get innerArcRad {
    const double shiftDeg = -90.0;
    return (
      startRad: (arcStartClockForLevel(1) + shiftDeg) * m.pi / 180.0,
      sweepRad: kRingLevelSweepDeg * m.pi / 180.0,
    );
  }

  // ── Outer per-block clock helpers (scheme A) ───────────────────────────────
  //
  // Why 按块: sweep 固定 330°，起点逐块 −30°，死区天然成为"第几圈"的视觉编码，
  // 首/末不再特殊。Boundary: clockDeg 任意实数先归一到 [0,360)，offset>sweep
  // 即落入死区（无意义，tap 返回 null，drag 由 session 的 clamp 兜底）。

  /// Clock for fraction within block [index]'s 330° arc.
  static double clockForOuterFraction(double fraction, int blockIndex) {
    final double f = fraction.clamp(0.0, 1.0).toDouble();
    return (outerStartClockForBlock(blockIndex) + f * outerSweepClockForBlock(blockIndex)) % 360;
  }

  /// Fraction + gap test for outer block [blockIndex].
  static ({double fraction, bool inGap}) fractionForOuterClock(
      double clockDeg, int blockIndex) {
    final double sweep = outerSweepClockForBlock(blockIndex);
    final double start = outerStartClockForBlock(blockIndex);
    final double offset = ((clockDeg - start) % 360 + 360) % 360;
    if (offset > sweep) {
      return (fraction: 0.0, inGap: true);
    }
    return (fraction: offset / sweep, inGap: false);
  }

  /// Pre-shifted canvas span for outer block [blockIndex] (painter contract).
  static ({double startRad, double sweepRad}) outerArcRadForBlock(int blockIndex) {
    const double shiftDeg = -90.0;
    return (
      startRad: (outerStartClockForBlock(blockIndex) + shiftDeg) * m.pi / 180.0,
      sweepRad: outerSweepClockForBlock(blockIndex) * m.pi / 180.0,
    );
  }

  // ── Legacy kind-based wrappers (kept for compatibility, now degenerate) ─────
  // Middle 360° retired — all kinds map to 330°; kind callers should migrate
  // to the block-index variants above.

  static double clockForFraction(double fraction, RingBlockKind kind) {
    final double f = fraction.clamp(0.0, 1.0).toDouble();
    return (ringStartClock(kind) + f * ringSweepClock(kind)) % 360;
  }

  static ({double fraction, bool inGap}) fractionForClock(
      double clockDeg, RingBlockKind kind) {
    final double sweep = ringSweepClock(kind);
    final double offset =
        ((clockDeg - ringStartClock(kind)) % 360 + 360) % 360;
    if (offset > sweep) {
      return (fraction: 0.0, inGap: true);
    }
    return (fraction: offset / sweep, inGap: false);
  }

  /// Canvas-radian span for the painter's outer-band arcs. Flutter's
  /// Canvas.drawArc measures from the +x axis (3 o'clock) clockwise while
  /// ring geometry speaks "clock degrees" measured clockwise from 12 o'clock
  /// — hence the fixed −90° shift. Per-point helpers (thumb position)
  /// convert on their own; per-span arcs MUST come pre-shifted or every band
  /// renders rotated 90° away from its thumb tip.
  static ({double startRad, double sweepRad}) outerArcRad(RingBlockKind kind) {
    const double shiftDeg = -90.0;
    return (
      startRad: (ringStartClock(kind) + shiftDeg) * m.pi / 180.0,
      sweepRad: ringSweepClock(kind) * m.pi / 180.0,
    );
  }

  // ── Drag band resolution ────────────────────────────────────────────────

  /// Which functional band a DRAG scrubs on. Physical radius follows
  /// [RingDialAssignment] (`innerChunk` → chunk inside / progress outside).
  ///
  /// Why mandatory fallback: the drag used to arm only when the pan START
  /// landed inside a band, and `onPanUpdate` silently returns when unarmed — a
  /// press a few pixels off, or on the dial centre, swallowed the ENTIRE
  /// gesture while a tap on the same spot still acted ("点击能跳，拖动不行").
  /// Drags therefore always resolve: an in-band hit wins, otherwise the
  /// NEAREST band is used. Taps keep their richer classification (corners /
  /// centre / dead wedge) in the view layer.
  static RingDialDragBand resolveDragBand({
    required double dist,
    required RingDialGeometry geometry,
    required bool chunkIsOuter,
    required bool chunkVisible,
  }) {
    final double chunkR = chunkIsOuter ? geometry.outerR : geometry.innerR;
    final double progressR = chunkIsOuter ? geometry.innerR : geometry.outerR;
    final bool progressHit = dist >= progressR - kProgressHitInnerSlack &&
        dist <= progressR + kProgressHitOuterSlack;
    final bool chunkHit =
        chunkVisible && (dist - chunkR).abs() <= geometry.innerHitHalf;
    // Physical outer priority when the two bands overlap (degenerate panels),
    // mirroring the tap classifier.
    if (chunkIsOuter) {
      if (chunkHit) return RingDialDragBand.chunk;
      if (progressHit) return RingDialDragBand.progress;
    } else {
      if (progressHit) return RingDialDragBand.progress;
      if (chunkHit) return RingDialDragBand.chunk;
    }
    if (!chunkVisible) return RingDialDragBand.progress;
    return (dist - chunkR).abs() <= (dist - progressR).abs()
        ? RingDialDragBand.chunk
        : RingDialDragBand.progress;
  }

  /// Whether a press at [dist] is accepted by the progress band (tap parity).
  static bool progressBandHit(double dist, double progressR) =>
      dist >= progressR - kProgressHitInnerSlack &&
      dist <= progressR + kProgressHitOuterSlack;

  /// Whether a press at [dist] is accepted by the chunk band (tap parity).
  static bool chunkBandHit(
          double dist, double chunkR, RingDialGeometry geometry) =>
      (dist - chunkR).abs() <= geometry.innerHitHalf;

  // ── Taps ────────────────────────────────────────────────────────────────

  /// Absolute jump inside the given block. Returns null for notch taps
  /// (dead zones carry no meaning, matching the old slider's ignored hits).
  /// Why 按块 330°: dead wedge 随 blockIndex 旋转，tap 落入 [start+330°, start+360°)
  /// 即判定为 inGap → null；Boundary: 任意 clockDeg 先归一，跨 0° 边界由模运算覆盖。
  ///
  /// [blockCount] optionally overrides the time-derived block count — used by
  /// the virtual-media dial where each block is one video file (equal arcs).
  /// When null the duration-based count (blockCountFor(duration)) is used, so
  /// real-file callers keep the exact existing semantics.
  static Duration? positionForOuterTap({
    required double clockDeg,
    required int blockIndex,
    required Duration duration,
    int? blockCount,
  }) {
    final int count = blockCount ?? blockCountFor(duration);
    final int i = blockIndex.clamp(0, count - 1);
    final ({double fraction, bool inGap}) hit =
        fractionForOuterClock(clockDeg, i);
    if (hit.inGap) return null;
    final double blockMs = duration.inMilliseconds / count;
    // When an explicit blockCount override is supplied the block start is an
    // equal division of the timeline (virtual media: one file per block). Without
    // it we keep the legacy integer-exact blockStart for real-file callers.
    final double startMs =
        blockCount != null ? (i * blockMs) : blockStart(i, duration).inMilliseconds.toDouble();
    return Duration(
        milliseconds:
            (startMs + hit.fraction * blockMs).round().clamp(0, duration.inMilliseconds));
  }

  // ── Inner sector tap: approximate interval ────────────────────────────────
  // Tapping a small inner slot cannot resolve to an exact instant; recover
  // a band inside the SLOT's time span and return a random instant within it.
  // The tap's intra-sector angle (sectorFraction) seeds the band centre so
  // roughly hitting the upper vs lower half biases the upper vs lower half of
  // the slot, but the realised point stays bounded away from exact seams.
  // "区间随机即可". Since [maxBlocks] == [kMaxInnerSlots] one slot never spans
  // several blocks for real media (aggregation is only a defensive path for an
  // out-of-range raw count); drag stays the precision tool.

  /// Margins that keep inner taps off exact block seams.
  static const double innerTapMarginFrac = 0.10; // 10% off each edge
  /// Half-band around the tapped angle that defines the sampling interval.
  static const double innerTapBandHalfFrac = 0.20; // ±20% of the slot

  /// Random position somewhere inside the tapped slot, biased by where inside
  /// the sector the gesture landed (sectorFraction ∈ [0,1]).
  ///
  /// [slotCount] optionally overrides the slot count — used by the virtual
  /// dial so each video file maps to exactly one equal sector (no 11-slot cap).
  /// When null the capped innerSlotCount(blockCountFor(duration)) is used.
  static Duration positionForInnerTap({
    required int index,
    required double sectorFraction,
    required Duration duration,
    required m.Random rng,
    int? slotCount,
  }) {
    final int slots = slotCount ?? innerSlotCount(blockCountFor(duration));
    final int i = index.clamp(0, slots - 1);
    final double slotMs = duration.inMilliseconds / slots;
    final double startMs = i * slotMs;
    final double endMs = startMs + slotMs;
    final double margin = slotMs * innerTapMarginFrac;
    final double absLo = startMs + margin;
    final double absHi = endMs - margin;
    // Band centred on the tapped angle inside the slot.
    final double f = sectorFraction.clamp(0.0, 1.0).toDouble();
    final double centre = startMs + f * slotMs;
    final double half = slotMs * innerTapBandHalfFrac;
    double bLo = (centre - half).clamp(absLo, absHi);
    double bHi = (centre + half).clamp(absLo, absHi);
    // Avoid a degenerate single-point band: relax half towards the far edge.
    if (bHi - bLo < margin * 0.5) {
      bLo = absLo;
      bHi = absHi;
    }
    if (bLo > bHi) {
      final double tmp = bLo; bLo = bHi; bHi = tmp;
    }
    final int lo = bLo.round().clamp(0, duration.inMilliseconds);
    final int hi = bHi.round().clamp(0, duration.inMilliseconds);
    if (hi <= lo) return Duration(milliseconds: lo);
    return Duration(milliseconds: lo + rng.nextInt(hi - lo + 1));
  }

  // ── Commit guard ─────────────────────────────────────────────────────────

  static Duration clampSeekTarget(Duration target, Duration duration) {
    final int maxMs = m.max(0, duration.inMilliseconds - endGuardMs);
    return Duration(
        milliseconds: target.inMilliseconds.clamp(0, maxMs));
  }

  // ── Random jump ──────────────────────────────────────────────────────────

  static bool randomEnabled(Duration duration) =>
      duration >= const Duration(seconds: randomMinDisabledSeconds);

  static Duration randomTarget({
    required Duration duration,
    required Duration current,
    required m.Random rng,
  }) {
    assert(randomEnabled(duration), 'caller must gate on randomEnabled');
    final int hiMs = duration.inMilliseconds - randomTailGuard.inMilliseconds;
    const int loMs = 0;
    final int gapMs = m.max(
      randomMinGapFloor.inMilliseconds,
      (duration.inMilliseconds * 0.05).round(),
    );
    int fallback = loMs;
    for (int attempt = 0; attempt < _maxRandomAttempts; attempt++) {
      final int cand = loMs + rng.nextInt(hiMs - loMs + 1);
      fallback = cand;
      if ((cand - current.inMilliseconds).abs() >= gapMs) {
        return Duration(milliseconds: cand);
      }
    }
    return Duration(milliseconds: fallback.clamp(loMs, hiMs));
  }

  // ── Dial styling geometry (user-configurable) ────────────────────────────

  /// Invisible bounding box hosting the ring square. The height share of the
  /// available span drives the ring size, floored at [kMinDiameter]; the box
  /// width is the placement canvas the ring travels within (see
  /// [dialPlacementPx]) AND the hard cap on that size: a tall narrow panel must
  /// never render a ring wider than the panel itself.
  static RingDialBox dialBox({
    required double panelWidth,
    required double maxHeight,
    double heightPct = 1.0,
  }) {
    final double bw = panelWidth;
    final double bh = maxHeight * clampRingDialPct(heightPct);
    final double diameter = m.min(m.max(kMinDiameter, bh), bw);
    return RingDialBox(
      width: bw,
      height: m.max(bh, diameter),
      diameter: diameter,
    );
  }

  // ── Panel mutual-exclusion envelope (ring + buttons) ──────────────────────
  static double minPanelWidthForRingAndStrip({
    required double diameter,
    double inset = 8,
  }) =>
      diameter + 2 * inset;

  /// Minimum panel height to host ring + gap + buttons without overflow.
  /// Why 垂直可分: Column(环(span→dial) + gap + 按钮) 高度 = d + gap + buttonsH
  /// (+ 上下 inset)，拖拽更矮即限位而非溢出。Boundary: span< d 时环退化为 span。
  static double minPanelHeightForContent({
    required double diameter,
    required double buttonsH,
    double gap = 8,
    double inset = 8,
  }) =>
      diameter + gap + buttonsH + 2 * inset;

  /// Anchor-relative placement for the ring, resolved in PX from the left
  /// edge of [box]. The slot ratio `ringSlotT` (0-1) maps the ring centre
  /// inside `[r .. 100-r]` anchor space, then mirrors for `outer` side and
  /// left-handed panels.
  static double dialPlacementPx({
    required RingDialBox box,
    required bool leftHanded,
    required DialSide side,
    required double ringSlotT,
  }) {
    final double w = box.width;
    final double rU = m.min(box.diameter / 2 / w, 0.5) * 100;
    final double rt = clampSlotT(ringSlotT);
    double slotU(double lo, double hi, double t) {
      if (lo > hi) return (lo + hi) / 2;
      return lo + (hi - lo) * t;
    }

    final double cLo = m.min(rU, 100 - rU);
    final double cHi = m.max(rU, 100 - rU);
    final double ringFinal = slotU(rU, 100 - rU, rt).clamp(cLo, cHi).toDouble();
    double ringLeftC = ringFinal / 100 * w - box.diameter / 2;
    final bool mirror = (side == DialSide.outer) != leftHanded;
    if (mirror) {
      ringLeftC = w - ringLeftC - box.diameter;
    }
    return ringLeftC;
  }

  /// Radius budget left after inset for the outer stroke: R = c − 4.
  static double _usableRadius(double squareHalf) => squareHalf - 4;

  /// Parameterised dial layout — supersedes the view's private `_DialGeometry`.
  ///
  /// Defaults reproduce the legacy numbers at the reference 210px square
  /// (outerR 101 / innerR 79.5). The inner radius is clamped in pixel space
  /// so the two bands can never touch regardless of stored factor values;
  /// the corner hit radius keeps a 44px-equivalent touch target and shrinks
  /// only to avoid overlapping neighbouring corners on tiny panels.
  static RingDialGeometry dialGeometry({
    required Size size,
    double outerRadiusFactor = 1.0,
    double innerRadiusFactor = kDefaultInnerRadiusFactor,
  }) {
    final double c = size.shortestSide / 2;
    final double r = _usableRadius(c);
    final double outerR = r * clampRingDialOuterRadius(outerRadiusFactor);
    final double innerR = m.min(
      r * clampRingDialInnerRadius(innerRadiusFactor, outerFactor: outerRadiusFactor),
      outerR - _kMinRingClearance,
    );
    final double rIn = innerR - kInnerBandW / 2;

    // Corner centres sit in the curved-triangle leftover between the outer
    // circle and each square corner: diagonal gap = c√2 − outerR.
    final double gapDiag = c * m.sqrt1_2 * 2 - outerR;
    final double cornerDist = outerR + gapDiag * 0.48;
    final double diag = cornerDist * m.sqrt1_2;
    final Offset ctr = Offset(c, c);

    // Touch-target floor with anti-overlap cap: hits never shrink with the
    // visual scale; on cramped panels they yield before swallowing neighbours.
    final double neighborDist = 2 * diag;
    final double cornerHitR = m.min(kCornerHitIdealR, neighborDist / 2);

    return RingDialGeometry(
      c: c,
      outerR: outerR,
      innerR: innerR,
      rIn: rIn,
      centerHitR: rIn * 0.55,
      innerHitHalf: kInnerBandW / 2 + 1.5,
      cornerCenters: <Offset>[
        ctr + Offset(-diag, -diag), // TL
        ctr + Offset(diag, -diag), // TR
        ctr + Offset(-diag, diag), // BL
        ctr + Offset(diag, diag), // BR
      ],
      cornerHitR: cornerHitR,
    );
  }
}

/// Invisible ring bounding box (see [PhoneRingDialMath.dialBox]).
class RingDialBox {
  const RingDialBox({
    required this.width,
    required this.height,
    required this.diameter,
  });

  /// Box width — `panelWidth × widthPct` (clamped to [0.5, 1.0]).
  final double width;

  /// Box height — `max(height share, capped diameter)` so the ring stays
  /// vertically centred when the width cap shrinks it below the height budget.
  final double height;

  /// Ring square side that fits inside the box.
  final double diameter;
}

/// Default inner-radius fraction reproducing the legacy derived value
/// (79.5/101 at the reference diameter).
const double kDefaultInnerRadiusFactor = 0.787;

// ── Store-layer clamp contracts (pure; updaters delegate here) ─────────────

const double _kPctMin = 0.30, _kPctMax = 1.00;
const double _kOuterMin = 0.80, _kOuterMax = 1.00;
const double _kInnerMin = 0.30;
/// Conservative global ceiling so a stored inner factor can never exceed the
/// pixel-space collision bound even on the smallest legal diameter.
const double _kInnerStaticMax = 0.81;
const double _kInnerOuterSeparation = 0.05;

/// Corridor slot ratio (ring / axis position inside their live gaps).
double clampSlotT(double v) => v.clamp(0.0, 1.0).toDouble();

/// Invisible bounding-box height share of the available span —
/// shrink-only by design: 100% reproduces the fitted baseline, smaller
/// values scale everything down inside it.
double clampRingDialPct(double v) => v.clamp(_kPctMin, _kPctMax).toDouble();

double clampRingDialOuterRadius(double v) =>
    v.clamp(_kOuterMin, _kOuterMax).toDouble();

double clampRingDialInnerRadiusBound({required double outerFactor}) =>
    m.min(_kInnerStaticMax, outerFactor - _kInnerOuterSeparation);

double clampRingDialInnerRadius(double v, {required double outerFactor}) {
  final double hi =
      m.max(_kInnerMin, clampRingDialInnerRadiusBound(outerFactor: outerFactor));
  return v.clamp(_kInnerMin, hi).toDouble();
}

/// Pure layout numbers derived once per layout/paint pass.
class RingDialGeometry {
  const RingDialGeometry({
    required this.c,
    required this.outerR,
    required this.innerR,
    required this.rIn,
    required this.centerHitR,
    required this.innerHitHalf,
    required this.cornerCenters,
    required this.cornerHitR,
  });

  /// Half of the shortest panel side (dial-local centre coordinate).
  final double c;
  final double outerR;
  final double innerR;
  final double rIn;
  final double centerHitR;
  final double innerHitHalf;
  final List<Offset> cornerCenters; // TL, TR, BL, BR
  final double cornerHitR;

  Offset get center => Offset(c, c);
}

/// Relative dial drag session: converts per-update clock-angle deltas into
/// continuous time movement. Why 固定 330°: scheme A 下外环所有块均为 330° 旋转缺口，
/// 中段 360° 全圆已废弃 — 速率恒定为 blockMs/330°，跨块不再跳变；Boundary: 首/末
/// 亦 330°，拖过 [start+330°, start+360°) 死区由模运算的 shortest-path 自然处理，
/// 媒体首尾由 clamp 兜底不回绕。
class PhoneRingDialSession {
  PhoneRingDialSession({
    required this.duration,
    required Duration start,
    this.blockCount,
  })  : _targetMs =
            start.inMilliseconds.toDouble().clamp(0.0, duration.inMilliseconds.toDouble()),
        _lastClock = null,
        _vmItem = null,
        _lockToSegment = false;

  /// Virtual-merge drag session: one 330° revolution covers the CURRENT
  /// file's real duration (matching the progress-ring painter), not
  /// total/count. Dragging past a file edge rebases into the neighbour file
  /// carrying the overshoot, so one continuous gesture walks across files;
  /// the virtual head/tail clamp instead of wrapping.
  ///
  /// [lockToSegment] clamps the gesture inside the file the drag STARTED in:
  /// 0% sticks at the file head, 100% at the file tail (one seekable ms short,
  /// see [clampVmLocalMs]), and a reversed finger moves back immediately
  /// because the clamp applies to the accumulated target, not the output.
  /// The user's per-file lock must never strand phantom overshoot.
  PhoneRingDialSession.vm({
    required VirtualMediaItem item,
    required int startVirtualMs,
    bool lockToSegment = false,
  })  : duration = Duration(milliseconds: m.max(0, item.totalDurationMs)),
        blockCount = null,
        _vmItem = item,
        _lockToSegment = lockToSegment,
        _targetMs = startVirtualMs
            .clamp(0, m.max(0, item.totalDurationMs))
            .toDouble(),
        _lastClock = null {
    final int idx = lockToSegment
        ? item.locate(_targetMs.round()).$1
        : -1;
    _lockSegmentIndex = idx;
    if (lockToSegment && item.segments.isNotEmpty) {
      final double start = item.offsetOf(idx).toDouble();
      final double span = PhoneRingDialMath._vmSegDurMs(item, idx);
      _targetMs = _targetMs.clamp(start, start + m.max(0.0, span - 1));
    }
  }

  final Duration duration;

  /// Optional fixed block count override — the virtual-media dial uses the
  /// number of video files so every 330° revolution covers exactly one file.
  /// When null the time-derived blockCountFor(duration) is used.
  final int? blockCount;

  /// Non-null only for the [.vm] constructor: per-file drag axis.
  final VirtualMediaItem? _vmItem;

  /// Non-null only for the [.vm] constructor: whether the drag is clamped to
  /// the file it started in (user setting `ringDialVmProgressLock`).
  final bool _lockToSegment;

  /// Segment index the locked drag is confined to; -1 when unlocked.
  late final int _lockSegmentIndex;

  double get targetVirtualMs => _targetMs;

  double _targetMs;
  double? _lastClock;

  Duration get target => Duration(milliseconds: _targetMs.round());

  void reset({required Duration start}) {
    final double hi = (_vmItem?.totalDurationMs ?? duration.inMilliseconds)
        .toDouble()
        .clamp(0.0, double.infinity);
    _targetMs = start.inMilliseconds.toDouble().clamp(0.0, m.max(0.0, hi));
    _lastClock = null;
  }

  /// First call primes the angle reference (touch-down must not jump);
  /// subsequent calls accumulate shortest-path deltas.
  Duration update(double clockDeg) {
    final double? last = _lastClock;
    _lastClock = clockDeg;
    if (last == null) return target;

    double delta = (clockDeg - last) % 360;
    if (delta > 180) delta -= 360;
    const double sweep = PhoneRingDialMath.kOuterSweepDeg; // fixed 330° (scheme A)
    final VirtualMediaItem? vm = _vmItem;
    if (vm != null && vm.segments.isNotEmpty) {
      if (_lockToSegment) {
        // Per-file lock: keep the accumulated target inside the STARTING
        // file's real span. The upper bound is one seekable millisecond short
        // of the seam so `locate` never awards the preview to the next file
        // (the canonical `clampVmLocalMs` contract). Clamping the TARGET, not
        // the output, means a reversed finger moves back on the next update.
        final int idx = _lockSegmentIndex.clamp(0, vm.segments.length - 1);
        final double segStart = vm.offsetOf(idx).toDouble();
        final double segSpan =
            PhoneRingDialMath._vmSegDurMs(vm, idx).clamp(1.0, double.infinity);
        final double maxLocal = m.max(0.0, segSpan - 1);
        _targetMs = (_targetMs + delta / sweep * segSpan)
            .clamp(segStart, segStart + maxLocal);
        return target;
      }
      final (int idx, int local) = vm.locate(_targetMs.round());
      final double segDur =
          PhoneRingDialMath._vmSegDurMs(vm, idx).clamp(1.0, double.infinity);
      final double nextVirtual = (vm.offsetOf(idx) +
              local +
              delta / sweep * segDur)
          .clamp(0.0, m.max(0, vm.totalDurationMs).toDouble());
      // locate() clamps past-end into the last file, which keeps the session
      // continuous across file edges while the virtual ends still clamp.
      _targetMs = nextVirtual;
      return target;
    }
    final int count = blockCount ?? PhoneRingDialMath.blockCountFor(duration);
    final double blockMs = duration.inMilliseconds / count;
    _targetMs = (_targetMs + delta / sweep * blockMs)
        .clamp(0.0, duration.inMilliseconds.toDouble());
    return target;
  }
}

/// Result of [ringDialPlacement]: the ring box, its slot-shifted left edge and
/// the geometry both rings paint with.
class RingDialPlacement {
  const RingDialPlacement({
    required this.box,
    required this.ringX,
    required this.geometry,
  });

  final RingDialBox box;
  final double ringX;
  final RingDialGeometry geometry;

  /// Vertical offset that centres the ring square inside the box.
  double get ringTop => (box.height - box.diameter) / 2;

  /// The ring's centre in the box's coordinate space.
  Offset get ringCenter =>
      Offset(ringX + box.diameter / 2, ringTop + box.diameter / 2);
}

/// ONE ring placement for every surface that hosts the dual ring (the normal
/// one-handed scrubber and the APB align editor), so replacing the control bar
/// never moves or resizes the ring.
///
/// Mirrors `PhoneRingDialScrubber` exactly: [dialHeightPx] (the sticky panel
/// height) wins over `maxHeight * heightPct`; the x position is the user's slot
/// ratio inside the ring corridor; the radii come from the user's knob factors.
RingDialPlacement ringDialPlacement({
  required double panelWidth,
  required double maxHeight,
  double? dialHeightPx,
  double heightPct = 1.0,
  double outerRadiusFactor = 1.0,
  double innerRadiusFactor = kDefaultInnerRadiusFactor,
  double ringSlotT = 0.5,
  DialSide side = DialSide.inner,
  bool leftHanded = false,
}) {
  final RingDialBox box = dialHeightPx != null
      ? PhoneRingDialMath.dialBox(
          panelWidth: panelWidth,
          maxHeight: dialHeightPx,
          heightPct: 1.0,
        )
      : PhoneRingDialMath.dialBox(
          panelWidth: panelWidth,
          maxHeight: maxHeight,
          heightPct: heightPct,
        );
  final double ringX = PhoneRingDialMath.dialPlacementPx(
    box: box,
    leftHanded: leftHanded,
    side: side,
    ringSlotT: ringSlotT,
  );
  final RingDialGeometry geometry = PhoneRingDialMath.dialGeometry(
    size: Size.square(box.diameter),
    outerRadiusFactor: outerRadiusFactor,
    innerRadiusFactor: innerRadiusFactor,
  );
  return RingDialPlacement(box: box, ringX: ringX, geometry: geometry);
}
