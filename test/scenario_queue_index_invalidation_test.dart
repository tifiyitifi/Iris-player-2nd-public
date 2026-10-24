import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

/// The derived index is invalidated by CONTENT, not by activity: a scenario
/// switch reuses both generations, while a definition edit (even one made
/// outside the store), a media rescan or a VM rule edit rebuilds the generation.
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

  test('a scenario switch reuses both generations', () async {
    final store = usePlaybackScenarioStore();
    final a = await scenarioWith('sw-a', 'a.mp4');
    final b = await scenarioWith('sw-b', 'b.mp4');

    await store.setActiveScenario(a);
    await store.resolvePage(page: 0, pageSize: 10);
    final buildA = await indexDao.currentBuildId(a);

    await store.setActiveScenario(b);
    await store.resolvePage(page: 0, pageSize: 10);
    final buildB = await indexDao.currentBuildId(b);

    await store.setActiveScenario(a);
    await store.resolvePage(page: 0, pageSize: 10);

    expect(buildA, greaterThan(0));
    expect(buildB, greaterThan(0));
    expect(buildB, isNot(buildA));
    expect(await indexDao.currentBuildId(a), buildA,
        reason: 'switching back must not rebuild A');
    expect(await indexDao.currentBuildId(b), buildB,
        reason: 'switching away must not touch B');
  });

  test('a source edit made outside the store rebuilds the generation',
      () async {
    final store = usePlaybackScenarioStore();
    final id = await scenarioWith('edit-a', 'a.mp4');
    await store.setActiveScenario(id);
    await store.resolvePage(page: 0, pageSize: 10);
    final before = await indexDao.currentBuildId(id);

    // The sources / browse pages write through the repository and bump no
    // store revision at all.
    await seedFile('edit-b', 'b.mp4');
    await DbModule.scenarioRepo.addSource(
      scenarioId: id,
      storageId: 'st1',
      path: 'edit-b',
      recursive: true,
    );

    final page = await store.resolvePage(page: 0, pageSize: 10);
    expect(page.totalItems, 2);
    expect(await indexDao.currentBuildId(id), greaterThan(before));
  });

  test('a media rescan rebuilds the generation', () async {
    final store = usePlaybackScenarioStore();
    final id = await scenarioWith('scan-a', 'a.mp4');
    await store.setActiveScenario(id);
    await store.resolvePage(page: 0, pageSize: 10);
    final before = await indexDao.currentBuildId(id);

    await seedFile('scan-a', 'b.mp4');
    await store.bumpSourceScanRevision();

    final page = await store.resolvePage(page: 0, pageSize: 10);
    expect(page.totalItems, 2);
    expect(await indexDao.currentBuildId(id), greaterThan(before));
  });

  test('a rescan of an unrelated storage does not rebuild the generation',
      () async {
    final store = usePlaybackScenarioStore();
    final id = await scenarioWith('scope-a', 'a.mp4');
    await store.setActiveScenario(id);
    await store.resolvePage(page: 0, pageSize: 10);
    final before = await indexDao.currentBuildId(id);

    // Only storages this scenario references can change what it resolves to.
    await store.bumpSourceScanRevision(storages: {'st2'});
    await store.resolvePage(page: 0, pageSize: 10);
    expect(await indexDao.currentBuildId(id), before,
        reason: 'an unrelated storage rescan must not rebuild');

    // A rescan of THIS scenario's storage must invalidate it.
    await store.bumpSourceScanRevision(storages: {'st1'});
    await store.resolvePage(page: 0, pageSize: 10);
    expect(await indexDao.currentBuildId(id), greaterThan(before));
  });

  test('a VM rule edit rebuilds the generation', () async {
    final store = usePlaybackScenarioStore();
    final id = await scenarioWith('vm-a', 'a.mp4');
    await store.setActiveScenario(id);
    await store.resolvePage(page: 0, pageSize: 10);
    final before = await indexDao.currentBuildId(id);

    VirtualMediaService.instance.invalidate();

    await store.resolvePage(page: 0, pageSize: 10);
    expect(await indexDao.currentBuildId(id), greaterThan(before));
  });

  test('a duration heal rebuilds the generation', () async {
    final store = usePlaybackScenarioStore();
    final id = await scenarioWith('dur-a', 'a.mp4');
    await store.setActiveScenario(id);
    await store.resolvePage(page: 0, pageSize: 10);
    final before = await indexDao.currentBuildId(id);

    // A VM duration scan/heal writes durations that feed duration sorts and
    // VM caps; it must invalidate the derived index too.
    await VirtualMediaService.instance.notifyDurationsChanged();

    await store.resolvePage(page: 0, pageSize: 10);
    expect(await indexDao.currentBuildId(id), greaterThan(before));
  });

  test('a fresh store reuses the persisted generation (cold start)', () async {
    final store = usePlaybackScenarioStore();
    final id = await scenarioWith('cold-a', 'a.mp4');
    await store.setActiveScenario(id);
    await store.resolvePage(page: 0, pageSize: 10);
    final built = await indexDao.currentBuildId(id);
    expect(built, greaterThan(0));

    // Simulate an app restart: a brand-new store whose in-memory build map is
    // empty. It must reuse the stored generation instead of re-walking.
    final restarted = PlaybackScenarioStore();
    await restarted.initialized;
    await restarted.setActiveScenario(id);
    await restarted.resolvePage(page: 0, pageSize: 10);

    expect(await indexDao.currentBuildId(id), built,
        reason: 'cold start must reuse the persisted generation');
    await restarted.dispose();
  });

  test('a viewed non-active scenario is not evicted', () async {
    final store = usePlaybackScenarioStore();
    final ids = <String>[];
    for (var i = 0; i < PlaybackScenarioStore.kQueueIndexRetention; i++) {
      final id = await scenarioWith('view-$i', 'a$i.mp4');
      await store.setActiveScenario(id);
      await store.resolvePage(page: 0, pageSize: 10);
      ids.add(id);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }

    // Page the OLDEST scenario WITHOUT making it active (the queue can show a
    // non-active scenario), then push past the cap with one more build.
    await store.resolvePageFor(ids.first, page: 0, pageSize: 10);
    final extra = await scenarioWith('view-extra', 'x.mp4');
    await store.setActiveScenario(extra);
    await store.resolvePage(page: 0, pageSize: 10);

    final materialized = await indexDao.materializedScenarioIds();
    expect(materialized.length,
        lessThanOrEqualTo(PlaybackScenarioStore.kQueueIndexRetention));
    expect(materialized, contains(ids.first),
        reason: 'the scenario being viewed must survive eviction');
  });

  test('a generation evicted by another window rebuilds on the next read',
      () async {
    final store = usePlaybackScenarioStore();
    final id = await scenarioWith('evicted-a', 'a.mp4');
    await store.setActiveScenario(id);
    await store.resolvePage(page: 0, pageSize: 10);
    final before = await indexDao.currentBuildId(id);
    expect(before, greaterThan(0));

    // Another window's retention pass drops this scenario's generation while
    // this window still holds a matching signature for it.
    await indexDao.clearScenario(id);

    final page = await store.resolvePage(page: 0, pageSize: 10);
    expect(page.items, isNotEmpty);
    expect(await indexDao.currentBuildId(id), greaterThan(before),
        reason: 'a vanished generation must rebuild instead of leaving this '
            'window on the legacy walk for the rest of the session');
  });

  test('retention keeps only the most-recently-used generations', () async {
    final store = usePlaybackScenarioStore();
    final ids = <String>[];
    for (var i = 0; i < PlaybackScenarioStore.kQueueIndexRetention + 1; i++) {
      final id = await scenarioWith('lru-$i', 'a$i.mp4');
      await store.setActiveScenario(id);
      await store.resolvePage(page: 0, pageSize: 10);
      ids.add(id);
      // Distinct use stamps so the LRU order is deterministic.
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }

    final materialized = await indexDao.materializedScenarioIds();
    expect(materialized.length,
        lessThanOrEqualTo(PlaybackScenarioStore.kQueueIndexRetention));
    expect(materialized, isNot(contains(ids.first)),
        reason: 'the least-recently-used generation must be evicted');

    // An evicted scenario is still correct — it just rebuilds on next read.
    final page = await store.resolvePageFor(ids.first, page: 0, pageSize: 10);
    expect(page.items, isNotEmpty);
  });
}
