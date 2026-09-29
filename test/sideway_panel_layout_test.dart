import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/sideway_panel_layout.dart';
import 'package:iris/models/store/app_state.dart';

void main() {
  group('borderEdgesForAnchor — which panel edges sit on the window border', () {
    test('corner anchors touch two borders', () {
      expect(borderEdgesForAnchor(Alignment.bottomRight),
          (left: false, top: false, right: true, bottom: true));
      expect(borderEdgesForAnchor(Alignment.topLeft),
          (left: true, top: true, right: false, bottom: false));
    });

    test('edge anchors touch one border', () {
      expect(borderEdgesForAnchor(Alignment.bottomCenter),
          (left: false, top: false, right: false, bottom: true));
      expect(borderEdgesForAnchor(Alignment.centerLeft),
          (left: true, top: false, right: false, bottom: false));
    });

    test('center anchor floats — no border edges', () {
      expect(borderEdgesForAnchor(Alignment.center),
          (left: false, top: false, right: false, bottom: false));
    });
  });

  group('resizePlanForAnchor — 8-zone handle availability', () {
    test('bottom-right dock: only left width / top height / TL corner full', () {
      final plan = resizePlanForAnchor(Alignment.bottomRight);
      expect(plan.leftEdge, isTrue);
      expect(plan.topEdge, isTrue);
      expect(plan.rightEdge, isFalse);
      expect(plan.bottomEdge, isFalse);
      // Corners inherit the union of their two edges; absent when neither
      // edge is resizable.
      expect(plan.cornerTL, (w: true, h: true));
      expect(plan.cornerTR, (w: false, h: true)); // top only
      expect(plan.cornerBL, (w: true, h: false)); // left only
      expect(plan.cornerBR, isNull); // both edges on the border
    });

    test('center float: every zone is live', () {
      final plan = resizePlanForAnchor(Alignment.center);
      expect(plan.leftEdge, isTrue);
      expect(plan.rightEdge, isTrue);
      expect(plan.topEdge, isTrue);
      expect(plan.bottomEdge, isTrue);
      expect(plan.cornerTL, (w: true, h: true));
      expect(plan.cornerTR, (w: true, h: true));
      expect(plan.cornerBL, (w: true, h: true));
      expect(plan.cornerBR, (w: true, h: true));
    });

    test('bottom-center dock: top edge + both top corners only', () {
      final plan = resizePlanForAnchor(Alignment.bottomCenter);
      expect(plan.topEdge, isTrue);
      expect(plan.leftEdge, isTrue);
      expect(plan.rightEdge, isTrue);
      expect(plan.bottomEdge, isFalse);
      expect(plan.cornerTL, (w: true, h: true));
      expect(plan.cornerTR, (w: true, h: true));
      expect(plan.cornerBL, (w: true, h: false));
      expect(plan.cornerBR, (w: true, h: false));
    });
  });

  group('dialPctForWidthDrag — width/height coupling', () {
    const double gap = 8;

    test('widening lets the dial reclaim the freed height (max span)', () {
      // Bar dropped from 3 lines to 1: span grew from 400 to 760.
      final pct = dialPctForWidthDrag(
        widening: true,
        dialPxBefore: 380,
        availH: 800,
        gap: gap,
        barHAfter: 32,
      );
      expect(pct, closeTo(1.0, 1e-9)); // 760/760
    });

    test('narrowing retains the dial pixel height', () {
      // Bar wrapped from 1 line (32) to 3 lines (96): span shrank 760→696.
      final pct = dialPctForWidthDrag(
        widening: false,
        dialPxBefore: 700,
        availH: 800,
        gap: gap,
        barHAfter: 96,
      );
      // 700 / (800 - 96 - 8) = 700/696 → clamps at the 1.00 ceiling.
      expect(pct, closeTo(1.0, 1e-9));
    });

    test('narrowing retains partially while slack remains', () {
      final pct = dialPctForWidthDrag(
        widening: false,
        dialPxBefore: 560,
        availH: 800,
        gap: gap,
        barHAfter: 96,
      );
      expect(pct, closeTo(560 / 696, 1e-6));
    });

    test('degenerate zero span degrades to the ceiling, never NaN', () {
      final pct = dialPctForWidthDrag(
        widening: false,
        dialPxBefore: 400,
        availH: 8,
        gap: gap,
        barHAfter: 96,
      );
      expect(pct.isFinite, isTrue);
      expect(pct, 1.0);
    });
  });

  group('retained scale for the classic circle (0..1 knob)', () {
    test('maps a retained pixel height back onto the scale knob', () {
      // min 100, max 660: retained 380 → (380-100)/(660-100) = 0.5
      expect(
          classicScaleForRetainedPx(
              retainedPx: 380, minSize: 100, maxSize: 660),
          closeTo(0.5, 1e-9));
      expect(
          classicScaleForRetainedPx(
              retainedPx: 1000, minSize: 100, maxSize: 660),
          1.0);
      expect(
          classicScaleForRetainedPx(retainedPx: 20, minSize: 100, maxSize: 660),
          0.0);
    });
  });

  group('effectivePanelWidth — width floor follows the dial', () {
    test('panel never narrower than the dial, capped by the window', () {
      expect(
          effectivePanelWidth(
              draggedWidth: 300, dialDiameter: 420, maxWindowWidth: 1000),
          420);
      expect(
          effectivePanelWidth(
              draggedWidth: 800, dialDiameter: 420, maxWindowWidth: 1000),
          800);
      expect(
          effectivePanelWidth(
              draggedWidth: 800, dialDiameter: 420, maxWindowWidth: 600),
          600);
    });
  });

  group('clampExtent — drag limits survive a window smaller than the floor', () {
    test('an inverted range clamps instead of throwing (double.clamp guards)', () {
      // `double.clamp` throws ArgumentError whenever lower > upper, and a
      // window narrower than the panel floor (320px wide) inverts the drag
      // range on every pan update.
      expect(() => clampExtent(300, 260, 256), returnsNormally);
      expect(clampExtent(300, 260, 256), 260);
      expect(clampExtent(0, 260, 256), 256);
      expect(clampExtent(400, 200, 150), 200);
    });

    test('a normal range behaves exactly like clamp', () {
      expect(clampExtent(300, 200, 400), 300);
      expect(clampExtent(10, 200, 400), 200);
      expect(clampExtent(999, 200, 400), 400);
    });
  });

  group('bottom button rows hug the edge facing the screen centre', () {
    test('right-anchored panel aligns its rows LEFT (toward the centre)', () {
      expect(sidewayButtonAlignForAnchor(Alignment.bottomRight),
          WrapAlignment.start);
      expect(sidewayButtonRowAlignForAnchor(Alignment.bottomRight),
          MainAxisAlignment.start);
    });

    test('left-anchored panel aligns its rows RIGHT (toward the centre)', () {
      expect(
          sidewayButtonAlignForAnchor(Alignment.bottomLeft), WrapAlignment.end);
      expect(sidewayButtonRowAlignForAnchor(Alignment.bottomLeft),
          MainAxisAlignment.end);
    });

    test('centre anchor stays centred', () {
      expect(sidewayButtonAlignForAnchor(Alignment.bottomCenter),
          WrapAlignment.center);
      expect(sidewayButtonRowAlignForAnchor(Alignment.bottomCenter),
          MainAxisAlignment.center);
    });
  });

  group('hideTranslateForAnchor — direction-aware hide', () {
    // A phone panel is always anchored to a bottom corner, so on a phone this
    // function is the ONLY thing deciding which way the panel leaves — the
    // corner modes are live there, not decoration.
    const double w = 320;
    const double h = 700;
    const double m = 24;

    Offset at(Alignment anchor, SidePanelCornerHideMode mode) =>
        hideTranslateForAnchor(
          anchor: anchor,
          isLeftHanded: false,
          panelW: w,
          panelH: h,
          cornerMode: mode,
        );

    test('bottom-left corner: vertical drops, horizontal exits left', () {
      expect(at(Alignment.bottomLeft, SidePanelCornerHideMode.vertical),
          const Offset(0, h + m));
      expect(at(Alignment.bottomLeft, SidePanelCornerHideMode.horizontal),
          const Offset(-(w + m), 0));
      expect(at(Alignment.bottomLeft, SidePanelCornerHideMode.diagonal),
          const Offset(-(w + m), h + m));
    });

    test('bottom-right corner mirrors horizontally, keeps the drop', () {
      expect(at(Alignment.bottomRight, SidePanelCornerHideMode.vertical),
          const Offset(0, h + m));
      expect(at(Alignment.bottomRight, SidePanelCornerHideMode.horizontal),
          const Offset(w + m, 0));
      expect(at(Alignment.bottomRight, SidePanelCornerHideMode.diagonal),
          const Offset(w + m, h + m));
    });

    test('top corners exit upward', () {
      expect(at(Alignment.topLeft, SidePanelCornerHideMode.vertical),
          const Offset(0, -(h + m)));
      expect(at(Alignment.topRight, SidePanelCornerHideMode.horizontal),
          const Offset(w + m, 0));
      expect(at(Alignment.topRight, SidePanelCornerHideMode.diagonal),
          const Offset(w + m, -(h + m)));
    });

    test('edge middles ignore cornerMode entirely', () {
      for (final mode in SidePanelCornerHideMode.values) {
        expect(at(Alignment.bottomCenter, mode), const Offset(0, h + m));
        expect(at(Alignment.centerLeft, mode), const Offset(-(w + m), 0));
        expect(at(Alignment.centerRight, mode), const Offset(w + m, 0));
        expect(at(Alignment.topCenter, mode), const Offset(0, -(h + m)));
      }
    });

    test('a pure centre anchor has no edge — handedness decides', () {
      expect(
        hideTranslateForAnchor(
          anchor: Alignment.center,
          isLeftHanded: false,
          panelW: w,
          panelH: h,
          cornerMode: SidePanelCornerHideMode.diagonal,
        ),
        const Offset(w + m, 0),
        reason: 'cornerMode must not leak into the side fallback',
      );
      expect(
        hideTranslateForAnchor(
          anchor: Alignment.center,
          isLeftHanded: true,
          panelW: w,
          panelH: h,
        ),
        const Offset(-(w + m), 0),
      );
    });

    test('the default is the vertical drop', () {
      expect(
        hideTranslateForAnchor(
          anchor: Alignment.bottomRight,
          isLeftHanded: false,
          panelW: w,
          panelH: h,
        ),
        at(Alignment.bottomRight, SidePanelCornerHideMode.vertical),
      );
    });
  });

  group('dialDiameterForHide — the layout dial, in one call', () {
    test('a ring dial is the span share, floored at 150 and capped by width', () {
      expect(
        dialDiameterForHide(
          span: 300,
          panelW: 400,
          scrubberKind: PhoneSideScrubberKind.dial,
          ringDialHeightPct: 1.0,
          classicScale: 0.5,
        ),
        300,
      );
      // Narrow panel: the ring can never outgrow it.
      expect(
        dialDiameterForHide(
          span: 300,
          panelW: 200,
          scrubberKind: PhoneSideScrubberKind.dial,
          ringDialHeightPct: 1.0,
          classicScale: 0.5,
        ),
        200,
      );
      // Short span degrades to the span itself.
      expect(
        dialDiameterForHide(
          span: 90,
          panelW: 400,
          scrubberKind: PhoneSideScrubberKind.dial,
          ringDialHeightPct: 1.0,
          classicScale: 0.5,
        ),
        90,
      );
    });

    test('a classic circle tops out at 260 — past the phone 200 floor', () {
      expect(
        dialDiameterForHide(
          span: 400,
          panelW: 200,
          scrubberKind: PhoneSideScrubberKind.classic,
          ringDialHeightPct: 1.0,
          classicScale: 1.0,
        ),
        260,
      );
    });

    test('a degenerate span yields 0 rather than a negative', () {
      expect(
        dialDiameterForHide(
          span: 0,
          panelW: 400,
          scrubberKind: PhoneSideScrubberKind.dial,
          ringDialHeightPct: 1.0,
          classicScale: 1.0,
        ),
        0,
      );
    });
  });

  group('renderedPanelWidthFor — the box the layout really fills', () {
    test('agrees with the drag width when the dial is narrower', () {
      // Desktop default 380 wide, dial 260 → the floor never lifts it.
      expect(
        renderedPanelWidthFor(
          windowW: 1600, isPhone: false, widthPct: 40, widthPx: 380,
          dialDiameter: 260),
        380,
      );
    });

    test('lifts a phone panel to its classic circle (260 > the 200 floor)',
        () {
      // The mismatch this exists for: a phone panel dragged to its 200px
      // minimum while the classic dial is at its 260px maximum renders 260
      // wide, so a hide computed from the raw 200 leaves a 60px sliver.
      expect(
        renderedPanelWidthFor(
          windowW: 800, isPhone: true, widthPct: 25, widthPx: 380,
          dialDiameter: 260),
        260,
      );
    });

    test('never exceeds the window', () {
      expect(
        renderedPanelWidthFor(
          windowW: 240, isPhone: false, widthPct: 40, widthPx: 800,
          dialDiameter: 600),
        240,
      );
    });

    test('a ring dial (150 min) never lifts the desktop panel', () {
      expect(
        renderedPanelWidthFor(
          windowW: 1600, isPhone: false, widthPct: 40, widthPx: 260,
          dialDiameter: 150),
        260,
      );
    });
  });

  group('sidewayBarX — block position, side-relative 0..1', () {
    test('right-docked: 0 hugs the left (centre-facing) edge, 1 the right', () {
      expect(sidewayBarX(anchor: Alignment.bottomRight, pos: 0, free: 200), 0);
      expect(sidewayBarX(anchor: Alignment.bottomRight, pos: 1, free: 200), 200);
      expect(sidewayBarX(anchor: Alignment.bottomRight, pos: 0.5, free: 200),
          100);
    });

    test('left-docked mirrors: 0 hugs the right (centre-facing) edge', () {
      expect(sidewayBarX(anchor: Alignment.bottomLeft, pos: 0, free: 200), 200);
      expect(sidewayBarX(anchor: Alignment.bottomLeft, pos: 1, free: 200), 0);
      expect(sidewayBarX(anchor: Alignment.bottomLeft, pos: 0.5, free: 200),
          100);
    });

    test('centre anchor keeps the historical centred block (knob is a no-op)',
        () {
      expect(sidewayBarX(anchor: Alignment.bottomCenter, pos: 0, free: 200),
          100);
      expect(sidewayBarX(anchor: Alignment.bottomCenter, pos: 1, free: 200),
          100);
    });

    test('no free space (or out-of-range pos) never yields a negative offset',
        () {
      expect(sidewayBarX(anchor: Alignment.bottomRight, pos: 0, free: 0), 0);
      expect(sidewayBarX(anchor: Alignment.bottomRight, pos: 0, free: -40), 0);
      expect(sidewayBarX(anchor: Alignment.bottomRight, pos: 2, free: 200), 200);
      expect(sidewayBarX(anchor: Alignment.bottomRight, pos: -1, free: 200), 0);
    });
  });
}
