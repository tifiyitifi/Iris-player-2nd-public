import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/view/files_db_paging/storage_browser_data_source.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';

// The storagedb file page offers "Open in Explorer" only for device-local rows
// (Windows host); remote storage rows never gain the entry.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
    useStorageStore();
    await useStorageStore().initialized;
  });

  Storage localStorage() => Storage.local(
        id: 'reveal-action-test',
        type: StorageType.internal,
        name: 'C',
        basePath: const ['E:'],
      );

  Storage remoteStorage() => Storage.webdav(
        id: 'reveal-action-remote',
        name: 'dav',
        host: 'host',
        basePath: const [],
        port: '80',
        username: 'u',
        password: 'p',
        https: false,
      );

  FileItem localFile() => const FileItem(
        storageId: 'reveal-action-test',
        storageType: StorageType.internal,
        name: 'v.mp4',
        uri: 'E:\\yb\\v.mp4',
        path: ['E:', 'yb', 'v.mp4'],
        type: ContentType.video,
      );

  FileItem remoteFile() => const FileItem(
        storageId: 'reveal-action-remote',
        storageType: StorageType.webdav,
        name: 'v.mp4',
        uri: 'http://host/Movies/v.mp4',
        path: ['Movies', 'v.mp4'],
        type: ContentType.video,
      );

  Future<({List<GenericItemAction<FileItem>> actions, String label})> trailingFor(
    WidgetTester tester,
    Storage storage,
    FileItem item,
  ) async {
    late List<GenericItemAction<FileItem>> actions;
    late String label;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(builder: (context) {
          label = getLocalizations(context).open_in_explorer;
          actions = StorageBrowserDataSource(storage)
              .getItemTrailingActions(context, item);
          return const SizedBox();
        }),
      ),
    ));
    await tester.pumpAndSettle();
    return (actions: actions, label: label);
  }

  testWidgets('local file row offers Open in Explorer', (tester) async {
    final result = await trailingFor(tester, localStorage(), localFile());
    expect(result.label, isNotEmpty);
    expect(
      result.actions.any((a) => a.label == result.label),
      isTrue,
      reason: 'local file row should offer Open in Explorer',
    );
  });

  testWidgets('remote file row never offers Open in Explorer', (tester) async {
    final result = await trailingFor(tester, remoteStorage(), remoteFile());
    expect(
      result.actions.any((a) => a.label == result.label),
      isFalse,
      reason: 'webdav rows have no on-disk identity',
    );
  });
}
