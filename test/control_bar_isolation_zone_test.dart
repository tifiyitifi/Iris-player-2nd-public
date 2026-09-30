import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_dock.dart';

/// The picture-fullscreen queue summon strip reserves a bottom ISOLATION zone
/// for the current control bar: `isolation height = bar height + pct% of the
/// area height`. The pointer inside it does not summon the queue, whether or
/// not the bar is currently shown. Both control-bar shapes share the formula —
/// the side-type panel passes its settings height, the normal long-strip bar
/// its measured render height.
void main() {
  group('resolveControlBarIsolationHeight', () {
    test('adds pct% of the area height to the bar height', () {
      expect(
        resolveControlBarIsolationHeight(
            controlBarHeight: 420, areaHeight: 1080, pct: 5),
        closeTo(420 + 54, 0.001),
      );
    });

    test('the normal-bar shape uses the measured bar height', () {
      expect(
        resolveControlBarIsolationHeight(
            controlBarHeight: 120, areaHeight: 1000, pct: 25),
        closeTo(120 + 250, 0.001),
      );
    });

    test('a zero percentage leaves just the bar height', () {
      expect(
        resolveControlBarIsolationHeight(
            controlBarHeight: 120, areaHeight: 1000, pct: 0),
        closeTo(120, 0.001),
      );
    });

    test('clamps to the area height', () {
      expect(
        resolveControlBarIsolationHeight(
            controlBarHeight: 1080, areaHeight: 1080, pct: 50),
        closeTo(1080, 0.001),
      );
      expect(
        resolveControlBarIsolationHeight(
            controlBarHeight: 5000, areaHeight: 1080, pct: 5),
        closeTo(1080, 0.001),
      );
    });

    test('degenerate area disables the isolation zone', () {
      expect(
        resolveControlBarIsolationHeight(
            controlBarHeight: 420, areaHeight: 0, pct: 5),
        0,
      );
      expect(
        resolveControlBarIsolationHeight(
            controlBarHeight: 420, areaHeight: double.infinity, pct: 5),
        0,
      );
    });
  });

  group('clamp helpers', () {
    test('side-panel pct is 0..50 with a 5 default fallback', () {
      expect(clampSidePanelIsolationPct(30), 30);
      expect(clampSidePanelIsolationPct(-1), 0);
      expect(clampSidePanelIsolationPct(80), 50);
      expect(
          clampSidePanelIsolationPct(double.nan), kSidePanelIsolationDefaultPct);
    });

    test('normal-bar pct is 0..100 with a 25 default fallback', () {
      expect(clampLinearBarIsolationPct(30), 30);
      expect(clampLinearBarIsolationPct(-1), 0);
      expect(clampLinearBarIsolationPct(200), 100);
      expect(clampLinearBarIsolationPct(double.nan),
          kLinearBarIsolationDefaultPct);
    });
  });

  group('isPointerInControlBarIsolationZone', () {
    test('blocks only at or below the zone top edge', () {
      // area 100, zone 30 -> threshold at y = 70.
      expect(
        isPointerInControlBarIsolationZone(
            localY: 69.9, areaHeight: 100, isolationHeight: 30),
        isFalse,
      );
      expect(
        isPointerInControlBarIsolationZone(
            localY: 70, areaHeight: 100, isolationHeight: 30),
        isTrue,
      );
      expect(
        isPointerInControlBarIsolationZone(
            localY: 100, areaHeight: 100, isolationHeight: 30),
        isTrue,
      );
    });

    test('a non-positive zone never blocks', () {
      for (final double h in <double>[0, -1]) {
        expect(
          isPointerInControlBarIsolationZone(
              localY: 99, areaHeight: 100, isolationHeight: h),
          isFalse,
        );
      }
    });
  });
}
