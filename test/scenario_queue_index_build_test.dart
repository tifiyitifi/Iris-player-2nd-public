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
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_queue_builder.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_source_provider.dart';
import 'package:iris/features/scenario_playback/resolver/shared_index_codec.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/path_conv.dart';

VirtualMediaRule _mergeRule({
  String id = 'r1',
  List<String> paths = const ['A'],
  VmBoundaryMode boundary = VmBoundaryMode.sameDirOnly,
  int maxItemCount = 10,
}) =>
    VirtualMediaRule(
      id: id,
      name: 'R',
      matchMode: VmMatchMode.specifiedDirRecursive,
      paths: paths,
      boundary: boundary,
      useDurationCap: false,
      useCountCap: true,
      maxItemCount: maxItemCount,
      enabled: true,
    );

EffectivePlaybackItem _item(String storageId, String path, int rank,
    {int? durationMs = 60000, String? id}) {
  final segs = path.split('/');
  final parent = segs.length > 1 ? segs.sublist(0, segs.length - 1).join('/') : '';
  return EffectivePlaybackItem(
    media: MediaNode.file(
      id: id ?? '$rank',
      storageId: storageId,
      path: segs,
      parentPath: parent,
      name: segs.last,
      mediaType: MediaType.video,
      durationMs: durationMs,
    ),
    scenarioId: 'sc1',
    available: true,
    virtualIndex: rank,
    occurrenceId: PlaybackOccurrenceId(storageId: storageId, path: path),
  );
}

void main() {
  group('ScenarioQueueBuilder (pure)', () {
    test('no rules → every file is an ordinary row at its base rank', () {
      final stream = [
        for (var i = 0; i < 5; i++) _item('st1', 'A/e$i.mp4', i),
      ];
      final plan = ScenarioQueueBuilder.build(
        stream: stream,
        rules: const [],
        mediaNodeIdOf: (rank, item) => rank,
      );
      expect(plan.groups, isEmpty);
      expect(plan.entries, hasLength(5));
      expect(plan.entries.map((e) => e.anchorRank).toList(), [0, 1, 2, 3, 4]);
      expect(plan.entries.every((e) => !e.isGroup), isTrue);
      expect(plan.totalRanks, 5);
    });

    test('a full-directory group collapses members into ONE group row at the '
        'earliest member rank', () {
      final stream = [
        for (var i = 0; i < 5; i++) _item('st1', 'A/e$i.mp4', i),
      ];
      final plan = ScenarioQueueBuilder.build(
        stream: stream,
        rules: [_mergeRule()],
        mediaNodeIdOf: (rank, item) => rank,
      );
      // All 5 files in one group → one group row, no file rows.
      expect(plan.groups, hasLength(1));
      expect(plan.groups.single.segmentCount, 5);
      expect(plan.entries, hasLength(1));
      expect(plan.entries.single.isGroup, isTrue);
      expect(plan.entries.single.anchorRank, 0);
      expect(plan.entries.single.groupId, plan.groups.single.groupId);
    });

    test('group anchors at the EARLIEST member, not the rule-sort first', () {
      // Rule sorts by fileName ascending: e0 < e1 < e2 < e3.
      // Stream order (base ranks) is reversed: e3(0) e2(1) e1(2) e0(3).
      final stream = [
        _item('st1', 'A/e3.mp4', 0, id: '3'),
        _item('st1', 'A/e2.mp4', 1, id: '2'),
        _item('st1', 'A/e1.mp4', 2, id: '1'),
        _item('st1', 'A/e0.mp4', 3, id: '0'),
      ];
      final plan = ScenarioQueueBuilder.build(
        stream: stream,
        rules: [_mergeRule()],
        mediaNodeIdOf: (rank, item) => rank,
      );
      expect(plan.groups, hasLength(1));
      // Earliest base rank among members is 0 (e3).
      expect(plan.entries.single.anchorRank, 0);
      // Members stay in RULE order (e0 first) even though e0 is rank 3.
      final members = plan.groups.single.members;
      expect(members.map((m) => m.mediaNodeId).toList(), [3, 2, 1, 0]);
    });

    test('non-grouped files between groups stay ordinary rows', () {
      // B/ is covered, C/ is not; A/ is covered.
      final stream = [
        _item('st1', 'A/a0.mp4', 0),
        _item('st1', 'A/a1.mp4', 1),
        _item('st1', 'C/c0.mp4', 2),
        _item('st1', 'A/a2.mp4', 3),
      ];
      final plan = ScenarioQueueBuilder.build(
        stream: stream,
        rules: [_mergeRule(paths: const ['A'])],
        mediaNodeIdOf: (rank, item) => rank,
      );
      // A/a0,a1,a2 grouped (contiguous in rule space), C/c0 ordinary.
      expect(plan.groups, hasLength(1));
      expect(plan.entries, hasLength(2));
      final ranks = plan.entries.map((e) => e.anchorRank).toList()..sort();
      expect(ranks, [0, 2]);
      final groupRow = plan.entries.firstWhere((e) => e.isGroup);
      expect(groupRow.anchorRank, 0);
      final fileRow = plan.entries.firstWhere((e) => !e.isGroup);
      expect(fileRow.anchorRank, 2);
    });

    test('a degraded group (member with unknown duration) yields NO group row',
        () {
      final stream = [
        _item('st1', 'A/a0.mp4', 0),
        _item('st1', 'A/a1.mp4', 1, durationMs: null), // unknown → degrade
      ];
      final plan = ScenarioQueueBuilder.build(
        stream: stream,
        rules: [_mergeRule()],
        mediaNodeIdOf: (rank, item) => rank,
      );
      expect(plan.groups, isEmpty);
      // Both members stay ordinary file rows.
      expect(plan.entries, hasLength(2));
      expect(plan.entries.every((e) => !e.isGroup), isTrue);
    });

    test('unavailable placeholders always get a file row', () {
      final stream = [
        _item('st1', 'A/a0.mp4', 0),
        EffectivePlaybackItem(
          media: MediaNode.file(
            id: '-1',
            storageId: 'st1',
            path: const ['A', 'missing.mp4'],
            name: 'missing.mp4',
            mediaType: MediaType.unknown,
            isPresent: false,
          ),
          scenarioId: 'sc1',
          available: false,
          virtualIndex: 1,
          occurrenceId: const PlaybackOccurrenceId(
              storageId: 'st1', path: 'A/missing.mp4'),
        ),
      ];
      final plan = ScenarioQueueBuilder.build(
        stream: stream,
        rules: const [],
        mediaNodeIdOf: (rank, item) => rank,
      );
      expect(plan.entries, hasLength(2));
      expect(plan.entries[1].isGroup, isFalse);
      expect(plan.entries[1].mediaNodeId, isNotNull);
    });

    test('every accepted file is represented exactly once (file row OR group '
        'member)', () {
      final stream = [
        for (var i = 0; i < 6; i++)
          _item('st1', i.isEven ? 'A/e$i.mp4' : 'C/c$i.mp4', i),
      ];
      final plan = ScenarioQueueBuilder.build(
        stream: stream,
        rules: [_mergeRule(paths: const ['A'])],
        mediaNodeIdOf: (rank, item) => rank,
      );
      final represented = <String>{};
      for (final e in plan.entries) {
        if (!e.isGroup) {
          represented.add(e.mediaNodeId.toString());
        }
      }
      for (final g in plan.groups) {
        for (final m in g.members) {
          represented.add(m.mediaNodeId.toString());
        }
      }
      expect(represented.length, 6);
    });

    test('SAF single-picked files keep their own identity (uri, not path)', () {
      // A SAF single pick has `path == []` and its only stable identity is the
      // persisted document uri. Keying on `path.join('/')` collapsed EVERY such
      // file of one storage onto `storageId:`, so the second pick resolved to
      // the first one's rank and reappeared as an extra standalone row while
      // still being counted as a group member.
      EffectivePlaybackItem saf(String uri, int rank) => EffectivePlaybackItem(
            media: MediaNode.file(
              id: 'saf$rank',
              storageId: 'saf1',
              path: const <String>[],
              parentPath: '',
              name: 'pick$rank.mp4',
              mediaType: MediaType.video,
              durationMs: 60000,
              uri: uri,
            ),
            scenarioId: 'sc1',
            available: true,
            virtualIndex: rank,
            occurrenceId: PlaybackOccurrenceId(storageId: 'saf1', path: uri),
          );
      final plan = ScenarioQueueBuilder.build(
        stream: [saf('content://doc/a', 0), saf('content://doc/b', 1)],
        // A rule path of '' roots at the storage, so it covers both picks.
        rules: [_mergeRule(paths: const [''])],
        mediaNodeIdOf: (rank, item) => rank,
      );
      expect(plan.groups, hasLength(1));
      expect(plan.groups.single.segmentCount, 2);
      expect(plan.groups.single.members.map((m) => m.mediaNodeId).toList(),
          [0, 1]);
      // One group row only: no member rank survives as a standalone file row.
      expect(plan.entries, hasLength(1));
      expect(plan.entries.single.isGroup, isTrue);
      // The identity the exclusion/lookup side computes must agree.
      expect(canonicalKey('saf1', 'content://doc/a'),
          isNot(canonicalKey('saf1', '')));
    });
  });

  group('ScenarioResolver.buildQueueIndex (persisted index)', () {
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

    Future<void> seedMedia(int n, {int? durationMs = 60000}) async {
      final dao = MediaNodesDao(db);
      for (var i = 0; i < n; i++) {
        final path = 'A/${i.toString().padLeft(4, '0')}.mp4';
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

    Future<String> scenarioWithSource() async {
      final scenario = await scenarioRepo.createScenario(name: 'Anime');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'A',
        recursive: true,
      );
      return scenario.id;
    }

    test('builds a shared index over every file when no rule matches', () async {
      await seedMedia(5);
      final resolver = buildResolver();
      final id = await scenarioWithSource();

      final buildId = await resolver.buildQueueIndex(id);
      expect(buildId, greaterThan(0));

      // The shared index is the only persisted representation.
      final blobs = await sharedDao.read(buildId);
      expect(blobs, isNotNull);
      expect(blobs!.baseCount, 5);
      expect(await resolver.indexedTotalCount(buildId), 5);

      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 10);
      expect(page.totalItems, 5);
      expect(page.items, hasLength(5));
      expect(page.items.every((e) => !e.virtualMerged), isTrue);
    });

    test('persists a group row + its members for a matching rule', () async {
      await seedMedia(5);
      final resolver = buildResolver(rules: [_mergeRule()]);
      final id = await scenarioWithSource();

      final buildId = await resolver.buildQueueIndex(id);
      final blobs = await sharedDao.read(buildId);
      final groups = SharedIndexCodec.decodeGroups(blobs!.groupRows);
      expect(groups, hasLength(1));
      expect(groups.single.members, hasLength(5));

      // The merged row stands for the whole group: ONE visible row, 5 segments.
      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 10);
      expect(page.totalItems, 1, reason: 'totalItems counts visible rows');
      expect(page.items, hasLength(1));
      expect(page.items.single.vmSegmentCount, 5);
    });

    test('rebuild evicts the previous generation (only newest survives)',
        () async {
      await seedMedia(3);
      final resolver = buildResolver();
      final id = await scenarioWithSource();

      final first = await resolver.buildQueueIndex(id);
      final second = await resolver.buildQueueIndex(id);
      expect(second, isNot(first));

      expect(await sharedDao.read(first), isNull);
      expect(await sharedDao.read(second), isNotNull);
    });

    test('degraded group members become ordinary rows with no group row',
        () async {
      await seedMedia(2, durationMs: null);
      final resolver = buildResolver(rules: [_mergeRule()]);
      final id = await scenarioWithSource();

      final buildId = await resolver.buildQueueIndex(id);
      final blobs = await sharedDao.read(buildId);
      expect(SharedIndexCodec.decodeGroups(blobs!.groupRows), isEmpty);

      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 10);
      expect(page.items, hasLength(2));
      expect(page.items.every((e) => !e.virtualMerged), isTrue);
    });

    test('buildQueueIndex is a no-op when the index DAO is absent', () async {
      await seedMedia(2);
      final resolver = ScenarioResolver(
        repo: scenarioRepo,
        nodeRepo: MediaNodeRepository(MediaNodesDao(db)),
        scopedMediaTypes: () => null,
        providers: {
          ScenarioSourceKind.folder:
              FolderSourceProvider(scopedMediaTypes: () => null),
        },
        vmRulesProvider: () async => const [],
      );
      final id = await scenarioWithSource();
      expect(await resolver.buildQueueIndex(id), 0);
    });
  });
}
