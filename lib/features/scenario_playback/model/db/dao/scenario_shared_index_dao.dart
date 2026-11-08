import 'package:drift/drift.dart';
import 'package:iris/features/scenario_playback/model/db/tables/scenario_shared_index_table.dart';
import 'package:iris/models/db/app_database.dart';

part 'scenario_shared_index_dao.g.dart';

/// The raw blobs of one persisted shared-order index (decoded by
/// `SharedIndexCodec`). Kept as plain bytes so this layer stays format-agnostic.
class ScenarioSharedIndexBlobs {
  const ScenarioSharedIndexBlobs({
    required this.baseCount,
    required this.slices,
    required this.accepted,
    required this.absorbed,
    required this.groupRows,
    required this.placeholders,
    required this.occurrence,
    required this.flags,
    this.elementOrder,
  });

  final int baseCount;
  final Uint8List slices;
  final Uint8List accepted;
  final Uint8List absorbed;
  final Uint8List groupRows;
  final Uint8List placeholders;
  final Uint8List occurrence;
  final Uint8List flags;

  /// Element-axis permutation (VM rows sorted by their displayed totals), or
  /// null for the identity permutation.
  final Uint8List? elementOrder;
}

/// Persistence for the shared-order derived index (schema v44).
///
/// A rebuildable cache keyed by the scenario's build id: it lives and dies with
/// the `scenario_queue_builds` meta row of that id (its GC drops every blob no
/// live build owns).
@DriftAccessor(tables: [ScenarioSharedIndexTable])
class ScenarioSharedIndexDao extends DatabaseAccessor<AppDatabase>
    with _$ScenarioSharedIndexDaoMixin {
  ScenarioSharedIndexDao(super.db);

  Future<void> write(
    int buildId, {
    required int baseCount,
    required Uint8List slices,
    required Uint8List accepted,
    required Uint8List absorbed,
    required Uint8List groupRows,
    required Uint8List placeholders,
    required Uint8List occurrence,
    required Uint8List flags,
    Uint8List? elementOrder,
  }) async {
    final base = <Object>[
      buildId,
      baseCount,
      slices,
      accepted,
      absorbed,
      groupRows,
      placeholders,
      occurrence,
      flags,
    ];
    if (elementOrder == null) {
      await customInsert(
        'INSERT OR REPLACE INTO scenario_shared_index '
        '(build_id, base_count, slices, accepted, absorbed, group_rows, '
        'placeholders, occurrence, flags) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [for (final v in base) _variableOf(v)],
      );
      return;
    }
    await customInsert(
      'INSERT OR REPLACE INTO scenario_shared_index '
      '(build_id, base_count, slices, accepted, absorbed, group_rows, '
      'placeholders, occurrence, flags, element_order) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [for (final v in base) _variableOf(v), Variable.withBlob(elementOrder)],
    );
  }

  static Variable<Object> _variableOf(Object value) => switch (value) {
        final int v => Variable.withInt(v),
        final Uint8List v => Variable.withBlob(v),
        _ => throw ArgumentError('unsupported variable: $value'),
      };

  Future<ScenarioSharedIndexBlobs?> read(int buildId) async {
    final row = await customSelect(
      'SELECT base_count, slices, accepted, absorbed, group_rows, '
      'placeholders, occurrence, flags, element_order FROM scenario_shared_index '
      'WHERE build_id = ?',
      variables: [Variable.withInt(buildId)],
    ).getSingleOrNull();
    if (row == null) return null;
    return ScenarioSharedIndexBlobs(
      baseCount: row.read<int>('base_count'),
      slices: row.read<Uint8List>('slices'),
      accepted: row.read<Uint8List>('accepted'),
      absorbed: row.read<Uint8List>('absorbed'),
      groupRows: row.read<Uint8List>('group_rows'),
      placeholders: row.read<Uint8List>('placeholders'),
      occurrence: row.read<Uint8List>('occurrence'),
      flags: row.read<Uint8List>('flags'),
      elementOrder: row.read<Uint8List?>('element_order'),
    );
  }

  Future<void> deleteBuild(int buildId) async {
    await customUpdate(
      'DELETE FROM scenario_shared_index WHERE build_id = ?',
      variables: [Variable.withInt(buildId)],
      updates: {scenarioSharedIndexTable},
    );
  }

  /// Drops every shared index whose build id is no longer live.
  Future<void> gcStaleGenerations() async {
    await customUpdate(
      'DELETE FROM scenario_shared_index WHERE build_id NOT IN '
      '(SELECT build_id FROM scenario_queue_builds)',
      updates: {scenarioSharedIndexTable},
    );
  }

  Future<int> count() async {
    final row = await customSelect(
            'SELECT COUNT(*) AS c FROM scenario_shared_index')
        .getSingle();
    return row.read<int>('c');
  }
}
