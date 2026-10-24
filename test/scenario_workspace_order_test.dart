import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_workspace_order.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/models/db/app_database.dart';

import 'helpers/sqlite3_loader.dart';

/// The primary window's playing workspace is "the oldest `systemPlaying` row".
/// Two places decide that: `ScenariosDao.getByType` (SQL, used by
/// `ensureSystemPlayingScenario`) and `oldestOfType` (Dart, used by the store's
/// scenario mirror). They MUST pick the same row — otherwise the queue the
/// engine plays and the queue the UI shows come from different rows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('both picks agree on the oldest row', () async {
    final a = await repo.createSystemPlayingWorkspace(name: 'A');
    final b = await repo.createSystemPlayingWorkspace(name: 'B');
    final c = await repo.createSystemPlayingWorkspace(name: 'C');

    // Give them distinct, explicit ages out of creation order: C oldest, then
    // A, then B. The pick must follow createdAt, not insertion order.
    final base = DateTime(2024, 1, 1);
    await repo.updateScenario(c.copyWith(createdAt: base));
    await repo.updateScenario(a.copyWith(createdAt: base.add(const Duration(hours: 1))));
    await repo.updateScenario(b.copyWith(createdAt: base.add(const Duration(hours: 2))));

    final bySql = await repo.getSystemPlayingScenario();
    final byList =
        oldestOfType(await repo.getAllScenarios(), ScenarioKind.systemPlaying);

    expect(bySql?.id, c.id);
    expect(byList?.id, c.id,
        reason: 'a different pick would show one window another row\'s queue');
  });

  test('a tie resolves to the same row on both sides', () async {
    final shared = DateTime(2024, 5, 5);
    final a = await repo.createSystemPlayingWorkspace(name: 'A');
    final b = await repo.createSystemPlayingWorkspace(name: 'B');
    await repo.updateScenario(a.copyWith(createdAt: shared));
    await repo.updateScenario(b.copyWith(createdAt: shared));

    final bySql = await repo.getSystemPlayingScenario();
    final byList =
        oldestOfType(await repo.getAllScenarios(), ScenarioKind.systemPlaying);

    expect(bySql, isNotNull);
    // The tie is a TOTAL order, not "whatever the sorter produced": `createdAt`
    // then rowid (insertion order). Both queries share that order, so the first
    // inserted row wins on both sides.
    expect(bySql!.id, a.id,
        reason: 'a same-millisecond tie must resolve to insertion order');
    expect(byList?.id, bySql.id,
        reason: 'a tie must not let the two resolution paths diverge');
  });

  test('other kinds never leak into the pick', () async {
    final entry = await repo.createEntryWorkspace();
    await repo.updateScenario(
        entry.copyWith(createdAt: DateTime(2020, 1, 1)));
    final sys = await repo.ensureSystemPlayingScenario();

    expect((await repo.getSystemPlayingScenario())!.id, sys.id);
    expect(
        oldestOfType(await repo.getAllScenarios(), ScenarioKind.entryWorkspace)!
            .id,
        entry.id);
  });
}
