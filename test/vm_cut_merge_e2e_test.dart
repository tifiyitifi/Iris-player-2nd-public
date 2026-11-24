import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/services/fake_cut_discovery.dart';
import 'package:iris/features/fake_cut/services/fake_cut_project_index.dart';
import 'package:iris/features/fake_cut/store/use_fake_cut_store.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/playback/playback_position_signal.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show PlayerBackend;
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:path/path.dart' as p;

import 'helpers/sqlite3_loader.dart';

/// The 虚拟剪播 ↔ 虚拟合并 wiring end to end, with the REAL chain:
/// `FakeCutStore.activate` → `PlaybackProviderRegistry.onCutPlanChanged` →
/// `notifyCutPlanChanged` → `refreshLiveVirtualGroups` → the DB-resolved groups
/// → `VirtualMediaController.resegmentLiveFromGroups`.
///
/// The unit suites prove each link; this proves they are actually connected, so
/// a handler swap or a dropped `cutRange` fails here instead of only on a device
/// (the `player.open` call itself still needs one manual run — no host test
/// drives media_kit).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  late String scenarioId;
  late Directory tempRoot;

  Future<void> seedMedia(String path, {int durationMs = 60000}) async {
    final parts = path.split('/');
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: path,
      storageId: 'st1',
      path: parts,
      parentPath:
          parts.length <= 1 ? null : parts.sublist(0, parts.length - 1).join('/'),
      name: parts.last,
      mediaType: MediaType.video,
      durationMs: durationMs,
    ));
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
    StoragePathCodec.baseResolver = (_) => null;
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
          // 虚拟剪播 needs the mpv EDL backend; fvp merges the source instead.
          playerBackend: PlayerBackend.mediaKit,
        ));
    VirtualMediaService.instance.invalidate();
    useVmPlaybackStore().replace(const VmPlaybackState());
    PlaybackPositionSignal.instance.clear();
    await usePlayQueueStore().clear();
    await useAppStore().updateAutoPlay(false);
    final sys = await usePlaybackScenarioStore().ensureSystemPlayingScenario();
    await usePlaybackScenarioStore().setActiveScenario(sys.id);
    scenarioId = sys.id;

    tempRoot = await Directory.systemTemp.createTemp('iris_cut_merge_e2e');
    StoragePathCodec.baseResolver =
        (String id) => id == 'st1' ? pathConv(tempRoot.path) : null;
    setKvStoreForTest(MemoryKvStore());
    FakeCutProjectIndex.instance.invalidate();
  });

  tearDown(() async {
    await VirtualMediaController.instance.stop().catchError((_) {});
    useVmPlaybackStore().replace(const VmPlaybackState());
    PlaybackPositionSignal.instance.clear();
    resetKvStoreForTest();
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  test('activating a cut re-segments the live merged group', () async {
    final String dir = p.join(tempRoot.path, 'root');
    await Directory(dir).create();
    for (final String name in <String>['a.mp4', 'b.mp4', 'c.mp4']) {
      await File(p.join(dir, name)).writeAsBytes(const <int>[0]);
    }
    // 1s..20s kept → a 19s cut.
    await File(p.join(dir, 'b.llc')).writeAsString('''
{
  version: 2,
  mediaFileName: 'b.mp4',
  cutSegments: [{ start: 1, end: 20, name: 'keep', selected: true }],
}
''');

    await DbModule.scenarioRepo.addSource(
      scenarioId: scenarioId,
      storageId: 'st1',
      path: 'root',
      recursive: true,
    );
    await seedMedia('root/a.mp4');
    await seedMedia('root/b.mp4');
    await seedMedia('root/c.mp4');
    await DbModule.virtualMediaRepo.saveRule(VirtualMediaRule(
      id: 'r1',
      name: 'root',
      matchMode: VmMatchMode.specifiedDir,
      paths: const <String>['root'],
    ));
    VirtualMediaService.instance.invalidate();

    final String videoFsPath = p.join(dir, 'b.mp4');
    // DB/resolver form (forward slashes): the cut index keys paths by spelling,
    // and production always reaches it through this form.
    final List<String> absPath = pathConv(videoFsPath);
    final String videoUri = absPath.join('/');
    final String absKey = canonicalMediaKey('st1', absPath);
    final FileItem playing = FileItem(
      storageId: 'st1',
      name: 'b.mp4',
      uri: videoUri,
      path: absPath,
      durationMs: 60000,
    );
    await usePlayQueueStore().update(
      playQueue: <PlayQueueItem>[PlayQueueItem(file: playing, index: 0)],
      index: 0,
    );
    await useAppStore().updateAutoPlay(true);

    // The group the DB resolves for this file: the same derivation a tap uses.
    final store = usePlaybackScenarioStore();
    final groups = await store.resolver.resolveVmGroupsFor(
      scenarioId,
      playbackVersion: store.state.playbackVersion,
    );
    final group =
        groups.inOrder.firstWhere((g) => g.indexOfSegmentKey(absKey) != null);
    expect(group.totalDurationMs, 180000);
    final int queueIndex = groups.inOrder.indexOf(group);
    final int segIdx = group.indexOfSegmentKey(absKey)!;

    final ctrl = VirtualMediaController.instance;
    expect(
      await ctrl.adoptLiveSession(
        queue: groups.inOrder,
        queueIndex: queueIndex,
        segmentIndex: segIdx,
      ),
      isTrue,
      reason: 'the playing file must bind to its merged group first',
    );
    expect(ctrl.currentSegmentOrNull!.cutRange, isNull);

    // Activate through the REAL store: its handler must re-segment the live
    // session before anything reopens the media.
    final FakeCutStore cutStore = useFakeCutStore();
    await cutStore.initialized;
    final List<FakeCutPlanSource> sources = await FakeCutDiscovery.scan(
      videoPath: videoUri,
      sourceDurationMs: 60000,
    );
    expect(sources, hasLength(1));
    expect(await cutStore.activate(playing, sources.single), isTrue);

    expect(ctrl.isActive, isTrue, reason: 'the live session must survive');
    expect(ctrl.currentSegmentOrNull!.cutRange, isNotNull);
    expect(ctrl.currentSegmentOrNull!.cutRange!.planPath, sources.single.path);
    expect(ctrl.currentSegmentOrNull!.durationMs, 19000);
    expect(ctrl.state.item!.totalDurationMs, 139000);

    // Closing the cut puts the segment back on its source and the totals back.
    await cutStore.deactivate(playing);
    expect(ctrl.isActive, isTrue);
    expect(ctrl.currentSegmentOrNull!.cutRange, isNull);
    expect(ctrl.currentSegmentOrNull!.durationMs, 60000);
    expect(ctrl.state.item!.totalDurationMs, 180000);

    // Re-activate, then edit the plan ON DISK while its segment is open. The
    // player re-reads the `.llc`, but the group still displays the previous
    // kept length; `onCutPlanEdited` must re-derive it (ADR 0034). The resolver
    // cache is keyed by the SCENARIO signature, not the plan content, so the
    // forced re-derive is what makes this work.
    expect(await cutStore.activate(playing, sources.single), isTrue);
    expect(ctrl.currentSegmentOrNull!.durationMs, 19000);

    // 1s..30s kept → a 29s cut (10s longer than before).
    await File(p.join(dir, 'b.llc')).writeAsString('''
{
  version: 2,
  mediaFileName: 'b.mp4',
  cutSegments: [{ start: 1, end: 30, name: 'keep', selected: true }],
}
''');
    await PlaybackProviderRegistry.onCutPlanEdited();

    expect(ctrl.currentSegmentOrNull!.cutRange, isNotNull);
    expect(ctrl.currentSegmentOrNull!.durationMs, 29000,
        reason: 'the live merge must follow the edited plan');
    expect(ctrl.state.item!.totalDurationMs, 149000, // 60 + 29 + 60
        reason: 'the displayed group total must agree with the played EDL');
  });
}
