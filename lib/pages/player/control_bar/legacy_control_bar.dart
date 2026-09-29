import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/services/segment_edit_guard.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/windows/desktop_keyboard/view/shortcut_hints.dart';
import 'package:iris/globals.dart'
    show moreMenuKeyNotifier, rateMenuKeyNotifier, speedStops;
import 'package:iris/hooks/use_published_global_key.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/pages/player/control_bar/circle_slider_landscepe_percent_control.dart';
import 'package:iris/pages/player/control_bar/control_bar_slider.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/control_bar_circle_slider.dart';
import 'package:iris/pages/player/control_bar/volume_control.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/app_exit.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/a11y_tooltip.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/bottom_sheets/show_open_link_bottom_sheet.dart';
import 'package:iris/widgets/dialogs/show_open_link_dialog.dart';
import 'package:iris/widgets/dialogs/show_rate_dialog.dart';
import 'package:iris/widgets/popup.dart';
import 'package:iris/widgets/popups/history.dart';
import 'package:iris/widgets/popups/play_queue.dart';
import 'package:iris/widgets/popups/settings/settings.dart';
import 'package:iris/widgets/popups/storages/storages.dart';
import 'package:iris/widgets/popups/track/subtitle_and_audio_track.dart';
import 'package:provider/provider.dart';

// We keep two ControlBar implementations on purpose:
//
// - LegacyControlBar: frozen, stable behavior
// - ControlBar: new/refactored version under active development
//
// This split allows us to evolve the new UI without risking regressions
// in the existing playback experience. The legacy version must remain
// untouched so we always have a known-good fallback.
//
// This reduces cognitive load when refactoring and makes failures local
// instead of system-wide (see: A Philosophy of Software Design).
class LegacyControlBar extends HookWidget {
  const LegacyControlBar({
    super.key,
    required this.showControl,
    required this.showControlForHover,
    this.color,
    this.overlayColor,
  });

  final void Function() showControl;
  final Future<void> Function(Future<void> callback) showControlForHover;
  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;

    // Per-mount keys published for the keyboard shortcuts (see
    // `usePublishedGlobalKey`): never shared objects.
    final GlobalKey<PopupMenuButtonState> rateMenuKey =
        usePublishedGlobalKey(rateMenuKeyNotifier);
    final GlobalKey<PopupMenuButtonState> moreMenuKey =
        usePublishedGlobalKey(moreMenuKeyNotifier);

    final t = getLocalizations(context);
    final scheme = useEffectiveKeyboardScheme(context);
    String hint(ShortcutHintKind kind) =>
        shortcutHintLabelFor(kind, scheme) ?? '';

    final isPlaying = context.select<MediaPlayer, bool>((player) => player.isPlaying);

    final isInitializing = context.select<MediaPlayer, bool>((player) => player.isInitializing);

    final rate = useAppStore().select(context, (state) => state.rate);
    final volume = useAppStore().select(context, (state) => state.volume);
    final isMuted = useAppStore().select(context, (state) => state.isMuted);

    final isFullScreen = usePlayerUiStore().select(context, (state) => state.isFullScreen);
    final store = usePlayQueueStore();
    final int playQueueLength = store.select(context, (state) => state.playQueue.length);
    // The queue total is a SEPARATE signal from the list length: in query mode
    // the synthetic state is pinned to one item, so `playQueue.length` is
    // always 1 and a bare `store.totalCount` read left prev/next visibility
    // frozen when a search/filter moved the total 1↔N. Subscribing to the
    // store's published mirror makes showTransport recompute.
    final int totalCount = useValueListenable(store.totalCountNotifier);

    final bool appShuffle = useAppStore().select(context, (state) => state.shuffle);
    final Repeat appRepeat = useAppStore().select(context, (state) => state.repeat);
    final BoxFit fit = useAppStore().select(context, (state) => state.fit);

    // 副音 retarget (parity with the new bar): while the controls drive the
    // background runtime, transport/shuffle/repeat must read and act on the
    // 副音 queue instead of the foreground one.
    final bg = useBackgroundPlaybackStore();
    final bool bgIsControl =
        bg.select(context, (s) => s.bgOwnsControls);
    // Hook order must stay stable: read BOTH sides unconditionally, then pick.
    final bool bgShuffle = bg.select(context, (s) => s.shuffle);
    final Repeat bgRepeat = bg.select(context, (s) => s.bgRepeat);
    final int bgQueueLength = bg.select(context, (s) => s.queue.length);
    final bool shuffle = bgIsControl ? bgShuffle : appShuffle;
    final Repeat repeat = bgIsControl ? bgRepeat : appRepeat;

    final bool isSeeking = useScrubDragStore().select(
      context,
      (state) => state.isScrubbing,
    );

    final displayIsPlaying = useState(isPlaying);

    final PhoneLandscapeSliderType phoneLandscapeSliderType =
        useAppStore().select(context, (state) => state.phoneLandscapeSliderType);
    // Same gate the anchor resolver applies: the meta gate retires the legacy
    // circle placement, so a leftover enum mounts nothing here either.
    final bool metaSettingsOn =
        useAppStore().select(context, (state) => state.useMetadataSettings);
    final circleSliderPanelWidthPercent =
        useAppStore().select(context, (state) => state.circleLandscapePercent);

    final runtimeOrientation = useAppStore().select(context, (state) => state.runtimeOrientation);
    final realOrientation = MediaQuery.of(context).orientation;
    final popupDirection = useAppStore().select(context, (s) => s.defaultPopupDirection);

    final bool isLandscape = () {
      switch (runtimeOrientation) {
        case ScreenOrientation.landscape:
          return true;
        case ScreenOrientation.portrait:
          return false;
        case ScreenOrientation.device:
          return realOrientation == Orientation.landscape;
      }
    }();

    final bool useCircleSlider = useLegacyCircleSliderPanel(
      metadataEnabled: metaSettingsOn,
      isPhone: isMobilePlatform,
      isLandscape: isLandscape,
      sliderType: phoneLandscapeSliderType,
    );

    final playQueue = usePlayQueueStore().select(context, (state) => state.playQueue);
    final currentIndex = usePlayQueueStore().select(context, (state) => state.currentIndex);

    final FileItem? file = useMemoized(() {
      final index = playQueue.indexWhere((element) => element.index == currentIndex);
      return playQueue.isEmpty || index < 0 ? null : playQueue[index].file;
    }, [playQueue, currentIndex]);

    useEffect(() {
      if (!isSeeking) {
        displayIsPlaying.value = isPlaying;
      }
      return null;
    }, [isPlaying]);

    final playPauseButton = Stack(
      alignment: Alignment.center,
      children: [
        if (isInitializing)
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 4,
              color: Theme.of(context).colorScheme.surface,
            ),
          ),
        a11yTooltipIconButton(
        context: context,
        tooltip: '${displayIsPlaying.value ? t.pause : t.play} ( ${hint(ShortcutHintKind.playPause)} )',
          icon: Icon(
            displayIsPlaying.value ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 32,
            color: color,
          ),
          onPressed: () {
            showControl();
            if (isPlaying == true) {
              useAppStore().updateAutoPlay(false);
              context.read<MediaPlayer>().pause();
            } else {
              useAppStore().updateAutoPlay(true);
              context.read<MediaPlayer>().play();
            }
          },
          style: ButtonStyle(overlayColor: overlayColor),
        ),
      ],
    );

    final stopButton = a11yTooltipIconButton(
        context: context,
        tooltip: '${t.stop} ( ${hint(ShortcutHintKind.stop)} )',
      icon: Icon(
        Icons.stop_rounded,
        size: 26,
        color: color,
      ),
      onPressed: () {
        showControl();
        useAppStore().updateAutoPlay(false);
        context.read<MediaPlayer>().pause();
        PlaybackProviderRegistry.stop();
      },
      style: ButtonStyle(overlayColor: overlayColor),
    );

    // Visibility follows the queue the controls actually drive: while 副音 owns
    // the controls, the 副音 queue length decides whether prev/next appear.
    final bool showTransport = bgIsControl
        ? bgQueueLength > 1
        : (store.isQueryMode ? totalCount : playQueueLength) > 1;

    final prevButton = showTransport
        ? a11yTooltipIconButton(
        context: context,
        tooltip: '${t.previous} ( ${hint(ShortcutHintKind.previous)} )',
            icon: Icon(
              Icons.skip_previous_rounded,
              size: 26,
              color: color,
            ),
            onPressed: () {
              if (SegmentEditGuard.transportFrozen) return;
              showControl();
              if (bgIsControl) {
                bg.step(forward: false, userInitiated: true);
              } else {
                PlaybackProviderRegistry.step(forward: false);
              }
            },
            style: ButtonStyle(overlayColor: overlayColor),
          )
        : const SizedBox.shrink();

    final nextButton = showTransport
        ? a11yTooltipIconButton(
        context: context,
        tooltip: '${t.next} ( ${hint(ShortcutHintKind.next)} )',
            icon: Icon(
              Icons.skip_next_rounded,
              size: 26,
              color: color,
            ),
            onPressed: () {
              if (SegmentEditGuard.transportFrozen) return;
              showControl();
              if (bgIsControl) {
                bg.step(forward: true, userInitiated: true);
              } else {
                PlaybackProviderRegistry.step(forward: true);
              }
            },
            style: ButtonStyle(overlayColor: overlayColor),
          )
        : const SizedBox.shrink();

    final shuffleButton = Builder(
      builder: (context) => a11yTooltipIconButton(
        context: context,
        tooltip: '${t.shuffle}: ${shuffle ? t.on : t.off} ( ${hint(ShortcutHintKind.shuffle)} )',
        icon: Icon(
          Icons.shuffle_rounded,
          size: 20,
          color: !shuffle ? color?.withAlpha(153) : color,
        ),
        onPressed: () {
          showControl();
          if (bgIsControl) {
            bg.toggleShuffle();
            return;
          }
          shuffle ? usePlayQueueStore().sort() : usePlayQueueStore().shuffle();
          useAppStore().updateShuffle(!shuffle);
        },
        style: ButtonStyle(overlayColor: overlayColor),
      ),
    );

    final repeatButton = Builder(
      builder: (context) => a11yTooltipIconButton(
        context: context,
        tooltip:
            '${repeat == Repeat.one ? t.repeat_one : repeat == Repeat.all ? t.repeat_all : t.repeat_none} ( ${hint(ShortcutHintKind.repeat)} )',
        icon: Icon(
          repeat == Repeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
          size: 20,
          color: repeat == Repeat.none ? color?.withAlpha(153) : color,
        ),
        onPressed: () {
          showControl();
          if (bgIsControl) {
            bg.cycleBgRepeat();
            return;
          }
          useAppStore().toggleRepeat();
        },
        style: ButtonStyle(overlayColor: overlayColor),
      ),
    );

    final fitButton = a11yTooltipIconButton(
        context: context,
        tooltip:
          '${t.video_zoom}: ${fit == BoxFit.contain ? t.fit : fit == BoxFit.fill ? t.stretch : fit == BoxFit.cover ? t.crop : '100%'} ( ${hint(ShortcutHintKind.fit)} )',
      icon: Icon(
        fit == BoxFit.contain
            ? Icons.fit_screen_rounded
            : fit == BoxFit.fill
                ? Icons.aspect_ratio_rounded
                : fit == BoxFit.cover
                    ? Icons.crop_landscape_rounded
                    : Icons.crop_free_rounded,
        size: 20,
        color: color,
      ),
      onPressed: () {
        showControl();
        useAppStore().toggleFit();
      },
      style: ButtonStyle(overlayColor: overlayColor),
    );

    final rateButton = PopupMenuButton(
      key: rateMenuKey,
      clipBehavior: Clip.hardEdge,
      constraints: const BoxConstraints(minWidth: 0),
      itemBuilder: (BuildContext context) => speedStops
          .map(
            (item) => PopupMenuItem(
              child: Text(
                '${item}X',
                style: TextStyle(
                  color: item == rate ? Theme.of(context).colorScheme.primary : null,
                  fontWeight: item == rate ? FontWeight.bold : FontWeight.w100,
                  height: 1,
                ),
              ),
              onTap: () async {
                showControl();
                useAppStore().updateRate(item);
              },
            ),
          )
          .toList(),
      // AXTree stability (#182444): tap-only tooltip under a UIA client.
      child: a11yTooltip(
        context: context,
        message: t.playback_speed,
        child: TextButton(
          onPressed: () => rateMenuKey.currentState?.showButtonMenu(),
          style: ButtonStyle(overlayColor: overlayColor),
          child: Text(
            '${rate}X',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
      ),
    );

    final volumeWidget = width < 768
        ? Builder(
            builder: (context) => a11yTooltipIconButton(
        context: context,
        tooltip: '${t.volume}: $volume',
              icon: Icon(
                isMuted || volume == 0
                    ? Icons.volume_off_rounded
                    : volume < 50
                        ? Icons.volume_down_rounded
                        : Icons.volume_up_rounded,
                size: 20,
                color: color,
              ),
              onPressed: () => showControlForHover(
                showVolumePopover(context, showControl),
              ),
              style: ButtonStyle(overlayColor: overlayColor),
            ),
          )
        : SizedBox(
            width: 160,
            child: VolumeControl(
              showControl: showControl,
              showVolumeText: false,
              color: color,
              overlayColor: overlayColor,
            ),
          );

/*    final circleSliderPanelWidthWidget = Builder(
      builder: (context) => a11yTooltipIconButton(
        context: context,
        tooltip: '${t.circle_slider_landscape_percent}: $circleSliderPanelWidthPercent',
        icon: Icon(
          Icons.space_bar,
          size: 20,
          color: color,
        ),
        onPressed: () => showControlForHover(
          showCircleSliderLandscapePercentPopover(context, showControl),
        ),
        style: ButtonStyle(overlayColor: overlayColor),
      ),
    );*/

    final sliderWidget = ControlBarSlider(showControl: showControl, color: color);

    final circleSliderWidget = ControlBarCircleSlider(showControl: showControl, color: color);

    final subtitleButton = a11yTooltipIconButton(
        context: context,
        tooltip: '${t.subtitle_and_audio_track} ( ${hint(ShortcutHintKind.subtitleAudio)} )',
      icon: Icon(
        Icons.subtitles_rounded,
        size: 20,
        color: color,
      ),
      onPressed: () async {
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
      },
      style: ButtonStyle(overlayColor: overlayColor),
    );

    final playQueueButton = a11yTooltipIconButton(
        context: context,
        tooltip: '${t.play_queue} ( ${hint(ShortcutHintKind.playQueue)} )',
      icon: Transform.translate(
        offset: const Offset(1, 1.5),
        child: Icon(
          Icons.playlist_play_rounded,
          size: 28,
          color: color,
        ),
      ),
      onPressed: () async {
        showControlForHover(
          showPopup(
            context: context,
            child: const PlayQueue(),
            direction: popupDirection,
          ),
        );
      },
      style: ButtonStyle(overlayColor: overlayColor),
    );

    final storageButton = a11yTooltipIconButton(
        context: context,
        tooltip: '${t.storage} ( ${hint(ShortcutHintKind.storage)} )',
      icon: Icon(
        Icons.storage_rounded,
        size: 18,
        color: color,
      ),
      onPressed: () => showControlForHover(
        showPopup(
          context: context,
          child: const Storages(),
          direction: popupDirection,
        ),
      ),
      style: ButtonStyle(overlayColor: overlayColor),
    );

    final fullscreenButton = a11yTooltipIconButton(
        context: context,
        tooltip: isFullScreen
          ? '${t.exit_fullscreen} ( ${hint(ShortcutHintKind.fullscreen)} )'
          : '${t.enter_fullscreen} ( ${hint(ShortcutHintKind.fullscreen)} )',
      icon: Icon(
        isFullScreen ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded,
        size: 19,
        color: color,
      ),
      onPressed: () async {
        showControl();
        usePlayerUiStore().updateFullScreen(!isFullScreen);
      },
      style: ButtonStyle(overlayColor: overlayColor),
    );

    const double mobileBreakpoint = 640.0;
    const double tabletBreakpoint = 1024.0;

    final rotateOrVolumeWidget = (Platform.isAndroid || Platform.isIOS)
        ? a11yTooltipIconButton(
        context: context,
        tooltip: '${t.screen_rotation} ',
            icon: Icon(
              Icons.screen_rotation,
              size: 26,
              color: color,
            ),
            onPressed: () {
              showControl();
              final curOrientation = MediaQuery.of(context).orientation;
              if (curOrientation == Orientation.portrait) {
                useAppStore().updateRuntimeOrientation(ScreenOrientation.landscape);
              } else {
                useAppStore().updateRuntimeOrientation(ScreenOrientation.portrait);
              }
            },
            style: ButtonStyle(overlayColor: overlayColor),
          )
        : volumeWidget;

    final moreMenuButton = PopupMenuButton(
      key: moreMenuKey,
      icon: Icon(
        Icons.more_vert_rounded,
        size: 20,
        color: color,
      ),
      style: ButtonStyle(overlayColor: overlayColor),
      clipBehavior: Clip.hardEdge,
      constraints: const BoxConstraints(minWidth: 200),
      itemBuilder: (BuildContext context) => [
        PopupMenuItem(
          child: ListTile(
            mouseCursor: SystemMouseCursors.click,
            leading: const Icon(
              Icons.file_open_rounded,
              size: 16.5,
            ),
            title: Text(t.open_file),
            trailing: Text(
              'Ctrl + O',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).dividerColor,
              ),
            ),
          ),
          onTap: () async {
            showControl();
            if (Platform.isAndroid) {
              await pickContentFile();
            } else {
              await pickLocalFile();
            }
            showControl();
          },
        ),
        PopupMenuItem(
          child: ListTile(
            mouseCursor: SystemMouseCursors.click,
            leading: const Icon(
              Icons.file_present_rounded,
              size: 16.5,
            ),
            title: Text(t.open_link),
            trailing: Text(
              shortcutHintLabel(DesktopShortcutHintTarget.openLink, scheme) ?? 'Ctrl + L',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).dividerColor,
              ),
            ),
          ),
          onTap: () async {
            isDesktop ? await showOpenLinkDialog(context) : await showOpenLinkBottomSheet(context);
            showControl();
          },
        ),
        if (width < 600)
          PopupMenuItem(
            child: ListTile(
              mouseCursor: SystemMouseCursors.click,
              leading: const Icon(
                Icons.speed_rounded,
                size: 20,
              ),
              title: Text('${t.playback_speed}: ${rate}X'),
            ),
            onTap: () => showControlForHover(showRateDialog(context)),
          ),

        // circle slider panel width control;
        // accessible only when the circle slider layout is active.
        if (useCircleSlider)
          PopupMenuItem(
            child: ListTile(
              mouseCursor: SystemMouseCursors.click,
              leading: const Icon(
                Icons.space_bar,
                size: 20,
              ),
              title: Text('${t.circle_slider_landscape_percent}: $circleSliderPanelWidthPercent%'),
            ),
            onTap: () => showControlForHover(
              showCircleSliderLandscapePercentPopover(context, showControl),
            ),
          ),
        PopupMenuItem(
          child: ListTile(
            mouseCursor: SystemMouseCursors.click,
            leading: const Icon(
              Icons.history_rounded,
              size: 20,
            ),
            title: Text(t.history),
            trailing: Text(
              shortcutHintLabel(DesktopShortcutHintTarget.history, scheme) ?? 'Ctrl + H',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).dividerColor,
              ),
            ),
          ),
          onTap: () => showControlForHover(
            showPopup(
              context: context,
              child: const History(),
              direction: popupDirection,
            ),
          ),
        ),
        PopupMenuItem(
          child: ListTile(
            mouseCursor: SystemMouseCursors.click,
            leading: const Icon(
              Icons.settings_rounded,
              size: 20,
            ),
            title: Text(t.settings),
            trailing: Text(
              shortcutHintLabel(DesktopShortcutHintTarget.settings, scheme) ?? 'Ctrl + P',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).dividerColor,
              ),
            ),
          ),
          onTap: () => showControlForHover(
            showPopup(
              context: context,
              child: const Settings(),
              direction: popupDirection,
            ),
          ),
        ),
        PopupMenuItem(
          child: ListTile(
            mouseCursor: SystemMouseCursors.click,
            leading: const Icon(
              Icons.exit_to_app_rounded,
              size: 20,
            ),
            title: Text(t.exit),
            trailing: Text(
              'Alt + X',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).dividerColor,
              ),
            ),
          ),
          onTap: () => AppExit.run(context.read<MediaPlayer>().saveProgress),
        ),
        if (isMobilePlatform)
          PopupMenuItem(
            child: ListTile(
              mouseCursor: SystemMouseCursors.click,
              leading: const Icon(
                Icons.touch_app_rounded,
                size: 20,
              ),
              title: Text(t.show_gesture_overlay),
            ),
            onTap: () => usePlayerUiStore().updateIsShowGestureTips(true),
          ),
      ],
    );

    final Widget controlLayout;

    if (useCircleSlider) {
      controlLayout = SizedBox(
        width: width * (circleSliderPanelWidthPercent / 100.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            circleSliderWidget,
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  repeatButton,
                  prevButton,
                  playPauseButton,
                  nextButton,
                  stopButton,
                  shuffleButton,
                  if (file?.type != ContentType.audio) fitButton,
                  rotateOrVolumeWidget,
                  subtitleButton,
                  playQueueButton,
                  storageButton,
                  if (isDesktop) fullscreenButton,
                  moreMenuButton,
                ],
              ),
            ),
          ],
        ),
      );
    } else {
      if (width < mobileBreakpoint) {
        controlLayout = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            sliderWidget,
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                shuffleButton,
                prevButton,
                playPauseButton,
                stopButton,
                nextButton,
                repeatButton,
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (file?.type != ContentType.audio) fitButton,
                rotateOrVolumeWidget,
                subtitleButton,
                playQueueButton,
                storageButton,
                if (isDesktop) fullscreenButton,
                moreMenuButton,
              ],
            )
          ],
        );
      } else if (width < tabletBreakpoint) {
        controlLayout = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            sliderWidget,
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                playPauseButton,
                stopButton,
                prevButton,
                nextButton,
                shuffleButton,
                repeatButton,
                if (file?.type != ContentType.audio) fitButton,
                rateButton,
                rotateOrVolumeWidget,
                const Spacer(),
                subtitleButton,
                playQueueButton,
                storageButton,
                if (isDesktop) fullscreenButton,
                moreMenuButton,
              ],
            ),
          ],
        );
      } else {
        controlLayout = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            playPauseButton,
            stopButton,
            prevButton,
            nextButton,
            shuffleButton,
            repeatButton,
            if (file?.type != ContentType.audio) fitButton,
            rateButton,
            rotateOrVolumeWidget,
            Expanded(child: sliderWidget),
            subtitleButton,
            playQueueButton,
            storageButton,
            if (isDesktop) fullscreenButton,
            moreMenuButton,
          ],
        );
      }
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: 0.25),
            Colors.black.withValues(alpha: 0.65),
          ],
        ),
      ),
      child: controlLayout,
    );
  }
}
