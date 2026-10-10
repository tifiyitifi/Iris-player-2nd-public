import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
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
