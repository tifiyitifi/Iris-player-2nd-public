import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/db/dao/media_order_dao.dart';
import 'package:iris/features/scenario_playback/resolver/shared_media_order.dart';
import 'package:iris/models/db/app_database.dart';

/// `media_orders` is a rebuildable cache with no upper bound: one key per
/// (storage, field, direction, grouping, media-type set) at 4 B/item. These
/// cover the eviction contract that keeps it from growing to ~32 MB/storage.
void main() {
  late AppDatabase db;
  late MediaOrderDao dao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = MediaOrderDao(db);
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() => db.close());

  String key(String storage, String field) =>
      '${SharedMediaOrder.scopePrefix(storage)}$field|asc|f|video,audio';

  Future<void> setLastUsed(String orderKey, int ms) async {
    await db.customStatement(
      'UPDATE media_orders SET last_used_at = ? WHERE order_key = ?',
      [ms, orderKey],
    );
  }

  Future<int> lastUsed(String orderKey) async {
    final row = await db.customSelect(
      'SELECT last_used_at FROM media_orders WHERE order_key = ?',
      variables: [Variable.withString(orderKey)],
    ).getSingle();
    return row.read<int>('last_used_at');
  }

  test('a stale revision is a miss, and READING does not delete the row',
      () async {
    await dao.write(key('st', 'sizeInBytes'), mediaRev: 1, ids: Int32List(0));

    expect(await dao.read(key('st', 'sizeInBytes'), mediaRev: 2), isNull,
        reason: 'a stale order must never be served');
    expect(await dao.count(), 1,
        reason: 'eviction is GC (pruneStale at build time), never a read: a '
            'persisted index built against an older revision asks for its own '
            'rev, and deleting here would drop the CURRENT order that another '
            'live scenario resolves');
  });

  test('a stale-rev read leaves the CURRENT order usable', () async {
    final k = key('st', 'sizeInBytes');
    await dao.write(k, mediaRev: 2, ids: Int32List(0));

    // A persisted blob still carries revision 1 and keeps asking for it.
    expect(await dao.read(k, mediaRev: 1), isNull);
    expect(await dao.read(k, mediaRev: 2), isNotNull,
        reason: 'the stale read must not evict the order the current revision '
            'resolves to');
  });

  test('pruneStale is the rev-based GC that drops what read refuses', () async {
    final k = key('st', 'sizeInBytes');
    await dao.write(k, mediaRev: 1, ids: Int32List(0));

    expect(await dao.read(k, mediaRev: 2), isNull);
    expect(await dao.pruneStale(
            keyPrefix: SharedMediaOrder.scopePrefix('st'), currentRev: 2),
        1);
    expect(await dao.count(), 0);
  });

  test('a hit refreshes last_used_at', () async {
    final k = key('st', 'sizeInBytes');
    await dao.write(k, mediaRev: 1, ids: Int32List(0));
    await setLastUsed(k, 1);

    await dao.read(k, mediaRev: 1);

    expect(await lastUsed(k), greaterThan(1));
  });

  test('pruneStale keeps the current revision only', () async {
    final prefix = SharedMediaOrder.scopePrefix('st');
    await dao.write(key('st', 'sizeInBytes'), mediaRev: 7, ids: Int32List(0));
    await dao.write(key('st', 'durationMs'), mediaRev: 6, ids: Int32List(0));
    await dao.write(key('other', 'sizeInBytes'), mediaRev: 6, ids: Int32List(0));

    final removed = await dao.pruneStale(keyPrefix: prefix, currentRev: 7);

    expect(removed, 1);
    expect(await dao.read(key('st', 'sizeInBytes'), mediaRev: 7), isNotNull);
    expect(await dao.count(), 2,
        reason: 'the other storage must not be pruned');
  });

  test('pruneToRecent keeps the most recently used keys of one storage',
      () async {
    final prefix = SharedMediaOrder.scopePrefix('st');
    final keys = [
      for (final f in ['name', 'sizeInBytes', 'durationMs', 'modifiedAt'])
        key('st', f),
    ];
    for (var i = 0; i < keys.length; i++) {
      await dao.write(keys[i], mediaRev: 1, ids: Int32List(0));
      await setLastUsed(keys[i], i + 1);
    }
    final other = key('other', 'sizeInBytes');
    await dao.write(other, mediaRev: 1, ids: Int32List(0));
    await setLastUsed(other, 1);

    final removed = await dao.pruneToRecent(keyPrefix: prefix, keep: 2);

    expect(removed, 2);
    // The two youngest survive, the two oldest go, the other storage is intact.
    expect(await dao.read(keys[2], mediaRev: 1), isNotNull);
    expect(await dao.read(keys[3], mediaRev: 1), isNotNull);
    expect(await dao.count(), 3);
  });

  test('the LRU bound never leaves the scope empty', () async {
    final prefix = SharedMediaOrder.scopePrefix('st');
    await dao.write(key('st', 'name'), mediaRev: 1, ids: Int32List(0));

    expect(await dao.pruneToRecent(keyPrefix: prefix, keep: 0), 0);
    expect(await dao.count(), 1);
  });

  test('the DEFAULT bound never evicts the realistic live key set', () async {
    final prefix = SharedMediaOrder.scopePrefix('st');
    // 4 fields x 2 directions: the bounded axes of `SharedMediaOrder.orderKey`.
    // Every one of them can belong to a DIFFERENT live scenario on this storage.
    final keys = [
      for (final f in ['name', 'sizeInBytes', 'durationMs', 'modifiedAt'])
        for (final d in ['asc', 'desc']) '$prefix$f|$d|f|video,audio',
    ];
    for (var i = 0; i < keys.length; i++) {
      await dao.write(keys[i], mediaRev: 1, ids: Int32List(0));
      await setLastUsed(keys[i], i + 1);
    }

    final removed = await dao.pruneToRecent(keyPrefix: prefix);

    expect(removed, 0,
        reason: 'evicting a current-revision order makes the scenario that owns '
            'it fall back to the legacy walk for the whole session (the read '
            'side never rebuilds), so the cap must cover the bounded key space');
    expect(await dao.count(), keys.length);
  });
}
