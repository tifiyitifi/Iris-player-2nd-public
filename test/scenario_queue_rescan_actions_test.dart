import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/scenario_playback/actions/scenario_media_rescan_actions.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/origin_reference.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/queue/paged_scenario_media_data_source.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/models/db/storage_path_codec.dart';

/// The scenario queue row's desktop rescan trio: this file / its containing
/// folder / its origin source. The scopes' root derivations are pure; the menu
/// entries are desktop-only and grey "rescan source" for a row that has no
/// originating source (an explicit single-file pick) instead of hiding it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScenarioRescanTargets (pure)', () {
    test('parentRoot drops the file name', () {
      expect(
        ScenarioRescanTargets.parentRoot(['root', 'q1', 'a.mp4']),
        ['root', 'q1'],
      );
    });

    test('parentRoot of a base-less file is the storage root', () {
      expect(ScenarioRescanTargets.parentRoot(['a.mp4']), isEmpty);
    });

    test('sourceRoot of an empty path is the storage base', () {
      const source = ScenarioSource(
        id: 1,
        scenarioId: 's',
        storageId: 'st',
        path: '',
      );
      final storage = Storage.local(
        id: 'st',
        type: StorageType.internal,
        name: 't',
        basePath: const ['root'],
      );
      expect(ScenarioRescanTargets.sourceRoot(source, storage), 'root');
    });

    test('sourceRoot of a folder source is its saved path', () {
      const source = ScenarioSource(
        id: 1,
        scenarioId: 's',
        storageId: 'st',
        path: 'q1/sub',
        recursive: true,
      );
      final storage = Storage.local(
        id: 'st',
        type: StorageType.internal,
        name: 't',
        basePath: const ['root'],
      );
      expect(ScenarioRescanTargets.sourceRoot(source, storage), 'q1/sub');
    });

    test('sourceRoot absolutizes a storage-relative path (scan-service form)',
        () {
      StoragePathCodec.baseResolver =
          (id) => id == 'st' ? const ['root'] : null;
      try {
        const source = ScenarioSource(
          id: 1,
          scenarioId: 's',
          storageId: 'st',
          path: 'q1/sub',
          recursive: true,
        );
        final storage = Storage.local(
          id: 'st',
          type: StorageType.internal,
          name: 't',
          basePath: const ['root'],
        );
        expect(
            ScenarioRescanTargets.sourceRoot(source, storage), 'root/q1/sub');
        // A base-inclusive row stays idempotent.
        const abs = ScenarioSource(
          id: 1,
          scenarioId: 's',
          storageId: 'st',
          path: 'root/q1/sub',
          recursive: true,
        );
        expect(ScenarioRescanTargets.sourceRoot(abs, storage), 'root/q1/sub');
      } finally {
        StoragePathCodec.baseResolver = (_) => null;
      }
    });
  });

  group('ScenarioMediaRescanActions presence (pure)', () {
    const dirEntry = FileItem(name: 'movie.mkv', uri: '', isDir: true);
    const fileEntry = FileItem(name: 'movie.mkv', uri: '');

    test('case-sensitive filesystems require an exact name', () {
      // POSIX: `Movie.MKV` renamed to `movie.mkv` is a different file, so the
      // old node is genuinely absent and must be deletable.
      expect(
        ScenarioMediaRescanActions.filePresent(
          listed: const [FileItem(name: 'other.mp4', uri: '')],
          name: 'Movie.MKV',
          foldCase: false,
        ),
        isFalse,
      );
      expect(
        ScenarioMediaRescanActions.filePresent(
          listed: const [FileItem(name: 'movie.mkv', uri: '')],
          name: 'Movie.MKV',
          foldCase: false,
        ),
        isFalse,
      );
    });

    test('case-insensitive filesystems match a case-only rename', () {
      expect(
        ScenarioMediaRescanActions.filePresent(
          listed: const [FileItem(name: 'movie.mkv', uri: '')],
          name: 'Movie.MKV',
          foldCase: true,
        ),
        isTrue,
      );
    });

    test('directories never satisfy a file presence check', () {
      expect(
        ScenarioMediaRescanActions.filePresent(
          listed: const [dirEntry],
          name: 'movie.mkv',
          foldCase: true,
        ),
        isFalse,
      );
    });

    test('an exact match works on either filesystem', () {
      expect(
        ScenarioMediaRescanActions.filePresent(
          listed: const [fileEntry],
          name: 'movie.mkv',
          foldCase: false,
        ),
        isTrue,
      );
    });

    test('foldsCaseFor: network folds, POSIX/SAF stay sensitive', () {
      final network = Storage.local(
        id: 'n',
        type: StorageType.network,
        name: 'NAS',
        basePath: const [r'\\server\share'],
      );
      final windowsDrive = Storage.local(
        id: 'd',
        type: StorageType.internal,
        name: 'D',
        basePath: const ['D:'],
      );
      final android = Storage.local(
        id: 'a',
        type: StorageType.internal,
        name: 'A',
        basePath: const ['storage/emulated/0'],
      );
      expect(
        ScenarioMediaRescanActions.foldsCaseFor(
            network, const ['server', 'share', 'a.mp4']),
        isTrue,
      );
      expect(
        ScenarioMediaRescanActions.foldsCaseFor(
            windowsDrive, const ['D:', 'Movies', 'a.mp4']),
        isTrue,
      );
      expect(
        ScenarioMediaRescanActions.foldsCaseFor(
            android, const ['storage', 'emulated', '0', 'a.mp4']),
        isFalse,
      );
    });
  });

  group('queue trailing rescan trio', () {
    setUpAll(() async {
      final db = AppDatabase(NativeDatabase.memory());
      DbModule.init(db);
      usePlaybackScenarioStore();
      await usePlaybackScenarioStore().initialized;
      usePlayQueueStore();
      await usePlayQueueStore().initialized;
      useAppStore();
      await useAppStore().initialized;
      // The row's storage must be registered: a rescan scope needs the Storage
      // object, so an unknown storage greys the entries (offline-grey parity).
      useStorageStore();
      await useStorageStore().initialized;
      await useStorageStore().addStorage(Storage.local(
        id: 'st1',
        type: StorageType.internal,
        name: 'Local',
        basePath: const ['root'],
      ));
    });

    tearDown(() {
      debugIsMobilePlatformOverride = null;
    });

    /// A resolved-looking file row; only the fields the menu reads are set.
    EffectivePlaybackItem fileRow({required List<OriginReference> origins}) =>
        EffectivePlaybackItem(
          media: MediaNode.file(
            id: 'f:st1:q1/a.mp4',
            storageId: 'st1',
            path: const ['q1', 'a.mp4'],
            name: 'a.mp4',
            mediaType: MediaType.video,
          ),
          scenarioId: 'scn',
          origins: origins,
          virtualIndex: 0,
          occurrenceId: const PlaybackOccurrenceId(
            storageId: 'st1',
            path: 'q1/a.mp4',
          ),
        );

    /// Builds the row's trailing actions with the queue data source mounted.
    /// Deliberately synchronous (no awaited fetch): the menu depends only on the
    /// passed row plus app/platform state. `getItemTrailingActions` requires a
    /// `StoreScope` ancestor.
    ///
    /// Two call styles are exercised, because the production row uses both:
    /// `actionsFor` (during build, from the trailing "more" button) and
    /// [actionsOutsideBuild] (from the desktop right-click gesture callback).
    Future<List<GenericItemAction<EffectivePlaybackItem>>> actionsFor(
      WidgetTester tester,
      EffectivePlaybackItem item,
    ) async {
      final ds = PagedScenarioMediaDataSource(scenarioId: 'scn');
      addTearDown(ds.dispose);
      late List<GenericItemAction<EffectivePlaybackItem>> actions;
      await tester.pumpWidget(StoreScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(builder: (context) {
              actions = ds.getItemTrailingActions(context, item);
              return const SizedBox();
            }),
          ),
        ),
      ));
      // Let the deferred localization delegate resolve, then render the frame
      // whose Builder captures the actions.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      return actions;
    }

    /// Same, but the call happens OUTSIDE build — exactly how the right-click
    /// menu reaches it (a gesture callback, not a `build` method).
    ///
    /// The Builder only captures the context; the provider assertion that
    /// `select` carries (`debugDoingBuild`) is what the right-click path trips.
    Future<List<GenericItemAction<EffectivePlaybackItem>>> actionsOutsideBuild(
      WidgetTester tester,
      EffectivePlaybackItem item,
    ) async {
      final ds = PagedScenarioMediaDataSource(scenarioId: 'scn');
      addTearDown(ds.dispose);
      late BuildContext captured;
      await tester.pumpWidget(StoreScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(builder: (context) {
              captured = context;
              return const SizedBox();
            }),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      // Not during build: any reactive `select(context, …)` inside the action
      // builder throws here (see the desktop right-click regression).
      return ds.getItemTrailingActions(captured, item);
    }

    AppLocalizations loc(WidgetTester tester) =>
        AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

    testWidgets('desktop row offers file / folder / source rescan',
        (tester) async {
      final actions = await actionsFor(
        tester,
        fileRow(
          origins: const [
            OriginReference(sourceId: 1, sourceKind: ScenarioSourceKind.folder),
          ],
        ),
      );
      final t = loc(tester);
      final labels = actions.map((a) => a.label).toSet();
      expect(labels, contains(t.scn_rescan_file));
      expect(labels, contains(t.scn_rescan_dir));
      expect(labels, contains(t.scn_rescan_source));
      // A folder-source row has an origin and the storage is online by default.
      final source =
          actions.singleWhere((a) => a.label == t.scn_rescan_source);
      expect(source.enabled, isTrue);
    });

    testWidgets('right-click (out-of-build) action build does not throw',
        (tester) async {
      // Regression: the row is right-clicked from a gesture callback, where
      // provider's `context.select` asserts. The actions must be buildable
      // there or every right-click throws before `showMenu` runs (silently
      // dead context menu + an unhandled exception per click).
      final actions = await actionsOutsideBuild(
        tester,
        fileRow(
          origins: const [
            OriginReference(sourceId: 1, sourceKind: ScenarioSourceKind.folder),
          ],
        ),
      );
      final t = loc(tester);
      final labels = actions.map((a) => a.label).toSet();
      expect(labels, contains(t.scn_rescan_file));
      expect(labels, contains(t.scn_rescan_dir));
      expect(labels, contains(t.scn_rescan_source));
      // The pre-existing actions survive the non-build call too.
      expect(labels, contains(t.open_in_folder));
      expect(labels, contains(t.scn_add_perm_exclude));
      expect(labels, contains(t.scn_add_source_exclude));
    });

    testWidgets('explicit pick greys (never hides) rescan source',
        (tester) async {
      final actions = await actionsFor(tester, fileRow(origins: const []));
      final t = loc(tester);
      final source = actions.where((a) => a.label == t.scn_rescan_source);
      expect(source, hasLength(1), reason: 'greyed, not hidden');
      expect(source.single.enabled, isFalse);
      // File/folder scopes stay available for an explicit row.
      expect(actions.map((a) => a.label), contains(t.scn_rescan_file));
      expect(actions.map((a) => a.label), contains(t.scn_rescan_dir));
    });

    testWidgets('mobile hides the rescan trio and the row context menu',
        (tester) async {
      debugIsMobilePlatformOverride = true;
      final ds = PagedScenarioMediaDataSource(scenarioId: 'scn');
      addTearDown(ds.dispose);
      final actions = await actionsFor(
        tester,
        fileRow(
          origins: const [
            OriginReference(sourceId: 1, sourceKind: ScenarioSourceKind.folder),
          ],
        ),
      );
      final t = loc(tester);
      expect(actions.map((a) => a.label), isNot(contains(t.scn_rescan_file)));
      expect(actions.map((a) => a.label), isNot(contains(t.scn_rescan_dir)));
      expect(actions.map((a) => a.label), isNot(contains(t.scn_rescan_source)));
      expect(ds.supportsRowContextMenu, isFalse);
    });

    testWidgets('row whose storage is gone greys every rescan scope',
        (tester) async {
      // A scope needs the Storage object; offering it enabled would make the
      // click silently no-op. Grey instead (same convention as offline).
      // The row on a storage that is still registered stays enabled (above).
      const row = EffectivePlaybackItem(
        media: MediaNode.file(
          id: 'f:ghost:vanished.mp4',
          storageId: 'ghost-storage',
          path: ['vanished.mp4'],
          name: 'vanished.mp4',
          mediaType: MediaType.video,
        ),
        scenarioId: 'scn',
        origins: [
          OriginReference(sourceId: 1, sourceKind: ScenarioSourceKind.folder),
        ],
        virtualIndex: 0,
        occurrenceId: PlaybackOccurrenceId(
          storageId: 'ghost-storage',
          path: 'vanished.mp4',
        ),
      );
      final actions = await actionsFor(tester, row);
      final t = loc(tester);
      for (final action in actions) {
        if (action.label == t.scn_rescan_file ||
            action.label == t.scn_rescan_dir ||
            action.label == t.scn_rescan_source) {
          expect(action.enabled, isFalse, reason: action.label);
        }
      }
    });
  });
}
