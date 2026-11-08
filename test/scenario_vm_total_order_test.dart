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
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_source_provider.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/app_database.dart';

/// A VM merged row must sort by the totals it DISPLAYS, not by its first
/// member's base rank.
///
/// The fixture makes that visible: a group of three small files has a LARGER
/// total than the one file that follows it, so on an ascending size/duration
/// sort the group has to move AFTER that file.
void main() {
  group('VM element order', () {
    late AppDatabase db;
    late MediaNodesDao nodesDao;
    late ScenarioRepository repo;
    late ScenarioQueueIndexDao indexDao;
    late MediaOrderDao orderDao;
    late ScenarioSharedIndexDao sharedDao;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      nodesDao = MediaNodesDao(db);
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

    VirtualMediaRule rule() => VirtualMediaRule(
          id: 'r1',
          name: 'R',
          matchMode: VmMatchMode.specifiedDirRecursive,
          paths: const ['A'],
          boundary: VmBoundaryMode.sameDirOnly,
          useDurationCap: false,
          useCountCap: true,
          maxItemCount: 3,
          enabled: true,
        );

    ScenarioResolver resolver({List<VirtualMediaRule> rules = const []}) =>
        ScenarioResolver(
          repo: repo,
          nodeRepo: MediaNodeRepository(nodesDao),
          scopedMediaTypes: () => null,
          providers: {
            ScenarioSourceKind.folder:
                FolderSourceProvider(scopedMediaTypes: () => null),
          },
          vmRulesProvider: () async => rules,
          queueIndexDao: indexDao,
          mediaOrderDao: orderDao,
          sharedIndexDao: sharedDao,
          mediaRevisionProvider: (_) async => 0,
        );

    Future<void> seedFiles() async {
      // a=1, b=2, c=3 form the group (total 6); d=4 stands alone. Ascending by
      // size the single file must come FIRST, so the group's anchor rank (0) is
      // not its display ordinal.
      const specs = [
        ('a.mp4', 1, 1000),
        ('b.mp4', 2, 1000),
        ('c.mp4', 3, 1000),
        ('d.mp4', 4, 1000),
      ];
      var day = 1;
      for (final spec in specs) {
        await nodesDao.insertNode(MediaNode.file(
          id: 'st1:A/${spec.$1}',
          storageId: 'st1',
          path: ['A', spec.$1],
          parentPath: 'A',
          name: spec.$1,
          normalizedName: spec.$1,
          mediaType: MediaType.video,
          sizeInBytes: spec.$2,
          durationMs: spec.$3,
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(
              DateTime.utc(2024, 1, day++).millisecondsSinceEpoch),
        ));
      }
    }

    Future<String> newScenario({
      ScenarioSortField sortField = ScenarioSortField.name,
      SortDirection direction = SortDirection.asc,
    }) async {
      final scenario = await repo.createScenario(name: 'S');
      await repo.updateScenario(scenario.copyWith(
        sortField: sortField,
        sortDirection: direction,
      ));
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      return scenario.id;
    }

    test('a group sorts by its size TOTAL, not by its first member', () async {
      await seedFiles();
      for (final direction in SortDirection.values) {
        final id = await newScenario(
            sortField: ScenarioSortField.sizeInBytes, direction: direction);
        await resolver(rules: [rule()]).buildQueueIndex(id);

        final blobs = await sharedDao.read(await indexDao.currentBuildId(id));
        expect(blobs!.elementOrder, isNotNull,
            reason: 'a VM view persists its element permutation');

        final page = await resolver(rules: [rule()])
            .resolvePageIndexed(scenarioId: id, page: 0, pageSize: 10);
        expect(page.totalItems, 2);
        if (direction == SortDirection.asc) {
          // d(4) < group total(6)
          expect(page.items[0].virtualMerged, isFalse);
          expect(page.items[0].media.name, 'd.mp4');
          expect(page.items[1].virtualMerged, isTrue);
          expect(page.items[1].vmChildren, hasLength(3));
        } else {
          expect(page.items[0].virtualMerged, isTrue);
          expect(page.items[1].media.name, 'd.mp4');
        }
      }
    });

    test('a group sorts by its duration TOTAL', () async {
      await seedFiles();
      final id = await newScenario(
          sortField: ScenarioSortField.durationMs,
          direction: SortDirection.asc);
      await resolver(rules: [rule()]).buildQueueIndex(id);

      final page = await resolver(rules: [rule()])
          .resolvePageIndexed(scenarioId: id, page: 0, pageSize: 10);
      expect(page.totalItems, 2);
      // d contributes 1000ms; the group's total is 3000ms.
      expect(page.items[0].media.name, 'd.mp4');
      expect(page.items[1].virtualMerged, isTrue);
    });

    test('the tapped ordinal starts the group the list displays', () async {
      await seedFiles();
      final id = await newScenario(
          sortField: ScenarioSortField.sizeInBytes,
          direction: SortDirection.asc);
      await resolver(rules: [rule()]).buildQueueIndex(id);

      final r = resolver(rules: [rule()]);
      final page =
          await r.resolvePageIndexed(scenarioId: id, page: 0, pageSize: 10);
      for (var ordinal = 0; ordinal < page.items.length; ordinal++) {
        final item = await r.resolveItemAtIndex(id, ordinal);
        expect(item, isNotNull);
        expect(item!.media.name, page.items[ordinal].media.name,
            reason: 'ordinal $ordinal must seek the row the page shows');
        expect(item.virtualMerged, page.items[ordinal].virtualMerged);
      }
    });

    test('without VM rules no permutation is stored', () async {
      await seedFiles();
      final id = await newScenario(sortField: ScenarioSortField.sizeInBytes);
      await resolver().buildQueueIndex(id);

      final blobs = await sharedDao.read(await indexDao.currentBuildId(id));
      expect(blobs!.elementOrder, isNull,
          reason: 'a non-VM view keeps the identity element axis for free');
    });
  });
}
