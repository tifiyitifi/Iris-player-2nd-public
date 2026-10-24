import 'package:iris/features/meta_settings/model/enum/settings_section.dart';
import 'package:iris/features/meta_settings/model/enum/setting_value_type.dart';
import 'package:iris/features/meta_settings/model/enum/setting_widget_kind.dart';
import 'package:iris/features/meta_settings/model/setting_def.dart';

/// Core-app settings contribution: mirrors the legacy Play + General panels.
///
/// Defaults MUST equal the corresponding `AppState` @Default values — the
/// bridge roundtrip test enforces this so gate-on materialization reproduces
/// legacy behavior exactly. Composite editors (title-overlay config,
/// breadcrumb sides) get ONE row keyed by their dialog, not per state field;
/// the state-field mapping lives exclusively in the state bridge.
///
/// Action rows (editor entries without a value) declare valueType json with
/// null default; the renderer routes them purely via editorKey.
///
/// LAYOUT (requirement #5): rows are grouped into semantic blocks with
/// distinct sortOrders; each block leader carries the groupHeaderKey. Order:
/// 播放与窗口 → 手势与触控 → 虚拟媒体 → 副音 → 桌面工具 (Play);
/// 外观语言 → 数据 → 标题与浏览 → 警告 → OSD → 扫描 → Advanced(legacy) (General).
abstract final class AppSettingsContribution {
  static const List<SettingDef> defs = <SettingDef>[
    // ════ Play ════

    // ── 播放与窗口 ──
    SettingDef(
      key: 'app.playerBackend',
      section: SettingsSection.play,
      valueType: SettingValueType.enumeration,
      defaultValue: 'mediaKit',
      enumValues: ['mediaKit', 'fvp'],
      widgetKind: SettingWidgetKind.enumPick,
      titleKey: 'player_backend',
      iconKey: 'player_backend',
      groupHeaderKey: 'group_playback',
      sortOrder: 10,
    ),
    SettingDef(
      key: 'app.autoResize',
      section: SettingsSection.play,
      valueType: SettingValueType.bool,
      defaultValue: 'false',
      widgetKind: SettingWidgetKind.toggle,
      titleKey: 'auto_resize',
      subtitleKey: 'auto_resize_desc',
      iconKey: 'auto_resize',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 12,
    ),
    // Desktop window-fit mode (窗口适应视频 / 固定窗口): higher priority than
    // the video display mode; runtime toggled by the control-bar button and
    // Ctrl+R. Legacy-mode users keep the `app.autoResize` checkbox instead —
    // this row is hidden with the whole `window.` prefix when gate OFF.
    SettingDef(
      key: 'window.fitMode',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'window_fit_mode',
      titleKey: 'window_fit_mode',
      subtitleKey: 'window_fit_mode_desc',
      iconKey: 'auto_resize',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 14,
    ),
    SettingDef(
      key: 'window.keepInBounds',
      section: SettingsSection.play,
      valueType: SettingValueType.bool,
      defaultValue: 'true', // == AppState @Default
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'keep_window_in_bounds',
      titleKey: 'window_keep_in_bounds',
      subtitleKey: 'window_keep_in_bounds_desc',
      iconKey: 'keep_in_bounds',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 16,
    ),
    SettingDef(
      key: 'window.playlistPanelMode',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'playlist_panel_mode',
      titleKey: 'playlist_panel_mode',
      subtitleKey: 'playlist_panel_mode_desc',
      iconKey: 'playlist',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 18,
    ),
    SettingDef(
      key: 'window.sideFullscreenBehavior',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'side_fullscreen_behavior',
      titleKey: 'side_fullscreen_behavior',
      subtitleKey: 'side_fullscreen_behavior_desc',
      iconKey: 'fullscreen',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 20,
    ),
    SettingDef(
      key: 'window.fullscreenDockEdgeRevealPct',
      section: SettingsSection.play,
      valueType: SettingValueType.double,
      defaultValue: '10.0', // == AppState @Default
      writable: true,
      clampMin: 0, // == clampFullscreenDockEdgePct hard bounds
      clampMax: 50,
      // custom + editorKey: out-of-domain rows must not use the generic
      // slider kind (see settings_domain_guard_test); the hand-written
      // `_sliderTile` binding below renders the same inline slider.
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'fullscreen_dock_edge_width',
      titleKey: 'set_fs_edge_reveal_width',
      subtitleKey: 'set_fs_edge_reveal_width_desc',
      iconKey: 'fullscreen',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 21,
    ),
    // Isolation-zone percentages for the picture-fullscreen queue summon strip.
    // Both control-bar shapes share one formula — isolation height = bar height
    // + pct% of the playback-area height — so these rows only adjust the
    // percentage (side-type panel vs normal long-strip bar). Windows-only.
    SettingDef(
      key: 'window.sidePanelIsolationPct',
      section: SettingsSection.play,
      valueType: SettingValueType.double,
      defaultValue: '5.0', // == AppState @Default
      writable: true,
      clampMin: 0, // == clampSidePanelIsolationPct hard bounds
      clampMax: 50,
      // custom + editorKey: out-of-domain rows must not use the generic
      // slider kind (see settings_domain_guard_test); the hand-written
      // `_sliderTile` binding below renders the same inline slider.
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'side_panel_isolation',
      titleKey: 'set_fs_isolation_side',
      subtitleKey: 'set_fs_isolation_side_desc',
      iconKey: 'fullscreen',
      platforms: ['windows'],
      sortOrder: 22,
    ),
    SettingDef(
      key: 'window.linearBarIsolationPct',
      section: SettingsSection.play,
      valueType: SettingValueType.double,
      defaultValue: '25.0', // == AppState @Default
      writable: true,
      clampMin: 0, // == clampLinearBarIsolationPct hard bounds
      clampMax: 100,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'linear_bar_isolation',
      titleKey: 'set_fs_isolation_linear',
      subtitleKey: 'set_fs_isolation_linear_desc',
      iconKey: 'fullscreen',
      platforms: ['windows'],
      sortOrder: 23,
    ),
    SettingDef(
      key: 'window.playlistPopupTheme',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'playlist_popup_theme',
      titleKey: 'playlist_popup_theme',
      subtitleKey: 'playlist_popup_theme_desc',
      iconKey: 'theme_mode',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 24,
    ),
    SettingDef(
      key: 'window.playlistDockTheme',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'playlist_dock_theme',
      titleKey: 'playlist_dock_theme',
      subtitleKey: 'playlist_dock_theme_desc',
      iconKey: 'theme_mode',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 25,
    ),
    // Video display mode (metadata era): per-platform enums persisted as
    // `video.` AUX rows. Gate-OFF keeps the legacy `fit` cycle — rows hidden
    // via DefVisibility('video.'). The fit control-bar button is the runtime
    // toggle; these rows expose the same choice in the settings panel.
    SettingDef(
      key: 'video.desktopDisplayMode',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'video_desktop_display_mode',
      titleKey: 'video_display_mode',
      subtitleKey: 'video_display_mode_desc',
      iconKey: 'video_zoom',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 26,
    ),
    SettingDef(
      key: 'video.mobileDisplayMode',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'video_mobile_display_mode',
      titleKey: 'video_display_mode',
      subtitleKey: 'video_display_mode_desc',
      iconKey: 'video_zoom',
      platforms: ['android'],
      sortOrder: 27,
    ),
    // Play-queue toolbar layout (scenario playback). Cross-platform: the queue
    // exists on desktop and phone, and the compact single-row bar is the only
    // one that fits a narrow phone. The queue's own trailing toggle is the
    // runtime control; this row exposes the same choice here.
    //
    // The Def key is the LEGACY single-value row, not the live storage. The
    // value itself is remembered PER SCREEN SHAPE and written to
    // `window.scenarioQueueLayout{Desktop,Portrait,Landscape}`; this row is read
    // once at load purely as a migration seed for profiles that have no row of
    // their own (`applyWindowRows`). The custom editor bypasses the row and
    // writes the three per-profile rows directly, so nothing writes this one
    // after the split — it is retained as the settings SECTION's identity (title,
    // icon, sort order, cross-platform visibility) so the tile keeps rendering.
    SettingDef(
      key: 'window.scenarioQueueLayout',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'scenario_queue_layout',
      titleKey: 'set_scenario_queue_layout',
      subtitleKey: 'set_scenario_queue_layout_desc',
      iconKey: 'playlist',
      sortOrder: 29,
    ),

    // ── 播放行为 ──
    SettingDef(
      key: 'app.alwaysPlayFromBeginning',
      section: SettingsSection.play,
      valueType: SettingValueType.bool,
      defaultValue: 'false',
      widgetKind: SettingWidgetKind.toggle,
      titleKey: 'always_play_from_beginning',
      subtitleKey: 'always_play_from_beginning_description',
      iconKey: 'always_play_from_beginning',
      sortOrder: 30,
    ),
    // Metadata-mode-only knob (startup-resume contract): the AppState field
    // is JsonKey-excluded and its ONLY persistence route is the dedicated
    // `playback.` Drift row. The plain toggle renderer is hardwired to the
    // `app.` domain, so this row ships as a custom switch editor instead.
    // Gate-OFF runs resolve to `true` via resolveResumeOnStartup, and the
    // row is hidden by DefVisibility whenever the feature is unavailable.
    SettingDef(
      key: 'playback.resumeOnStartup',
      section: SettingsSection.play,
      valueType: SettingValueType.bool,
      defaultValue: 'true',
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'resume_on_startup',
      titleKey: 'resume_on_startup',
      subtitleKey: 'resume_on_startup_desc',
      iconKey: 'resume_on_startup',
      sortOrder: 32,
    ),
    // Desktop drag-drop split: the top share of the player height APPENDS to
    // the queue, the rest OVERRIDES and plays. Metadata-only `playback.` AUX
    // row (JsonKey-excluded AppState field); hidden whenever the drop feature
    // is unavailable (legacy / metadata off) via DefVisibility.
    SettingDef(
      key: 'playback.dropAppendPercent',
      section: SettingsSection.play,
      valueType: SettingValueType.double,
      clampMin: 10,
      clampMax: 90,
      defaultValue: '30.0',
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'drop_append_zone',
      titleKey: 'drop_append_zone_percent',
      subtitleKey: 'drop_append_zone_percent_desc',
      iconKey: 'drop_append_zone_percent',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 33,
    ),
    SettingDef(
      key: 'app.showControlsOnPlayToPause',
      section: SettingsSection.play,
      valueType: SettingValueType.bool,
      defaultValue: 'false',
      widgetKind: SettingWidgetKind.toggle,
      titleKey: 'show_controls_on_play_to_pause',
      subtitleKey: 'show_controls_on_play_to_pause_description',
      iconKey: 'show_controls_on_play_to_pause',
      // Legacy panel gates this row behind isMobilePlatform; android-only in
      // practice (no iOS target ships) — same rationale as popup_direction.
      platforms: ['android'],
      sortOrder: 34,
    ),
    // media_kit (mpv) demuxer cache sizing preset. Metadata-only `playback.`
    // AUX row (JsonKey-excluded AppState field), so it renders as a custom
    // radio-dialog tile — the generic renderer only drives `app.` fields.
    // Hidden whenever the media_kit backend is not active (DefVisibility):
    // the preset only steers mpv, never fvp.
    SettingDef(
      key: 'playback.videoCachePreset',
      section: SettingsSection.play,
      valueType: SettingValueType.enumeration,
      defaultValue: 'balanced',
      enumValues: ['low', 'balanced', 'high'],
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'playback_cache_preset',
      titleKey: 'playback_cache_preset',
      subtitleKey: 'playback_cache_preset_desc',
      iconKey: 'playback_cache_preset',
      sortOrder: 35,
    ),
    // Tail-step policy: what a FORWARD step press does once its target reaches
    // the media tail — finish the item (advance to the next queue entry) or keep
    // stepping. Metadata-only `playback.` AUX row (JsonKey-excluded AppState
    // field), so it renders as a custom radio-dialog tile. Backend-neutral: both
    // player hooks apply it (see `decideStepTail`), hence no backend visibility
    // gate beyond the shared `playback.` prefix.
    SettingDef(
      key: 'playback.stepTailFinish',
      section: SettingsSection.play,
      valueType: SettingValueType.enumeration,
      defaultValue: 'strict',
      enumValues: ['strict', 'window'],
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'playback_step_tail_finish',
      titleKey: 'step_tail_finish',
      subtitleKey: 'step_tail_finish_desc',
      iconKey: 'playback_step_tail_finish',
      sortOrder: 36,
    ),
    // ── 手机滑动与手势 ──
    SettingDef(
      key: 'app.phoneLandscapeSliderType',
      section: SettingsSection.play,
      valueType: SettingValueType.enumeration,
      // Mirrors the AppState @Default (parity-guarded): `circleRight`, so a
      // fresh install is a self-consistent pair with the `rightSide` use mode
      // below. The store folds the two together, so a stored value that
      // disagrees is repaired on load.
      defaultValue: 'circleRight',
      enumValues: ['normal', 'circleRight', 'circleLeft'],
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'phone_landscape_slider_type',
      // "Slider type" — merged tile: the former one-handed-design row lives
      // inside this dialog (design switch + panel anchor). The stored enum
      // keeps dual-writing the legacy runtime placement fields.
      titleKey: 'slider_type',
      subtitleKey: 'slider_type_desc',
      iconKey: 'slider_type',
      groupHeaderKey: 'group_gestures',
      platforms: ['android', 'windows', 'linux', 'macos'],
      sortOrder: 40,
    ),
    // Phone-PORTRAIT bottom-bar alignment of the two groups (MobileControlLayout).
    // PORTRAIT-only and Android-only: the one-handed side panel's block position
    // is the `slider.barPos` knob inside the slider-type dialog, and the
    // standalone desktop 副音 row follows `background_playback.quickBarAlign`.
    // One composite tile opens a two-row dialog (playback group / 副音 group);
    // `defaultValue` mirrors the AppState @Default (center) for the parity guard.
    SettingDef(
      key: 'app.portraitPlaybackAlign',
      section: SettingsSection.play,
      valueType: SettingValueType.enumeration,
      defaultValue: 'center',
      enumValues: ['left', 'center', 'right'],
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'portrait_bar_align',
      titleKey: 'set_portrait_bar_align',
      subtitleKey: 'set_portrait_bar_align_desc',
      platforms: ['android'],
      sortOrder: 44,
    ),
    // Unified side-panel composite now hosts dial-ring + circle tuning + center
    // action inline (see show_slider_type_dialog.dart). The former standalone
    // `dialring.compositeEntry` and `circleSliderCenterAction` rows are retired
    // from the contribution list; their storage (`dialring.*` AUX and
    // `app.circleSliderCenterAction`) remains and is edited inside the unified
    // dialog's per-kind lower section.
    SettingDef(
      key: 'app.preferredOrientation',
      section: SettingsSection.play,
      valueType: SettingValueType.enumeration,
      defaultValue: 'device',
      enumValues: ['device', 'landscape', 'portrait'],
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'screen_orientation',
      titleKey: 'screen_orientation',
      subtitleKey: 'screen_orientation_desc',
      iconKey: 'screen_orientation',
      platforms: ['android'],
      sortOrder: 48,
    ),
    SettingDef(
      key: 'app.reuseLastOrientation',
      section: SettingsSection.play,
      valueType: SettingValueType.bool,
      defaultValue: 'false',
      widgetKind: SettingWidgetKind.toggle,
      titleKey: 'reuse_last_orientation',
      iconKey: 'reuse_last_orientation',
      platforms: ['android'],
      sortOrder: 50,
    ),
    // Action rows: entries, not value holders.
    SettingDef(
      key: 'gesture.unifiedEntry',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'gesture_unified',
      titleKey: 'gesture_profile',
      subtitleKey: 'gesture_profile_desc',
      iconKey: 'gesture_profile',
      platforms: ['android'],
      sortOrder: 52,
    ),

    // ── 桌面键盘、控制栏与截图 ──
    SettingDef(
      key: 'app.keyboardShortcutScheme',
      section: SettingsSection.play,
      valueType: SettingValueType.enumeration,
      defaultValue: 'potplayer', // == AppState @Default; parity test locks it
      enumValues: ['legacy', 'potplayer'],
      widgetKind: SettingWidgetKind.enumPick,
      titleKey: 'keyboard_shortcut_scheme',
      subtitleKey: 'keyboard_shortcut_scheme_desc',
      iconKey: 'keyboard_shortcut_scheme',
      // Keyboard-first feature; the legacy hook still runs on every desktop
      // platform, so the row follows the same windows/linux/macos set as
      // autoResize rather than windows alone.
      groupHeaderKey: 'group_desktop_tools',
      platforms: ['windows', 'linux', 'macos'],
      // 100 keeps the desktop-tools block AFTER the whole background_playback
      // group (which runs 68..97): the bg cross-video/progress tail must not
      // land under this header or it renders as "desktop tools" on phones.
      sortOrder: 100,
    ),
    SettingDef(
      key: 'app.desktopControlBarLayout',
      section: SettingsSection.play,
      valueType: SettingValueType.enumeration,
      defaultValue: 'stacked', // == AppState @Default; parity test locks it
      enumValues: ['singleLine', 'stacked'],
      widgetKind: SettingWidgetKind.enumPick,
      titleKey: 'desktop_control_bar_layout',
      subtitleKey: 'desktop_control_bar_layout_desc',
      iconKey: 'desktop_control_bar_layout',
      // The desktop bar code path runs on every desktop platform (CI also
      // ships Linux builds) — same set as keyboardShortcutScheme.
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 101,
    ),
    SettingDef(
      key: 'keybind.editorEntry',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'desktop_keybind_editor',
      titleKey: 'keybind_editor',
      subtitleKey: 'keybind_editor_desc',
      iconKey: 'keybind_editor',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 102,
    ),
    // Desktop hover policy: what a PASSIVE mouse move reveals. Explicit shows
    // (startup / click / keyboard / wheel) always reveal the full bar — these
    // two rows only gate the hover path. Runtime reads go through
    // `shouldRequireClickToShowPanel` / `desktopHoverRevealsTitle`, which
    // ignore the stored bits while the metadata gate is OFF.
    SettingDef(
      key: 'app.desktopHoverShowTitle',
      section: SettingsSection.play,
      valueType: SettingValueType.bool,
      defaultValue: 'true', // == AppState @Default; parity test locks it
      widgetKind: SettingWidgetKind.toggle,
      titleKey: 'desktop_hover_show_title',
      subtitleKey: 'desktop_hover_show_title_desc',
      iconKey: 'desktop_hover_show_title',
      groupHeaderKey: 'group_desktop_hover',
      platforms: ['windows', 'linux', 'macos'],
      // 103/104 are the screenshot rows; keep this a unique section order.
      sortOrder: 105,
    ),
    SettingDef(
      key: 'app.desktopHoverShowControlBar',
      section: SettingsSection.play,
      valueType: SettingValueType.bool,
      defaultValue: 'false', // == AppState @Default; parity test locks it
      widgetKind: SettingWidgetKind.toggle,
      titleKey: 'desktop_hover_show_control_bar',
      subtitleKey: 'desktop_hover_show_control_bar_desc',
      iconKey: 'desktop_hover_show_control_bar',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 106,
    ),
    // ── Center tap zones (circle slider / ring dial) ──
    // The inner hit circle splits into four sectors by a faint 45° X. Phones
    // default the inward sector to the bottom control-group switch; desktop
    // keeps the legacy all-toggleControls center until the phone-mode opt-in
    // below. The four zone rows are hidden on desktop while that opt-in is off
    // (DefVisibility in app_startup).
    SettingDef(
      key: 'app.centerZoneInwardAction',
      section: SettingsSection.play,
      valueType: SettingValueType.enumeration,
      defaultValue: 'switchControlGroup', // == AppState @Default
      enumValues: [
        'none',
        'toggleControls',
        'togglePlayPause',
        'switchControlGroup',
      ],
      widgetKind: SettingWidgetKind.enumPick,
      titleKey: 'center_zone_inward',
      iconKey: 'center_zone_inward',
      groupHeaderKey: 'group_center_zone',
      sortOrder: 107,
    ),
    SettingDef(
      key: 'app.desktopCenterZonePhoneMode',
      section: SettingsSection.play,
      valueType: SettingValueType.bool,
      defaultValue: 'false', // == AppState @Default
      widgetKind: SettingWidgetKind.toggle,
      titleKey: 'desktop_center_zone_phone_mode',
      subtitleKey: 'desktop_center_zone_phone_mode_desc',
      iconKey: 'desktop_center_zone_phone_mode',
      platforms: ['windows', 'linux', 'macos'],
      sortOrder: 108,
    ),
    SettingDef(
      key: 'app.centerZoneOutwardAction',
      section: SettingsSection.play,
      valueType: SettingValueType.enumeration,
      defaultValue: 'toggleControls', // == AppState @Default
      enumValues: [
        'none',
        'toggleControls',
        'togglePlayPause',
        'switchControlGroup',
      ],
      widgetKind: SettingWidgetKind.enumPick,
      titleKey: 'center_zone_outward',
      iconKey: 'center_zone_outward',
      sortOrder: 109,
    ),
    SettingDef(
      key: 'app.centerZoneTopAction',
      section: SettingsSection.play,
      valueType: SettingValueType.enumeration,
      defaultValue: 'toggleControls', // == AppState @Default
      enumValues: [
        'none',
        'toggleControls',
        'togglePlayPause',
        'switchControlGroup',
      ],
      widgetKind: SettingWidgetKind.enumPick,
      titleKey: 'center_zone_top',
      iconKey: 'center_zone_top',
      sortOrder: 110,
    ),
    SettingDef(
      key: 'app.centerZoneBottomAction',
      section: SettingsSection.play,
      valueType: SettingValueType.enumeration,
      defaultValue: 'toggleControls', // == AppState @Default
      enumValues: [
        'none',
        'toggleControls',
        'togglePlayPause',
        'switchControlGroup',
      ],
      widgetKind: SettingWidgetKind.enumPick,
      titleKey: 'center_zone_bottom',
      iconKey: 'center_zone_bottom',
      sortOrder: 111,
    ),

    // ════ General ════

    // ── 外观与语言 ──
    SettingDef(
      key: 'app.language',
      section: SettingsSection.general,
      valueType: SettingValueType.string,
      defaultValue: 'system',
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'language',
      titleKey: 'language',
      iconKey: 'language',
      groupHeaderKey: 'group_appearance',
      sortOrder: 10,
    ),
    SettingDef(
      key: 'app.themeMode',
      section: SettingsSection.general,
      valueType: SettingValueType.enumeration,
      defaultValue: 'system',
      enumValues: ['system', 'light', 'dark'],
      widgetKind: SettingWidgetKind.enumPick,
      titleKey: 'theme_mode',
      iconKey: 'theme_mode',
      sortOrder: 12,
    ),
    // Metadata-mode-only knob (ring-dial contract): the AppState field is
    // JsonKey-excluded and its ONLY persistence route is the dedicated
    // `browse.mediaScope` Drift row. Legacy-mode runs resolve to `all` via
    // resolveBrowseMediaScope, so nothing is filtered and this row is hidden
    // by DefVisibility whenever the feature is unavailable.
    SettingDef(
      key: 'browse.mediaScope',
      section: SettingsSection.general,
      valueType: SettingValueType.enumeration,
      defaultValue: 'all', // == AppState @Default
      enumValues: ['all', 'videoOnly', 'audioOnly'],
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'browse_media_scope',
      titleKey: 'browse_media_scope',
      subtitleKey: 'browse_media_scope_desc',
      iconKey: 'browse_media_scope',
      sortOrder: 14,
    ),

    // ── 数据 ──
    // Transfer entries are deliberately platform-unrestricted: the v2 engine
    // is cross-platform (file_picker + pure-Dart crypto) and cross-platform
    // imports keep common + target-platform keys (PlatformKeyPolicy).
    SettingDef(
      key: 'data.exportEntry',
      section: SettingsSection.general,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'settings_export',
      titleKey: 'export_label',
      groupHeaderKey: 'group_data',
      sortOrder: 20,
    ),
    SettingDef(
      key: 'data.importEntry',
      section: SettingsSection.general,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'settings_import',
      titleKey: 'import_label',
      sortOrder: 22,
    ),

    // ── 标题与浏览 ──
    SettingDef(
      key: 'app.controlsTitleConfig',
      section: SettingsSection.general,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'controls_title_settings',
      titleKey: 'controls_title_settings',
      subtitleKey: 'controls_title_settings_desc',
      iconKey: 'controls_title_settings',
      groupHeaderKey: 'group_titles',
      platforms: ['android'],
      sortOrder: 30,
    ),
    SettingDef(
      key: 'app.minimalTitleConfig',
      section: SettingsSection.general,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'minimal_title_settings',
      titleKey: 'minimal_title_settings',
      subtitleKey: 'minimal_title_settings_desc',
      iconKey: 'minimal_title_settings',
      platforms: ['android'],
      sortOrder: 32,
    ),
    SettingDef(
      key: 'app.defaultPopupDirection',
      section: SettingsSection.general,
      valueType: SettingValueType.enumeration,
      defaultValue: 'right',
      enumValues: ['left', 'right'],
      widgetKind: SettingWidgetKind.enumPick,
      titleKey: 'popup_direction',
      iconKey: 'popup_direction',
      // Legacy panel gated this row behind isMobilePlatform; android-only in
      // practice (no iOS target ships). Parity test locks this.
      platforms: ['android'],
      sortOrder: 34,
    ),
    SettingDef(
      key: 'breadcrumb.startSides',
      section: SettingsSection.general,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'breadcrumb_start_side',
      titleKey: 'breadcrumb_start_side',
      subtitleKey: 'breadcrumb_start_side_desc',
      iconKey: 'breadcrumb_start_side',
      platforms: ['android'],
      sortOrder: 36,
    ),

    // ── 警告 ──
    // Action row: entries, not value holders. Suppressed ids live on
    // AppState.suppressedWarnings; this row only opens the editor panel.
    SettingDef(
      key: 'warnings.editorEntry',
      section: SettingsSection.general,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'warning_dialog_prefs',
      titleKey: 'warning_dialog_prefs',
      subtitleKey: 'warning_dialog_prefs_desc',
      iconKey: 'warning_dialog_prefs',
      groupHeaderKey: 'group_warnings',
      sortOrder: 40,
    ),

    // ── WebDAV 通配解析策略 ──
    // app.-domain enumPick so the generic renderer + SettingsEngine enum
    // whitelist apply (no custom editor needed). Default mirrors the
    // AppState @Default (`discovery`); the `legacyScan` value keeps the
    // original serial isolate scan reachable.
    SettingDef(
      key: 'app.webDavScanMode',
      section: SettingsSection.general,
      valueType: SettingValueType.enumeration,
      defaultValue: 'discovery', // == AppState @Default; parity test locks it
      enumValues: ['discovery', 'legacyScan'],
      widgetKind: SettingWidgetKind.enumPick,
      titleKey: 'webdav_scan_mode',
      subtitleKey: 'webdav_scan_mode_desc',
      // Network/data resolution strategy — grouped with the Data block, not
      // the media-library scan preferences (`scan.*`).
      sortOrder: 28,
    ),

    // ── Advanced · Legacy 兼容（收拢弹窗）──
    //
    // The five former standalone rows (useClassicTitleBar / useLegacyControl
    // Bar / useLegacyStoragePersistence / syncLegacyBlob / useMetadataSettings)
    // consolidated into ONE tile: the master gate IS the legacy-compat
    // switch, so it leads the dialog; persistence behavior unchanged (the
    // dialog routes through the same store updaters). See show_legacy_compat_dialog.
    SettingDef(
      key: 'legacy.compatEntry',
      section: SettingsSection.general,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'legacy_compat',
      titleKey: 'legacy_compat',
      subtitleKey: 'legacy_compat_desc',
      iconKey: 'legacy_compat',
      groupHeaderKey: 'group_advanced',
      sortOrder: 200,
    ),
  ];
}
