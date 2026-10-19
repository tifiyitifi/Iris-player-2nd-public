import 'dart:io';

import 'package:drift/drift.dart' show Variable;
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
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_source_provider.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/dao/app_meta_dao.dart';
import 'package:iris/models/db/migration/v43_migration.dart';
import 'package:iris/models/db/migration/v45_migration.dart';

/// Schema v45: the v39/v43 row-based derived index is retired.
///
/// This replaces the v39/v40/v43 SHAPE tests: those migrations still run on the
/// way to v45 (and are used here as the input), but their subject no longer
/// exists at HEAD, so what has to hold now is:
///
/// - a fresh install never creates the retired tables;
/// - an existing v44 database drops them WITHOUT losing its generation — the
///   shared index keeps serving read-path-for-read-path, no rebuild;
/// - the drop is re-entrant, and the surviving tables (`scenario_queue_builds`,
///   `scenario_shared_index`, `media_orders`, `tag_view_entries`, `app_meta`) are
///   untouched.
void main() {
  /// Tables the drop deliberately KEEPS. `scenario_queue_builds` carries the live
  /// generation the reads resolve; the shared index is that generation.
  const survivors = <String>[
    'scenario_queue_builds',
    'scenario_shared_index',
    'media_orders',
    'tag_view_entries',
    'app_meta',
  ];

  /// Index names the retired tables used to own (v39 + v42 + v43). Dropping a
  /// table drops its indexes, so not one of them may survive.
  const retiredIndexes = <String>[
    'idx_scenario_queue_node',
    'idx_vm_groups_rule_build',
    'idx_vm_group_members_node_build',
    'idx_vm_group_members_group_build',
    'idx_scenario_queue_seek',
    'idx_scenario_queue_build',
  ];

  Future<Set<String>> names(AppDatabase db, String type) async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = ?",
            variables: [Variable.withString(type)])
        .get();
    return {for (final r in rows) r.read<String>('name')};
  }

  Future<int> countOf(AppDatabase db, String table) async {
    final row =
        await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
    return row.read<int>('c');
  }

  ScenarioRepository repoOf(AppDatabase db) => ScenarioRepository(
        scenariosDao: ScenariosDao(db),
        sourcesDao: ScenarioSourcesDao(db),
        itemsDao: ScenarioExplicitItemsDao(db),
        excludesDao: ScenarioExcludesDao(db),
        statesDao: ScenarioStatesDao(db),
      );

  test('a fresh install has no retired row tables and keeps the survivors',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    expect(db.schemaVersion, greaterThanOrEqualTo(46));
    final tables = await names(db, 'table');
    for (final table in MigrationV45.droppedTables) {
      expect(tables, isNot(contains(table)), reason: '$table must not exist');
    }
    expect(tables, containsAll(survivors));
    final indexes = await names(db, 'index');
    for (final index in retiredIndexes) {
      expect(indexes, isNot(contains(index)), reason: '$index must not exist');
    }
  });

  test('a v44 database upgrades: the row tables go, the generation stays, and '
      'the queue keeps serving', () async {
    final dir = Directory.systemTemp.createTempSync('iris_v45_probe');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/iris_storages.db');

    // ── Build a real v44-shaped database: a scenario with a persisted shared
    //    index, plus the v43 row tables an installed v44 still carried.
    final db = AppDatabase(NativeDatabase(file));
    final nodeRepo = MediaNodeRepository(MediaNodesDao(db));
    final repo = repoOf(db);
    final indexDao = ScenarioQueueIndexDao(db);
    final sharedDao = ScenarioSharedIndexDao(db);
    for (var i = 0; i < 6; i++) {
      final path = 'A/000$i.mp4';
      await MediaNodesDao(db).insertNode(MediaNode.file(
        id: path,
        storageId: 'st1',
        path: path.split('/'),
        name: path.split('/').last,
        mediaType: MediaType.video,
        durationMs: 60000,
      ));
    }
    final scenario = await repo.createScenario(name: 'S');
    await repo.addSource(
        scenarioId: scenario.id, storageId: 'st1', path: 'A', recursive: true);
    final resolver = ScenarioResolver(
      repo: repo,
      nodeRepo: nodeRepo,
      scopedMediaTypes: () => null,
      providers: {
        ScenarioSourceKind.folder:
            FolderSourceProvider(scopedMediaTypes: () => null),
      },
      vmRulesProvider: () async => const [],
      queueIndexDao: indexDao,
      mediaOrderDao: MediaOrderDao(db),
      sharedIndexDao: sharedDao,
      mediaRevisionProvider: (_) async => 0,
    );
    final buildId = await resolver.buildQueueIndex(scenario.id);
    expect(await sharedDao.read(buildId), isNotNull);
    // The legacy shape this upgrade has to clean up.
    await MigrationV43(db).run(db.createMigrator());
    final before = await resolver.resolvePageIndexed(
        scenarioId: scenario.id, page: 0, pageSize: 10);
    expect(before.items, hasLength(6));
    // Rewrite the meta the v43 run cleared, so the generation is live again.
    await indexDao.writeBuildMeta(
        scenarioId: scenario.id,
        buildId: buildId,
        baseCount: 6,
        entryCount: 6);
    await db.customStatement('PRAGMA user_version = 44');
    await db.close();

    // ── Reopen at the new version: drift runs MigrationV45 on the way in.
    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final tables = await names(upgraded, 'table');
    for (final table in MigrationV45.droppedTables) {
      expect(tables, isNot(contains(table)), reason: '$table must be dropped');
    }
    expect(tables, containsAll(survivors));
    final row = await upgraded
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(row.read<int>('user_version'), greaterThanOrEqualTo(46));

    // The generation survived: the shared blob is still there and the reads
    // still resolve from it, with no rebuild.
    final upgradedShared = ScenarioSharedIndexDao(upgraded);
    expect(await upgradedShared.read(buildId), isNotNull);
    expect(await countOf(upgraded, 'scenario_queue_builds'), 1);
    final after = await ScenarioResolver(
      repo: repoOf(upgraded),
      nodeRepo: MediaNodeRepository(MediaNodesDao(upgraded)),
      scopedMediaTypes: () => null,
      providers: {
        ScenarioSourceKind.folder:
            FolderSourceProvider(scopedMediaTypes: () => null),
      },
      vmRulesProvider: () async => const [],
      queueIndexDao: ScenarioQueueIndexDao(upgraded),
      mediaOrderDao: MediaOrderDao(upgraded),
      sharedIndexDao: upgradedShared,
      mediaRevisionProvider: (_) async => 0,
    ).resolvePageIndexed(scenarioId: scenario.id, page: 0, pageSize: 10);
    expect(after.totalItems, before.totalItems);
    expect(after.items.map((e) => e.media.name).toList(),
        before.items.map((e) => e.media.name).toList());
  });

  test('MigrationV45 is re-entrant and leaves the survivors alone', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    // Put something in every surviving table, then drop twice: a re-run must not
    // touch any of them.
    await AppMetaDao(db).write('k', 'v');
    await db.customStatement(
        "INSERT INTO scenario_queue_builds "
        "(scenario_id, build_id, base_count, entry_count, built_at) "
        "VALUES ('sc', 1, 2, 2, 0)");
    await MigrationV43(db).run(db.createMigrator());
    // v43 clears the builds; restore one so the assertion has something to see.
    await db.customStatement(
        "INSERT INTO scenario_queue_builds "
        "(scenario_id, build_id, base_count, entry_count, built_at) "
        "VALUES ('sc', 1, 2, 2, 0)");

    await MigrationV45(db).run(db.createMigrator());
    await MigrationV45(db).run(db.createMigrator());

    final tables = await names(db, 'table');
    for (final table in MigrationV45.droppedTables) {
      expect(tables, isNot(contains(table)), reason: '$table must stay dropped');
    }
    expect(await countOf(db, 'scenario_queue_builds'), 1);
    expect(await AppMetaDao(db).read('k'), 'v');
  });

  test('app_meta still round-trips', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AppMetaDao(db);
    await dao.write('k', 'v');
    expect(await dao.read('k'), 'v');
    expect(await dao.increment('counter'), 1);
    expect(await dao.increment('counter'), 2);
    expect(await dao.read('counter'), '2');
    await dao.deleteKey('k');
    expect(await dao.read('k'), isNull);
  });
}
