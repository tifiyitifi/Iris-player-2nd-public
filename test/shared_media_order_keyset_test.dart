import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_query.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/resolver/shared_media_order.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/natural_sort_key.dart';

import 'helpers/sqlite3_loader.dart';

typedef _Row = ({int id, String? parent, String key, String path});

/// `SharedMediaOrder.build` walks the name order with a KEYSET cursor, while the
/// DAO pages it with `ORDER BY ... LIMIT/OFFSET`. The two must agree row for
/// row — a mismatch is not a wrong-looking list but duplicated/dropped rows
/// across the page seams, and the queue index refuses (or silently mis-ranks) a
/// non-monotonic base order.
///
/// The grouped (同目录连续) cursor is the delicate one: SQlite sorts a NULL
/// `parent_path` FIRST on ASC and LAST on DESC, so the predicate has to spell
/// the NULL group out. Root-level files (parent_path NULL, and the legacy `''`
/// spelling) are therefore in the fixture on purpose.
void main() {
  ensureSqlite3Loaded();

  late AppDatabase db;
  late MediaNodesDao dao;
  late MediaNodeRepository repo;

  // 400 library rows: > 10 keyset pages with chunk=37, and the last page is
  // partial (400 % 37 != 0), which is where a cursor bug shows up.
  const libraryRows = 400;
  const chunk = 37;

  /// Root-level files with a NULL parent_path — larger than one page, so the
  /// walk must cross the NULL-group boundary (see the setUp comment).
  const rootRows = 40;

  /// Root-level files still stored under the legacy `''` parent.
  const legacyRows = 6;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = MediaNodesDao(db);
    repo = MediaNodeRepository(dao);

    String nameFor(int i) {
      // Mixes the cases that lexicographic and natural order disagree on.
      switch (i % 6) {
        case 0:
          return 'ep$i.mkv';
        case 1:
          return 'EP${i.toString().padLeft(4, '0')}.mkv';
        case 2:
          return '进击的巨人 第$i集.mkv';
        case 3:
          return 'clip$i.mkv';
        case 4:
          return 'same${i % 11}.mkv'; // duplicate basenames in several folders
        default:
          return '007_$i.mkv';
      }
    }

    for (var i = 0; i < libraryRows; i++) {
      final name = nameFor(i);
      final dir = 'd${i % 7}';
      await dao.insertNode(MediaNode.file(
        id: '$dir/$name',
        storageId: 'p',
        path: '$dir/$name'.split('/'),
        parentPath: dir,
        name: name,
        normalizedName: name.toLowerCase(),
        mediaType: MediaType.video,
        sizeInBytes: 100 + i,
      ));
    }

    // Root-level files through the adapter: parent_path NULL (canonical).
    // MORE than one keyset page on purpose: the walk then has to cross the
    // NULL group boundary, which is exactly where a `parent_path > ?` cursor
    // silently drops rows (the bench dataset never had a root-level file).
    for (var i = 0; i < rootRows; i++) {
      final name = 'root$i.mkv';
      await dao.insertNode(MediaNode.file(
        id: name,
        storageId: 'p',
        path: [name],
        name: name,
        normalizedName: name.toLowerCase(),
        mediaType: MediaType.video,
        sizeInBytes: 10,
      ));
    }

    // Root-level files in the LEGACY `''` spelling (rows written before the
    // scanner normalization fix). They sort after the NULL group on ASC.
    for (var i = 0; i < legacyRows; i++) {
      final name = 'legacy$i.mkv';
      await db.customStatement(
        'INSERT INTO media_nodes (storage_id, data_scope_id, path, '
        'parent_path, path_depth, name, normalized_name, natural_name, '
        'node_kind, media_type, is_present) '
        "VALUES ('p', 'p', ?, '', 1, ?, ?, ?, 'file', 'video', 1)",
        [name, name, name.toLowerCase(), naturalSortKey(name)],
      );
    }
  });

  tearDown(() => db.close());

  Future<List<_Row>> allRows() async {
    final rows = await db.customSelect(
      'SELECT id, parent_path, natural_name, path FROM media_nodes '
      "WHERE data_scope_id = 'p' AND node_kind = 'file' "
      'AND media_type = ? ORDER BY id',
      variables: [Variable.withString(MediaType.video.name)],
    ).get();
    return [
      for (final r in rows)
        (
          id: r.read<int>('id'),
          parent: r.read<String?>('parent_path'),
          key: r.read<String>('natural_name'),
          path: r.read<String>('path'),
        ),
    ];
  }

  /// SQLite semantics, spelled out: `parent_path` ASC puts NULL first (DESC
  /// puts it last), `path` stays ascending in both directions, and ties on the
  /// key fall through to the ASC path.
  int compare(_Row a, _Row b, {required bool grouped, required bool asc}) {
    if (grouped) {
      final byParent = _compareParent(a.parent, b.parent, asc);
      if (byParent != 0) return byParent;
    }
    final byKey = asc ? a.key.compareTo(b.key) : b.key.compareTo(a.key);
    if (byKey != 0) return byKey;
    return a.path.compareTo(b.path);
  }

  Future<List<int>> buildOrder({
    required bool grouped,
    required SortDirection direction,
  }) async {
    final order = await SharedMediaOrder.build(
      repo,
      storageId: 'p',
      sortField: ScenarioSortField.name,
      sortDirection: direction,
      pathGroupFirst: grouped,
      mediaTypes: const [MediaType.video],
      chunk: chunk,
    );
    return order.toList();
  }

  for (final direction in SortDirection.values) {
    for (final grouped in [false, true]) {
      test(
          'build() ${direction.name} grouped=$grouped == an independent sort '
          'of every row', () async {
        final rows = await allRows();
        expect(rows.length, libraryRows + rootRows + legacyRows);
        final expected = [...rows]
          ..sort((a, b) =>
              compare(a, b, grouped: grouped, asc: direction == SortDirection.asc));

        final actual = await buildOrder(grouped: grouped, direction: direction);
        expect(
          actual,
          [for (final r in expected) r.id],
          reason: 'keyset walk and the ORDER BY must be the same sequence',
        );

        // A cursor bug shows up as a duplicate or a dropped row, not as a
        // differently-sorted list, so pin that explicitly.
        expect(actual.toSet().length, actual.length, reason: 'duplicate page');
        expect(actual.toSet().length, rows.length, reason: 'dropped row');
      });
    }
  }

  test('grouped order keeps the root level (NULL and legacy empty parent)',
      () async {
    final rows = await allRows();
    String? parentOf(int id) => rows.firstWhere((r) => r.id == id).parent;
    final rootIds = [
      for (final r in rows)
        if (r.parent == null || r.parent!.isEmpty) r.id,
    ];
    expect(rootIds.length, rootRows + legacyRows);

    for (final grouped in [false, true]) {
      final asc = await buildOrder(grouped: grouped, direction: SortDirection.asc);
      expect(asc.toSet(), containsAll(rootIds),
          reason: 'grouped=$grouped lost a root-level file on ASC');
      if (grouped) {
        // ASC: the whole NULL group first, then the legacy '' group, before
        // every real directory.
        expect(
          [for (final id in asc.take(rootRows)) parentOf(id)],
          everyElement(isNull),
          reason: 'the NULL group must lead on ASC',
        );
        expect(
          [for (final id in asc.skip(rootRows).take(legacyRows)) parentOf(id)],
          everyElement(''),
          reason: "the legacy '' group follows the NULL group on ASC",
        );
        expect(parentOf(asc[rootRows + legacyRows]), isNot(anyOf(isNull, '')));
      }

      final desc =
          await buildOrder(grouped: grouped, direction: SortDirection.desc);
      expect(desc.toSet(), containsAll(rootIds),
          reason: 'grouped=$grouped lost a root-level file on DESC');
      if (grouped) {
        // DESC: the '' group, then the NULL group, close the sequence.
        final tailStart = desc.length - rootRows - legacyRows;
        expect(
          [for (final id in desc.skip(tailStart).take(legacyRows)) parentOf(id)],
          everyElement(''),
          reason: "the legacy '' group leads the tail on DESC",
        );
        expect(
          [for (final id in desc.skip(tailStart + legacyRows)) parentOf(id)],
          everyElement(isNull),
          reason: 'the NULL group must trail on DESC',
        );
      }
    }
  });

  test('the DAO offset paging agrees with the same independent order',
      () async {
    // Guards the OTHER half of the contract: build() is only allowed to use a
    // keyset because this ORDER BY is what the DAO pages.
    for (final direction in SortDirection.values) {
      for (final grouped in [false, true]) {
        final rows = await allRows();
        final expected = [...rows]
          ..sort((a, b) =>
              compare(a, b, grouped: grouped, asc: direction == SortDirection.asc));

        final paged = <int>[];
        for (var page = 1; page <= (rows.length / chunk).ceil(); page++) {
          final result = await dao.getPagedNodes(MediaNodePageQuery(
            page: page,
            pageSize: chunk,
            storageId: 'p',
            nodeKind: MediaNodeKind.file,
            mediaTypes: const [MediaType.video],
            matchAllInStorage: true,
            sortField: MediaSortField.name,
            sortDirection: direction,
            pathGroupFirst: grouped,
            countTotal: false,
          ));
          paged.addAll([for (final n in result.items) int.parse(n.id)]);
        }
        expect(paged, [for (final r in expected) r.id],
            reason: 'DAO paging ${direction.name} grouped=$grouped');
      }
    }
  });
}

int _compareParent(String? a, String? b, bool asc) {
  if (a == b) return 0;
  if (a == null) return asc ? -1 : 1;
  if (b == null) return asc ? 1 : -1;
  final c = a.compareTo(b);
  return asc ? c : -c;
}
