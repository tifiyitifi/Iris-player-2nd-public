import 'package:drift/drift.dart';

/// A shared, scenario-independent ORDER over one media scope (schema v44).
///
/// The v43 derived index persists a per-scenario permutation of node ids —
/// twice (queue rows and VM group members). With many whole-library scenarios
/// that is largely the SAME permutation stored N times. A shared order is built
/// once per (scope, sort, direction, grouping, media-type set) and every
/// scenario then stores only a membership bitmap over it; a scenario's base
/// order is the concatenation of its sources, each a FILTERED SUBSEQUENCE of
/// this order (filtering an ordered set preserves order).
///
/// [ids] is the packed int32 node-id sequence (`media_nodes.id`, little-endian;
/// see `Int32BlobCodec`), [n] its length. [mediaRev] is the scoped media
/// revision the order was built against, so a stale order is rebuilt rather
/// than silently serving a pre-scan ordering.
class MediaOrdersTable extends Table {
  @override
  String get tableName => 'media_orders';

  /// Stable key: scope + sort + direction + grouping + media-type set
  /// (`SharedMediaOrder.orderKey`).
  TextColumn get orderKey => text()();

  /// Scoped media revision this order was built against.
  IntColumn get mediaRev => integer().withDefault(const Constant(0))();

  /// Number of ids in [ids].
  IntColumn get n => integer()();

  /// Packed int32 node ids, little-endian.
  BlobColumn get ids => blob()();

  /// Last time a builder read this order (epoch ms), for the cache GC.
  ///
  /// Nothing used to evict these rows: one key per (storage, field, direction,
  /// grouping, media-type set) grew to 16 × 4 B/item with no upper bound. The
  /// scenario builder keeps only the most recently used few per storage, so a
  /// library that keeps switching sorts cannot accumulate tens of MB per
  /// storage forever.
  IntColumn get lastUsedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {orderKey};
}
