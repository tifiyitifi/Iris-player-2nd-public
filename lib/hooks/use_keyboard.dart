import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/services/segment_edit_guard.dart';
import 'package:iris/features/background_playback/view/player_control_target_scope.dart'
    show resolveActivePlayer;
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/osd/engine/osd_texts.dart';
import 'package:iris/features/osd/engine/show_player_osd.dart';
import 'package:iris/features/paginated_browser/widgets/list_keyboard_scope.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_dock.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/resolve_keyboard_scheme.dart';
import 'package:iris/features/windows/desktop_keyboard/executor/potplayer_key_executor.dart';
import 'package:iris/globals.dart';
import 'package:iris/hooks/use_global_keyboard.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/utils/app_exit.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/bottom_sheets/show_open_link_bottom_sheet.dart';
import 'package:iris/widgets/dialogs/show_open_link_dialog.dart';
import 'package:iris/widgets/popup.dart';
import 'package:iris/widgets/popups/history.dart';
import 'package:iris/widgets/popups/play_queue.dart';
import 'package:iris/widgets/popups/settings/settings.dart';
import 'package:iris/widgets/popups/storages/storages.dart';
import 'package:iris/widgets/popups/track/subtitle_and_audio_track.dart';
import 'package:provider/provider.dart';

typedef KeyboardEvent = void Function(KeyEvent event);

KeyboardEvent useKeyboard({
  required void Function() showControl,
  required Future<void> Function(Future<void>) showControlForHover,
  required void Function() showProgress,
}) {
  final context = useContext();
  // Build-phase reactive read; captured here so the async key handler can use
  // the popup direction without calling context.select outside of build.
  final popupDirection =
      useAppStore().select(context, (s) => s.defaultPopupDirection);

  // Effective keyboard scheme: potplayer only manifests while the metadata
  // gate is ON — resolveKeyboardScheme degrades to legacy otherwise, so
  // legacy-blob users keep today's bindings no matter what is stored.
  final storedScheme =
      useAppStore().select(context, (s) => s.keyboardShortcutScheme);
  final metadataGate =
      useAppStore().select(context, (s) => s.useMetadataSettings);
  final scheme = resolveKeyboardScheme(
    stored: storedScheme,
    metadataEnabled: metadataGate && MetaSettingsModule.ready,
  );
  // Captured per build for async OSD text (frame step); the context itself
  // must not cross the async gap.
  final t = getLocalizations(context);

  void onKeyEvent(KeyEvent event) async {
    // Global-intake relevance guards (see use_global_keyboard.dart): skip
    // when another route (dialog / popup) is current — those handle their
    // own keys — and while the user is typing in any text field.
    if (!playerKeysAllowed(context)) return;

    // A focused playlist list owns its PotPlayer PL keys (its own `↑/↓` cursor
    // navigation, `P`, `Del`, sort, type-ahead, ...). Skip them here so they do
    // not ALSO drive the player — the `↑/↓`-also-changes-volume double action.
    // Only an enabled metadata-era list scope reports ownership, so legacy and
    // non-list surfaces are unaffected.
    if (ListKeyboardScope.ownsKey(event)) return;

    // While 副音 is the control target the shortcuts drive the background
    // engine; otherwise today's foreground player (byte-identical path).
    final player = resolveActivePlayer(context);

    // fb/bg align edit mode: the pair is locked, so almost every shortcut is
    // swallowed. Only play/pause and ±seek stay live (the panel offers them as
    // buttons too).
    if (SegmentEditGuard.transportFrozen) {
      if (event is! KeyDownEvent) return;
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.mediaPlayPause) {
        if (player.isPlaying) {
          player.pause();
        } else {
          player.play();
        }
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        await player.backward(5);
      } else if (key == LogicalKeyboardKey.arrowRight) {
        await player.forward(5);
      }
      return;
    }

    if (scheme == KeyboardShortcutScheme.potplayer) {
      await PotPlayerKeyExecutor(
        context: context,
        player: player,
        showControl: showControl,
        showControlForHover: showControlForHover,
        showProgress: showProgress,
      ).handle(event);
      return;
    }

    if (event.runtimeType == KeyDownEvent) {
      if (HardwareKeyboard.instance.isAltPressed) {
        switch (event.logicalKey) {
          // 退出
          case LogicalKeyboardKey.keyX:
            showControl();
            await AppExit.run(player.saveProgress);
        }
        return;
      }

      if (HardwareKeyboard.instance.isControlPressed) {
        // Ctrl+\ — toggle playlist dock mode (desktop meta-driven only)
        if (event.logicalKey == LogicalKeyboardKey.backslash) {
          if (isDesktop && useAppStore().state.useMetadataSettings) {
            await useAppStore().togglePlaylistPanelMode();
            showControl();
          }
          return;
        }
        switch (event.logicalKey) {
          // 设置
          case LogicalKeyboardKey.keyP:
            showControlForHover(
              showPopup(
                context: context,
                child: const Settings(),
                direction: popupDirection,
              ),
            );
            break;
          // 打开文件
          case LogicalKeyboardKey.keyO:
            showControl();
            await pickLocalFile();
            showControl();
            break;
          // 随机
          case LogicalKeyboardKey.keyX:
            showControl();
            await PlaybackProviderRegistry.toggleShuffle();
            break;
          // 循环
          case LogicalKeyboardKey.keyR:
            showControl();
            await PlaybackProviderRegistry.toggleRepeat();
            break;
          // 视频缩放
          case LogicalKeyboardKey.keyV:
            showControl();
            useAppStore().toggleFit();
            break;
          // 历史
          case LogicalKeyboardKey.keyH:
            showControlForHover(
              showPopup(
                context: context,
                child: const History(),
                direction: popupDirection,
              ),
            );
            break;
          // 打开链接
          case LogicalKeyboardKey.keyL:
            showControl();
            isDesktop ? await showOpenLinkDialog(context) : await showOpenLinkBottomSheet(context);
            showControl();
            break;
          // 关闭当前播放媒体文件
          case LogicalKeyboardKey.keyC:
            showControl();
            player.pause();
            PlaybackProviderRegistry.stop();
            break;
          // 静音
          case LogicalKeyboardKey.keyM:
            showControl();
            useAppStore().toggleMute();
            break;
          default:
            break;
        }
        return;
      }

      final playerUiState = usePlayerUiStore().state;
      switch (event.logicalKey) {
        // 播放 | 暂停
        case LogicalKeyboardKey.space:
        case LogicalKeyboardKey.mediaPlayPause:
          showControl();
          if (player.isPlaying) {
            useAppStore().updateAutoPlay(false);
            player.pause();
          } else {
            useAppStore().updateAutoPlay(true);
            player.play();
          }
          break;
        // 上一个
        case LogicalKeyboardKey.mediaTrackPrevious:
          PlaybackProviderRegistry.step(forward: false);
          showControl();
          break;
        // 下一个
        case LogicalKeyboardKey.mediaTrackNext:
          showControl();
          PlaybackProviderRegistry.step(forward: true);
          break;
        // 存储
        case LogicalKeyboardKey.keyF:
          showControlForHover(
            showPopup(
              context: context,
              child: const Storages(),
              direction: popupDirection,
            ),
          );
          break;
        // 播放队列（侧边优先：窄竖屏仍切侧边显隐，不降级浮动）
        case LogicalKeyboardKey.keyP:
          {
            final app = useAppStore().state;
            final isDock = isDesktop &&
                app.useMetadataSettings &&
                app.playlistPanelMode == PlaylistPanelMode.dockedRight;
            if (isDock) {
              // Picture fullscreen uses the separate runtime overlay state;
              // windowed keeps the persisted visible flag.
              if (isFullscreenDockOverlayEnabled(
                isDesktop: isDesktop,
                useMetadataSettings: app.useMetadataSettings,
                mode: app.playlistPanelMode,
                isFullScreen: playerUiState.isFullScreen,
              )) {
                // Pin toggles on the pin state alone: hovering (peek) + P
                // pins it open instead of dismissing it.
                final bool pinned =
                    usePlayerUiStore().state.isFullscreenDockPinned;
                usePlayerUiStore().updateIsFullscreenDockPeeking(false);
                usePlayerUiStore().updateIsFullscreenDockPinned(!pinned);
              } else {
                await useAppStore().togglePlaylistPanelVisible();
              }
              showControl();
            } else {
              showControlForHover(
                showPopup(
                  context: context,
                  child: const PlayQueue(),
                  direction: popupDirection,
                ),
              );
            }
          }
          break;
        // 字幕和音轨
        case LogicalKeyboardKey.keyS:
          showControlForHover(
            showPopup(
              context: context,
              child: Provider<MediaPlayer>.value(
                value: context.read<MediaPlayer>(),
                child: const SubtitleAndAudioTrack(),
              ),
              direction: popupDirection,
            ),
          );
          break;
        // 退出全屏 / 关闭侧边列表
        case LogicalKeyboardKey.escape:
          if (isDesktop) {
            final app = useAppStore().state;
            // Picture-fullscreen overlay first: close the (pinned or peeked)
            // panel before leaving fullscreen.
            final ui = usePlayerUiStore().state;
            if (ui.isFullscreenDockPinned || ui.isFullscreenDockPeeking) {
              usePlayerUiStore().updateIsFullscreenDockPinned(false);
              usePlayerUiStore().updateIsFullscreenDockPeeking(false);
              break;
            }
            final isDockVisible = app.useMetadataSettings &&
                app.playlistPanelMode == PlaylistPanelMode.dockedRight &&
                app.playlistPanelVisible &&
                !(app.sideFullscreenBehavior == SideFullscreenBehavior.hidePanel && playerUiState.isFullScreen);
            if (isDockVisible) {
              await useAppStore().updatePlaylistPanelVisible(false);
              break;
            }
            if (playerUiState.isFullScreen) {
              await usePlayerUiStore().updateFullScreen(false);
            }
          }
          break;
        // 全屏
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.f11:
          if (isDesktop) {
            usePlayerUiStore().updateFullScreen(!playerUiState.isFullScreen);
          }
          break;
        case LogicalKeyboardKey.tab:
          showControl();
          break;
        case LogicalKeyboardKey.f10:
          showControl();
          await usePlayerUiStore().toggleIsAlwaysOnTop();
          break;
        case LogicalKeyboardKey.contextMenu:
          showControl();
          moreMenuKeyNotifier.value?.currentState?.showButtonMenu();
          break;
        default:
          break;
      }
    }

    // Releasing a held ←/→ must stop the step burst (see
    // StepSeekChain.collapseOnRelease): without this a held arrow key keeps
    // walking its auto-repeated backlog long after the key was let go.
    if (event is KeyUpEvent &&
        (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight)) {
      await player.endStepBurst?.call();
      return;
    }

    if (event.runtimeType == KeyDownEvent || event.runtimeType == KeyRepeatEvent) {
      switch (event.logicalKey) {
        // 快退
        case LogicalKeyboardKey.arrowLeft:
          if (usePlayerUiStore().state.isShowControl) {
            showControl();
          } else {
            showProgress();
          }
          player.backward(5);
          break;
        // 快进
        case LogicalKeyboardKey.arrowRight:
          if (usePlayerUiStore().state.isShowControl) {
            showControl();
          } else {
            showProgress();
          }
          player.forward(5);
          break;
        // 提升音量
        case LogicalKeyboardKey.arrowUp:
          showControl();
          await useAppStore().updateVolume(useAppStore().state.volume + 1);
          break;
        // 降低音量
        case LogicalKeyboardKey.arrowDown:
          showControl();
          await useAppStore().updateVolume(useAppStore().state.volume - 1);
          break;
        // 帧步进（= / -）：点按暂停后单步，长按连帧（KeyRepeat 一并送达，
        // PotPlayer 快速逐帧一致性；后端 stepForward/stepBackward 自带先暂停 + OSD）。
        case LogicalKeyboardKey.equal:
          await player.stepForward();
          showPlayerOsd(OsdTexts.frame(true, t));
          break;
        case LogicalKeyboardKey.minus:
          await player.stepBackward();
          showPlayerOsd(OsdTexts.frame(false, t));
          break;
        default:
          break;
      }
    }
  }

  return onKeyEvent;
}
