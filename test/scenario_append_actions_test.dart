import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/actions/scenario_append_actions.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/path_conv.dart';

/// F-009 / D16 / D12: the shared append action supports mixed file + directory
/// appends; the plain variant early-returns only when BOTH are empty, while
/// the WithFeedback variant still reports "added 0 items".
void main() {
  setUpAll(() async {
    final db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    await runZonedGuarded(() async {
      usePlayQueueStore();
      await usePlayQueueStore().initialized;
      useAppStore();
      await useAppStore().initialized;
    }, (Object e, StackTrace st) {});
  });

  setUp(() async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await store.setActiveScenario(sys.id);
    await store.clearSources(sys.id);
    await store.clearExplicitItems(sys.id);
    await store.clearTemporaryExcludes(sys.id);
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

  FileItem fileItem(String storageId, String p) {
    final segments = p.split('/');
    return FileItem(
      storageId: storageId,
      storageType: StorageType.none,
      name: segments.last,
      uri: '/$p',
      path: segments,
      size: 0,
      type: ContentType.video,
    );
  }

  Future<List<String>> explicitPaths() async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    final items = await DbModule.scenarioRepo.getExplicitItems(sys.id);
    return items.map((e) => e.path).toList();
  }

  test('append adds sources and explicit items (F-009)', () async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await seedFile('s', 'a/x.mp4');

    await ScenarioAppendActions.appendToDefaultScenario(
      [fileItem('s', 'b.mp4')],
      directories: const [
        (
          storageId: 's',
          path: 'a',
          recursive: true,
          kind: ScenarioSourceKind.folder,
        ),
      ],
    );

    final srcs = await store.getSources(sys.id);
    expect(srcs.where((s) => s.path == 'a').first.recursive, isTrue);
    expect(await explicitPaths(), contains('b.mp4'));
  });

  test('plain append early-returns only when files AND dirs are empty (v2-D3)',
      () async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();

    await ScenarioAppendActions.appendToDefaultScenario(const []);
    expect(await store.getSources(sys.id), isEmpty);
    expect(await explicitPaths(), isEmpty);

    await ScenarioAppendActions.appendToDefaultScenario(
      const [],
      directories: const [
        (
          storageId: 's',
          path: 'd',
          recursive: false,
          kind: ScenarioSourceKind.folder,
        ),
      ],
    );
    final srcs = await store.getSources(sys.id);
    expect(srcs.where((s) => s.path == 'd').first.recursive, isFalse);
  });

  test('a path-less SAF single pick is appended by its uri, not dropped',
      () async {
    // Two picks of ONE storage: both must land and both must RESOLVE. The old
    // `path.isNotEmpty` filter threw every SAF single pick away, and the
    // scenario table's UNIQUE(scenario_id, storage_id, path) collapsed them.
    const u1 = 'content://doc/one';
    const u2 = 'content://doc/two';
    for (final (uri, name) in const [(u1, 'one.mp4'), (u2, 'two.mp4')]) {
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 'saf:$uri',
        storageId: 's',
        path: const <String>[],
        name: name,
        mediaType: MediaType.video,
        uri: uri,
      ));
    }

    await ScenarioAppendActions.appendToDefaultScenario([
      const FileItem(
        storageId: 's',
        name: 'one.mp4',
        uri: u1,
        type: ContentType.video,
      ),
      const FileItem(
        storageId: 's',
        name: 'two.mp4',
        uri: u2,
        type: ContentType.video,
      ),
    ]);

    // Stored in the DB-canonical form (the scenario DAO canonicalizes, like
    // `media_nodes.path`).
    expect(
      await explicitPaths(),
      containsAll(<String>[canonicalDbPath(u1), canonicalDbPath(u2)]),
    );

    // The chain must resolve: the explicit path is looked up in `media_nodes`
    // (a path-less SAF row is keyed by that same canonical uri).
    final page =
        await usePlaybackScenarioStore().resolvePage(page: 0, pageSize: 10);
    expect(
      page.items.map((e) => e.media.name).toSet(),
      containsAll(<String>{'one.mp4', 'two.mp4'}),
    );
  });

  test('append honors dir.recursive and empty-path storage root (v2-D1/F-009)',
      () async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();

    await ScenarioAppendActions.appendToDefaultScenario(
      const [],
      directories: const [
        (
          storageId: 's',
          path: '',
          recursive: true,
          kind: ScenarioSourceKind.folder,
        ),
      ],
    );
    final srcs = await store.getSources(sys.id);
    expect(srcs.map((s) => s.path), contains(''));
    expect(srcs.first.recursive, isTrue);
  });

  testWidgets('WithFeedback with empty input still shows "added 0 items" (D16)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () =>
                  ScenarioAppendActions.appendToDefaultScenarioWithFeedback(
                      context, const []),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    // Deferred l10n delegates load async — settle once before tapping.
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('已添加到播放队列'), findsOneWidget);
    expect(find.text('添加后：0 项（新增 0 项）'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(AlertDialog), findsNothing);
  });
}
