import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
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
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_state.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_source_provider.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/path_conv.dart';

VirtualMediaRule _mergeRule({
  String id = 'r1',
  String name = 'R',
  List<String> paths = const ['A'],
  VmBoundaryMode boundary = VmBoundaryMode.sameDirOnly,
  int maxItemCount = 10,
  List<VmTitleTag>? titleTags,
}) =>
    VirtualMediaRule(
      id: id,
      name: name,
      matchMode: VmMatchMode.specifiedDirRecursive,
      paths: paths,
      boundary: boundary,
      useDurationCap: false,
      useCountCap: true,
      maxItemCount: maxItemCount,
      titleTags:
          titleTags ?? const [VmTitleTag.dirName, VmTitleTag.seq],
      enabled: true,
    );

void main() {
  group('ScenarioResolver index-backed read', () {
    late AppDatabase db;
    late ScenarioRepository scenarioRepo;
    late ScenarioQueueIndexDao indexDao;
    late MediaOrderDao orderDao;
    late ScenarioSharedIndexDao sharedDao;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      scenarioRepo = ScenarioRepository(
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

    tearDown(() async {
      await db.close();
    });

    Future<void> seedMedia(int n, {int? durationMs = 60000, String dir = 'A'}) async {
      final dao = MediaNodesDao(db);
      for (var i = 0; i < n; i++) {
        final path = '$dir/${i.toString().padLeft(4, '0')}.mp4';
        await dao.insertNode(
          MediaNode.file(
            id: path,
            storageId: 'st1',
            path: path.split('/'),
            name: path.split('/').last,
            mediaType: MediaType.video,
            durationMs: durationMs,
          ),
        );
      }
    }

    ScenarioResolver buildResolver({List<VirtualMediaRule>? rules}) {
      return ScenarioResolver(
        repo: scenarioRepo,
        nodeRepo: MediaNodeRepository(MediaNodesDao(db)),
        scopedMediaTypes: () => null,
        providers: {
          ScenarioSourceKind.folder:
              FolderSourceProvider(scopedMediaTypes: () => null),
        },
        vmRulesProvider: () async => rules ?? const [],
        queueIndexDao: indexDao,
        mediaOrderDao: orderDao,
        sharedIndexDao: sharedDao,
        mediaRevisionProvider: (_) async => 0,
      );
    }

    Future<String> scenarioWithSource({
      PlaybackOrder order = PlaybackOrder.sequential,
      int? seed,
    }) async {
      final scenario = await scenarioRepo.createScenario(name: 'Anime');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'A',
        recursive: true,
      );
      if (order != PlaybackOrder.sequential) {
        await scenarioRepo.updateScenario(
          (await scenarioRepo.getScenario(scenario.id))!.copyWith(order: order),
        );
      }
      if (seed != null) {
        await scenarioRepo.updateState(
          ScenarioState(scenarioId: scenario.id, shuffleSeed: seed),
        );
      }
      return scenario.id;
    }

    test('indexed page equals legacy page (no rules), full walk parity',
        () async {
      await seedMedia(100);
      final resolver = buildResolver();
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      const pageSize = 25;
      for (var page = 0; page < 4; page++) {
        final legacy = await resolver.resolvePage(
            scenarioId: id, page: page, pageSize: pageSize);
        final indexed = await resolver.resolvePageIndexed(
            scenarioId: id, page: page, pageSize: pageSize);
        expect(indexed.totalItems, legacy.totalItems);
        expect(
          indexed.items.map((e) => e.mediaKey).toList(),
          legacy.items.map((e) => e.mediaKey).toList(),
          reason: 'page $page differs',
        );
      }
    });

    test('indexed rows keep the contributing source as an origin', () async {
      // The derived index persists only the media node id, so a read-back row
      // must re-derive its origin from the scenario's sources — otherwise the
      // queue's "Skip from source" action silently disappears on the indexed
      // path.
      await seedMedia(3);
      final resolver = buildResolver();
      final id = await scenarioWithSource();
      final sourceId = (await scenarioRepo.getSources(id)).single.id;
      await resolver.buildQueueIndex(id);

      final indexed = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);
      expect(indexed.items, hasLength(3));
      for (final item in indexed.items) {
        expect(item.origins, hasLength(1));
        expect(item.origins.single.sourceId, sourceId);
      }
    });

    test('occurrence recovery matches the legacy walk, then the index',
        () async {
      await seedMedia(10);
      final resolver = buildResolver();
      final id = await scenarioWithSource();
      const occ = PlaybackOccurrenceId(storageId: 'st1', path: 'A/0004.mp4');

      // No index yet → the legacy walk.
      final legacy = await resolver.resolveItemByOccurrenceFor(
          scenarioId: id, occurrence: occ);
      expect(legacy, isNotNull);

      await resolver.buildQueueIndex(id);
      // Index exists → the O(log n) path; same identity and base slot.
      final indexed = await resolver.resolveItemByOccurrenceFor(
          scenarioId: id, occurrence: occ);
      expect(indexed, isNotNull);
      expect(indexed!.mediaKey, legacy!.mediaKey);
      expect(indexed.virtualIndex, legacy.virtualIndex);
      expect(indexed.occurrenceId.occurrenceIndex,
          legacy.occurrenceId.occurrenceIndex);
    });

    test('occurrence recovery maps a covered member to its group row', () async {
      await seedMedia(6);
      final resolver = buildResolver(rules: [_mergeRule(maxItemCount: 3)]);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      final item = await resolver.resolveItemByOccurrenceFor(
        scenarioId: id,
        occurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/0001.mp4'),
      );
      expect(item, isNotNull);
      expect(item!.virtualMerged, isTrue);
      expect(item.vmSegmentCount, 3);
      // The row it maps to is the group's BASE slot (anchor 0), not the
      // member's own slot.
      expect(item.virtualIndex, 0);
      // Identity still belongs to the requested FILE.
      expect(item.mediaKey, canonicalKey('st1', 'A/0001.mp4'));
      expect(item.occurrenceId.path, 'A/0001.mp4');
    });

    test('legacy pages do not overlap when excludes compact the stream',
        () async {
      // Regression: the loop used to collect `pageSize` ACCEPTED items from an
      // unbounded start point, so excluded slots shifted later items forward
      // and page 1 repeated the tail of page 0. Pages are windows of the
      // ELEMENT axis — the same one the indexed read uses — so neighbouring
      // pages can never share a row.
      await seedMedia(105);
      final resolver = buildResolver();
      final id = await scenarioWithSource();
      for (final n in ['0000', '0001']) {
        await scenarioRepo.addExcludeRule(
          scenarioId: id,
          rule: ScenarioExcludeRule(
            id: 0,
            scenarioId: id,
            kind: ExcludeRuleKind.media,
            storageId: 'st1',
            path: 'A/$n.mp4',
          ),
        );
      }
      final p0 =
          await resolver.resolvePage(scenarioId: id, page: 0, pageSize: 50);
      final p1 =
          await resolver.resolvePage(scenarioId: id, page: 1, pageSize: 50);
      final p0keys = p0.items.map((e) => e.mediaKey).toSet();
      expect(p0keys, isNotEmpty);
      expect(
        p1.items.map((e) => e.mediaKey).any(p0keys.contains),
        isFalse,
        reason: 'page 1 must not repeat page 0 items',
      );
    });

    test('indexed page slices by element with pageSize', () async {
      await seedMedia(100);
      final resolver = buildResolver();
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      final p0 = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 10);
      final p1 = await resolver.resolvePageIndexed(
          scenarioId: id, page: 1, pageSize: 10);
      expect(p0.items, hasLength(10));
      expect(p1.items, hasLength(10));
      expect(p0.items.first.mediaKey, isNot(p1.items.first.mediaKey));
      expect(p0.totalItems, 100);
    });

    test('virtualIndex and totalItems match the legacy walk when nothing is '
        'filtered out', () async {
      await seedMedia(6);
      final resolver = buildResolver();
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);
      final legacy =
          await resolver.resolvePage(scenarioId: id, page: 0, pageSize: 50);
      final indexed = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);
      expect(indexed.totalItems, legacy.totalItems);
      expect(indexed.items.map((e) => e.virtualIndex).toList(),
          legacy.items.map((e) => e.virtualIndex).toList());
    });

    test('a group row numbers by DISPLAY position and swallows its members\' '
        'slots', () async {
      // 6 files, groups of 3 → two ELEMENTS. The members take no row of their
      // own, so the second group is element 1 even though its base anchor is
      // rank 3 — the anchor is a storage detail the queue never shows.
      await seedMedia(6);
      final resolver = buildResolver(rules: [_mergeRule(maxItemCount: 3)]);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);
      final indexed = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);
      expect(indexed.items.map((e) => e.virtualIndex).toList(), [0, 1]);
      expect(indexed.items.map((e) => e.vmSegmentCount).toList(), [3, 3]);
      expect(indexed.totalItems, 2, reason: 'totalItems counts visible rows');
    });

    test('both reads number the ACCEPTED stream densely and totalItems counts '
        'only it', () async {
      await seedMedia(6);
      final resolver = buildResolver();
      final id = await scenarioWithSource();
      for (final n in ['0001', '0002']) {
        await scenarioRepo.addExcludeRule(
          scenarioId: id,
          rule: ScenarioExcludeRule(
            id: 0,
            scenarioId: id,
            kind: ExcludeRuleKind.media,
            storageId: 'st1',
            path: 'A/$n.mp4',
          ),
        );
      }
      await resolver.buildQueueIndex(id);
      final legacy =
          await resolver.resolvePage(scenarioId: id, page: 0, pageSize: 50);
      final indexed = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);

      // The index stores the ACCEPTED stream, so its elements are compact…
      expect(indexed.items.map((e) => e.mediaKey).toList(), [
        canonicalKey('st1', 'A/0000.mp4'),
        canonicalKey('st1', 'A/0003.mp4'),
        canonicalKey('st1', 'A/0004.mp4'),
        canonicalKey('st1', 'A/0005.mp4'),
      ]);
      expect(indexed.items.map((e) => e.virtualIndex).toList(), [0, 1, 2, 3]);
      // …and the walk pages the SAME element axis, so the two agree exactly:
      // an excluded file leaves no hole in what the user reads, and the page
      // total is the number of rows they can actually reach.
      expect(legacy.items.map((e) => e.mediaKey).toList(),
          indexed.items.map((e) => e.mediaKey).toList());
      expect(legacy.items.map((e) => e.virtualIndex).toList(), [0, 1, 2, 3]);
      expect(indexed.totalItems, 4);
      expect(legacy.totalItems, 4);
    });

    test('groups + excludes: rows still number densely and totalItems counts '
        'the elements', () async {
      // Files 0..5, exclude A/0001 → accepted ranks 0,2,3,4,5; groups of 3
      // anchor at ranks 0 and 3, so the two group rows ARE the two elements.
      await seedMedia(6);
      final resolver = buildResolver(rules: [_mergeRule(maxItemCount: 3)]);
      final id = await scenarioWithSource();
      await scenarioRepo.addExcludeRule(
        scenarioId: id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: id,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'A/0001.mp4',
        ),
      );
      await resolver.buildQueueIndex(id);
      final indexed = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);
      expect(indexed.items.map((e) => e.virtualIndex).toList(), [0, 1]);
      expect(indexed.totalItems, 2);
    });

    test('group collapses members into ONE merged row with children', () async {
      await seedMedia(5);
      final resolver = buildResolver(rules: [_mergeRule()]);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);
      // 5 files fold into ONE element: one row, one number, one page slot.
      expect(page.items, hasLength(1));
      expect(page.items.single.virtualMerged, isTrue);
      expect(page.items.single.vmSegmentCount, 5);
      expect(page.items.single.vmChildren, hasLength(5));
      expect(page.items.single.virtualIndex, 0);
      expect(page.totalItems, 1);
    });

    test('cross-page group is emitted exactly once', () async {
      await seedMedia(5);
      final resolver = buildResolver(rules: [_mergeRule()]);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      // 5 files fold into ONE element, so page 0 (pageSize 2) owns the single
      // row and page 1 is simply past the element count.
      final p0 = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 2);
      final p1 = await resolver.resolvePageIndexed(
          scenarioId: id, page: 1, pageSize: 2);
      expect(p0.items, hasLength(1));
      expect(p0.items.single.virtualMerged, isTrue);
      expect(p1.items, isEmpty);
    });

    test('resolveItemAtIndex seeks the right item (no rules)', () async {
      await seedMedia(50);
      final resolver = buildResolver();
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      final legacy = await resolver.resolvePage(
          scenarioId: id, page: 0, pageSize: 50);
      for (final ordinal in [0, 7, 25, 49]) {
        final item = await resolver.resolveItemAtIndex(id, ordinal);
        expect(item, isNotNull);
        expect(item!.mediaKey, legacy.items[ordinal].mediaKey,
            reason: 'ordinal $ordinal');
      }
    });

    test('resolveItemAtIndex returns the merged group for a member ordinal',
        () async {
      await seedMedia(5);
      final resolver = buildResolver(rules: [_mergeRule()]);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      // All 5 files are one group at ordinal 0; ordinals 1-4 don't exist as
      // rows, so they resolve to null.
      final first = await resolver.resolveItemAtIndex(id, 0);
      expect(first, isNotNull);
      expect(first!.virtualMerged, isTrue);
      expect(await resolver.resolveItemAtIndex(id, 1), isNull);
    });

    test('shuffled indexed page numbers its rows by display position', () async {
      await seedMedia(40);
      final resolver = buildResolver();
      final id = await scenarioWithSource(order: PlaybackOrder.shuffled, seed: 9);
      await resolver.buildQueueIndex(id);

      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 40);
      expect(page.totalItems, 40);
      expect(page.items, hasLength(40));
      // Every display position is served exactly once, whatever the permutation.
      expect(page.items.map((e) => e.virtualIndex).toSet(),
          {for (var i = 0; i < 40; i++) i});
      final natural = [
        for (var i = 0; i < 40; i++)
          canonicalKey('st1', 'A/${i.toString().padLeft(4, '0')}.mp4')
      ];
      expect(page.items.map((e) => e.mediaKey).toSet(), natural.toSet());
      // The permutation must be visible: the page is NOT in rank order.
      expect(page.items.map((e) => e.mediaKey).toList(), isNot(natural));
    });

    test('page windows are element windows and lose no row', () async {
      await seedMedia(12);
      final resolver = buildResolver();
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      final positions = <int>[];
      for (var page = 0; page < 3; page++) {
        final p = await resolver.resolvePageIndexed(
            scenarioId: id, page: page, pageSize: 5);
        positions.addAll(p.items.map((e) => e.virtualIndex));
      }
      expect(positions, [for (var i = 0; i < 12; i++) i]);
    });

    test('an empty-source placeholder survives the indexed read', () async {
      await seedMedia(2);
      final resolver = buildResolver();
      final id = await scenarioWithSource();
      await scenarioRepo.addSource(
        scenarioId: id,
        storageId: 'st1',
        path: 'zz-empty',
        recursive: true,
      );
      await resolver.buildQueueIndex(id);

      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);
      expect(page.totalItems, 3);
      expect(page.items, hasLength(3));
      final unavailable = page.items.where((i) => !i.available).toList();
      expect(unavailable, hasLength(1));
      expect(unavailable.single.media.name, 'zz-empty');
      expect(unavailable.single.explicit, isFalse);
      expect(unavailable.single.virtualIndex, 2);

      // The legacy walk renders the same placeholder.
      final legacy =
          await resolver.resolvePage(scenarioId: id, page: 0, pageSize: 50);
      expect(legacy.items.where((i) => !i.available).single.media.name,
          'zz-empty');
    });

    test('an explicit row is representable: a vanished file is the tail '
        'placeholder and the indexed read serves it', () async {
      await seedMedia(2);
      final resolver = buildResolver();
      final id = await scenarioWithSource();
      await scenarioRepo.addExplicitItem(
        scenarioId: id,
        storageId: 'st1',
        path: 'A/ghost.mp4',
      );
      final buildId = await resolver.buildQueueIndex(id);

      // Explicit items are part of the base order now, so the generation HAS a
      // persisted representation; only the missing node becomes a placeholder.
      expect(await sharedDao.read(buildId), isNotNull);
      expect(await resolver.indexedTotalCount(buildId), 3);

      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);
      final unavailable = page.items.singleWhere((i) => !i.available);
      expect(unavailable.media.name, 'ghost.mp4');
      expect(unavailable.explicit, isTrue);
      expect(unavailable.virtualIndex, 2, reason: 'placeholders are the tail');

      // The slot seek is index-backed too, and it serves the placeholder row.
      final byOrdinal = await resolver.resolveItemAtIndex(
          id, unavailable.virtualIndex);
      expect(byOrdinal, isNotNull);
      expect(byOrdinal!.available, isFalse);
      expect(byOrdinal.media.name, 'ghost.mp4');
    });

    test('group title follows the rule\'s own titleTags', () async {
      await seedMedia(5);
      final rules = [
        _mergeRule(
          name: 'Anime',
          titleTags: const [VmTitleTag.ruleName, VmTitleTag.seq],
        ),
      ];
      final resolver = buildResolver(rules: rules);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      final legacy = await resolver.resolvePage(
          scenarioId: id, page: 0, pageSize: 50);
      final indexed = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);

      expect(legacy.items.single.media.name, 'Anime · 1');
      expect(indexed.items.single.media.name, legacy.items.single.media.name);
    });

    test('group title dirName is the last path segment, not the full root',
        () async {
      await seedMedia(3, dir: 'A/B');
      final resolver = buildResolver(rules: [_mergeRule()]);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      final legacy = await resolver.resolvePage(
          scenarioId: id, page: 0, pageSize: 50);
      final indexed = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);

      expect(legacy.items.single.media.name, 'B · 1');
      expect(indexed.items.single.media.name, legacy.items.single.media.name);
    });

    test('the leading column numbers by DISPLAY position while the title '
        'keeps the chunk\'s stable seq', () async {
      // 12 files merged 3-at-a-time → four ELEMENTS, so the leading column
      // reads the position in the list the user is reading (what
      // `rowInCurrentPage` and the page window key on). The title's `seq` is a
      // different piece of information: the chunk's stable identity, which does
      // not renumber when rows are filtered in or out — see the next test for
      // the case where the two really differ.
      await seedMedia(12);
      final rules = [
        _mergeRule(
          name: 'Anime',
          maxItemCount: 3,
          titleTags: const [VmTitleTag.ruleName, VmTitleTag.seq],
        ),
      ];
      final resolver = buildResolver(rules: rules);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);

      expect(page.items.map((e) => e.media.name).toList(),
          ['Anime · 1', 'Anime · 2', 'Anime · 3', 'Anime · 4']);
      expect(page.items.map((e) => e.virtualIndex).toList(), [0, 1, 2, 3]);
      expect(page.items.map((e) => e.occurrenceId.path).toList(),
          ['A/0000.mp4', 'A/0003.mp4', 'A/0006.mp4', 'A/0009.mp4']);
    });

    test('the leading number and the title seq diverge once a chunk degrades',
        () async {
      // Same 12 files, but 0005's duration is unknown: preflight degrades its
      // whole chunk, so those three files stay plain rows BETWEEN the merged
      // ones. The leading column keeps counting what is on screen (0..5) while
      // the titles keep counting chunks — chunk 2 never became a row, so the
      // remaining rows read 1, 3, 4.
      for (var i = 0; i < 12; i++) {
        final name = '${i.toString().padLeft(4, '0')}.mp4';
        await MediaNodesDao(db).insertNode(MediaNode.file(
          id: 'A/$name',
          storageId: 'st1',
          path: ['A', name],
          name: name,
          mediaType: MediaType.video,
          durationMs: i == 5 ? null : 60000,
        ));
      }
      final rules = [
        _mergeRule(
          name: 'Anime',
          maxItemCount: 3,
          titleTags: const [VmTitleTag.ruleName, VmTitleTag.seq],
        ),
      ];
      final resolver = buildResolver(rules: rules);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);

      expect(page.items.map((e) => e.virtualIndex).toList(),
          [for (var i = 0; i < 6; i++) i],
          reason: 'plain rows occupy real positions too — the column is dense');
      expect(
        page.items
            .where((e) => e.virtualMerged)
            .map((e) => '${e.media.name}@${e.virtualIndex + 1}')
            .toList(),
        ['Anime · 1@1', 'Anime · 3@5', 'Anime · 4@6'],
        reason: 'title seq follows chunks, the column follows the list',
      );
    });

    test('searchVmGroupsIndexed has no hits before the index is built',
        () async {
      await seedMedia(5);
      final resolver = buildResolver(rules: [_mergeRule()]);
      final id = await scenarioWithSource();

      expect(await resolver.searchVmGroupsIndexed(id), isNull);
    });

    test('searchVmGroupsIndexed composes the title and representative from the '
        'index, agreeing with the queue row', () async {
      await seedMedia(5);
      final rules = [
        _mergeRule(
          name: 'Anime',
          titleTags: const [VmTitleTag.ruleName, VmTitleTag.seq],
        ),
      ];
      final resolver = buildResolver(rules: rules);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      final hits = await resolver.searchVmGroupsIndexed(id);
      expect(hits, hasLength(1));
      final hit = hits!.single;
      expect(hit.title, 'Anime · 1');
      expect(hit.scopeKey, 'r1|A|#1');
      expect(hit.segmentCount, 5);
      expect(hit.totalDurationMs, 5 * 60000);
      expect(hit.storageId, 'st1');
      expect(hit.path, 'A/0000.mp4');
      expect(hit.occurrenceIndex, 0);

      // The search hit must carry the same title as the queue's merged row.
      final queue = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);
      expect(hit.title, queue.items.single.media.name);
    });

    test('searchVmGroupsIndexed degrades to the default tags when the rule is '
        'gone', () async {
      await seedMedia(3);
      final rules = [_mergeRule(name: 'Anime')];
      final resolver = buildResolver(rules: rules);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      rules.clear();
      final hits = await resolver.searchVmGroupsIndexed(id);
      expect(hits, hasLength(1));
      expect(hits!.single.title, 'A · 1');
    });
  });
}
