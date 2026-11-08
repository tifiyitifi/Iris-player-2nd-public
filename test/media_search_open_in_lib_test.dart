import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_library.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/model/media_lib/media_library.dart';
import 'package:iris/features/media_library/model/media_lib/media_library_source.dart';
import 'package:iris/features/media_library/search/data_source/media_search_data_source.dart';
import 'package:iris/features/media_library/search/model/search_context.dart';
import 'package:iris/features/media_library/search/model/search_result_item.dart';
import 'package:iris/features/media_library/search/model/search_scope.dart';
import 'package:iris/features/media_library/search/store/search_browser_store.dart';
import 'package:iris/features/media_library/search/store/use_media_lib_search_store.dart';
import 'package:iris/features/media_library/store/browser_open_mode.dart';
import 'package:iris/features/media_library/store/use_media_lib_browser_store.dart';
import 'package:iris/features/media_library/view/content/model/media_lib_content_mode.dart';
import 'package:iris/features/media_library/view/content/store/use_media_lib_content_store.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

/// "Open in lib" (v11-D5): resolves the target library for a search result and
/// opens the media-library content page at the file's parent directory.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
    // Pre-initialize the persistent stores in the REAL async zone (setUpAll),
    // so their secure-storage load completes before the widget tests (which run
    // in FakeAsync and would hang on the platform channel). NOTE: never create
    // usePlayQueueStore()/useAppStore() here — UnifiedPlayQueueStore.load()
    // LateErrors on _activePersistence before onReady and flutter_test fails.
    useMediaLibSearchStore();
    useMediaLibContentStore();
    await useMediaLibSearchStore().initialized;
    await useMediaLibContentStore().initialized;
  });

  setUp(() {
    useSearchBrowserStore().destroySession();
    useSearchBrowserStore().clearAll();
    useSearchBrowserStore().setPinned(false);
  });

  Future<void> seedSysLib(String storageId) async {
    final now = DateTime.now();
    await DbModule.mediaLibsDao.upsert(MediaLibrary(
      id: 'sys_$storageId',
      name: 'sys',
      type: MediaLibraryType.system,
      createdAt: now,
      updatedAt: now,
    ).toCompanion());
    await DbModule.mediaLibSourcesDao.upsertSource(MediaLibrarySource(
      id: 0,
      libraryId: 'sys_$storageId',
      storageId: storageId,
      path: null,
      name: 'sys',
      kind: MediaSourceKind.storage,
    ));
  }

  group('resolveLibraryForStorage', () {
    test('prefers the per-storage system lib sys_<id>', () async {
      await seedSysLib('s1');
      expect(await resolveLibraryForStorage('s1'), 'sys_s1');
    });

    test('falls back to a user library holding a source for the storage',
        () async {
      final now = DateTime.now();
      await DbModule.mediaLibsDao.upsert(MediaLibrary(
        id: 'lib1',
        name: 'lib1',
        type: MediaLibraryType.user,
        createdAt: now,
        updatedAt: now,
      ).toCompanion());
      await DbModule.mediaLibSourcesDao.upsertSource(MediaLibrarySource(
        id: 0,
        libraryId: 'lib1',
        storageId: 's2',
        path: ['m'],
        name: 'm',
        kind: MediaSourceKind.directory,
      ));
      expect(await resolveLibraryForStorage('s2'), 'lib1');
    });

    test('returns null when no library covers the storage', () async {
      expect(await resolveLibraryForStorage('nope'), isNull);
    });
  });

  group('Open in lib trailing action', () {
    Future<void> invokeOpenInLib(
      WidgetTester tester,
      MediaSearchDataSource ds,
      SearchResultItem item,
    ) async {
      // Real async (drift + secure storage) does not advance under FakeAsync,
      // so run the tap + poll inside runAsync and let real work complete.
      await tester.runAsync(() async {
        late List<GenericItemAction<SearchResultItem>> actions;
        var actionsReady = false;
        // No StoreScope: it disposes the whole StoreLocator on unmount, which
        // would kill cross-test store state. Handlers use useXStore() directly.
        await tester.pumpWidget(MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(builder: (context) {
              actions = ds.getItemTrailingActions(context, item);
              actionsReady = true;
              return Column(
                children: [
                  for (final a in actions)
                    TextButton(
                      onPressed: () => a.onPressed(context, item),
                      child: Text(a.label),
                    ),
                ],
              );
            }),
          ),
        ));
        // The deferred l10n delegates load asynchronously and the Builder only
        // runs once AppLocalizations is above it (the labels are localized now).
        for (var i = 0; i < 200 && !actionsReady; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
        expect(actions.map((a) => a.label), contains('Open in lib'));
        await tester.tap(find.text('Open in lib'));
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
          if (useMediaLibBrowserStore().state.openMode ==
              BrowserOpenMode.libContent) {
            break;
          }
        }
      });
    }

    testWidgets(
        'opens the storage system lib at the file parent path (pathTree)',
        (tester) async {
      await seedSysLib('s');

      final ds = MediaSearchDataSource(
        searchContext: const SearchContext(
          entryContext: SearchEntryContext.scenarioSourcesRoot,
          scenarioId: 'sc',
          storageId: 's',
          sources: [
            SearchSource(
              storageId: 's',
              kind: MediaSourceKind.storage,
              recursive: true,
            ),
          ],
        ),
      );
      // setUpAll pre-initializes the stores; avoid awaiting initialized here.
      // Root-level item (no parent) keeps _syncDirectoryFor's AppStore/queue
      // chain out of the test (parentPath null → early return).
      const item = SearchResultItem(
        storageId: 's',
        path: 'movie.mp4',
        name: 'movie.mp4',
        origin: SearchResultOrigin.dbSource,
      );

      await invokeOpenInLib(tester, ds, item);

      expect(useMediaLibBrowserStore().state.openMode,
          BrowserOpenMode.libContent);
      final cs = useMediaLibContentStore().state;
      expect(cs.currentLibraryId, 'sys_s');
      expect(cs.currentStorageId, 's');
      expect(cs.currentParentPath, isNull);
      expect(cs.viewMode, MediaLibContentMode.pathTree);
      // The session is destroyed (explicit navigation, not a park).
      expect(useSearchBrowserStore().parkedSearchSession, isNull);
      ds.dispose();
    });

    testWidgets('keeps the current library when the storage has no library',
        (tester) async {
      final ds = MediaSearchDataSource(
        searchContext: const SearchContext(
          entryContext: SearchEntryContext.scenarioSourcesRoot,
          scenarioId: 'sc',
          storageId: 's',
          sources: [
            SearchSource(
              storageId: 's',
              kind: MediaSourceKind.storage,
              recursive: true,
            ),
          ],
        ),
      );
      // setUpAll pre-initializes the stores; avoid awaiting initialized here.
      const item = SearchResultItem(
        storageId: 's',
        path: 'movie.mp4',
        name: 'movie.mp4',
        origin: SearchResultOrigin.dbSource,
      );

      await invokeOpenInLib(tester, ds, item);

      // Q7 fallback: no library resolved → the current (null) library stays.
      expect(useMediaLibBrowserStore().state.openMode,
          BrowserOpenMode.libContent);
      expect(useMediaLibContentStore().state.currentStorageId, 's');
      expect(useMediaLibContentStore().state.currentParentPath, isNull);
      ds.dispose();
    });
  });
}
