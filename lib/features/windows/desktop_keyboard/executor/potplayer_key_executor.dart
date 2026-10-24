// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iris/utils/app_exit.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/playback_tools/services/screenshot_service.dart';
import 'package:iris/features/playback_tools/view/screenshot_capture_flow.dart';
import 'package:iris/features/playback_tools/view/screenshot_feedback.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/player_control_target_scope.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/ab_loop_engine.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/seek_tiers.dart';
import 'package:iris/features/windows/desktop_keyboard/store/ab_loop_store.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/potplayer_key_map.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/resolve_keybinds.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/sequence_resolver.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/speed_reset_toggle.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/speed_step.dart';
import 'package:iris/features/windows/desktop_keyboard/model/keybind_codec.dart';
import 'package:iris/features/tag_play/playback/tag_play_controller.dart' show TagPlayGate;
import 'package:iris/features/tag_play/commands/tag_play_actions.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';
import 'package:iris/features/windows/desktop_keyboard/store/key_sequence_buffer_store.dart';
import 'package:iris/features/windows/desktop_keyboard/view/show_jump_to_time_dialog.dart';
import 'package:iris/features/windows/explorer/menu/explorer_reveal_action.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/seek_step_popover.dart';
import 'package:iris/features/meta_settings/engine/osd_resolver.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/osd/engine/osd_texts.dart';
import 'package:iris/features/osd/model/osd_entry.dart';
import 'package:iris/features/osd/store/osd_store.dart';
import 'package:iris/features/windows/recycle_bin/recycle_bin.dart';
import 'package:iris/features/scenario_playback/actions/media_revision_actions.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:iris/features/virtual_media/service/vm_membership_pin.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/vm_gate.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/db/storage_scope.dart';
import 'package:iris/models/file.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';
import 'package:iris/globals.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/models/store/video_display_mode.dart';
import 'package:iris/models/store/window_fit_mode.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/bottom_sheets/show_open_link_bottom_sheet.dart';
import 'package:iris/widgets/dialogs/show_open_link_dialog.dart';
import 'package:iris/widgets/popup.dart';
import 'package:iris/widgets/popups/history.dart';
import 'package:iris/widgets/popups/play_queue.dart';
import 'package:iris/widgets/popups/settings/settings.dart';
import 'package:iris/widgets/popups/storages/storages.dart';
import 'package:iris/widgets/popups/track/subtitle_and_audio_track.dart';
import 'package:provider/provider.dart';

final _log = AreaKeyLog(LogKeys.player);

/// The currently playing LOCAL file's identity (see
/// [PotPlayerKeyExecutor._resolveCurrentLocalMedia]).
typedef _LocalMedia = ({
  PlayQueueItem item,
  String path,
  String storageId,
  String? relPath,
});

/// Whether a physical delete must re-arm autoplay so the legacy/paged queue
/// keeps playing the NEXT entry.
///
/// Scenario mode has an explicit resume path (`revalidateCurrent` /
/// `resumeActive`). The non-scenario queue only re-opens the advanced entry
/// through the player's `[file]` effect with `play: autoPlay`; if the user was
/// watching while autoplay happened to be off, the delete would otherwise park
/// on a paused, swapped-out current item. Pure so the intent is unit-testable.
@visibleForTesting
bool shouldContinueQueuePlaybackAfterDelete({
  required bool scenarioMode,
  required bool wasPlaying,
}) =>
    !scenarioMode && wasPlaying;

/// Executes PotPlayerAction for the potplayer keyboard scheme (SRS §5).
///
/// Owns the sequence-buffer Timer; every action mirrors the corresponding
/// legacy handler in use_keyboard so switching schemes changes ONLY the
/// bindings, never the side effects. Strict replacement: unbound keys do
/// nothing.
class PotPlayerKeyExecutor {
  PotPlayerKeyExecutor({
    required this.context,
    required this.player,
    required this.showControl,
    required this.showControlForHover,
    required this.showProgress,
  });

  final BuildContext context;
  final MediaPlayer player;
  final void Function() showControl;
  final Future<void> Function(Future<void>) showControlForHover;
  final void Function() showProgress;

  Future<void> handle(KeyEvent event) async {
    final isRepeat = event.runtimeType == KeyRepeatEvent;

    // Releasing a base-step adjust key commits the live value (no-op when
    // clean). Checked before the KeyDown/Repeat gate so the release is caught.
    if (event is KeyUpEvent &&
        (event.logicalKey == LogicalKeyboardKey.arrowUp ||
            event.logicalKey == LogicalKeyboardKey.arrowDown)) {
      await useAppStore().commitSeekStepSeconds();
      return;
    }

    // Releasing a held speed key flushes the live rate to storage once (the
    // auto-repeat path below only mutated memory — see updateRateLive).
    if (event is KeyUpEvent &&
        (event.logicalKey == LogicalKeyboardKey.keyX ||
            event.logicalKey == LogicalKeyboardKey.keyC)) {
      await useAppStore().commitRate();
      return;
    }

    if (event.runtimeType != KeyDownEvent && !isRepeat) return;

    // Hardware media keys work identically under both schemes (SRS §5.6).
    if (!isRepeat && await _handleMediaKey(event.logicalKey)) return;

    final input = (
      key: event.logicalKey,
      ctrl: HardwareKeyboard.instance.isControlPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
      isRepeat: isRepeat,
    );

    final bufferStore = useKeySequenceBufferStore();
    // While a popup/dialog covers the player, the buffered `;` session is
    // stale — dismiss it so a subsequent H/R/F/X cannot re-trigger the
    // panel just closed via Esc (L5).
    if (bufferStore.state.isBuffering &&
        ModalRoute.of(context)?.isCurrent == false) {
      _closeSequenceBuffer();
    }
    final verdict = resolveSequence(
      state: (
        buffered: bufferStore.state.isBuffering,
        elapsed: bufferStore.elapsed,
      ),
      input: input,
    );
    if (verdict is! Unhandled) _log.d('sequence: $verdict');

    switch (verdict) {
      case OpenBuffer():
        _openSequenceBuffer();
        return;
      case Complete(:final action):
        _closeSequenceBuffer();
        await perform(action, isRepeat);
        return;
      case PassThroughStandalone(:final action):
        _closeSequenceBuffer();
        await perform(action, isRepeat);
        return;
      case Discard():
        _closeSequenceBuffer();
        return;
      case Unhandled():
        break;
    }
    if (bufferStore.state.isBuffering) return; // stay armed, no-op

    final combo = KeyCombo(
      input.key,
      ctrl: input.ctrl,
      alt: input.alt,
      shift: input.shift,
    );
    final overrides = KeybindCodec.decodeOverrides(
      useAppStore().state.keybindOverridesJson,
    );
    final bool metadataEnabled =
        useAppStore().state.useMetadataSettings && MetaSettingsModule.ready;
    final Map<KeyCombo, PotPlayerAction> effective = resolveEffectiveKeyMap(
      overrides: overrides,
      metadataEnabled: metadataEnabled,
    );
    final action = effective[combo];
    if (action == null) {
      // Strict replacement keeps unbound keys silent — but a modifier stuck
      // by a lost UP event also lands here (plain X reads as Ctrl+X), so
      // surface the resolved combo once per press to keep that class of
      // dead keys diagnosable from the console alone.
      if (!isRepeat) _log.d('key unbound: $combo');
      return;
    }
    if (isRepeat && !kRepeatablePotPlayerActions.contains(action)) return;
    await perform(action, isRepeat);
  }

  Future<bool> _handleMediaKey(LogicalKeyboardKey key) async {
    switch (key) {
      case LogicalKeyboardKey.mediaPlayPause:
        _togglePlayPause();
        return true;
      case LogicalKeyboardKey.mediaTrackPrevious:
        PlaybackProviderRegistry.step(forward: false);
        _showOsd(OsdTexts.previous(getLocalizations(context)));
        return true;
      case LogicalKeyboardKey.mediaTrackNext:
        PlaybackProviderRegistry.step(forward: true);
        _showOsd(OsdTexts.next(getLocalizations(context)));
        return true;
      default:
        return false;
    }
  }

  void _openSequenceBuffer() => useKeySequenceBufferStore().open();

  void _closeSequenceBuffer() => useKeySequenceBufferStore().close();

  // ── Action implementations (legacy-semantics mirrors) ──

  void _togglePlayPause() {
    final t = getLocalizations(context);
    // While the shared controls target 副音 the toggle drives the background
    // runtime through its store (the scope's autoplay-sync applies it to the
    // engine); the foreground autoplay pref must stay untouched.
    if (isBackgroundControlTarget(context)) {
      final bg = useBackgroundPlaybackStore();
      final next = !player.isPlaying;
      bg.setPlaying(next);
      _showOsd(next ? OsdTexts.playing(t) : OsdTexts.paused(t));
      return;
    }
    if (player.isPlaying) {
      useAppStore().updateAutoPlay(false);
      player.pause();
      _showOsd(OsdTexts.paused(t));
    } else {
      useAppStore().updateAutoPlay(true);
      player.play();
      _showOsd(OsdTexts.playing(t));
    }
  }

  int get _stepSeconds => useAppStore().state.seekStepSeconds;

  /// Direct base-step adjust (Ctrl+↑/↓ ±1s, Ctrl+Shift+↑/↓ ±10s) with OSD.
  ///
  /// No window is opened, so every other player shortcut stays live — the user
  /// can adjust then immediately seek. Live-only (no persist) during the hold;
  /// the KeyUp path in [handle] commits once on release.
  void _adjustSeekStep(int delta) {
    final store = useAppStore();
    final int next = (store.state.seekStepSeconds + delta).clamp(1, 120);
    store.updateSeekStepSecondsLive(next);
    _showOsd(OsdTexts.seekStep(next, getLocalizations(context)));
  }

  /// Expected landing position of a relative skip, computed from the same
  /// snapshot the seek itself used (ms precision, clamped to the media).
  /// The snapshot is stale after an async cross-segment jump, so deriving
  /// the display value here keeps the OSD truthful without a second read.
  Duration _clampedRelativeTarget(MediaPlayer player, int deltaMs) {
    final totalMs = player.duration.inMilliseconds;
    if (totalMs <= 0) return player.position;
    return Duration(
        milliseconds:
            (player.position.inMilliseconds + deltaMs).clamp(0, totalMs));
  }

  /// One of the four seek tiers: the jump is `seekStepSeconds × tier multiplier`,
  /// so every tier tracks the user's single base-step setting.
  Future<void> _tierSeek({
    required bool forward,
    required SeekTier tier,
  }) async {
    final t = getLocalizations(context);
    final int seconds = seekTierSeconds(_stepSeconds, tier);
    final int deltaMs = forward ? seconds * 1000 : -seconds * 1000;
    if (forward) {
      await player.forward(seconds);
    } else {
      await player.backward(seconds);
    }
    // The OSD reads the accumulated step intent (set synchronously by the seek
    // path) so a rapid burst shows where the seek is HEADING instead of the
    // stale pre-seek snapshot — which used to read ahead of the picture.
    final int? intentMs = player.stepIntentTargetMs?.call();
    _showOsd(OsdTexts.seek(t,
        delta: Duration(milliseconds: deltaMs),
        position: intentMs == null
            ? _clampedRelativeTarget(player, deltaMs)
            : Duration(milliseconds: intentMs),
        duration: player.duration));
  }

  /// Rate the speed keys act on. 前台与副音共享同一倍率 (1:1): X/C/Z only
  /// mutate the foreground rate, and the 副音 engine follows it through
  /// `background_playback_scope` (bgRateLock). Differential 副音 rate is not
  /// supported here, so there is deliberately no separate 副音 cycle.
  double get _activeRate => useAppStore().state.rate;

  void _stepPlaybackRate(int direction) {
    // Live-only during auto-repeat; handle() commits on KeyUp.
    useAppStore().updateRateLive(
      nextSpeedStop(useAppStore().state.rate, direction, speedStops),
    );
  }

  Future<void> _showPanel(Widget child) =>
      showControlForHover(showPopup(
        context: context,
        child: child,
        direction: useAppStore().state.defaultPopupDirection,
      ));

  // ── Physical delete (Windows-only policy, §5) ──

  /// Identity of the currently playing LOCAL file: the play-queue item plus
  /// the bits the delete path needs — the absolute path for the shell op, and
  /// the storage id + storage-relative path for the DB row / VM-rule matching.
  _LocalMedia? _resolveCurrentLocalMedia() {
    final state = usePlayQueueStore().state;
    for (final item in state.playQueue) {
      if (item.index != state.currentIndex) continue;
      final uri = item.file.uri;
      if (uri.isEmpty || uri.startsWith('http')) return null;
      final relPath = item.file.path.join('/');
      try {
        // `file:` URIs and the legacy '/E:/…' shape both normalize here; the
        // old code's raw string reached `existsSync` unnormalized and silently
        // aborted the whole delete.
        final rawPath =
            uri.startsWith('file:') ? Uri.parse(uri).toFilePath() : uri;
        final path = normalizePathText(rawPath);
        if (!File(path).existsSync()) return null;
        return (
          item: item,
          path: path,
          storageId: item.file.storageId,
          relPath: relPath.isEmpty ? null : relPath,
        );
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Confirms moving the current file to the Recycle Bin.
  ///
  /// Deliberately a plain, ALWAYS-ON dialog: a physical delete is destructive,
  /// so it must never be suppressible through the warning-prefs memory (that
  /// would turn Shift+Delete into a silent permanent delete).
  Future<bool> _confirmPhysicalDelete(String path) async {
    final name = path.split('/').last;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        final t = getLocalizations(dialogCtx);
        final colorScheme = Theme.of(dialogCtx).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.delete_forever_rounded, color: colorScheme.error),
          title: Text(t.recycle_title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.recycle_body(name)),
                const SizedBox(height: 8),
                SelectableText(
                  path,
                  style: Theme.of(dialogCtx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: Text(t.recycle_cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.error,
                foregroundColor: colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: Text(t.recycle_delete),
            ),
          ],
        );
      },
    );
    return ok == true;
  }

  /// Confirms the irreversible permanent-delete fallback (class B1: always
  /// shown, never suppressible). True only when the user explicitly accepts.
  Future<bool> _confirmPermanentDelete(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        final t = getLocalizations(dialogCtx);
        return AlertDialog(
          icon: Icon(Icons.warning_amber_rounded,
              color: Theme.of(dialogCtx).colorScheme.error),
          title: Text(t.recycle_unavailable_title),
          content: Text(t.recycle_unavailable_body(path)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: Text(t.recycle_cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogCtx).colorScheme.error,
                foregroundColor: Theme.of(dialogCtx).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: Text(t.recycle_permanent),
            ),
          ],
        );
      },
    );
    return ok == true;
  }

  /// Captures the frozen chunk boundaries of every enabled VM rule covering the
  /// to-be-deleted file, keyed by ruleId. Captures BOTH feasible and infeasible
  /// (unknown-duration) groups — the latter keep their yellow degraded mark
  /// after the rule is pinned (see `collectPinnedVmChunks`). MUST run while
  /// the file still exists:
  /// once the DB row is gone the rule would already have re-chunked and the
  /// original boundary would be unrecoverable. Does NOT activate the freeze —
  /// the caller seeds it only after the delete actually succeeds, so an aborted
  /// delete never leaves boundaries frozen.
  Future<Map<String, List<PinnedVmChunk>>> _captureVmChunks(
      String storageId, String? relPath) async {
    if (storageId.isEmpty || relPath == null || relPath.isEmpty) return const {};
    if (!VirtualMediaGate.enabled) return const {};
    final rules =
        await VirtualMediaService.instance.coveringRulesFor(storageId, relPath);
    if (rules.isEmpty) return const {};

    final store = usePlaybackScenarioStore();
    final scenarioId = store.state.activeScenarioId;
    if (scenarioId == null) return const {};
    final ruleIds = {for (final r in rules) r.id};
    try {
      final groups = await store.resolver.resolveVmGroupsFor(
        scenarioId,
        playbackVersion: store.state.playbackVersion,
      );
      return collectPinnedVmChunks(groups, ruleIds);
    } catch (e) {
      _log.w('vm boundary capture failed: $e');
      return const {};
    }
  }

  /// Applies the delete across every layer so nothing can re-feed the dead
  /// source: removes the `media_nodes` row in the storage's whole scope family,
  /// drops it from the queue (and from a scenario's explicit includes), ends a
  /// VM session that fed it, bumps the revisions (PRESERVING the VM boundary
  /// freeze), then advances to the next PLAYABLE item.
  ///
  /// [wasPlaying] drives the non-scenario continuation: the queue's `[file]`
  /// effect opens the next entry with `play: autoPlay`, so autoplay is re-armed
  /// when the user was actually watching.
  Future<void> _removeDeletedMediaAndAdvance(
    _LocalMedia media, {
    required bool wasPlaying,
  }) async {
    final scenarioMode = PlaybackProviderRegistry.scenarioModeActive;
    final tagView = PlaybackProviderRegistry.tagViewDriving;
    final scenarioProvider = PlaybackProviderRegistry.scenario;
    final vmWasActive = VirtualMediaController.instance.isActive;
    // Snapshot the surviving VM group BEFORE the DB row disappears, so a
    // resolver cache serving the pre-delete stream cannot hide it. Guarded:
    // scenario mode without an active scenario must not throw out of a keybind.
    final vmCurrent = (scenarioMode && vmWasActive)
        ? await _safeScenarioCurrent(scenarioProvider)
        : null;

    // Scope family FIRST: a node row can live under a sibling entry's scope
    // (same physical tree, independent `data_scope_id`), so a scope-only WHERE
    // silently deleted 0 rows while the file was already gone from disk.
    final scopes = <String>{...StorageScope.familyOf(media.storageId)};
    if (media.storageId.isNotEmpty && media.relPath != null) {
      try {
        scopes.addAll(await DbModule.mediaNodesDao.scopesContainingPath(
          storageId: media.storageId,
          candidateScopes: scopes,
          rawPath: media.relPath!,
        ));
      } catch (e) {
        _log.w('scope probe failed: $e');
      }
    }

    var removedRows = 0;
    if (media.storageId.isNotEmpty && media.relPath != null) {
      try {
        removedRows = await DbModule.mediaNodesDao.deleteNodeAcrossScopes(
          storageId: media.storageId,
          scopeIds: scopes,
          rawPath: media.relPath!,
        );
        if (removedRows == 0) {
          // The file IS gone: still hide any stale row across the family rather
          // than leaving a ghost the queue can resolve and play again.
          await DbModule.mediaNodesDao.markNodeAbsentAcrossScopes(
            storageId: media.storageId,
            scopeIds: scopes,
            rawPath: media.relPath!,
          );
        }
      } catch (e) {
        _log.w('media node delete failed: $e');
      }
    }
    if (media.storageId.isNotEmpty && media.relPath != null && removedRows == 0) {
      _log.w('physical delete: no media_nodes row matched '
          'storage=${media.storageId} path=${media.relPath} '
          'scopes=${scopes.join(",")}');
    }

    // A scenario EXPLICIT include is path-keyed and would otherwise stay in the
    // queue forever (a folder-source item disappears with its row).
    await _removeDeletedExplicitInclude(media);

    if (shouldContinueQueuePlaybackAfterDelete(
      scenarioMode: scenarioMode,
      wasPlaying: wasPlaying,
    )) {
      // Set autoplay BEFORE the removal so the [file] effect opens the advanced
      // entry playing (legacy mode has no scenario resume effect to restart it).
      try {
        await useAppStore().updateAutoPlay(true);
      } catch (_) {}
    }
    if (!scenarioMode) {
      try {
        await usePlayQueueStore().remove(media.item);
      } catch (_) {}
    }

    if (vmWasActive) {
      try {
        await VirtualMediaController.instance.stop();
      } catch (_) {}
    }

    if (scopes.isNotEmpty) {
      // Bump every family scope: an index over the OTHER entry would otherwise
      // keep serving the deleted row.
      await MediaRevisionActions.mediaNodesChanged(
        scopes,
        preserveVirtualMediaBoundaries: true,
      );
    }

    try {
      if (tagView) {
        // The tag controller owns its own cursor/feed; its next() skips the
        // dead member (the row is gone, so the member resolves unavailable).
        await PlaybackProviderRegistry.step(forward: true);
      } else if (scenarioMode) {
        final skipKey = media.relPath == null
            ? const <String>{}
            : {canonicalKey(media.storageId, media.relPath!)};
        // Removing the current occurrence advances to the next entry
        // (队尾 -> stop). A STALE index can still hand back the deleted
        // occurrence; the skip set makes the advance walk past it instead of
        // re-persisting and re-feeding the dead file (which kept playing from
        // the backend's still-open handle).
        final advanced =
            await scenarioProvider.revalidateCurrent(skipMediaKeys: skipKey);
        // A merged group that survived keeps its representative: the revalidate
        // above did NOT re-feed it, so restart the session on the frozen
        // (shrunk) segment list.
        if (vmCurrent != null) {
          await PlaybackProviderRegistry.resumeActive();
        } else if (!advanced) {
          // Nothing survived: unload the feed so the deleted file's handle is
          // released instead of sitting paused behind an empty queue.
          await PlaybackProviderRegistry.stop();
        }
      }
    } catch (e) {
      _log.w('advance after delete failed: $e');
    }
  }

  /// Drops a scenario EXPLICIT include of the deleted path.
  ///
  /// Matched by the storage-relative key, not by storage id: the include may
  /// have been written through a sibling entry for the same tree.
  Future<void> _removeDeletedExplicitInclude(_LocalMedia media) async {
    if (!PlaybackProviderRegistry.scenarioModeActive) return;
    if (media.storageId.isEmpty || media.relPath == null) return;
    final store = usePlaybackScenarioStore();
    final scenarioId = store.state.activeScenarioId;
    if (scenarioId == null) return;
    try {
      final key = StoragePathCodec.relativeKey(media.storageId, media.relPath!);
      final items = await store.getExplicitItems(scenarioId);
      final ids = <int>[
        for (final item in items)
          if (StoragePathCodec.relativeKey(item.storageId, item.path) == key)
            item.id,
      ];
      if (ids.isNotEmpty) await store.removeExplicitIncludes(ids);
    } catch (e) {
      _log.w('remove explicit include failed: $e');
    }
  }

  Future<PlaybackEntry?> _safeScenarioCurrent(
      ScenarioPlaybackProvider provider) async {
    try {
      return await provider.current();
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteCurrentFileToRecycleBin() async {
    if (!isDesktop || !Platform.isWindows) return; // policy: Windows only
    final media = _resolveCurrentLocalMedia();
    if (media == null) {
      if (context.mounted) {
        _showOsd(OsdTexts.deleteUnavailable(getLocalizations(context)));
      }
      return;
    }
    if (!context.mounted) return;

    final confirmed = await _confirmPhysicalDelete(media.path);
    if (!confirmed) return;
    if (!context.mounted) return;

    // Capture (but do not yet activate) the VM boundaries of every rule the
    // file belongs to, while the file is still present.
    final vmChunks = await _captureVmChunks(media.storageId, media.relPath);

    // Pause first so the shell move does not fight a live decode; the backend
    // keeps the (renamed) file open, which is why the feed is unloaded AFTER
    // the DB row is gone (see _removeDeletedMediaAndAdvance).
    final wasPlaying = player.isPlaying;
    await player.pause();

    var deleted = moveFileToRecycleBin(media.path);
    if (!deleted) {
      // Recycle bin unavailable — permanent delete is irreversible, so this
      // confirmation is ALWAYS shown and never suppressible (class B1).
      final permanentOk = await _confirmPermanentDelete(media.path);
      if (!permanentOk) {
        if (wasPlaying) await player.play();
        return;
      }
      try {
        await File(media.path).delete();
        deleted = true;
      } catch (e) {
        _log.e('permanent delete failed: $e '
            '(recycle code=$deleteFileToRecycleBinLastFailure)');
      }
    }
    if (!deleted) {
      if (wasPlaying) await player.play();
      if (context.mounted) {
        final t = getLocalizations(context);
        await showMessageDialog(
          Navigator.of(context, rootNavigator: true),
          type: MessageDialogType.error,
          title: t.physical_delete_failed_title,
          message: t.physical_delete_failed_body(
            deleteFileToRecycleBinLastFailure,
          ),
        );
      }
      return;
    }

    // Freeze the captured boundaries and excise the member so only its own
    // chunk shrinks — neighbouring chunks / other rules stay intact.
    final mediaKey = media.storageId.isNotEmpty && media.relPath != null
        ? canonicalKey(media.storageId, media.relPath!)
        : null;
    for (final entry in vmChunks.entries) {
      VmMembershipPin.instance.seedRule(entry.key, entry.value);
      if (mediaKey != null) {
        VmMembershipPin.instance.removeMember(entry.key, mediaKey);
      }
    }

    await _removeDeletedMediaAndAdvance(media, wasPlaying: wasPlaying);
    if (context.mounted) {
      _showOsd(OsdTexts.deleted(getLocalizations(context)));
    }
  }

  // ── Reveal the playing file in Explorer (Windows right-click menu) ──

  /// Opens Explorer at the currently fed file's folder, selecting the file.
  ///
  /// The play queue always carries the item the player is fed — legacy,
  /// scenario, tag-view and virtual-media segment feeds all go through
  /// `update(playQueue: …)` — so this is the same identity the queue/history
  /// popups reveal. A missing file degrades to its folder through the shared
  /// service; a hard failure surfaces its dialog. The menu entry is already
  /// gated on revealability, so an inapplicable race stays a silent no-op.
  Future<void> _revealCurrentFileInExplorer() async {
    if (!isDesktop || !Platform.isWindows) return;
    final file = await usePlayQueueStore().getCurrentFile();
    if (file.uri.isEmpty && file.name.isEmpty) return;
    if (!context.mounted) return;
    await revealFileInExplorer(context, file);
  }

  // ── Frame capture (mediaKit-only, F1) — shared playback_tools service ──

  Future<void> _captureFrame() async {
    final t = getLocalizations(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final result = await runScreenshotCapture(
      navigator: navigator,
      player: player,
      savingLabel: t.shot_saving,
    );
    switch (result) {
      case ScreenshotSuccess(:final path):
        _showOsd(OsdTexts.screenshot(path, t));
      case ScreenshotFailure(:final kind, :final detail):
        _log.w('screenshot failed: $kind ${detail ?? ''}');
        _showOsd(OsdTexts.screenshotFailed(t));
      case ScreenshotUnsupported():
        // Desktop keeps OSD for outcomes, but a backend that can NEVER
        // capture deserves an actionable dialog, not a toast.
        await showScreenshotFeedback(navigator, result);
    }
  }

  /// Shared OSD gate — desktop-only, PotPlayer-style (left/top, 9-grid).
  /// Respects `osd.enabled` + `osd.visibilityMode` (hideWhenControlVisible).
  void _showOsd(OsdEntry entry) {
    if (!isDesktop) return;
    final app = useAppStore().state;
    final enabled = app.useMetadataSettings && MetaSettingsModule.ready;
    if (!resolveOsdShouldShow(
      app,
      enabled,
      isShowControl: usePlayerUiStore().state.isShowControl,
    )) {
      return;
    }
    useOsdStore().show(
      entry,
      duration: Duration(milliseconds: app.osdDurationMs.clamp(800, 5000)),
    );
  }

  Future<void> perform(PotPlayerAction action, bool isRepeat) async {
    // Captured once per action for OSD/dialog text; the context itself must
    // not cross async gaps (file carries use_build_context_synchronously
    // ignore for pre-existing patterns).
    final t = getLocalizations(context);
    switch (action) {
      case PotPlayerAction.tagChordAdd:
        if (!TagPlayGate.enabled) {
          final navigator = Navigator.of(context, rootNavigator: true);
          await showMessageDialog(
            navigator,
            message: t.tag_gate_meta_body,
            type: MessageDialogType.info,
          );
          break;
        }
        await showControlForHover(
            openTagPlaySheet(context, initialCommand: '+'));
        break;
      case PotPlayerAction.tagChordRemove:
        if (!TagPlayGate.enabled) {
          final navigator = Navigator.of(context, rootNavigator: true);
          await showMessageDialog(
            navigator,
            message: t.tag_gate_meta_body,
            type: MessageDialogType.info,
          );
          break;
        }
        await showControlForHover(
            openTagPlaySheet(context, initialCommand: '-'));
        break;
      case PotPlayerAction.tagChordSwitchView:
        if (!TagPlayGate.enabled) {
          final navigator = Navigator.of(context, rootNavigator: true);
          await showMessageDialog(
            navigator,
            message: t.tag_gate_meta_body,
            type: MessageDialogType.info,
          );
          break;
        }
        if (!TagPlayGate.viewSwitchingEnabled) {
          final navigator = Navigator.of(context, rootNavigator: true);
          await showMessageDialog(
            navigator,
            message: t.tag_gate_scenario_body,
            type: MessageDialogType.info,
          );
          break;
        }
        await showControlForHover(
            openTagPlaySheet(context, initialCommand: '*'));
        break;
      case PotPlayerAction.playPause:
        _togglePlayPause();
        break;
      case PotPlayerAction.previousItem:
        PlaybackProviderRegistry.step(forward: false);
        AbLoopEngine.instance.reset();
        _showOsd(OsdTexts.previous(t));
        break;
      case PotPlayerAction.nextItem:
        PlaybackProviderRegistry.step(forward: true);
        AbLoopEngine.instance.reset();
        _showOsd(OsdTexts.next(t));
        break;
      case PotPlayerAction.frameBackward:
        await player.stepBackward();
        _showOsd(OsdTexts.frame(false, t));
        break;
      case PotPlayerAction.frameForward:
        await player.stepForward();
        _showOsd(OsdTexts.frame(true, t));
        break;

      // OSD shows the COMPUTED landing target (ms, clamped): the injected
      // MediaPlayer snapshot's position is stale after a cross-segment jump
      // (the open completes asynchronously), so re-reading it displays the
      // pre-seek position instead of where playback is heading.
      case PotPlayerAction.seekBackward:
        await _tierSeek(forward: false, tier: SeekTier.small);
        break;
      case PotPlayerAction.seekForward:
        await _tierSeek(forward: true, tier: SeekTier.small);
        break;
      case PotPlayerAction.bigSeekBackward:
        await _tierSeek(forward: false, tier: SeekTier.medium);
        break;
      case PotPlayerAction.bigSeekForward:
        await _tierSeek(forward: true, tier: SeekTier.medium);
        break;
      case PotPlayerAction.largeSeekBackward:
        await _tierSeek(forward: false, tier: SeekTier.large);
        break;
      case PotPlayerAction.largeSeekForward:
        await _tierSeek(forward: true, tier: SeekTier.large);
        break;
      case PotPlayerAction.hugeSeekBackward:
        await _tierSeek(forward: false, tier: SeekTier.huge);
        break;
      case PotPlayerAction.hugeSeekForward:
        await _tierSeek(forward: true, tier: SeekTier.huge);
        break;
      case PotPlayerAction.seekStepPopover:
        // Menu-only (Windows right-click > Playback): share the More-menu
        // popover so the visual is identical; anchor to the More button when
        // present. NOT key-bound — see SeekStepIncrease/Decrease below.
        showControl();
        await showControlForHover(
            showSeekStepPopover(moreMenuKeyNotifier.value?.currentContext ?? context));
        break;
      case PotPlayerAction.seekStepIncrease:
        _adjustSeekStep(HardwareKeyboard.instance.isShiftPressed ? 10 : 1);
        break;
      case PotPlayerAction.seekStepDecrease:
        _adjustSeekStep(HardwareKeyboard.instance.isShiftPressed ? -10 : -1);
        break;
      case PotPlayerAction.restart:
        AbLoopEngine.instance.reset();
        _showOsd(OsdTexts.seekTo(t, Duration.zero, player.duration));
        await player.seek(Duration.zero);
        break;
      case PotPlayerAction.jumpToTime:
        await showControlForHover(showJumpToTimeDialog(context, player));
        break;

      case PotPlayerAction.volumeUp:
        await useAppStore().updateVolume(useAppStore().state.volume + 1);
        _showOsd(OsdTexts.volume(useAppStore().state.volume, t));
        break;
      case PotPlayerAction.volumeDown:
        await useAppStore().updateVolume(useAppStore().state.volume - 1);
        _showOsd(OsdTexts.volume(useAppStore().state.volume, t));
        break;
      case PotPlayerAction.mute:
        await useAppStore().toggleMute();
        _showOsd(OsdTexts.mute(useAppStore().state.isMuted, t));
        break;
      case PotPlayerAction.speedDown:
        _stepPlaybackRate(-1);
        _showOsd(OsdTexts.speed(_activeRate, t));
        break;
      case PotPlayerAction.speedUp:
        _stepPlaybackRate(1);
        _showOsd(OsdTexts.speed(_activeRate, t));
        break;
      case PotPlayerAction.speedReset:
        // 前台/副音 1:1: Z also only resets the foreground rate; the 副音
        // engine follows through bgRateLock (see _activeRate).
        final s = useAppStore().state;
        final (:rate, :memory) =
            resolveSpeedResetToggle(s.rate, s.rateBeforeReset);
        await useAppStore().applySpeedReset(rate, memory);
        _showOsd(
            OsdTexts.speed(useAppStore().state.rate, t, reset: rate == 1.0));
        break;
      case PotPlayerAction.fitCycle:
        // Metadata era: the fit key cycles the platform display mode
        // (with the two original-size modes on desktop) + OSD feedback;
        // legacy era keeps the 4-way BoxFit cycle untouched.
        if (useAppStore().state.useMetadataSettings && MetaSettingsModule.ready) {
          await useAppStore().cycleVideoDisplayMode();
          final app = useAppStore().state;
          _showOsd(OsdTexts.videoDisplayMode(
              isMobilePlatform
                  ? mobileVideoDisplayModeLabel(app.mobileDisplayMode, t)
                  : desktopVideoDisplayModeLabel(app.desktopDisplayMode, t),
              t));
          break;
        }
        await useAppStore().toggleFit(); // D6-adjacent: J parity via fit cycle
        _showOsd(OsdTexts.fit(useAppStore().state.fit.name, t));
        break;

      // ── P0: track cycling / visibility ──
      case PotPlayerAction.cycleSubtitleTrack:
        await player.cycleSubtitleTrack();
        _showOsd(OsdTexts.subtitleTrack('switched', t));
        break;
      case PotPlayerAction.cycleAudioTrack:
        await player.cycleAudioTrack();
        _showOsd(OsdTexts.audioTrack('switched', t));
        break;
      case PotPlayerAction.toggleSubtitleVisibility:
        final nextVisible = !player.subtitlesVisible;
        await player.setSubtitlesVisible(nextVisible);
        _showOsd(OsdTexts.subtitleVisibility(nextVisible, t));
        break;

      // ── P0: sync triads (silent no-ops on backends without the property) ──
      case PotPlayerAction.subtitleSyncForward:
        await player.nudgeSubtitleSync(1);
        _showOsd(OsdTexts.subtitleSync(0.5, t));
        break;
      case PotPlayerAction.subtitleSyncBackward:
        await player.nudgeSubtitleSync(-1);
        _showOsd(OsdTexts.subtitleSync(-0.5, t));
        break;
      case PotPlayerAction.subtitleSyncReset:
        await player.resetSubtitleSync();
        _showOsd(OsdTexts.subtitleSync(0, t));
        break;
      case PotPlayerAction.audioSyncForward:
        await player.nudgeAudioSync(1);
        _showOsd(OsdTexts.audioSync(0.5, t));
        break;
      case PotPlayerAction.audioSyncBackward:
        await player.nudgeAudioSync(-1);
        _showOsd(OsdTexts.audioSync(-0.5, t));
        break;
      case PotPlayerAction.audioSyncReset:
        await player.resetAudioSync();
        _showOsd(OsdTexts.audioSync(0, t));
        break;

      // ── P0: quick jumps (ms precision: second-truncation can land a
      // segment boundary on the wrong side of a virtual merge) ──
      case PotPlayerAction.jumpToMiddle:
        final duration = player.duration;
        if (duration > Duration.zero) {
          final mid =
              Duration(milliseconds: duration.inMilliseconds ~/ 2);
          _showOsd(OsdTexts.seekTo(t, mid, duration));
          await player.seek(mid);
        }
        break;
      case PotPlayerAction.jumpNearEnd:
        final duration = player.duration;
        if (duration > Duration.zero) {
          final remainingMs = duration.inMilliseconds - 30000;
          final target =
              Duration(milliseconds: remainingMs > 0 ? remainingMs : 0);
          _showOsd(OsdTexts.seekTo(t, target, duration));
          await player.seek(target);
        }
        break;

      // ── Physical delete: Windows playback view only (capability_matrix §5) ──
      case PotPlayerAction.deletePhysicalFile:
        await _deleteCurrentFileToRecycleBin();
        break;

      // ── Frame capture: mediaKit-only (F1); other backends no-op ──
      case PotPlayerAction.screenshotFrame:
        await _captureFrame();
        break;

      // ── A-B section repeat (engine owns points + loop-back seek; the
      // player hooks own its lifecycle binding — no ensureBound here) ──
      case PotPlayerAction.abSetPointA:
        AbLoopEngine.instance.dispatch(AbEvent.setPointA, player.position);
        _showOsd(OsdTexts.abPointA(player.position));
        break;
      case PotPlayerAction.abSetPointB:
        AbLoopEngine.instance.dispatch(AbEvent.setPointB, player.position);
        _showOsd(OsdTexts.abPointB(player.position));
        break;
      case PotPlayerAction.abQuickToggle:
        AbLoopEngine.instance.dispatch(AbEvent.quickToggle, player.position);
        final q = useAbLoopStore().state;
        _showOsd(OsdTexts.abLoop(q.enabled, q.pointA, q.pointB, t));
        break;
      case PotPlayerAction.abToggleSectionRepeat:
        AbLoopEngine.instance
            .dispatch(AbEvent.toggleSectionRepeat, player.position);
        final ab = useAbLoopStore().state;
        _showOsd(OsdTexts.abLoop(ab.enabled, ab.pointA, ab.pointB, t));
        break;

      case PotPlayerAction.subtitlesPanel:
      case PotPlayerAction.audioTracksPanel:
        await _showPanel(Provider<MediaPlayer>.value(
          value: player,
          child: const SubtitleAndAudioTrack(),
        ));
        break;
      case PotPlayerAction.settings:
        await _showPanel(const Settings());
        break;
      case PotPlayerAction.playQueue:
        {
          final app = useAppStore().state;
          final isDock = isDesktop &&
              app.useMetadataSettings &&
              !app.useLegacyStoragePersistence &&
              app.playlistPanelMode == PlaylistPanelMode.dockedRight;
          if (isDock) {
            await useAppStore().togglePlaylistPanelVisible();
            _showOsd(OsdTexts.dockVisibility(
                useAppStore().state.playlistPanelVisible, t));
          } else {
            await _showPanel(const PlayQueue());
          }
        }
        break;
      case PotPlayerAction.togglePlaylistDockMode:
        {
          await useAppStore().togglePlaylistPanelMode();
          final isDocked = useAppStore().state.playlistPanelMode == PlaylistPanelMode.dockedRight;
          _showOsd(OsdTexts.dockMode(isDocked, t));
        }
        break;
      case PotPlayerAction.storagesBrowser:
        await _showPanel(const Storages());
        break;
      case PotPlayerAction.historyPanel:
        await _showPanel(const History());
        break;
      case PotPlayerAction.moreMenu:
        showControl();
        moreMenuKeyNotifier.value?.currentState?.showButtonMenu();
        break;

      case PotPlayerAction.openFile:
        await pickLocalFile();
        break;
      case PotPlayerAction.openLink:
        isDesktop
            ? await showOpenLinkDialog(context)
            : await showOpenLinkBottomSheet(context);
        break;
      case PotPlayerAction.revealCurrentFileInExplorer:
        await _revealCurrentFileInExplorer();
        break;
      case PotPlayerAction.closePlayback:
        player.pause();
        PlaybackProviderRegistry.stop();
        AbLoopEngine.instance.reset();
        _showOsd(OsdTexts.playbackClosed(t));
        break;
      case PotPlayerAction.toggleRepeatMode:
        await PlaybackProviderRegistry.toggleRepeat();
        _showOsd(OsdTexts.repeat(useAppStore().state.repeat.name, t));
        break;
      case PotPlayerAction.toggleShuffleMode:
        await PlaybackProviderRegistry.toggleShuffle();
        _showOsd(OsdTexts.shuffle(useAppStore().state.shuffle, t));
        break;
      case PotPlayerAction.alwaysOnTop:
        await usePlayerUiStore().toggleIsAlwaysOnTop();
        _showOsd(OsdTexts.alwaysOnTop(usePlayerUiStore().state.isAlwaysOnTop, t));
        break;
      case PotPlayerAction.toggleAutoResize:
        // Metadata era: Ctrl+R toggles the WindowFitMode enum (窗口适应视频 /
        // 固定窗口大小). Legacy era keeps the autoResize checkbox semantics.
        if (useAppStore().state.useMetadataSettings && MetaSettingsModule.ready) {
          await useAppStore().toggleWindowFitMode();
          final fitVideo =
              useAppStore().state.windowFitMode == WindowFitMode.fitVideo;
          _showOsd(OsdTexts.windowFitMode(t, fitVideo: fitVideo));
          break;
        }
        await useAppStore().toggleAutoResize();
        final autoOn = useAppStore().state.autoResize;
        _showOsd(OsdTexts.autoFit(autoOn, t));
        break;
      case PotPlayerAction.fullscreen:
        if (isDesktop) {
          final next = !usePlayerUiStore().state.isFullScreen;
          await usePlayerUiStore().updateFullScreen(next);
          _showOsd(OsdTexts.fullscreen(next, t));
        }
        break;
      case PotPlayerAction.exitFullscreen:
        if (isDesktop && usePlayerUiStore().state.isFullScreen) {
          await usePlayerUiStore().updateFullScreen(false);
          _showOsd(OsdTexts.fullscreen(false, t));
        }
        break;
      case PotPlayerAction.exitApp:
        await AppExit.run(player.saveProgress);
        break;
    }
  }
}
