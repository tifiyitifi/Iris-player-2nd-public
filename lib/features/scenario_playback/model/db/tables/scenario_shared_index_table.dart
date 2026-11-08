import 'package:drift/drift.dart';

/// The persisted shared-order derived index for one scenario generation
/// (schema v44).
///
/// This is the compact replacement for the v43 row-per-element tables: it holds
/// the per-source membership bitmaps, the accepted bitmap over the virtual
/// space, the absorbed bitmap, and the group/member overlay. The blobs are
/// encoded by `SharedIndexCodec`; the DAO only moves bytes.
class ScenarioSharedIndexTable extends Table {
  @override
  String get tableName => 'scenario_shared_index';

  /// The scenario generation this index belongs to (1:1 with a build id).
  IntColumn get buildId => integer()();

  /// Accepted base element count (the queue's rank space).
  IntColumn get baseCount => integer()();

  /// Per-source `(order_key, bitmap)` blobs, in source order.
  BlobColumn get slices => blob()();

  /// Accepted membership over the concatenated virtual space.
  BlobColumn get accepted => blob()();

  /// Ranks absorbed into a group row (emit no row of their own).
  BlobColumn get absorbed => blob()();

  /// Group rows: anchor, group id, rule-ordered members.
  BlobColumn get groupRows => blob()();

  /// Sparse placeholder identities by rank.
  BlobColumn get placeholders => blob()();

  /// Sparse non-zero file occurrence indices by rank.
  BlobColumn get occurrence => blob()();

  /// Sparse raw row flags by rank.
  BlobColumn get flags => blob()();

  /// Element-axis permutation (schema v52): element ordinal → anchor rank,
  /// sorted by the row's DISPLAYED key (a VM group by its member totals).
  ///
  /// Empty/NULL means the identity permutation — a scenario without VM rules
  /// never pays for it.
  BlobColumn get elementOrder => blob().nullable()();

  @override
  Set<Column> get primaryKey => {buildId};
}
