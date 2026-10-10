import 'package:drift/drift.dart';
import 'package:iris/features/scenario_playback/model/db/adapters/scenario_explicit_item_adapter.dart';
import 'package:iris/features/scenario_playback/model/db/tables/scenario_explicit_items_table.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_explicit_item.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/path_prefix_remap.dart';

part 'scenario_explicit_items_dao.g.dart';

@DriftAccessor(tables: [ScenarioExplicitItemsTable])
class ScenarioExplicitItemsDao extends DatabaseAccessor<AppDatabase>
    with _$ScenarioExplicitItemsDaoMixin {
  ScenarioExplicitItemsDao(super.db);

  Future<List<ScenarioExplicitItem>> getByScenario(String scenarioId) async {
    final rows = await (select(scenarioExplicitItemsTable)
          ..where((t) => t.scenarioId.equals(scenarioId))
          ..orderBy([
            (t) => OrderingTerm(expression: t.batchId, mode: OrderingMode.asc),
            (t) => OrderingTerm(expression: t.addOrder, mode: OrderingMode.asc),
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
          ]))
        .get();
    return rows.map(ScenarioExplicitItemAdapter.fromDb).toList();
  }

  Future<void> upsert(ScenarioExplicitItem item) {
    return into(scenarioExplicitItemsTable).insertOnConflictUpdate(
      item.toCompanion(),
    );
  }

  Future<void> deleteItem(int itemId) {
    return (delete(scenarioExplicitItemsTable)..where((t) => t.id.equals(itemId))).go();
  }

  /// Deletes several explicit items in one statement. Empty input is a no-op
  /// (an `IN ()` list would otherwise be malformed SQL).
  Future<void> deleteItems(Iterable<int> itemIds) {
    final ids = itemIds.toList(growable: false);
    if (ids.isEmpty) return Future.value();
    return (delete(scenarioExplicitItemsTable)..where((t) => t.id.isIn(ids)))
        .go();
  }

  Future<void> deleteByScenario(String scenarioId) {
    return (delete(scenarioExplicitItemsTable)
          ..where((t) => t.scenarioId.equals(scenarioId)))
        .go();
  }

  /// Rewrites the leading [oldBase] of every explicit item path for
  /// [storageId] to [newBase] (drive-letter reassignment).
  Future<int> remapPathPrefix({
    required String storageId,
    required String oldBase,
    required String newBase,
  }) {
    final query = buildPathPrefixRemap(
      table: 'scenario_explicit_items',
      keyColumn: 'storage_id',
      keyValue: storageId,
      oldBase: oldBase,
      newBase: newBase,
    );
    return customUpdate(
      query.sql,
      variables: query.variables,
      updates: {scenarioExplicitItemsTable},
    );
  }
}
