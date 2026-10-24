import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

/// Two windows are two PROCESSES over ONE database (see `AppInstance`), so the
/// derived queue index has to stay coherent across them: the media revisions the
/// signature keys on live in `app_meta`, and the generation itself is a shared
/// row set both windows read through `currentBuildId`.
///
/// Own file / own in-memory database on purpose: the retention pass evicts
/// generations once more than `kQueueIndexRetention` scenarios are materialized,
/// so sharing a database with the invalidation suite would evict the very
/// generation under test.
void main() {
  late AppDatabase db;
  late ScenarioQueueIndexDao indexDao;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
    indexDao = ScenarioQueueIndexDao(db);
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
  });

  tearDownAll(() => db.close());

  Future<void> seedFile(String folder, String name) async {
    try {
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 'f:st1:$folder/$name',
        storageId: 'st1',
        path: [folder, name],
        name: name,
        mediaType: MediaType.video,
      ));
    } catch (_) {}
  }

  Future<String> scenarioWith(String folder, String name) async {
    final s = await DbModule.scenarioRepo.createScenario(name: folder);
    await DbModule.scenarioRepo.addSource(
      scenarioId: s.id,
      storageId: 'st1',
      path: folder,
      recursive: true,
    );
    await seedFile(folder, name);
    return s.id;
  }

  test('a scan in ANOTHER window reaches this window\'s warm generation',
      () async {
    // Two stores = two windows over ONE shared database.
    final a = PlaybackScenarioStore();
    await a.initialized;
    final b = PlaybackScenarioStore();
    await b.initialized;

    final id = await scenarioWith('xwin-a', 'a.mp4');
    await a.setActiveScenario(id);
    await a.resolvePage(page: 0, pageSize: 10);
    final first = await indexDao.currentBuildId(id);
    expect(first, greaterThan(0));

    // Window B opened the same queue and reused A's persisted generation.
    await b.setActiveScenario(id);
    await b.resolvePage(page: 0, pageSize: 10);
    expect(await indexDao.currentBuildId(id), first);

    // Window A scans. Only the shared database revision moves — nothing about
    // it reaches B's memory.
    await seedFile('xwin-a', 'b.mp4');
    await a.bumpSourceScanRevision(storages: {'st1'});
    await a.resolvePage(page: 0, pageSize: 10);
    expect(await indexDao.currentBuildId(id), greaterThan(first));

    // B must notice the shared revision instead of serving its stale
    // generation: the old code cached the revisions in memory, so B's signature
    // never changed. Its count path must also stop handing out the dead build
    // id (the store's id is what `indexedTotalCount` uses).
    final page = await b.resolvePage(page: 0, pageSize: 10);
    expect(page.totalItems, 2);
    expect(await b.indexedTotalCount(), 2);

    await a.dispose();
    await b.dispose();
  });
}
