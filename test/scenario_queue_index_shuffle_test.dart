import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/play_queue/engine/shuffle_engine.dart';
import 'package:iris/features/scenario_playback/model/db/dao/media_order_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_shared_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_state.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_source_provider.dart';
import 'package:iris/features/scenario_playback/resolver/shared_base_order.dart';
import 'package:iris/features/scenario_playback/resolver/shared_index_codec.dart';
import 'package:iris/models/db/app_database.dart';

/// The persisted derived index stores the BASE order — exclusion/dedup applied,
/// in ascending base-slot order — and shuffle is applied LAZILY on read.
///
/// Anything else breaks the contract in two directions at once: a shuffle
/// refresh (new seed) would need a full rebuild, and the read side would apply
/// the permutation a second time. These tests pin the contract, so "shuffle as
/// many times as you like" stays zero writes.
void main() {
  group('scenario index shuffle contract', () {
    late AppDatabase db;
    late ScenarioRepository repo;
    late ScenarioQueueIndexDao indexDao;
    late MediaOrderDao orderDao;
    late ScenarioSharedIndexDao sharedDao;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = ScenarioRepository(
        scenariosDao: ScenariosDao(db),
        sourcesDao: ScenarioSourcesDao(db),
        itemsDao: ScenarioExplicitItemsDao(db),
        excludesDao: ScenarioExcludesDao(db),
        statesDao: ScenarioStatesDao(db),
      );
      indexDao = ScenarioQueueIndexDao(db);
      orderDao = MediaOrderDao(db);
      sharedDao = ScenarioSharedIndexDao(db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> seedMedia(int n) async {
      final dao = MediaNodesDao(db);
      for (var i = 0; i < n; i++) {
        final path = 'A/${i.toString().padLeft(4, '0')}.mp4';
        await dao.insertNode(
          MediaNode.file(
            id: path,
            storageId: 'st1',
            path: path.split('/'),
            name: path.split('/').last,
            mediaType: MediaType.video,
            durationMs: 60000,
          ),
        );
      }
    }

    // The shared index is the only persisted representation, so a fixture that
    // expects INDEX-backed reads must wire it (otherwise the reads take the
    // legacy walk and the test would pass against the wrong path).
    ScenarioResolver buildResolver() => ScenarioResolver(
          repo: repo,
          nodeRepo: MediaNodeRepository(MediaNodesDao(db)),
          scopedMediaTypes: () => null,
          providers: {
            ScenarioSourceKind.folder:
                FolderSourceProvider(scopedMediaTypes: () => null),
          },
          vmRulesProvider: () async => const [],
          queueIndexDao: indexDao,
          mediaOrderDao: orderDao,
          sharedIndexDao: sharedDao,
          mediaRevisionProvider: (_) async => 0,
        );

    Future<String> scenarioWithSource({
      PlaybackOrder order = PlaybackOrder.sequential,
      int? seed,
    }) async {
      final scenario = await repo.createScenario(name: 'Anime');
      await repo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'A',
        recursive: true,
      );
      if (order != PlaybackOrder.sequential) {
        await repo.updateScenario(
          (await repo.getScenario(scenario.id))!.copyWith(order: order),
        );
      }
      if (seed != null) {
        await repo.updateState(
          ScenarioState(scenarioId: scenario.id, shuffleSeed: seed),
        );
      }
      return scenario.id;
    }

    Future<Map<int, String>> pathByNodeId() async {
      final rows =
          await db.customSelect('SELECT id, path FROM media_nodes').get();
      return {for (final r in rows) r.read<int>('id'): r.read<String>('path')};
    }

    List<String> naturalNames(int n) =>
        [for (var i = 0; i < n; i++) 'A/${i.toString().padLeft(4, '0')}.mp4'];

    test('the persisted order is the BASE order, not the shuffled view',
        () async {
      await seedMedia(40);
      final resolver = buildResolver();
      final id = await scenarioWithSource(order: PlaybackOrder.shuffled, seed: 9);
      await resolver.buildQueueIndex(id);

      final buildId = await indexDao.currentBuildId(id);
      // The persisted base order now lives in the shared index: decode it back
      // (via the shared orders it references) and read the rank → node sequence.
      final blobs = await sharedDao.read(buildId);
      expect(blobs, isNotNull);
      final slices = <SharedOrderSlice>[];
      for (final s in SharedIndexCodec.decodeSlices(blobs!.slices).singleSlices) {
        final order = await orderDao.read(s.orderKey, mediaRev: s.mediaRev);
        expect(order, isNotNull, reason: 'the shared order must persist');
        slices.add(
            SharedOrderSlice(orderKey: s.orderKey, order: order!, bits: s.bits));
      }
      final base = SharedBaseOrder(
        slices: slices,
        accepted: SharedIndexCodec.decodeBitmap(blobs.accepted),
      );
      expect(base.count, 40);
      final paths = await pathByNodeId();
      expect([for (final nodeId in base.materialize()) paths[nodeId]],
          naturalNames(40),
          reason: 'a shuffled scenario must still persist the natural base order');
    });

    test('a seed change needs no rebuild and the new seed drives the display',
        () async {
      await seedMedia(40);
      final resolver = buildResolver();
      final id = await scenarioWithSource(order: PlaybackOrder.shuffled, seed: 9);
      await resolver.buildQueueIndex(id);

      final signatureBefore = await resolver.definitionSignature(id);
      // Exactly what shuffleRefresh does: a new seed in state, nothing else.
      await repo.updateState(ScenarioState(scenarioId: id, shuffleSeed: 123));
      expect(await resolver.definitionSignature(id), signatureBefore,
          reason: 'the seed is a view: it must not invalidate the index');

      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 40);
      final engine = FeistelShuffle(123, 40);
      expect(
        page.items.map((e) => e.media.name).toList(),
        [
          for (var p = 0; p < 40; p++)
            '${engine.forward(p).toString().padLeft(4, '0')}.mp4'
        ],
        reason: 'the display must follow the CURRENT seed',
      );
    });

    test('a shuffle-direction flip is an exact reversal and writes nothing',
        () async {
      await seedMedia(40);
      final resolver = buildResolver();
      final id = await scenarioWithSource(order: PlaybackOrder.shuffled, seed: 9);
      await resolver.buildQueueIndex(id);
      final buildId = await indexDao.currentBuildId(id);

      final asc = await resolver.resolvePageIndexed(
          scenarioId: id,
          page: 0,
          pageSize: 40,
          sortDirection: SortDirection.asc);
      final desc = await resolver.resolvePageIndexed(
          scenarioId: id,
          page: 0,
          pageSize: 40,
          sortDirection: SortDirection.desc);
      expect(
        desc.items.map((e) => e.media.name).toList(),
        asc.items.map((e) => e.media.name).toList().reversed.toList(),
      );
      expect(await indexDao.currentBuildId(id), buildId);
    });

    test('the persisted signature keys on the base direction, not the shuffle '
        'view', () async {
      await seedMedia(5);
      final resolver = buildResolver();
      final id = await scenarioWithSource(); // sequential, asc
      final seqAsc = await resolver.definitionSignature(id);

      await repo.updateScenario((await repo.getScenario(id))!
          .copyWith(order: PlaybackOrder.shuffled));
      expect(await resolver.definitionSignature(id), seqAsc,
          reason: 'shuffled+asc shares the sequential base order');

      await repo.updateScenario((await repo.getScenario(id))!
          .copyWith(sortDirection: SortDirection.desc));
      expect(await resolver.definitionSignature(id), seqAsc,
          reason: 'the shuffle direction is a view, not a base-order change');

      await repo.updateScenario((await repo.getScenario(id))!
          .copyWith(order: PlaybackOrder.sequential));
      expect(await resolver.definitionSignature(id), isNot(seqAsc),
          reason: 'sequential+desc really does change the base order');
    });

    test('shuffled indexed display matches the legacy walk when nothing is '
        'filtered', () async {
      await seedMedia(40);
      final resolver = buildResolver();
      final id = await scenarioWithSource(order: PlaybackOrder.shuffled, seed: 9);
      await resolver.buildQueueIndex(id);

      final legacy =
          await resolver.resolvePage(scenarioId: id, page: 0, pageSize: 40);
      final indexed = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 40);
      expect(
        indexed.items.map((e) => e.media.name).toList(),
        legacy.items.map((e) => e.media.name).toList(),
        reason: 'the stored base order + one lazy permutation == the walk',
      );
    });

    test('exclude + shuffle: the domain is the accepted count and slots are '
        'base slots', () async {
      await seedMedia(10);
      final resolver = buildResolver();
      final id = await scenarioWithSource(order: PlaybackOrder.shuffled, seed: 5);
      await repo.addExcludeRule(
        scenarioId: id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: id,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'A/0003.mp4',
        ),
      );
      await resolver.buildQueueIndex(id);
      final buildId = await indexDao.currentBuildId(id);
      expect(await indexDao.visibleBaseCount(id, buildId), 9);

      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 20);
      expect(page.totalItems, 9);
      expect(page.items.map((e) => e.virtualIndex).toSet(),
          {for (var i = 0; i < 9; i++) i},
          reason: 'the indexed slot is the BASE slot');

      const base = [
        '0000', '0001', '0002', '0004', '0005', '0006', '0007', '0008', '0009'
      ];
      final engine = FeistelShuffle(5, 9);
      expect(
        page.items.map((e) => e.media.name).toList(),
        [for (var p = 0; p < 9; p++) '${base[engine.forward(p)]}.mp4'],
      );
    });
  });
}
