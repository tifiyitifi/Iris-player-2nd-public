import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/db/dao/media_order_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_shared_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/enum/duplicate_policy.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_source_provider.dart';
import 'package:iris/features/scenario_playback/resolver/shared_index_codec.dart';
import 'package:iris/models/db/app_database.dart';

/// The queue's order is GLOBAL: one comparator over every source, every storage
/// and every explicit item — not "source 1's order, then source 2's".
///
/// These pin the user-visible contract of the v2.0.11 sort fix:
///  - the persisted index and the legacy walk return the SAME sequence;
///  - that sequence is the whole queue sorted by the chosen field/direction;
///  - unknown size/duration (NULL and 0) sits LAST in both directions;
///  - a single source keeps the bitmap shape (the zero-regression case);
///  - duplicates from overlapping sources keep every occurrence, in order;
///  - 同目录连续 makes the WHOLE queue directory-contiguous.
void main() {
  group('global queue order', () {
    late AppDatabase db;
    late MediaNodesDao nodesDao;
    late ScenarioRepository repo;
    late ScenarioQueueIndexDao indexDao;
    late MediaOrderDao orderDao;
    late ScenarioSharedIndexDao sharedDao;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      nodesDao = MediaNodesDao(db);
      repo = ScenarioRepository(
        scenariosDao: ScenariosDao(db),
        sourcesDao: ScenarioSourcesDao(db),
        itemsDao: ScenarioExplicitItemsDao(db),
        excludesDao: ScenarioExcludesDao(db),
        statesDao: ScenarioStatesDao(db),
      );
      indexDao = ScenarioQueueIndexDao(db);
      orderDao = MediaOrderDao(db);
      sharedDao = ScenarioSharedIndexDao(db);
    });

    tearDown(() => db.close());

    Future<void> seedFile(
      String storageId,
      String path, {
      int? size,
      int? duration,
      int? mtimeDay,
    }) async {
      await nodesDao.insertNode(MediaNode.file(
        id: '$storageId:$path',
        storageId: storageId,
        path: path.split('/'),
        parentPath: path.split('/').length > 1
            ? path.split('/').sublist(0, path.split('/').length - 1).join('/')
            : null,
        name: path.split('/').last,
        normalizedName: path.split('/').last.toLowerCase(),
        mediaType: MediaType.video,
        sizeInBytes: size,
        durationMs: duration,
        modifiedAt: mtimeDay == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                DateTime.utc(2024, 1, mtimeDay).millisecondsSinceEpoch),
      ));
    }

    ScenarioResolver resolver() => ScenarioResolver(
          repo: repo,
          nodeRepo: MediaNodeRepository(nodesDao),
          scopedMediaTypes: () => null,
          providers: {
            ScenarioSourceKind.folder:
                FolderSourceProvider(scopedMediaTypes: () => null),
          },
          vmRulesProvider: () async => const [],
          queueIndexDao: indexDao,
          mediaOrderDao: orderDao,
          sharedIndexDao: sharedDao,
          mediaRevisionProvider: (_) async => 0,
        );

    Future<String> scenario({
      ScenarioSortField sortField = ScenarioSortField.name,
      SortDirection direction = SortDirection.asc,
      bool grouped = false,
      DuplicatePolicy duplicatePolicy = DuplicatePolicy.allowDuplicate,
    }) async {
      final created = await repo.createScenario(name: 'G');
      await repo.updateScenario(created.copyWith(
        sortField: sortField,
        sortDirection: direction,
        sourceInternalFirst: grouped,
        duplicatePolicy: duplicatePolicy,
      ));
      return created.id;
    }

    /// `storageId:path` of every row the view serves, in order.
    Future<List<String>> queue(
      String scenarioId, {
      required bool indexed,
      int pageSize = 100,
    }) async {
      final r = resolver();
      final page = indexed
          ? await r.resolvePageIndexed(
              scenarioId: scenarioId, page: 0, pageSize: pageSize)
          : await r.resolvePage(
              scenarioId: scenarioId, page: 0, pageSize: pageSize);
      return [
        for (final item in page.items)
          '${item.media.storageId}:${item.media.path.join('/')}',
      ];
    }

    Future<void> build(String scenarioId) =>
        resolver().buildQueueIndex(scenarioId);

    Future<void> twoStorages() async {
      await seedFile('st1', 'A/0001.mp4', size: 300, duration: 1000, mtimeDay: 1);
      await seedFile('st1', 'A/0002.mp4', size: 100, duration: 3000, mtimeDay: 3);
      await seedFile('st1', 'A/0003.mp4', size: 200, duration: 2000, mtimeDay: 2);
      await seedFile('st2', 'B/0001.mp4', size: 250, duration: 1500, mtimeDay: 4);
      await seedFile('st2', 'B/0002.mp4', size: 50, duration: 500, mtimeDay: 5);
    }

    Future<void> addTwoSources(String id) async {
      await repo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);
      await repo.addSource(
          scenarioId: id, storageId: 'st2', path: 'B', recursive: true);
    }

    const nameAsc = [
      'st1:A/0001.mp4',
      'st2:B/0001.mp4',
      'st1:A/0002.mp4',
      'st2:B/0002.mp4',
      'st1:A/0003.mp4',
    ];
    const sizeAsc = [
      'st2:B/0002.mp4',
      'st1:A/0002.mp4',
      'st1:A/0003.mp4',
      'st2:B/0001.mp4',
      'st1:A/0001.mp4',
    ];
    const durationAsc = [
      'st2:B/0002.mp4',
      'st1:A/0001.mp4',
      'st2:B/0001.mp4',
      'st1:A/0003.mp4',
      'st1:A/0002.mp4',
    ];
    const modifiedAsc = [
      'st1:A/0001.mp4',
      'st1:A/0003.mp4',
      'st1:A/0002.mp4',
      'st2:B/0001.mp4',
      'st2:B/0002.mp4',
    ];

    const nameDesc = [
      'st1:A/0003.mp4',
      // The ascending tail survives the direction flip: within the same name,
      // path (then storage) still decides, so this is NOT the reverse of asc.
      'st1:A/0002.mp4',
      'st2:B/0002.mp4',
      'st1:A/0001.mp4',
      'st2:B/0001.mp4',
    ];
    const sizeDesc = [
      'st1:A/0001.mp4',
      'st2:B/0001.mp4',
      'st1:A/0003.mp4',
      'st1:A/0002.mp4',
      'st2:B/0002.mp4',
    ];
    const durationDesc = [
      'st1:A/0002.mp4',
      'st1:A/0003.mp4',
      'st2:B/0001.mp4',
      'st1:A/0001.mp4',
      'st2:B/0002.mp4',
    ];
    const modifiedDesc = [
      'st2:B/0002.mp4',
      'st2:B/0001.mp4',
      'st1:A/0002.mp4',
      'st1:A/0003.mp4',
      'st1:A/0001.mp4',
    ];

    final expectations = <({
      ScenarioSortField field,
      List<String> asc,
      List<String> desc
    })>[
      (field: ScenarioSortField.name, asc: nameAsc, desc: nameDesc),
      (field: ScenarioSortField.sizeInBytes, asc: sizeAsc, desc: sizeDesc),
      (
        field: ScenarioSortField.durationMs,
        asc: durationAsc,
        desc: durationDesc
      ),
      (
        field: ScenarioSortField.modifiedAt,
        asc: modifiedAsc,
        desc: modifiedDesc
      ),
    ];

    for (final expectation in expectations) {
      for (final direction in SortDirection.values) {
        test('${expectation.field} ${direction.name}: two storages, '
            'indexed == walk == global order', () async {
          await twoStorages();
          final id = await scenario(
              sortField: expectation.field, direction: direction);
          await addTwoSources(id);
          await build(id);

          // Two storages must use the merged base order.
          final blobs =
              await sharedDao.read(await indexDao.currentBuildId(id));
          expect(SharedIndexCodec.decodeSlices(blobs!.slices),
              isA<MultiBaseOrder>());

          final expected = direction == SortDirection.asc
              ? expectation.asc
              : expectation.desc;
          expect(await queue(id, indexed: true), expected);
          expect(await queue(id, indexed: false), expected,
              reason: 'the fallback walk serves the same global order');
        });
      }
    }

    test('unknown size (NULL and 0) sorts last in BOTH directions', () async {
      await twoStorages();
      // NULL size on st1. The literal 0 must be written through raw SQL: the
      // adapter now maps a listing's 0 to "unknown" (absent), so the only way to
      // own such a row is the pre-fix data this test is about.
      await seedFile('st1', 'A/0004.mp4', duration: 9000, mtimeDay: 6);
      await seedFile('st2', 'B/0003.mp4', duration: 9000, mtimeDay: 7);
      await db.customStatement(
        'UPDATE media_nodes SET size_in_bytes = 0 '
        "WHERE storage_id = 'st2' AND path = 'B/0003.mp4'",
      );

      for (final direction in SortDirection.values) {
        final id = await scenario(
            sortField: ScenarioSortField.sizeInBytes, direction: direction);
        await addTwoSources(id);
        await build(id);

        final known =
            direction == SortDirection.asc ? sizeAsc : sizeDesc;
        final unknown = direction == SortDirection.asc
            // Inside the unknown bucket the raw column still orders rows:
            // NULL before 0 on ASC.
            ? ['st1:A/0004.mp4', 'st2:B/0003.mp4']
            : ['st2:B/0003.mp4', 'st1:A/0004.mp4'];
        expect(await queue(id, indexed: true), [...known, ...unknown]);
        expect(await queue(id, indexed: false), [...known, ...unknown]);
      }
    });

    test('a single source keeps the bitmap shape (zero storage regression)',
        () async {
      await seedFile('st1', 'A/0001.mp4', size: 300);
      await seedFile('st1', 'A/0002.mp4', size: 100);
      final id = await scenario(sortField: ScenarioSortField.sizeInBytes);
      await repo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);
      await build(id);

      final blobs = await sharedDao.read(await indexDao.currentBuildId(id));
      expect(SharedIndexCodec.decodeSlices(blobs!.slices),
          isA<SingleBaseOrder>());
      expect(await queue(id, indexed: true),
          ['st1:A/0002.mp4', 'st1:A/0001.mp4']);
    });

    test('one storage with two sources uses the merged shape and stays sorted',
        () async {
      await seedFile('st1', 'A/0001.mp4', size: 300);
      await seedFile('st1', 'A/sub/0002.mp4', size: 100);
      final id = await scenario(sortField: ScenarioSortField.sizeInBytes);
      await repo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);
      await repo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A/sub', recursive: true);
      await build(id);

      final blobs = await sharedDao.read(await indexDao.currentBuildId(id));
      expect(SharedIndexCodec.decodeSlices(blobs!.slices),
          isA<MultiBaseOrder>());
      // The sub file is contributed by BOTH sources, so it appears twice.
      expect(await queue(id, indexed: true), [
        'st1:A/sub/0002.mp4',
        'st1:A/sub/0002.mp4',
        'st1:A/0001.mp4',
      ]);
      expect(await queue(id, indexed: false), [
        'st1:A/sub/0002.mp4',
        'st1:A/sub/0002.mp4',
        'st1:A/0001.mp4',
      ]);
    });

    test('duplicates keep every occurrence, numbered in global order', () async {
      await seedFile('st1', 'A/0001.mp4', size: 100);
      await seedFile('st1', 'A/0002.mp4', size: 200);
      await seedFile('st1', 'A/sub/0001.mp4', size: 300);
      final id = await scenario();
      await repo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);
      await repo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A/sub', recursive: true);
      await build(id);

      final page = await resolver().resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 100);
      expect([for (final i in page.items) i.media.path.join('/')], [
        'A/0001.mp4',
        'A/sub/0001.mp4',
        'A/sub/0001.mp4',
        'A/0002.mp4',
      ]);
      expect([for (final i in page.items) i.occurrenceId.occurrenceIndex],
          [0, 0, 1, 0],
          reason: 'the duplicate occurrence is numbered by its base position');
    });

    test('同目录连续 makes the whole queue directory-contiguous', () async {
      await seedFile('st1', 'A/0001.mp4');
      await seedFile('st1', 'A/sub/0002.mp4');
      await seedFile('st1', 'A/0003.mp4');
      await seedFile('st2', 'B/0001.mp4');
      await seedFile('st2', 'B/0002.mp4');
      final id = await scenario(grouped: true);
      await addTwoSources(id);
      await build(id);

      // Directory blocks span sources and storages, and stay in name order
      // inside each block.
      expect(await queue(id, indexed: true), [
        'st1:A/0001.mp4',
        'st1:A/0003.mp4',
        'st1:A/sub/0002.mp4',
        'st2:B/0001.mp4',
        'st2:B/0002.mp4',
      ]);
      expect(await queue(id, indexed: false), [
        'st1:A/0001.mp4',
        'st1:A/0003.mp4',
        'st1:A/sub/0002.mp4',
        'st2:B/0001.mp4',
        'st2:B/0002.mp4',
      ]);
    });
  });
}
