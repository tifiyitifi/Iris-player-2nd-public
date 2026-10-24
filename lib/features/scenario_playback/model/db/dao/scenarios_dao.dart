import 'package:drift/drift.dart';
import 'package:iris/features/scenario_playback/model/db/adapters/scenario_adapter.dart';
import 'package:iris/features/scenario_playback/model/db/tables/scenarios_table.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/models/db/app_database.dart';

part 'scenarios_dao.g.dart';

@DriftAccessor(tables: [ScenariosTable])
class ScenariosDao extends DatabaseAccessor<AppDatabase> with _$ScenariosDaoMixin {
  ScenariosDao(super.db);

  /// ONE age order for BOTH the list ([getAll]) and the LIMIT 1 pick
  /// ([getByType]).
  ///
  /// `createdAt` alone is not a total order: two workspaces minted in the same
  /// millisecond (two windows starting at once) tie, and SQLite is then free to
  /// return them in any order — the two queries could disagree. A disagreement
  /// would let `ensureSystemPlayingScenario` write into one row while the
  /// store's `oldestOfType` mirror (fed by [getAll]) and the workspace GC keep
  /// the other, so after the 30-day age gate the GC could reclaim the workspace
  /// the primary window is actually using.
  ///
  /// `rowid` is the insertion order. It is exactly what ties resolved to before
  /// this was explicit (a full-table scan feeds both queries in rowid order),
  /// so the ordering is codified, not changed. NEVER sort on `id`: it is a
  /// random UUID, so a tie would resolve differently per install and could move
  /// the primary window off its historical row.
  static final List<OrderingTerm Function($ScenariosTableTable)> _ageOrder = [
    (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc),
    (t) => OrderingTerm(
          expression: const CustomExpression<int>('rowid'),
          mode: OrderingMode.asc,
        ),
  ];

  Future<List<Scenario>> getAll() async {
    final rows = await (select(scenariosTable)..orderBy(_ageOrder)).get();
    return rows.map(ScenarioAdapter.fromDb).toList();
  }

  Future<Scenario?> getById(String scenarioId) async {
    final row = await (select(scenariosTable)
          ..where((t) => t.id.equals(scenarioId))
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : ScenarioAdapter.fromDb(row);
  }

  /// The OLDEST row of [kind], or null.
  ///
  /// The order is load-bearing: the primary window's playing workspace is "the
  /// oldest `systemPlaying` row", and `refreshScenarios` picks the same one from
  /// the already-loaded list (see `oldestOfType`). Both sides use [_ageOrder],
  /// so a same-millisecond tie resolves identically (insertion order) instead of
  /// depending on whatever order each query's sorter happened to produce.
  Future<Scenario?> getByType(ScenarioKind kind) async {
    final row = await (select(scenariosTable)
          ..where((t) => t.type.equals(kind.name))
          ..orderBy(_ageOrder)
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : ScenarioAdapter.fromDb(row);
  }

  Future<void> upsert(Scenario scenario) {
    return into(scenariosTable).insertOnConflictUpdate(
      scenario.toCompanion(),
    );
  }

  Future<void> deleteScenario(String scenarioId) {
    return (delete(scenariosTable)..where((t) => t.id.equals(scenarioId))).go();
  }
}
