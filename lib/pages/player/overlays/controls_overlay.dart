import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/control_target_indicator.dart';
import 'package:iris/features/background_playback/view/segment_align_edit_panel.dart';
import 'package:iris/features/control_group/model/enum/player_control_group.dart';
import 'package:iris/features/control_group/store/use_control_group_store.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/sideway_panel_layout.dart';
import 'package:iris/globals.dart'
    show controlPanelKeyNotifier, sidePanelLayoutWidthNotifier;
import 'package:iris/hooks/use_published_global_key.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/pages/player/control_bar/control_bar.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/control_bar_constants.dart';
import 'package:iris/pages/player/control_bar/legacy_control_bar.dart';
import 'package:iris/pages/player/control_bar/title_area.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/drag_area.dart';
import 'package:provider/provider.dart';

class ControlsOverlay extends HookWidget {
  const ControlsOverlay({
    super.key,
    required this.file,
    required this.title,
    this.queueLabel,
    this.tagSuffix,
    this.bgTitleSuffix,
    this.bgTitleNoMedia = false,
    required this.showControl,
    required this.showControlForHover,
    required this.hideControl,
    required this.showProgress,
    this.showTitleOnly,
  });

  final FileItem? file;
  final String title;
  final String? queueLabel;
  final String? tagSuffix;

  /// 副音 on-marker appended to the title (see [TitleArea]).
  final String? bgTitleSuffix;

  /// 副音 is on but no media is loaded — the marker renders muted (see
  /// [TitleArea]).
  final bool bgTitleNoMedia;
  final Function() showControl;
  final Future<void> Function(Future<void> callback) showControlForHover;
  final Function() hideControl;
  final Function() showProgress;
  final Function()? showTitleOnly;

  /// Test seam: counts overlay builds so a test can prove the subscriptions
  /// stayed FIELD-scoped. This widget sits over the whole video, so one
  /// whole-state `select(context, (s) => s)` re-ran the title bar AND the
  /// control bar on every AppState mutation — including the per-frame writes a
  /// speed/panel drag makes. Null in prod.
  static void Function()? debugOnOverlayBuild;

  @override
  Widget build(BuildContext context) {
    debugOnOverlayBuild?.call();
    final saveProgress = context.read<MediaPlayer>().saveProgress;

    final isShowControl = usePlayerUiStore().select(context, (state) => state.isShowControl);

    final contentColor = useMemoized(
        () => Theme.of(context).brightness == Brightness.dark
            ? Theme.of(context).colorScheme.onSurface
            : Theme.of(context).colorScheme.surface,
        [context]);

    final width = MediaQuery.sizeOf(context).width;
    final AppStore appStore = useAppStore();
    // FIELD-scoped subscriptions only. A whole-state
    // `select(context, (s) => s)` here is NOT an inert read: `Store.set` emits
    // unconditionally and Freezed's `==` is a deep compare, so every AppState
    // mutation rebuilt the title bar AND the control bar — including the
    // per-frame `transientRate` write a speed-gesture drag makes, for a field
    // this overlay renders nowhere. The overlays above the video are exactly
    // where a blanket subscription costs the most.
    final PhoneLandscapeUseMode phoneLandscapeUseMode =
        appStore.select(context, (state) => state.phoneLandscapeUseMode);
    final ScreenOrientation runtimeOrientation =
        appStore.select(context, (state) => state.runtimeOrientation);
    final controlsTitleConfig =
        appStore.select(context, (state) => state.controlsTitleConfig);
    final useLegacy =
        appStore.select(context, (state) => state.useLegacyControlBar);
    final bool metaOn = appStore.select(context, (s) => s.useMetadataSettings);
    final PhoneSidePositionH mobileSidePositionH =
        appStore.select(context, (s) => s.mobileSidePositionH);
    final PhoneSidePositionH phoneSidePositionH =
        appStore.select(context, (s) => s.phoneSidePositionH);
    final PhoneSidePositionV phoneSidePositionV =
        appStore.select(context, (s) => s.phoneSidePositionV);
    final PhoneLandscapeSliderType phoneLandscapeSliderType =
        appStore.select(context, (s) => s.phoneLandscapeSliderType);
    final bool desktopHoverShowControlBar =
        appStore.select(context, (s) => s.desktopHoverShowControlBar);
    final bool desktopHoverShowTitle =
        appStore.select(context, (s) => s.desktopHoverShowTitle);
    final bool sidewayPanelRequireClick =
        appStore.select(context, (s) => s.sidewayPanelRequireClick);
    final double sidewayPanelWidthPct =
        appStore.select(context, (s) => s.sidewayPanelWidthPct);
    final double sidewayPanelHeightPct =
        appStore.select(context, (s) => s.sidewayPanelHeightPct);
    final double sidewayPanelWidthPx =
        appStore.select(context, (s) => s.sidewayPanelWidthPx);
    final double sidewayPanelHeightPx =
        appStore.select(context, (s) => s.sidewayPanelHeightPx);
    final SidePanelCornerHideMode sidePanelCornerHideMode =
        appStore.select(context, (s) => s.sidePanelCornerHideMode);
    final SidePanelCornerHideMode mobileSidePanelCornerHideMode =
        appStore.select(context, (s) => s.mobileSidePanelCornerHideMode);

    final bool isLandscape = isLandscapeOrientation(
      runtimeOrientation: runtimeOrientation,
      realOrientation: MediaQuery.orientationOf(context),
    );
    // Single authority for the side PANEL's screen anchor (shared with the
    // panel's bottom button rows, which face the screen centre). Whether the
    // BAR belongs there too is decided further down, once the child is known.
    final Alignment sidePanelAnchor = resolveControlPanelAnchorFrom(
      mode: phoneLandscapeUseMode,
      useMetadataSettings: metaOn,
      mobileSidePositionH: mobileSidePositionH,
      phoneSidePositionH: phoneSidePositionH,
      phoneSidePositionV: phoneSidePositionV,
      sliderType: phoneLandscapeSliderType,
      isLandscape: isLandscape,
      width: width,
    );
    // The click-to-show gate, resolved once from the selected slice so the
    // hover/tap handlers and the visibility rule below cannot disagree.
    final bool requireClick = shouldRequireClickToShowPanelFrom(
      useMetadataSettings: metaOn,
      desktopHoverShowControlBar: desktopHoverShowControlBar,
      sidewayPanelRequireClick: sidewayPanelRequireClick,
      oneHandedControls: phoneLandscapeUseMode.usesOneHandedControls,
    );

    final overlayColor = useMemoized(
        () => WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
              if (states.contains(WidgetState.pressed)) {
                return contentColor.withValues(alpha: 0.2);
              } else if (states.contains(WidgetState.hovered)) {
                return contentColor.withValues(alpha: 0.2);
              }
              return null;
            }),
        [contentColor]);

    void onHover(PointerHoverEvent event) {
      if (event.kind != PointerDeviceKind.touch) {
        // The SAME resolved bit the frame below is gated with, not a second
        // read: a hover landing in the gap before the next build must not be
        // answered by a different gate than the one on screen.
        final bool rc = requireClick;
        final bool armed = usePlayerUiStore().state.isPanelClickArmed;
        final bool holding = useScrubDragStore().state.any;
        final bool isVideo = file?.type == ContentType.video;
        final bool hiddenForRc = rc && isVideo && !holding && !armed;
        if (hiddenForRc) {
          // Hidden: hover only shows title/cursor
          if (showTitleOnly != null) {
            showTitleOnly!.call();
          } else {
            usePlayerUiStore().updateIsShowControl(true);
            usePlayerUiStore().updateIsHovering(true);
            showControl();
          }
        } else {
          usePlayerUiStore().updateIsHovering(true);
          showControl();
        }
      }
    }

    // tap on title / panel: when requireClick is ON, arm the panel
    void handlePanelTap() {
      if (requireClick) {
        final ui = usePlayerUiStore().state;
        if (!ui.isPanelClickArmed) {
          usePlayerUiStore().updateIsPanelClickArmed(true);
        }
      }
      showControl();
    }

    final bool isPanelClickArmed =
        usePlayerUiStore().select(context, (s) => s.isPanelClickArmed);
    final bool isHoverReveal =
        usePlayerUiStore().select(context, (s) => s.isHoverReveal);
    final bool dragActive = useScrubDragStore().select(context, (s) => s.any);
    // The align editor replaces the bar and is ALWAYS shown while open — no
    // auto-hide, no click requirement, no tap-away dismissal.
    final bool editing = useBackgroundPlaybackStore()
        .select(context, (s) => s.segmentEditMode);
    // Passive hover only: `app.desktopHoverShow*` decide what it reveals.
    // Explicit shows (startup / click / key) ignore the switches entirely.
    final bool titleRevealed = !isHoverReveal ||
        desktopHoverRevealsTitleFrom(
          useMetadataSettings: metaOn,
          desktopHoverShowTitle: desktopHoverShowTitle,
          desktopHoverShowControlBar: desktopHoverShowControlBar,
        );
    // Shared with every affordance that rides WITH the panel (see
    // `resolveControlPanelVisible`).
    final bool isShowSidePanel = resolveControlPanelVisibleFrom(
      requireClick: requireClick,
      isShowControl: isShowControl,
      isHoverReveal: isHoverReveal,
      isPanelClickArmed: isPanelClickArmed,
      editing: editing,
      isVideo: file?.type == ContentType.video,
      dragActive: dragActive,
    );

    // 副音 quick column state — the column is magnetically attached OUTSIDE the
    // panel, so the hide translation has to clear the WHOLE row, not just the
    // panel box. Subscribed here (not read from the layout) because the hide
    // happens in the overlay, one tree level above the panel that owns the
    // gate decision; the helpers below are the same ones the layout renders
    // from, so the two cannot disagree.
    final bool bgQuickBarVisible = useBackgroundPlaybackStore()
        .select(context, (s) => s.quickBarEnabled);
    final PlayerControlGroup controlGroup =
        useControlGroupStore().select(context, (s) => s.group);
    final bool desktopPhoneMode =
        appStore.select(context, (s) => s.desktopCenterZonePhoneMode);
    final double ringDialHeightPct =
        appStore.select(context, (s) => s.ringDialHeightPct);
    final double circleSliderScale =
        appStore.select(context, (s) => s.circleSliderScale);
    final PhoneSideScrubberKind scrubberKind =
        appStore.select(context, (s) => s.phoneOneHandedScrubberKind);

    // Direction-aware hide translation: side total panel per actual panel size
    // + anchor (9-grid); linear bottom bars fall back to downward slide.
    final Size windowSize = MediaQuery.sizeOf(context);
    // The bar's REAL layout zone, SUBSCRIBED to. The docked playlist shrinks
    // the zone the bar is laid out in, so the 副音 quick column attached beside
    // the panel can drop off it and the hide must travel further. A bare
    // `.value` read froze both: the overlay builds on the frame the dock
    // toggles, but the new zone is only published while the DESCENDANT lays out
    // afterwards — and nothing re-ran this build when it did.
    final double? sidePanelLayoutWidth =
        useValueListenable(sidePanelLayoutWidthNotifier);
    // Per-mount key of the BAR box itself (published for the picture-fullscreen
    // playlist dock, which excludes it from its right-edge summon strip — see
    // `controlPanelKeyNotifier`). It wraps the translated box, so a hidden bar
    // reports an off-screen rect and cannot block the dock's strip.
    final GlobalKey controlPanelKey =
        usePublishedGlobalKey(controlPanelKeyNotifier);
    // The CHILD decides this, not the mode alone: under the legacy control bar
    // a one-handed mode still renders a full-width linear layout, so placing it
    // by the side anchor slid it out sideways and handed `isSide: true` to the
    // 副音 align editor. [isSidePanelLayoutMounted] carries the legacy veto.
    final bool isSideLayout = isSidePanelLayoutMounted(
      mode: phoneLandscapeUseMode,
      legacyControlBar: useLegacy,
      isPhone: isMobilePlatform,
      isLandscape: isLandscape,
    );
    // Where the bar BOX is actually placed, which is not the same question as
    // [isSideLayout] (that one answers "is it a side panel"). A linear bar is
    // full width, so the anchor's horizontal half moves nothing; its VERTICAL
    // half does, and pairing it with the linear downward hide parks the bar
    // against the top edge and then sends it across the whole video on every
    // hide. posV only reaches the resolver on desktop, so the mismatch was
    // desktop-only and easy to miss.
    //
    // The one legacy child that really IS a side box is its own narrow circle
    // column (gate OFF + a stored circle placement), and there the resolver's
    // legacy corner IS the placement — so the veto has to exclude it, or it
    // would silently relocate a frozen layout.
    final bool legacyCircleColumn = useLegacy &&
        useLegacyCircleSliderPanel(
          metadataEnabled: metaOn,
          isPhone: isMobilePlatform,
          isLandscape: isLandscape,
          sliderType: phoneLandscapeSliderType,
        );
    final Alignment controlBarOverlayAlignment =
        (isSideLayout || legacyCircleColumn)
            ? sidePanelAnchor
            : Alignment.bottomCenter;
    late final Offset hideTranslate;
    if (isSideLayout) {
      final bool isPhone = isMobilePlatform;
      final ({double panelW, double panelH}) panel = panelSizeForWindow(
        windowW: windowSize.width,
        windowH: windowSize.height,
        isPhone: isPhone,
        widthPct: sidewayPanelWidthPct,
        heightPct: sidewayPanelHeightPct,
        widthPx: sidewayPanelWidthPx,
        heightPx: sidewayPanelHeightPx,
      );
      // The panel box the layout really fills: the dial-width floor can widen
      // it past the drag width (a classic circle on a phone panel), and a hide
      // computed from the drag width would strand that strip on screen.
      final double dialDiameter = dialDiameterForHide(
        span: spanForTotalHeight(panel.panelH, sidewayBarHeight.value, 8),
        panelW: panel.panelW,
        scrubberKind: scrubberKind,
        ringDialHeightPct: ringDialHeightPct,
        classicScale: circleSliderScale,
      );
      final double boxW = renderedPanelWidthFor(
        windowW: windowSize.width,
        isPhone: isPhone,
        widthPct: sidewayPanelWidthPct,
        widthPx: sidewayPanelWidthPx,
        dialDiameter: dialDiameter,
      );
      // …and the 副音 column attached to its centre-facing side. The layout
      // budgets it off the REAL bar layout zone (the playlist dock can shrink
      // the video area), so the notifier is the same source the layout used.
      final double layoutWidth = sidePanelLayoutWidth ?? windowSize.width;
      final double quickAvail = sidewayQuickAvailWidth(
        layoutWidth: layoutWidth,
        panelW: boxW,
      );
      final bool attached = showsSidewayQuickColumn(
        isPhone: isPhone,
        gateEnabled: BackgroundPlaybackGate.enabled,
        quickBarEnabled: bgQuickBarVisible,
        showingBackgroundGroup: (isPhone || desktopPhoneMode) &&
            controlGroup == PlayerControlGroup.background,
        quickAvail: quickAvail,
      );
      // Only a HORIZONTAL hide can strand the column: it sits beside the
      // panel, so a vertical drop carries it off the same way.
      final double footprintW = attached && quickAvail > 0
          ? boxW + kSidewayQuickGap +
              sidewayQuickColumnWidth(quickAvail: quickAvail, panelH: panel.panelH)
          : boxW;
      hideTranslate = hideTranslateForAnchor(
        anchor: controlBarOverlayAlignment,
        isLeftHanded: resolvePanelSideIsLeft(
          anchor: controlBarOverlayAlignment,
          mode: phoneLandscapeUseMode,
        ),
        panelW: footprintW,
        panelH: panel.panelH,
        cornerMode: resolveSidePanelCornerHideModeFrom(
          isPhone: isPhone,
          desktop: sidePanelCornerHideMode,
          phone: mobileSidePanelCornerHideMode,
        ),
      );
    } else {
      // Linear bars (desktop single/stacked, tablet, phone portrait) slide down.
      hideTranslate = Offset(0, windowSize.height + 24);
    }

    return Stack(
      children: [
        // 标题栏 - hover always shows title/cursor via normal showControl
        AnimatedPositioned(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOutCubicEmphasized,
          top: (isShowControl && titleRevealed) ||
                  file?.type != ContentType.video
              ? 0
              : kTitleBarHiddenOffset,
          left: 0,
          right: 0,
          child: MouseRegion(
            onHover: onHover,
            child: GestureDetector(
              onTap: handlePanelTap,
              child: DragArea(
                child: TitleArea(
                  title: title,
                  queueLabel: queueLabel,
                  tagSuffix: tagSuffix,
                  bgTitleSuffix: bgTitleSuffix,
                  bgTitleNoMedia: bgTitleNoMedia,
                  color: contentColor,
                  overlayColor: overlayColor,
                  saveProgress: () => saveProgress(),
                  config: controlsTitleConfig,
                ),
              ),
            ),
          ),
        ),
        // 控制栏 - direction-aware hide (手机/桌面按实际面板高，电脑按锚点方位；边中单轴、四角对角、正中按 side)
        Positioned.fill(
          child: Align(
            alignment: controlBarOverlayAlignment,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOutCubicEmphasized,
              transform: Matrix4.translationValues(
                isShowSidePanel ? 0 : hideTranslate.dx,
                isShowSidePanel ? 0 : hideTranslate.dy,
                0,
              ),
              // The 副音 target frame sits INSIDE the transform, wrapping the
              // bar itself. Outside it (or around the full-screen fill) the
              // border is painted at the untranslated box and stays on screen
              // while the bar slides away — which read as "only a blue frame,
              // no control bar".
              child: BackgroundControlTargetIndicator(
                borderRadius: BorderRadius.all(Radius.circular(
                  isSideLayout ? 12 : 0,
                )),
                child: ConstrainedBox(
                  key: controlPanelKey,
                  constraints: BoxConstraints(
                    maxHeight: windowSize.height,
                    maxWidth: windowSize.width,
                  ),
                  child: IgnorePointer(
                    ignoring: !isShowSidePanel,
                    child: ExcludeSemantics(
                      excluding: !isShowSidePanel,
                      child: TickerMode(
                        enabled: isShowSidePanel,
                        child: MouseRegion(
                          onHover: onHover,
                          child: GestureDetector(
                            onTap: handlePanelTap,
                            child: editing
                                ? SegmentAlignEditPanel(
                                    isSide: isSideLayout,
                                    color: contentColor,
                                    overlayColor: overlayColor,
                                    showControl: showControl,
                                  )
                                : useLegacy
                                    ? LegacyControlBar(
                                        showControl: showControl,
                                        showControlForHover: showControlForHover,
                                        color: contentColor,
                                        overlayColor: overlayColor,
                                      )
                                    : ControlBar(
                                        showControl: showControl,
                                        showControlForHover: showControlForHover,
                                        color: contentColor,
                                        overlayColor: overlayColor,
                                      ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
