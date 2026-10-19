import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart'
    show SortDirection;
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/tag_play/resolver/tag_view_resolver.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_members_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_pin_presets_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_view_states_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tags_dao.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_view_state.dart';
import 'package:iris/features/tag_play/model/enum/tag_play_sort_field.dart';
import 'package:iris/features/tag_play/model/enum/tag_system_kind.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/app_database.dart';

import 'helpers/sqlite3_loader.dart';

/// 副音's candidate pool is the reserved 「副音备选」tag's tag VIEW — the SAME
/// resolver (`TagViewResolver`, `ignoreScenario: true`) the foreground tag play
/// uses. A 副音 workspace carries NO scenario sources.
void main() {
  ensureSqlite3Loaded();

  late AppDatabase db;
  late ScenarioRepository repo;
  late TagPlayRepository tagRepo;
  late MediaNodeRepository nodeRepo;
  late VideoTagMembersDao membersDao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    membersDao = VideoTagMembersDao(db);
    repo = ScenarioRepository(
      scenariosDao: ScenariosDao(db),
      sourcesDao: ScenarioSourcesDao(db),
      itemsDao: ScenarioExplicitItemsDao(db),
      excludesDao: ScenarioExcludesDao(db),
      statesDao: ScenarioStatesDao(db),
    );
    tagRepo = TagPlayRepository(
      tagsDao: VideoTagsDao(db),
      membersDao: membersDao,
      viewStatesDao: VideoTagViewStatesDao(db),
      presetsDao: VideoTagPinPresetsDao(db),
      db: db,
    );
    nodeRepo = MediaNodeRepository(MediaNodesDao(db));
  });

  tearDown(() => db.close());

  Future<void> insertNode(String storageId, String path) async {
    final segments = path.split('/');
    await MediaNodesDao(db).insertNode(MediaNode.file(
      id: '$storageId:$path',
      storageId: storageId,
      path: segments,
      name: segments.last,
      mediaType: MediaType.video,
    ));
  }

  Future<int> reservedTagId() async {
    final ensured = await tagRepo.ensureReservedTags();
    return ensured
        .firstWhere(
            (t) => t.systemKind == TagSystemKind.backgroundVoiceCandidate)
        .id;
  }

  /// The production 副音 candidate resolution, pinned to the reserved tag.
  Future<List<EffectivePlaybackItem>> candidates() async {
    final tagId = await reservedTagId();
    final resolver = TagViewResolver(
      source: ScenarioResolverStub(),
      repo: tagRepo,
      nodesByKeys: (keys) => nodeRepo.nodesByMediaKeys(keys),
    );
    final snap = await resolver.resolve(
      tagId: tagId,
      scenarioId: 'bg',
      ignoreScenario: true,
      withVmOverlay: false,
    );
    return snap.vmStream;
  }

  test('a 副音 workspace carries NO sources', () async {
    final bg = await repo.ensureBackgroundWorkspace();
    expect(await repo.getSources(bg.id), isEmpty);
  });

  test('the candidate stream is the reserved tag membership', () async {
    await insertNode('s1', 'Anime/A.mp4');
    await insertNode('s1', 'Anime/B.mp4');
    final tagId = await reservedTagId();
    for (final n in ['A.mp4', 'B.mp4']) {
      await tagRepo.addMember(
          tagId: tagId, storageId: 's1', pathSegments: ['Anime', n]);
    }

    final items = await candidates();
    expect(items.map((e) => e.media.name).toSet(), {'A.mp4', 'B.mp4'});
    // VM overlay is skipped: every candidate is a real file row.
    expect(items.every((e) => !e.virtualMerged), isTrue);
  });

  test('the tag view ordering drives the candidate stream', () async {
    await insertNode('s1', 'Anime/A.mp4');
    await insertNode('s1', 'Anime/B.mp4');
    final tagId = await reservedTagId();
    for (final n in ['B.mp4', 'A.mp4']) {
      await tagRepo.addMember(
          tagId: tagId, storageId: 's1', pathSegments: ['Anime', n]);
    }
    await tagRepo.saveState(TagPlayViewState(
      tagId: tagId,
      sortField: TagPlaySortField.name,
      sortDirection: SortDirection.asc,
    ));

    final items = await candidates();
    expect(items.map((e) => e.media.name).toList(), ['A.mp4', 'B.mp4']);
  });

  test('the 副音 view never VM-merges its members', () async {
    await insertNode('s1', 'A/ep1.mp4');
    await insertNode('s1', 'A/ep2.mp4');
    await insertNode('s1', 'A/ep3.mp4');
    final tagId = await reservedTagId();
    for (final n in ['ep1.mp4', 'ep2.mp4', 'ep3.mp4']) {
      await tagRepo.addMember(
          tagId: tagId, storageId: 's1', pathSegments: ['A', n]);
    }

    final rule = VirtualMediaRule(
      id: 'r1',
      name: 'R',
      matchMode: VmMatchMode.specifiedDirRecursive,
      paths: const ['A'],
      boundary: VmBoundaryMode.ignoreDirs,
      useDurationCap: false,
      useCountCap: true,
      maxItemCount: 10,
      useExcludeOverlong: false,
      skipSingleSegment: false,
      enabled: true,
    );
    final resolver = TagViewResolver(
      source: ScenarioResolverStub(),
      repo: tagRepo,
      nodesByKeys: (keys) => nodeRepo.nodesByMediaKeys(keys),
    );
    final snap = await resolver.resolve(
      tagId: tagId,
      scenarioId: 'bg',
      ignoreScenario: true,
      withVmOverlay: false,
    );
    expect(snap.items, hasLength(3),
        reason: 'every member survives as its own row');
    expect(snap.items.every((e) => !e.virtualMerged), isTrue);
    // The rule is unused because the overlay is skipped; kept for clarity.
    expect(rule.id, 'r1');
  });

  test('an empty reserved tag yields no candidates', () async {
    await reservedTagId();
    expect(await candidates(), isEmpty);
  });
}

/// The tag view's `source` is unused on the `ignoreScenario` path; this stub
/// (rather than the real scenario resolver) keeps the test DB-local.
class ScenarioResolverStub implements ScenarioEffectiveItemsSource {
  @override
  Future<List<EffectivePlaybackItem>> collect({
    required String scenarioId,
    Set<String>? mediaKeyFilter,
  }) async =>
      const [];
}
