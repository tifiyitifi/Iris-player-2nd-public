import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/db/dao/media_order_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_shared_index_dao.dart';
import 'package:iris/features/scenario_playback/resolver/bit_vector.dart';
import 'package:iris/features/scenario_playback/resolver/shared_index_codec.dart';
import 'package:iris/features/scenario_playback/resolver/shared_row_overlay.dart';
import 'package:iris/models/db/app_database.dart';

/// Measures the on-disk cost of the shared-order index for one whole-library
/// generation, using the SAME synthetic shape as
/// `scenario_queue_index_storage_probe_test.dart` so the two compare directly:
/// n files, a rule grouping them 10-to-a-group (so all n are absorbed).
///
///   `$env:IRIS_SCALE='200000'; flutter test test/shared_index_storage_probe_test.dart`
void main() {
  test('shared index storage breakdown', () async {
    final n = int.tryParse(Platform.environment['IRIS_SCALE'] ?? '') ?? 20000;
    final membersPer =
        int.tryParse(Platform.environment['IRIS_GROUP'] ?? '') ?? 10;
    final dir = Directory.systemTemp.createTempSync('iris_shared_probe');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = AppDatabase(NativeDatabase(File('${dir.path}/probe.sqlite')));
    addTearDown(db.close);

    const ruleId = '00000000-0000-4000-8000-000000000000';

    // Shared order: the whole library, one node id per file.
    final groups = n ~/ membersPer;
    final orders = MediaOrderDao(db);
    await orders.write('probe',
        mediaRev: 1, ids: Int32List.fromList([for (var i = 1; i <= n; i++) i]));

    // One source selecting the whole order; every rank accepted.
    final all = BitVectorBuilder(n)..setAll([for (var i = 0; i < n; i++) i]);
    final bits = all.build();
    // Every file folded into a group ⇒ every rank absorbed.
    final absorbed = (BitVectorBuilder(n)
          ..setAll([for (var i = 0; i < n; i++) i]))
        .build();
    final groupRows = [
      for (var g = 0; g < groups; g++)
        SharedGroupRow(
          anchorRank: g * membersPer,
          ruleId: ruleId,
          rootPath: '/some/path',
          chunkNo: g + 1,
          members: Int32List.fromList([
            for (var m = 0; m < membersPer; m++) g * membersPer + m + 1,
          ]),
        ),
    ];

    final shared = ScenarioSharedIndexDao(db);
    await shared.write(
      1,
      baseCount: n,
      slices: SharedIndexCodec.encodeSlices(SingleBaseOrder(
          [(orderKey: 'probe', mediaRev: 1, bits: bits)])),
      accepted: SharedIndexCodec.encodeBitmap(bits),
      absorbed: SharedIndexCodec.encodeBitmap(absorbed),
      groupRows: SharedIndexCodec.encodeGroups(groupRows),
      placeholders: SharedIndexCodec.encodePlaceholders(const {}),
      occurrence: SharedIndexCodec.encodeIntMap(const {}),
      flags: SharedIndexCodec.encodeIntMap(const {}),
    );
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');

    final objects = await _objects(db);
    final total = await _dbBytes(db);
    final orderBytes = objects['media_orders'] ?? 0;
    final sharedBytes = objects['scenario_shared_index'] ?? 0;

    // The v43 equivalent of this shape: one group row per group (carrying the
    // ~50-char scopeKey) + one member row per file (74 B/member measured).
    final v43GroupRowBytes = groups * 50;
    final v43MemberBytes = n * 74;

    // ignore: avoid_print
    print('IRIS_SCALE=$n IRIS_GROUP=$membersPer '
        'shared_total=${_mb(total)}MB (${(total / n).toStringAsFixed(1)}B/file) '
        'media_orders=${_mb(orderBytes)} '
        'shared_index=${_mb(sharedBytes)} '
        '(${(sharedBytes / n).toStringAsFixed(1)}B/file/scenario) '
        '| v43_equiv≈${_mb(v43GroupRowBytes + v43MemberBytes)}MB '
        '(groups ${_mb(v43GroupRowBytes)} + members ${_mb(v43MemberBytes)})');

    expect(total, greaterThan(0));
    expect(await shared.count(), 1);
  });
}

Future<Map<String, int>> _objects(AppDatabase db) async {
  final out = <String, int>{};
  try {
    final stat = await db
        .customSelect('SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name')
        .get();
    for (final r in stat) {
      out[r.read<String>('name')] = r.read<int>('bytes');
    }
  } catch (_) {
    // dbstat unavailable in this SQLite build; totals are still reported.
  }
  return out;
}

Future<int> _dbBytes(AppDatabase db) async {
  final page = await db.customSelect('PRAGMA page_count').getSingle();
  final size = await db.customSelect('PRAGMA page_size').getSingle();
  return (page.data.values.first as int) * (size.data.values.first as int);
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(2);
