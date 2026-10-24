import 'dart:async';

import 'package:flutter/material.dart';
import 'package:iris/features/app_instance/model/new_window_request.dart';
import 'package:iris/features/media_library/store/use_media_lib_browser_store.dart';
import 'package:iris/features/media_library/view/content/store/use_media_lib_content_store.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/globals.dart' as globals;
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/widgets/popup.dart';
import 'package:iris/widgets/popups/storages/db/storages_db.dart';
import 'package:iris/widgets/popups/storages/storages.dart';

final _log = AreaKeyLog(LogKeys.legacyScenario);

bool _applied = false;

/// Clears the one-shot latch between test cases.
///
/// The latch is process-wide (one isolate per window) and normally flips once
/// per window, so a test that exercises [applyStartupOpenRequest] has to reset
/// it or the next case inherits a "consumed" window.
@visibleForTesting
void resetStartupOpenRequestLatch() => _applied = false;

/// Test seam: awaited after the intent was decided and BEFORE it is applied.
///
/// The window's context can die WHILE the stores are loading (the Home page is
/// replaced, the window is torn down). The intent then cannot be applied and
/// must not report itself as consumed. The seam lets a test reproduce that
/// mid-flight unmount deterministically instead of racing the real stores.
@visibleForTesting
Future<void> Function()? debugBeforeApply;

/// Resets the test seam between test cases.
@visibleForTesting
void resetStartupOpenRequestSeam() => debugBeforeApply = null;

/// Whether [request] carries an action this window can actually replay.
///
/// A default-constructed request (e.g. `{"sort":[...]}` only) parses fine but
/// has nothing to open or play. Consuming it would skip the generic startup
/// resume and leave a blank window, so it must be treated as "no request".
///
/// An entry with an EMPTY `storageId` is not an action either: `{"files":[{}]}`
/// deserializes to one all-default [NewWindowFile], and replaying it can only
/// fail (`playSelectionInDefaultScenario` resolves every file through
/// `storageId + path`, and its playability pre-check throws for an unknown
/// storage). Treating that as "consumed" showed the play-failed dialog AND
/// skipped the resume the window should have run.
@visibleForTesting
bool startupRequestHasAction(NewWindowRequest request) =>
    _hasText(request.scenarioId) ||
    _hasText(request.libraryId) ||
    _hasText(request.openStorageId) ||
    _hasText(request.startFile?.storageId) ||
    request.folders.any((f) => _hasText(f.storageId)) ||
    request.files.any((f) => _hasText(f.storageId));

bool _hasText(String? value) => value != null && value.isNotEmpty;

/// Replays the `--open-request` payload of a window spawned by
/// [NewWindowLauncher], using the SAME scenario actions the source window's
/// entry would have run.
///
/// Returns true when a request was present (and consumed) so the caller skips
/// the generic startup resume — a window opened with an explicit intent must not
/// also restore whichever queue its session happened to hold.
///
/// CONTRACT: the one-shot latch means "this window CONSUMED an intent". An
/// intent that was never fully applied (unknown id, vanished row, failed
/// store write) must NOT report itself as consumed: the caller would skip the
/// generic resume and the window would neither play nor open anything. Every
/// such path clears the latch and returns false.
///
/// Runs from Home's one-shot startup effect: database + stores are ready, and a
/// Navigator exists for the browser/dialog surfaces.
Future<bool> applyStartupOpenRequest(BuildContext context) async {
  // Already consumed by this window: still report "consumed" so a caller that
  // runs again (a remounted Home) cannot fall through to the generic resume
  // and replay/overwrite the queue the intent already installed.
  if (_applied) return true;
  final NewWindowRequest? request = NewWindowRequest.parse(globals.arguments);
  if (request == null) return false;
  // A payload with no action must NOT mark itself consumed: returning false lets
  // the caller run the generic startup resume instead of showing a blank window.
  if (!startupRequestHasAction(request)) {
    _log.w('startup open request carried no action; using the normal resume');
    return false;
  }
  // Do NOT consume a request this (unmounted) context cannot apply: returning
  // false lets the caller fall back to the generic startup resume instead of
  // showing a blank window that neither played nor opened anything.
  if (!context.mounted) return false;
  _applied = true;
  _log.i('startup open request: ${request.describe()}');

  try {
    final scenarioStore = usePlaybackScenarioStore();
    await scenarioStore.ensureReady();
    await useStorageStore().initialized;
    // Test seam (no-op in production): lets a test unmount the context
    // between the decision and the application.
    await debugBeforeApply?.call();

    // Scenario tile: activate it and resume per the playback policy.
    final String? scenarioId = request.scenarioId;
    if (scenarioId != null) {
      if (!context.mounted) {
        // Same contract as the file/selection branches below: an intent this
        // (dead) window cannot apply must not report itself as consumed, or
        // the caller skips the generic startup resume.
        _applied = false;
        return false;
      }
      // The scenario must still exist IN THIS WINDOW. A stale id (the row was
      // deleted between spawn and apply) would otherwise be activated as an
      // empty workspace: the intent would count as consumed, the generic
      // resume would be skipped and the window would sit empty. The mirror is
      // also the ownership filter — a foreign playing workspace is not listed
      // here and must not be adopted.
      final known = scenarioStore.state.scenarios.any((s) => s.id == scenarioId);
      if (!known) {
        _log.w('startup open request scenario $scenarioId is gone; '
            'using the normal resume');
        _applied = false;
        return false;
      }
      await scenarioStore.setActiveScenario(scenarioId);
      await ScenarioPlaybackActions.resumeScenarioPlayback();
      return true;
    }

    // Library tile: OPEN the library, do not play it.
    final String? libraryId = request.libraryId;
    if (libraryId != null) {
      if (!context.mounted) {
        // Same contract as above: the store write belongs to a live window.
        _applied = false;
        return false;
      }
      // The row may have been deleted in ANOTHER window between the spawn and
      // this apply. Adopting a stale id consumed the intent while opening
      // nothing: the content store accepts any id, the browser shows an empty
      // library and the generic resume is skipped. Fall back like the
      // scenario/storage branches do.
      final library = await DbModule.mediaFacade.getLibraryById(libraryId);
      if (library == null) {
        _log.w('startup open request library $libraryId is gone; '
            'using the normal resume');
        _applied = false;
        return false;
      }
      await useMediaLibContentStore().initialized;
      await useMediaLibContentStore().setLibrary(libraryId);
      useMediaLibBrowserStore().openLibContent();
      if (context.mounted) _showBrowser(context);
      return true;
    }

    // Favorites entry: OPEN the folder, do not play it.
    final String? openStorageId = request.openStorageId;
    if (openStorageId != null) {
      final storage = useStorageStore().findById(openStorageId);
      if (storage == null) {
        // The row vanished between spawn and apply: do NOT consume the
        // request silently (that left a window that neither opened nor
        // resumed anything). Fall back to the generic startup resume.
        _log.w('startup open request storage $openStorageId is gone; '
            'using the normal resume');
        // The latch means "an intent was consumed" and this path consumed
        // nothing: leaving it set made a later call (a remounted Home) report
        // a consumed request and skip the generic resume it never got.
        _applied = false;
        return false;
      }
      await useStorageStore().updateCurrentStorage(storage);
      await useStorageStore()
          .updateCurrentPath(request.openPath ?? const <String>[]);
      if (context.mounted) _showBrowser(context);
      return true;
    }

    if (!request.isPlaybackRequest) return true;

    // File row: play its folder scope and land on the file (same as tapping it).
    // An empty `storageId` is a malformed entry, not a row: fall through to the
    // selection branch so a mixed payload still plays its valid entries.
    final NewWindowFile? start = request.startFile;
    if (start != null && start.storageId.isNotEmpty) {
      if (!context.mounted) {
        // The context died while the stores were loading: the intent was NOT
        // applied, so it must not report "consumed" — the caller would skip
        // the generic resume and the window would neither play nor open.
        // The latch is cleared for the same reason as the storage-gone branch
        // above: nothing was consumed.
        _applied = false;
        return false;
      }
      await ScenarioPlaybackActions.playFolderScopeInDefaultScenario(
        storageId: start.storageId,
        folderPath: request.startFolderPath ?? '',
        tapped: start.toFileItem(),
        itemPath: request.startItemPath,
        sortField: request.sortField,
        sortDirection: request.sortDirection,
        gateContext: context,
      );
      return true;
    }

    // Selection / folder / whole storage: directory sources first, then explicit
    // files — the selection-override contract. [startupRequestHasAction] already
    // guarantees at least one of them is present. Entries without a storageId
    // are dropped here too: a payload may mix a valid row with an all-default
    // one, and the invalid entry would only fail the playability pre-check.
    if (!context.mounted) {
      // Same contract as the file-row branch above: an unapplied intent is
      // not a consumed one, so the generic startup resume still runs.
      _applied = false;
      return false;
    }
    await ScenarioPlaybackActions.playSelectionInDefaultScenario(
      files: [
        for (final f in request.files)
          if (f.storageId.isNotEmpty) f.toFileItem(),
      ],
      directories: [
        for (final d in request.folders)
          if (d.storageId.isNotEmpty)
            (
              storageId: d.storageId,
              path: d.path,
              recursive: d.recursive,
              kind: ScenarioSourceKind.folder,
            ),
      ],
      sortField: request.sortField,
      sortDirection: request.sortDirection,
      gateContext: context,
    );
    return true;
  } catch (e) {
    // An exception means the intent was NOT fully applied (a store write
    // failed, the player refused the media, ...). It must not report itself as
    // consumed: the caller would skip the generic startup resume and the
    // window would stay empty. The latch is cleared for the same reason as the
    // storage-gone branch above — nothing was consumed.
    _applied = false;
    _log.e('startup open request failed: $e');
    if (context.mounted) {
      await _showPlayFailedDialog(context);
    }
    return false;
  }
}

/// Opens the storage browser popup (the library/scenario sub-interfaces render
/// inside it). Never awaited: the popup lives until the user closes it.
void _showBrowser(BuildContext context) {
  unawaited(showPopup(
    context: context,
    child: useAppStore().state.useLegacyStoragePersistence
        ? const Storages()
        : const StoragesDb(),
    direction: useAppStore().state.defaultPopupDirection,
  ));
}

Future<void> _showPlayFailedDialog(BuildContext context) async {
  final t = getLocalizations(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.new_window_play_failed_title),
      content: Text(t.new_window_play_failed_body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t.ok),
        ),
      ],
    ),
  );
}
