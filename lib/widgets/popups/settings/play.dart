import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/hooks/ui/mappers/enum_localization.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/dialogs/show_slider_type_dialog.dart';
import 'package:iris/widgets/dialogs/show_orientation_dialog.dart';
import 'package:iris/widgets/dialogs/show_phone_horizontal_slider_dialog.dart';
import 'package:iris/widgets/dialogs/show_phone_landscape_use_mode_dialog.dart';
import 'package:iris/widgets/dialogs/show_phone_one_handed_scrubber_kind_dialog.dart';
import 'package:iris/widgets/dialogs/show_snake_fine_window_dialog.dart';

class Play extends HookWidget {
  const Play({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);

    final autoResize = useAppStore().select(context, (state) => state.autoResize);
    final bool alwaysPlayFromBeginning = useAppStore().select(context, (state) => state.alwaysPlayFromBeginning);
    final playerBackend = useAppStore().select(context, (state) => state.playerBackend);

    // final orientation = useAppStore().select(context, (state) => state.orientation);

    final preferredOrientation = useAppStore().select(context, (state) => state.preferredOrientation);
    final lastOrientation = useAppStore().select(context, (state) => state.runtimeOrientation);
    final bool reuseLastOrientation = useAppStore().select(context, (state) => state.reuseLastOrientation);
    final phoneLandscapeSliderType = useAppStore().select(context, (state) => state.phoneLandscapeSliderType);
    final phoneLandscapeUseMode = useAppStore().select(context, (state) => state.phoneLandscapeUseMode);
    final phoneOneHandedKind = useAppStore().select(context, (state) => state.phoneOneHandedScrubberKind);
    final snakeFineSec = useAppStore().select(context, (state) => state.snakeFineWindowSeconds);

    final screenOrientationLabels = screenOrientationLabelsMap(t);
    final phoneLandscapeSliderTypeLabels = phoneLandscapeSliderTypeLabelsMap(t);

    final bool showControlsOnPlayToPause = useAppStore().select(context, (state) => state.showControlsOnPlayToPause);

    return SingleChildScrollView(
      child: Column(
        children: [
          ListTile(
              leading: const Icon(Icons.settings_input_component_rounded),
              title: Text(t.player_backend),
              trailing: DropdownButton<PlayerBackend>(
                borderRadius: BorderRadius.circular(12),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                value: playerBackend,
                onChanged: (value) {
                  if (value != null) useAppStore().updatePlayerBackend(value);
                },
                items: [
                  DropdownMenuItem<PlayerBackend>(value: PlayerBackend.mediaKit, child: Text(t.play_backend_mediakit)),
                  DropdownMenuItem<PlayerBackend>(value: PlayerBackend.fvp, child: Text(t.play_backend_fvp)),
                ],
              )),
          Visibility(
            visible: isDesktop,
            child: ListTile(
              leading: const Icon(Icons.aspect_ratio_rounded),
              title: Text(t.auto_resize),
              onTap: () => useAppStore().toggleAutoResize(),
              trailing: Checkbox(
                value: autoResize,
                onChanged: (_) => useAppStore().toggleAutoResize(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt_rounded),
            title: Text(t.always_play_from_beginning),
            subtitle: Text(t.always_play_from_beginning_description),
            onTap: () => useAppStore().toggleAlwaysPlayFromBeginning(),
            trailing: Checkbox(
              value: alwaysPlayFromBeginning,
              onChanged: (_) => useAppStore().toggleAlwaysPlayFromBeginning(),
            ),
          ),
          if (isMobilePlatform)
            ListTile(
              leading: const Icon(Icons.pan_tool_alt_rounded),
              title: Text(t.play_landscape_controls),
              // The deprecated hand members are folded away by the loader, so
              // the arms below are unreachable; they exist only to keep the
              // switch exhaustive over the enum.
              subtitle: Text(switch (phoneLandscapeUseMode) {
                PhoneLandscapeUseMode.normal => t.play_mode_normal,
                PhoneLandscapeUseMode.rightSide => t.play_mode_right,
                PhoneLandscapeUseMode.leftSide => t.play_mode_left,
                PhoneLandscapeUseMode.rightHanded => t.play_mode_right,
                PhoneLandscapeUseMode.leftHanded => t.play_mode_left,
              }),
              onTap: () => showPhoneLandscapeUseModeDialog(context),
            ),
          if (isMobilePlatform)
            ListTile(
              leading: const Icon(Icons.timeline_rounded),
              title: Text(t.play_scrubber_design),
              subtitle: Text(switch (phoneOneHandedKind) {
                PhoneOneHandedScrubberKind.arc => t.play_scrubber_arc,
                PhoneOneHandedScrubberKind.timeLens => t.play_scrubber_time_lens,
                PhoneOneHandedScrubberKind.snake => t.play_scrubber_snake,
                PhoneOneHandedScrubberKind.dial => t.play_scrubber_dial,
                PhoneOneHandedScrubberKind.classic => t.play_scrubber_classic,
              }),
              onTap: () => showPhoneOneHandedScrubberKindDialog(context),
            ),
          if (isMobilePlatform)
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: Text(t.play_fine_range),
              subtitle: Text(t.play_fine_shared(snakeFineSec)),
              onTap: () => showSnakeFineWindowDialog(context),
            ),
          if (isMobilePlatform)
            ListTile(
              leading: const Icon(Icons.screen_rotation_rounded),
              title: Text(t.screen_orientation),
              subtitle: Text(screenOrientationLabels[preferredOrientation] ?? preferredOrientation.name),
              onTap: () => showOrientationDialog(context),
            ),
          if (isMobilePlatform)
            ListTile(
              leading: const Icon(Icons.incomplete_circle),
              title: Text(t.phone_landscape_slider_type),
              subtitle: Text(phoneLandscapeSliderTypeLabels[phoneLandscapeSliderType] ?? phoneLandscapeSliderType.name),
              onTap: () => showPhoneLandScapeSliderDialog(context),
            ),
          if (isMobilePlatform)
            ListTile(
              leading: const Icon(Icons.screen_lock_rotation),
              title: Text(t.reuse_last_orientation),
              subtitle: Text(
                  "${t.reuse_last_orientation_description}:${screenOrientationLabels[lastOrientation] ?? lastOrientation.name}"),
              onTap: () => useAppStore().toggleReuseLastRotateOrientation(),
              trailing: Checkbox(
                value: reuseLastOrientation,
                onChanged: (_) => useAppStore().toggleReuseLastRotateOrientation(),
              ),
            ),

          // Center tap behavior now lives in the slider-type dialog as four
          // independent center-zone pickers (circle slider / ring dial).
          if (isMobilePlatform)
            ListTile(
              leading: const Icon(Icons.lightbulb_circle_outlined),
              title: Text(t.sld_center_action),
              onTap: () => showSliderTypeDialog(context),
            ),
          // NOTE: the 手势布局 (gesture_unified) tile used to live here behind
          // `useAppStore().state.useMetadataSettings` — a BARE read, not a
          // subscription. It was unreachable regardless: this legacy panel is
          // only mounted when the metadata gate is OFF (`Settings` returns
          // `MetaSettingsPage` otherwise), so the condition was always false.
          // The live entry is the `gesture_unified` editor in the meta page
          // (features/meta_settings/view/widgets/editor_bindings.dart).

          if (isMobilePlatform)
            ListTile(
              leading: const Icon(Icons.pause_circle),
              title: Text(t.show_controls_on_play_to_pause),
              subtitle: Text(t.show_controls_on_play_to_pause_description),
              onTap: () => useAppStore().toggleShowControlsOnPlayToPause(),
              trailing: Checkbox(
                value: showControlsOnPlayToPause,
                onChanged: (_) => useAppStore().toggleShowControlsOnPlayToPause(),
              ),
            ),
        ],
      ),
    );
  }
}
