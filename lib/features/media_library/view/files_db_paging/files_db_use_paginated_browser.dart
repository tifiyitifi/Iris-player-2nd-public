import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/media_library/view/files_db_paging/storage_browser_data_source.dart';
import 'package:iris/features/paginated_browser/paginated_browser_controller.dart';
import 'package:iris/features/paginated_browser/paginated_browser_page.dart';
import 'package:iris/globals.dart' as globals;
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/request_storage_permission.dart';
import 'package:permission_handler/permission_handler.dart';

class FilesDbUsePaginatedBrowser extends HookWidget {
  const FilesDbUsePaginatedBrowser({
    super.key,
    required this.storage,
    required this.onBack,
    this.onClose,
  });

  final Storage storage;
  final VoidCallback onBack;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    // Re-evaluate whenever the live permission state changes: the data source
    // drops it back to `denied` the moment a local listing is actually refused
    // (a stale "granted" would otherwise keep showing an empty folder), and the
    // grant action raises it again. Both transitions must switch this surface.
    useListenable(globals.storagePermissionStatusNotifier);
    final needPermission = Platform.isAndroid &&
        globals.storagePermissionStatus != PermissionStatus.granted &&
        storage is LocalStorage;
    final permissionBump = useState(false);

    // Keyed on [storage]: when the entry's resolved host changes (discovery
    // recorded a new one), the data source must be rebuilt instead of keeping
    // the stale storage object it was created with.
    final dataSource = useMemoized(
      () => StorageBrowserDataSource(storage),
      [storage],
    );
    final controller = useMemoized(
      () => PaginatedBrowserController<FileItem>(),
    );

    useEffect(() => () => dataSource.dispose(), [dataSource]);

    useEffect(() {
      if (needPermission) return null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final savedPath = useStorageStore().state.currentPath;
        if (savedPath.isNotEmpty) {
          dataSource.loadFromStorage();
        } else {
          dataSource.handleNavigationHome();
        }
      });
      return null;
    }, [needPermission, permissionBump.value]);

    if (needPermission) {
      return Center(
        child: ElevatedButton(
          onPressed: () async {
            await requestStoragePermission();
            permissionBump.value = !permissionBump.value;
          },
          child: Text(t.grant_storage_permission),
        ),
      );
    }

    return PaginatedBrowserPage<FileItem>(
      dataSource: dataSource,
      controller: controller,
      onClose: onClose,
      onHomePage: onBack,
    );
  }
}
