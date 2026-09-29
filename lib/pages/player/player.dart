import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/hooks/use_app_lifecycle.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/ab_loop_engine.dart';
import 'package:iris/features/windows/desktop_keyboard/store/key_sequence_buffer_store.dart';
import 'package:iris/features/scenario_playback/actions/drag_drop_gate.dart';
import 'package:iris/features/scenario_playback/actions/drag_drop_play_handler.dart';
import 'package:iris/features/scenario_playback/playback/playback_position_signal.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/pages/player/title_prefix.dart';
import 'package:iris/hooks/use_cover.dart';
import 'package:iris/hooks/use_global_keyboard.dart';
import 'package:iris/hooks/use_keyboard.dart';
import 'package:iris/info.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/rule/vm_title_composer.dart';
import 'package:iris/features/virtual_media/view/vm_error_dialog_host.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/player_ui_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/models/store/scrub_drag_state.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/pages/player/audio.dart';
import 'package:iris/pages/player/overlays/controls_overlay.dart';
import 'package:iris/pages/player/overlays/drop_zone_overlay.dart';
import 'package:iris/pages/player/overlays/gesture_overlay.dart';
import 'package:iris/pages/player/overlays/gesture_tips_overlay.dart';
import 'package:iris/pages/player/overlays/minimal_progress_overlay.dart';
import 'package:iris/pages/player/video_view.dart';
import 'package:iris/pages/player/video_layout.dart';
import 'package:iris/features/background_playback/view/background_video_surface.dart';
import 'package:iris/features/background_playback/view/player_control_target_scope.dart';
import 'package:iris/features/background_playback/view/bg_quick_panel_host.dart';
import 'package:iris/features/background_playback/services/segment_edit_guard.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/control_group/view/control_group_floating_button.dart';
import 'package:iris/features/playback_tools/view/frame_tools_float_panel.dart';
import 'package:iris/features/osd/view/osd_overlay.dart';
import 'package:iris/features/windows/desktop_keyboard/view/ab_loop_overlay.dart';
import 'package:iris/features/windows/desktop_keyboard/view/key_sequence_overlay.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/models/store/video_display_mode.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/pages/player/player_back_disposition.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/app_exit.dart';
import 'package:iris/utils/check_content_type.dart';
import 'package:iris/utils/drag_window_lock.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

final areaKeyLog = AreaKeyLog(LogKeys.legacyPlayer);

/// Vertical fraction (0 = top, 1 = bottom) of [localPosition] inside a drop
/// target of [boxHeight], or null when the height is unknown/zero. Drives the
/// PotPlayer-style append/override split indicator.
double? _dropHoverFraction(Offset localPosition, double boxHeight) {
  if (boxHeight <= 0 || !boxHeight.isFinite) return null;
  final fraction = localPosition.dy / boxHeight;
  if (fraction.isNaN) return null;
  return fraction.clamp(0.0, 1.0).toDouble();
}

/// Resolves the BoxFit the video pipeline renders with for this frame.
///
/// Gate OFF: the legacy `fit` cycle, byte-for-byte (none degrades to contain
/// in picture-fullscreen). Gate ON: the platform display mode decides —
/// original-size semantics resolve via [resolveDesktopDisplayBoxFit] /
/// [resolveMobileDisplayBoxFit] against the video's logical (DPI-scaled)
/// size, and 1:1 likewise degrades to contain in picture-fullscreen (the
/// window is the whole video surface there; 1:1 would truncate the frame).
BoxFit resolvePlayerBoxFit({
  required bool gateOn,
  required bool desktop,
  required DesktopVideoDisplayMode desktopMode,
  required MobileVideoDisplayMode mobileMode,
  required BoxFit legacyFit,
  required bool fullscreen,
  required Size videoPx,
  required double scaleFactor,
  required Size windowSize,
}) {
  if (!gateOn) {
    return (fullscreen && legacyFit == BoxFit.none)
        ? BoxFit.contain
        : legacyFit;
  }
  final Size videoLogical = scaleFactor > 0
      ? Size(videoPx.width / scaleFactor, videoPx.height / scaleFactor)
      : Size.zero;
  final BoxFit resolved = desktop
      ? resolveDesktopDisplayBoxFit(
          mode: desktopMode,
          videoLogicalSize: videoLogical,
          windowSize: windowSize,
        )
      : resolveMobileDisplayBoxFit(
          mode: mobileMode,
          videoLogicalSize: videoLogical,
          windowSize: windowSize,
        );
  if (fullscreen && resolved == BoxFit.none) return BoxFit.contain;
  return resolved;
}

class Player extends HookWidget {
  const Player({super.key});

  @override
  Widget build(BuildContext context) {
    final width = context.select<MediaPlayer, double>((player) => player.width);
    final height =
        context.select<MediaPlayer, double>((player) => player.height);

    useAppLifecycle();

    // Latch-proof scrub state: the player page owns every scrub surface, so
    // leaving it must drop any session whose end event was lost.
    useEffect(() {
      return () => useScrubDragStore().resetAll();
    }, const <Object?>[]);

    final cover = useCover();

    final controlHideTimer = useRef<Timer?>(null);
    final progressHideTimer = useRef<Timer?>(null);
    final lastValidVideoSize = useRef<Size?>(null);

    final fit = useAppStore().select(context, (state) => state.fit);

    final playQueue =
        usePlayQueueStore().select(context, (state) => state.playQueue);
    final currentIndex =
        usePlayQueueStore().select(context, (state) => state.currentIndex);
    final store = usePlayQueueStore();

    final int currentPlayIndex = useMemoized(
        () => playQueue.indexWhere((element) => element.index == currentIndex),
        [playQueue, currentIndex]);

    final FileItem? file = useMemoized(
        () => playQueue.isEmpty || currentPlayIndex < 0
            ? null
            : playQueue[currentPlayIndex].file,
        [playQueue, currentPlayIndex]);

    // Plain media name — the `[cur/total]` prefix and the tag suffix are
    // rendered ONLY by the bar title area (they hide with the bottom bar).
    // When a Virtual Media session is active, replace the single-file name
    // part with “目录:序号/总数:原名” (spec §9.2).
    final vmCtrl = VirtualMediaController.instance;
    final vmItem = vmCtrl.isActive ? vmCtrl.state.item : null;
    final vmSegIdx = vmCtrl.isActive ? vmCtrl.state.segmentIndex : 0;
    final title = useMemoized(
      () {
        if (file == null) return INFO.title;
        if (vmItem != null) {
          final seg =
              vmItem.segments[vmSegIdx.clamp(0, vmItem.segments.length - 1)];
          final dirName = seg.parentPath.isEmpty
              ? (vmItem.rootPath.isEmpty
                  ? getLocalizations(context).vm_title_cross_dir
                  : vmItem.rootPath.split('/').last)
              : seg.parentPath.split('/').last;
          // Separator comes from rule; default ':' matches table default.
          return vmPlayerTitle(
            dirName: dirName,
            innerIndex: vmSegIdx + 1,
            innerTotal: vmItem.segments.length,
            origName: file.name,
          );
        }
        return file.name;
      },
      [file, vmItem, vmSegIdx],
    );

    // Reactive position of the current item in the active view / scenario
    // stream — drives the bar's `[cur/total]` prefix.
    final tagStatus = useValueListenable(
      PlaybackProviderRegistry.tagPlay.tagViewStatus,
    );
    // Read from the shared signal, NOT from one provider instance: list taps
    // publish through a short-lived provider, next/previous through the
    // registry singleton, and the title must follow both.
    final scenarioPos =
        useValueListenable(PlaybackProviderRegistry.scenario.position);
    // Per-CONTEXT ownership, NOT the global `scenarioModeActive` flag: in the
    // default drift configuration that flag is true for every playback, so it
    // cannot tell a scenario stream from a history / file-browser feed whose
    // queue index is meaningful and must win. Reading it as a listenable also
    // rebuilds the title on the hand-off itself, not only on the feed that
    // follows it.
    final scenarioOwnsPlayback = useValueListenable(
      PlaybackPositionSignal.instance.scenarioOwnsContext,
    );

    // The queue's REAL size, as a SUBSCRIPTION. In query mode the published
    // `playQueue` is a synthetic single item, so the total lives only on the
    // store's notifier: a bare `store.totalCount` read left the title prefix
    // frozen when a search/filter moved the total 1↔N, while the control bar —
    // which subscribes — already showed the new number.
    final int queryTotalCount = useValueListenable(store.totalCountNotifier);

    final String? queueLabel = useMemoized(
      () => resolveQueuePrefix(
        tagView: tagStatus,
        scenarioPos: scenarioPos,
        scenarioOwnsPlayback: scenarioOwnsPlayback,
        isQueryMode: store.isQueryMode,
        queryVirtualPos: store.currentVirtualPos,
        queryTotalCount: queryTotalCount,
        queueLength: playQueue.length,
        currentQueueIndex: currentPlayIndex,
      ),
      [
        tagStatus,
        scenarioPos,
        scenarioOwnsPlayback,
        store.isQueryMode,
        store.currentVirtualPos,
        queryTotalCount,
        playQueue.length,
        currentPlayIndex,
      ],
    );

    // Trailing tag indicator for the bar title: "Tag <name>" while a tag view
    // drives playback; a subdued no-tag marker otherwise (meta-driven era
    // only). The marker travels as the [kNoTagSuffix] sentinel and is
    // rendered localized at each display site.
    final tagFeatureActive = useAppStore().select(context,
        (s) => !s.useLegacyStoragePersistence && s.useMetadataSettings);
    final String? tagSuffix = useMemoized(() {
      final status = tagStatus;
      if (status != null) return status.tagName;
      return tagFeatureActive ? kNoTagSuffix : null;
    }, [tagStatus, tagFeatureActive]);

    // 副音 is running: APPEND the background media's name to the bar title in
    // the accent color so the on-state is visible at a glance. The foreground
    // title, queue prefix and tag suffix stay exactly as they are — this is an
    // additive marker, never a replacement.
    final bgTitleState = useBackgroundPlaybackStore().select(
      context,
      (s) => (
        enabled: s.enabled,
        name: s.currentIndex >= 0 && s.currentIndex < s.queue.length
            ? s.queue[s.currentIndex].name
            : null,
      ),
    );
    final String? bgTitleSuffix = useMemoized(
      () => bgTitleState.enabled
          ? getLocalizations(context).bg_title_bar_sub(bgTitleState.name ?? '—')
          : null,
      [bgTitleState.enabled, bgTitleState.name],
    );
    // 副音 is on but no media is loaded: the marker renders muted (gray)
    // instead of the accent color so the placeholder "—" never reads as a
    // live sub-audio.
    final bool bgTitleNoMedia =
        bgTitleState.enabled && bgTitleState.name == null;

    void startControlHideTimer() {
      controlHideTimer.value = Timer(
        const Duration(seconds: 5),
        () {
          final PlayerUiState ui = usePlayerUiStore().state;
          if (!ui.isShowControl) return;
          // The fb/bg align editor replaces the bar and must stay visible:
          // never auto-hide while it owns the pair.
          if (SegmentEditGuard.transportFrozen) {
            startControlHideTimer();
            return;
          }
          // In use (scrub session / hover): never hide mid-use — re-check
          // after another interval; hides within 5s once use ends.
          if (!mayHideControl(
            ui: ui,
            drag: useScrubDragStore().state,
          )) {
            startControlHideTimer();
            return;
          }
          usePlayerUiStore().updateIsShowControl(false);
          usePlayerUiStore().updateIsPanelClickArmed(false);
          usePlayerUiStore().updateIsHoverReveal(false);
        },
      );
    }

    void startProgressHideTimer() {
      progressHideTimer.value = Timer(
        const Duration(seconds: 5),
        () {
          if (usePlayerUiStore().state.isShowProgress) {
            usePlayerUiStore().updateIsShowProgress(false);
          }
        },
      );
    }

    void resetControlHideTimer() {
      controlHideTimer.value?.cancel();
      startControlHideTimer();
    }

    void resetBottomProgressTimer() {
      progressHideTimer.value?.cancel();
      startProgressHideTimer();
    }

    void showControl() {
      usePlayerUiStore().updateIsShowControl(true);
      usePlayerUiStore().updateIsHovering(false);
      // Explicit show (startup / click / key / context menu): the hover-only
      // switches never gate it.
      usePlayerUiStore().updateIsHoverReveal(false);
      // An explicit "show" (click / key / context menu) reveals the FULL bar:
      // when the require-click gate is active, arm the panel here so only the
      // passive hover path (showTitleOnly) leaves it hidden.
      if (shouldRequireClickToShowPanel(useAppStore().state)) {
        usePlayerUiStore().updateIsPanelClickArmed(true);
      }
      resetControlHideTimer();
    }

    void showTitleOnly() {
      usePlayerUiStore().updateIsShowControl(true);
      // Passive hover: the desktop `app.desktopHoverShow*` switches decide
      // whether the title/panel actually render (see ControlsOverlay).
      usePlayerUiStore().updateIsHoverReveal(true);
      // isHovering stays false so the idle timer auto-hides the title after the
      // usual interval; the panel is omitted because the click latch is unset.
      usePlayerUiStore().updateIsHovering(false);
      resetControlHideTimer();
    }

    void hideControl() {
      usePlayerUiStore().updateIsShowControl(false);
      usePlayerUiStore().updateIsHovering(false);
      usePlayerUiStore().updateIsPanelClickArmed(false);
      usePlayerUiStore().updateIsHoverReveal(false);
      controlHideTimer.value?.cancel();
    }

    Future<void> showControlForHover(Future<void> callback) async {
      try {
        context.read<MediaPlayer>().saveProgress();
        showControl();
        usePlayerUiStore().updateIsHovering(true);
        await callback;
        showControl();
      } catch (e) {
        areaKeyLog.e(e.toString());
      }
    }

    void showProgress() {
      usePlayerUiStore().updateIsShowProgress(true);
      resetBottomProgressTimer();
    }

    // Global key intake: HardwareKeyboard-level dispatch instead of a
    // widget-scoped KeyboardListener, whose focus node went deaf the moment
    // primary focus moved into the docked playlist panel (a sibling subtree).
    // Relevance guards live in use_keyboard (route currentness + typing).
    final onKeyEvent = useKeyboard(
      showControl: showControl,
      showControlForHover: showControlForHover,
      showProgress: showProgress,
    );
    useGlobalKeyboard(onKeyEvent);

    useEffect(() {
      startControlHideTimer();
      return () => controlHideTimer.value?.cancel();
    }, []);

    useEffect(() {
      return () => progressHideTimer.value?.cancel();
    }, []);

    useEffect(() {
      if (isDesktop) {
        windowManager.setTitle(title);
      }
      return;
    }, [title]);

    final isFullScreen =
        usePlayerUiStore().select(context, (s) => s.isFullScreen);
    // Metadata-era display modes: gate ON replaces the legacy `fit` cycle as
    // the render source of truth (per-platform enum); gate OFF keeps the
    // legacy BoxFit path byte-for-byte.
    final metadataGate =
        useAppStore().select(context, (s) => s.useMetadataSettings) &&
            MetaSettingsModule.ready;
    final desktopMode =
        useAppStore().select(context, (s) => s.desktopDisplayMode);
    final mobileMode =
        useAppStore().select(context, (s) => s.mobileDisplayMode);
    // Scrub-drag surface freeze: the window is locked mid-drag (see
    // useResizeWindow), so the video must adapt inside it instead of
    // following per-segment sizes. Subscribe to the DERIVED booleans, not the
    // whole state: `ScrubDragState` holds only owner-id sets (it changes on
    // gesture begin/end, never per frame), and a blanket `select((s) => s)`
    // here re-ran the whole player Stack — LayoutBuilder, DropTarget, every
    // overlay — on every session transition, for a two-bool answer.
    final isDragging = useScrubDragStore().select(
      context,
      (s) => shouldSkipResizeDuringDrag(
        isScrubbing: s.isScrubbing,
        isHolding: s.isHolding,
      ),
    );

    // Drag-and-drop zone state (desktop, metadata era only). The top strip of
    // the player appends dropped items; the rest overrides and plays. The
    // fraction is only for the hover indicator — the actual zone is recomputed
    // from the drop position.
    final dropZonePercent =
        useAppStore().select(context, (s) => s.dropAppendZonePercent);
    final dropHoverFraction = useState<double?>(null);
    final dropBoxHeight = useRef<double>(0);

    final bool dropGateOn = isDesktop && DragDropGate.enabled;

    return DropTarget(
      onDragEntered: dropGateOn
          ? (details) => dropHoverFraction.value =
              _dropHoverFraction(details.localPosition, dropBoxHeight.value)
          : null,
      onDragUpdated: dropGateOn
          ? (details) => dropHoverFraction.value =
              _dropHoverFraction(details.localPosition, dropBoxHeight.value)
          : null,
      onDragExited:
          dropGateOn ? (_) => dropHoverFraction.value = null : null,
      onDragDone: (details) async {
        AbLoopEngine.instance.reset();
        useKeySequenceBufferStore().close();
        // Metadata-era drop path: the vertical zone decides append (top strip)
        // vs override+play (rest of the player). Gate OFF keeps the legacy
        // same-folder queue below byte-for-byte.
        if (dropGateOn) {
          final zone = resolveDropZone(
            localY: details.localPosition.dy,
            boxHeight: dropBoxHeight.value,
            appendPercent: dropZonePercent,
          );
          dropHoverFraction.value = null;
          await DragDropPlayHandler.handle(
            context,
            [for (final file in details.files) file.path],
            zone: zone,
          );
          return;
        }
        final files = details.files
            .map((file) => checkContentType(file.path) == ContentType.video ||
                    checkContentType(file.path) == ContentType.audio
                ? file.path
                : null)
            .where((element) => element != null)
            .toList() as List<String>;
        if (files.isNotEmpty) {
          final firstFile = files[0];
          if (firstFile.isEmpty) return;
          final playQueue = await getLocalPlayQueue(firstFile);
          if (playQueue == null || playQueue.playQueue.isEmpty) return;
          final List<PlayQueueItem> filteredPlayQueue = [];
          for (final item in playQueue.playQueue) {
            final file = item.file;
            if (files.contains(file.uri)) {
              filteredPlayQueue.add(item);
            }
          }
          if (filteredPlayQueue.isEmpty) return;
          useAppStore().updateAutoPlay(true);
          PlaybackProviderRegistry.beginExternalFeed();
          usePlayQueueStore().update(
              playQueue: filteredPlayQueue, index: playQueue.currentIndex);
        }
      },
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, Object? result) async {
          if (!didPop) {
            // Back arrow owns the gesture guide first (requirement #4): the
            // guide is a Stack overlay, not a route, so a bare back press
            // used to fall straight through to app exit below.
            switch (resolvePlayerBackDisposition(
                isShowGestureTips:
                    usePlayerUiStore().state.isShowGestureTips)) {
              case PlayerBackDisposition.closeGestureGuide:
                usePlayerUiStore().updateIsShowGestureTips(false);
                return;
              case PlayerBackDisposition.leavePlayer:
                break;
            }
            await AppExit.run(context.read<MediaPlayer>().saveProgress);
          }
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            // When docked, constraints reflect the video zone only (Row Expanded).
            // Fallback to MediaQuery when constraints are unbounded (tests).
            final Size windowSize =
                constraints.hasBoundedWidth && constraints.hasBoundedHeight
                    ? Size(constraints.maxWidth, constraints.maxHeight)
                    : MediaQuery.sizeOf(context);
            // Drop-zone split is relative to the player area; keep it in sync
            // with the drop callbacks' local coordinates.
            dropBoxHeight.value = windowSize.height;
            final double physicalWidth = View.of(context).physicalSize.width;
            final double scaleFactor = windowSize.width > 0 &&
                    windowSize.width.isFinite &&
                    physicalWidth.isFinite &&
                    physicalWidth > 0
                ? physicalWidth / windowSize.width
                : 1.0;
            final BoxFit effectiveFit = resolveDraggingBoxFit(
              resolvePlayerBoxFit(
                gateOn: metadataGate,
                desktop: isDesktop,
                desktopMode: desktopMode,
                mobileMode: mobileMode,
                legacyFit: fit,
                fullscreen: isFullScreen,
                videoPx: Size(width, height),
                scaleFactor: scaleFactor,
                windowSize: windowSize,
              ),
              isDragging: isDragging,
            );
            final Size candidateVideoSize =
                (effectiveFit != BoxFit.none || width <= 0 || height <= 0)
                    ? windowSize
                    : Size(width / scaleFactor, height / scaleFactor);
            final Size? stableVideoSize = retainValidVideoSize(
              // Drag freeze: hold the pre-drag surface so per-segment size
              // changes adapt inside the locked window instead of resizing it.
              isDragging && lastValidVideoSize.value != null
                  ? lastValidVideoSize.value!
                  : candidateVideoSize,
              lastValidVideoSize.value,
            );
            if (stableVideoSize != null && !isDragging) {
              lastValidVideoSize.value = stableVideoSize;
            }
            final Size videoViewSize = stableVideoSize ?? const Size(1, 1);
            final Offset videoViewOffset = stableVideoSize == null
                ? Offset(-videoViewSize.width, -videoViewSize.height)
                : effectiveFit == BoxFit.none
                    ? Offset(
                        (windowSize.width - videoViewSize.width) / 2,
                        (windowSize.height - videoViewSize.height) / 2,
                      )
                    : Offset.zero;
            return Stack(
              children: [
                // Video
                Positioned(
                  left: videoViewOffset.dx,
                  top: videoViewOffset.dy,
                  width: videoViewSize.width,
                  height: videoViewSize.height,
                  child: VideoView(
                    mediaKey: file?.uri,
                    fit: effectiveFit,
                  ),
                ),
                Positioned.fill(
                  child: MinimalProgressOverlay(
                    title: title,
                    bgTitleSuffix: bgTitleSuffix,
                    bgTitleNoMedia: bgTitleNoMedia,
                    file: file,
                  ),
                ),
                // Audio
                if (file?.type == ContentType.audio)
                  Positioned.fill(
                    child: Audio(cover: cover),
                  ),
                // 副音 video surface (renders only while showBgVideo).
                const BackgroundPlaybackVideoSurface(),
                BackgroundTargetMediaScope(
                  child: Positioned.fill(
                    child: GestureOverlay(
                      showControl: showControl,
                      hideControl: hideControl,
                      showProgress: showProgress,
                      showControlForHover: showControlForHover,
                      showTitleOnly: showTitleOnly,
                    ),
                  ),
                ),
                BackgroundTargetMediaScope(
                  child: Positioned.fill(
                    child: ControlsOverlay(
                      file: file,
                      title: title,
                      queueLabel: queueLabel,
                      tagSuffix: tagSuffix,
                      bgTitleSuffix: bgTitleSuffix,
                      bgTitleNoMedia: bgTitleNoMedia,
                      showControl: showControl,
                      showControlForHover: showControlForHover,
                      hideControl: hideControl,
                      showProgress: showProgress,
                      showTitleOnly: showTitleOnly,
                    ),
                  ),
                ),
                // `;` sequence-buffer waiting chip (renders only while armed).
                const Positioned.fill(
                  child: KeySequenceOverlay(),
                ),
                // A-B loop indicator chip (renders only while looping).
                const Positioned.fill(
                  child: AbLoopOverlay(),
                ),
                // Draggable frame-tools float panel (phone, more-menu toggle).
                const FrameToolsFloatPanel(),
                // Quick 副音 floating cards (scope / ratio / mapping) — non-modal,
                // draggable, no dimming.
                const BgQuickPanelHost(),
                // Draggable one-handed bottom-group switch button (More menu
                // toggle; phone / desktop phone-mode only). It rides the
                // control bar's visibility and keeps its auto-hide timer alive
                // while in use, so it must be handed the same showControl.
                ControlGroupFloatingButton(showControl: showControl),
                // Gesture guide — topmost, full-screen: one swipeable page per
                // intent (bottom chip row = always-readable clickable legend).
                Positioned.fill(
                  child: GestureTipsOverlay(),
                ),
                // PotPlayer-style keyboard OSD (desktop-only, meta-gated).
                const Positioned.fill(
                  child: OsdOverlay(),
                ),
                // Virtual Media fatal-error dialog host (renders nothing until
                // the VM controller stores a localized lastError).
                const VmErrorDialogHost(),
                // Desktop drag-drop split indicator: top strip appends, the
                // rest overrides and plays.
                if (dropHoverFraction.value != null)
                  Positioned.fill(
                    child: DropZoneOverlay(
                      appendPercent:
                          clampDropAppendPercent(dropZonePercent),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
