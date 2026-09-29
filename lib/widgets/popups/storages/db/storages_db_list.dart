import 'dart:async';

import 'package:flutter/material.dart';

import 'package:iris/widgets/a11y_tooltip.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart'
    show SortDirection;
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
import 'package:iris/features/media_library/scan/service/scan_preflight.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/media_library/scan/view/scan_options_dialog.dart';
import 'package:iris/features/media_library/services/local_storage_discovery.dart';
import 'package:iris/features/scenario_playback/actions/media_revision_actions.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/webdav_discovery/services/webdav_connect_coordinator.dart';
import 'package:iris/features/webdav_discovery/view/gated_webdav_connect.dart';
import 'package:iris/features/webdav_discovery/view/webdav_connect_loop.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/enums/webdav_scan_mode.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/storages/webdav.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/widgets/dialogs/show_folder_dialog.dart';
import 'package:iris/widgets/dialogs/show_ftp_dialog.dart';
import 'package:iris/widgets/dialogs/show_webdav_dialog.dart';
import 'package:iris/widgets/popups/storages/db/storages_utils/storage_utils.dart';
import 'package:path/path.dart' as p;

enum StorageTileAction { play, playAppend, scan, edit, remove }

/// Menu actions for a storage-tile trailing button, in display order.
///
/// Hidden logic only — the widget maps these to localized menu items.
/// - [scenarioMode] selects the existing more-menu shape whose primary
///   trailing button is the recursive scan; the legacy shape keeps its
///   Edit/Remove base.
/// - [canScan] gates the recursive-scan entry on the non-legacy (Drift) stack.
///   Scenario mode renders scan as the primary button instead of a menu entry.
/// - [online] disables scan without a connection (scanning a dead remote can
///   only fail); the entry is still shown so the state is visible.
/// - [isScanned] marks auto-discovered local storages, whose Edit/Remove stay
///   hidden and which have no menu at all in the legacy shape.
List<({StorageTileAction action, bool enabled})> storageTileMenuActions({
  required bool scenarioMode,
  required bool canScan,
  required bool online,
  required bool isScanned,
}) {
  if (!scenarioMode) {
    if (isScanned) return const [];
    return [
      if (canScan) (action: StorageTileAction.scan, enabled: online),
      (action: StorageTileAction.edit, enabled: true),
      (action: StorageTileAction.remove, enabled: true),
    ];
  }
  return [
    (action: StorageTileAction.play, enabled: true),
    (action: StorageTileAction.playAppend, enabled: true),
    if (!isScanned) ...[
      (action: StorageTileAction.edit, enabled: true),
      (action: StorageTileAction.remove, enabled: true),
    ],
  ];
}

List<PopupMenuEntry<StorageTileAction>> _buildMenuItems(
  AppLocalizations t,
  List<({StorageTileAction action, bool enabled})> actions,
) {
  String label(StorageTileAction action) => switch (action) {
        StorageTileAction.play => t.storages_play_override,
        StorageTileAction.playAppend => t.storages_play_append,
        StorageTileAction.scan => t.files_scan_recursive,
        StorageTileAction.edit => t.edit,
        StorageTileAction.remove => t.remove,
      };
  return [
    for (final entry in actions)
      PopupMenuItem(
        value: entry.action,
        enabled: entry.enabled,
        child: Text(label(entry.action)),
      ),
  ];
}

final _log = AreaKeyLog(LogKeys.legacyUi);

/// Opens a dialog without letting an async failure vanish.
///
/// `showWebDAVDialog` is async, so an exception in its future (e.g. a build
/// error) would otherwise be an unhandled future error — which presents exactly
/// like an unresponsive menu item.
void openDialogSafely(Future<void> Function() open) {
  unawaited(open().catchError((Object e, StackTrace s) {
    _log.e('dialog open failed: $e\n$s');
  }));
}

/// The endpoint the entry will actually dial.
///
/// For a wildcard entry this is the last RESOLVED host — showing the pattern
/// alone (e.g. `192.168.*.*`) hid which machine discovery had picked, so a wrong
/// pick silently looked like an empty folder. The configured pattern is
/// appended in brackets whenever it differs from the resolved address.
String _webdavEndpointLabel(WebDAVStorage s) {
  final resolved = s.resolvedHost;
  final url = 'http${s.https ? 's' : ''}://${resolved ?? s.host}'
      '${s.port.isNotEmpty && s.port != '80' && s.port != '443' ? ':${s.port}' : ''}'
      '${s.basePath.join('/')}';
  if (resolved == null || !isIPv4WildcardHost(s.host)) return url;
  return '$url  [${s.host}]';
}

class StoragesDbList extends HookWidget {
  const StoragesDbList({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final store = useStorageStore();

    // Load database-stored local storages

    final dbLocalStoragesFuture = useMemoized(() async {
      final allStorages = await DbModule.storageRepo.getStorages();
      return allStorages.whereType<LocalStorage>().toList();
    }, []);
    final dbLocalStorages = useFuture(dbLocalStoragesFuture).data ?? [];

    final scannedLocalStoragesFuture = useMemoized(() async => await getLocalStorages(context), []);
    final scannedLocalStoragesSnapshot = useFuture(scannedLocalStoragesFuture);
    final scannedLocalStorages = scannedLocalStoragesSnapshot.data ?? [];

    // Persist scanned storages. Delegated to the shared discovery service (the
    // popup root also runs it) so there is ONE reconciliation owner: a direct
    // call here in parallel with the root's would race the same `addStorage`.
    // Microtask-deferred: flutter_hooks runs effect callbacks during the build
    // phase, where mutating stores can raise "markNeedsBuild() during build".
    useEffect(() {
      final labels = LocalStorageLabels.of(t);
      Future.microtask(
          () => LocalStorageDiscovery.ensure(labels: labels, store: store));
      return null;
    }, [scannedLocalStorages, dbLocalStorages]);

    final storagesFromStore = store.select(context, (state) => state.storages);
    final allStorages = useMemoized(
      () => mergeScannedAndStoredStorages(
        scanned: scannedLocalStorages,
        stored: storagesFromStore,
      ),
      [scannedLocalStorages, storagesFromStore],
    );

    final isHandlingTap = useState(false);

    // A blank body is a bare ListView, i.e. indistinguishable from a failed or
    // still-pending enumeration. INFO level: `log.legacy.*` is silent by default
    // (see Log.init) and can be opened with
    // `--dart-define=IRIS_LOG_KEYS=log.legacy.db`.
    _log.i('StoragesDbList: scanned=${scannedLocalStorages.length} '
        'storeLocal=${storagesFromStore.whereType<LocalStorage>().length} '
        'dbLocal=${dbLocalStorages.length} total=${allStorages.length} '
        'scannedState=${scannedLocalStoragesSnapshot.connectionState} '
        'scannedError=${scannedLocalStoragesSnapshot.error}');

    // F-001 (D2/D32): the whole-storage scan + more tile is gated on the
    // scenario mode; legacy mode keeps the pre-existing trailing unchanged.
    final scenarioMode = useAppStore().select(context,
        (s) => !s.useLegacyStoragePersistence && s.useScenarioDrivenPlayback);

    final scanMode = useAppStore().select(context, (s) => s.webDavScanMode);

    Future<void> playWholeStorage(BuildContext context, Storage storage) async {
      final result =
          await ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
        context,
        action: ({bool force = false}) =>
            ScenarioPlaybackActions.playSelectionInDefaultScenario(
          files: const [],
          directories: [
            (storageId: storage.id, path: '', recursive: true),
          ],
          sortField: ScenarioSortField.name,
          sortDirection: SortDirection.asc,
          force: force,
          gateContext: context,
        ),
      );
      // v5-D33/v6-D34: success closes the popup unless pinned; a forced
      // No-Media install keeps it open.
      if (result == NoMediaActionResult.success &&
          context.mounted &&
          !usePlaybackScenarioStore().storagesDbStayOnPlay &&
          Navigator.of(context).canPop()) {
        Navigator.pop(context);
      }
    }

    Future<void> playAppendWholeStorage(
        BuildContext context, Storage storage) async {
      await ScenarioPlaybackActions.appendToDefaultScenarioWithFeedback(
        context,
        const [],
        directories: [
          (storageId: storage.id, path: '', recursive: true),
        ],
      );
    }

    Future<void> editStorage(BuildContext context, Storage storage) async {
      switch (storage.type) {
        case StorageType.internal:
        case StorageType.network:
        case StorageType.usb:
        case StorageType.sdcard:
          showFolderDialog(context, storage: storage as LocalStorage);
          break;
        case StorageType.webdav:
          openDialogSafely(
              () => showWebDAVDialog(context, storage: storage as WebDAVStorage));
          break;
        case StorageType.ftp:
          showFTPDialog(context, storage: storage as FTPStorage);
          break;
        case StorageType.none:
          break;
      }
    }

    /// Endpoint shown in the connect-failure dialog: the concrete address the
    /// scan will dial, not the wildcard pattern.
    String scanEndpointLabel(Storage storage) {
      switch (storage.type) {
        case StorageType.webdav:
          final s = storage as WebDAVStorage;
          return s.resolvedHost ?? s.host;
        case StorageType.ftp:
          final s = storage as FTPStorage;
          return '${s.host}:${s.port}';
        default:
          return storage.name;
      }
    }

    /// Recursive-scan entry for a whole storage.
    ///
    /// Remote entries are pre-flighted first: a wildcard WebDAV host is
    /// resolved and the live root is listed, so an unreachable/unauthorized
    /// host is explained up front (retry / edit / cancel) instead of starting a
    /// scan that can only fail — and the scanner never mistakes a failed
    /// listing for an empty directory (which would purge the snapshot).
    Future<void> startStorageScan(BuildContext context, Storage storage) async {
      // Captured before the first attempt: the surface must land on the root
      // navigator even if the popup hosting this goes away.
      final navigator = Navigator.of(context, rootNavigator: true);
      final endpoint = scanEndpointLabel(storage);

      final ConnectLoopResult<Storage> loop = await runRemoteConnectLoop(
        attempt: (_) async {
          // The caller went away while the failure dialog was up: there is no
          // longer anything to connect for.
          if (!context.mounted) return const ConnectAttempt<Storage>.abandoned();
          final connect = GatedWebDavConnect(endpoint: endpoint)..arm(navigator: navigator);
          late final ScanPreflightResult pre;
          try {
            pre = await prepareStorageForScan(
              storage,
              onProgress: connect.report,
              stillWanted: () => !connect.cancelled,
            );
          } on Object {
            // Never leave the surface behind on an unexpected throw.
            await connect.succeed();
            connect.dispose();
            rethrow;
          }
          // The user gave up: nothing is known about the far end, so neither a
          // failure dialog nor a scan, and the entry keeps its current state.
          // The surface was pushed on the root navigator, so a gone caller is
          // not a gone window: cancel() is what takes it down.
          if (!context.mounted || pre.cancelled) {
            await connect.cancel();
            connect.dispose();
            return const ConnectAttempt<Storage>.abandoned();
          }

          if (!pre.ok) {
            store.markDisconnected(storage.id);
            // The gate is handed over undisposed: the loop turns this same
            // window into the failure dialog instead of stacking one on it.
            return ConnectAttempt<Storage>.failed(
              errorKind: pre.errorKind,
              errorDetail: pre.errorDetail,
              endpoint: endpoint,
              gate: connect,
            );
          }

          final target = pre.storage!;
          store.markConnected(target.id);
          final gaveUp = await connect.succeed();
          connect.dispose();
          // Dismissed mid-connect: drop the result rather than acting on it.
          if (gaveUp) return const ConnectAttempt<Storage>.abandoned();
          return ConnectAttempt<Storage>.connected(target);
        },
        onEdit: () async {
          if (!context.mounted) return;
          await editStorage(context, storage);
        },
        onRunningChanged: (running) => isHandlingTap.value = running,
      );

      // Only a connected attempt is allowed to go on; the other two endings
      // have already left the entry exactly as it was.
      if (!loop.connected) return;
      if (!context.mounted) return;
      final target = loop.value!;

      // Scan options gate: null = cancelled by the user.
      final probeEnabled =
          await showScanOptionsDialog(context, storageType: target.type);
      if (probeEnabled == null) return;
      if (!context.mounted) return;

      final service = RecursiveScanService(
        storage: target,
        scanStore: useRecursiveScanStore(),
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        probeService: probeEnabled ? createMediaProbeService() : null,
      );
      await service.scanRecursively(
        rootPaths: [target.basePath.join('/')],
        context: context,
      );
      // The scan mutated `media_nodes`: announce the storage so the derived
      // queue index / open queue view reflect the new content.
      await MediaRevisionActions.mediaNodesChanged([target.id]);
    }

    Future<void> handleMenu(BuildContext context, StorageTileAction value,
        Storage storage) async {
      switch (value) {
        case StorageTileAction.play:
          await playWholeStorage(context, storage);
          break;
        case StorageTileAction.playAppend:
          await playAppendWholeStorage(context, storage);
          break;
        case StorageTileAction.scan:
          await startStorageScan(context, storage);
          break;
        case StorageTileAction.edit:
          await editStorage(context, storage);
          break;
        case StorageTileAction.remove:
          await store.removeStorage(storage);
          break;
      }
    }

    Widget? buildTrailing(BuildContext context, Storage storage) {
      // Recursive scan needs the non-legacy (Drift-backed) stack. Read state
      // directly: this widget rebuilds on the same-store selections above.
      final canScan = !useAppStore().state.useLegacyStoragePersistence;
      final online =
          useStorageStore().state.storageConnectionStatus[storage.id] ?? true;
      final isScanned = scannedLocalStorages.contains(storage);

      if (!scenarioMode) {
        if (isScanned) return null;
        final actions = storageTileMenuActions(
          scenarioMode: false,
          canScan: canScan,
          online: online,
          isScanned: isScanned,
        );
        return PopupMenuButton<StorageTileAction>(
          tooltip: t.menu,
          clipBehavior: Clip.hardEdge,
          color: Theme.of(context).colorScheme.surface.withAlpha(250),
          onSelected: (value) => handleMenu(context, value, storage),
          itemBuilder: (_) => _buildMenuItems(t, actions),
        );
      }
      final actions = storageTileMenuActions(
        scenarioMode: true,
        canScan: canScan,
        online: online,
        isScanned: isScanned,
      );
      // Primary trailing is the whole-storage recursive scan; the whole-storage
      // Play moved into the more menu above. Offline-grey mirrors the menu
      // entry: scanning a dead remote can only fail, and the tile tap is the
      // recovery path.
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.autorenew_rounded),
            tooltip: rowTooltip(t.files_scan_recursive),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            onPressed: canScan && online
                ? () => startStorageScan(context, storage)
                : null,
          ),
          PopupMenuButton<StorageTileAction>(
            tooltip: rowTooltip(t.menu),
            clipBehavior: Clip.hardEdge,
            color: Theme.of(context).colorScheme.surface.withAlpha(250),
            onSelected: (value) => handleMenu(context, value, storage),
            itemBuilder: (_) => _buildMenuItems(t, actions),
          ),
        ],
      );
    }

    /// Connects a wildcard WebDAV entry: resolves a concrete host, then lets
    /// the user retry / edit / cancel for as long as they keep choosing retry.
    ///
    /// The retry lives in [runRemoteConnectLoop] instead of re-entering this
    /// function. A re-entry comes back through the `isHandlingTap` guard above,
    /// which the previous attempt is still holding at that point, so the retry
    /// the user just asked for returned without dialling anything.
    Future<void> handleWebDAVTap(BuildContext context, WebDAVStorage storage) async {
      if (isHandlingTap.value) return; // ignore repeated taps

      final ctx = context;
      if (!isIPv4WildcardHost(storage.host)) {
        store.updateCurrentPath(storage.basePath);
        store.updateCurrentStorage(storage);
        return;
      }

      // Legacy strategy: the dialog owns the serial isolate scan.
      if (scanMode == WebDavScanMode.legacyScan) {
        isHandlingTap.value = true;
        try {
          await showWebDAVDialog(ctx, storage: storage); //  await!
        } finally {
          isHandlingTap.value = false; // always release lock
        }
        return;
      }

      // Discovery strategy: cached hosts → SSDP → subnet scan. A failure
      // keeps the last resolved host and stays on the list: the edit form
      // opens only when the user explicitly chooses it, and the entry is
      // marked disconnected so the library page renders its snapshot greyed.
      //
      // The resolve is unbounded (a wide pattern scans a whole subnet), so it
      // runs behind a progress surface: silent while a cached host answers,
      // naming the host being tried once it does not, and cancellable
      // throughout — an unbounded wait the user cannot escape is what made
      // this tap look like a dead button.
      //
      // Captured before the first await so the surface still lands on the root
      // navigator if this popup is gone by the time it appears.
      final navigator = Navigator.of(ctx, rootNavigator: true);

      final ConnectLoopResult<WebDAVStorage> loop;
      try {
        loop = await runRemoteConnectLoop<WebDAVStorage>(
          attempt: (_) async {
            // The caller went away while the failure dialog was up: there is no
            // longer anything to connect for.
            if (!ctx.mounted) return const ConnectAttempt<WebDAVStorage>.abandoned();
            final gate = GatedWebDavConnect(endpoint: storage.host)
              ..arm(navigator: navigator);

            final outcome = await webdavConnectCoordinator().resolveDetailed(
              storage,
              onCandidate: gate.report,
              stillWanted: () => !gate.cancelled,
            );
            // The user dismissed the progress surface, or the caller went away:
            // nothing is known about the far end, so do not navigate and do not
            // report a failure.
            if (!ctx.mounted || outcome.cancelled) {
              await gate.cancel();
              gate.dispose();
              return const ConnectAttempt<WebDAVStorage>.abandoned();
            }

            if (outcome.ok) {
              final gaveUp = await gate.succeed();
              gate.dispose();
              if (gaveUp) return const ConnectAttempt<WebDAVStorage>.abandoned();
              return ConnectAttempt<WebDAVStorage>.connected(storage);
            }

            store.markDisconnected(storage.id);
            // The gate is handed over undisposed: the loop turns this same
            // window into the failure dialog instead of stacking one on it.
            return ConnectAttempt<WebDAVStorage>.failed(
              errorKind: outcome.errorKind,
              errorDetail: outcome.errorDetail,
              // The address that was actually dialled, not the pattern the
              // progress surface named.
              endpoint: storage.resolvedHost ?? storage.host,
              gate: gate,
            );
          },
          onEdit: () async {
            if (!ctx.mounted) return;
            await showWebDAVDialog(ctx, storage: storage);
          },
          onRunningChanged: (running) => isHandlingTap.value = running,
        );
      } on Object catch (e, s) {
        // Never a silent no-op: an async failure here used to vanish into an
        // unhandled future error (the shape of "tap does nothing").
        _log.e('webdav tile tap failed: $e\n$s');
        isHandlingTap.value = false; // always release lock
        return;
      }
      isHandlingTap.value = false; // always release lock

      if (!loop.connected || !ctx.mounted) return;
      store.markConnected(storage.id);
      final resolved = (store.findById(storage.id) as WebDAVStorage?) ?? storage;
      store.updateCurrentPath(resolved.basePath);
      store.updateCurrentStorage(resolved);
    }

    String? buildSubtitle(Storage storage) {
      switch (storage.type) {
        case StorageType.internal:
        case StorageType.network:
        case StorageType.usb:
        case StorageType.sdcard:
          return p.normalize(storage.basePath.join('/'));
        case StorageType.webdav:
          return _webdavEndpointLabel(storage as WebDAVStorage);
        case StorageType.ftp:
          final s = storage as FTPStorage;
          return 'ftp://${s.username.isNotEmpty ? '${s.username}@' : ''}${s.host}:${s.port}'
              '${s.basePath.join('/')}';
        case StorageType.none:
          return null;
      }
    }

    // Reactive offline badge: the map identity changes on every
    // markDisconnected/markConnected, so the list greys without a reload.
    final connStatus =
        store.select(context, (s) => s.storageConnectionStatus);

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: allStorages.length,
      itemBuilder: (context, index) {
        final storage = allStorages[index];
        final offline = connStatus[storage.id] == false;
        final subtitle = buildSubtitle(storage);
        return ListTile(
          contentPadding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
          title: Text(
            offline ? '${storage.name} (${t.storage_offline})' : storage.name,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: storage.name.contains(storage.basePath[0])
              ? (offline ? Text(t.storage_offline) : null)
              : Text(
                  offline && subtitle != null
                      ? '$subtitle · ${t.storage_offline}'
                      : subtitle ?? '',
                  overflow: TextOverflow.ellipsis),
          onTap: isHandlingTap.value
              ? null
              : () {
                  if (storage is WebDAVStorage && isIPv4WildcardHost(storage.host)) {
                    handleWebDAVTap(context, storage);
                  } else {
                    store.updateCurrentPath(storage.basePath);
                    store.updateCurrentStorage(storage);
                  }
                },
          trailing: buildTrailing(context, storage),
        );
      },
    );
  }
}
