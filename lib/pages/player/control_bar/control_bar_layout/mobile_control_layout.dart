import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/view/background_quick_bar.dart';
import 'package:iris/features/control_group/model/enum/player_control_group.dart';
import 'package:iris/features/control_group/store/use_control_group_store.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_button_row.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_controls.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_layout_kind.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/portrait_bar_align.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/resolve_control_bar_overflow.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/platform.dart';

/// Phone-portrait / narrow bottom bar: seek slider + two button rows.
///
/// The two groups carry INDEPENDENT horizontal alignment (see
/// [PortraitBarAlign]): the normal playback rows spread/pack via
/// [portraitPlaybackRowAlign], while the group-2 副音 block is positioned by an
/// outer `Align` ([portraitSubAudioBlockAlign]) because a shrink-wrapped
/// `BalancedButtonWrap` would otherwise be centred by the `Column`. The default
/// is [PortraitBarAlign.center] — the pre-238d47c2 look. This is PORTRAIT-only:
/// the side panel and the standalone desktop 副音 row keep their own knobs.
class MobileControlLayout extends HookWidget {
  const MobileControlLayout({super.key, required this.controls});

  final ControlBarControls controls;

  @override
  Widget build(BuildContext context) {
    // Bottom control group: playback (two legacy rows) vs 副音 quick controls.
    // The standalone 副音 row is gone on phones; group 2 owns it here. On
    // desktop it survives only in legacy mode (no phone-mode, floating switch
    // off); group-switch mode shows exactly one group.
    final PlayerControlGroup group =
        useControlGroupStore().select(context, (s) => s.group);
    final bool desktopPhoneMode =
        useAppStore().select(context, (s) => s.desktopCenterZonePhoneMode);
    final bool floatingDesktop =
        useControlGroupStore().select(context, (s) => s.floatingButtonDesktop);
    final bool supported = resolveControlBarGroupSupport(
      isMobile: isMobilePlatform,
      desktopPhoneMode: desktopPhoneMode,
      desktopFloatingEnabled: floatingDesktop,
    );
    final bool showingBackgroundGroup =
        supported && group == PlayerControlGroup.background;
    final bool showStandaloneQuickBar = showStandaloneQuickBarFor(
      isMobile: isMobilePlatform,
      groupSupported: supported,
    );
    // 副音 menu button MOVES into the 副音 group on PHONES: their playback row
    // hands the slot to the screen-lock toggle. The desktop bars are untouched
    // (a narrow desktop window also renders this layout, so the gate is the
    // platform, never the layout kind).
    final bool bgMenuInGroup = isMobilePlatform;

    final PortraitBarAlign portraitAlign =
        useAppStore().select(context, (s) => s.portraitPlaybackAlign);
    final PortraitBarAlign portraitSubAlign =
        useAppStore().select(context, (s) => s.portraitSubAudioAlign);
    final MainAxisAlignment playbackAlign =
        portraitPlaybackRowAlign(portraitAlign);
    final Set<ControlBarSlot> collapsed = controls.collapsed;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        controls.slider,
        if (showStandaloneQuickBar) controls.backgroundQuickBar,
        if (showingBackgroundGroup)
          // The 副音 bar shrink-wraps, so its BLOCK position is owned by this
          // Align (a bare Column child would be centred regardless of the
          // wrap's own alignment). heightFactor keeps it from eating the column.
          Align(
            alignment: portraitSubAudioBlockAlign(portraitSubAlign),
            heightFactor: 1,
            child: BackgroundQuickBar(
              axis: Axis.horizontal,
              alignment: portraitSubAudioWrapAlign(portraitSubAlign),
              forceVisible: true,
              color: controls.color,
              overlayColor: controls.overlayColor,
              // The 副音 menu closes the group (the counterpart of More on the
              // playback row) — phones only, see [bgMenuInGroup].
              trailingAction:
                  bgMenuInGroup ? controls.backgroundPlaybackMenu : null,
            ),
          )
        else ...[
          ControlBarButtonRow(
            alignment: wrapAlignmentFrom(playbackAlign),
            children: [
              if (!collapsed.contains(ControlBarSlot.shuffle)) controls.shuffle,
              if (!collapsed.contains(ControlBarSlot.prev)) controls.prev,
              if (!collapsed.contains(ControlBarSlot.playPause))
                controls.playPause,
              if (!collapsed.contains(ControlBarSlot.stop)) controls.stop,
              if (!collapsed.contains(ControlBarSlot.next)) controls.next,
              if (!collapsed.contains(ControlBarSlot.repeat)) controls.repeat,
            ],
          ),
          ControlBarButtonRow(
            alignment: wrapAlignmentFrom(playbackAlign),
            children: [
              if (controls.showFit && !collapsed.contains(ControlBarSlot.fit))
                controls.fit,
              if (!collapsed.contains(ControlBarSlot.volume))
                controls.rotateOrVolume,
              if (!collapsed.contains(ControlBarSlot.subtitle))
                controls.subtitle,
              // 副音 menu: phones hand its slot to the screen-lock toggle (the
              // menu went into the 副音 group); desktop keeps the menu here.
              if (!bgMenuInGroup &&
                  !collapsed.contains(ControlBarSlot.backgroundMenu))
                controls.backgroundPlaybackMenu,
              if (controls.showScreenLock) controls.screenLock,
              if (!collapsed.contains(ControlBarSlot.playQueue))
                controls.playQueue,
              if (!collapsed.contains(ControlBarSlot.storage))
                controls.storage,
              if (isDesktop && !collapsed.contains(ControlBarSlot.fullscreen))
                controls.fullscreen,
              controls.more,
            ],
          ),
        ],
      ],
    );
  }
}
