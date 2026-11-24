import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/queue/paged_scenario_media_data_source.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

import 'helpers/sqlite3_loader.dart';

/// A Virtual Media rule change must reach the ALREADY-OPEN play queue.
///
/// The desktop playlist dock is mounted for the whole session and its data
/// source re-fetches on `sourceScanRevision` only — `playbackVersion` is
/// deliberately ignored there, because the paths that bump it already fetch
/// explicitly. A rule change therefore has to bump BOTH revisions, or the dock
/// keeps rendering the pre-change rows (separate files instead of the merged
/// one, or the reverse) until the user reopens it: the reported desktop bug.
/// `notifyRulesChanged` is the single choke point every VM mutation goes
/// through, so the contract is asserted against it rather than each caller.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  late String scenarioId;

  Future<void> seedMedia(String path, {int durationMs = 60000}) async {
    final parts = path.split('/');
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: path,
      storageId: 'st1',
      path: parts,
      parentPath: parts.length <= 1
          ? null
          : parts.sublist(0, parts.length - 1).join('/'),
      name: parts.last,
      mediaType: MediaType.video,
      durationMs: durationMs,
    ));
  }

  /// Waits for the data source's in-flight fetch (and the notify that follows
  /// it) to land. The constructor kicks one off synchronously.
  Future<void> settle(PagedScenarioMediaDataSource ds) async {
    for (var i = 0; i < 100 && ds.isLoading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  Future<String> scenarioWithSource(String folder) async {
    await DbModule.scenarioRepo.addSource(
      scenarioId: scenarioId,
      storageId: 'st1',
      path: folder,
      recursive: true,
    );
    return scenarioId;
  }

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
    PlaybackProviderRegistry.init();
  });

  tearDownAll(() async {
    await db.close();
  });

  setUp(() async {
    for (final t in const [
      'media_nodes',
      'scenario',
      'scenario_sources',
      'scenario_explicit_items',
      'scenario_excludes',
      'scenario_state',
      'vm_rules',
      'virtual_media_states',
      'vm_progress',
      'scenario_queue_builds',
      'scenario_shared_index',
      'media_orders',
    ]) {
      await db.customStatement('DELETE FROM $t');
    }
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: true,
          useLegacyStoragePersistence: false,
          useScenarioDrivenPlayback: true,
        ));
    VirtualMediaService.instance.invalidate();
    await usePlayQueueStore().clear();
    await useAppStore().updateAutoPlay(false);
    final sys = await usePlaybackScenarioStore().ensureSystemPlayingScenario();
    await usePlaybackScenarioStore().setActiveScenario(sys.id);
    scenarioId = sys.id;
  });

  test('a rule change re-fetches the open queue and merges the rows', () async {
    await scenarioWithSource('d');
    await seedMedia('d/a.mp4');
    await seedMedia('d/b.mp4');

    final ds = PagedScenarioMediaDataSource(scenarioId: scenarioId);
    await settle(ds);
    expect(ds.totalItems, 2, reason: 'two ordinary files, no rule yet');
    final beforeScan = usePlaybackScenarioStore().state.sourceScanRevision;
    final beforeVersion = usePlaybackScenarioStore().state.playbackVersion;

    await DbModule.virtualMediaRepo.saveRule(VirtualMediaRule(
      id: 'r1',
      name: 'd',
      matchMode: VmMatchMode.specifiedDir,
      paths: const ['d'],
    ));
    await VirtualMediaService.instance.notifyRulesChanged();
    await settle(ds);

    // Both re-resolution signals move: playbackVersion owns the player chrome,
    // sourceScanRevision owns the open lists (this file's contract).
    expect(usePlaybackScenarioStore().state.playbackVersion,
        greaterThan(beforeVersion));
    expect(usePlaybackScenarioStore().state.sourceScanRevision,
        greaterThan(beforeScan));
    expect(ds.totalItems, 1,
        reason: 'the always-mounted dock must re-group without being reopened');
    expect(ds.items.single.virtualMerged, isTrue);
    expect(ds.items.single.vmChildren, hasLength(2));
    ds.dispose();
  });

  test('flipping the rule to notUse restores the single rows in place',
      () async {
    await scenarioWithSource('e');
    await seedMedia('e/a.mp4');
    await seedMedia('e/b.mp4');
    await DbModule.virtualMediaRepo.saveRule(VirtualMediaRule(
      id: 'r2',
      name: 'e',
      matchMode: VmMatchMode.specifiedDir,
      paths: const ['e'],
    ));
    VirtualMediaService.instance.invalidate();

    final ds = PagedScenarioMediaDataSource(scenarioId: scenarioId);
    await settle(ds);
    expect(ds.totalItems, 1,
        reason: 'the enabled rule already merges the pair');

    await DbModule.virtualMediaRepo.setRuleUseMode('r2', VmRuleUseMode.notUse);
    await VirtualMediaService.instance.notifyRulesChanged();
    await settle(ds);

    expect(ds.totalItems, 2,
        reason: 'turning the folder off must un-merge the open list');
    expect(ds.items.every((i) => !i.virtualMerged), isTrue);
    ds.dispose();
  });

  test('re-grouping moves the follow token to the merged row', () async {
    await scenarioWithSource('f');
    await seedMedia('f/a.mp4');
    await seedMedia('f/b.mp4');
    final store = usePlaybackScenarioStore();
    // The playing file is NOT the group's anchor: before the rule its row is
    // b.mp4 itself, after the merge that same file is covered by a.mp4's row.
    await store.setCurrentItem(
      occurrence: const PlaybackOccurrenceId(
        storageId: 'st1',
        path: 'f/b.mp4',
      ),
    );

    final ds = PagedScenarioMediaDataSource(scenarioId: scenarioId);
    await settle(ds);
    expect(ds.totalItems, 2);
    final beforeToken = ds.currentItemToken;
    var notified = 0;
    ds.addListener(() => notified++);

    await DbModule.virtualMediaRepo.saveRule(VirtualMediaRule(
      id: 'r3',
      name: 'f',
      matchMode: VmMatchMode.specifiedDir,
      paths: const ['f'],
    ));
    await VirtualMediaService.instance.notifyRulesChanged();
    await settle(ds);

    expect(ds.totalItems, 1);
    expect(ds.currentItemToken, isNot(beforeToken),
        reason: 'the page follows the token, so a re-grouped row must move it '
            'or an open queue never scrolls to the playing row');
    expect(notified, greaterThan(0));
    ds.dispose();
  });

  test('paging by hand does not move the follow token', () async {
    await scenarioWithSource('p');
    for (var i = 0; i < 60; i++) {
      await seedMedia('p/a${i.toString().padLeft(3, '0')}.mp4');
    }
    final store = usePlaybackScenarioStore();
    await store.ensureQueueIndex(scenarioId);
    await store.setCurrentItem(
      occurrence: const PlaybackOccurrenceId(
        storageId: 'st1',
        path: 'p/a000.mp4',
      ),
    );

    final ds = PagedScenarioMediaDataSource(scenarioId: scenarioId);
    await settle(ds);
    expect(ds.totalItems, 60);
    final beforeToken = ds.currentItemToken;

    await ds.fetchPage(1, ds.pageSize);

    expect(ds.currentItemToken, beforeToken,
        reason: 'a user page change must never be read as "the row moved", or '
            'the auto-locate would drag the reader back');
    ds.dispose();
  });

  test('notifyRulesChanged runs the tag-view refresher before the list refetch',
      () async {
    final store = usePlaybackScenarioStore();
    final beforeScan = store.state.sourceScanRevision;
    var calls = 0;
    int? scanSeenByRefresher;
    final previous = VirtualMediaService.tagViewRuleChangeRefresher;
    addTearDown(
        () => VirtualMediaService.tagViewRuleChangeRefresher = previous);
    VirtualMediaService.tagViewRuleChangeRefresher = () async {
      calls++;
      scanSeenByRefresher = usePlaybackScenarioStore().state.sourceScanRevision;
    };

    await VirtualMediaService.instance.notifyRulesChanged();

    expect(calls, 1);
    expect(scanSeenByRefresher, beforeScan,
        reason: 'an active tag view must be re-resolved BEFORE the queue '
            'refetch, or the refetch serves the stale merge groups');
    expect(store.state.sourceScanRevision, greaterThan(beforeScan));
  });
}
