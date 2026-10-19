import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_dock.dart';
import 'package:iris/models/store/app_state.dart';

// 保侧边栏优先：竖屏 fitVideo 会把窗口收窄到 <1024，dock 意图仍须保留，
// 不得静默降级为浮动弹窗（视频区 letterbox 而非隐藏 dock）。
void main() {
  group('playlist dock keeps sidebar for narrow portrait windows', () {
    test('narrow portrait width (867) with dock intent stays docked', () {
      expect(
        shouldShowPlaylistDock(
          isDesktop: true,
          maxWidth: 867, // 720x1280 @150% (480) + dock chrome (~387)
          mode: PlaylistPanelMode.dockedRight,
          visible: true,
          isFullScreen: false,
          behavior: SideFullscreenBehavior.hidePanel,
          useMetadataSettings: true,
          legacyStorage: false,
        ),
        isTrue,
      );
    });

    test('dock intent helper ignores current width for resize reservation', () {
      expect(
        isDockIntentVisible(
          isDesktop: true,
          mode: PlaylistPanelMode.dockedRight,
          visible: true,
          isFullScreen: false,
          useMetadataSettings: true,
          legacyStorage: false,
        ),
        isTrue,
      );
    });

    test('gates still hold: fullscreen / hidden / popup / mobile', () {
      bool dock({
        required double w,
        required PlaylistPanelMode mode,
        required bool visible,
        required bool full,
        required bool desktop,
      }) =>
          shouldShowPlaylistDock(
            isDesktop: desktop,
            maxWidth: w,
            mode: mode,
            visible: visible,
            isFullScreen: full,
            behavior: SideFullscreenBehavior.hidePanel,
            useMetadataSettings: true,
            legacyStorage: false,
          );
      // Picture fullscreen never docks — floating only.
      expect(
        dock(
          w: 1600,
          mode: PlaylistPanelMode.dockedRight,
          visible: true,
          full: true,
          desktop: true,
        ),
        isFalse,
      );
      // User-hidden dock stays hidden.
      expect(
        dock(
          w: 867,
          mode: PlaylistPanelMode.dockedRight,
          visible: false,
          full: false,
          desktop: true,
        ),
        isFalse,
      );
      // Popup mode never docks.
      expect(
        dock(
          w: 867,
          mode: PlaylistPanelMode.popup,
          visible: true,
          full: false,
          desktop: true,
        ),
        isFalse,
      );
      // Mobile never docks.
      expect(
        dock(
          w: 867,
          mode: PlaylistPanelMode.dockedRight,
          visible: true,
          full: false,
          desktop: false,
        ),
        isFalse,
      );
    });

    test('legacy lifecycle removes the dock entirely', () {
      bool dock({
        required bool useMetadataSettings,
        required bool legacyStorage,
      }) =>
          shouldShowPlaylistDock(
            isDesktop: true,
            maxWidth: 1600,
            mode: PlaylistPanelMode.dockedRight,
            visible: true,
            isFullScreen: false,
            behavior: SideFullscreenBehavior.hidePanel,
            useMetadataSettings: useMetadataSettings,
            legacyStorage: legacyStorage,
          );

      // Metadata gate OFF (the dock feature's own "legacy mode") → no side panel.
      expect(
        dock(useMetadataSettings: false, legacyStorage: false),
        isFalse,
      );
      // Legacy-storage backend ON (even with metadata ON) → no side panel.
      expect(
        dock(useMetadataSettings: true, legacyStorage: true),
        isFalse,
      );
      // The meta-era default still docks.
      expect(
        dock(useMetadataSettings: true, legacyStorage: false),
        isTrue,
      );
    });
  });
}
