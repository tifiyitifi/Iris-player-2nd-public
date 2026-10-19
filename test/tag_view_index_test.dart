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
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_source_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_members_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_pin_presets_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_view_states_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tags_dao.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/resolver/tag_view_resolver.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/storage_path_codec.dart';

void main() {
  late AppDatabase db;
  late ScenarioRepository scenarioRepo;
  late TagPlayRepository tagRepo;
  late ScenarioQueueIndexDao indexDao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    scenarioRepo = ScenarioRepository(
      scenariosDao: ScenariosDao(db),
      sourcesDao: ScenarioSourcesDao(db),
      itemsDao: ScenarioExplicitItemsDao(db),
      excludesDao: ScenarioExcludesDao(db),
      statesDao: ScenarioStatesDao(db),
    );
    tagRepo = TagPlayRepository(
      tagsDao: VideoTagsDao(db),
      membersDao: VideoTagMembersDao(db),
      viewStatesDao: VideoTagViewStatesDao(db),
      presetsDao: VideoTagPinPresetsDao(db),
      db: db,
    );
    indexDao = ScenarioQueueIndexDao(db);
  });

  tearDown(() async {
    StoragePathCodec.baseResolver = (_) => null;
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

  ScenarioResolver resolverWith({List<VirtualMediaRule>? rules}) =>
      ScenarioResolver(
        repo: scenarioRepo,
        nodeRepo: MediaNodeRepository(MediaNodesDao(db)),
        scopedMediaTypes: () => null,
        providers: {
          ScenarioSourceKind.folder:
              FolderSourceProvider(scopedMediaTypes: () => null),
        },
        vmRulesProvider: () async => rules ?? const [],
        queueIndexDao: indexDao,
      );

  /// The same resolver with the SHARED-order index wired and serving, so the two
  /// representations can be compared on the same generation.
  ///
  /// [tagCallbacks] is the injected tag membership the shared tag reads need;
  /// passing false leaves tag reads on the v43 rows (the guard).
  ScenarioResolver sharedResolverWith({
    List<VirtualMediaRule>? rules,
    bool tagCallbacks = true,
  }) {
    final membersDao = VideoTagMembersDao(db);
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
      mediaOrderDao: MediaOrderDao(db),
      sharedIndexDao: ScenarioSharedIndexDao(db),
      mediaRevisionProvider: (_) async => 0,
      tagMemberNodeIds: tagCallbacks
          ? (tagId, addedAfter) =>
              membersDao.memberNodeIds(tagId, addedAfter: addedAfter)
          : null,
      // The PRODUCTION provider (retention-aware), not the raw DAO: a count
      // test must exercise the same expiry rule the app wires.
      tagMembersByTag: tagCallbacks
          ? (addedAfter) => PlaybackScenarioStore.activeTagMemberNodeIdsByTag(
                addedAfter,
                repo: tagRepo,
                membersDao: membersDao,
              )
          : null,
      useSharedIndexRead: true,
    );
  }

  Future<String> buildScenario({
    List<VirtualMediaRule>? rules,
    bool shared = false,
  }) async {
    final scenario = await scenarioRepo.createScenario(name: 'S');
    await scenarioRepo.addSource(
      scenarioId: scenario.id,
      storageId: 'st1',
      path: 'A',
      recursive: true,
    );
    await (shared
            ? sharedResolverWith(rules: rules)
            : resolverWith(rules: rules))
        .buildQueueIndex(scenario.id);
    return scenario.id;
  }

  test('resolveTagViewIndexed returns only member files, in anchor order',
      () async {
    await seedMedia(10);
    final sid = await buildScenario(shared: true);
    final tag = await tagRepo.createTag(name: 't');
    await tagRepo.addMember(
        tagId: tag.id, storageId: 'st1', pathSegments: ['A/0003.mp4']);
    await tagRepo.addMember(
        tagId: tag.id, storageId: 'st1', pathSegments: ['A/0001.mp4']);

    final items = await sharedResolverWith()
        .resolveTagViewIndexed(scenarioId: sid, tagId: tag.id);
    expect(items, isNotNull);
    expect(items!.map((e) => e.media.name).toList(), ['0001.mp4', '0003.mp4']);
  });

  test('tagIntersectionCountsFor counts the scenario rows a tag hits', () async {
    await seedMedia(10);
    final sid = await buildScenario(shared: true);
    final tag = await tagRepo.createTag(name: 't');
    // The first two are in the scenario, the third is not: the count must be the
    // intersection, not the tag's total.
    for (final p in ['A/0001.mp4', 'A/0002.mp4', 'A/9999.mp4']) {
      await tagRepo.addMember(
          tagId: tag.id, storageId: 'st1', pathSegments: [p]);
    }
    final counts = await sharedResolverWith().tagIntersectionCountsFor(sid);
    expect(counts, isNotNull);
    expect(counts![tag.id], 2);
  });

  test('tagIntersectionCountsFor drops members past the tag retention',
      () async {
    await seedMedia(10);
    final sid = await buildScenario(shared: true);
    final tag = await tagRepo.createTag(
      name: 'r',
      retention: const Duration(minutes: 5),
    );
    // Both are in the scenario; only the fresh one is inside the retention
    // window (the expired row has not been purged yet).
    await tagRepo.addMember(
      tagId: tag.id,
      storageId: 'st1',
      pathSegments: ['A/0001.mp4'],
      at: DateTime.now().subtract(const Duration(hours: 1)),
    );
    await tagRepo.addMember(
      tagId: tag.id,
      storageId: 'st1',
      pathSegments: ['A/0002.mp4'],
      at: DateTime.now(),
    );

    final counts = await sharedResolverWith().tagIntersectionCountsFor(sid);
    expect(counts, isNotNull);
    expect(counts![tag.id], 1,
        reason: 'the expired member must not inflate scenarioCount');
  });

  test('memberCountsByTag returns per-tag totals in SQL', () async {
    final t1 = await tagRepo.createTag(name: 't1');
    final t2 = await tagRepo.createTag(name: 't2');
    await tagRepo.addMember(tagId: t1.id, storageId: 's', pathSegments: ['a']);
    await tagRepo.addMember(tagId: t1.id, storageId: 's', pathSegments: ['b']);
    await tagRepo.addMember(tagId: t2.id, storageId: 's', pathSegments: ['c']);
    final counts = await tagRepo.memberCountsByTag();
    expect(counts[t1.id], 2);
    expect(counts[t2.id], 1);
  });

  test('indexed tag view shows the whole group when one member is tagged',
      () async {
    await seedMedia(4);
    final rule = VirtualMediaRule(
      id: 'r1',
      name: 'R',
      matchMode: VmMatchMode.specifiedDirRecursive,
      paths: const ['A'],
      boundary: VmBoundaryMode.sameDirOnly,
      useDurationCap: false,
      useCountCap: true,
      maxItemCount: 10,
      enabled: true,
    );
    final sid = await buildScenario(rules: [rule], shared: true);
    final tag = await tagRepo.createTag(name: 't');
    await tagRepo.addMember(
        tagId: tag.id, storageId: 'st1', pathSegments: ['A/0002.mp4']);

    final items = await sharedResolverWith(rules: [rule])
        .resolveTagViewIndexed(scenarioId: sid, tagId: tag.id);
    expect(items, hasLength(1));
    expect(items!.single.virtualMerged, isTrue);
    expect(items.single.vmSegmentCount, 4);
  });

  test('the tag view surfaces whole groups, and declines when it cannot serve',
      () async {
    await seedMedia(6);
    final rule = VirtualMediaRule(
      id: 'r1',
      name: 'R',
      matchMode: VmMatchMode.specifiedDirRecursive,
      paths: const ['A'],
      boundary: VmBoundaryMode.sameDirOnly,
      useDurationCap: false,
      useCountCap: true,
      maxItemCount: 3,
      enabled: true,
    );
    final sid = await buildScenario(rules: [rule], shared: true);
    // The build must have produced a SHARED index, otherwise the assertions below
    // would pass vacuously on the fallback.
    expect(
        await ScenarioSharedIndexDao(db)
            .read(await indexDao.currentBuildId(sid)),
        isNotNull,
        reason: 'the scenario must be representable');
    final tag = await tagRepo.createTag(name: 't');
    // One tagged file inside each group: the "宽松" policy surfaces both whole.
    await tagRepo.addMember(
        tagId: tag.id, storageId: 'st1', pathSegments: ['A/0001.mp4']);
    await tagRepo.addMember(
        tagId: tag.id, storageId: 'st1', pathSegments: ['A/0004.mp4']);

    final view = await sharedResolverWith(rules: [rule])
        .resolveTagViewIndexed(scenarioId: sid, tagId: tag.id);
    expect(view, isNotNull);
    expect(view, hasLength(2), reason: 'both groups surface whole');
    expect(view!.every((e) => e.virtualMerged), isTrue);
    expect(view.map((e) => e.vmSegmentCount).toSet(), {3});

    // Without the injected tag membership the shared source cannot answer a tag
    // read at all, so the indexed method DECLINES (null) and the caller keeps its
    // own walk — a silently empty view would be worse than a slow one.
    expect(
      await sharedResolverWith(rules: [rule], tagCallbacks: false)
          .resolveTagViewIndexed(scenarioId: sid, tagId: tag.id),
      isNull,
      reason: 'a tag read without membership data must decline, not guess',
    );

    // Same when the shared index itself is gone: the indexed read declines.
    final buildId = await indexDao.currentBuildId(sid);
    await db.customStatement(
        'DELETE FROM scenario_shared_index WHERE build_id = ?', [buildId]);
    expect(
      await sharedResolverWith(rules: [rule])
          .resolveTagViewIndexed(scenarioId: sid, tagId: tag.id),
      isNull,
    );
  });

  test('the intersection counts are index-only, and decline when they cannot '
      'be answered', () async {
    await seedMedia(10);
    final rule = VirtualMediaRule(
      id: 'r1',
      name: 'R',
      matchMode: VmMatchMode.specifiedDirRecursive,
      paths: const ['A'],
      boundary: VmBoundaryMode.sameDirOnly,
      useDurationCap: false,
      useCountCap: true,
      maxItemCount: 3,
      enabled: true,
    );
    final sid = await buildScenario(rules: [rule], shared: true);
    final buildId = await indexDao.currentBuildId(sid);
    expect(await ScenarioSharedIndexDao(db).read(buildId), isNotNull,
        reason: 'the counts must not come from the fallback');

    final t1 = await tagRepo.createTag(name: 't1');
    final t2 = await tagRepo.createTag(name: 't2');
    // t1 tags a FOLDED group member (NOT counted: the count is over the visible
    // non-group rows) and a standalone file (counted).
    await tagRepo.addMember(
        tagId: t1.id, storageId: 'st1', pathSegments: ['A/0001.mp4']);
    await tagRepo.addMember(
        tagId: t1.id, storageId: 'st1', pathSegments: ['A/0005.mp4']);
    // t2 tags a file that is not in the scenario at all.
    await tagRepo.addMember(
        tagId: t2.id, storageId: 'st1', pathSegments: ['A/9999.mp4']);

    final counts =
        await sharedResolverWith(rules: [rule]).tagIntersectionCountsFor(sid);
    expect(counts, isNotNull);
    expect(counts![t2.id] ?? 0, 0, reason: 'no intersection');

    expect(
      await sharedResolverWith(rules: [rule], tagCallbacks: false)
          .tagIntersectionCountsFor(sid),
      isNull,
      reason: 'an unwired count must decline, not guess',
    );
    await db.customStatement(
        'DELETE FROM scenario_shared_index WHERE build_id = ?', [buildId]);
    expect(
      await sharedResolverWith(rules: [rule]).tagIntersectionCountsFor(sid),
      isNull,
      reason: 'the count is index-only and degrades with it',
    );
  });

  test('TagViewResolver uses the indexed source in mode 1', () async {
    await seedMedia(6);
    final sid = await buildScenario(shared: true);
    final tag = await tagRepo.createTag(name: 't');
    await tagRepo.addMember(
        tagId: tag.id, storageId: 'st1', pathSegments: ['A/0005.mp4']);
    await tagRepo.addMember(
        tagId: tag.id, storageId: 'st1', pathSegments: ['A/0000.mp4']);

    final resolver = TagViewResolver(
      // A source that throws if consulted — proves the index path is used.
      source: _ThrowingSource(),
      indexedSource: ResolverIndexedTagItemsSource(sharedResolverWith()),
      repo: tagRepo,
    );
    final snap = await resolver.resolve(tagId: tag.id, scenarioId: sid);
    expect(snap.length, 2);
    expect(snap.items.map((e) => e.media.name).toSet(),
        {'0000.mp4', '0005.mp4'});
  });

  test('the indexed tag view and counts survive a configured base path',
      () async {
    // Production shape for a local drive: the storage carries a base path, so
    // `media_nodes` stores RELATIVE paths (`A/0001.mp4`) while membership rows
    // stay DOMAIN-absolute (`D:/A/0001.mp4` — what the queue hands to
    // addMember). Joining the two domains in raw SQL used to match nothing:
    // the indexed read returned a NON-NULL empty list, the walk fallback was
    // skipped, and every tag view/intersection count came back empty/zero.
    StoragePathCodec.baseResolver = (id) => id == 'st1' ? const ['D:'] : null;
    final dao = MediaNodesDao(db);
    for (var i = 0; i < 6; i++) {
      final name = '${i.toString().padLeft(4, '0')}.mp4';
      await dao.insertNode(MediaNode.file(
        id: 'A/$name',
        storageId: 'st1',
        path: ['D:', 'A', name],
        name: name,
        mediaType: MediaType.video,
        durationMs: 60000,
      ));
    }
    final sid = await buildScenario(shared: true);
    final tag = await tagRepo.createTag(name: 't');
    await tagRepo.addMember(
        tagId: tag.id, storageId: 'st1', pathSegments: ['D:/A/0001.mp4']);
    await tagRepo.addMember(
        tagId: tag.id, storageId: 'st1', pathSegments: ['D:/A/0003.mp4']);
    // A member whose file is not in the scenario: counted nowhere.
    await tagRepo.addMember(
        tagId: tag.id, storageId: 'st1', pathSegments: ['D:/A/9999.mp4']);

    final items = await sharedResolverWith()
        .resolveTagViewIndexed(scenarioId: sid, tagId: tag.id);
    expect(items, isNotNull);
    expect(items!.map((e) => e.media.name).toList(),
        ['0001.mp4', '0003.mp4'],
        reason: 'members stored absolute must resolve against relative '
            'media_nodes rows');

    final counts = await sharedResolverWith().tagIntersectionCountsFor(sid);
    expect(counts, isNotNull);
    expect(counts![tag.id], 2,
        reason: 'the scenario intersection count must not collapse to 0');

    // The full resolver path: mode-1 view via the index, walk never consulted.
    final resolver = TagViewResolver(
      source: _ThrowingSource(),
      indexedSource: ResolverIndexedTagItemsSource(sharedResolverWith()),
      repo: tagRepo,
    );
    final snap = await resolver.resolve(tagId: tag.id, scenarioId: sid);
    expect(snap.items.map((e) => e.media.name).toSet(),
        {'0001.mp4', '0003.mp4'});
  });
}

class _ThrowingSource implements ScenarioEffectiveItemsSource {
  @override
  Future<List<EffectivePlaybackItem>> collect({
    required String scenarioId,
    Set<String>? mediaKeyFilter,
  }) {
    throw StateError('source must not be consulted when the index is present');
  }
}
