import 'package:flutter/material.dart';

/// iconKey → IconData resolution for generic-rendered rows.
///
/// Keys mirror the legacy panels' leading icons so the metadata renderer is
/// visually indistinguishable from the hand-written lists. Hand-written
/// editor bindings (editor_bindings.dart) resolve their own icons directly, so
/// a def whose row is `custom` may carry an iconKey with no entry here.
abstract final class SettingIcons {
  static const Map<String, IconData> _map = <String, IconData>{
    'player_backend': Icons.settings_input_component_rounded,
    'auto_resize': Icons.aspect_ratio_rounded,
    'always_play_from_beginning': Icons.restart_alt_rounded,
    'resume_on_startup': Icons.play_circle_outline,
    'drop_append_zone_percent': Icons.vertical_split_rounded,
    'playback_cache_preset': Icons.sd_storage_rounded,
    'playback_step_tail_finish': Icons.skip_next_rounded,
    'reuse_last_orientation': Icons.screen_lock_rotation,
    'show_controls_on_play_to_pause': Icons.pause_circle,
    'language': Icons.translate_rounded,
    'theme_mode': Icons.contrast_rounded,
    'popup_direction': Icons.open_in_new_rounded,
    'breadcrumb_start_side': Icons.sync_alt,
    'scan_auto_close': Icons.timer_outlined,
    'osd_enabled': Icons.info_outline_rounded,
    'osd_visibility_mode': Icons.visibility_outlined,
    'osd_h_align': Icons.horizontal_distribute_rounded,
    'osd_v_align': Icons.vertical_distribute_rounded,
    'osd_layout': Icons.view_agenda_outlined,
    'osd_duration': Icons.timer_outlined,
    'keep_in_bounds': Icons.fit_screen_rounded,
    // Generic enumPick rows — unified rounded style.
    'playlist': Icons.playlist_play_rounded,
    'fullscreen': Icons.fullscreen_rounded,
    'video_zoom': Icons.aspect_ratio_rounded,
    'slider_type': Icons.line_style_rounded,
    'screen_orientation': Icons.screen_rotation_rounded,
    'gesture_profile': Icons.touch_app_rounded,
    'keyboard_shortcut_scheme': Icons.keyboard_rounded,
    'desktop_control_bar_layout': Icons.table_rows_rounded,
    'desktop_hover_show_title': Icons.title_rounded,
    'desktop_hover_show_control_bar': Icons.control_camera_rounded,
    'keybind_editor': Icons.keyboard_alt_rounded,
    'browse_media_scope': Icons.video_library_outlined,
    'controls_title_settings': Icons.title_rounded,
    'minimal_title_settings': Icons.text_fields_rounded,
    'warning_dialog_prefs': Icons.warning_amber_rounded,
    'legacy_compat': Icons.history_rounded,
    'identity_entries': Icons.alternate_email_rounded,
    'speed_gesture_mode': Icons.speed_rounded,
    'speed_rate_mode': Icons.tune_rounded,
    'virtual_media': Icons.video_collection_rounded,
    'center_zone_inward': Icons.center_focus_weak_rounded,
    'center_zone_outward': Icons.zoom_out_map_rounded,
    'center_zone_top': Icons.vertical_align_top_rounded,
    'center_zone_bottom': Icons.vertical_align_bottom_rounded,
    'desktop_center_zone_phone_mode': Icons.phone_android_rounded,
  };

  static IconData? resolve(String? iconKey) =>
      iconKey == null ? null : _map[iconKey];

  /// Every resolved iconKey — used by the residue guard test to keep the map
  /// free of entries whose def was retired.
  static Iterable<String> get keys => _map.keys;
}
