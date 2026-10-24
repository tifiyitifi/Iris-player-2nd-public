import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/path_conv.dart';

/// Physical-delete advance regression.
///
/// The field failure this pins: after Shift+Delete removed the file, the
/// persisted occurrence was re-resolved through a still-stale derived index,
/// re-persisted as current and RE-FED to the player. The backend's open handle
/// survives a recycle-bin rename, so the deleted file kept playing and the queue
/// appeared frozen. `revalidateCurrent(skipMediaKeys:)` must walk past the
/// deleted key instead of re-feeding it.
void main() {
  late AppDatabase db;
  late PlaybackScenarioStore store;
  late ScenarioPlaybackProvider provider;

  setUpAll(() {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
  });

  tearDownAll(() async {
    await db.close();
  });

  setUp(() async {
    await db.customStatement('DELETE FROM media_nodes');
    await db.customStatement('DELETE FROM scenario');
    await db.customStatement('DELETE FROM scenario_sources');
    await db.customStatement('DELETE FROM scenario_explicit_items');
    await db.customStatement('DELETE FROM scenario_excludes');
    await db.customStatement('DELETE FROM scenario_state');
    await usePlayQueueStore().initialized;
    await usePlayQueueStore().clear();
    store = PlaybackScenarioStore();
    await store.initialized;
    provider = ScenarioPlaybackProvider(store: store);
  });

  tearDown(() async {
    await store.dispose();
  });

  Future<void> seed(String name) async {
    await MediaNodesDao(db).insertNode(
      MediaNode.file(
        id: name,
        storageId: 'st1',
        path: <String>['A', name],
        parentPath: 'A',
        pathDepth: 2,
        name: name,
        mediaType: MediaType.video,
      ),
    );
  }

  Future<String> scenario({List<String> files = const ['ep01.mp4']}) async {
    // A real scan always has the source directory row; without it the resolver
    // emits a directory placeholder for the now-empty source and the advance
    // would feed that instead of reporting "nothing left".
    await MediaNodesDao(db).insertNode(
      MediaNode.directory(
        id: 'A',
        storageId: 'st1',
        path: const <String>['A'],
        pathDepth: 1,
        name: 'A',
      ),
    );
    // A scanned source emits no "unscanned source" placeholder row; without
    // this the resolver synthesizes one for the (now empty) directory and the
    // advance would feed that instead of reporting "nothing left".
    await db.customStatement(
      "UPDATE media_nodes SET is_scan_done = 1, scan_state = 'scanDone' "
      "WHERE path = 'A'",
    );
    for (final name in files) {
      await seed(name);
    }
    final s = await DbModule.scenarioRepo.createScenario(name: 'S');
    await store.setActiveScenario(s.id);
    await DbModule.scenarioRepo.addSource(
      scenarioId: s.id,
      storageId: 'st1',
      path: 'A',
      recursive: true,
    );
    return s.id;
  }

  String fedFile() => usePlayQueueStore()
      .state
      .playQueue
      .last
      .file
      .path
      .last;

  test('a stale index is walked past instead of re-feeding the deleted file',
      () async {
    await scenario(files: ['ep01.mp4', 'ep02.mp4', 'ep03.mp4']);
    await store.setCurrentItem(
      occurrence:
          const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep02.mp4'),
      virtualPos: 1,
    );
    // Builds the derived index with ep02 still at 1 (the stale generation the
    // player re-resolved through in the field log).
    expect(await provider.establishCurrentPosition(), 1);

    // The DB row is gone, but the media revision is NOT bumped in this test —
    // the index generation therefore still serves ep02 at position 1.
    await MediaNodesDao(db).deleteNodeAcrossScopes(
      storageId: 'st1',
      scopeIds: const {'st1'},
      rawPath: 'A/ep02.mp4',
    );

    final advanced = await provider.revalidateCurrent(
      skipMediaKeys: {canonicalKey('st1', 'A/ep02.mp4')},
    );

    expect(advanced, isTrue);
    expect(fedFile(), 'ep03.mp4');
    final state = await store.activeState();
    expect(state?.currentPlaybackOccurrence?.path, 'A/ep03.mp4');
  });

  test('no surviving entry reports false so the caller can unload the feed',
      () async {
    await scenario(files: ['ep01.mp4']);
    await store.setCurrentItem(
      occurrence:
          const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep01.mp4'),
      virtualPos: 0,
    );
    expect(await provider.establishCurrentPosition(), 0);

    await MediaNodesDao(db).deleteNodeAcrossScopes(
      storageId: 'st1',
      scopeIds: const {'st1'},
      rawPath: 'A/ep01.mp4',
    );

    final advanced = await provider.revalidateCurrent(
      skipMediaKeys: {canonicalKey('st1', 'A/ep01.mp4')},
    );

    expect(advanced, isFalse);
  });

  test('without a skip set a still-present current entry does not advance',
      () async {
    await scenario(files: ['ep01.mp4', 'ep02.mp4']);
    await store.setCurrentItem(
      occurrence:
          const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep01.mp4'),
      virtualPos: 0,
    );

    expect(await provider.revalidateCurrent(), isFalse);
  });
}
