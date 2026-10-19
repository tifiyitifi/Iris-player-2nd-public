import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/meta_settings/contributions/settings_catalog.dart';
import 'package:iris/features/meta_settings/model/enum/setting_value_type.dart';
import 'package:iris/features/meta_settings/model/setting_def.dart';
import 'package:iris/features/meta_settings/view/setting_texts.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';

/// Parity locks between the metadata catalog and the legacy hand-written
/// panels. If one of these fails, the meta page and the legacy panels have
/// drifted — fix the CONTRIBUTION, not the test.
void main() {
  final defs = SettingsCatalog.defs;
  bool visible(SettingDef d, String platform) =>
      d.platforms.isEmpty || d.platforms.contains(platform);

  List<String> keys(String sectionName, String platform) => defs
      .where((d) => d.section.name == sectionName && visible(d, platform))
      .map((d) => d.key)
      .toList();

  group('row parity vs legacy panels', () {
    test('Play tab on desktop (windows)', () {
      expect(keys('play', 'windows'), [
        'app.playerBackend',
        'app.autoResize',
        'window.fitMode',
        'window.keepInBounds',
        'window.playlistPanelMode',
        'window.sideFullscreenBehavior',
        // Picture-fullscreen edge hover-strip width, as a percentage of the
        // playback area (slider, sortOrder 21).
        'window.fullscreenDockEdgeRevealPct',
        // Control-bar isolation-zone percentages for the same strip
        // (Windows-only sliders): side-type panel and normal long-strip bar.
        'window.sidePanelIsolationPct',
        'window.linearBarIsolationPct',
        'window.playlistPopupTheme',
        'window.playlistDockTheme',
        'video.desktopDisplayMode',
        // Play-queue toolbar layout (cross-platform; the queue's own trailing
        // toggle is the runtime control).
        'window.scenarioQueueLayout',
        'app.alwaysPlayFromBeginning',
        // Auto-resume last media on app start (metadata-only AUX row,
        // hidden via DefVisibility under gate OFF).
        'playback.resumeOnStartup',
        // Desktop drag-drop append/override split (metadata-only `playback.`
        // AUX row, desktop platforms, hidden when the drop feature is absent).
        'playback.dropAppendPercent',
        // media_kit demuxer cache preset (metadata-only `playback.` AUX row;
        // hidden while the fvp backend is active).
        'playback.videoCachePreset',
        // "Slider type" merged tile (design + anchor live in its dialog) and
        // the dial-ring/circle style tile — both power the sideway panel on
        // desktop too.
        'app.phoneLandscapeSliderType',
        // Speed-picker shape (more menu / control-bar RATE) — dual-wheel vs
        // the legacy flat 0.1 list; same gestures block as speed.gestureMode.
        'speed.rateMode',
        'virtualmedia.managerEntry',
        'virtualmedia.crossDragStrategy',
        'virtualmedia.markTickColor',
        'virtualmedia.namingStrategy',
        'virtualmedia.namePrefix',
        'virtualmedia.nameNumberFormat',
        'virtualmedia.dualTimeSync',
        'virtualmedia.hideChunkWhenSingleSegment',
        'virtualmedia.multiSelectHint',
        // Sub-audio playback block (background_playback.* AUX rows): source
        // management first, then follow/same-file policy, rate lock, layout.
        'background_playback.keepWarmPlayer',
        'background_playback.startArmed',
        'background_playback.autoFocusControl',
        'background_playback.followFgSwitch',
        'background_playback.allowSameFile',
        'background_playback.rateLock',
        'background_playback.videoLayout',
        'background_playback.alignDefault',
        'background_playback.ratioExplicitSave',
        'background_playback.seekLink',
        'background_playback.quickBar',
        'background_playback.quickBarAlign',
        // A/P/B editor: segment minimum length, P boundary behaviour, guide.
        'background_playback.minSegmentSpanMs',
        'background_playback.pAlignKeepMaxLength',
        'background_playback.stickyConsume',
        'background_playback.segmentGuide',
        'background_playback.gateStopBehavior',
        'background_playback.fgWindowZoom',
        'background_playback.fgWindowPushBg',
        'background_playback.snapEnabled',
        'background_playback.snapReleaseLimit',
        // 自动使用已保存的映射 (E 节 playback switch): off ignores saved timelines.
        'background_playback.useSavedMapping',
        // Cross-video switches + progress-lock tail (sortOrders 90..97) —
        // still inside the 副音 group, BEFORE the desktop-tools block.
        'background_playback.lockLevel',
        'background_playback.alignRingAssignment',
        'background_playback.stepMode',
        // VM 作用范围 matching mode (bg.vmScopeMode AUX row): matching rule
        // first, then the continuous-tiling switches.
        'background_playback.vmScopeMode',
        'background_playback.itemSwitch',
        'background_playback.segmentSwitch',
        'background_playback.alignAutoPauseRemainSec',
        'background_playback.exhaustedAction',
        'background_playback.queueSyncMode',
        // PotPlayer-style stacked bar (features/windows/desktop_control_bar)
        'app.keyboardShortcutScheme',
        'app.desktopControlBarLayout',
        // Desktop keybind customization (PotPlayer scheme, keybind.* AUX row).
        'keybind.editorEntry',
        // Screenshot save dir (desktop custom dir — desktop tools block tail;
        // platform default when empty).
        'screenshot.desktopDir',
        // Desktop hover policy: title-only on hover, full bar on click.
        'app.desktopHoverShowTitle',
        'app.desktopHoverShowControlBar',
        // Center-tap zone actions (circle slider / ring dial). The four zone
        // rows are phone-facing; the desktop phone-mode opt-in gates them.
        'app.centerZoneInwardAction',
        'app.desktopCenterZonePhoneMode',
        'app.centerZoneOutwardAction',
        'app.centerZoneTopAction',
        'app.centerZoneBottomAction',
      ]);
    });

    test(
        'General tab on desktop (windows) — no android-only rows, '
        'popup direction stays hidden like the legacy panel', () {
      expect(keys('general', 'windows'), [
        'app.language',
        'app.themeMode',
        // Browse-media-scope picker (dual-platform custom action row,
        // meta-driven only — hidden via DefVisibility under gate OFF).
        'browse.mediaScope',
        // Transfer entries are cross-platform since the full-platform
        // import/export change (engine is platform-neutral; cross-platform
        // imports filter via PlatformKeyPolicy).
        'data.exportEntry',
        'data.importEntry',
        // Transfer audit log entry (settings_transfer) — Data block tail,
        // meta-driven only (hidden via DefVisibility under gate OFF).
        'security.transferLog',
        // WebDAV wildcard-host resolution strategy (app.-domain enumPick:
        // discovery vs legacy serial scan) — network/data strategy, grouped
        // with the Data block.
        'app.webDavScanMode',
        // Warning-dialog suppression editor (dual-platform action row)
        'warnings.editorEntry',
        // PotPlayer-style keyboard OSD (desktop-only, `osd.` AUX rows).
        'osd.enabled',
        'osd.visibilityMode',
        'osd.hAlign',
        'osd.vAlign',
        'osd.layout',
        'osd.durationMs',
        // Media-library scan preferences (own group, ahead of Advanced).
        // Custom desktop entries are Android-only (features/app_identity,
        // meta-driven only) — the Windows desktop has no such row.
        'scan.autoCloseDelay',
        'scan.rescanReminderMinutes',
        // tag_play block (tagplay.* AUX rows): numeric command bar + hint
        // banner + the opt-in "previous view" return row. Dual-platform; the
        // bar is locked ON for desktop.
        'tagplay.inputBar',
        'tagplay.inputHint',
        'tagplay.viewStackEnabled',
        // Requirement #5: the five legacy toggles consolidated into ONE
        // Legacy 兼容 entry (gate + dual-write + three runtime switches live
        // inside its dialog) — Advanced tail.
        'legacy.compatEntry',
      ]);
    });

    test('Play tab on android covers every legacy row', () {
      // autoResize is desktop-only (platforms windows/linux/macos);
      // showControlsOnPlayToPause stays mobile-only like the legacy panel
      // (play.dart gates it behind isMobilePlatform). The one-handed right/left
      // slider-type option folded away the standalone landscape-use-mode row,
      // the snake fine-tune row is meta-hidden (timeLens/snake no longer
      // offered there), and seek step now lives on the control bar (horizontal
      // slider dialog at the former subtitle position) — not in settings.
      // dialring composite retired into sliderType dialog; speed gesture mode is android-only.
      expect(keys('play', 'android'), [
        'app.playerBackend',
        'video.mobileDisplayMode',
        // Play-queue toolbar layout (cross-platform; the queue's own trailing
        // toggle is the runtime control).
        'window.scenarioQueueLayout',
        'app.alwaysPlayFromBeginning',
        // Auto-resume last media on app start (metadata-only AUX row).
        'playback.resumeOnStartup',
        'app.showControlsOnPlayToPause',
        // media_kit demuxer cache preset (metadata-only `playback.` AUX row).
        'playback.videoCachePreset',
        'app.phoneLandscapeSliderType',
        'speed.gestureMode',
        'speed.rateMode',
        // Phone-PORTRAIT bottom-bar alignment (one composite tile: playback
        // group + 副音 group), android-only.
        'app.portraitPlaybackAlign',
        'app.preferredOrientation',
        'app.reuseLastOrientation',
        'gesture.unifiedEntry',
        'virtualmedia.managerEntry',
        'virtualmedia.crossDragStrategy',
        'virtualmedia.markTickColor',
        'virtualmedia.namingStrategy',
        'virtualmedia.namePrefix',
        'virtualmedia.nameNumberFormat',
        'virtualmedia.dualTimeSync',
        'virtualmedia.hideChunkWhenSingleSegment',
        'virtualmedia.multiSelectHint',
        // Sub-audio playback block (same semantic order as desktop).
        'background_playback.keepWarmPlayer',
        'background_playback.startArmed',
        'background_playback.autoFocusControl',
        'background_playback.followFgSwitch',
        'background_playback.allowSameFile',
        'background_playback.rateLock',
        'background_playback.videoLayout',
        'background_playback.alignDefault',
        'background_playback.ratioExplicitSave',
        'background_playback.seekLink',
        'background_playback.quickBar',
        'background_playback.quickBarAlign',
        'background_playback.minSegmentSpanMs',
        'background_playback.pAlignKeepMaxLength',
        'background_playback.stickyConsume',
        'background_playback.segmentGuide',
        'background_playback.gateStopBehavior',
        'background_playback.fgWindowZoom',
        'background_playback.fgWindowPushBg',
        'background_playback.snapEnabled',
        'background_playback.snapReleaseLimit',
        'background_playback.useSavedMapping',
        // Cross-video switches + progress-lock tail (sortOrders 90..97).
        'background_playback.lockLevel',
        'background_playback.alignRingAssignment',
        'background_playback.stepMode',
        'background_playback.vmScopeMode',
        'background_playback.itemSwitch',
        'background_playback.segmentSwitch',
        'background_playback.alignAutoPauseRemainSec',
        'background_playback.exhaustedAction',
        'background_playback.queueSyncMode',
        // Screenshot save dir (mobile custom dir; platform default
        // Pictures/IRIS when empty).
        'screenshot.mobileDir',
        // Center-tap zone actions (phone-facing; the desktop-only phone-mode
        // opt-in row is filtered out here).
        'app.centerZoneInwardAction',
        'app.centerZoneOutwardAction',
        'app.centerZoneTopAction',
        'app.centerZoneBottomAction',
      ]);
    });
  });

  group('defaults parity — every app.* def default equals AppState default',
      () {
    final defaults = const AppState().toJson();

    /// Def defaults follow ValueCodec's column encoding: bool → 'true'/
    /// 'false', numerics → toString(), strings/enum-names verbatim. (This is
    /// NOT jsonEncode form — that's the setting_values row dialect.)
    String encode(SettingValueType? type, Object value) {
      if (value is bool) return value ? 'true' : 'false';
      if (value is num) return value.toString();
      if (type == SettingValueType.enumeration || value is String) {
        return value.toString();
      }
      return jsonEncode(value);
    }

    test('declared defaults match @Default values byte-for-byte', () {
      for (final d in defs) {
        if (!d.key.startsWith('app.') || d.defaultValue == null) continue;
        final field = d.key.substring('app.'.length);
        expect(defaults.containsKey(field), isTrue,
            reason: '${d.key}: def targets a nonexistent AppState field');
        expect(d.defaultValue, encode(d.valueType, defaults[field]!),
            reason: '${d.key}: contribution default diverged from AppState');
      }
    });

    test('gate + sync default polarity (dialog-hosted, requirement #5)', () {
      // The gate/sync DEFS moved inside the Legacy 兼容 entry; the polarity
      // contract now lives on AppState defaults, which the dialog's switches
      // lead with.
      expect(const AppState().useMetadataSettings, isTrue,
          reason: 'meta-driven is the install default (meta era)');
      expect(const AppState().syncLegacyBlob, isTrue,
          reason: 'dual-write is the safe default');
    });
  });

  group('constraint parity — metadata clamps equal typed mutator clamps', () {
    // These literals mirror AppStore/RecursiveScanStore clamp code; if a
    // typed clamp changes, change it here AND in the contribution together.
    test('autoCloseDelay [0.0, 15.0] and default matches scan state', () {
      final d = defs.singleWhere((d) => d.key == 'scan.autoCloseDelay');
      expect(d.clampMin, 0);
      expect(d.clampMax, 15);
      expect(
        d.defaultValue,
        jsonEncode(const RecursiveScanState().toJson()['autoCloseDelay']),
      );
    });
  });

  group('subtitle parity — legacy descriptive subtitles survive migration', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    const expected = <String, String>{
      'app.alwaysPlayFromBeginning': 'always_play_from_beginning_description',
      'app.showControlsOnPlayToPause':
          'show_controls_on_play_to_pause_description',
      // Requirement #5: the three legacy runtime toggles moved inside the
      // Legacy 兼容 entry — their descriptive copy lives on that def now.
      'legacy.compatEntry': 'legacy_compat_desc',
    };

    test('the legacy toggles declare their descriptive subtitle keys', () {
      for (final entry in expected.entries) {
        final d = defs.singleWhere((d) => d.key == entry.key);
        expect(d.subtitleKey, entry.value,
            reason: '${entry.key} lost its legacy descriptive subtitle');
      }
    });

    test('SettingTexts resolves those keys to non-empty localized text',
        () async {
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      for (final key in expected.values) {
        expect(SettingTexts.subtitle(key, t), isNotEmpty,
            reason: '$key must map to a real localized string');
      }
    });
  });
}
