import 'package:drift/drift.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';

/// A Scenario-owned bulk media producer (C4). NOT a global MediaSource.
///
/// It must never modify global media sources and never trigger filesystem
/// scanning directly — it only references where media comes from.
class ScenarioSourcesTable extends Table {
  @override
  String get tableName => 'scenario_sources';

  IntColumn get id => integer().autoIncrement()();

  TextColumn get scenarioId => text()();

  TextColumn get storageId => text()();

  /// Path relative to the storage root. Empty string = entire storage.
  TextColumn get path => text().withDefault(const Constant(''))();

  BoolColumn get recursive => boolean().withDefault(const Constant(false))();

  TextColumn get sourceKind => textEnum<ScenarioSourceKind>().nullable()();

  /// Insertion timeline within the scenario (A4): max+1, never reused.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime().nullable()();

  @override
  List<String> get customConstraints => [
        // The business key is (scenario, storage, path).
        'UNIQUE(scenario_id, storage_id, path)',
      ];
}
