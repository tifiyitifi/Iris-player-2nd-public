import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_query.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';import 'package:iris/features/scenario_playback/resolver/scenario_order_comparator.dart';
import 'package:iris/models/db/app_database.dart';

/// The queue's global order is only representable while the comparator agrees
/// with `MediaNodesDao`'s ORDER BY column for column — each storage's shared
/// order was built with that ORDER BY, so a disagreement makes the merge
/// non-monotonic (and the encoder refuses it).
///
/// This is the parity harness that keeps the two in lockstep: same rows, same
/// field, same direction, same grouping → identical sequences.
void main() {
  late AppDatabase db;
  late MediaNodesDao dao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = MediaNodesDao(db);

    DateTime day(int d) =>
        DateTime.fromMillisecondsSinceEpoch(DateTime.utc(2024, 1, d).millisecondsSinceEpoch);

    Future<void> add({
      required String path,
      required String name,
      required String? parent,
      int? size,
      int? duration,
      int? mtimeDay,
    }) async {
      await dao.insertNode(MediaNode.file(
        id: path,
        storageId: 'p',
        path: path.split('/'),
        parentPath: parent,
        name: name,
        normalizedName: name.toLowerCase(),
        mediaType: MediaType.video,
        sizeInBytes: size,
        durationMs: duration,
        modifiedAt: mtimeDay == null ? null : day(mtimeDay),
      ));
    }

    // Same normalized name in several directories, case variants, and every
    // unknown spelling (NULL and literal 0 for size/duration).
    await add(path: 'dir1/a.mkv', name: 'a.mkv', parent: 'dir1', size: 100, duration: 1000, mtimeDay: 2);
    await add(path: 'dir1/A.MKV', name: 'A.MKV', parent: 'dir1', size: null, duration: 0, mtimeDay: null);
    await add(path: 'dir1/b.mkv', name: 'B.mkv', parent: 'dir1', size: 100, duration: 1000, mtimeDay: 2);
    await add(path: 'dir2/a.mkv', name: 'a.mkv', parent: 'dir2', size: 100, duration: 1000, mtimeDay: 2);
    await add(path: 'dir2/c.mkv', name: 'c.mkv', parent: 'dir2', size: null, duration: null, mtimeDay: null);
    await add(path: 'dir3/d.mkv', name: 'd.mkv', parent: 'dir3', size: 50, duration: 2000, mtimeDay: 1);
    await add(path: 'z.mkv', name: 'z.mkv', parent: null, size: null, duration: null, mtimeDay: null);

    // A legacy root row: pre-fix scans stored the root parent as `''` while the
    // canonical form is NULL, and SQL groups the two SEPARATELY. The comparator
    // used to fold both to `''` and merge the groups, so a legacy root row could
    // sit in the wrong group relative to the paged order.
    await add(path: 'legacy.mkv', name: 'legacy.mkv', parent: null, size: 100, duration: 1000, mtimeDay: 2);
    await db.customStatement(
        "UPDATE media_nodes SET parent_path = '' "
        "WHERE storage_id = 'p' AND path = 'legacy.mkv'");

    // The adapter maps 0 to "unknown" on the way in; own the literal value the
    // way pre-fix rows carry it.
    await db.customStatement(
        "UPDATE media_nodes SET size_in_bytes = 0, duration_ms = 0 "
        "WHERE storage_id = 'p' AND path = 'dir2/c.mkv'");
  });

  tearDown(() => db.close());

  Future<List<String>> daoOrder({
    required ScenarioSortField field,
    required SortDirection direction,
    required bool grouped,
  }) async {
    final result = await dao.getPagedNodes(MediaNodePageQuery(
      page: 1,
      pageSize: 100,
      storageId: 'p',
      nodeKind: MediaNodeKind.file,
      matchAllInStorage: true,
      mediaTypes: const [MediaType.video],
      sortField: field.toMediaSortField(),
      sortDirection: direction,
      pathGroupFirst: grouped,
    ));
    return [for (final n in result.items) n.path.join('/')];
  }

  for (final field in ScenarioSortField.values) {
    for (final direction in SortDirection.values) {
      for (final grouped in [false, true]) {
        test('$field ${direction.name} grouped=$grouped matches the DAO',
            () async {
          final expected =
              await daoOrder(field: field, direction: direction, grouped: grouped);
          final nodes = await dao.getPagedNodes(MediaNodePageQuery(
            page: 1,
            pageSize: 100,
            storageId: 'p',
            nodeKind: MediaNodeKind.file,
            matchAllInStorage: true,
            mediaTypes: const [MediaType.video],
            sortField: field.toMediaSortField(),
            sortDirection: direction,
            pathGroupFirst: grouped,
          ));
          final comparator = ScenarioOrderComparator(
            field: field,
            direction: direction,
            grouped: grouped,
          );
          // Sort from a deliberately scrambled start, so the comparator — not
          // the incoming order — has to produce the sequence.
          final sorted = [...nodes.items.reversed]
            ..sort((a, b) => comparator.compare(a, b));
          expect([for (final n in sorted) n.path.join('/')], expected);
        });
      }
    }
  }

  test('cross-storage ties fall back to storageId, then occurrence path', () {
    MediaNode node(String storageId, String path) => MediaNode.file(
          id: '$storageId:$path',
          storageId: storageId,
          path: path.split('/'),
          name: 'x.mkv',
          normalizedName: 'x.mkv',
          mediaType: MediaType.video,
          sizeInBytes: 10,
        );
    final comparator = const ScenarioOrderComparator(
      field: ScenarioSortField.sizeInBytes,
      direction: SortDirection.asc,
      grouped: false,
    );
    final list = [node('z', 'x.mkv'), node('a', 'x.mkv')]
      ..sort(comparator.compare);
    expect([for (final n in list) n.storageId], ['a', 'z']);
  });

  /// The 7-row fixture above cannot expose a page-window bug: with fewer rows
  /// than one page, a comparator/ORDER BY mismatch still produces a plausible
  /// list. These sweep a >page-size dataset (the natural-order key bugs only
  /// show up past the first page) and assert the page seams as well.
  group('page-window parity (1000+ rows)', () {
    const total = 1200;
    const pageSize = 100;

    setUp(() async {
      // Names chosen so lexicographic and natural order disagree loudly, plus
      // leading zeros, CJK, case twins and duplicate basenames across dirs.
      for (var i = 0; i < total; i++) {
        final dir = 'd${i % 37}';
        final n = i + 1;
        final String name;
        switch (i % 5) {
          case 0:
            name = 'ep$n.mkv';
          case 1:
            name = 'EP${n.toString().padLeft(4, '0')}.mkv';
          case 2:
            name = '进击的巨人 第$n集.mkv';
          case 3:
            name = 'clip$n.mkv';
          default:
            // duplicate basenames in different folders → the path tail decides
            name = 'same${n % 40}.mkv';
        }
        await dao.insertNode(MediaNode.file(
          id: '$dir/$name',
          storageId: 'p',
          path: '$dir/$name'.split('/'),
          parentPath: dir,
          name: name,
          normalizedName: name.toLowerCase(),
          mediaType: MediaType.video,
          sizeInBytes: 100 + (i % 7),
          durationMs: 1000 * (i % 3),
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000 + i),
        ));
      }
    });

    Future<List<String>> pages({
      required ScenarioSortField field,
      required SortDirection direction,
      required bool grouped,
    }) async {
      final out = <String>[];
      final pages = (total / pageSize).ceil();
      for (var page = 1; page <= pages; page++) {
        final result = await dao.getPagedNodes(MediaNodePageQuery(
          page: page,
          pageSize: pageSize,
          storageId: 'p',
          nodeKind: MediaNodeKind.file,
          matchAllInStorage: true,
          mediaTypes: const [MediaType.video],
          sortField: field.toMediaSortField(),
          sortDirection: direction,
          pathGroupFirst: grouped,
        ));
        out.addAll([for (final n in result.items) n.path.join('/')]);
      }
      return out;
    }

    for (final direction in SortDirection.values) {
      for (final grouped in [false, true]) {
        test('name ${direction.name} grouped=$grouped: walk == paged DB order',
            () async {
          final paged = await pages(
            field: ScenarioSortField.name,
            direction: direction,
            grouped: grouped,
          );
          expect(paged.length, total);

          // The comparator must reproduce the SAME sequence, starting from a
          // scrambled list — otherwise the queue index merge is non-monotonic.
          final all = await dao.getPagedNodes(MediaNodePageQuery(
            page: 1,
            pageSize: total,
            storageId: 'p',
            nodeKind: MediaNodeKind.file,
            matchAllInStorage: true,
            mediaTypes: const [MediaType.video],
            sortField: MediaSortField.name,
            sortDirection: direction,
            pathGroupFirst: grouped,
          ));
          final comparator = ScenarioOrderComparator(
            field: ScenarioSortField.name,
            direction: direction,
            grouped: grouped,
          );
          final sorted = [...all.items.reversed]
            ..sort((a, b) => comparator.compare(a, b));
          expect([for (final n in sorted) n.path.join('/')], paged);

          // No duplicated or dropped row across page boundaries.
          expect(paged.toSet().length, total);
          for (var page = 1; page < (total / pageSize).ceil(); page++) {
            final head = paged[page * pageSize];
            final tail = paged[page * pageSize - 1];
            final c = comparator.compare(
              sorted[page * pageSize - 1],
              sorted[page * pageSize],
            );
            expect(c, lessThan(0), reason: 'seam $page: "$tail" vs "$head"');
          }
        });
      }
    }
  });
}
