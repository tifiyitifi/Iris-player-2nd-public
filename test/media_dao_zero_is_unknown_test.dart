import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_query.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

/// `size_in_bytes` / `duration_ms` == 0 is "unknown", not "smallest".
///
/// The listing lanes that cannot stat a file (SAF, WebDAV, FTP) report 0, so
/// ranking 0 as a real value piled exactly the unprobed files at the head of an
/// ascending queue (and the tail of a descending one) — the user-visible
/// "size sort is wrong" bug. Unknown must land last in BOTH directions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
  });

  tearDownAll(() => db.close());

  Future<void> seed() async {
    final spec = <String, ({int? size, int? duration})>{
      's050.mkv': (size: 50, duration: 500),
      's100.mkv': (size: 100, duration: 1000),
      'z000.mkv': (size: 0, duration: 0),
      'znull.mkv': (size: null, duration: null),
    };
    // Upsert keeps the fixture idempotent across tests sharing this database.
    await DbModule.mediaNodesDao.batchUpsert([
      for (final entry in spec.entries)
        MediaNode.file(
          id: 'z:${entry.key}',
          storageId: 'z',
          path: [entry.key],
          name: entry.key,
          mediaType: MediaType.video,
          sizeInBytes: entry.value.size,
          durationMs: entry.value.duration,
        ).toCompanion(),
    ]);
    // The adapter now maps 0 to "absent", so write the literal 0 through raw SQL:
    // these are the LEGACY rows this fix has to rank as unknown.
    await db.customStatement(
      'UPDATE media_nodes SET size_in_bytes = 0, duration_ms = 0 '
      'WHERE storage_id = ? AND path = ?',
      ['z', 'z000.mkv'],
    );
  }

  Future<List<String>> orderBy(
    MediaSortField field,
    SortDirection direction,
  ) async {
    final result = await DbModule.mediaNodesDao.getPagedNodes(
      MediaNodePageQuery(
        page: 1,
        pageSize: 50,
        storageId: 'z',
        nodeKind: MediaNodeKind.file,
        matchAllInStorage: true,
        mediaTypes: const [MediaType.video],
        sortField: field,
        sortDirection: direction,
      ),
    );
    return [for (final n in result.items) n.name];
  }

  for (final field in [MediaSortField.sizeInBytes, MediaSortField.durationMs]) {
    test('$field: 0 and NULL are the same "unknown" bucket, last both ways',
        () async {
      await seed();

      // Known values follow the direction. The unknown bucket stays after them
      // and is then ordered by the RAW column value (SQLite NULLs-first, so the
      // direction still applies inside the bucket) followed by the ascending
      // name tail. This is exactly what the resolver's comparator must mirror:
      // a stream is only mergeable while it is non-decreasing under it.
      expect(
        await orderBy(field, SortDirection.asc),
        ['s050.mkv', 's100.mkv', 'znull.mkv', 'z000.mkv'],
      );
      expect(
        await orderBy(field, SortDirection.desc),
        ['s100.mkv', 's050.mkv', 'z000.mkv', 'znull.mkv'],
      );
    });
  }
}
