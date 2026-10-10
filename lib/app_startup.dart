import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:iris/app_shutdown.dart';
import 'package:iris/features/app_identity/services/app_identity_paths.dart';
import 'package:iris/features/app_identity/services/shortcut_channel_service.dart';
import 'package:iris/features/app_identity/store/use_app_identity_store.dart';
import 'package:iris/features/media_library/services/saf_uri_backfill_service.dart';
import 'package:iris/features/playback_tools/services/screenshot_service.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/controller/background_playback_bootstrap.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/services/bg_source_revision.dart';
import 'package:iris/features/background_playback/store/bg_source_bootstrap.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/control_group/store/use_control_group_store.dart';
import 'package:iris/features/meta_settings/engine/def_visibility.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/scenario_playback/actions/drag_drop_gate.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/playback/vm_group_position_sync.dart';
import 'package:iris/features/settings_transfer/transfer_module.dart';
import 'package:iris/features/tag_play/playback/tag_play_controller.dart';
import 'package:iris/features/tag_play/store/tag_play_bootstrap.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/features/virtual_media/store/vm_bootstrap.dart';
import 'package:iris/features/virtual_media/vm_gate.dart';
import 'package:iris/globals.dart' as globals;
import 'package:iris/models/db/app_database_holder.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_scope.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/storages/storage_name_prefs.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart' show isMobilePlatform;
import 'package:media_stream/media_stream.dart';
import 'package:window_manager/window_manager.dart';

final _log = AreaKeyLog(LogKeys.legacyMain);

/// Desktop window bootstrap (kept separate so `main()` stays linear).
Future<void> windowManagerEnsureReady() async {
  await windowManager.ensureInitialized();

  // Intercept the native close so the players are disposed BEFORE the engine
  // tears the isolate down (see [AppShutdown]): Alt+F4 / the title-bar ✕ would
  // otherwise kill the isolate with live mpv callbacks still registered,
  // crashing the process on exit. The window is hidden immediately so the
  // multi-second teardown stays off-screen.
  AppShutdown.configure(
    destroy: windowManager.destroy,
    hide: windowManager.hide,
    forceExit: () async => exit(0),
  );
  await windowManager.setPreventClose(true);
  windowManager.addListener(_WindowCloseShutdownListener());

  WindowOptions windowOptions = const WindowOptions(
    size: Size(1280, 720),
    minimumSize: Size(427, 240),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

/// Heavyweight startup that runs behind the [BootstrapGate] splash, AFTER
/// the optional portable first-run import has settled. Everything touching
/// the database, stores, or plugins with startup side effects lives here.
Future<void> completeStartupInitialization() async {
  await AppDatabaseHolder.init();
  await DbModule.init(AppDatabaseHolder.instance);

  // AppStore is constructed on the first frame (before this point), so its
  // `onReady` could not switch the DB-backed stores. Now that the DB is wired,
  // wait for AppStore's persisted state and apply the configured backends once.
  // Doing it here (not inside onReady) keeps onReady synchronous, avoiding a
  // FakeAsync deadlock in widget tests.
  await useAppStore().initialized;
  await useAppStore().applyConfiguredBackends();

  // AUX preference rows are re-hydrated on gate-ON; while the gate is OFF a
  // legacy-mode run must not write them (or a stale default could clobber the
  // preserved meta-era data). Injected here so MetaSettingsModule stays
  // state-agnostic and never imports the store.
  MetaSettingsModule.writeGate = () => useAppStore().state.useMetadataSettings;

  // Media-library data scope: linked entries (same account + same/contained
  // tree) share one `data_scope_id`, so node/scan IO is keyed by it. Reads the
  // live storage store; an unknown/independent entry resolves to itself.
  StorageScope.resolver = (storageId) =>
      useStorageStore().findById(storageId)?.dataScopeId ?? storageId;

  // Media-node paths are stored RELATIVE to the storage base (schema v38), so a
  // drive-letter reassignment changes only `storages_table.base_path` — the node
  // rows need no rewrite. The base is resolved here from the live store; remote
  // entries (`/` root) resolve to no conversion.
  StoragePathCodec.baseResolver =
      (storageId) => useStorageStore().findById(storageId)?.basePath;

  await DbModule.scenarioRepo.ensureSystemPlayingScenario();
  await DbModule.scenarioRepo.dedupeSources();
  // tag_play retention sweep: physically remove long-expired memberships in
  // the background (lazy read-filter already hides them from the UI).
  await DbModule.tagPlayRepo.purgeExpired();

  Log.init();
  PlaybackProviderRegistry.init();
  // Merged-session → scenario bookkeeping: a VM session advances across groups
  // without the scenario ever being told, which left the queue highlight (and
  // the locate hint) on the previously tapped row.
  VmGroupPositionSync.instance.start();
  // 副音 playback: registers the control-target router + candidate sources.
  BackgroundPlaybackBootstrap.init();
  // 副音 source rules: seed the non-deletable built-in rule + import legacy
  // JSON rules into the table (meta-driven era only).
  if (BackgroundPlaybackGate.enabled) {
    await BgSourceBootstrap.ensure(DbModule.bgSourceRuleRepo);
    // Membership writes of the tags the rules read from must reach the
    // candidate pool (and a live queue) without waiting for a rule edit.
    BgSourceRevision.shared.start();
  }

  // tag_play global session prefs (pin order, active view, view stack).
  await useTagPlayStore().load();
  // Storage-name template: preload the in-memory snapshot so the (cached)
  // storage dialogs read it synchronously without an async rebuild.
  await StorageNamePrefs.load();
  // 副音 playback prefs (queue/volume/linkage rows) — construct + load so the
  // meta settings rows below read real persisted values, never boot defaults.
  await useBackgroundPlaybackStore().initialized;
  // One-handed bottom control-group switch (selected group + floating button
  // visibility/position) — KV-backed, cross-restart.
  await useControlGroupStore().initialized;
  // Hide tagplay.* settings rows whenever the feature is unavailable
  // (metadata gate OFF ⇒ no tag functionality at all).
  DefVisibility.registerPrefix('gesture.', () => MetaSettingsModule.ready && useAppStore().state.useMetadataSettings);
  DefVisibility.registerPrefix('tagplay.', () => TagPlayGate.enabled);
  // 副音 settings rows: meta-driven era only (feature gate — absent in the
  // legacy persistence mode where the subsystem does not exist at all).
  DefVisibility.registerPrefix(
    'background_playback.',
    () => BackgroundPlaybackGate.enabled,
  );
  // Virtual-video matching only makes sense under the "This video" scope:
  // the "All videos" scope covers it (nothing to match), so the row stays
  // hidden there — mirroring the quick scope card, which only renders the
  // section for `currentOnly`.
  DefVisibility.registerKey(
    'background_playback.vmScopeMode',
    () =>
        BackgroundPlaybackGate.enabled &&
        useBackgroundPlaybackStore().state.applyScope ==
            BgApplyScope.currentOnly,
  );
  // Same contract for the browse-media-scope row: absent unless the metadata
  // subsystem is actually running (legacy mode filters nothing).
  DefVisibility.registerPrefix(
    'browse.',
    () =>
        MetaSettingsModule.ready &&
        useAppStore().state.useMetadataSettings,
  );
  // Same contract for the playback-resume row (`playback.resumeOnStartup`):
  // metadata-only AUX domain, absent in legacy mode (behavior degrades to
  // the code default `true` via resolveResumeOnStartup).
  DefVisibility.registerPrefix(
    'playback.',
    () =>
        MetaSettingsModule.ready &&
        useAppStore().state.useMetadataSettings,
  );
  // The drag-drop split row exists only where the drop path does (metadata era
  // + scenario-driven playback); otherwise it is hidden entirely.
  DefVisibility.registerKey(
    'playback.dropAppendPercent',
    () => DragDropGate.enabled,
  );
  // Demuxer cache preset steers the media_kit (mpv) backend only; hide it
  // while fvp is active (unavailable functionality must never be shown).
  DefVisibility.registerKey(
    'playback.videoCachePreset',
    () =>
        MetaSettingsModule.ready &&
        useAppStore().state.useMetadataSettings &&
        useAppStore().state.playerBackend == PlayerBackend.mediaKit,
  );
  // Step-seek scheduling steers the media_kit burst chain only; hide it while
  // fvp is active.
  DefVisibility.registerKey(
    'playback.stepSeekMode',
    () =>
        MetaSettingsModule.ready &&
        useAppStore().state.useMetadataSettings &&
        useAppStore().state.playerBackend == PlayerBackend.mediaKit,
  );
  // App-identity rows: meta-driven era only (entries live in `identity.*`
  // AUX rows); the def's own platforms list restricts to android/windows.
  DefVisibility.registerPrefix(
    'identity.',
    () =>
        MetaSettingsModule.ready &&
        useAppStore().state.useMetadataSettings,
  );
  // Custom desktop entries: icon storage + persisted entries + capability.
  await AppIdentityPaths.ensureInitialized();
  await useAppIdentityStore().load();
  if (!kIsWeb && Platform.isAndroid) {
    final cap = await ShortcutChannelService().capability();
    await useAppIdentityStore().setSupported(cap.pinAvailable);
    // Buffer a cold-start shortcut launch for the Home router to consume.
    final initialEntry = await ShortcutChannelService().popInitialEntry();
    if (initialEntry != null) {
      globals.entryLaunchId ??= initialEntry;
    }
  }
  // Virtual Media: absent unless the metadata-driven stack is running
  // (rules live in Drift; the feature has no legacy-mode behavior at all).
  DefVisibility.registerPrefix(
    'virtualmedia.',
    () => VirtualMediaGate.enabled,
  );
  // Keyboard OSD: metadata-driven desktop-only transient HUD (see
  // features/osd). Hidden in legacy mode, degrades to no OSD.
  DefVisibility.registerPrefix(
    'osd.',
    () =>
        MetaSettingsModule.ready &&
        useAppStore().state.useMetadataSettings,
  );
  // Playlist dock / window settings: meta-driven desktop-only.
  DefVisibility.registerPrefix(
    'window.',
    () =>
        MetaSettingsModule.ready &&
        useAppStore().state.useMetadataSettings,
  );
  // Desktop keybind customization: PotPlayer scheme, meta-driven only.
  DefVisibility.registerPrefix(
    'keybind.',
    () =>
        MetaSettingsModule.ready &&
        useAppStore().state.useMetadataSettings,
  );
  // Video display modes: per-platform enums, meta-driven only (gate-OFF
  // keeps the legacy `fit` cycle — unavailable functionality must never be
  // displayed).
  DefVisibility.registerPrefix(
    'video.',
    () =>
        MetaSettingsModule.ready &&
        useAppStore().state.useMetadataSettings,
  );
  DefVisibility.registerPrefix(
    'speed.',
    () => MetaSettingsModule.ready && useAppStore().state.useMetadataSettings,
  );
  // Transfer audit log: meta-driven only.
  DefVisibility.registerPrefix(
    'security.',
    () =>
        MetaSettingsModule.ready &&
        useAppStore().state.useMetadataSettings,
  );
  // Rescan-reminder window: meta-driven only (the scan gate + dialog are
  // absent in legacy mode; autoCloseDelay stays visible as before).
  DefVisibility.registerPrefix(
    'scan.rescanReminder',
    () =>
        MetaSettingsModule.ready &&
        useAppStore().state.useMetadataSettings,
  );
  // Screenshot save dirs: metadata-only AUX (`screenshot.mobileDir` /
  // `screenshot.desktopDir`); legacy mode keeps the old beside-video /
  // documents behavior and never shows these rows.
  DefVisibility.registerPrefix(
    'screenshot.',
    () =>
        MetaSettingsModule.ready &&
        useAppStore().state.useMetadataSettings,
  );
  // Center-tap zones: the four sector pickers are phone-facing; on desktop
  // they appear only after the `app.desktopCenterZonePhoneMode` opt-in, so a
  // desktop user who never enables it sees no inactive zone rows.
  for (final String key in const <String>[
    'app.centerZoneInwardAction',
    'app.centerZoneOutwardAction',
    'app.centerZoneTopAction',
    'app.centerZoneBottomAction',
  ]) {
    DefVisibility.registerKey(
      key,
      () =>
          MetaSettingsModule.ready &&
          useAppStore().state.useMetadataSettings &&
          (isMobilePlatform ||
              useAppStore().state.desktopCenterZonePhoneMode),
    );
  }
  await TransferModule.init();
  // One-shot seeding of the two built-in sample tags (meta era only).
  if (TagPlayGate.enabled) {
    await TagPlayBootstrap.ensure(DbModule.tagPlayRepo);
  }
  // One-shot seeding of the default `_dirs_as_virtual` rule (meta era only).
  if (VirtualMediaGate.enabled) {
    await VirtualMediaBootstrap.ensure(DbModule.virtualMediaRepo);
  }

  fvp.registerWith(options: {
    // 'fastSeek': true,
    'player': {
      if (Platform.isAndroid) 'audio.renderer': 'AudioTrack',
      'avio.reconnect': '1',
      'avio.reconnect_delay_max': '7',
      'buffer': '2000+80000',
      'demux.buffer.ranges': '8',
    },
    if (Platform.isAndroid) 'subtitleFontFile': 'assets/fonts/NotoSansCJKsc-Medium.otf',
    'global': {
      'log': 'debug',
    }
  });

  final appLinks = AppLinks();
  final initUri = await appLinks.getInitialLinkString();

  if (initUri != null) {
    _log.i('initUri: $initUri');
    globals.initUri = initUri;
  }

  MediaStream mediaStream = MediaStream();
  mediaStream.startServer();

  // Screenshot dir prewarm: the first-ever capture used to pay for the
  // permission probe + public-Pictures mkdir on the shutter tap (UI
  // freeze behind the system dialog). Warm it in the background once so
  // the first tap only waits on the mpv frame grab. Best-effort: never
  // blocks startup, never throws.
  unawaited(prewarmScreenshotDir());

  // One-time background repair of SAF rows that predate the persisted
  // `uri` column (schema v23). Android-only; no-op without SAF storages.
  unawaited(backfillSafMediaUris());
}

/// Bridges window_manager's close event to [AppShutdown]. Registered once at
/// startup; the OS close signal (Alt+F4, ✕, taskbar) is held until the
/// shutdown finishes and releases the window.
class _WindowCloseShutdownListener with WindowListener {
  @override
  void onWindowClose() {
    unawaited(AppShutdown.run());
  }
}
