import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/search/data_source/media_search_data_source.dart';
import 'package:iris/features/media_library/search/model/search_context.dart';
import 'package:iris/features/media_library/search/model/search_result_item.dart';
import 'package:iris/features/media_library/search/model/search_scope.dart';
import 'package:iris/features/media_library/search/store/search_browser_store.dart';
import 'package:iris/features/media_library/search/store/use_media_lib_search_store.dart';
import 'package:iris/features/media_library/store/browser_open_mode.dart';
import 'package:iris/features/media_library/store/use_media_lib_browser_store.dart';
import 'package:iris/features/media_library/view/content/store/use_media_lib_content_store.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/l10n/app_localizations_zh.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/coordinator/scenario_browser_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/warning_dialogs.dart';
import 'package:iris/widgets/popup.dart';

/// gen-l10n deferred chunks can be loaded only once per test isolate through
/// the stock delegate; pumping a SECOND locale later in the same file renders
/// nothing. The tap flows need zh text (the search dialogs still hardcode zh),
/// so serve zh synchronously instead of via the deferred delegate.
class _SyncZhLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _SyncZhLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'zh';

  @override
  Future<AppLocalizations> load(Locale locale) async => AppLocalizationsZh();

  @override
  bool shouldReload(_SyncZhLocalizationsDelegate old) => false;
}

/// Search play actions per entry context (v15-D1…D4/D6): click / trailing /
/// multi-select behave differently for A (system playing scenario), B (user
/// saved scenario) and C (media library); failures surface the uniform
/// copyable error dialog and never disturb the player.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
    useMediaLibSearchStore();
    useMediaLibContentStore();
    await useMediaLibSearchStore().initialized;
    await useMediaLibContentStore().initialized;
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    // Mirrors main.dart: the scenario playback path (e.g. playInScenario →
    // PlaybackProviderRegistry.scenario) needs the provider registered.
    PlaybackProviderRegistry.init();
    await runZonedGuarded(() async {
      usePlayQueueStore();
      await usePlayQueueStore().initialized;
      useAppStore();
      await useAppStore().initialized;
      // Play actions route through runPlayAction, which shows the first-use
      // workspace notice (kWarningScenarioWorkspace). These tests exercise the
      // play/park mechanics, not the notice, so pre-suppress it as the real
      // second-use onward state does.
      await useAppStore().suppressWarning(kWarningScenarioWorkspace);
    }, (Object e, StackTrace st) {});
  });

  setUp(() {
    useSearchBrowserStore().destroySession();
    useSearchBrowserStore().clearAll();
    useSearchBrowserStore().setPinned(false);
    useMediaLibBrowserStore().closeBrowser();
  });

  Future<void> seedFile(String storageId, String p) async {
    await DbModule.mediaNodesDao.deleteNode(storageId, p);
    final segments = p.split('/');
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 'f:$storageId:$p',
      storageId: storageId,
      path: segments,
      name: segments.last,
      mediaType: MediaType.video,
    ));
  }

  /// Context C — media library entry.
  MediaSearchDataSource libDataSource() => MediaSearchDataSource(
        searchContext: const SearchContext(
          entryContext: SearchEntryContext.libPathTreeDir,
          storageId: 's',
          parentPath: 'a',
          sources: [
            SearchSource(
              storageId: 's',
              path: 'a',
              kind: MediaSourceKind.directory,
              recursive: true,
            ),
          ],
        ),
      );

  /// Context B — user saved scenario entry.
  MediaSearchDataSource userScenarioDataSource() => MediaSearchDataSource(
        searchContext: const SearchContext(
          entryContext: SearchEntryContext.scenarioSourcesRoot,
          scenarioId: 'sc1',
          sources: [
            SearchSource(
              storageId: 's',
              path: 'a',
              kind: MediaSourceKind.directory,
              recursive: true,
            ),
          ],
          explicitItems: [],
        ),
      );

  /// Context A — the SystemPlaying scenario itself.
  Future<MediaSearchDataSource> systemPlayingDataSource() async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await store.refreshScenarios();
    return MediaSearchDataSource(
      searchContext: SearchContext(
        entryContext: SearchEntryContext.scenarioSourcesRoot,
        scenarioId: sys.id,
        sources: const [],
        explicitItems: const [],
      ),
    );
  }

  const item = SearchResultItem(
    storageId: 's',
    path: 'a/movie.mp4',
    name: 'movie.mp4',
    origin: SearchResultOrigin.dbSource,
  );

  /// Hosts the trailing-action buttons inside a pushed [Popup] route so
  /// `Navigator.pop()` (v14-D1 unpin-play exit) pops a real route.
  Future<void> invokeAction(
    WidgetTester tester,
    MediaSearchDataSource ds,
    String label, {
    SearchResultItem target = item,
    required Future<bool> Function() done,
  }) async {
    await tester.runAsync(() async {
      late List<GenericItemAction<SearchResultItem>> actions;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(builder: (context) {
            actions = ds.getItemTrailingActions(context, target);
            return Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  Popup(
                    direction: PopupDirection.right,
                    child: Builder(
                      builder: (popupCtx) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final a in actions)
                            TextButton(
                              onPressed: () => a.onPressed(popupCtx, target),
                              child: Text(a.label),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                child: const Text('open actions'),
              ),
            );
          }),
        ),
      ));
      // Deferred l10n delegates load async — wait with real time for the
      // localized home subtree (fake-time pumpAndSettle returns too early).
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.text('open actions').evaluate().isNotEmpty) break;
      }
      await tester.tap(find.text('open actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // popup entrance
      await tester.tap(find.text(label));
      for (var i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (await done()) return;
      }
      fail('action "$label" did not complete in time');
    });
  }

  /// Same popup-route host for the selection-mode actions.
  Future<void> invokeSelectionAction(
    WidgetTester tester,
    MediaSearchDataSource ds,
    String label, {
    required List<SearchResultItem> selected,
    required Future<bool> Function() done,
  }) async {
    await tester.runAsync(() async {
      late List<CustomSelectionAction<SearchResultItem>> actions;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(builder: (context) {
            actions = ds.buildCustomSelectionActions(context);
            return Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  Popup(
                    direction: PopupDirection.right,
                    child: Builder(
                      builder: (popupCtx) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final a in actions)
                            TextButton(
                              onPressed: () =>
                                  a.onPressed(popupCtx, selected.toSet()),
                              child: Text(a.label),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                child: const Text('open actions'),
              ),
            );
          }),
        ),
      ));
      // Deferred l10n delegates load async — wait with real time for the
      // localized home subtree (fake-time pumpAndSettle returns too early).
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.text('open actions').evaluate().isNotEmpty) break;
      }
      await tester.tap(find.text('open actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // popup entrance
      await tester.tap(find.text(label));
      for (var i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (await done()) return;
      }
      fail('selection action "$label" did not complete in time');
    });
  }

  /// Hosts `handleItemTap` inside a pushed [Popup] route.
  Future<void> tapItem(
    WidgetTester tester,
    MediaSearchDataSource ds,
    SearchResultItem target,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: [
          const _SyncZhLocalizationsDelegate(),
          ...AppLocalizations.localizationsDelegates.skip(1),
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(builder: (context) => Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                Popup(
                  direction: PopupDirection.right,
                  child: Builder(
                    builder: (popupCtx) => TextButton(
                      onPressed: () => ds.handleItemTap(popupCtx, target),
                      child: const Text('tap item'),
                    ),
                  ),
                ),
              ),
              child: const Text('open item'),
            ),
          )),
        ),
      ));
      // Deferred l10n delegates load async — wait with real time for the
      // localized home subtree (fake-time pumpAndSettle returns too early).
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.text('open item').evaluate().isNotEmpty) break;
      }
      await tester.tap(find.text('open item'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // popup entrance
      await tester.tap(find.text('tap item'));
      await tester.pump();
    });
  }

  Future<void> pumpUntil(WidgetTester tester, Future<bool> Function() cond,
      [String? msg]) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (await cond()) return;
      }
      fail(msg ?? 'condition did not become true in time');
    });
  }

  group('context discrimination (v15-D1)', () {
    test('isMediaLibEntry is true only for lib entries', () {
      const lib = SearchContext(
        entryContext: SearchEntryContext.libPathTreeDir,
        storageId: 's',
        parentPath: 'a',
      );
      const scn = SearchContext(
        entryContext: SearchEntryContext.scenarioSourcesRoot,
        scenarioId: 'sc1',
      );
      expect(lib.isMediaLibEntry, isTrue);
      expect(scn.isMediaLibEntry, isFalse);
    });
  });

  group('trailing actions per context (v15-D3)', () {
    testWidgets('A (system playing): only Open in lib / Open in folder',
        (tester) async {
      final ds = await systemPlayingDataSource();
      late List<GenericItemAction<SearchResultItem>> actions;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(builder: (context) {
            actions = ds.getItemTrailingActions(context, item);
            return const SizedBox();
          }),
        ),
      ));
      // Deferred l10n delegates load async — settle once before reading.
      await tester.pumpAndSettle();
      expect(actions.map((a) => a.label),
          ['Open in lib', 'Open in folder']);
      ds.dispose();
    });

    testWidgets('B (user scenario): Override / Append / Open in lib / '
        'Open in folder', (tester) async {
      final ds = userScenarioDataSource();
      late List<GenericItemAction<SearchResultItem>> actions;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(builder: (context) {
            actions = ds.getItemTrailingActions(context, item);
            return const SizedBox();
          }),
        ),
      ));
      await tester.pumpAndSettle();
      expect(actions.map((a) => a.label),
          ['Override', 'Append', 'Open in lib', 'Open in folder']);
      ds.dispose();
    });

    testWidgets('C (media library): Play single / Append / Open in folder '
        '(no Override, no Open in lib)', (tester) async {
      final ds = libDataSource();
      late List<GenericItemAction<SearchResultItem>> actions;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(builder: (context) {
            actions = ds.getItemTrailingActions(context, item);
            return const SizedBox();
          }),
        ),
      ));
      await tester.pumpAndSettle();
      expect(actions.map((a) => a.label),
          ['Play single', 'Append', 'Open in folder']);
      ds.dispose();
    });
  });

  group('multi-select per context (v15-D4)', () {
    testWidgets('A (system playing): only Play selected items', (tester) async {
      final ds = await systemPlayingDataSource();
      late List<CustomSelectionAction<SearchResultItem>> actions;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(builder: (context) {
            actions = ds.buildCustomSelectionActions(context);
            return const SizedBox();
          }),
        ),
      ));
      await tester.pumpAndSettle();
      expect(actions.map((a) => a.label), ['Play selected items']);
      ds.dispose();
    });

    testWidgets('B (user scenario): Override Queue / Append Queue',
        (tester) async {
      final ds = userScenarioDataSource();
      late List<CustomSelectionAction<SearchResultItem>> actions;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(builder: (context) {
            actions = ds.buildCustomSelectionActions(context);
            return const SizedBox();
          }),
        ),
      ));
      await tester.pumpAndSettle();
      expect(actions.map((a) => a.label), ['Override Queue', 'Append Queue']);
      ds.dispose();
    });

    testWidgets('C (media library): Override Queue / Append Queue',
        (tester) async {
      final ds = libDataSource();
      late List<CustomSelectionAction<SearchResultItem>> actions;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(builder: (context) {
            actions = ds.buildCustomSelectionActions(context);
            return const SizedBox();
          }),
        ),
      ));
      await tester.pumpAndSettle();
      expect(actions.map((a) => a.label), ['Override Queue', 'Append Queue']);
      ds.dispose();
    });
  });

  group('Append (v11-D3 / v14-D2): always keeps the page + feedback dialog', () {
    testWidgets('Append adds the file as an explicit item and shows feedback',
        (tester) async {
      await seedFile('s', 'a/movie.mp4');
      final ds = libDataSource();
      final openModeBefore = useMediaLibBrowserStore().state.openMode;

      await invokeAction(
        tester,
        ds,
        'Append',
        done: () async {
          final sys = await DbModule.scenarioRepo.getSystemPlayingScenario();
          if (sys == null) return false;
          final items = await DbModule.scenarioRepo.getExplicitItems(sys.id);
          return items.any((e) => e.path == 'a/movie.mp4') &&
              tester.any(find.byType(AlertDialog));
        },
      );

      final sys = await DbModule.scenarioRepo.getSystemPlayingScenario();
      expect(sys, isNotNull);
      final items = await DbModule.scenarioRepo.getExplicitItems(sys!.id);
      expect(items.map((e) => e.path), contains('a/movie.mp4'));
      expect(find.text('Added to play queue'), findsOneWidget);
      expect(find.text('• movie.mp4'), findsOneWidget);
      expect(useMediaLibBrowserStore().state.openMode, openModeBefore);
      expect(useSearchBrowserStore().parkedSearchSession, isNull);
      await tester.tap(find.text('OK'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      ds.dispose();
    });

    testWidgets('Append Queue adds the selection and shows feedback',
        (tester) async {
      await seedFile('s', 'a/movie1.mp4');
      await seedFile('s', 'a/movie2.mp4');
      final ds = libDataSource();
      const selected = [
        SearchResultItem(
            storageId: 's', path: 'a/movie1.mp4', name: 'movie1.mp4',
            origin: SearchResultOrigin.dbSource),
        SearchResultItem(
            storageId: 's', path: 'a/movie2.mp4', name: 'movie2.mp4',
            origin: SearchResultOrigin.dbSource),
      ];

      await invokeSelectionAction(
        tester,
        ds,
        'Append Queue',
        selected: selected,
        done: () async {
          final sys = await DbModule.scenarioRepo.getSystemPlayingScenario();
          if (sys == null) return false;
          final items = await DbModule.scenarioRepo.getExplicitItems(sys.id);
          return items.length >= 2 && tester.any(find.byType(AlertDialog));
        },
      );

      final sys = await DbModule.scenarioRepo.getSystemPlayingScenario();
      final items = await DbModule.scenarioRepo.getExplicitItems(sys!.id);
      expect(items.map((e) => e.path),
          containsAll(['a/movie1.mp4', 'a/movie2.mp4']));
      await tester.tap(find.text('OK'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      ds.dispose();
    });
  });

  group('Play single (context C, v15-D3): park + close popup unless pinned', () {
    testWidgets('unpinned Play single parks the session and closes the popup',
        (tester) async {
      await seedFile('s', 'a/movie.mp4');
      useMediaLibBrowserStore().openSearch();
      final ds = libDataSource();

      await invokeAction(
        tester,
        ds,
        'Play single',
        done: () async {
          final sys = await DbModule.scenarioRepo.getSystemPlayingScenario();
          if (sys == null) return false;
          final items = await DbModule.scenarioRepo.getExplicitItems(sys.id);
          return items.any((e) => e.path == 'a/movie.mp4') &&
              useSearchBrowserStore().parkedSearchSession == ds;
        },
      );

      final sys = await DbModule.scenarioRepo.getSystemPlayingScenario();
      final items = await DbModule.scenarioRepo.getExplicitItems(sys!.id);
      expect(items.map((e) => e.path), contains('a/movie.mp4'));
      expect(useSearchBrowserStore().parkedSearchSession, same(ds));
      expect(useSearchBrowserStore().pinned, isFalse);
      expect(useMediaLibBrowserStore().state.openMode, BrowserOpenMode.search);
      await tester.pump(const Duration(milliseconds: 300)); // popup exit
      expect(find.text('Play single'), findsNothing);
      ds.dispose();
    });

    testWidgets('unpinned Play single keeps the scenario return seeds',
        (tester) async {
      await seedFile('s', 'a/movie.mp4');
      useSearchBrowserStore().setScenarioSourcesEntry(
        context: const SearchContext(
          entryContext: SearchEntryContext.scenarioSourcesRoot,
          scenarioId: 'sc1',
          sources: [],
          explicitItems: [],
        ),
        returnPage: 3,
        groupOrder: const [],
        hiddenGroups: const {},
      );
      final ds = libDataSource();

      await invokeAction(
        tester,
        ds,
        'Play single',
        done: () async {
          final sys = await DbModule.scenarioRepo.getSystemPlayingScenario();
          if (sys == null) return false;
          final items = await DbModule.scenarioRepo.getExplicitItems(sys.id);
          return items.any((e) => e.path == 'a/movie.mp4') &&
              useSearchBrowserStore().parkedSearchSession == ds;
        },
      );

      expect(useSearchBrowserStore().parkedSearchSession, same(ds));
      expect(useSearchBrowserStore().scenarioSearchReturnMode,
          ScenarioBrowserMode.sources);
      expect(useSearchBrowserStore().sourcesReturnPage, 3);
      await tester.pump(const Duration(milliseconds: 300)); // popup exit
      expect(find.text('Play single'), findsNothing);
      ds.dispose();
    });

    testWidgets('pinned Play single keeps the search page open',
        (tester) async {
      await seedFile('s', 'a/movie.mp4');
      useSearchBrowserStore().setPinned(true);
      final ds = libDataSource();

      await invokeAction(
        tester,
        ds,
        'Play single',
        done: () async {
          final sys = await DbModule.scenarioRepo.getSystemPlayingScenario();
          if (sys == null) return false;
          final items = await DbModule.scenarioRepo.getExplicitItems(sys.id);
          return items.any((e) => e.path == 'a/movie.mp4');
        },
      );

      final sys = await DbModule.scenarioRepo.getSystemPlayingScenario();
      final items = await DbModule.scenarioRepo.getExplicitItems(sys!.id);
      expect(items.map((e) => e.path), contains('a/movie.mp4'));
      expect(useMediaLibBrowserStore().state.openMode, BrowserOpenMode.tabs);
      expect(useSearchBrowserStore().parkedSearchSession, isNull);
      expect(find.text('Play single'), findsOneWidget);
      ds.dispose();
    });
  });

  group('explicit items resolve against the DB (dropped files)', () {
    /// Seeds a file row with explicit metadata so the assertions can prove the
    /// row's data came from the node, not from a synthetic placeholder.
    Future<void> seedVideo(
      String storageId,
      String p, {
      int? durationMs,
      int? sizeInBytes,
    }) async {
      await DbModule.mediaNodesDao.deleteNode(storageId, p);
      final segments = p.split('/');
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 'f:$storageId:$p',
        storageId: storageId,
        path: segments,
        name: segments.last,
        mediaType: MediaType.video,
        durationMs: durationMs,
        sizeInBytes: sizeInBytes,
      ));
    }

    MediaSearchDataSource dataSourceWithExplicit({
      String? scenarioId,
      List<SearchSource> sources = const [],
      List<SearchExplicitItem> explicit = const [],
    }) {
      return MediaSearchDataSource(
        searchContext: SearchContext(
          entryContext: SearchEntryContext.scenarioSourcesRoot,
          scenarioId: scenarioId,
          sources: sources,
          explicitItems: explicit,
        ),
      );
    }

    test('an explicit item present in the DB is available and carries the '
        'node metadata even when no source covers it', () async {
      await seedVideo('s', 'drop/meta.mp4', durationMs: 42000, sizeInBytes: 900);
      final ds = dataSourceWithExplicit(
        scenarioId: 'sc-meta',
        explicit: const [
          SearchExplicitItem(storageId: 's', path: 'drop/meta.mp4'),
        ],
      );

      await ds.submitQuery('meta');

      expect(ds.items, hasLength(1));
      final row = ds.items.single;
      expect(row.origin, SearchResultOrigin.explicitItem);
      expect(row.available, isTrue);
      expect(row.mediaType, MediaType.video);
      expect(row.durationMs, 42000);
      expect(row.sizeInBytes, 900);
      ds.dispose();
    });

    test('an explicit item really absent from the DB stays unavailable and '
        'synthetic', () async {
      final ds = dataSourceWithExplicit(
        scenarioId: 'sc-ghost',
        explicit: const [
          SearchExplicitItem(storageId: 's', path: 'drop/ghost.mp4'),
        ],
      );

      await ds.submitQuery('ghost');

      expect(ds.items, hasLength(1));
      final row = ds.items.single;
      expect(row.origin, SearchResultOrigin.explicitItem);
      expect(row.available, isFalse);
      expect(row.mediaType, MediaType.unknown);
      ds.dispose();
    });

    test('an in-scope explicit item already returned by the DB segment is not '
        'duplicated', () async {
      await seedVideo('s', 'dupdir/dup.mp4');
      final ds = dataSourceWithExplicit(
        scenarioId: 'sc-dup',
        sources: const [
          SearchSource(
            storageId: 's',
            path: 'dupdir',
            kind: MediaSourceKind.directory,
            recursive: true,
          ),
        ],
        explicit: const [
          SearchExplicitItem(storageId: 's', path: 'dupdir/dup.mp4'),
        ],
      );

      await ds.submitQuery('dup');

      expect(ds.items, hasLength(1));
      expect(ds.items.single.origin, SearchResultOrigin.dbSource);
      ds.dispose();
    });

    testWidgets('A (system playing): tapping a dropped explicit item that is '
        'in the DB plays it instead of reporting "not in the media database"',
        (tester) async {
      final store = usePlaybackScenarioStore();
      final sys = await store.ensureSystemPlayingScenario();
      await store.clearSources(sys.id);
      await store.clearExplicitItems(sys.id);
      await seedVideo('s', 'drop/playable.mp4');
      await store.addExplicitItemFor(
        scenarioId: sys.id,
        storageId: 's',
        path: 'drop/playable.mp4',
      );
      useMediaLibBrowserStore().openSearch();
      final ds = dataSourceWithExplicit(
        scenarioId: sys.id,
        explicit: const [
          SearchExplicitItem(storageId: 's', path: 'drop/playable.mp4'),
        ],
      );

      const dropped = SearchResultItem(
        storageId: 's',
        path: 'drop/playable.mp4',
        name: 'playable.mp4',
        mediaType: MediaType.video,
        origin: SearchResultOrigin.explicitItem,
      );

      await tapItem(tester, ds, dropped);
      await pumpUntil(
        tester,
        () async => useSearchBrowserStore().parkedSearchSession == ds,
        'explicit tap did not play + park',
      );
      expect(find.textContaining('不在媒体数据库'), findsNothing);
      ds.dispose();
    });

    testWidgets('A (system playing): an explicit item really absent from the '
        'DB reports the localized not-in-db reason', (tester) async {
      final store = usePlaybackScenarioStore();
      final sys = await store.ensureSystemPlayingScenario();
      await store.clearSources(sys.id);
      await store.clearExplicitItems(sys.id);
      useMediaLibBrowserStore().openSearch();
      final ds = dataSourceWithExplicit(
        scenarioId: sys.id,
        explicit: const [
          SearchExplicitItem(storageId: 's', path: 'drop/ghost2.mp4'),
        ],
      );

      const ghost = SearchResultItem(
        storageId: 's',
        path: 'drop/ghost2.mp4',
        name: 'ghost2.mp4',
        origin: SearchResultOrigin.explicitItem,
        available: false,
      );

      await tapItem(tester, ds, ghost);
      await pumpUntil(
        tester,
        () async => tester.any(find.text('播放出错')),
        'explicit tap did not surface the error dialog',
      );
      expect(find.textContaining('该文件不在媒体数据库中'), findsOneWidget);
      ds.dispose();
    });
  });

  group('tap per context (v15-D2)', () {
    testWidgets('C (media library): tap plays the parent dir directly, no '
        'dialog, and parks + closes the popup when unpinned', (tester) async {
      await seedFile('s', 'a/movie.mp4');
      useMediaLibBrowserStore().openSearch();
      final ds = libDataSource();

      await tapItem(tester, ds, item);
      await pumpUntil(tester, () async {
        final sys = await DbModule.scenarioRepo.getSystemPlayingScenario();
        if (sys == null) return false;
        final sources = await DbModule.scenarioRepo.getSources(sys.id);
        return sources.any((src) => src.path == 'a') &&
            useSearchBrowserStore().parkedSearchSession == ds;
      }, 'C tap did not play parent dir + park');

      expect(useSearchBrowserStore().parkedSearchSession, same(ds));
      expect(useMediaLibBrowserStore().state.openMode, BrowserOpenMode.search);
      // No play-options dialog on click in context C.
      expect(find.text('播放场景'), findsNothing);
      await tester.pump(const Duration(milliseconds: 300)); // popup exit
      expect(find.text('tap item'), findsNothing);
      ds.dispose();
    });

    testWidgets('C (media library): tapping an item whose parent folder is '
        'empty shows the uniform error dialog (v15-D6)', (tester) async {
      // Use a folder no test ever seeds → the parent-folder scope has nothing
      // playable (the shared DB would otherwise leak a prior test's file).
      const missingItem = SearchResultItem(
        storageId: 's',
        path: 'empty-dir/x.mp4',
        name: 'x.mp4',
        origin: SearchResultOrigin.dbSource,
      );
      final ds = libDataSource();

      await tapItem(tester, ds, missingItem);
      await pumpUntil(
        tester,
        () async => tester.any(find.text('播放出错')),
        'C tap did not surface the error dialog',
      );
      expect(find.textContaining('没有可播放的内容'), findsOneWidget);
      // The failed play did NOT commit: the workspace keeps its prior scope
      // (left over from the earlier C-tap test) and gains nothing new.
      final sys = await DbModule.scenarioRepo.getSystemPlayingScenario();
      final sources = await DbModule.scenarioRepo.getSources(sys!.id);
      expect(sources.map((s) => s.path), isNot(contains('empty-dir')));
      ds.dispose();
    });

    testWidgets('B (user scenario): tap opens the play-options dialog with '
        'Play scenario', (tester) async {
      final ds = userScenarioDataSource();

      await tapItem(tester, ds, item);
      await tester.pump(const Duration(milliseconds: 300)); // dialog entrance
      expect(find.text('仅播放该媒体'), findsOneWidget);
      expect(find.text('播放其文件夹'), findsOneWidget);
      expect(find.text('播放场景'), findsOneWidget);
      // No results yet → "Play search result" hidden.
      expect(find.text('播放搜索结果'), findsNothing);
      ds.dispose();
    });

    testWidgets('B (user scenario): Play search result appears when the result '
        'set is non-empty', (tester) async {
      await seedFile('s', 'a/movie.mp4');
      final ds = userScenarioDataSource();
      await tester.runAsync(() => ds.submitQuery('movie'));

      await tapItem(tester, ds, item);
      await tester.pump(const Duration(milliseconds: 300)); // dialog entrance
      expect(find.text('播放搜索结果'), findsOneWidget);
      ds.dispose();
    });

    testWidgets('B (user scenario): Play scenario for a missing scenario shows '
        'the error dialog (v15-D6)', (tester) async {
      // 'sc1' does not exist as a scenario row.
      final ds = userScenarioDataSource();

      await tapItem(tester, ds, item);
      await tester.pump(const Duration(milliseconds: 300)); // dialog entrance
      await tester.tap(find.text('播放场景'));
      await pumpUntil(
        tester,
        () async => tester.any(find.text('播放出错')),
        'Play scenario did not surface the error dialog',
      );
      expect(find.text('被搜索的场景不存在。'), findsOneWidget);
      ds.dispose();
    });

    testWidgets('A (system playing): a non-resolvable item shows the error '
        'dialog — not the play-options dialog (v15-D6)', (tester) async {
      // Give the SystemPlaying workspace a source that does NOT contain the
      // tapped item → resolution returns null cleanly (avoids the empty-queue
      // resolver edge) → the uniform error dialog.
      final store = usePlaybackScenarioStore();
      final sys = await store.ensureSystemPlayingScenario();
      await store.clearSources(sys.id);
      await store.addSource(storageId: 's', path: 'b', recursive: true);
      await seedFile('s', 'b/other.mp4');
      useMediaLibBrowserStore().openSearch();
      final ds = await systemPlayingDataSource();

      await tapItem(tester, ds, item);
      await pumpUntil(
        tester,
        () async => tester.any(find.text('播放出错')),
        'A tap did not surface the error dialog',
      );
      // The uniform error dialog, NOT the play-options dialog.
      expect(find.text('播放场景'), findsNothing);
      expect(find.textContaining('不在当前播放队列中'), findsOneWidget);
      ds.dispose();
    });

    testWidgets('A (system playing): a resolvable item plays directly, parks '
        'and closes the popup when unpinned', (tester) async {
      final store = usePlaybackScenarioStore();
      final sys = await store.ensureSystemPlayingScenario();
      await store.clearSources(sys.id);
      await store.addSource(storageId: 's', path: 'a', recursive: true);
      await seedFile('s', 'a/movie.mp4');
      useMediaLibBrowserStore().openSearch();
      final ds = await systemPlayingDataSource();

      await tapItem(tester, ds, item);
      await pumpUntil(
        tester,
        () async => useSearchBrowserStore().parkedSearchSession == ds,
        'A tap did not play + park',
      );
      expect(useSearchBrowserStore().parkedSearchSession, same(ds));
      // No dialog on click in context A.
      expect(find.text('播放场景'), findsNothing);
      await tester.pump(const Duration(milliseconds: 300)); // popup exit
      expect(find.text('tap item'), findsNothing);
      ds.dispose();
    });
  });
}
