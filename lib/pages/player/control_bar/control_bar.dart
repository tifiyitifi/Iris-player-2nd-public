import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_scrubber_slot.dart';
import 'package:iris/features/phone/one_handed_scrubber/view/phone_one_handed_scrubber.dart';
import 'package:iris/features/windows/desktop_control_bar/controller/resolve_desktop_control_bar_layout.dart';
import 'package:iris/features/windows/desktop_control_bar/view/desktop_stacked_control_layout.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/circle_slider_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_controls.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_layout_kind.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/desktop_control_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/mobile_control_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/resolve_control_bar_overflow.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/tablet_control_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/control_bar_constants.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:provider/provider.dart';

class ControlBar extends HookWidget {
  const ControlBar({
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

    final isPlaying = context.select<MediaPlayer, bool>((player) => player.isPlaying);

    final isSeeking = useScrubDragStore().select(context, (state) => state.isScrubbing);

    final displayIsPlaying = useState(isPlaying);

    final PhoneLandscapeSliderType phoneLandscapeSliderType =
        useAppStore().select(context, (state) => state.phoneLandscapeSliderType);
    final PhoneLandscapeUseMode phoneLandscapeUseMode =
        useAppStore().select(context, (state) => state.phoneLandscapeUseMode);
    // The hand the scrubber mirrors by. Resolved from the panel's own anchor
    // (so a centre anchor keeps the stored hand) rather than read straight off
    // the mode, which let the dial and the button rows disagree.
    final bool panelIsLeft =
        useAppStore().select(context, panelIsLeftHanded);
    final circleSliderPanelWidthPercent =
        useAppStore().select(context, (state) => state.circleLandscapePercent);

    final runtimeOrientation = useAppStore().select(context, (state) => state.runtimeOrientation);
    final realOrientation = MediaQuery.of(context).orientation;

    final bool isLandscape = isLandscapeOrientation(
      runtimeOrientation: runtimeOrientation,
      realOrientation: realOrientation,
    );

    final bool metaSettingsOn =
        useAppStore().select(context, (state) => state.useMetadataSettings);

    // The plain circle panel is LEGACY placement, so the meta gate retires it
    // the same way the anchor resolver does: with the gate on, the one-handed
    // use mode is the only reason a panel exists. Mounting one off a leftover
    // enum put a panel on screen that the overlay placed bottom-centre, hid
    // like a linear bar and left the settings dialog covering it.
    final bool useCircleSlider = useLegacyCircleSliderPanel(
      metadataEnabled: metaSettingsOn,
      isPhone: isMobilePlatform,
      isLandscape: isLandscape,
      sliderType: phoneLandscapeSliderType,
    );
    final bool useOneHandedScrubber = isSidewayPanelMounted(
      oneHanded: phoneLandscapeUseMode.usesOneHandedControls,
      isPhone: isMobilePlatform,
      isLandscape: isLandscape,
    );
    final PhoneOneHandedScrubberKind scrubberKind =
        useAppStore().select(context, (state) => state.phoneOneHandedScrubberKind);
    // Ring dial ships metadata-driven only; under the frozen legacy path a
    // stale 'dial' selection degrades to the classic circle slider.
    final PhoneScrubberSlot scrubberSlot = resolveScrubberSlot(
      kind: scrubberKind,
      metadataEnabled: metaSettingsOn,
    );
    // Stacked desktop bar ships metadata-driven only; gate OFF keeps the
    // classic one-line arrangement (see features/windows/desktop_control_bar).
    final DesktopControlBarLayout desktopBarLayout =
        resolveDesktopControlBarLayout(
      stored: useAppStore()
          .select(context, (state) => state.desktopControlBarLayout),
      metadataEnabled: metaSettingsOn && MetaSettingsModule.ready,
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

    final scale = useAppStore().select(context, (s) => s.circleSliderScale);
    final quickBarAlign = useBackgroundPlaybackStore()
        .select(context, (s) => s.quickBarAlign);

    final controls = ControlBarControls(
      showControl: showControl,
      showControlForHover: showControlForHover,
      color: color,
      overlayColor: overlayColor,
      file: file,
      circleScale: scale, // 👈 inject here
      quickBarAlign: quickBarAlign,
    );

    final bool showFit = file?.type != ContentType.audio;
    final bool showWindowFit = isDesktop && file?.type != ContentType.audio;
    // Matches `AdaptiveVolumeControl`: the audio slot is a 160px strip only
    // above the volume breakpoint (window width, not the bar box).
    final double volumeWidth =
        MediaQuery.sizeOf(context).width >= kVolumeControlBreakpoints
            ? kVolumeSliderWidth
            : kControlBarIconButtonWidth;

    Widget linearLayoutFor(double availableWidth) {
      final ControlBarLayoutKind kind = resolveControlBarLayoutKind(
        width: availableWidth,
        desktopLayout: desktopBarLayout,
      );
      final Set<ControlBarSlot> collapsed =
          kind == ControlBarLayoutKind.mobile
              ? const <ControlBarSlot>{}
              : resolveControlBarOverflow(
                  availableWidth: availableWidth,
                  present: presentControlBarSlots(
                    kind,
                    showFit: showFit,
                    showWindowFit: showWindowFit,
                    hasFullscreen: isDesktop,
                  ),
                  volumeWidth: volumeWidth,
                  // Only the single-line bar keeps the seek axis on the same
                  // row as the buttons; everywhere else it has its own row.
                  sliderReserveWidth:
                      kind == ControlBarLayoutKind.desktopSingle
                          ? kControlBarSliderMinWidth
                          : 0,
                );
      final ControlBarControls linearControls = ControlBarControls(
        showControl: showControl,
        showControlForHover: showControlForHover,
        color: color,
        overlayColor: overlayColor,
        file: file,
        circleScale: scale,
        quickBarAlign: quickBarAlign,
        collapsed: collapsed,
      );
      switch (kind) {
        case ControlBarLayoutKind.mobile:
          return MobileControlLayout(controls: linearControls);
        case ControlBarLayoutKind.tablet:
          return TabletControlLayout(controls: linearControls);
        case ControlBarLayoutKind.desktopSingle:
          return DesktopControlLayout(controls: linearControls);
        case ControlBarLayoutKind.desktopStacked:
          return DesktopStackedControlLayout(controls: linearControls);
      }
    }

    final Widget? panelLayout = useOneHandedScrubber
        ? CircleSliderLayout(
            width: width,
            panelPercent: circleSliderPanelWidthPercent,
            controls: controls,
            showControl: showControl,
            scrubberBuilder:
                (double? availableSpan, double? dialHeightPx) =>
                    scrubberSlot == PhoneScrubberSlot.oneHanded
                        ? PhoneOneHandedScrubber(
                            showControl: showControl,
                            color: color,
                            isLeftHanded: panelIsLeft,
                            availableSpan: availableSpan,
                            dialHeightPx: dialHeightPx,
                          )
                        : controls.circleSlider,
          )
        : useCircleSlider
            ? CircleSliderLayout(
                width: width,
                panelPercent: circleSliderPanelWidthPercent,
                controls: controls,
                showControl: showControl,
                scrubberBuilder: (double? _, double? __) =>
                    controls.circleSlider,
              )
            : null;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            // transparent → subtle dark → strong dark
            Colors.black.withValues(alpha: kOverlayGradientTopOpacity),
            Colors.black.withValues(alpha: kOverlayGradientMidOpacity),
            Colors.black.withValues(alpha: kOverlayGradientBottomOpacity),
          ],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Use the bar's REAL available width (video zone; a docked playlist
          // shrinks it) instead of the window width, so a narrow picture
          // degrades the layout even while the window stays wide. Unbounded
          // constraints (tests, bare rows) fall back to MediaQuery.
          final double availableWidth = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          return panelLayout ?? linearLayoutFor(availableWidth);
        },
      ),
    );
  }
}
