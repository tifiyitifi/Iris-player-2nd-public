import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_dock.dart';
import 'package:iris/models/store/app_state.dart';

void main() {
  group('isFullscreenDockOverlayEnabled', () {
    bool enabled({
      bool desktop = true,
      bool meta = true,
      PlaylistPanelMode mode = PlaylistPanelMode.dockedRight,
      bool full = true,
      bool legacy = false,
    }) =>
        isFullscreenDockOverlayEnabled(
          isDesktop: desktop,
          useMetadataSettings: meta,
          mode: mode,
          isFullScreen: full,
          legacyStorage: legacy,
        );

    test('enabled only for meta desktop docked picture-fullscreen', () {
      expect(enabled(), isTrue);
    });

    test('window fullscreen is NOT gated here (isFullScreen false -> off)', () {
      expect(enabled(full: false), isFalse);
    });

    test('floating popup mode is untouched', () {
      expect(enabled(mode: PlaylistPanelMode.popup), isFalse);
    });

    test('legacy (metadata gate OFF) never enables the overlay', () {
      expect(enabled(meta: false), isFalse);
    });

    test('legacy-storage backend never enables the overlay', () {
      expect(enabled(legacy: true), isFalse);
    });

    test('mobile is excluded', () {
      expect(enabled(desktop: false), isFalse);
    });
  });

  group('isFullscreenDockPinnedOnEntry', () {
    test('keepPanel pins, hidePanel stays hidden by default', () {
      expect(
        isFullscreenDockPinnedOnEntry(SideFullscreenBehavior.keepPanel),
        isTrue,
      );
      expect(
        isFullscreenDockPinnedOnEntry(SideFullscreenBehavior.hidePanel),
        isFalse,
      );
    });
  });

  group('shouldConcealAfterExit', () {
    const region = Size(245, 300);
    test('exit landing inside the region is spurious (no conceal)', () {
      expect(
        shouldConcealAfterExit(
          regionSize: region,
          exitLocalPosition: const Offset(120, 150),
        ),
        isFalse,
      );
      expect(
        shouldConcealAfterExit(
          regionSize: region,
          exitLocalPosition: Offset.zero,
        ),
        isFalse,
      );
      expect(
        shouldConcealAfterExit(
          regionSize: region,
          exitLocalPosition: const Offset(244.5, 299.5),
        ),
        isFalse,
      );
    });

    test('exit landing outside the region conceals', () {
      expect(
        shouldConcealAfterExit(
          regionSize: region,
          exitLocalPosition: const Offset(-2, 150),
        ),
        isTrue,
      );
      expect(
        shouldConcealAfterExit(
          regionSize: region,
          exitLocalPosition: const Offset(245, 150),
        ),
        isTrue,
      );
      expect(
        shouldConcealAfterExit(
          regionSize: region,
          exitLocalPosition: const Offset(120, 300),
        ),
        isTrue,
      );
    });
  });

  group('isPointerOverControlPanel', () {
    const Rect bar = Rect.fromLTWH(760, 640, 380, 420);

    test('a pointer on the bar is excluded (a null rect excludes nothing)', () {
      expect(
        isPointerOverControlPanel(panelRect: bar, pointer: const Offset(1000, 900)),
        isTrue,
      );
      expect(
        isPointerOverControlPanel(panelRect: bar, pointer: const Offset(960, 660)),
        isTrue,
      );
      expect(
        isPointerOverControlPanel(panelRect: null, pointer: const Offset(1000, 900)),
        isFalse,
      );
    });

    test('a pointer beside the bar (same strip, other band) is not excluded',
        () {
      expect(
        isPointerOverControlPanel(panelRect: bar, pointer: const Offset(1000, 300)),
        isFalse,
      );
      expect(
        isPointerOverControlPanel(panelRect: bar, pointer: const Offset(500, 900)),
        isFalse,
      );
      // Bottom/right edges are exclusive — the bar's own pixels end there.
      expect(
        isPointerOverControlPanel(panelRect: bar, pointer: const Offset(1000, 1060)),
        isFalse,
      );
    });

    test('an off-screen bar (translated away while hidden) excludes nothing',
        () {
      const Rect offScreen = Rect.fromLTWH(760, 1180, 380, 420);
      expect(
        isPointerOverControlPanel(
          panelRect: offScreen,
          pointer: const Offset(1000, 900),
        ),
        isFalse,
      );
    });
  });

  group('clampFullscreenDockEdgePct', () {
    test('clamps to hard percentage bounds', () {
      expect(clampFullscreenDockEdgePct(10), 10);
      expect(clampFullscreenDockEdgePct(0), kFullscreenDockEdgeMinPct);
      expect(clampFullscreenDockEdgePct(-5), kFullscreenDockEdgeMinPct);
      expect(clampFullscreenDockEdgePct(999), kFullscreenDockEdgeMaxPct);
      expect(
        clampFullscreenDockEdgePct(double.nan),
        kFullscreenDockEdgeDefaultPct,
      );
    });

    test('defaults are consistent', () {
      expect(kFullscreenDockEdgeDefaultPct, 10);
      expect(kFullscreenDockEdgeMinPct, 0);
      expect(kFullscreenDockEdgeMaxPct, 50);
      expect(kFullscreenDockHideMargin, 5);
    });
  });

  group('resolveFullscreenDockEdgeWidth', () {
    test('percentage of the playback-area width', () {
      expect(
        resolveFullscreenDockEdgeWidth(pct: 10, maxWidth: 1920),
        closeTo(192, 1e-9),
      );
      expect(
        resolveFullscreenDockEdgeWidth(pct: 50, maxWidth: 800),
        closeTo(400, 1e-9),
      );
    });

    test('zero percent disables the strip', () {
      expect(resolveFullscreenDockEdgeWidth(pct: 0, maxWidth: 1920), 0);
    });

    test('out-of-range and non-finite inputs degrade cleanly', () {
      expect(
        resolveFullscreenDockEdgeWidth(pct: 80, maxWidth: 1000),
        closeTo(500, 1e-9),
      );
      expect(resolveFullscreenDockEdgeWidth(pct: 10, maxWidth: double.infinity), 0);
      expect(
        resolveFullscreenDockEdgeWidth(pct: double.nan, maxWidth: 1000),
        closeTo(100, 1e-9),
      );
    });
  });
}
