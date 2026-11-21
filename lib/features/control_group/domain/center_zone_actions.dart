import 'package:flutter/widgets.dart';
import 'package:iris/features/background_playback/view/player_control_target_scope.dart';
import 'package:iris/features/control_group/store/use_control_group_store.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:provider/provider.dart';

/// Executes one center-sector action.
///
/// Shared by the classic circle slider and the ring dial so their centre
/// tap semantics can never drift. [showControl] refreshes the auto-hide
/// timer for actions that are visible UI work.
void handleCenterZoneAction({
  required BuildContext context,
  required CircleSliderCenterAction action,
  required VoidCallback? showControl,
}) {
  final uiStore = usePlayerUiStore();
  final MediaPlayer player = context.read<MediaPlayer>();
  final bool isPlaying = player.isPlaying;
  switch (action) {
    case CircleSliderCenterAction.none:
      return;
    case CircleSliderCenterAction.toggleControls:
      uiStore.updateIsShowControl(false);
      uiStore.updateIsHovering(false);
      // Explicit cancel must clear click-arm so hover stays title-only.
      try {
        // ignore: avoid_dynamic_calls
        uiStore.updateIsPanelClickArmed(false);
      } catch (_) {}
      return;
    case CircleSliderCenterAction.togglePlayPause:
      showControl?.call();
      // The dial's centre is mounted under the control-target override, so the
      // resolved player may be the 副音 engine: the flag written must follow it
      // (ADR 0017).
      setActiveTransportFlag(context, playing: !isPlaying);
      if (isPlaying) {
        // ignore: discarded_futures
        player.pause();
      } else {
        // ignore: discarded_futures
        player.play();
      }
      return;
    case CircleSliderCenterAction.switchControlGroup:
      showControl?.call();
      // ignore: discarded_futures
      useControlGroupStore().cycleGroup();
      return;
  }
}
