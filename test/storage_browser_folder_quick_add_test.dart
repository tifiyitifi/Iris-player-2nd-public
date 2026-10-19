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

// Folder rows in the storagedb file page expose "Add as audio source" and
// "Add as virtual merge" in their trailing more-action menu; plain files do
// not, and both entries disappear when the metadata-driven stack is off.
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

  void setMetaDriven({required bool on}) {
    final app = useAppStore();
    app.set(app.state.copyWith(
      useMetadataSettings: on,
      useLegacyStoragePersistence: !on,
    ));
  }

  tearDown(() => setMetaDriven(on: true));

  Storage testStorage() => Storage.local(
        id: 'quick-add-test',
        type: StorageType.internal,
        name: 'E',
        basePath: const ['root'],
      );

  FileItem dirItem() => const FileItem(
        storageId: 'quick-add-test',
        name: 'Anime',
        uri: 'Anime',
        path: ['root', 'Anime'],
        isDir: true,
        type: ContentType.other,
      );

  FileItem fileItem() => const FileItem(
        storageId: 'quick-add-test',
        name: 'v.mp4',
        uri: 'v.mp4',
        path: ['root', 'v.mp4'],
        type: ContentType.video,
      );

  Future<Set<String>> trailingLabels(
    WidgetTester tester,
    Storage storage,
    FileItem item,
  ) async {
    late List<GenericItemAction<FileItem>> actions;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(builder: (context) {
          actions = StorageBrowserDataSource(storage)
              .getItemTrailingActions(context, item);
          return const SizedBox();
        }),
      ),
    ));
    await tester.pumpAndSettle();
    return {for (final a in actions) a.label};
  }

  AppLocalizations labels(WidgetTester tester) =>
      getLocalizations(tester.element(find.byType(Scaffold)));

  testWidgets('folder trailing offers the virtual-merge quick-add',
      (tester) async {
    setMetaDriven(on: true);
    final found = await trailingLabels(tester, testStorage(), dirItem());
    final t = labels(tester);
    expect(found, contains(t.lib_add_as_vm_merge));
  });

  testWidgets('plain file trailing offers no virtual-merge quick-add',
      (tester) async {
    setMetaDriven(on: true);
    final found = await trailingLabels(tester, testStorage(), fileItem());
    final t = labels(tester);
    expect(found, isNot(contains(t.lib_add_as_vm_merge)));
  });

  testWidgets('the quick-add disappears when the feature is off',
      (tester) async {
    setMetaDriven(on: false);
    final found = await trailingLabels(tester, testStorage(), dirItem());
    final t = labels(tester);
    expect(found, isNot(contains(t.lib_add_as_vm_merge)));
  });
}
