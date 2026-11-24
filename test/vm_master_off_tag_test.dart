import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/playback/tag_play_controller.dart';
import 'package:iris/features/tag_play/resolver/tag_view_resolver.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/features/virtual_media/commands/vm_master_actions.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/path_conv.dart';

import 'helpers/sqlite3_loader.dart';

/// Pausing the master switch while a TAG VIEW drives a MERGED group must book
/// the file that is actually playing. A merged row is identified by its anchor
/// (segment 0), so relocating by the row key would drop the position back to
/// the start of the group; `revalidate` has to relocate by the live segment.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  const scenarioId = 'sc';

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    final sys = await usePlaybackScenarioStore().ensureSystemPlayingScenario();
    await usePlaybackScenarioStore().refreshScenarios();
    await usePlaybackScenarioStore().setActiveScenario(sys.id);
    PlaybackProviderRegistry.init();
    useAppStore();
    await useAppStore().initialized;
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useTagPlayStore();
  });

  setUp(() async {
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: true,
          useLegacyStoragePersistence: false,
          useScenarioDrivenPlayback: true,
        ));
    useVmPlaybackStore().replace(const VmPlaybackState());
    await usePlayQueueStore().clear();
    await useAppStore().updateAutoPlay(false);
    for (final rule in await DbModule.virtualMediaRepo.loadRules()) {
      await DbModule.virtualMediaRepo.deleteRule(rule.id);
    }
    await DbModule.virtualMediaRepo.clearAllVmProgress();
    await DbModule.virtualMediaRepo.clearAnchors();
    VmPrefs.debugFailMasterWrite = false;
    await VmPrefs.setMasterEnabled(true);
    VirtualMediaService.instance.invalidate();
    await useTagPlayStore().setActiveView(null);
  });

  Future<void> seed(String name) async {
    await DbModule.mediaNodesDao.deleteNode('s1', name);
    await DbModule.mediaNodesDao.insertNode(
      MediaNode.file(
        id: 'f:s1:$name',
        storageId: 's1',
        path: [name],
        name: name,
        mediaType: MediaType.video,
      ),
    );
  }

  EffectivePlaybackItem row(String path, String name) => EffectivePlaybackItem(
        media: MediaNode.file(
          id: '-1',
          storageId: 's1',
          path: path.split('/').where((s) => s.isNotEmpty).toList(),
          name: name,
          mediaType: MediaType.video,
          isPresent: true,
        ),
        scenarioId: scenarioId,
        origins: const [],
        explicit: false,
        duplicated: false,
        available: true,
        virtualIndex: 0,
        occurrenceId: PlaybackOccurrenceId(storageId: 's1', path: path),
      );

  VirtualMediaItem group() => VirtualMediaItem(
        ruleId: 'r',
        scopeKey: 'r|d|#1',
        rootPath: 'd',
        displayIndex: 1,
        displayName: 'group',
        segments: [
          VirtualSegment(
            mediaKey: canonicalKey('s1', '/a0.mp4'),
            storageId: 's1',
            path: const ['a0.mp4'],
            name: 'a0.mp4',
            parentPath: '',
            durationMs: 60000,
          ),
          VirtualSegment(
            mediaKey: canonicalKey('s1', '/a1.mp4'),
            storageId: 's1',
            path: const ['a1.mp4'],
            name: 'a1.mp4',
            parentPath: '',
            durationMs: 60000,
          ),
        ],
      );

  test('pausing mid-group under a tag view books the file actually playing',
      () async {
    final repo = DbModule.tagPlayRepo;
    final tag = await repo.createTag(name: 'tag-off-mid-group');
    // Oldest first: the default addedAt-DESC order puts a0 at index 0, so the
    // view's current ROW is the group's anchor while the session plays a1.
    var at = DateTime.utc(2026, 8, 1);
    for (final p in ['a1.mp4', 'a0.mp4']) {
      await repo.addMember(
          tagId: tag.id, storageId: 's1', pathSegments: [p], at: at);
      at = at.add(const Duration(hours: 1));
    }
    await seed('a0.mp4');
    await seed('a1.mp4');

    TagViewResolver resolver() => TagViewResolver(
          source: FakeControllerSource([
            row('/a0.mp4', 'a0'),
            row('/a1.mp4', 'a1'),
          ]),
          repo: repo,
        );
    final snap = await resolver()
        .resolve(tagId: tag.id, scenarioId: scenarioId, withVmOverlay: false);

    final controller = TagPlayController(
      repo: repo,
      resolverFactory: resolver,
      noTagDelegate: _NoTagStub(),
    )..bindScenario(scenarioId);
    await useTagPlayStore().setActiveView(tag.id);
    controller.snapshot = snap;
    PlaybackProviderRegistry.debugOverrideTagPlay(controller);

    // The view's current row is the merged row's anchor, a0.
    await controller.advanceFirst();
    expect(controller.currentCachedEntry?.key, canonicalKey('s1', '/a0.mp4'));
    await useAppStore().updateAutoPlay(true);

    final vm = VirtualMediaController.instance;
    await vm.startSession(queue: [group()], queueIndex: 0, segmentIndex: 1);
    expect(vm.isActive, isTrue);
    expect(vm.currentSegmentOrNull?.mediaKey, canonicalKey('s1', '/a1.mp4'));

    final beforeVersion = usePlaybackScenarioStore().state.playbackVersion;
    final beforeScan = usePlaybackScenarioStore().state.sourceScanRevision;

    await setVmMasterEnabled(enabled: false);

    // A seamless pause: VM state drops, the feed keeps playing the LIVE file.
    expect(vm.isActive, isFalse);
    expect(usePlayQueueStore().state.playQueue.single.file.name, 'a1.mp4');
    expect(useAppStore().state.autoPlay, isTrue);
    expect(await VirtualMediaService.instance.enabledRules(), isEmpty);

    // The bookmark follows the REAL segment, not the merged row's anchor.
    final state = await repo.stateOf(tag.id);
    expect(state!.lastMediaKey, canonicalKey('s1', '/a1.mp4'));
    expect(state.lastVirtualPos,
        snap.indexOfFileKey(canonicalKey('s1', '/a1.mp4')));

    // Both re-resolution signals moved (player chrome + open queue refetch).
    expect(usePlaybackScenarioStore().state.playbackVersion,
        greaterThan(beforeVersion));
    expect(usePlaybackScenarioStore().state.sourceScanRevision,
        greaterThan(beforeScan));

    await useTagPlayStore().setActiveView(null);
  });
}

class _NoTagStub extends NoTagDelegate {
  @override
  Future<PlaybackEntry?> current() async => null;

  @override
  Future<void> advanceEntry(
    PlaybackEntry entry, {
    bool autoplay = true,
    String? targetFileKey,
  }) async {}

  @override
  Future<void> captureCurrentSegment() async {}
}

class FakeControllerSource implements ScenarioEffectiveItemsSource {
  FakeControllerSource(this.items);

  final List<EffectivePlaybackItem> items;

  @override
  Future<List<EffectivePlaybackItem>> collect({
    required String scenarioId,
    Set<String>? mediaKeyFilter,
  }) async {
    if (mediaKeyFilter == null) return items;
    return items
        .where((e) => mediaKeyFilter.contains(
            canonicalKey(e.occurrenceId.storageId, e.occurrenceId.path)))
        .toList();
  }
}
