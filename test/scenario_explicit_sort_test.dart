import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_query.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/models/db/app_database.dart';

// An explicit-item queue (e.g. a workspace built by "Append") must take part in
// the scenario's sort like a folder source does — otherwise the queue's sort
// menu silently does nothing.
void main() {
  group('explicit items honor the scenario sort', () {
    late AppDatabase db;
    late ScenarioRepository repo;
    late ScenarioResolver resolver;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = ScenarioRepository(
        scenariosDao: ScenariosDao(db),
        sourcesDao: ScenarioSourcesDao(db),
        itemsDao: ScenarioExplicitItemsDao(db),
        excludesDao: ScenarioExcludesDao(db),
        statesDao: ScenarioStatesDao(db),
      );
      resolver = ScenarioResolver(
        repo: repo,
        nodeRepo: MediaNodeRepository(MediaNodesDao(db)),
        scopedMediaTypes: () => null,
      );
    });

    tearDown(() async => db.close());

    Future<void> seed(MediaNode node) => MediaNodesDao(db).insertNode(node);

    MediaNode file(String path, {int? size, int? durationMs}) => MediaNode.file(
          id: path,
          storageId: 'st1',
          path: path.split('/'),
          name: path.split('/').last,
          mediaType: MediaType.video,
          sizeInBytes: size,
          durationMs: durationMs,
        );

    Future<List<String>> orderFor(
      Scenario scenario,
      ScenarioSortField field,
      SortDirection direction,
    ) async {
      await repo.updateScenario(
        scenario.copyWith(sortField: field, sortDirection: direction),
      );
      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 50,
      );
      return page.items.map((e) => e.media.name).toList();
    }

    test('sorts by size, nulls last, honoring direction', () async {
      await seed(file('D:/a.mp4', size: 100));
      await seed(file('D:/b.mp4', size: 300));
      await seed(file('D:/c.mp4', size: 200));

      final scenario = await repo.createScenario(name: 'q');
      // Added in a deliberately non-size order (equals name order).
      for (final p in ['D:/a.mp4', 'D:/b.mp4', 'D:/c.mp4']) {
        await repo.addExplicitItem(
            scenarioId: scenario.id, storageId: 'st1', path: p);
      }
      // A missing file becomes an unavailable placeholder → sorts last.
      await repo.addExplicitItem(
          scenarioId: scenario.id, storageId: 'st1', path: 'D:/missing.mp4');

      expect(
        await orderFor(
            scenario, ScenarioSortField.sizeInBytes, SortDirection.desc),
        ['b.mp4', 'c.mp4', 'a.mp4', 'missing.mp4'],
      );
      expect(
        await orderFor(
            scenario, ScenarioSortField.sizeInBytes, SortDirection.asc),
        ['a.mp4', 'c.mp4', 'b.mp4', 'missing.mp4'],
      );
    });

    test('a stored 0 for size/duration is unknown: same order as the DAO',
        () async {
      await seed(file('D:/a.mp4', size: 999, durationMs: 999));
      await seed(file('D:/b.mp4', size: 100, durationMs: 10));
      await seed(file('D:/z.mp4', size: 999, durationMs: 999));
      // A lane that cannot stat (SAF / WebDAV / FTP) stores a literal 0; the
      // adapter refuses to write it, so own the value the way such rows carry it.
      await db.customStatement(
          "UPDATE media_nodes SET size_in_bytes = 0, duration_ms = 0 "
          "WHERE storage_id = 'st1' AND path = 'D:/z.mp4'");

      final scenario = await repo.createScenario(name: 'q');
      for (final p in ['D:/a.mp4', 'D:/b.mp4', 'D:/z.mp4']) {
        await repo.addExplicitItem(
            scenarioId: scenario.id, storageId: 'st1', path: p);
      }
      // No node at all: the NULL spelling of the same "unknown" bucket.
      await repo.addExplicitItem(
          scenarioId: scenario.id, storageId: 'st1', path: 'D:/missing.mp4');

      Future<List<String>> daoOrder(
        ScenarioSortField field,
        SortDirection direction,
      ) async {
        final result = await MediaNodesDao(db).getPagedNodes(MediaNodePageQuery(
          page: 1,
          pageSize: 100,
          storageId: 'st1',
          nodeKind: MediaNodeKind.file,
          matchAllInStorage: true,
          mediaTypes: const [MediaType.video],
          sortField: field.toMediaSortField(),
          sortDirection: direction,
          pathGroupFirst: false,
        ));
        return [for (final n in result.items) n.name];
      }

      for (final field in [
        ScenarioSortField.sizeInBytes,
        ScenarioSortField.durationMs,
      ]) {
        for (final direction in SortDirection.values) {
          final explicit = await orderFor(scenario, field, direction);
          // The explicit queue must page in the folder-source order, and the
          // unknown rows (0 and NULL) stay last in BOTH directions.
          expect(explicit, [...await daoOrder(field, direction), 'missing.mp4'],
              reason: '$field ${direction.name}');
        }
      }
    });

    test('sorts by duration and by name', () async {
      await seed(file('D:/x.mp4', durationMs: 10));
      await seed(file('D:/y.mp4', durationMs: 30));
      await seed(file('D:/z.mp4', durationMs: 20));

      final scenario = await repo.createScenario(name: 'q');
      for (final p in ['D:/x.mp4', 'D:/y.mp4', 'D:/z.mp4']) {
        await repo.addExplicitItem(
            scenarioId: scenario.id, storageId: 'st1', path: p);
      }

      expect(
        await orderFor(scenario, ScenarioSortField.durationMs, SortDirection.desc),
        ['y.mp4', 'z.mp4', 'x.mp4'],
      );
      expect(
        await orderFor(scenario, ScenarioSortField.name, SortDirection.asc),
        ['x.mp4', 'y.mp4', 'z.mp4'],
      );
    });
  });
}
