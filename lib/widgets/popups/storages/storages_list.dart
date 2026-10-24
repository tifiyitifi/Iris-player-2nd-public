import 'dart:async';

import 'package:flutter/material.dart';

import 'package:iris/widgets/a11y_tooltip.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/webdav_discovery/services/webdav_connect_coordinator.dart';
import 'package:iris/features/webdav_discovery/view/webdav_connect_error_dialog.dart';
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
import 'package:path/path.dart' as p;

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

class StoragesList extends HookWidget {
  const StoragesList({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);

    final localStoragesFuture = useMemoized(() async => await getLocalStorages(context), []);
    final localStorages = useFuture(localStoragesFuture).data ?? [];

    final storages = useStorageStore().select(context, (state) => state.storages);
    final scanMode = useAppStore().select(context, (state) => state.webDavScanMode);

    final allStorages = useMemoized(
        () => [
              ...localStorages,
              ...storages.where((s) => !localStorages.any((l) => l.id == s.id)),
            ],
        [localStorages, storages]);

    Future<void> handleWebDAVTap(
      BuildContext context,
      WebDAVStorage storage,
      WebDavScanMode scanMode,
    ) async {
      // Capture context for async safety
      final ctx = context;

      // Only do special handling for IPv4 wildcard
      if (!isIPv4WildcardHost(storage.host)) {
        // Normal behavior
        useStorageStore().updateCurrentPath(storage.basePath);
        useStorageStore().updateCurrentStorage(storage);
        return;
      }

      try {
        // Legacy strategy: the dialog owns the serial isolate scan.
        if (scanMode == WebDavScanMode.legacyScan) {
          await showWebDAVDialog(ctx, storage: storage);
          return;
        }

        // Discovery strategy: cached hosts → SSDP → subnet scan. On success the
        // resolved host is recorded on the entry and opened directly. On
        // failure the browser stays closed: explain first, edit only on
        // explicit user choice, and keep the last resolved host.
        final outcome =
            await webdavConnectCoordinator().resolveDetailed(storage);
        if (!ctx.mounted) return; // Guard BuildContext

        if (outcome.ok) {
          useStorageStore().markConnected(storage.id);
          final resolved =
              (useStorageStore().findById(storage.id) as WebDAVStorage?) ?? storage;
          useStorageStore().updateCurrentPath(resolved.basePath);
          useStorageStore().updateCurrentStorage(resolved);
        } else {
          useStorageStore().markDisconnected(storage.id);
          if (!ctx.mounted) return;
          final action = await showWebdavConnectFailure(
            ctx,
            endpoint: storage.resolvedHost ?? storage.host,
            errorKind: outcome.errorKind,
            errorDetail: outcome.errorDetail,
          );
          if (!ctx.mounted) return;
          switch (action) {
            case WebdavConnectAction.retry:
              await handleWebDAVTap(ctx, storage, scanMode);
              break;
            case WebdavConnectAction.edit:
              await showWebDAVDialog(ctx, storage: storage);
              break;
            case WebdavConnectAction.cancel:
              break;
          }
        }
      } on Object catch (e, s) {
        // Never a silent no-op: an async failure here used to vanish into an
        // unhandled future error (the shape of "tap does nothing").
        _log.e('webdav tile tap failed: $e\n$s');
      }
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: allStorages.length,
      itemBuilder: (context, index) => ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
        title: Text(allStorages[index].name),
        subtitle: allStorages[index].name.contains(allStorages[index].basePath[0])
            ? null
            : () {
                String? subtitle;

                switch (allStorages[index].type) {
                  case StorageType.internal:
                  case StorageType.network:
                  case StorageType.usb:
                  case StorageType.sdcard:
                    subtitle = p.normalize(allStorages[index].basePath.join('/'));
                    break;
                  case StorageType.webdav:
                    subtitle = _webdavEndpointLabel(
                        allStorages[index] as WebDAVStorage);
                    break;
                  case StorageType.ftp:
                    final storage = allStorages[index] as FTPStorage;
                    subtitle =
                        'ftp://${storage.username.isNotEmpty ? '${storage.username}@' : ''}${storage.host}:${storage.port}${storage.basePath.join('/')}';
                    break;
                  case StorageType.none:
                    break;
                }

                return subtitle == null
                    ? null
                    : Text(
                        subtitle,
                        overflow: TextOverflow.ellipsis,
                      );
              }(),
        onTap: () {
          final storage = allStorages[index];
          if (storage is WebDAVStorage && isIPv4WildcardHost(storage.host)) {
            handleWebDAVTap(context, storage, scanMode);
          } else {
            useStorageStore().updateCurrentPath(storage.basePath);
            useStorageStore().updateCurrentStorage(storage);
          }
        },
        trailing: localStorages.contains(allStorages[index])
            ? null
            : PopupMenuButton<StorageOptions>(
                tooltip: rowTooltip(t.menu),
                clipBehavior: Clip.hardEdge,
                color: Theme.of(context).colorScheme.surface.withAlpha(250),
                onSelected: (value) {
                  switch (value) {
                    // Multi-window only; this legacy list does not offer it.
                    case StorageOptions.openInNewWindow:
                      break;
                    case StorageOptions.edit:
                      switch (allStorages[index].type) {
                        case StorageType.internal:
                        case StorageType.network:
                        case StorageType.usb:
                        case StorageType.sdcard:
                          showFolderDialog(context, storage: allStorages[index] as LocalStorage);
                          break;
                        case StorageType.webdav:
                          openDialogSafely(() => showWebDAVDialog(context,
                              storage: allStorages[index] as WebDAVStorage));
                          break;
                        case StorageType.ftp:
                          showFTPDialog(context, storage: allStorages[index] as FTPStorage);
                          break;
                        case StorageType.none:
                          break;
                      }
                      break;
                    case StorageOptions.remove:
                      useStorageStore().removeStorage(allStorages[index]);
                      break;
                  }
                },
                itemBuilder: (BuildContext context) {
                  return [
                    PopupMenuItem(
                      value: StorageOptions.edit,
                      child: Text(t.edit),
                    ),
                    PopupMenuItem(
                      value: StorageOptions.remove,
                      child: Text(t.remove),
                    ),
                  ];
                },
              ),
      ),
    );
  }
}
