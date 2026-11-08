import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
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
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_source_provider.dart';
import 'package:iris/features/scenario_playback/resolver/shared_base_order.dart';
import 'package:iris/features/scenario_playback/resolver/shared_media_order.dart';
import 'package:iris/models/db/app_database.dart';

import 'helpers/shared_index_decode.dart';

/// The shared-order base order must reproduce the per-scenario permutation
/// exactly — the whole point is that rank/select over bitmaps is a DROP-IN for the
/// v43 rows it replaced. The resolver's OWN persisted shared index is the oracle:
/// the tests below build the slices independently and must land on the same order.
void main() {
  group('composition (pure Dart)', () {
    test('rank/select over slices reproduces concat + exclusion + dedup', () {
      final order = Int32List.fromList([10, 11, 12, 13, 14, 15]);
      final a = SharedOrderSlice.of(
          orderKey: 'a', order: order, select: (id) => id <= 13);
      final b = SharedOrderSlice.of(
          orderKey: 'b', order: order, select: (id) => id >= 12);
      // Virtual space: [10,11,12,13] ++ [12,13,14,15].
      final base = SharedBaseOrder.build(
        slices: [a, b],
        isExcluded: (id) => id == 11,
        dedupKey: (id) => '$id',
      );
      expect(base.virtualSize, 8);
      expect(base.count, 5);
      expect(base.materialize(), [10, 12, 13, 14, 15]);
      expect(base.nodeIdAt(0), 10);
      expect(base.nodeIdAt(2), 13);
      expect(base.nodeIdAt(4), 15);
      expect(base.nodeIdAt(5), isNull);
      expect(base.nodeIdAt(-1), isNull);
    });

    test('without dedup every virtual element is accepted', () {
      final order = Int32List.fromList([1, 2, 3]);
      final a = SharedOrderSlice.of(
          orderKey: 'a', order: order, select: (id) => id <= 2);
      final b = SharedOrderSlice.of(
          orderKey: 'b', order: order, select: (id) => id >= 2);
      final base = SharedBaseOrder.build(slices: [a, b]);
      expect(base.materialize(), [1, 2, 2, 3]);
    });

    test('empty slices yield an empty order', () {
      final base = SharedBaseOrder.build(
        slices: [
          SharedOrderSlice.of(
              orderKey: 'a', order: Int32List(0), select: (_) => true)
        ],
      );
      expect(base.count, 0);
      expect(base.materialize(), isEmpty);
      expect(base.nodeIdAt(0), isNull);
    });
  });

  group('parity with the resolver\'s persisted shared base order', () {
    late AppDatabase db;
    late MediaNodesDao nodesDao;
    late MediaNodeRepository nodeRepo;
    late ScenarioRepository repo;
    late ScenarioQueueIndexDao indexDao;
    late MediaOrderDao orderDao;
    late ScenarioSharedIndexDao sharedDao;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      nodesDao = MediaNodesDao(db);
      nodeRepo = MediaNodeRepository(nodesDao);
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
    tearDown(() => db.close());

    const mediaTypes = <MediaType>[MediaType.video, MediaType.audio];

    Future<void> seed() async {
      const files = <(String, int?)>[
        ('A/x.mp4', 300),
        ('A/y.mp4', 100),
        ('A/z.mp4', null),
        ('A/sub/p.mp4', 200),
        ('A/sub/q.mp4', 50),
        ('B/m.mp4', 400),
        ('B/n.mp4', 150),
      ];
      for (final (path, durationMs) in files) {
        await nodesDao.insertNode(MediaNode.file(
          id: path,
          storageId: 'st1',
          path: path.split('/'),
          name: path.split('/').last,
          mediaType: MediaType.video,
          durationMs: durationMs,
        ));
      }
    }

    /// The resolver's OWN persisted base order, decoded from the shared index it
    /// wrote. This is the oracle: the test builds its slices independently, so
    /// agreement means the builder's slices/bitmaps encode the same order.
    ScenarioResolver resolver() => ScenarioResolver(
          repo: repo,
          nodeRepo: nodeRepo,
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

    Future<Map<int, String>> pathByNodeId() async {
      final rows = await db
          .customSelect('SELECT id, path FROM media_nodes')
          .get();
      return {for (final r in rows) r.read<int>('id'): r.read<String>('path')};
    }

    Future<List<int>> persistedBaseOrder(String scenarioId) async {
      final buildId = await indexDao.currentBuildId(scenarioId);
      expect(buildId, greaterThan(0));
      final blobs = await sharedDao.read(buildId);
      expect(blobs, isNotNull, reason: 'the scenario must be representable');
      final decoded = await decodeSharedIndex(blobs: blobs!, orderDao: orderDao);
      return [
        for (var i = 0; i < decoded.base.count; i++) decoded.base.nodeIdAt(i)!,
      ];
    }

    /// The order the resolver's WALK serves. For a multi-source scenario the
    /// persisted representation is the merged GLOBAL order (not the
    /// per-source concatenation), so this is the oracle the index must match.
    Future<List<int>> walkOrder(String scenarioId) async {
      final page = await resolver().resolvePage(
          scenarioId: scenarioId, page: 0, pageSize: 10000);
      return [
        for (final item in page.items)
          int.tryParse(item.media.maybeMap(
                file: (f) => f.id,
                orElse: () => '',
              )) ??
              -1,
      ];
    }

    /// The shared-order view of the same scenario.
    Future<SharedBaseOrder> sharedBaseOrder(
      List<({String storageId, String path, bool recursive})> sources, {
      bool Function(String path)? excludePath,
      bool dedup = false,
    }) async {
      final paths = await pathByNodeId();
      final slices = <SharedOrderSlice>[];
      for (final source in sources) {
        final order = await SharedMediaOrder.build(
          nodeRepo,
          storageId: source.storageId,
          sortField: ScenarioSortField.name,
          sortDirection: SortDirection.asc,
          pathGroupFirst: true,
          mediaTypes: mediaTypes,
        );
        slices.add(SharedOrderSlice.of(
          orderKey: SharedMediaOrder.orderKey(
            storageId: source.storageId,
            sortField: ScenarioSortField.name,
            sortDirection: SortDirection.asc,
            pathGroupFirst: true,
            mediaTypes: mediaTypes,
          ),
          order: order,
          select: (id) {
            final p = paths[id]!;
            if (source.path.isEmpty) return source.recursive;
            return p == source.path ||
                (source.recursive && p.startsWith('${source.path}/'));
          },
        ));
      }
      return SharedBaseOrder.build(
        slices: slices,
        isExcluded:
            excludePath == null ? null : (id) => excludePath(paths[id]!),
        // The scenario's default is allowDuplicate, so dedup is opt-in.
        dedupKey: dedup ? (id) => paths[id]! : null,
      );
    }

    test('single source: shared base order == persisted base order', () async {
      await seed();
      final r = resolver();
      final scenario = await repo.createScenario(name: 'S');
      // [sharedBaseOrder] pins pathGroupFirst: true, so the scenario must group
      // too — the app default is flat since v46.
      await repo.updateScenario(scenario.copyWith(sourceInternalFirst: true));
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);

      await r.buildQueueIndex(scenario.id);
      final persisted = await persistedBaseOrder(scenario.id);
      expect(persisted, isNotEmpty);

      final shared = await sharedBaseOrder(
          const [(storageId: 'st1', path: 'A', recursive: true)]);
      expect(shared.materialize(), persisted);
    });

    test('overlapping sources + exclude: persisted == walk', () async {
      await seed();
      final r = resolver();
      final scenario = await repo.createScenario(name: 'S');
      // [sharedBaseOrder] pins pathGroupFirst: true, so the scenario must group
      // too — the app default is flat since v46.
      await repo.updateScenario(scenario.copyWith(sourceInternalFirst: true));
      // Overlapping sources so cross-source duplication is exercised.
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A/sub',
          recursive: true);
      await repo.addExcludeRule(
        scenarioId: scenario.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: scenario.id,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'A/x.mp4',
        ),
      );

      await r.buildQueueIndex(scenario.id);
      final persisted = await persistedBaseOrder(scenario.id);
      expect(persisted, isNotEmpty);
      // The excluded file is really gone; the overlap is NOT deduped (default
      // duplicatePolicy is allowDuplicate).
      final paths = await pathByNodeId();
      expect(persisted.any((id) => paths[id] == 'A/x.mp4'), isFalse);
      expect(persisted.toSet().length, lessThan(persisted.length));

      // The persisted order is the GLOBAL one (merged base order), so the walk
      // is the oracle — not a per-source concatenation.
      expect(persisted, await walkOrder(scenario.id));
    });

    test('dedup policy collapses the overlap in both views', () async {
      await seed();
      final r = resolver();
      final scenario = await repo.createScenario(name: 'S');
      // [sharedBaseOrder] pins pathGroupFirst: true, so the scenario must group
      // too — the app default is flat since v46.
      await repo.updateScenario(scenario.copyWith(sourceInternalFirst: true));
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A/sub',
          recursive: true);
      await db.customStatement(
        "UPDATE scenario SET duplicate_policy = 'deduplicate' WHERE id = ?",
        [scenario.id],
      );

      await r.buildQueueIndex(scenario.id);
      final persisted = await persistedBaseOrder(scenario.id);
      // Dedup really collapsed the overlap.
      expect(persisted.toSet().length, persisted.length);

      final shared = await sharedBaseOrder(
        const [
          (storageId: 'st1', path: 'A', recursive: true),
          (storageId: 'st1', path: 'A/sub', recursive: true),
        ],
        dedup: true,
      );
      // Both views agree that the overlap collapsed to ONE row; the ORDER is
      // the global one now, so only the SET is compared against the
      // concatenation reference.
      expect(shared.materialize().toSet(), persisted.toSet());
      expect(persisted, await walkOrder(scenario.id));
    });
  });
}
