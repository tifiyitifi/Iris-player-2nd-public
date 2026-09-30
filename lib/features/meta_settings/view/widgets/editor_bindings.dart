import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/app_identity/view/app_identity_manager_page.dart'
    show showAppIdentityManager;
import 'package:iris/features/background_playback/model/background_playback_state.dart';
import 'package:iris/features/background_playback/model/enum/align_ring_assignment.dart';
import 'package:iris/features/background_playback/model/enum/bg_align_default.dart';
import 'package:iris/features/background_playback/model/enum/bg_cross_action.dart';
import 'package:iris/features/background_playback/model/enum/bg_exhausted_action.dart';
import 'package:iris/features/background_playback/model/enum/bg_gate_stop_behavior.dart';
import 'package:iris/features/background_playback/model/enum/bg_queue_sync_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_quick_bar_align.dart';
import 'package:iris/features/background_playback/model/enum/bg_seek_link.dart';
import 'package:iris/features/background_playback/model/enum/bg_step_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_sticky_consume.dart';
import 'package:iris/features/background_playback/model/enum/bg_video_layout.dart';
import 'package:iris/features/background_playback/model/enum/bg_vm_scope_mode.dart';
import 'package:iris/features/background_playback/services/background_alignment.dart'
    show kMaxAlignWarnRemainSec, kMinAlignWarnRemainSec;
import 'package:iris/features/background_playback/resolver/segment_span_math.dart'
    show kMaxMinSegmentSpanMs, kMinMinSegmentSpanMs;
import 'package:iris/features/background_playback/resolver/fg_display_window.dart'
    show FgDisplayWindowMath;
import 'package:iris/features/background_playback/resolver/segment_snap.dart';
import 'package:iris/features/background_playback/view/bg_segment_guide_dialog.dart'
    show showBgSegmentGuideDialog;
import 'package:iris/features/background_playback/store/bg_source_prefs.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/background_sources_sheet.dart'
    show showBackgroundSourcesSheet;
import 'package:iris/models/db/db_module.dart';
import 'package:iris/features/virtual_media/view/vm_manager_page.dart'
    show showVirtualMediaManager;
import 'package:iris/features/virtual_media/view/vm_mark_color_dialog.dart'
    show showVmMarkColorDialog;
import 'package:iris/features/virtual_media/rule/vm_tick_color.dart'
    show vmTickColorLabel;
import 'package:iris/features/virtual_media/rule/vm_tick_extent.dart'
    show vmTickExtentLabel;
import 'package:iris/features/virtual_media/store/vm_prefs.dart' show VmPrefs;
import 'package:iris/features/media_library/scan/view/scan_auto_close_settings_dialog.dart';
import 'package:iris/features/playback_tools/services/screenshot_paths.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_queue_layout.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_queue_profile.dart';
import 'package:iris/features/tag_play/playback/tag_play_input_policy.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/features/playback_tools/view/screenshot_save_path_dialog.dart'
    show showScreenshotSavePathDialog;
import 'package:iris/features/media_library/scan/view/scan_rescan_reminder_dialog.dart'
    show openScanRescanReminder;
import 'package:iris/features/meta_settings/engine/browse_media_scope.dart';
import 'package:iris/features/meta_settings/engine/playback_resume.dart';
import 'package:iris/features/meta_settings/engine/video_cache_preset.dart';
import 'package:iris/models/enums/video_cache_preset.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/meta_settings/view/setting_texts.dart';
import 'package:iris/features/meta_settings/view/widgets/setting_editors.dart';
import 'package:iris/features/windows/desktop_keyboard/view/keybind_editor_dialog.dart'
    show showKeybindEditorDialog;
import 'package:iris/hooks/ui/mappers/enum_localization.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/l10n/languages.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/models/store/title_overlay_config.dart';
import 'package:iris/models/store/video_display_mode.dart';
import 'package:iris/models/store/window_fit_mode.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/rule/vm_naming.dart'
    show VmNamingStrategy;
import 'package:iris/pages/player/control_bar/title_overlay_config_ialog.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/features/settings_transfer/view/export_dialog.dart'
    show showTransferExportDialog;
import 'package:iris/features/settings_transfer/view/import_dialog.dart'
    show showTransferImportDialog;
import 'package:iris/features/settings_transfer/view/transfer_audit_dialog.dart'
    show showTransferAuditDialog;
import 'package:iris/widgets/dialogs/open_breadcrumb_settings.dart'
    show openBreadcrumbSettings;
import 'package:iris/widgets/dialogs/show_message_dialog.dart';
import 'package:iris/utils/platform.dart' show isDesktop, isMobilePlatform;
import 'package:iris/widgets/dialogs/show_enum_radio_dialog.dart';
import 'package:iris/features/speed/model/enum/speed_gesture_mode.dart';
import 'package:iris/features/speed/model/enum/speed_rate_picker_mode.dart';
import 'package:iris/features/speed/model/speed_gesture_resolver.dart';
import 'package:iris/features/speed/model/speed_rate_picker_resolver.dart';
import 'package:iris/widgets/dialogs/show_unified_gesture_profile_dialog.dart';
import 'package:iris/widgets/dialogs/show_language_dialog.dart';
import 'package:iris/widgets/dialogs/show_legacy_compat_dialog.dart';
import 'package:iris/widgets/dialogs/show_orientation_dialog.dart';
import 'package:iris/widgets/dialogs/show_portrait_bar_align_dialog.dart';
import 'package:iris/widgets/adaptive/keyboard_form_shell.dart';
import 'package:iris/widgets/dialogs/show_slider_type_dialog.dart';
import 'package:iris/widgets/dialogs/warning_prefs_editor.dart'
    show showWarningDialogPrefsEditor;

part 'bindings/binding_kit.dart';
part 'bindings/background_playback_tiles.dart';
part 'bindings/virtual_media_tiles.dart';
part 'bindings/tag_play_tiles.dart';

/// Hand-written editor bindings — the bridge between metadata rows and the
/// proven legacy dialogs.
///
/// Each entry reproduces its legacy row verbatim: same leading icon, same
/// live-value subtitle, same dialog. Zero behavior drift is the contract;
/// the renderer only decides WHICH rows exist and where.
///
/// [EditorBindings.ensureRegistered] is idempotent and called from
/// SettingRow.build, so bindings work regardless of init order (no reliance
/// on module bootstrap).
abstract final class EditorBindings {
  static bool _registered = false;

  static void ensureRegistered() {
    if (_registered) return;
    _registered = true;
    SettingEditors.registerAll(<String, SettingEditorBuilder>{
      // ── Play · gestures & touch controls ──
      'screen_orientation': _tile(
        icon: Icons.screen_rotation_rounded,
        titleKey: 'screen_orientation',
        subtitle: (s, t) =>
            screenOrientationLabelsMap(t)[s.preferredOrientation] ??
            s.preferredOrientation.name,
        open: showOrientationDialog,
      ),
      'phone_landscape_slider_type': _tile(
        icon: Icons.line_style_rounded,
        titleKey: 'slider_type',
        subtitle: (s, t) {
          if (!s.phoneLandscapeUseMode.usesOneHandedControls) {
            return t.sld_mode_normal;
          }
          final String pos;
          if (isMobilePlatform) {
            final h = s.mobileSidePositionH == PhoneSidePositionH.center
                ? PhoneSidePositionH.right
                : s.mobileSidePositionH;
            pos = h == PhoneSidePositionH.left
                ? t.ed_side_pos_bl
                : t.ed_side_pos_br;
          } else {
            pos = t.ed_side_pos(
                switch (s.phoneSidePositionH) {
                  PhoneSidePositionH.left => t.ed_pos_left,
                  PhoneSidePositionH.center => t.ed_pos_center,
                  PhoneSidePositionH.right => t.ed_pos_right
                },
                switch (s.phoneSidePositionV) {
                  PhoneSidePositionV.top => t.ed_pos_top,
                  PhoneSidePositionV.middle => t.ed_pos_middle,
                  PhoneSidePositionV.bottom => t.ed_pos_bottom
                });
          }
          final String design =
              s.phoneOneHandedScrubberKind == PhoneSideScrubberKind.dial
                  ? t.sld_kind_dial
                  : t.sld_kind_circle;
          return t.ed_slider_sideway_summary(pos, design);
        },
        open: showSliderTypeDialog,
      ),
      // Phone-PORTRAIT bottom-bar alignment (MobileControlLayout): one tile,
      // two independent rows in the dialog. Subtitle summarises both groups.
      'portrait_bar_align': _tile(
        icon: Icons.align_horizontal_center_rounded,
        titleKey: 'set_portrait_bar_align',
        subtitle: (s, t) => t.set_portrait_bar_align_summary(
          _portraitAlignLabel(s.portraitPlaybackAlign, t),
          _portraitAlignLabel(s.portraitSubAudioAlign, t),
        ),
        open: showPortraitBarAlignDialog,
      ),
      'speed_gesture_mode': _tile(
        icon: Icons.speed_rounded,
        titleKey: 'speed_gesture_mode',
        subtitle: (s, t) {
          final mode = resolveSpeedGestureMode(s,
              metadataEnabled:
                  s.useMetadataSettings && MetaSettingsModule.ready);
          return mode == SpeedGestureMode.dualAxis
              ? t.ed_speed_dual
              : t.ed_speed_single;
        },
        open: _openSpeedGestureModeDialog,
      ),
      // Playback-speed picker shape (more menu / control-bar RATE): the
      // dual wheel, the slider, or the legacy flat list. Value lives in the
      // `speed.rateMode` AUX row.
      'speed_rate_mode': _tile(
        icon: Icons.tune_rounded,
        titleKey: 'speed_rate_mode',
        subtitle: (s, t) => switch (resolveSpeedRatePickerMode(
          s,
          metadataEnabled: s.useMetadataSettings && MetaSettingsModule.ready,
        )) {
          SpeedRatePickerMode.dualWheel => t.set_rate_mode_dual_wheel,
          SpeedRatePickerMode.slider => t.set_rate_mode_slider,
          SpeedRatePickerMode.list => t.set_rate_mode_list,
        },
        open: _openSpeedRateModeDialog,
      ),
      'gesture_unified': _tile(
        icon: Icons.touch_app_rounded,
        titleKey: 'gesture_profile',
        subtitle: (s, t) {
          if (!s.useMetadataSettings) return t.ed_gesture_legacy;
          final land =
              landscapeGestureProfileLabels(t)[s.landscapeGestureProfile] ??
                  s.landscapeGestureProfile.name;
          final isLegacy =
              s.landscapeGestureProfile == LandscapeGestureProfile.classic;
          return isLegacy ? t.ed_gesture_legacy : t.ed_gesture_region(land);
        },
        open: showUnifiedGestureProfileDialog,
      ),

      // ── Legacy 兼容（收拢弹窗）：主闸 + 双写策略 + 三个旧版运行时开关 ──
      'legacy_compat': _tile(
        icon: Icons.history_rounded,
        titleKey: 'legacy_compat',
        subtitle: (s, t) =>
            s.useMetadataSettings ? t.ed_mode_meta : t.ed_mode_legacy,
        open: showLegacyCompatDialog,
      ),

      // ── Play · startup resume (metadata-only `playback.` row) ──
      'resume_on_startup': _switchTile(
        icon: Icons.restart_alt_rounded,
        titleKey: 'resume_on_startup',
        subtitleKey: 'resume_on_startup_desc',
        valueOf: (s) => resolveResumeOnStartup(s,
            metadataEnabled: s.useMetadataSettings && MetaSettingsModule.ready),
        apply: (store, v) => store.updateResumeOnStartup(v),
      ),

      // ── Play · desktop drag-drop append/override split (`playback.` AUX) ──
      'drop_append_zone': _sliderTile(
        icon: Icons.vertical_split_rounded,
        titleKey: 'drop_append_zone_percent',
        subtitleKey: 'drop_append_zone_percent_desc',
        valueOf: (s) => s.dropAppendZonePercent,
        min: 10,
        max: 90,
        // 1% steps across the 10–90 range.
        divisions: 80,
        format: (v) => '${v.round()}%',
        apply: (store, v) => store.updateDropAppendZonePercent(v),
      ),

      // ── Play · media_kit demuxer cache preset (`playback.` AUX) ──
      // Radio dialog (stacked rows), not an inline slider: the value is a
      // small enum and phone width never has to fit a slider + value label.
      'playback_cache_preset': _tile(
        icon: Icons.sd_storage_rounded,
        titleKey: 'playback_cache_preset',
        subtitle: (s, t) => _videoCachePresetLabel(
            resolveVideoCachePreset(s,
                metadataEnabled:
                    s.useMetadataSettings && MetaSettingsModule.ready),
            t),
        open: _openVideoCachePresetDialog,
      ),

      // ── General ──
      'browse_media_scope': _tile(
        icon: Icons.video_library_outlined,
        titleKey: 'browse_media_scope',
        subtitle: (s, t) => _browseScopeLabel(
            resolveBrowseMediaScope(s,
                metadataEnabled:
                    s.useMetadataSettings && MetaSettingsModule.ready),
            t),
        open: _openBrowseScopeDialog,
      ),
      'language': _tile(
        icon: Icons.translate_rounded,
        titleKey: 'language',
        subtitle: (s, t) => s.language == 'system'
            ? t.system
            : languages[s.language] ?? s.language,
        open: showLanguageDialog,
      ),
      'settings_export': _tile(
        icon: Icons.upload_rounded,
        titleKey: 'export_label',
        subtitle: (_, t) => t.export_options,
        open: showTransferExportDialog,
      ),
      'settings_import': _tile(
        icon: Icons.download_rounded,
        titleKey: 'import_label',
        subtitle: (_, t) => t.import_options,
        open: showTransferImportDialog,
      ),
      'password_transfer_log': _tile(
        icon: Icons.security_rounded,
        titleKey: 'transfer_audit_log',
        subtitle: (_, t) => SettingTexts.subtitle('transfer_audit_log_desc', t),
        open: showTransferAuditDialog,
      ),
      'controls_title_settings': _titleOverlayEntry(
        icon: Icons.title,
        titleKey: 'controls_title_settings',
        subtitleOf: (t) => t.configure_controls_title,
        initialOf: (s) => s.controlsTitleConfig,
        confirm: (store, c) => store.updateControlsTitleConfig(c),
      ),
      'minimal_title_settings': _titleOverlayEntry(
        icon: Icons.text_fields,
        titleKey: 'minimal_title_settings',
        subtitleOf: (t) => t.configure_minimal_title,
        initialOf: (s) => s.minimalTitleConfig,
        confirm: (store, c) => store.updateMinimalTitleConfig(c),
      ),
      'breadcrumb_start_side': _tile(
        icon: Icons.sync_alt,
        titleKey: 'breadcrumb_start_side',
        subtitle: (_, t) => t.breadcrumb_start_side_desc,
        open: openBreadcrumbSettings,
      ),

      // ── General · advanced ──
      'warning_dialog_prefs': _tile(
        icon: Icons.warning_amber_rounded,
        titleKey: 'warning_dialog_prefs',
        open: showWarningDialogPrefsEditor,
      ),
      'scan_auto_close': _tile(
        icon: Icons.timer_outlined,
        titleKey: 'scan_auto_close',
        subtitle: (_, t) => SettingTexts.subtitle('scan_auto_close_desc', t),
        open: openScanAutoCloseSettings,
      ),
      'scan_rescan_reminder': _tile(
        icon: Icons.update,
        titleKey: 'scan_rescan_reminder',
        subtitle: (_, t) =>
            SettingTexts.subtitle('scan_rescan_reminder_desc', t),
        open: openScanRescanReminder,
      ),
      'app_identity_entries': _tile(
        icon: Icons.alternate_email_rounded,
        titleKey: 'identity_entries',
        subtitle: (_, t) => SettingTexts.subtitle('identity_entries_desc', t),
        open: showAppIdentityManager,
      ),
      'virtual_media_manager': _tile(
        icon: Icons.video_collection_outlined,
        titleKey: 'virtual_media',
        subtitle: (_, t) => SettingTexts.subtitle('virtual_media_desc', t),
        open: showVirtualMediaManager,
      ),
      'vm_mark_tick_color': _tile(
        icon: Icons.straight_rounded,
        titleKey: 'vm_mark_tick_color',
        subtitle: (s, _) =>
            '${vmTickColorLabel(s.vmMarkTickColor)} · ${vmTickExtentLabel(s.vmMarkTickExtent)}',
        open: showVmMarkColorDialog,
      ),
      'virtual_media_name_prefix': _tile(
        icon: Icons.drive_file_rename_outline_rounded,
        titleKey: 'vm_name_prefix',
        subtitle: (_, t) => SettingTexts.subtitle('vm_name_prefix_desc', t),
        open: _openVmNamePrefixDialog,
      ),
      // `virtualmedia.*` enum rows: values live in AUX rows (VmPrefs), not the
      // `app.` snapshot — custom async tiles route through the typed store.
      'vm_cross_drag_strategy': (context, def) =>
          _VmEnumTile<VmCrossSegmentDragStrategy>(
            icon: Icons.swipe_rounded,
            titleKey: 'virtual_media_cross_drag',
            subtitleKey: 'virtual_media_cross_drag_desc',
            defKey: 'virtualmedia.crossDragStrategy',
            values: const [
              VmCrossSegmentDragStrategy.previewOnRelease,
              VmCrossSegmentDragStrategy.directSwitch,
            ],
            nameOf: (v) => v.name,
            // Load/save through AppStore so the change applies live AND
            // persists to the row `applyVirtualMediaRows` actually reads
            // (`virtualmedia.crossDragStrategy`).
            load: () async => useAppStore().state.vmCrossSegmentDragStrategy,
            save: (v) => useAppStore().updateVmCrossSegmentDragStrategy(v),
          ),
      // B-scheme dual-time second-grid alignment (AUX row
      // `virtualmedia.dualTimeSync` via AppStore.updateVmDualTimeSync).
      'vm_dual_time_sync': (context, def) => _VmEnumTile<VmDualTimeSyncMode>(
            icon: Icons.timer_outlined,
            titleKey: 'vm_dual_time_sync',
            subtitleKey: 'vm_dual_time_sync_desc',
            defKey: 'virtualmedia.dualTimeSync',
            values: VmDualTimeSyncMode.values,
            nameOf: (v) => v.name,
            load: () async => useAppStore().state.vmDualTimeSync,
            save: (v) => useAppStore().updateVmDualTimeSync(v),
          ),
      // Dial-ring chunk indicator for single-segment virtual items (spec
      // §8): `virtualmedia.hideChunkWhenSingleSegment` via AppStore.
      'vm_hide_chunk_when_single_segment': _switchTile(
        icon: Icons.hide_source_rounded,
        titleKey: 'vm_hide_chunk_when_single_segment',
        subtitleKey: 'vm_hide_chunk_when_single_segment_desc',
        valueOf: (s) => s.vmHideChunkWhenSingleSegment,
        apply: (store, v) => store.updateVmHideChunkWhenSingleSegment(v),
      ),
      // Scenario-search multi-select hint for virtual merged media (AUX row
      // `virtualmedia.multiSelectHintHidden` via VmPrefs). The row reads
      // naturally: ON = keep showing the hint; turning it off permanently
      // suppresses it ("取消永关").
      'vm_multi_select_hint': (context, def) => _VmPrefsSwitchTile(
            icon: Icons.help_outline_rounded,
            titleKey: 'vm_multi_select_hint',
            subtitleKey: 'vm_multi_select_hint_desc',
            load: VmPrefs.multiSelectHintHidden,
            save: VmPrefs.setMultiSelectHintHidden,
          ),
      'vm_naming_strategy': (context, def) => _VmEnumTile<VmNamingStrategy>(
            icon: Icons.numbers_rounded,
            titleKey: 'vm_naming_strategy',
            subtitleKey: 'vm_naming_strategy_desc',
            defKey: 'virtualmedia.namingStrategy',
            values: VmNamingStrategy.values,
            nameOf: (v) => v.name,
            load: VmPrefs.namingStrategy,
            save: VmPrefs.setNamingStrategy,
          ),
      'vm_name_number_format': (context, def) => _VmEnumTile<String>(
            icon: Icons.pin_rounded,
            titleKey: 'vm_name_number_format',
            subtitleKey: 'vm_name_number_format_desc',
            defKey: 'virtualmedia.nameNumberFormat',
            values: const ['raw', 'pad2', 'pad3', 'pad4'],
            nameOf: (v) => v,
            load: VmPrefs.nameNumberFormat,
            save: VmPrefs.setNameNumberFormat,
          ),
      'screenshot_save_path_mobile': _tile(
        icon: Icons.save_alt_rounded,
        titleKey: 'screenshot_save_path',
        subtitle: (s, t) =>
            _screenshotDirSubtitle(s.screenshotMobileDir, isMobile: true, t: t),
        open: (ctx) => showScreenshotSavePathDialog(ctx, isMobile: true),
      ),
      'screenshot_save_path_desktop': _tile(
        icon: Icons.save_alt_rounded,
        titleKey: 'screenshot_save_path',
        subtitle: (s, t) => _screenshotDirSubtitle(s.screenshotDesktopDir,
            isMobile: false, t: t),
        open: (ctx) => showScreenshotSavePathDialog(ctx, isMobile: false),
      ),

      // ── Desktop keyboard OSD (PotPlayer-style, `osd.` AUX rows) ──
      'osd_enabled': _switchTile(
        icon: Icons.info_outline_rounded,
        titleKey: 'osd_enabled',
        subtitleKey: 'osd_enabled_desc',
        valueOf: (s) => s.osdEnabled,
        apply: (store, v) => store.updateOsdEnabled(v),
      ),
      'osd_visibility_mode': _tile(
        icon: Icons.visibility_outlined,
        titleKey: 'osd_visibility_mode',
        subtitle: (s, t) => _osdVisibilityLabel(s.osdVisibilityMode, t),
        open: _openOsdVisibilityModeDialog,
      ),
      'osd_h_align': _tile(
        icon: Icons.horizontal_distribute_rounded,
        titleKey: 'osd_h_align',
        subtitle: (s, t) => _osdHAlignLabel(s.osdHAlign, t),
        open: _openOsdHAlignDialog,
      ),
      'osd_v_align': _tile(
        icon: Icons.vertical_distribute_rounded,
        titleKey: 'osd_v_align',
        subtitle: (s, t) => _osdVAlignLabel(s.osdVAlign, t),
        open: _openOsdVAlignDialog,
      ),
      'osd_layout': _tile(
        icon: Icons.view_agenda_outlined,
        titleKey: 'osd_layout',
        subtitle: (s, t) => _osdLayoutLabel(s.osdLayout, t),
        open: _openOsdLayoutDialog,
      ),
      'osd_duration': _sliderTile(
        icon: Icons.timer_outlined,
        titleKey: 'osd_duration',
        subtitleKey: 'osd_duration_desc',
        valueOf: (s) => s.osdDurationMs.toDouble(),
        min: 800,
        max: 5000,
        divisions: 14,
        format: (v) => '${v.round()}ms',
        apply: (store, v) => store.updateOsdDurationMs(v.round()),
      ),

      'desktop_keybind_editor': _tile(
        icon: Icons.keyboard_rounded,
        titleKey: 'keybind_editor',
        subtitle: (_, t) => SettingTexts.subtitle('keybind_editor_desc', t),
        open: showKeybindEditorDialog,
      ),

      // ── Tag play: numeric input bar + hint banner (`tagplay.` AUX rows) ──
      'tagplay_input_bar': (context, def) => const _TagPlayInputBarTile(),
      'tagplay_input_hint': (context, def) => const _TagPlayHintTile(),
      'tagplay_view_stack': (context, def) => const _TagPlayViewStackTile(),

      // ── Play · window keep-in-bounds (meta-driven `window.` AUX bool) ──
      'keep_window_in_bounds': _switchTile(
        icon: Icons.fit_screen_rounded,
        titleKey: 'window_keep_in_bounds',
        subtitleKey: 'window_keep_in_bounds_desc',
        valueOf: (s) => s.keepWindowInBounds,
        apply: (store, v) => store.updateKeepWindowInBounds(v),
      ),

      // ── Play · desktop window/playlist rows (`window.` AUX enums) ──
      'window_fit_mode': _tile(
        icon: Icons.aspect_ratio_rounded,
        titleKey: 'window_fit_mode',
        subtitle: (s, t) =>
            SettingTexts.enumLabel('window.fitMode', s.windowFitMode.name, t),
        open: _openWindowFitModeDialog,
      ),
      'playlist_panel_mode': _tile(
        icon: Icons.playlist_play_rounded,
        titleKey: 'playlist_panel_mode',
        subtitle: (s, t) => SettingTexts.enumLabel(
            'window.playlistPanelMode', s.playlistPanelMode.name, t),
        open: _openPlaylistPanelModeDialog,
      ),
      'side_fullscreen_behavior': _tile(
        icon: Icons.fullscreen_rounded,
        titleKey: 'side_fullscreen_behavior',
        subtitle: (s, t) => SettingTexts.enumLabel(
            'window.sideFullscreenBehavior', s.sideFullscreenBehavior.name, t),
        open: _openSideFullscreenBehaviorDialog,
      ),
      'fullscreen_dock_edge_width': _sliderTile(
        icon: Icons.align_horizontal_right_rounded,
        titleKey: 'set_fs_edge_reveal_width',
        subtitleKey: 'set_fs_edge_reveal_width_desc',
        valueOf: (s) => s.fullscreenDockEdgeRevealPct,
        min: 0,
        max: 50,
        // 1% steps across the range.
        divisions: 50,
        format: (v) => '${v.round()}%',
        apply: (store, v) => store.updateFullscreenDockEdgeRevealPct(v),
      ),
      'side_panel_isolation': _sliderTile(
        icon: Icons.vertical_align_top_rounded,
        titleKey: 'set_fs_isolation_side',
        subtitleKey: 'set_fs_isolation_side_desc',
        valueOf: (s) => s.sidePanelIsolationPct,
        min: 0,
        max: 50,
        // 1% steps across the range.
        divisions: 50,
        format: (v) => '${v.round()}%',
        apply: (store, v) => store.updateSidePanelIsolationPct(v),
      ),
      'linear_bar_isolation': _sliderTile(
        icon: Icons.vertical_align_bottom_rounded,
        titleKey: 'set_fs_isolation_linear',
        subtitleKey: 'set_fs_isolation_linear_desc',
        valueOf: (s) => s.linearBarIsolationPct,
        min: 0,
        max: 100,
        // 1% steps across the range.
        divisions: 100,
        format: (v) => '${v.round()}%',
        apply: (store, v) => store.updateLinearBarIsolationPct(v),
      ),
      'playlist_popup_theme': _tile(
        icon: Icons.contrast_rounded,
        titleKey: 'playlist_popup_theme',
        subtitle: (s, t) => SettingTexts.enumLabel(
            'window.playlistPopupTheme', s.playlistPopupTheme.name, t),
        open: _openPlaylistPopupThemeDialog,
      ),
      'playlist_dock_theme': _tile(
        icon: Icons.contrast_rounded,
        titleKey: 'playlist_dock_theme',
        subtitle: (s, t) => SettingTexts.enumLabel(
            'window.playlistDockTheme', s.playlistDockTheme.name, t),
        open: _openPlaylistDockThemeDialog,
      ),
      'scenario_queue_layout': _tile(
        icon: Icons.view_agenda_outlined,
        titleKey: 'set_scenario_queue_layout',
        // Deliberately NOT the current value: which of the three stored layouts
        // applies depends on the screen shape, and this subtitle has no
        // BuildContext to resolve it. The dialog names the shape it edits.
        subtitle: (s, t) => t.set_scenario_queue_layout_scope,
        open: _openScenarioQueueLayoutDialog,
      ),

      // ── Play · video display mode (`video.` AUX enums, per-platform) ──
      'video_desktop_display_mode': _tile(
        icon: Icons.aspect_ratio_rounded,
        titleKey: 'video_display_mode',
        subtitle: (s, t) =>
            desktopVideoDisplayModeLabel(s.desktopDisplayMode, t),
        open: _openDesktopDisplayModeDialog,
      ),
      'video_mobile_display_mode': _tile(
        icon: Icons.aspect_ratio_rounded,
        titleKey: 'video_display_mode',
        subtitle: (s, t) => mobileVideoDisplayModeLabel(s.mobileDisplayMode, t),
        open: _openMobileDisplayModeDialog,
      ),

      // ── Play · 副音播放 rows (`background_playback.*`): values live in the
      //     background-playback store, never the `app.` snapshot ──
      'bg_sources': (context, def) => const _BgSourcesTile(),
      'bg_fallback_banner': (context, def) => const _BgFallbackBannerTile(),
      'bg_start_armed': _bgSwitchTile(
        icon: Icons.power_settings_new_rounded,
        titleKey: 'set_bg_start_armed',
        subtitleKey: 'set_bg_start_armed_desc',
        valueOf: (s) => s.startArmed,
        apply: (bg, v) => bg.setStartArmed(v),
      ),
      'bg_keep_warm': _bgSwitchTile(
        icon: Icons.play_circle_outline_rounded,
        titleKey: 'set_bg_keep_warm',
        subtitleKey: 'set_bg_keep_warm_desc',
        valueOf: (s) => s.keepWarmPlayer,
        apply: (bg, v) => bg.setKeepWarmPlayer(v),
        // Turning the preload off deserves an explanation before it lands.
        confirmOffTitleKey: 'set_bg_keep_warm',
        confirmOffBodyKey: 'set_bg_keep_warm_off_notice',
      ),
      'bg_use_saved_mapping': _bgSwitchTile(
        icon: Icons.timeline_rounded,
        titleKey: 'set_bg_use_saved_mapping',
        subtitleKey: 'set_bg_use_saved_mapping_desc',
        valueOf: (s) => s.mappingEnabled,
        apply: (bg, v) => bg.setMappingEnabled(v),
      ),
      'bg_align_default': _bgEnumTile<BgAlignDefault>(
        icon: Icons.tune_rounded,
        titleKey: 'set_bg_align_default',
        subtitleKey: 'set_bg_align_default_desc',
        defKey: 'background_playback.alignDefault',
        values: BgAlignDefault.values,
        valueOf: (s) => s.alignDefault,
        apply: (bg, v) => bg.setAlignDefault(v),
      ),
      'bg_ratio_explicit_save': _bgSwitchTile(
        icon: Icons.save_rounded,
        titleKey: 'set_bg_ratio_explicit_save',
        subtitleKey: 'set_bg_ratio_explicit_save_desc',
        valueOf: (s) => s.ratioExplicitSave,
        apply: (bg, v) => bg.setRatioExplicitSave(v),
      ),
      'bg_auto_focus_control': _bgSwitchTile(
        icon: Icons.center_focus_strong_rounded,
        titleKey: 'set_bg_auto_focus',
        subtitleKey: 'set_bg_auto_focus_desc',
        valueOf: (s) => s.autoFocusControl,
        apply: (bg, v) => bg.setAutoFocusControl(v),
      ),
      'bg_seek_link': _bgEnumTile<BgSeekLink>(
        icon: Icons.link_rounded,
        titleKey: 'set_bg_seek_link',
        subtitleKey: 'set_bg_seek_link_desc',
        defKey: 'background_playback.seekLink',
        values: BgSeekLink.values,
        valueOf: (s) => s.seekLink,
        apply: (bg, v) => bg.setSeekLink(v),
      ),
      'bg_lock_level': _bgEnumTile<BgLockLevel>(
        icon: Icons.sync_rounded,
        titleKey: 'set_bg_lock_level',
        subtitleKey: 'set_bg_lock_level_desc',
        defKey: 'background_playback.lockLevel',
        values: BgLockLevel.values,
        valueOf: (s) => s.lockLevel,
        apply: (bg, v) => bg.setLockLevel(v),
      ),
      'bg_gate_stop_behavior': _bgEnumTile<BgGateStopBehavior>(
        icon: Icons.power_settings_new_rounded,
        titleKey: 'set_bg_gate_stop_behavior',
        subtitleKey: 'set_bg_gate_stop_behavior_desc',
        defKey: 'background_playback.gateStopBehavior',
        values: BgGateStopBehavior.values,
        valueOf: (s) => s.gateStopBehavior,
        apply: (bg, v) => bg.setGateStopBehavior(v),
      ),
      'bg_step_mode': _bgEnumTile<BgStepMode>(
        icon: Icons.swap_horiz_rounded,
        titleKey: 'set_bg_step_mode',
        subtitleKey: 'set_bg_step_mode_desc',
        defKey: 'background_playback.stepMode',
        values: BgStepMode.values,
        valueOf: (s) => s.stepMode,
        apply: (bg, v) => bg.setStepMode(v),
      ),
      'bg_align_warn': _bgIntTile(
        icon: Icons.timer_outlined,
        titleKey: 'set_bg_align_warn',
        subtitleKey: 'set_bg_align_warn_desc',
        min: kMinAlignWarnRemainSec,
        max: kMaxAlignWarnRemainSec,
        valueOf: (s) => s.alignAutoPauseRemainSec,
        apply: (bg, v) => bg.setAlignAutoPauseRemainSec(v),
      ),
      'bg_exhausted_action': _bgEnumTile<BgExhaustedAction>(
        icon: Icons.skip_next_rounded,
        titleKey: 'set_bg_exhausted_action',
        subtitleKey: 'set_bg_exhausted_action_desc',
        defKey: 'background_playback.exhaustedAction',
        values: BgExhaustedAction.values,
        valueOf: (s) => s.bgExhaustedAction,
        apply: (bg, v) => bg.setBgExhaustedAction(v),
      ),
      'bg_queue_sync_mode': _bgEnumTile<BgQueueSyncMode>(
        icon: Icons.sync_alt_rounded,
        titleKey: 'set_bg_queue_sync_mode',
        subtitleKey: 'set_bg_queue_sync_mode_desc',
        defKey: 'background_playback.queueSyncMode',
        values: BgQueueSyncMode.values,
        valueOf: (s) => s.queueSyncMode,
        apply: (bg, v) => bg.setQueueSyncMode(v),
      ),
      'bg_align_ring': _bgEnumTile<AlignRingAssignment>(
        icon: Icons.album_rounded,
        titleKey: 'set_bg_align_ring',
        subtitleKey: 'set_bg_align_ring_desc',
        defKey: 'background_playback.alignRingAssignment',
        values: AlignRingAssignment.values,
        valueOf: (s) => s.alignRingAssignment,
        apply: (bg, v) => bg.setAlignRingAssignment(v),
      ),
      'bg_quick_bar': _bgSwitchTile(
        icon: Icons.view_column_rounded,
        titleKey: 'set_bg_quick_bar',
        subtitleKey: 'set_bg_quick_bar_desc',
        valueOf: (s) => s.quickBarEnabled,
        apply: (bg, v) => bg.setQuickBarEnabled(v),
      ),
      'bg_quick_bar_align': _bgEnumTile<BgQuickBarAlign>(
        icon: Icons.align_horizontal_right_rounded,
        titleKey: 'set_bg_quick_bar_align',
        subtitleKey: 'set_bg_quick_bar_align_desc',
        defKey: 'background_playback.quickBarAlign',
        values: BgQuickBarAlign.values,
        valueOf: (s) => s.quickBarAlign,
        apply: (bg, v) => bg.setQuickBarAlign(v),
      ),
      'bg_item_switch': _bgEnumTile<BgCrossAction>(
        icon: Icons.skip_next_rounded,
        titleKey: 'set_bg_item_switch',
        subtitleKey: 'set_bg_item_switch_desc',
        defKey: 'background_playback.itemSwitch',
        values: BgCrossAction.values,
        valueOf: (s) => s.bgItemSwitch,
        apply: (bg, v) => bg.setBgItemSwitch(v),
      ),
      'bg_segment_switch': _bgEnumTile<BgCrossAction>(
        icon: Icons.view_carousel_rounded,
        titleKey: 'set_bg_segment_switch',
        subtitleKey: 'set_bg_segment_switch_desc',
        defKey: 'background_playback.segmentSwitch',
        values: BgCrossAction.values,
        valueOf: (s) => s.bgSegmentSwitch,
        apply: (bg, v) => bg.setBgSegmentSwitch(v),
      ),
      'bg_vm_scope_mode': _bgEnumTile<BgVmScopeMode>(
        icon: Icons.select_all_rounded,
        titleKey: 'set_bg_vm_scope_mode',
        subtitleKey: 'set_bg_vm_scope_mode_desc',
        defKey: 'background_playback.vmScopeMode',
        values: BgVmScopeMode.values,
        valueOf: (s) => s.bgVmScopeMode,
        apply: (bg, v) => bg.setBgVmScopeMode(v),
      ),
      'bg_follow_fg_switch': _bgSwitchTile(
        icon: Icons.swap_horiz_rounded,
        titleKey: 'set_bg_follow_fg',
        subtitleKey: 'set_bg_follow_fg_desc',
        valueOf: (s) => s.bgFollowsFgSwitch,
        apply: (bg, v) => bg.setFollowFgSwitch(v),
      ),
      'bg_rate_lock': _bgSwitchTile(
        icon: Icons.speed_rounded,
        titleKey: 'set_bg_rate_lock',
        subtitleKey: 'set_bg_rate_lock_desc',
        valueOf: (s) => s.bgRateLock,
        apply: (bg, v) => bg.setRateLock(v),
      ),
      'bg_allow_same_file': _bgSwitchTile(
        icon: Icons.filter_alt_off_rounded,
        titleKey: 'set_bg_allow_same_file',
        subtitleKey: 'set_bg_allow_same_file_desc',
        valueOf: (s) => s.allowSameFgBgFile,
        apply: (bg, v) => bg.setAllowSameFgBgFile(v),
      ),
      'bg_video_layout': _bgEnumTile<BgVideoLayout>(
        icon: Icons.picture_in_picture_alt_rounded,
        titleKey: 'set_bg_video_layout',
        subtitleKey: 'set_bg_video_layout_desc',
        defKey: 'background_playback.videoLayout',
        values: BgVideoLayout.values,
        valueOf: (s) => s.bgVideoLayout,
        apply: (bg, v) => bg.setBgVideoLayout(v),
      ),
      'bg_min_segment_span': _bgIntTile(
        icon: Icons.straighten_rounded,
        titleKey: 'set_bg_min_segment_span',
        subtitleKey: 'set_bg_min_segment_span_desc',
        min: kMinMinSegmentSpanMs,
        max: kMaxMinSegmentSpanMs,
        valueOf: (s) => s.minSegmentSpanMs,
        apply: (bg, v) => bg.setMinSegmentSpanMs(v),
      ),
      'bg_p_align_keep_length': _bgSwitchTile(
        icon: Icons.swap_vert_rounded,
        titleKey: 'set_bg_p_align_keep_length',
        subtitleKey: 'set_bg_p_align_keep_length_desc',
        valueOf: (s) => s.pAlignKeepMaxLength,
        apply: (bg, v) => bg.setPAlignKeepMaxLength(v),
      ),
      'bg_sticky_consume': _bgEnumTile<BgStickyConsume>(
        icon: Icons.vertical_align_center_rounded,
        titleKey: 'set_bg_sticky_consume',
        subtitleKey: 'set_bg_sticky_consume_desc',
        defKey: 'background_playback.stickyConsume',
        values: BgStickyConsume.values,
        valueOf: (s) => s.stickyConsume,
        apply: (bg, v) => bg.setStickyConsume(v),
      ),
      'bg_fg_window_zoom': _bgDoubleTile(
        icon: Icons.zoom_out_map_rounded,
        titleKey: 'set_bg_fg_window_zoom',
        subtitleKey: 'set_bg_fg_window_zoom_desc',
        min: FgDisplayWindowMath.kMinZoom,
        max: FgDisplayWindowMath.kMaxZoom,
        valueOf: (s) => s.fgWindowZoom,
        apply: (bg, v) => bg.setFgWindowZoom(v),
      ),
      'bg_fg_window_push_bg': _bgSwitchTile(
        icon: Icons.push_pin_rounded,
        titleKey: 'set_bg_fg_window_push_bg',
        subtitleKey: 'set_bg_fg_window_push_bg_desc',
        valueOf: (s) => s.fgWindowPushBg,
        apply: (bg, v) => bg.setFgWindowPushBg(v),
      ),
      'bg_align_snap': _bgSwitchTile(
        icon: Icons.center_focus_strong_rounded,
        titleKey: 'set_bg_align_snap',
        subtitleKey: 'set_bg_align_snap_desc',
        valueOf: (s) => s.snapEnabled,
        apply: (bg, v) => bg.setSnapEnabled(v),
      ),
      'bg_align_snap_release_limit': _bgIntTile(
        icon: Icons.filter_list_rounded,
        titleKey: 'set_bg_align_snap_release_limit',
        subtitleKey: 'set_bg_align_snap_release_limit_desc',
        min: SegmentSnap.kMinReleaseLimit,
        max: SegmentSnap.kMaxReleaseLimit,
        suffix: '',
        valueOf: (s) => s.snapReleaseLimit,
        apply: (bg, v) => bg.setSnapReleaseLimit(v),
      ),
      'bg_segment_guide': (context, def) => ListTile(
            leading: const Icon(Icons.help_outline_rounded),
            title: Text(
              SettingTexts.title(
                  'set_bg_segment_guide', getLocalizations(context)),
            ),
            subtitle: Text(
              SettingTexts.subtitle(
                  'set_bg_segment_guide_desc', getLocalizations(context)),
            ),
            onTap: () => showBgSegmentGuideDialog(context),
          ),

      // Seek step moved to control bar (horizontal slider dialog at subtitle position).
      // Setting row removed; seekStepSeconds persists via store directly.
    });
  }

  // ── 副音播放 (background_playback.*) custom tiles ──

  /// Inline switch for a 副音 bool whose value lives in the background store.
  static SettingEditorBuilder _bgSwitchTile({
    required IconData icon,
    required String titleKey,
    String? subtitleKey,
    required bool Function(BackgroundPlaybackState s) valueOf,
    required Future<void> Function(BackgroundPlaybackStore bg, bool v) apply,
    String? confirmOffTitleKey,
    String? confirmOffBodyKey,
  }) {
    return (context, def) => _BgBoundSwitchTile(
          icon: icon,
          titleKey: titleKey,
          subtitleKey: subtitleKey,
          valueOf: valueOf,
          apply: apply,
          confirmOffTitleKey: confirmOffTitleKey,
          confirmOffBodyKey: confirmOffBodyKey,
        );
  }

  /// Integer row for a 副音 int (value lives in the background store) — tap
  /// opens a min..max slider dialog; commits through the store mutator.
  static SettingEditorBuilder _bgIntTile({
    required IconData icon,
    required String titleKey,
    String? subtitleKey,
    required int min,
    required int max,
    String suffix = ' s',
    required int Function(BackgroundPlaybackState s) valueOf,
    required Future<void> Function(BackgroundPlaybackStore bg, int v) apply,
  }) {
    return (context, def) => _BgBoundIntTile(
          icon: icon,
          titleKey: titleKey,
          subtitleKey: subtitleKey,
          min: min,
          max: max,
          suffix: suffix,
          valueOf: valueOf,
          apply: apply,
        );
  }

  /// Double row for a 副音 double (value lives in the background store) — tap
  /// opens a min..max slider dialog; commits through the store mutator.
  static SettingEditorBuilder _bgDoubleTile({
    required IconData icon,
    required String titleKey,
    String? subtitleKey,
    required double min,
    required double max,
    required double Function(BackgroundPlaybackState s) valueOf,
    required Future<void> Function(BackgroundPlaybackStore bg, double v) apply,
  }) {
    return (context, def) => _BgBoundDoubleTile(
          icon: icon,
          titleKey: titleKey,
          subtitleKey: subtitleKey,
          min: min,
          max: max,
          valueOf: valueOf,
          apply: apply,
        );
  }

  /// Enum row for a 副音 enum (values in the background store) — tap opens
  /// the shared radio dialog; labels come from SettingTexts.enumLabel.
  static SettingEditorBuilder _bgEnumTile<T extends Enum>({
    required IconData icon,
    required String titleKey,
    String? subtitleKey,
    required String defKey,
    required List<T> values,
    required T Function(BackgroundPlaybackState s) valueOf,
    required Future<void> Function(BackgroundPlaybackStore bg, T v) apply,
  }) {
    return (context, def) => _BgBoundEnumTile<T>(
          icon: icon,
          titleKey: titleKey,
          subtitleKey: subtitleKey,
          defKey: defKey,
          values: values,
          valueOf: valueOf,
          apply: apply,
        );
  }

  /// Row subtitle for the screenshot save-dir rows: the custom dir in
  /// human-readable form, or the platform default label when unset.
  static String _screenshotDirSubtitle(String stored,
      {required bool isMobile, required AppLocalizations t}) {
    final String defaultLabel =
        isMobile ? t.ed_shot_default_mobile : t.ed_shot_default_desktop;
    return displayScreenshotDir(
      stored,
      defaultLabel: defaultLabel,
      safFallbackLabel: t.shot_saf_dir_fallback,
    );
  }

  /// Rule-name prefix editor: single text field with a non-empty guard.
  /// Empty input is rejected with an explanatory dialog (never a SnackBar).
  /// Routes through the canonical keyboard shell instead of `AlertDialog`.
  static void _openVmNamePrefixDialog(BuildContext context) {
    final t = getLocalizations(context);
    unawaited(() async {
      final current = await VmPrefs.namePrefix();
      if (!context.mounted) return;
      final value = await showKeyboardTextPrompt(
        context: context,
        title: SettingTexts.title('vm_name_prefix', t),
        initialValue: current,
        label: SettingTexts.title('vm_name_prefix', t),
        helper: SettingTexts.subtitle('vm_name_prefix_desc', t),
        confirmLabel: t.save,
        cancelLabel: t.cancel,
      );
      if (value == null) return;
      if (value.isEmpty) {
        if (!context.mounted) return;
        await showDialog<void>(
          context: context,
          builder: (dialogCtx) {
            final t2 = getLocalizations(dialogCtx);
            return AlertDialog(
              title: Text(t2.editor_prefix_empty_title),
              content: Text(t2.editor_prefix_empty_body),
            );
          },
        );
        return;
      }
      await VmPrefs.setNamePrefix(value);
    }());
  }

  static void _openSpeedGestureModeDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    final current = resolveSpeedGestureMode(store.state,
        metadataEnabled:
            store.state.useMetadataSettings && MetaSettingsModule.ready);
    showEnumRadioDialog<SpeedGestureMode>(
      context: context,
      title: SettingTexts.title('speed_gesture_mode', t),
      values: SpeedGestureMode.values,
      currentValue: current,
      labelOf: (m) => SettingTexts.enumLabel('speed.gestureMode', m.name, t),
      onSelected: (m) => unawaited(store.updateSpeedGestureMode(m)),
    );
  }

  static void _openSpeedRateModeDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    final current = resolveSpeedRatePickerMode(store.state,
        metadataEnabled:
            store.state.useMetadataSettings && MetaSettingsModule.ready);
    showEnumRadioDialog<SpeedRatePickerMode>(
      context: context,
      title: SettingTexts.title('speed_rate_mode', t),
      // Platform-filtered: desktop is not offered the wheel.
      values: speedRatePickerChoices(),
      currentValue: current,
      labelOf: (m) => SettingTexts.enumLabel('speed.rateMode', m.name, t),
      onSelected: (m) => unawaited(store.updateSpeedRatePickerMode(m)),
    );
  }

  /// Browse-media-scope picker: shared radio dialog over the three scopes.
  /// Writes go through the typed store mutator (owns the `browse.` row).
  static void _openBrowseScopeDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<BrowseMediaScope>(
      context: context,
      title: SettingTexts.title('browse_media_scope', t),
      values: BrowseMediaScope.values,
      currentValue: store.state.browseMediaScope,
      labelOf: (scope) => _browseScopeLabel(scope, t),
      onSelected: (scope) => unawaited(store.updateBrowseMediaScope(scope)),
    );
  }

  /// Desktop window-fit / queue-panel / video-display enum pickers: each value
  /// lives on AppState but persists as a `window.`/`video.` AUX row (never the
  /// `app.` snapshot), so the generic enumPick renderer cannot drive them.
  static void _openWindowFitModeDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<WindowFitMode>(
      context: context,
      title: SettingTexts.title('window_fit_mode', t),
      values: WindowFitMode.values,
      currentValue: store.state.windowFitMode,
      labelOf: (m) => SettingTexts.enumLabel('window.fitMode', m.name, t),
      onSelected: (m) => unawaited(store.updateWindowFitMode(m)),
    );
  }

  static void _openPlaylistPanelModeDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<PlaylistPanelMode>(
      context: context,
      title: SettingTexts.title('playlist_panel_mode', t),
      values: PlaylistPanelMode.values,
      currentValue: store.state.playlistPanelMode,
      labelOf: (m) =>
          SettingTexts.enumLabel('window.playlistPanelMode', m.name, t),
      onSelected: (m) => unawaited(store.updatePlaylistPanelMode(m)),
    );
  }

  static void _openSideFullscreenBehaviorDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<SideFullscreenBehavior>(
      context: context,
      title: SettingTexts.title('side_fullscreen_behavior', t),
      values: SideFullscreenBehavior.values,
      currentValue: store.state.sideFullscreenBehavior,
      labelOf: (m) =>
          SettingTexts.enumLabel('window.sideFullscreenBehavior', m.name, t),
      onSelected: (m) => unawaited(store.updateSideFullscreenBehavior(m)),
    );
  }

  static void _openPlaylistPopupThemeDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<PlaylistPopupTheme>(
      context: context,
      title: SettingTexts.title('playlist_popup_theme', t),
      values: PlaylistPopupTheme.values,
      currentValue: store.state.playlistPopupTheme,
      labelOf: (m) =>
          SettingTexts.enumLabel('window.playlistPopupTheme', m.name, t),
      onSelected: (m) => unawaited(store.updatePlaylistPopupTheme(m)),
    );
  }

  static void _openPlaylistDockThemeDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<PlaylistDockTheme>(
      context: context,
      title: SettingTexts.title('playlist_dock_theme', t),
      values: PlaylistDockTheme.values,
      currentValue: store.state.playlistDockTheme,
      labelOf: (m) =>
          SettingTexts.enumLabel('window.playlistDockTheme', m.name, t),
      onSelected: (m) => unawaited(store.updatePlaylistDockTheme(m)),
    );
  }

  /// Edits the toolbar layout of the CURRENT screen shape only.
  ///
  /// The three shapes are stored separately, so the dialog has to say which one
  /// it is about — otherwise picking V2 on a phone looks like it did nothing,
  /// because the desktop is still on V1.
  static void _openScenarioQueueLayoutDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    final profile = scenarioQueueProfileOf(context, state: store.state);
    showEnumRadioDialog<ScenarioQueueLayout>(
      context: context,
      title: SettingTexts.title('set_scenario_queue_layout', t),
      subtitle: t.set_scenario_queue_layout_profile(
          _queueProfileLabel(profile, t)),
      values: ScenarioQueueLayout.values,
      currentValue: store.state.scenarioQueueLayoutFor(profile),
      labelOf: (m) =>
          SettingTexts.enumLabel('window.scenarioQueueLayout', m.name, t),
      onSelected: (m) =>
          unawaited(store.updateScenarioQueueLayout(profile, m)),
    );
  }

  /// Human name of a screen shape, for the settings dialog.
  static String _queueProfileLabel(ScenarioQueueProfile profile, AppLocalizations t) =>
      switch (profile) {
        ScenarioQueueProfile.desktop => t.scn_queue_profile_desktop,
        ScenarioQueueProfile.portrait => t.scn_queue_profile_portrait,
        ScenarioQueueProfile.landscape => t.scn_queue_profile_landscape,
      };

  static void _openDesktopDisplayModeDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<DesktopVideoDisplayMode>(
      context: context,
      title: SettingTexts.title('video_display_mode', t),
      values: DesktopVideoDisplayMode.values,
      currentValue: store.state.desktopDisplayMode,
      labelOf: (m) => desktopVideoDisplayModeLabel(m, t),
      onSelected: (m) => unawaited(store.updateDesktopDisplayMode(m)),
    );
  }

  static void _openMobileDisplayModeDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<MobileVideoDisplayMode>(
      context: context,
      title: SettingTexts.title('video_display_mode', t),
      values: MobileVideoDisplayMode.values,
      currentValue: store.state.mobileDisplayMode,
      labelOf: (m) => mobileVideoDisplayModeLabel(m, t),
      onSelected: (m) => unawaited(store.updateMobileDisplayMode(m)),
    );
  }

  static void _openOsdVisibilityModeDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<OsdVisibilityMode>(
      context: context,
      title: SettingTexts.title('osd_visibility_mode', t),
      values: OsdVisibilityMode.values,
      currentValue: store.state.osdVisibilityMode,
      labelOf: (v) => _osdVisibilityLabel(v, t),
      onSelected: (v) => unawaited(store.updateOsdVisibilityMode(v)),
    );
  }

  static void _openOsdHAlignDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<OsdHAlign>(
      context: context,
      title: SettingTexts.title('osd_h_align', t),
      values: OsdHAlign.values,
      currentValue: store.state.osdHAlign,
      labelOf: (v) => _osdHAlignLabel(v, t),
      onSelected: (v) => unawaited(store.updateOsdHAlign(v)),
    );
  }

  static void _openOsdVAlignDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<OsdVAlign>(
      context: context,
      title: SettingTexts.title('osd_v_align', t),
      values: OsdVAlign.values,
      currentValue: store.state.osdVAlign,
      labelOf: (v) => _osdVAlignLabel(v, t),
      onSelected: (v) => unawaited(store.updateOsdVAlign(v)),
    );
  }

  static void _openOsdLayoutDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<OsdLayout>(
      context: context,
      title: SettingTexts.title('osd_layout', t),
      values: OsdLayout.values,
      currentValue: store.state.osdLayout,
      labelOf: (v) => _osdLayoutLabel(v, t),
      onSelected: (v) => unawaited(store.updateOsdLayout(v)),
    );
  }

  static void _openVideoCachePresetDialog(BuildContext context) {
    final t = getLocalizations(context);
    final store = useAppStore();
    showEnumRadioDialog<VideoCachePreset>(
      context: context,
      title: SettingTexts.title('playback_cache_preset', t),
      values: VideoCachePreset.values,
      currentValue: resolveVideoCachePreset(
        store.state,
        metadataEnabled:
            store.state.useMetadataSettings && MetaSettingsModule.ready,
      ),
      labelOf: (v) => _videoCachePresetLabel(v, t),
      onSelected: (v) => unawaited(store.updateVideoCachePreset(v)),
    );
  }

  // Shared enum→label helpers: the row subtitle and its dialog must report the
  // SAME localized name (previously duplicated as inline switches).
  static String _browseScopeLabel(BrowseMediaScope scope, AppLocalizations t) =>
      switch (scope) {
        BrowseMediaScope.all => t.set_browse_scope_all,
        BrowseMediaScope.videoOnly => t.set_browse_scope_video,
        BrowseMediaScope.audioOnly => t.set_browse_scope_audio,
      };

  /// Align value → localized 左/中/右, shared by the row subtitle and its dialog
  /// so the two never disagree.
  static String _portraitAlignLabel(PortraitBarAlign v, AppLocalizations t) =>
      switch (v) {
        PortraitBarAlign.left => t.ed_pos_left,
        PortraitBarAlign.center => t.ed_pos_center,
        PortraitBarAlign.right => t.ed_pos_right,
      };

  static String _osdVisibilityLabel(OsdVisibilityMode v, AppLocalizations t) =>
      switch (v) {
        OsdVisibilityMode.always => t.ed_osd_always,
        OsdVisibilityMode.hideWhenControlVisible => t.ed_osd_hide,
      };

  static String _osdHAlignLabel(OsdHAlign v, AppLocalizations t) => switch (v) {
        OsdHAlign.left => t.ed_pos_left,
        OsdHAlign.center => t.ed_pos_center,
        OsdHAlign.right => t.ed_pos_right,
      };

  static String _osdVAlignLabel(OsdVAlign v, AppLocalizations t) => switch (v) {
        OsdVAlign.top => t.ed_pos_top,
        OsdVAlign.middle => t.ed_pos_middle,
        OsdVAlign.bottom => t.ed_pos_bottom,
      };

  static String _osdLayoutLabel(OsdLayout v, AppLocalizations t) => switch (v) {
        OsdLayout.singleLine => t.ed_osd_line_single,
        OsdLayout.twoLines => t.ed_osd_line_two,
      };

  static String _videoCachePresetLabel(
          VideoCachePreset v, AppLocalizations t) =>
      switch (v) {
        VideoCachePreset.low => t.set_cache_preset_low,
        VideoCachePreset.balanced => t.set_cache_preset_balanced,
        VideoCachePreset.high => t.set_cache_preset_high,
      };

  /// Builds a reactive tile whose subtitle recomputes from live state on
  /// every store change (the page selects the whole state object, so any
  /// mutation rebuilds rows → fresh subtitle without extra plumbing).
  static SettingEditorBuilder _tile({
    required IconData icon,
    required String titleKey,
    String Function(AppState state, AppLocalizations t)? subtitle,
    required void Function(BuildContext context) open,
  }) {
    return (context, def) => _BoundEditorTile(
          icon: icon,
          titleKey: titleKey,
          subtitleBuilder: subtitle,
          onOpen: open,
        );
  }

  /// Inline slider rows: value edits in place through the store updaters
  /// (each updater owns its clamp + persistence), no dialog hop.
  static SettingEditorBuilder _sliderTile({
    required IconData icon,
    required String titleKey,
    String? subtitleKey,
    required double Function(AppState s) valueOf,
    required double min,
    required double max,
    required int divisions,
    required String Function(double v) format,
    required Future<void> Function(AppStore store, double v) apply,
  }) {
    return (context, def) => _BoundSliderTile(
          icon: icon,
          titleKey: titleKey,
          subtitleKey: subtitleKey,
          valueOf: valueOf,
          min: min,
          max: max,
          divisions: divisions,
          format: format,
          apply: apply,
        );
  }

  /// Inline switch rows for AUX domains (`playback.` etc.) whose value does
  /// NOT live in the `app.` snapshot — the generic toggle renderer is
  /// hardwired to `app.` fields (see SettingRow._fieldOf), so out-of-domain
  /// booleans must route through the registry with their own store updaters.
  static SettingEditorBuilder _switchTile({
    required IconData icon,
    required String titleKey,
    String? subtitleKey,
    required bool Function(AppState s) valueOf,
    required Future<void> Function(AppStore store, bool v) apply,
  }) {
    return (context, def) => _BoundSwitchTile(
          icon: icon,
          titleKey: titleKey,
          subtitleKey: subtitleKey,
          valueOf: valueOf,
          apply: apply,
        );
  }

  /// Composite title-overlay config rows share one dialog with different
  /// initial configs and confirmation sinks.
  static SettingEditorBuilder _titleOverlayEntry({
    required IconData icon,
    required String titleKey,
    required String Function(AppLocalizations t) subtitleOf,
    required TitleOverlayConfig Function(AppState s) initialOf,
    required Future<void> Function(AppStore store, TitleOverlayConfig config)
        confirm,
  }) {
    return (context, def) => _BoundEditorTile(
          icon: icon,
          titleKey: titleKey,
          subtitleBuilder: (_, t) => subtitleOf(t),
          onOpen: (context) {
            final t = getLocalizations(context);
            final store = useAppStore();
            showTitleOverlayConfigDialog(
              context: context,
              title: SettingTexts.title(titleKey, t),
              initial: initialOf(store.state),
              onConfirmed: (c) => confirm(store, c),
            );
          },
        );
  }
}
