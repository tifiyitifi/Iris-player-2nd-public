import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/commands/scenario_commands.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/models/db/app_database.dart';

/// `copyExplicitItems` feeds every clone / merge path (Save As, Override,
/// Append, Sync back).
///
/// The table's UNIQUE(scenario_id, storage_id, path) is NOT the primary key, so
/// an `insertOnConflictUpdate` of an item the target already carries THROWS and
/// aborts the whole command instead of being a no-op — and the append paths do
/// NOT clear the target first, so an overlapping file is the normal case (the
/// same media set loaded twice), not an edge case. Duplicates are collapsed on
/// the canonical [canonicalKey] form, exactly like `copySources`.
void main() {
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

  tearDown(() => db.close());

  /// Writes a legacy row straight to the table, bypassing the adapter's
  /// canonicalization — exactly the shape a pre-canonicalization build left
  /// behind (`/a/b` vs `a/b`).
  Future<void> seedLegacyItem(
          String scenarioId, String storageId, String rawPath) =>
      db.customInsert(
        'INSERT INTO scenario_explicit_items (scenario_id, storage_id, path) '
        'VALUES (?, ?, ?)',
        variables: [
          Variable.withString(scenarioId),
          Variable.withString(storageId),
          Variable.withString(rawPath),
        ],
      );

  test('collapses an item the target already carries instead of throwing',
      () async {
    final source = await repo.createScenario(name: 'Source');
    final target = await repo.createScenario(name: 'Target');
    await repo.addExplicitItem(
        scenarioId: source.id, storageId: 'st1', path: 'Anime/ep01.mp4');
    await repo.addExplicitItem(
        scenarioId: target.id, storageId: 'st1', path: 'Anime/ep01.mp4');

    await repo.copyExplicitItems(
        sourceScenarioId: source.id, targetScenarioId: target.id);

    final items = await repo.getExplicitItems(target.id);
    expect(items, hasLength(1));
  });

  test('collapses a legacy raw-slash variant of a target item', () async {
    final source = await repo.createScenario(name: 'Source');
    final target = await repo.createScenario(name: 'Target');
    await seedLegacyItem(target.id, 'st1', '/Anime/ep01.mp4');
    await repo.addExplicitItem(
        scenarioId: source.id, storageId: 'st1', path: 'Anime/ep01.mp4');

    await repo.copyExplicitItems(
        sourceScenarioId: source.id, targetScenarioId: target.id);

    expect(await repo.getExplicitItems(target.id), hasLength(1));
  });

  test('copies a new item and preserves batch/addOrder/uiSortKey', () async {
    final source = await repo.createScenario(name: 'Source');
    final target = await repo.createScenario(name: 'Target');
    await repo.addExplicitItem(
      scenarioId: source.id,
      storageId: 'st1',
      path: 'Anime/ep01.mp4',
      batchId: 'b1',
      uiSortKey: 'k1',
    );

    await repo.copyExplicitItems(
        sourceScenarioId: source.id, targetScenarioId: target.id);

    final item = (await repo.getExplicitItems(target.id)).single;
    expect(item.path, 'Anime/ep01.mp4');
    expect(item.batchId, 'b1');
    expect(item.uiSortKey, 'k1');
    expect(item.addOrder, 1);
    expect(item.id, isNot(0), reason: 'the copy gets its own row');
  });

  test('append merges an overlapping explicit item without aborting', () async {
    final workspace = await repo.ensureSystemPlayingScenario();
    final saved = await repo.createScenario(name: 'Saved');
    await repo.addExplicitItem(
        scenarioId: workspace.id, storageId: 'st1', path: 'Anime/ep01.mp4');
    await repo.addExplicitItem(
        scenarioId: saved.id, storageId: 'st1', path: 'Anime/ep01.mp4');

    await ScenarioCommands.append(
        workspace: workspace, source: saved, repo: repo);

    expect(await repo.getExplicitItems(workspace.id), hasLength(1));
  });

  test('appendTarget merges an overlapping explicit item without aborting',
      () async {
    final workspace = await repo.ensureSystemPlayingScenario();
    final target = await repo.createScenario(name: 'Target');
    await repo.addExplicitItem(
        scenarioId: workspace.id, storageId: 'st1', path: 'Anime/ep01.mp4');
    await repo.addExplicitItem(
        scenarioId: target.id, storageId: 'st1', path: 'Anime/ep01.mp4');

    await ScenarioCommands.appendTarget(
        workspace: workspace, targetScenarioId: target.id, repo: repo);

    expect(await repo.getExplicitItems(target.id), hasLength(1));
  });
}
