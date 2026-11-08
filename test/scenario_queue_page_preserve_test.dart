import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/queue/paged_scenario_media_data_source.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

/// The scenario queue must not move the viewport when the MEDIA CONTENT
/// revision bumps.
///
/// `sourceScanRevision` is also bumped by the playback-time duration backfill
/// (`MediaRevisionActions.mediaNodesChanged` from the player hooks). Refreshing
/// page 0 there threw the list back to the first page about a second after a row
/// on a later page was tapped. A content refresh re-resolves the CURRENT page;
/// only an explicit navigation (page-size change, sort/shuffle, tag switch)
/// may start over at page 0.
void main() {
  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
  });

  tearDownAll(() => db.close());

  Future<String> workspaceWithFiles(String folder, int count) async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await store.clearSources(sys.id);
    await DbModule.scenarioRepo.addSource(
      scenarioId: sys.id,
      storageId: 'st1',
      path: folder,
      recursive: true,
    );
    for (var i = 0; i < count; i++) {
      final name = 'a${i.toString().padLeft(3, '0')}.mp4';
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
    return sys.id;
  }

  test('source revision bump refreshes in place, keeping the current page',
      () async {
    final id = await workspaceWithFiles('q1', 60);
    final ds = PagedScenarioMediaDataSource(scenarioId: id);
    await ds.fetchPage(0, ds.pageSize);
    expect(ds.totalItems, 60);

    await ds.fetchPage(1, ds.pageSize);
    expect(ds.currentPage, 1, reason: 'second page is the viewport under test');
    expect(ds.items, hasLength(10));

    // A duration backfill / background scan completes while the user reads
    // page 2.
    await usePlaybackScenarioStore().bumpSourceScanRevision();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(ds.currentPage, 1,
        reason: 'a content refresh must not throw the list back to page 1');
    expect(ds.items, hasLength(10));
    ds.dispose();
  });

  test('a current-item switch changes the follow token and notifies the page',
      () async {
    final id = await workspaceWithFiles('q3', 4);
    final store = usePlaybackScenarioStore();
    // The follow token is only exposed for the ACTIVE workspace.
    await store.setActiveScenario(id);
    final page =
        await store.resolvePageFor(id, page: 0, pageSize: 4);
    expect(page.items.length, greaterThanOrEqualTo(2));

    final ds = PagedScenarioMediaDataSource(scenarioId: id);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    var notified = 0;
    ds.addListener(() => notified++);
    final before = ds.currentItemToken;

    // Simulates auto-advance / next: the store books another occurrence.
    await store.setCurrentItem(occurrence: page.items[1].occurrenceId);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(ds.currentItemToken, isNot(before),
        reason: 'the page follows the token, so it must move with the item');
    expect(notified, greaterThan(0),
        reason: 'the data source must wake the page on a current-item switch');
    ds.dispose();
  });

  test('content shrink clamps the viewport to the last remaining page',
      () async {
    final id = await workspaceWithFiles('q2', 60);
    final ds = PagedScenarioMediaDataSource(scenarioId: id);
    await ds.fetchPage(0, ds.pageSize);
    await ds.fetchPage(1, ds.pageSize);
    expect(ds.currentPage, 1);

    // Removing 40 rows leaves one page; page 2 no longer exists.
    for (var i = 20; i < 60; i++) {
      await DbModule.mediaNodesDao
          .deleteNode('st1', 'q2/a${i.toString().padLeft(3, '0')}.mp4');
    }
    await usePlaybackScenarioStore().bumpSourceScanRevision();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(ds.totalItems, 20);
    expect(ds.currentPage, 0,
        reason: 'an out-of-range page must clamp to the last page, not stay '
            'empty above the counter');
    expect(ds.items, hasLength(20));
    ds.dispose();
  });
}
