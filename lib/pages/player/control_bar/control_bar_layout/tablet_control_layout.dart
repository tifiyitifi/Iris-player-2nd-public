import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/view/background_quick_bar.dart';
import 'package:iris/features/control_group/model/enum/player_control_group.dart';
import 'package:iris/features/control_group/store/use_control_group_store.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_button_row.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_controls.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_layout_kind.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/resolve_control_bar_overflow.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/platform.dart';

class TabletControlLayout extends HookWidget {
  const TabletControlLayout({super.key, required this.controls});

  final ControlBarControls controls;

  @override
  Widget build(BuildContext context) {
    // Same bottom-group contract as the phone layout: mobile never shows the
    // standalone 副音 row, and group 2 replaces the button row. Desktop keeps
    // the standalone row ONLY in legacy mode (no phone-mode, floating switch
    // off); with either on, the bar shows exactly one group.
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
    final Set<ControlBarSlot> collapsed = controls.collapsed;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        controls.slider,
        if (showStandaloneQuickBar) controls.backgroundQuickBar,
        const SizedBox(height: 4),
        if (showingBackgroundGroup)
          BackgroundQuickBar(
            axis: Axis.horizontal,
            alignment: MainAxisAlignment.center,
            forceVisible: true,
            color: controls.color,
            overlayColor: controls.overlayColor,
          )
        else
          // Legacy tablet split: transport group packed left, secondary group
          // packed right, one gap between them (the trailing unit wraps to its
          // own run only when the bar is too narrow).
          ControlBarGroupedRow(
            leading: [
              if (!collapsed.contains(ControlBarSlot.playPause)) controls.playPause,
              if (!collapsed.contains(ControlBarSlot.stop)) controls.stop,
              if (!collapsed.contains(ControlBarSlot.prev)) controls.prev,
              if (!collapsed.contains(ControlBarSlot.next)) controls.next,
              if (!collapsed.contains(ControlBarSlot.shuffle)) controls.shuffle,
              if (!collapsed.contains(ControlBarSlot.repeat)) controls.repeat,
              if (controls.showFit && !collapsed.contains(ControlBarSlot.fit))
                controls.fit,
              if (!collapsed.contains(ControlBarSlot.rate)) controls.rate,
              if (!collapsed.contains(ControlBarSlot.volume))
                controls.rotateOrVolume,
            ],
            trailing: [
              if (!collapsed.contains(ControlBarSlot.subtitle))
                controls.subtitle,
              if (!collapsed.contains(ControlBarSlot.backgroundMenu))
                controls.backgroundPlaybackMenu,
              // The playback row's lock slot (see MobileControlLayout): tablet
              // video is a primary lock scenario and this bar is its only
              // surface at 640–1024. Inert on the desktop app, where
              // `showScreenLock` is false.
              if (controls.showScreenLock) controls.screenLock,
              if (!collapsed.contains(ControlBarSlot.playQueue))
                controls.playQueue,
              if (!collapsed.contains(ControlBarSlot.storage)) controls.storage,
              if (isDesktop && !collapsed.contains(ControlBarSlot.fullscreen))
                controls.fullscreen,
              controls.more,
            ],
          ),
      ],
    );
  }
}
