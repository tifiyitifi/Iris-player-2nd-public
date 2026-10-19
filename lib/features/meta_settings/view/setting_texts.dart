import 'package:iris/l10n/app_localizations.dart';

/// l10n resolution for metadata rows.
///
/// One hand-written switch over def keys — deliberately compile-checked
/// against the ARB getters (a typo here is an analyzer error, unlike string
/// interpolation into the catalog). Unknown keys degrade to a readable
/// fallback so a new def can render before its text lands.
abstract final class SettingTexts {
  static String title(String key, AppLocalizations t) =>
      titleOrNull(key, t) ?? _prettify(key);

  /// Null when no ARB mapping exists (unknown keys degrade to [title]'s
  /// readable fallback). The coverage test uses this to verify every def's
  /// titleKey has a real localized string.
  static String? titleOrNull(String key, AppLocalizations t) => switch (key) {
        'player_backend' => t.player_backend,
        'auto_resize' => t.auto_resize,
        'always_play_from_beginning' => t.always_play_from_beginning,
        'screen_orientation' => t.screen_orientation,
        'slider_type' => t.set_slider_type,
        'set_portrait_bar_align' => t.set_portrait_bar_align,
        'reuse_last_orientation' => t.reuse_last_orientation,
        'show_controls_on_play_to_pause' => t.show_controls_on_play_to_pause,
        'language' => t.language,
        'theme_mode' => t.theme_mode,
        'export_label' => t.export_label,
        'import_label' => t.import_label,
        'popup_direction' => t.popup_direction,
        'breadcrumb_start_side' => t.breadcrumb_start_side,
        'keyboard_shortcut_scheme' => t.set_keyboard_shortcut_scheme,
        'desktop_control_bar_layout' => t.set_desktop_control_bar_layout,
        'desktop_hover_show_title' => t.desktop_hover_show_title,
        'desktop_hover_show_control_bar' => t.desktop_hover_show_control_bar,
        'scan_auto_close' => t.set_scan_auto_close,
        'webdav_scan_mode' => t.set_webdav_scan_mode,
        'browse_media_scope' => t.set_browse_media_scope,
        'resume_on_startup' => t.set_resume_on_startup,
        'drop_append_zone_percent' => t.set_drop_append_zone_percent,
        'playback_cache_preset' => t.set_playback_cache_preset,
        'controls_title_settings' => t.controls_title_settings,
        'minimal_title_settings' => t.minimal_title_settings,
        'warning_dialog_prefs' => t.set_warning_dialog_prefs,
        'identity_entries' => t.set_identity_entries,
        'osd_enabled' => t.set_osd_enabled,
        'osd_visibility_mode' => t.set_osd_visibility_mode,
        'osd_h_align' => t.set_osd_h_align,
        'osd_v_align' => t.set_osd_v_align,
        'osd_layout' => t.set_osd_layout,
        'osd_duration' => t.set_osd_duration,
        'window_keep_in_bounds' => t.set_window_keep_in_bounds,
        'keybind_editor' => t.set_keybind_editor,
        'legacy_compat' => t.set_legacy_compat,
        'speed_gesture_mode' => t.set_speed_gesture_mode,
        'speed_rate_mode' => t.set_speed_rate_mode,
        'virtual_media_cross_drag' => t.set_virtual_media_cross_drag,
        'vm_mark_tick_color' => t.set_vm_mark_tick_color,
        'vm_naming_strategy' => t.set_vm_naming_strategy,
        'vm_name_prefix' => t.set_vm_name_prefix,
        'vm_name_number_format' => t.set_vm_name_number_format,
        'vm_dual_time_sync' => t.set_vm_dual_time_sync,
        'vm_hide_chunk_when_single_segment' =>
          t.set_vm_hide_chunk_when_single_segment,
        'vm_multi_select_hint' => t.set_vm_multi_select_hint,
        'virtual_media' => t.set_virtual_media,
        'screenshot_save_path' => t.set_screenshot_save_path,
        'set_bg_follow_fg' => t.set_bg_follow_fg,
        'set_bg_rate_lock' => t.set_bg_rate_lock,
        'set_bg_allow_same_file' => t.set_bg_allow_same_file,
        'set_bg_video_layout' => t.set_bg_video_layout,
        'set_bg_keep_warm' => t.set_bg_keep_warm,
        'set_bg_start_armed' => t.set_bg_start_armed,
        'set_bg_gate_stop_behavior' => t.set_bg_gate_stop_behavior,
        'set_bg_align_default' => t.set_bg_align_default,
        'set_bg_ratio_explicit_save' => t.set_bg_ratio_explicit_save,
        'set_bg_auto_focus' => t.set_bg_auto_focus,
        'set_bg_seek_link' => t.set_bg_seek_link,
        'set_bg_use_saved_mapping' => t.set_bg_use_saved_mapping,
        'set_bg_lock_level' => t.set_bg_lock_level,
        'set_bg_step_mode' => t.set_bg_step_mode,
        'set_bg_align_warn' => t.set_bg_align_warn,
        'set_bg_exhausted_action' => t.set_bg_exhausted_action,
        'set_bg_queue_sync_mode' => t.set_bg_queue_sync_mode,
        'set_bg_align_ring' => t.set_bg_align_ring,
        'set_bg_quick_bar' => t.set_bg_quick_bar,
        'set_bg_quick_bar_align' => t.set_bg_quick_bar_align,
        'set_bg_item_switch' => t.set_bg_item_switch,
        'set_bg_segment_switch' => t.set_bg_segment_switch,
        'set_bg_vm_scope_mode' => t.set_bg_vm_scope_mode,
        'set_bg_min_segment_span' => t.set_bg_min_segment_span,
        'set_bg_p_align_keep_length' => t.set_bg_p_align_keep_length,
        'set_bg_sticky_consume' => t.set_bg_sticky_consume,
        'set_bg_segment_guide' => t.set_bg_segment_guide,
        'set_bg_fg_window_zoom' => t.set_bg_fg_window_zoom,
        'set_bg_fg_window_push_bg' => t.set_bg_fg_window_push_bg,
        'set_bg_align_snap' => t.set_bg_align_snap,
        'set_bg_align_snap_release_limit' =>
          t.set_bg_align_snap_release_limit,
        'set_tag_play_input_bar' => t.set_tag_play_input_bar,
        'set_tag_play_input_hint' => t.set_tag_play_input_hint,
        'set_tag_play_view_stack' => t.set_tag_play_view_stack,
        'window_fit_mode' => t.set_window_fit_mode,
        'playlist_panel_mode' => t.set_playlist_panel_mode,
        'side_fullscreen_behavior' => t.set_side_fullscreen_behavior,
        'set_fs_edge_reveal_width' => t.set_fs_edge_reveal_width,
        'set_fs_isolation_side' => t.set_fs_isolation_side,
        'set_fs_isolation_linear' => t.set_fs_isolation_linear,
        'playlist_popup_theme' => t.set_playlist_popup_theme,
        'playlist_dock_theme' => t.set_playlist_dock_theme,
        'set_scenario_queue_layout' => t.set_scenario_queue_layout,
        'video_display_mode' => t.set_video_display_mode,
        'gesture_profile' => t.set_gesture_profile,
        'scan_rescan_reminder' => t.set_scan_rescan_reminder,
        'transfer_audit_title' => t.transfer_audit_title,
        'center_zone_inward' => t.center_zone_inward,
        'center_zone_outward' => t.center_zone_outward,
        'center_zone_top' => t.center_zone_top,
        'center_zone_bottom' => t.center_zone_bottom,
        'desktop_center_zone_phone_mode' => t.desktop_center_zone_phone_mode,
        _ => null,
      };

  static String subtitle(String key, AppLocalizations t) =>
      subtitleOrNull(key, t) ?? '';

  /// Null when no ARB mapping exists (unknown keys render no subtitle).
  static String? subtitleOrNull(String key, AppLocalizations t) =>
      switch (key) {
        // Legacy descriptive subtitles — the defs carry the same ARB keys the
        // hand-written rows used, so no text is lost in the migration.
        'always_play_from_beginning_description' =>
          t.always_play_from_beginning_description,
        'show_controls_on_play_to_pause_description' =>
          t.show_controls_on_play_to_pause_description,
        'keyboard_shortcut_scheme_desc' => t.set_keyboard_shortcut_scheme_desc,
        'desktop_control_bar_layout_desc' =>
          t.set_desktop_control_bar_layout_desc,
        'desktop_hover_show_title_desc' =>
          t.desktop_hover_show_title_desc,
        'desktop_hover_show_control_bar_desc' =>
          t.desktop_hover_show_control_bar_desc,
        'warning_dialog_prefs_desc' => t.set_warning_dialog_prefs_desc,
        'scan_auto_close_desc' => t.set_scan_auto_close_desc,
        'scan_rescan_reminder_desc' => t.set_scan_rescan_reminder_desc,
        'webdav_scan_mode_desc' => t.set_webdav_scan_mode_desc,
        'browse_media_scope_desc' => t.set_browse_media_scope_desc,
        'resume_on_startup_desc' => t.set_resume_on_startup_desc,
        'drop_append_zone_percent_desc' => t.set_drop_append_zone_percent_desc,
        'playback_cache_preset_desc' => t.set_playback_cache_preset_desc,
        'identity_entries_desc' => t.set_identity_entries_desc,
        'auto_resize_desc' => t.set_auto_resize_desc,
        'playlist_panel_mode_desc' => t.set_playlist_panel_mode_desc,
        'side_fullscreen_behavior_desc' => t.set_side_fullscreen_behavior_desc,
        'set_fs_edge_reveal_width_desc' => t.set_fs_edge_reveal_width_desc,
        'set_fs_isolation_side_desc' => t.set_fs_isolation_side_desc,
        'set_fs_isolation_linear_desc' => t.set_fs_isolation_linear_desc,
        'playlist_popup_theme_desc' => t.set_playlist_popup_theme_desc,
        'playlist_dock_theme_desc' => t.set_playlist_dock_theme_desc,
        'set_scenario_queue_layout_desc' => t.set_scenario_queue_layout_desc,
        'video_display_mode_desc' => t.set_video_display_mode_desc,
        'osd_enabled_desc' => t.set_osd_enabled_desc,
        'osd_visibility_mode_desc' => t.set_osd_visibility_mode_desc,
        'osd_h_align_desc' => t.set_osd_h_align_desc,
        'osd_v_align_desc' => t.set_osd_v_align_desc,
        'osd_layout_desc' => t.set_osd_layout_desc,
        'osd_duration_desc' => t.set_osd_duration_desc,
        'keybind_editor_desc' => t.set_keybind_editor_desc,
        'window_keep_in_bounds_desc' => t.set_window_keep_in_bounds_desc,
        'speed_gesture_mode_desc' => t.set_speed_gesture_mode_desc,
        'speed_rate_mode_desc' => t.set_speed_rate_mode_desc,
        'legacy_compat_desc' => t.set_legacy_compat_desc,
        'slider_type_desc' => t.set_slider_type_desc,
        'set_portrait_bar_align_desc' => t.set_portrait_bar_align_desc,
        'screen_orientation_desc' => t.set_screen_orientation_desc,
        'gesture_profile_desc' => t.set_gesture_profile_desc,
        'controls_title_settings_desc' => t.configure_controls_title,
        'minimal_title_settings_desc' => t.configure_minimal_title,
        'breadcrumb_start_side_desc' => t.breadcrumb_start_side_desc,
        'virtual_media_desc' => t.set_virtual_media_desc,
        'virtual_media_cross_drag_desc' => t.set_virtual_media_cross_drag_desc,
        'vm_mark_tick_color_desc' => t.set_vm_mark_tick_color_desc,
        'vm_naming_strategy_desc' => t.set_vm_naming_strategy_desc,
        'vm_name_prefix_desc' => t.set_vm_name_prefix_desc,
        'vm_name_number_format_desc' => t.set_vm_name_number_format_desc,
        'vm_dual_time_sync_desc' => t.set_vm_dual_time_sync_desc,
        'vm_hide_chunk_when_single_segment_desc' =>
          t.set_vm_hide_chunk_when_single_segment_desc,
        'vm_multi_select_hint_desc' => t.set_vm_multi_select_hint_desc,
        'screenshot_save_path_desc' => t.set_screenshot_save_path_desc,
        'set_bg_follow_fg_desc' => t.set_bg_follow_fg_desc,
        'set_bg_rate_lock_desc' => t.set_bg_rate_lock_desc,
        'set_bg_allow_same_file_desc' => t.set_bg_allow_same_file_desc,
        'set_bg_video_layout_desc' => t.set_bg_video_layout_desc,
        'set_bg_keep_warm_desc' => t.set_bg_keep_warm_desc,
        'set_bg_keep_warm_off_notice' => t.set_bg_keep_warm_off_notice,
        'set_bg_start_armed_desc' => t.set_bg_start_armed_desc,
        'set_bg_gate_stop_behavior_desc' => t.set_bg_gate_stop_behavior_desc,
        'set_bg_align_default_desc' => t.set_bg_align_default_desc,
        'set_bg_ratio_explicit_save_desc' => t.set_bg_ratio_explicit_save_desc,
        'set_bg_auto_focus_desc' => t.set_bg_auto_focus_desc,
        'set_bg_seek_link_desc' => t.set_bg_seek_link_desc,
        'set_bg_use_saved_mapping_desc' => t.set_bg_use_saved_mapping_desc,
        'set_bg_lock_level_desc' => t.set_bg_lock_level_desc,
        'set_bg_step_mode_desc' => t.set_bg_step_mode_desc,
        'set_bg_align_warn_desc' => t.set_bg_align_warn_desc,
        'set_bg_exhausted_action_desc' => t.set_bg_exhausted_action_desc,
        'set_bg_queue_sync_mode_desc' => t.set_bg_queue_sync_mode_desc,
        'set_bg_align_ring_desc' => t.set_bg_align_ring_desc,
        'set_bg_quick_bar_desc' => t.set_bg_quick_bar_desc,
        'set_bg_quick_bar_align_desc' => t.set_bg_quick_bar_align_desc,
        'set_bg_item_switch_desc' => t.set_bg_item_switch_desc,
        'set_bg_segment_switch_desc' => t.set_bg_segment_switch_desc,
        'set_bg_vm_scope_mode_desc' => t.set_bg_vm_scope_mode_desc,
        'set_bg_min_segment_span_desc' => t.set_bg_min_segment_span_desc,
        'set_bg_p_align_keep_length_desc' =>
          t.set_bg_p_align_keep_length_desc,
        'set_bg_sticky_consume_desc' => t.set_bg_sticky_consume_desc,
        'set_bg_segment_guide_desc' => t.set_bg_segment_guide_desc,
        'set_bg_fg_window_zoom_desc' => t.set_bg_fg_window_zoom_desc,
        'set_bg_fg_window_push_bg_desc' => t.set_bg_fg_window_push_bg_desc,
        'set_bg_align_snap_desc' => t.set_bg_align_snap_desc,
        'set_bg_align_snap_release_limit_desc' =>
          t.set_bg_align_snap_release_limit_desc,
        'set_tag_play_input_bar_desc' => t.set_tag_play_input_bar_desc,
        'set_tag_play_input_hint_desc' => t.set_tag_play_input_hint_desc,
        'set_tag_play_view_stack_desc' => t.set_tag_play_view_stack_desc,
        'window_fit_mode_desc' => t.set_window_fit_mode_desc,
        'transfer_audit_log_desc' => t.transfer_audit_log_desc,
        'desktop_center_zone_phone_mode_desc' =>
          t.desktop_center_zone_phone_mode_desc,
        _ => null,
      };

  /// Group header labels for sectioned rendering.
  static String groupLabel(String key, AppLocalizations t) =>
      switch (key) {
        'group_playback' => t.set_group_playback,
        'group_gestures' => t.set_group_gestures,
        'group_virtual_media' => t.set_group_virtual_media,
        'group_background_playback' => t.set_group_background_playback,
        'group_desktop_tools' => t.set_group_desktop_tools,
        'group_desktop_hover' => t.set_group_desktop_hover,
        'group_center_zone' => t.set_group_center_zone,
        'group_appearance' => t.set_group_appearance,
        'group_data' => t.set_group_data,
        'group_titles' => t.set_group_titles,
        'group_warnings' => t.set_group_warnings,
        'group_osd' => t.set_group_osd,
        'group_scan' => t.set_group_scan,
        'group_advanced' => t.set_group_advanced,
        'group_tag_play' => t.group_tag_play,
        _ => '',
      };

  /// Enum value NAMES → localized labels. Keyed by the FULL def key because
  /// the same name can mean different things in different enums.
  static String enumLabel(String defKey, String name, AppLocalizations t) =>
      switch (defKey) {
        'app.playerBackend' => switch (name) {
            'mediaKit' => t.set_backend_media_kit,
            'fvp' => t.set_backend_fvp,
            _ => name,
          },
        'playback.videoCachePreset' => switch (name) {
            'low' => t.set_cache_preset_low,
            'balanced' => t.set_cache_preset_balanced,
            'high' => t.set_cache_preset_high,
            _ => name,
          },
        'app.themeMode' => switch (name) {
            'system' => t.system,
            'light' => t.light,
            'dark' => t.dark,
            _ => name,
          },
        'app.preferredOrientation' ||
        'app.runtimeOrientation' =>
          _orientation(name, t),
        'app.defaultPopupDirection' => switch (name) {
            'left' => t.popup_direction_left,
            'right' => t.popup_direction_right,
            _ => name,
          },
        'breadcrumb.startSides' || 'app.breadcrumbStartPortrait' => switch (
            name) {
            'left' => t.breadcrumb_start_left,
            'right' => t.breadcrumb_start_right,
            _ => name,
          },
        'app.ringDialPalette' => switch (name) {
            'rainbow' => t.set_palette_rainbow,
            'cold' => t.set_palette_cold,
            'warm' => t.set_palette_warm,
            'mono' => t.set_palette_mono,
            _ => name,
          },
        'app.keyboardShortcutScheme' => switch (name) {
            'legacy' => t.set_scheme_legacy,
            'potplayer' => t.set_scheme_potplayer,
            _ => name,
          },
        'app.desktopControlBarLayout' => switch (name) {
            'singleLine' => t.set_bar_single_line,
            'stacked' => t.set_bar_stacked,
            _ => name,
          },
        'app.webDavScanMode' => switch (name) {
            'discovery' => t.set_webdav_scan_mode_discovery,
            'legacyScan' => t.set_webdav_scan_mode_legacy,
            _ => name,
          },
        'speed.gestureMode' => switch (name) {
            'singleAxis' => t.set_speed_single_axis,
            'dualAxis' => t.set_speed_dual_axis,
            _ => name,
          },
        'speed.rateMode' => switch (name) {
            'dualWheel' => t.set_rate_mode_dual_wheel,
            'slider' => t.set_rate_mode_slider,
            'list' => t.set_rate_mode_list,
            _ => name,
          },
        'virtualmedia.crossDragStrategy' => switch (name) {
            'previewOnRelease' => t.set_cross_drag_preview,
            'directSwitch' => t.set_cross_drag_direct,
            _ => name,
          },
        'virtualmedia.namingStrategy' => switch (name) {
            'maxPlusOne' => t.set_naming_max_plus_one,
            'reuseGap' => t.set_naming_reuse_gap,
            'globalCounter' => t.set_naming_global_counter,
            _ => name,
          },
        'virtualmedia.nameNumberFormat' => switch (name) {
            'raw' => t.set_num_raw,
            'pad2' => t.set_num_pad2,
            'pad3' => t.set_num_pad3,
            'pad4' => t.set_num_pad4,
            _ => name,
          },
        'virtualmedia.dualTimeSync' => switch (name) {
            'exact' => t.set_dual_time_exact,
            'subToTotal' => t.set_dual_time_sub_to_total,
            'totalToSub' => t.set_dual_time_total_to_sub,
            _ => name,
          },
        'background_playback.videoLayout' => switch (name) {
            'fullscreen' => t.bg_layout_fullscreen,
            'pip' => t.bg_layout_pip,
            'split' => t.bg_layout_split,
            _ => name,
          },
        'background_playback.seekLink' => switch (name) {
            'linked' => t.bg_seek_linked,
            'independent' => t.bg_seek_independent,
            _ => name,
          },
        'background_playback.lockLevel' => switch (name) {
            'high' => t.bg_lock_level_high,
            'low' => t.bg_lock_level_low,
            _ => name,
          },
        'background_playback.gateStopBehavior' => switch (name) {
            'pause' => t.bg_gate_stop_pause,
            'unload' => t.bg_gate_stop_unload,
            _ => name,
          },
        'background_playback.stepMode' => switch (name) {
            'swapOnly' => t.bg_step_mode_swap_only,
            'followLink' => t.bg_step_mode_follow_link,
            _ => name,
          },
        'background_playback.alignRingAssignment' => switch (name) {
            'fgInner' => t.bg_align_ring_fg_inner,
            'fgOuter' => t.bg_align_ring_fg_outer,
            _ => name,
          },
        'background_playback.quickBarAlign' => switch (name) {
            'left' => t.bg_align_left,
            'right' => t.bg_align_right,
            _ => name,
          },
        'background_playback.itemSwitch' => switch (name) {
            'keepPlaying' => t.bg_cross_keep_playing,
            'newBg' => t.bg_cross_new_bg,
            _ => name,
          },
        'background_playback.segmentSwitch' => switch (name) {
            'keepPlaying' => t.bg_cross_keep_playing_tiled,
            'newBg' => t.bg_cross_new_bg,
            _ => name,
          },
        'background_playback.vmScopeMode' => switch (name) {
            'perBlock' => t.bg_vm_scope_per_block,
            'wholeVirtual' => t.bg_vm_scope_whole,
            _ => name,
          },
        'background_playback.exhaustedAction' => switch (name) {
            'nextBg' => t.bg_exhausted_next_bg_short,
            'stopRestoreFg' => t.bg_exhausted_stop_restore_short,
            _ => name,
          },
        'background_playback.queueSyncMode' => switch (name) {
            'rebuild' => t.bg_queue_sync_rebuild,
            'append' => t.bg_queue_sync_append,
            _ => name,
          },
        'background_playback.stickyConsume' => switch (name) {
            'off' => t.bg_sticky_consume_off,
            'pOnly' => t.bg_sticky_consume_p_only,
            'abOnly' => t.bg_sticky_consume_ab_only,
            'all' => t.bg_sticky_consume_all,
            _ => name,
          },
        'window.fitMode' => switch (name) {
            'fitVideo' => t.osd_window_fit,
            'fixedWindow' => t.osd_window_fixed,
            _ => name,
          },
        'window.playlistPanelMode' => switch (name) {
            'popup' => t.set_panel_popup,
            'dockedRight' => t.set_panel_docked,
            _ => name,
          },
        'window.sideFullscreenBehavior' => switch (name) {
            'keepPanel' => t.set_side_fs_keep,
            'hidePanel' => t.set_side_fs_hide,
            _ => name,
          },
        'window.playlistPopupTheme' => switch (name) {
            'system' => t.system,
            'dark' => t.dark,
            'light' => t.light,
            _ => name,
          },
        'window.playlistDockTheme' => switch (name) {
            'potlikeDark' => t.set_dock_theme_potlike,
            'system' => t.system,
            'light' => t.light,
            _ => name,
          },
        'window.scenarioQueueLayout' => switch (name) {
            'v1' => t.scn_queue_layout_v1,
            'v2' => t.scn_queue_layout_v2,
            'v3' => t.scn_queue_layout_v3,
            _ => name,
          },
        'video.desktopDisplayMode' => switch (name) {
            'contain' => t.disp_contain,
            'fill' => t.disp_fill,
            'cover' => t.disp_cover,
            'adaptiveOriginal' => t.disp_adaptive,
            'forcedOriginal' => t.disp_forced,
            _ => name,
          },
        'video.mobileDisplayMode' => switch (name) {
            'contain' => t.disp_contain,
            'fill' => t.disp_fill,
            'cover' => t.disp_cover,
            _ => name,
          },
        'app.centerZoneInwardAction' ||
        'app.centerZoneOutwardAction' ||
        'app.centerZoneTopAction' ||
        'app.centerZoneBottomAction' =>
          _centerZoneAction(name, t),
        _ => _prettify(name),
      };

  /// Shared labels for the four center-zone action pickers.
  static String _centerZoneAction(String name, AppLocalizations t) =>
      switch (name) {
        'none' => t.sld_action_none,
        'toggleControls' => t.sld_action_toggle,
        'togglePlayPause' => t.sld_action_play_pause,
        'switchControlGroup' => t.sld_action_switch_group,
        _ => name,
      };

  static String _orientation(String name, AppLocalizations t) =>
      switch (name) {
        'device' => t.device,
        'landscape' => t.landscape,
        'portrait' => t.portrait,
        _ => name,
      };

  static String _prettify(String key) {
    final last = key.split('.').last;
    final result = last
        .replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m[1]}')
        .trim();
    return result.isEmpty ? key : result[0].toUpperCase() + result.substring(1);
  }
}
