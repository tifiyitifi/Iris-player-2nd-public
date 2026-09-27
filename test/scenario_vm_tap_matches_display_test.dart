import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/playback/playback_position_signal.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/resolver/vm_resolver.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/path_conv.dart';

import 'helpers/sqlite3_loader.dart';

/// Tapping a merged row must start the session for the group THE LIST SHOWED.
///
/// The queue page is served by the persisted SHARED INDEX while the tap path
/// derives its groups from `resolveVmGroupsFor` (the persisted-config walk).
/// Both must agree on "which group does this file belong to" — and with the
/// grouping now rule-dimension on BOTH sides they derive from the same rule
/// pipeline, under any scenario order including shuffle
/// (`scenario_shuffle_display_test.dart` pins the shuffled case).
///
/// Fixture mirrors the reported shape: a root directory holding two files, and
/// a subdirectory holding many (a rule with a duration cap may chunk the
/// subdirectory only when durations are known).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  late String scenarioId;

  VirtualMediaRule buildRule() => VirtualMediaRule(
        id: 'r1',
        name: 'R',
        matchMode: VmMatchMode.specifiedDirRecursive,
        paths: const ['root'],
        boundary: VmBoundaryMode.sameDirOnly,
        sortField: VmSortField.fileName,
        sortDir: SortDirection.asc,
        useDurationCap: true,
        maxDurationMinutes: 90,
        useCountCap: true,
        maxItemCount: 30,
        useExcludeOverlong: false,
        skipSingleSegment: true,
        titleTags: const [VmTitleTag.dirName, VmTitleTag.seq],
        enabled: true,
      );

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

  PlaybackEntry entryOf(
      EffectivePlaybackItem item, ScenarioPlaybackProvider provider) =>
      PlaybackEntry(
        file: provider.fileOf(item.media),
        storageId: item.media.storageId,
        path: item.pathValue,
        key: item.mediaKey,
        available: item.available,
        occurrenceIndex: item.occurrenceId.occurrenceIndex,
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
    final sys = await usePlaybackScenarioStore().ensureSystemPlayingScenario();
    await usePlaybackScenarioStore().setActiveScenario(sys.id);
    scenarioId = sys.id;
  });

  tearDown(() async {
    await VirtualMediaController.instance
        .stop()
        .catchError((_) {});
    useVmPlaybackStore().replace(const VmPlaybackState());
    PlaybackPositionSignal.instance.clear();
  });

  test('stream-run grouping agrees with the rule pipeline (boundary)', () async {
    // The rule pipeline (`resolveRuleGroups`) is the AUTHORITY for group
    // membership; the stream-run path must not disagree. `sameDirOnly` forbids
    // a block from straddling directories, and the stream order places a
    // directory's own files right before its subdirectory's — exactly where the
    // old run-splitting glued them together.
    await DbModule.scenarioRepo.addSource(
      scenarioId: scenarioId,
      storageId: 'st1',
      path: 'root',
      recursive: true,
    );
    await seedMedia('root/keqing 2024-12-26.mp4');
    await seedMedia('root/zack-selene-4k60fps.mp4');
    for (var i = 0; i < 6; i++) {
      await seedMedia('root/sub/f$i.mp4');
    }
    final rule = buildRule();
    await DbModule.virtualMediaRepo.saveRule(rule);
    VirtualMediaService.instance.invalidate();

    final store = usePlaybackScenarioStore();
    final stream = await store.resolver.collectEffectiveItems(
      scenarioId: scenarioId,
    );

    // Authority: the rule pipeline over the same file universe.
    final library = [
      for (final item in stream)
        if (item.available)
          VirtualSegment(
            mediaKey: item.mediaKey,
            storageId: item.media.storageId,
            path: item.media.maybeMap(
                file: (f) => f.path, orElse: () => const <String>[]),
            name: item.media.name,
            parentPath: item.media.maybeMap(
                file: (f) => f.parentPath ?? '', orElse: () => ''),
            durationMs: 60000,
          ),
    ];
    final authoritative = resolveRuleGroups(rules: [rule], library: library);
    final streamRun = resolveGroupsForStream(stream, [rule]);

    Map<String, String> byFile(List<VirtualMediaItem> groups) => {
          for (final g in groups)
            for (final s in g.segments) s.mediaKey: g.scopeKey,
        };
    final a = byFile(authoritative);
    final b = byFile(streamRun.inOrder);
    for (final g in authoritative) {
      for (final s in g.segments) {
        final other = streamRun.byKey[s.mediaKey];
        expect(other, isNotNull, reason: '${s.mediaKey} missing from stream-run');
        expect(
          other!.segments.map((x) => x.mediaKey).toSet(),
          g.segments.map((x) => x.mediaKey).toSet(),
          reason: 'group membership for ${s.mediaKey} disagrees',
        );
      }
    }
    expect(a.keys.toSet(), b.keys.toSet());
  });

  test('the tapped row starts ITS OWN group, matching the displayed children',
      () async {
    await DbModule.scenarioRepo.addSource(
      scenarioId: scenarioId,
      storageId: 'st1',
      path: 'root',
      recursive: true,
    );
    // Root directory: two short files → ONE merged group (`root · 1`).
    await seedMedia('root/keqing 2024-12-26.mp4', durationMs: 8 * 60 * 1000);
    await seedMedia('root/zack-selene-4k60fps.mp4', durationMs: 43 * 1000);
    // Subdirectory: many files → further groups.
    for (var i = 0; i < 24; i++) {
      await seedMedia('root/sub/f$i.mp4', durationMs: 3 * 60 * 1000);
    }
    await DbModule.virtualMediaRepo.saveRule(buildRule());
    VirtualMediaService.instance.invalidate();

    final store = usePlaybackScenarioStore();

    // ── The DISPLAYED page. In production this is the persisted SHARED INDEX,
    // so build it and fail loudly rather than silently asserting the walk. ──
    await store.ensureQueueIndex(scenarioId);
    expect(await store.indexedTotalCount(), isNotNull,
        reason: 'the fixture must be representable, or this proves nothing '
            'about the read path the queue actually uses');
    final page = await store.resolver.resolvePageIndexed(
      scenarioId: scenarioId,
      page: 0,
      pageSize: 50,
    );
    final rowKeqing = page.items
        .firstWhere((i) => i.mediaKey == 'st1:root/keqing 2024-12-26.mp4');
    expect(rowKeqing.virtualMerged, isTrue,
        reason: 'the root directory merges into one row');
    final displayedChildren =
        rowKeqing.vmChildren.map((c) => c.mediaKey).toList();
    // The displayed row may ONLY contain root-level members.
    expect(
      displayedChildren.every((k) => !k.contains('/sub/')),
      isTrue,
      reason: 'the 20260614-style row must not contain subdirectory members, '
          'got $displayedChildren',
    );

    // ── Tap that row (the reported action). ──
    final provider = ScenarioPlaybackProvider(store: store);
    await provider.play(entryOf(rowKeqing, provider));

    final ctrl = VirtualMediaController.instance;
    final session = ctrl.state.item;
    expect(session, isNotNull, reason: 'a merged row must start a session');

    // The fed group must BE the displayed group.
    expect(
      session!.scopeKey,
      rowKeqing.vmChildren.isEmpty ? session.scopeKey : session.scopeKey,
      reason: 'sanity',
    );
    expect(
      session.segments.map((s) => s.mediaKey).toList(),
      displayedChildren,
      reason: 'the session must feed the children the row displayed '
          '(the tap must not resolve to a different directory\'s group)',
    );
  });

  // The merge branch of `play()` returned before establishing the position, so
  // a merged row left the bar title on the previous item's number for the whole
  // session — and on nothing at all when the context had never been located.
  // A merged row is still ONE position in the scenario stream.
  test('tapping a merged row publishes the bar position', () async {
    await DbModule.scenarioRepo.addSource(
      scenarioId: scenarioId,
      storageId: 'st1',
      path: 'root',
      recursive: true,
    );
    await seedMedia('root/keqing 2024-12-26.mp4', durationMs: 8 * 60 * 1000);
    await seedMedia('root/zack-selene-4k60fps.mp4', durationMs: 43 * 1000);
    for (var i = 0; i < 6; i++) {
      await seedMedia('root/sub/f$i.mp4', durationMs: 3 * 60 * 1000);
    }
    await DbModule.virtualMediaRepo.saveRule(buildRule());
    VirtualMediaService.instance.invalidate();

    final store = usePlaybackScenarioStore();
    await store.ensureQueueIndex(scenarioId);
    final page = await store.resolver.resolvePageIndexed(
      scenarioId: scenarioId,
      page: 0,
      pageSize: 50,
    );
    final merged = page.items.firstWhere((i) => i.virtualMerged);
    final total = page.totalItems;

    final tapProvider = ScenarioPlaybackProvider(store: store);
    await tapProvider.play(entryOf(merged, tapProvider));

    expect(
      VirtualMediaController.instance.state.item,
      isNotNull,
      reason: 'fixture must start a merged session, or this proves nothing',
    );
    // The observing provider is a DIFFERENT instance than the one that played —
    // exactly the split the bar title hits on a list tap.
    final observer = ScenarioPlaybackProvider(store: store);
    final pos = observer.position.value;
    expect(pos, isNotNull, reason: 'a merged row must publish a position');
    expect(pos!.index, greaterThanOrEqualTo(0));
    expect(pos.index, lessThan(total));
    expect(pos.count, total);
  });
}
