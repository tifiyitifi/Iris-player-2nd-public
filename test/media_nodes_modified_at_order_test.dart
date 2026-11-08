import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_query.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/app_database.dart';

/// The scenario queue's "sort by modified date" is only as good as the DAO's
/// ORDER BY: the sort column must be a TOTAL order (deterministic tail), NULL
/// timestamps must land last in both directions, and the timestamp must keep
/// sub-second precision.
void main() {
  late AppDatabase db;
  late MediaNodesDao dao;
  late MediaNodeRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = MediaNodesDao(db);
    repo = MediaNodeRepository(dao);
  });

  tearDown(() => db.close());

  /// Epoch-based, so the expected order does not depend on the local timezone.
  DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

  Future<void> seed(String path,
      {DateTime? modifiedAt, int? width, int? height}) async {
    final segments = path.split('/');
    await dao.insertNode(MediaNode.file(
      id: 'st1:$path',
      storageId: 'st1',
      path: segments,
      name: segments.last,
      mediaType: MediaType.video,
      modifiedAt: modifiedAt,
      width: width,
      height: height,
    ));
  }

  const sources = <SourcesQuerySource>[
    (
      storageId: 'st1',
      path: null,
      kind: MediaSourceKind.storage,
      recursive: true,
      scenarioSourceId: null,
    ),
  ];

  Future<List<String>> paged({
    required MediaSortField sortField,
    required SortDirection sortDirection,
    bool pathGroupFirst = false,
  }) async {
    final result = await repo.getPagedNodes(MediaNodePageQuery(
      page: 1,
      pageSize: 100,
      storageId: 'st1',
      nodeKind: MediaNodeKind.file,
      mediaTypes: const [MediaType.video],
      matchAllInStorage: true,
      sortField: sortField,
      sortDirection: sortDirection,
      pathGroupFirst: pathGroupFirst,
    ));
    return result.items.map((e) => e.name).toList();
  }

  Future<List<String>> pagedForSources({
    required MediaSortField sortField,
    required SortDirection sortDirection,
  }) async {
    final result = await repo.getPagedNodesForSources(
      sources: sources,
      nodeKind: MediaNodeKind.file,
      mediaTypes: const [MediaType.video],
      sortField: sortField,
      sortDirection: sortDirection,
      page: 1,
      pageSize: 100,
    );
    return result.items.map((e) => e.name).toList();
  }

  group('modified_at: NULLs last + deterministic tail', () {
    setUp(() async {
      // t0 is shared by a.mp4 and z.mp4 → the tail must decide between them.
      // m.mp4 was never probed → NULL, which must sort last either way.
      await seed('A/z.mp4', modifiedAt: at(1000));
      await seed('A/a.mp4', modifiedAt: at(1000));
      await seed('A/b.mp4', modifiedAt: at(6000));
      await seed('A/m.mp4');
    });

    test('getPagedNodes asc: ties by name, NULLs last', () async {
      expect(
        await paged(
            sortField: MediaSortField.modifiedAt,
            sortDirection: SortDirection.asc),
        ['a.mp4', 'z.mp4', 'b.mp4', 'm.mp4'],
      );
    });

    test('getPagedNodes desc: NULLs still last', () async {
      expect(
        await paged(
            sortField: MediaSortField.modifiedAt,
            sortDirection: SortDirection.desc),
        ['b.mp4', 'a.mp4', 'z.mp4', 'm.mp4'],
      );
    });

    test('getPagedNodesForSources asc/desc: NULLs last on this path too',
        () async {
      expect(
        await pagedForSources(
            sortField: MediaSortField.modifiedAt,
            sortDirection: SortDirection.asc),
        ['a.mp4', 'z.mp4', 'b.mp4', 'm.mp4'],
      );
      expect(
        await pagedForSources(
            sortField: MediaSortField.modifiedAt,
            sortDirection: SortDirection.desc),
        ['b.mp4', 'a.mp4', 'z.mp4', 'm.mp4'],
      );
    });
  });

  group('pathGroupFirst (同目录连续)', () {
    setUp(() async {
      // Same timestamp everywhere: only the grouping/tail can decide the order.
      await seed('root.mp4', modifiedAt: at(1000));
      await seed('A/b.mp4', modifiedAt: at(1000));
      await seed('A/a.mp4', modifiedAt: at(1000));
      await seed('B/z.mp4', modifiedAt: at(1000));
      await seed('B/y.mp4', modifiedAt: at(1000));
    });

    test('on: directory blocks (root, A, B) with a name tail inside each',
        () async {
      expect(
        await paged(
          sortField: MediaSortField.modifiedAt,
          sortDirection: SortDirection.asc,
          pathGroupFirst: true,
        ),
        ['root.mp4', 'a.mp4', 'b.mp4', 'y.mp4', 'z.mp4'],
      );
    });

    test('off (the default): one flat order, no directory blocks', () async {
      expect(
        await paged(
          sortField: MediaSortField.modifiedAt,
          sortDirection: SortDirection.asc,
        ),
        ['a.mp4', 'b.mp4', 'root.mp4', 'y.mp4', 'z.mp4'],
      );
    });
  });

  group('millisecond precision', () {
    setUp(() async {
      // 400ms apart, with names in the OPPOSITE order: a seconds-truncated
      // column would tie them and fall back to the name tail (aaa, zzz).
      await seed('A/zzz.mp4', modifiedAt: at(1000));
      await seed('A/aaa.mp4', modifiedAt: at(1400));
    });

    test('sub-second mtimes keep their real order (not a name fallback)',
        () async {
      expect(
        await paged(
            sortField: MediaSortField.modifiedAt,
            sortDirection: SortDirection.asc),
        ['zzz.mp4', 'aaa.mp4'],
      );
      expect(
        await paged(
            sortField: MediaSortField.modifiedAt,
            sortDirection: SortDirection.desc),
        ['aaa.mp4', 'zzz.mp4'],
      );
    });

    test('the instant survives an insert/read round trip', () async {
      final node = await repo
          .getNodeByPath(storageId: 'st1', path: const ['A', 'aaa.mp4']);
      expect(node!.modifiedAt!.millisecondsSinceEpoch, 1400);
    });
  });

  group('resolution (pixelCount) order is not a silent name fallback', () {
    setUp(() async {
      // Resolutions in the OPPOSITE order to the names: a path that forgets the
      // pixelCount sort column falls back to `natural_name` and returns
      // a.mp4, m.mp4, z.mp4 instead of the resolution order.
      await seed('A/z.mp4', width: 1280, height: 720); // 921 600
      await seed('A/a.mp4', width: 3840, height: 2160); // 8 294 400
      await seed('A/m.mp4'); // never probed → NULL, sorts last
    });

    test('getPagedNodes desc: biggest first, unknown last', () async {
      expect(
        await paged(
            sortField: MediaSortField.pixelCount,
            sortDirection: SortDirection.desc),
        ['a.mp4', 'z.mp4', 'm.mp4'],
      );
    });

    test('getPagedNodesForSources agrees with the reference path', () async {
      expect(
        await pagedForSources(
            sortField: MediaSortField.pixelCount,
            sortDirection: SortDirection.desc),
        ['a.mp4', 'z.mp4', 'm.mp4'],
      );
    });
  });
}
