import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_explicit_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/scan/model/scenario_source_refresh_state.dart';
import 'package:iris/features/scenario_playback/scan/service/scenario_source_refresh_service.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/storages/storage.dart';

import 'helpers/sqlite3_loader.dart';

Storage _storage(String id, {String base = ''}) => Storage.local(
      id: id,
      type: StorageType.internal,
      name: id,
      basePath: base.isEmpty ? <String>[] : base.split('/'),
    );

ScenarioSource _source(
  String storageId,
  String path, {
  int id = 0,
  String scenarioId = 'scn',
  ScenarioSourceKind kind = ScenarioSourceKind.folder,
}) =>
    ScenarioSource(
      id: id,
      scenarioId: scenarioId,
      storageId: storageId,
      path: path,
      sourceKind: kind,
    );

ScenarioExplicitItem _explicit(
  String storageId,
  String path, {
  int id = 0,
  String scenarioId = 'scn',
}) =>
    ScenarioExplicitItem(
      id: id,
      scenarioId: scenarioId,
      batchId: 'b0',
      storageId: storageId,
      path: path,
    );

void main() {
  group('collapseRootPaths', () {
    test('ancestor fully covers descendants', () {
      expect(collapseRootPaths(['a/b', 'a']), ['a']);
      expect(collapseRootPaths(['a/b/c', 'a', 'a/b']), ['a']);
    });

    test('siblings are both kept', () {
      expect(collapseRootPaths(['a/b', 'a/c']), ['a/b', 'a/c']);
    });

    test('prefix is not a path separator match', () {
      // "ab" must not be treated as under "a".
      expect(collapseRootPaths(['a', 'ab']), ['a', 'ab']);
    });

    test('normalizes slash variants to one canonical root', () {
      expect(collapseRootPaths(['/x/y/', 'x/y']), ['x/y']);
    });

    test('empty (whole storage) collapses everything', () {
      // Empty root means "the whole storage" and is represented by the storage
      // basePath by the caller; collapse only handles non-empty canonical.
      expect(collapseRootPaths(['', 'a/b']), ['a/b']);
    });
  });

  group('planSourceRefresh', () {
    test('groups sources by storage and collapses covered roots', () {
      final plan = planSourceRefresh(
        sources: [
          _source('s1', 'movies', id: 1),
          _source('s1', 'movies/2024', id: 2),
          _source('s2', 'tv', id: 3),
        ],
        explicitItems: const [],
        storageById: {'s1': _storage('s1'), 's2': _storage('s2')},
        nodeWeightByStorage: const {'s1': 100, 's2': 50},
      );

      expect(plan.units.length, 2);
      final s1 = plan.units.firstWhere((u) => u.storage.id == 's1');
      final s2 = plan.units.firstWhere((u) => u.storage.id == 's2');
      expect(s1.rootPaths, ['movies']);
      expect(s2.rootPaths, ['tv']);
      expect(s1.weight, 100);
      expect(s2.weight, 50);
    });

    test('drops sources whose storage no longer exists', () {
      final plan = planSourceRefresh(
        sources: [
          _source('gone', 'x', id: 1),
          _source('s1', 'y', id: 2),
        ],
        explicitItems: const [],
        storageById: {'s1': _storage('s1')},
        nodeWeightByStorage: const {},
      );

      expect(plan.units.length, 1);
      expect(plan.units.first.storage.id, 's1');
      expect(plan.dedupedSources, 1);
    });

    test('dedupes canonical duplicate rows within a storage', () {
      final plan = planSourceRefresh(
        sources: [
          _source('s1', 'a/b', id: 1),
          _source('s1', '/a/b', id: 2),
        ],
        explicitItems: const [],
        storageById: {'s1': _storage('s1')},
        nodeWeightByStorage: const {},
      );

      expect(plan.units.length, 1);
      expect(plan.dedupedSources, 1);
      expect(plan.units.first.rootPaths, ['a/b']);
    });

    test('empty dir path becomes the storage base path', () {
      final plan = planSourceRefresh(
        sources: [_source('s1', '', id: 1)],
        explicitItems: const [],
        storageById: {'s1': _storage('s1', base: 'root/dir')},
        nodeWeightByStorage: const {},
      );
      expect(plan.units.first.rootPaths, ['root/dir']);
    });

    test('absolutizes a storage-relative source root (scan-service form)', () {
      StoragePathCodec.baseResolver =
          (id) => id == 's1' ? const ['D:', 'media'] : null;
      try {
        final plan = planSourceRefresh(
          sources: [_source('s1', 'movies', id: 1)],
          explicitItems: const [],
          storageById: {'s1': _storage('s1', base: 'D:/media')},
          nodeWeightByStorage: const {},
        );
        expect(plan.units.single.rootPaths, ['D:/media/movies']);
        // A base-inclusive row stays idempotent.
        final plan2 = planSourceRefresh(
          sources: [_source('s1', 'D:/media/movies', id: 1)],
          explicitItems: const [],
          storageById: {'s1': _storage('s1', base: 'D:/media')},
          nodeWeightByStorage: const {},
        );
        expect(plan2.units.single.rootPaths, ['D:/media/movies']);
      } finally {
        StoragePathCodec.baseResolver = (_) => null;
      }
    });

    test('file sources contribute their parent directory root', () {
      final plan = planSourceRefresh(
        sources: [
          _source('s1', 'movies/a.mp4', id: 1, kind: ScenarioSourceKind.file),
        ],
        explicitItems: const [],
        storageById: {'s1': _storage('s1')},
        nodeWeightByStorage: const {},
      );
      expect(plan.units.first.rootPaths, ['movies']);
    });

    test('explicit items bring a storage in even without sources', () {
      final plan = planSourceRefresh(
        sources: const [],
        explicitItems: [_explicit('s1', 'movies/a.mp4')],
        storageById: {'s1': _storage('s1')},
        nodeWeightByStorage: const {},
      );
      expect(plan.units.length, 1);
      // No directory/file source exists, so there is NOTHING to scan: the
      // explicit file is only existence-checked, never subtree-scanned.
      expect(plan.units.first.rootPaths, isEmpty);
      expect(plan.units.first.explicitItems.length, 1);
    });

    test('weight falls back to 1 when unknown', () {
      final plan = planSourceRefresh(
        sources: [_source('s1', 'a', id: 1)],
        explicitItems: const [],
        storageById: {'s1': _storage('s1')},
        nodeWeightByStorage: const {},
      );
      expect(plan.units.first.weight, 1);
    });
  });

  group('ScenarioSourceRefreshState.overallFraction', () {
    test('reaches 1.0 only when every unit is finished', () {
      var state = const ScenarioSourceRefreshState(
        phase: ScenarioSourceRefreshPhase.running,
        units: [
          ScenarioSourceRefreshUnit(storageId: 'a', storageName: 'A', weight: 1),
          ScenarioSourceRefreshUnit(storageId: 'b', storageName: 'B', weight: 1),
        ],
      );
      expect(state.overallFraction, 0);

      state = state.copyWith(units: [
        state.units[0].copyWith(fraction: 1, finished: true),
        state.units[1].copyWith(fraction: 0.5),
      ]);
      // 1.5 / 2
      expect(state.overallFraction, closeTo(0.75, 1e-9));
      expect(state.overallFraction, lessThan(1.0));

      state = state.copyWith(units: [
        state.units[0],
        state.units[1].copyWith(fraction: 1, finished: true),
      ]);
      expect(state.overallFraction, 1.0);
    });

    test('weights larger storages more', () {
      const state = ScenarioSourceRefreshState(
        phase: ScenarioSourceRefreshPhase.running,
        units: [
          ScenarioSourceRefreshUnit(
              storageId: 'big', storageName: 'Big', weight: 9, fraction: 1, finished: true),
          ScenarioSourceRefreshUnit(
              storageId: 'small', storageName: 'Small', weight: 1, fraction: 0),
        ],
      );
      expect(state.overallFraction, closeTo(0.9, 1e-9));
    });

    test('skipped unit still counts as complete (decided, not scanned)', () {
      const state = ScenarioSourceRefreshState(
        phase: ScenarioSourceRefreshPhase.running,
        units: [
          ScenarioSourceRefreshUnit(
              storageId: 'a', storageName: 'A', weight: 1, fraction: 1, finished: true),
          ScenarioSourceRefreshUnit(
              storageId: 'b',
              storageName: 'B',
              weight: 1,
              fraction: 1,
              finished: true,
              skipped: true),
        ],
      );
      expect(state.overallFraction, 1.0);
    });
  });

  group('ScenarioRepository.dedupeScenarioSources', () {
    ensureSqlite3Loaded();
    late AppDatabase db;
    late ScenarioRepository repo;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = ScenarioRepository(
        scenariosDao: ScenariosDao(db),
        sourcesDao: ScenarioSourcesDao(db),
        itemsDao: ScenarioExplicitItemsDao(db),
        excludesDao: ScenarioExcludesDao(db),
        statesDao: ScenarioStatesDao(db),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('removes canonical duplicates for the target scenario only',
        () async {
      final scn = await repo.createScenario(name: 'A');
      final other = await repo.createScenario(name: 'B');

      // Legacy dirty rows: the physical table's UNIQUE constraint is enforced
      // on the CANONICAL path, but DBs migrated from before canonicalization
      // may still hold raw-slash variants. Insert them with raw SQL so the
      // healing pass has something real to collapse.
      final sid = scn.id;
      final oid = other.id;
      await db.customStatement(
        "INSERT INTO scenario_sources (scenario_id, storage_id, path, recursive, source_kind, sort_order) "
        "VALUES (?, 's1', 'a/b', 1, 'folder', 0)",
        [sid],
      );
      await db.customStatement(
        "INSERT INTO scenario_sources (scenario_id, storage_id, path, recursive, source_kind, sort_order) "
        "VALUES (?, 's1', '/a/b', 1, 'folder', 1)",
        [sid],
      );
      // A different scenario with the same raw path must stay untouched.
      await db.customStatement(
        "INSERT INTO scenario_sources (scenario_id, storage_id, path, recursive, source_kind, sort_order) "
        "VALUES (?, 's1', 'a/b', 1, 'folder', 0)",
        [oid],
      );

      final removed = await repo.dedupeScenarioSources(scn.id);
      expect(removed, 1);
      expect((await repo.getSources(scn.id)).length, 1);
      // The other scenario is untouched.
      expect((await repo.getSources(other.id)).length, 1);
    });

    test('returns 0 on a compliant scenario', () async {
      final scn = await repo.createScenario(name: 'A');
      await repo.addSource(
        scenarioId: scn.id,
        storageId: 's1',
        path: 'a',
        recursive: true,
      );
      await repo.addSource(
        scenarioId: scn.id,
        storageId: 's1',
        path: 'b',
        recursive: true,
      );
      expect(await repo.dedupeScenarioSources(scn.id), 0);
    });
  });
}
