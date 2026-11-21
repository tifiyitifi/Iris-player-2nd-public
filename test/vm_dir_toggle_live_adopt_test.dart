import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/playback/playback_position_signal.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/commands/vm_dir_toggle.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

import 'helpers/sqlite3_loader.dart';

/// The More-menu folder toggle must apply to the video that is ALREADY
/// playing: "use" adopts the live feed (no reopen, position kept), "not use"
/// stops the live merge (including a merge owned by a recursive rule above the
/// folder) and leaves the physical file playing.
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

  Future<void> playSingle(String path) async {
    final parts = path.split('/');
    await usePlayQueueStore().update(
      playQueue: [
        PlayQueueItem(
          file: FileItem(
            storageId: 'st1',
            name: parts.last,
            uri: 'file:///$path',
            path: parts,
          ),
          index: 0,
        ),
      ],
      index: 0,
    );
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
    useVmPlaybackStore().replace(const VmPlaybackState());
    PlaybackPositionSignal.instance.clear();
    await usePlayQueueStore().clear();
    await useAppStore().updateAutoPlay(false);
    final sys = await usePlaybackScenarioStore().ensureSystemPlayingScenario();
    await usePlaybackScenarioStore().setActiveScenario(sys.id);
    scenarioId = sys.id;
  });

  tearDown(() async {
    await VirtualMediaController.instance.stop().catchError((_) {});
    useVmPlaybackStore().replace(const VmPlaybackState());
    PlaybackPositionSignal.instance.clear();
  });

  test('enabling the folder adopts the already-playing video immediately',
      () async {
    await DbModule.scenarioRepo.addSource(
      scenarioId: scenarioId,
      storageId: 'st1',
      path: 'root',
      recursive: true,
    );
    await seedMedia('root/a.mp4');
    await seedMedia('root/b.mp4');
    final store = usePlaybackScenarioStore();
    await store.ensureQueueIndex(scenarioId);
    await store.setCurrentItem(
      occurrence: const PlaybackOccurrenceId(
        storageId: 'st1',
        path: 'root/a.mp4',
      ),
    );
    await playSingle('root/a.mp4');
    await useAppStore().updateAutoPlay(true);

    final res = await toggleVmDirUseMode(
      storageId: 'st1',
      storageName: 'Store',
      name: 'a.mp4',
      path: const ['root', 'a.mp4'],
      storageBasePaths: const [],
    );

    expect(res.usable, isTrue);
    expect(res.nowUsing, isTrue);
    expect(res.adopted, isTrue,
        reason: 'the current video must start merging right away');
    final ctrl = VirtualMediaController.instance;
    expect(ctrl.isActive, isTrue);
    expect(
      ctrl.state.item!.segments.map((s) => s.name),
      containsAll(<String>['a.mp4', 'b.mp4']),
    );
    // No reopen: the queue still plays the same physical file, autoplay on.
    expect(usePlayQueueStore().state.playQueue, hasLength(1));
    expect(usePlayQueueStore().state.playQueue.single.file.uri,
        'file:///root/a.mp4');
    expect(useAppStore().state.autoPlay, isTrue);
  });

  test('disabling a folder carves it out of a recursive merge immediately',
      () async {
    await seedMedia('root/sub/x.mp4');
    await seedMedia('root/sub/y.mp4');
    await DbModule.virtualMediaRepo.saveRule(VirtualMediaRule(
      id: 'rec',
      name: 'rec',
      matchMode: VmMatchMode.specifiedDirRecursive,
      paths: const ['root'],
    ));
    VirtualMediaService.instance.invalidate();
    final store = usePlaybackScenarioStore();
    await store.setCurrentItem(
      occurrence: const PlaybackOccurrenceId(
        storageId: 'st1',
        path: 'root/sub/x.mp4',
      ),
    );
    await playSingle('root/sub/x.mp4');
    await useAppStore().updateAutoPlay(true);

    final ctrl = VirtualMediaController.instance;
    // The reported shape: the recursive rule merged this folder, so a session
    // is live on the sub-folder file.
    await ctrl.adoptLiveSession(
      queue: [
        VirtualMediaItem(
          ruleId: 'rec',
          scopeKey: 'rec|root/sub|#1',
          rootPath: 'root/sub',
          displayIndex: 1,
          displayName: 'sub',
          segments: const [
            VirtualSegment(
              mediaKey: 'st1:root/sub/x.mp4',
              storageId: 'st1',
              path: ['root', 'sub', 'x.mp4'],
              name: 'x.mp4',
              parentPath: 'root/sub',
              durationMs: 60000,
            ),
            VirtualSegment(
              mediaKey: 'st1:root/sub/y.mp4',
              storageId: 'st1',
              path: ['root', 'sub', 'y.mp4'],
              name: 'y.mp4',
              parentPath: 'root/sub',
              durationMs: 60000,
            ),
          ],
        ),
      ],
      queueIndex: 0,
      segmentIndex: 0,
    );
    expect(ctrl.isActive, isTrue);

    final res = await toggleVmDirUseMode(
      storageId: 'st1',
      storageName: 'Store',
      name: 'x.mp4',
      path: const ['root', 'sub', 'x.mp4'],
      storageBasePaths: const [],
    );

    expect(res.usable, isTrue);
    expect(res.nowUsing, isFalse);
    expect(res.rule!.matchMode, VmMatchMode.specifiedDir);
    expect(res.rule!.useMode, VmRuleUseMode.notUse);
    // The recursive session must stop even though it belongs to ANOTHER rule.
    expect(ctrl.state.item, isNull);
    // The physical file keeps playing.
    expect(usePlayQueueStore().state.playQueue, hasLength(1));
    expect(usePlayQueueStore().state.playQueue.single.file.uri,
        'file:///root/sub/x.mp4');
    expect(useAppStore().state.autoPlay, isTrue);
  });

  test('flipping an existing folder rule to notUse clears its anchor',
      () async {
    await seedMedia('root/sub/x.mp4');
    await seedMedia('root/sub/y.mp4');
    await DbModule.virtualMediaRepo.saveRule(VirtualMediaRule(
      id: 'r_sub',
      name: 'sub',
      matchMode: VmMatchMode.specifiedDir,
      paths: const ['root/sub'],
    ));
    VirtualMediaService.instance.invalidate();
    await playSingle('root/sub/x.mp4');
    await useAppStore().updateAutoPlay(true);

    final ctrl = VirtualMediaController.instance;
    await ctrl.adoptLiveSession(
      queue: [
        VirtualMediaItem(
          ruleId: 'r_sub',
          scopeKey: 'r_sub|root/sub|#1',
          rootPath: 'root/sub',
          displayIndex: 1,
          displayName: 'sub',
          segments: const [
            VirtualSegment(
              mediaKey: 'st1:root/sub/x.mp4',
              storageId: 'st1',
              path: ['root', 'sub', 'x.mp4'],
              name: 'x.mp4',
              parentPath: 'root/sub',
              durationMs: 60000,
            ),
            VirtualSegment(
              mediaKey: 'st1:root/sub/y.mp4',
              storageId: 'st1',
              path: ['root', 'sub', 'y.mp4'],
              name: 'y.mp4',
              parentPath: 'root/sub',
              durationMs: 60000,
            ),
          ],
        ),
      ],
      queueIndex: 0,
      segmentIndex: 0,
    );
    expect(ctrl.isActive, isTrue);
    await DbModule.virtualMediaRepo.saveAnchor(
      scopeKey: 'r_sub|root/sub|#1',
      segmentKey: 'st1:root/sub/x.mp4',
      localPositionMs: 12000,
    );
    expect(
      await DbModule.virtualMediaRepo.loadAnchor('r_sub|root/sub|#1'),
      isNotNull,
    );

    final res = await toggleVmDirUseMode(
      storageId: 'st1',
      storageName: 'Store',
      name: 'x.mp4',
      path: const ['root', 'sub', 'x.mp4'],
      storageBasePaths: const [],
    );

    expect(res.usable, isTrue);
    expect(res.nowUsing, isFalse);
    expect(res.rule!.id, 'r_sub');
    // The polarity flip drops the rule's anchor; the live teardown must not
    // write it straight back (DIR-9).
    expect(
      await DbModule.virtualMediaRepo.loadAnchor('r_sub|root/sub|#1'),
      isNull,
    );
  });
}
