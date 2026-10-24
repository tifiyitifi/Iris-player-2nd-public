import 'dart:io';

import 'package:flutter/material.dart';
import 'package:iris/features/app_identity/model/domain/app_identity_entry.dart';
import 'package:iris/features/app_identity/services/shortcut_channel_service.dart';
import 'package:iris/features/app_identity/store/use_app_identity_store.dart';
import 'package:iris/features/meta_settings/engine/playback_resume.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/playback/tag_play_controller.dart';
import 'package:iris/globals.dart' as globals;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.appIdentity);

/// Result of an entry activation attempt.
enum ActivationResult {
  /// Playback was routed through the entry.
  activated,

  /// The launch was consumed but playback fell back to defaults
  /// (missing binding, unavailable feature) — the generic resume must NOT run.
  consumedFallback,

  /// Not an entry launch at all — caller should run the generic resume.
  notApplicable,
}

/// Orchestrates desktop-entry launches.
///
/// Each entry is one of two things ([AppIdentityEntry.sharedWithDefault]):
/// - SHARED: a plain icon/name alias of the default entry — activation resumes
///   the SystemPlaying context, exactly like tapping the default icon.
/// - INDEPENDENT (default): the entry owns its own saved "system playing"
///   workspace. The optional `seedScenarioId`/`seedTagId` initialize it ONCE on
///   the first activation (same effect as a normal scenario + tag activation);
///   afterwards the entry keeps its own evolving state and the seed is ignored.
///
/// All entries share the same database; "independent" simply means a separate
/// internal workspace row ([ScenarioKind.entryWorkspace]) per entry.
class AppIdentityActions {
  const AppIdentityActions._();

  /// Feature availability gate (mirrors DefVisibility contract).
  static bool get available {
    if (!Platform.isAndroid) {
      return false;
    }
    final app = useAppStore().state;
    return MetaSettingsModule.ready &&
        app.useMetadataSettings &&
        !app.useLegacyStoragePersistence &&
        // Entry playback is scenario-driven; without that path nothing routes.
        app.useScenarioDrivenPlayback;
  }

  /// Consumes the pending cold-start launch (Android shortcut extra)
  /// and activates it. Returns [ActivationResult.notApplicable] when there
  /// is no entry launch, letting the caller fall back to generic resume.
  ///
  /// The [NavigatorState] must be captured by the caller BEFORE any await
  /// (house pattern from ScenarioResolvedActions) so dialogs never touch a
  /// dead context.
  static Future<ActivationResult> consumeStartupLaunch(
    NavigatorState navigator,
  ) async {
    final id = globals.entryLaunchId ??
        await ShortcutChannelService().popInitialEntry();
    globals.entryLaunchId = null;
    if (id == null || id.isEmpty) return ActivationResult.notApplicable;
    return activateEntry(navigator, id, coldStart: true);
  }

  /// Activates one entry by id. Never throws — every failure degrades to a
  /// dialog or a fallback so a broken shortcut cannot wedge the player.
  ///
  /// [coldStart] selects the autoplay policy: a cold launch follows
  /// `playback.resumeOnStartup` (like the default icon), a warm launch
  /// preserves the live player's current play intent (see
  /// [resolveEntryAutoplay]).
  static Future<ActivationResult> activateEntry(
    NavigatorState navigator,
    String id, {
    bool coldStart = true,
  }) async {
    if (!available) return ActivationResult.notApplicable;
    final store = useAppIdentityStore();
    final entry = store.entryById(id);
    if (entry == null) {
      await _infoDialog(
        navigator,
        getLocalizations(navigator.context).entry_launch_stale,
      );
      return ActivationResult.consumedFallback;
    }

    final app = useAppStore();
    final autoplay = resolveEntryAutoplay(
      app.state,
      coldStart: coldStart,
      metadataEnabled:
          app.state.useMetadataSettings && MetaSettingsModule.ready,
    );

    try {
      final scenarioStore = usePlaybackScenarioStore();
      await scenarioStore.ensureReady();
      // The playback context is about to change: drop any tag view so its
      // adapter cannot keep driving the previous scenario.
      await PlaybackProviderRegistry.tagPlay.clearActiveView();
      // Flip the highlight pointer FIRST: the workspace/tag work below is
      // slow (database + resolver), and the manager page must reflect the
      // newly entered entry while it runs instead of after it. The in-memory
      // set is synchronous; persistence follows without blocking the UI.
      final previousActiveId = store.state.activeEntryId;
      await store.setActiveEntry(entry.id);
      try {
        return entry.sharedWithDefault
            ? await _activateShared(scenarioStore, entry, autoplay)
            : await _activateIndependent(
                navigator, store, scenarioStore, entry, autoplay);
      } catch (_) {
        // A failed activation must not leave a lying highlight behind.
        try {
          await store.setActiveEntry(previousActiveId);
        } catch (_) {
          // Best-effort: the next launch corrects the pointer.
        }
        rethrow;
      }
    } catch (e, s) {
      _log.e('activateEntry($id) failed: $e', e, s);
      await _infoDialog(
        navigator,
        getLocalizations(navigator.context).entry_activation_failed('$e'),
      );
      return ActivationResult.consumedFallback;
    }
  }

  /// Shared entry: resume the default SystemPlaying context. The active-entry
  /// pointer is flipped by the caller before this runs (see [activateEntry]).
  static Future<ActivationResult> _activateShared(
    PlaybackScenarioStore scenarioStore,
    AppIdentityEntry entry,
    bool autoplay,
  ) async {
    final ws = await scenarioStore.ensureSystemPlayingScenario();
    // Shared entries use the DEFAULT 副音 workspace (their fg/bg pair is the
    // default one).
    await scenarioStore.ensureBackgroundWorkspace();
    await ScenarioPlaybackActions.switchPlaybackContext(ws.id,
        autoplay: autoplay);
    return ActivationResult.activated;
  }

  /// Independent entry: resume the entry's OWN workspace, initializing it from
  /// the seed scenario/tag on the first activation only.
  static Future<ActivationResult> _activateIndependent(
    NavigatorState navigator,
    AppIdentityStore store,
    PlaybackScenarioStore scenarioStore,
    AppIdentityEntry entry,
    bool autoplay,
  ) async {
    final firstLaunch = entry.initializedAt == null;
    // 1. The entry's CANONICAL fg/bg rows: they own the shared definition, and
    //    the primary window plays directly in them.
    final canonical =
        await scenarioStore.ensureEntryWorkspace(entry.workspaceScenarioId);
    // Every independent entry owns its own fg/bg PAIR: its 副音 workspace is
    // created alongside the foreground one (prefs stay global; only the
    // queue/definition is per context).
    final canonicalBg = await scenarioStore
        .ensureEntryBackgroundWorkspace(entry.backgroundWorkspaceScenarioId);

    var next = entry;
    if (next.workspaceScenarioId != canonical.id) {
      next = next.copyWith(workspaceScenarioId: canonical.id);
    }
    if (next.backgroundWorkspaceScenarioId != canonicalBg.id) {
      next = next.copyWith(backgroundWorkspaceScenarioId: canonicalBg.id);
    }

    if (firstLaunch) {
      final seedSid = entry.seedScenarioId;
      if (seedSid != null) {
        final source = await scenarioStore.getScenario(seedSid);
        if (source != null) {
          // Seed the CANONICAL row: the definition is shared, so every window
          // (and the entry's own shortcut) inherits it. A window private row is
          // copied from it right below.
          await scenarioStore.overrideWorkspace(
            workspace: canonical,
            source: source,
          );
          await scenarioStore.bumpPlaybackVersion();
        } else {
          await _infoDialog(
            navigator,
            getLocalizations(navigator.context)
                .entry_seed_scenario_gone(entry.name),
          );
        }
      }
      next = next.copyWith(initializedAt: DateTime.now());
    }

    if (next != entry) {
      await store.upsertEntry(next);
    }

    // 2. The row THIS window actually plays: the canonical one for the primary,
    //    a private claim for an extra window (seeded with the canonical
    //    DEFINITION, never with another window's queue).
    final ws = await scenarioStore.ensureWindowEntryWorkspace(
      entryId: entry.id,
      sharedId: canonical.id,
    );
    await scenarioStore.ensureWindowEntryWorkspace(
      entryId: entry.id,
      sharedId: canonicalBg.id,
      background: true,
    );

    if (scenarioStore.state.activeScenarioId != ws.id) {
      await scenarioStore.setActiveScenario(ws.id);
    }
    // The active-entry pointer was flipped by the caller before the
    // workspace work above (see [activateEntry]).

    final tid = entry.seedTagId;
    if (firstLaunch && tid != null && TagPlayGate.viewSwitchingEnabled) {
      final tagStart = await PlaybackProviderRegistry.tagPlay
          .enterView(tid, scenarioId: ws.id, autoplay: autoplay);
      if (tagStart != null) return ActivationResult.activated;
      // Empty/dead tag view → fall through to plain workspace playback.
    }
    // Resolve and feed THIS entry's own current video (or blank when empty) —
    // never the previously playing context.
    await ScenarioPlaybackActions.switchPlaybackContext(ws.id,
        autoplay: autoplay);
    return ActivationResult.activated;
  }

  /// Called BEFORE the generic startup resume on DEFAULT-icon launches: clears
  /// the active-entry pointer and points the context at SystemPlaying.
  static Future<void> restoreDefaultBeforeResume() async {
    if (!available) return;
    try {
      final store = useAppIdentityStore();
      final scenarioStore = usePlaybackScenarioStore();
      await scenarioStore.ensureReady();
      // A default-icon launch ends any entry context, so a tag view seeded by
      // an entry must not keep driving playback against SystemPlaying.
      await PlaybackProviderRegistry.tagPlay.clearActiveView();
      final sys = await scenarioStore.ensureSystemPlayingScenario();
      // A default-icon launch also uses the DEFAULT 副音 workspace.
      await scenarioStore.ensureBackgroundWorkspace();
      if (scenarioStore.state.activeScenarioId != sys.id) {
        await scenarioStore.setActiveScenario(sys.id);
      }
      if (store.state.activeEntryId != null) {
        await store.setActiveEntry(null);
      }
      _log.i('default SystemPlaying workspace selected before generic resume');
    } catch (e, s) {
      _log.e('restoreDefaultBeforeResume failed: $e', e, s);
    }
  }

  static Future<void> _infoDialog(
    NavigatorState navigator,
    String message,
  ) {
    return showDialog<void>(
      context: navigator.context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalizations(ctx).entry_title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalizations(ctx).ok),
          ),
        ],
      ),
    );
  }
}
