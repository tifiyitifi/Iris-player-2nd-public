import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/playback/vm_group_position_sync.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/path_conv.dart';

import 'helpers/sqlite3_loader.dart';

/// The scenario's current item must follow the VM session ACROSS groups.
///
/// A merged session walks its own blocks and then crosses into sibling groups
/// (`vm-advance`), but nothing used to tell the scenario: the queue kept
/// highlighting the row that was tapped while a different group played, and the
/// locate hint (`currentVirtualPos`) stayed null (the tapped row was persisted
/// without it). [VmGroupPositionSync] closes that gap per group change.
///
/// The groups are built by hand: this test pins the SYNC contract, not the
/// merge derivation (covered by the resolver/index suites).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  late String scenarioId;

  Future<void> seedMedia(String path) async {
    final parts = path.split('/');
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: path,
      storageId: 'st1',
      path: parts,
      parentPath:
          parts.length <= 1 ? null : parts.sublist(0, parts.length - 1).join('/'),
      name: parts.last,
      mediaType: MediaType.video,
    ));
  }

  VirtualSegment segment(String path) {
    final parts = path.split('/');
    return VirtualSegment(
      mediaKey: 'st1:$path',
      storageId: 'st1',
      path: parts,
      name: parts.last,
      parentPath: parts.length <= 1 ? '' : parts.sublist(0, parts.length - 1).join('/'),
      durationMs: 60000,
    );
  }

  VirtualMediaItem group(String rootPath, List<String> files) => VirtualMediaItem(
        ruleId: 'r1',
        scopeKey: 'r1|$rootPath|#1',
        rootPath: rootPath,
        displayIndex: 1,
        displayName: rootPath,
        segments: [for (final f in files) segment(f)],
      );

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
    useStorageStore();
    await useStorageStore().initialized;
  });

  tearDownAll(() async {
    VmGroupPositionSync.instance.resetForTest();
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
    ]) {
      await db.customStatement('DELETE FROM $t');
    }
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: true,
          useLegacyStoragePersistence: false,
          useScenarioDrivenPlayback: true,
        ));
    useVmPlaybackStore().replace(const VmPlaybackState());
    VmGroupPositionSync.instance.resetForTest();
    final sys = await usePlaybackScenarioStore().ensureSystemPlayingScenario();
    await usePlaybackScenarioStore().setActiveScenario(sys.id);
    scenarioId = sys.id;
    await DbModule.scenarioRepo.addSource(
      scenarioId: scenarioId,
      storageId: 'st1',
      path: '',
      recursive: true,
    );
    for (final f in const ['A/a1.mp4', 'A/a2.mp4', 'B/b1.mp4', 'B/b2.mp4']) {
      await seedMedia(f);
    }
  });

  test('crossing into a sibling group re-books the scenario current item',
      () async {
    final store = usePlaybackScenarioStore();
    final groupA = group('A', const ['A/a1.mp4', 'A/a2.mp4']);
    final groupB = group('B', const ['B/b1.mp4', 'B/b2.mp4']);
    expect(PlaybackProviderRegistry.scenarioModeActive, isTrue);

    VmGroupPositionSync.instance.start();
    useVmPlaybackStore().replace(VmPlaybackState(
      item: groupA,
      queue: [groupA, groupB],
      queueIndex: 0,
    ));
    await pumpEventQueue();

    expect(
      store.state.currentOccurrenceKey,
      canonicalOccurrenceKey('st1', 'A/a1.mp4', 0),
    );

    // Auto-advance crosses into the sibling group: the session state changes
    // (a new scopeKey) and the scenario must follow it — that is the whole point
    // (the tapped row is no longer what plays).
    useVmPlaybackStore().replace(VmPlaybackState(
      item: groupB,
      queue: [groupA, groupB],
      queueIndex: 1,
    ));
    await pumpEventQueue();

    expect(
      store.state.currentOccurrenceKey,
      canonicalOccurrenceKey('st1', 'B/b1.mp4', 0),
      reason: 'the highlight must move to the group that is actually playing',
    );
    final persisted = await store.activeState();
    expect(persisted?.currentVirtualPos, isNotNull,
        reason:
            'the ordering hint must be re-established per group, not left null');
  });

  test('a segment switch inside the group does not re-write the current item',
      () async {
    final store = usePlaybackScenarioStore();
    final groupA = group('A', const ['A/a1.mp4', 'A/a2.mp4']);

    VmGroupPositionSync.instance.start();
    useVmPlaybackStore().replace(VmPlaybackState(item: groupA));
    await pumpEventQueue();
    final afterGroup = (await store.activeState())?.currentPlaybackOccurrence;

    // Segment 1 of the SAME group: per the write policy only the group change is
    // booked (the segment feed stamps its own file progress instead).
    useVmPlaybackStore().replace(VmPlaybackState(
      item: groupA,
      segmentIndex: 1,
    ));
    await pumpEventQueue();

    expect(
      (await store.activeState())?.currentPlaybackOccurrence?.occurrenceKey,
      afterGroup?.occurrenceKey,
    );
  });

  test('the tag view keeps ownership: no scenario bookkeeping', () async {
    final store = usePlaybackScenarioStore();
    final before = store.state.currentOccurrenceKey;

    VmGroupPositionSync.instance.start();
    // A tag view drives playback: `activeViewTagId` is set.
    useTagPlayStore();
    useTagPlayStore().set(useTagPlayStore().state.copyWith(activeViewTagId: 1));
    addTearDown(() => useTagPlayStore()
        .set(useTagPlayStore().state.copyWith(activeViewTagId: null)));

    useVmPlaybackStore().replace(VmPlaybackState(
      item: group('A', const ['A/a1.mp4', 'A/a2.mp4']),
    ));
    await pumpEventQueue();

    expect(store.state.currentOccurrenceKey, before);
    expect(PlaybackProviderRegistry.tagViewDriving, isTrue);
  });
}
