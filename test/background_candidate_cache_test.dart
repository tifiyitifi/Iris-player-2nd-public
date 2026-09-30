import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/model/db/dao/bg_source_rules_dao.dart';
import 'package:iris/features/background_playback/model/db/repositories/bg_source_rule_repository.dart';
import 'package:iris/features/background_playback/model/enum/bg_source_rule_kind.dart';
import 'package:iris/features/background_playback/model/source/bg_source_rule.dart';
import 'package:iris/features/background_playback/services/bg_source_revision.dart';
import 'package:iris/features/background_playback/services/background_candidate_cache.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_members_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_pin_presets_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_view_states_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tags_dao.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/model/enum/tag_system_kind.dart';
import 'package:iris/features/tag_play/services/tag_membership_revision.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

import 'helpers/sqlite3_loader.dart';

/// Node repository whose FIRST `nodesByMediaKeys` probe blocks until released,
/// letting a test interleave a second resolution and prove the in-flight map
/// shares the original future instead of starting a duplicate library scan.
class _GateNodeRepository extends MediaNodeRepository {
  _GateNodeRepository(super.dao);

  final Completer<void> firstCallStarted = Completer<void>();
  final Completer<void> _release = Completer<void>();
  int calls = 0;

  void releaseFirstCall() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<List<MediaNode>> nodesByMediaKeys(
    Set<String> keys, {
    int concurrency = 16,
  }) {
    calls++;
    if (calls == 1) {
      if (!firstCallStarted.isCompleted) firstCallStarted.complete();
      return _release.future.then(
        (_) => super.nodesByMediaKeys(keys, concurrency: concurrency),
      );
    }
    return super.nodesByMediaKeys(keys, concurrency: concurrency);
  }
}

void main() {
  ensureSqlite3Loaded();
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase moduleDb;
  setUpAll(() async {
    moduleDb = AppDatabase(NativeDatabase.memory());
    await DbModule.init(moduleDb);
  });
  tearDownAll(() => moduleDb.close());

  late AppDatabase db;
  late BgSourceRuleRepository ruleRepo;
  late TagPlayRepository tagRepo;
  late MediaNodeRepository nodeRepo;
  late BackgroundCandidateCache cache;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    ruleRepo = BgSourceRuleRepository(rulesDao: BgSourceRulesDao(db));
    tagRepo = TagPlayRepository(
      tagsDao: VideoTagsDao(db),
      membersDao: VideoTagMembersDao(db),
      viewStatesDao: VideoTagViewStatesDao(db),
      presetsDao: VideoTagPinPresetsDao(db),
      db: db,
    );
    nodeRepo = MediaNodeRepository(MediaNodesDao(db));
    cache = BackgroundCandidateCache(
      ruleRepo: ruleRepo,
      tagRepo: tagRepo,
      nodeRepo: nodeRepo,
      dedupeOf: () async => false,
    );
  });

  tearDown(() => db.close());

  Future<void> insertNode(String storageId, String path) async {
    final segments = path.split('/');
    await MediaNodesDao(db).insertNode(MediaNode.file(
      id: '$storageId:$path',
      storageId: storageId,
      path: segments,
      parentPath: segments.length == 1
          ? null
          : segments.sublist(0, segments.length - 1).join('/'),
      pathDepth: segments.length,
      name: segments.last,
      mediaType: MediaType.video,
    ));
  }

  Future<int> reservedBgTagId() async {
    final ensured = await tagRepo.ensureReservedTags();
    return ensured
        .firstWhere(
            (t) => t.systemKind == TagSystemKind.backgroundVoiceCandidate)
        .id;
  }

  List<String> namesOf(List<dynamic> files) =>
      [for (final f in files) (f as dynamic).name as String];

  group('BackgroundCandidateCache', () {
    test('second call is served from cache without re-resolving', () async {
      await insertNode('s1', 'Anime/A.mp4');
      await insertNode('s1', 'Anime/B.mp4');
      final tagId = await reservedBgTagId();
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'A.mp4'],
          at: DateTime(2026, 1, 1, 0, 0, 0));
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'B.mp4'],
          at: DateTime(2026, 1, 1, 0, 1, 0));

      expect(namesOf(await cache.pool()), ['B.mp4', 'A.mp4']);

      // A newer member lands AFTER the resolve and nothing announced it, so
      // the pool stays on its generation. At runtime a membership write DOES
      // announce itself (see the end-to-end case below), which is what keeps
      // this from being the user-visible bug it used to be.
      await insertNode('s1', 'Anime/C.mp4');
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'C.mp4'],
          at: DateTime(2026, 1, 1, 0, 2, 0));
      expect(namesOf(await cache.pool()), ['B.mp4', 'A.mp4']);
    });

    test('a membership revision re-resolves the pool', () async {
      var revision = 0;
      final versioned = BackgroundCandidateCache(
        ruleRepo: ruleRepo,
        tagRepo: tagRepo,
        nodeRepo: nodeRepo,
        dedupeOf: () async => false,
        sourceRevisionOf: () => revision,
      );
      await insertNode('s1', 'Anime/A.mp4');
      final tagId = await reservedBgTagId();
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'A.mp4'],
          at: DateTime(2026, 1, 1, 0, 0, 0));
      expect(namesOf(await versioned.pool()), ['A.mp4']);

      await insertNode('s1', 'Anime/B.mp4');
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'B.mp4'],
          at: DateTime(2026, 1, 1, 0, 1, 0));
      expect(namesOf(await versioned.pool()), ['A.mp4'],
          reason: 'an unannounced change must not re-resolve');

      revision++;
      expect(namesOf(await versioned.pool()), ['B.mp4', 'A.mp4']);
    });

    test('the foreground file itself can join the pool (the 音库 gesture)',
        () async {
      // 「看完 A 觉得不错, 顺手打上音库, 之后 B/C/D 用 A 的音频当副音」 — the
      // video the user is watching RIGHT NOW is the one most likely to get
      // tagged, so the pool must be able to hold it. The same-file guard then
      // keeps it from playing simultaneously; it is not a listing rule.
      TagMembershipRevision.shared.reset();
      final coordinator = BgSourceRevision(
        relevanceOf: (tagId) async => true,
        coalesce: const Duration(milliseconds: 5),
      );
      addTearDown(() {
        coordinator.dispose();
        TagMembershipRevision.shared.reset();
      });
      coordinator.start();
      final live = BackgroundCandidateCache(
        ruleRepo: ruleRepo,
        tagRepo: tagRepo,
        nodeRepo: nodeRepo,
        dedupeOf: () async => false,
        sourceRevisionOf: () => coordinator.revision,
      );

      await insertNode('s1', 'Anime/A.mp4');
      await insertNode('s1', 'Anime/B.mp4');
      final tagId = await reservedBgTagId();
      // B is tagged first and is the current pair; A (the foreground) is
      // tagged afterwards, which is exactly the gesture that used to vanish.
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'B.mp4'],
          at: DateTime(2026, 1, 1, 0, 1, 0));
      expect(namesOf(await live.pool()), ['B.mp4']);

      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'A.mp4'],
          at: DateTime(2026, 1, 1, 0, 2, 0));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(namesOf(await live.pool()), ['A.mp4', 'B.mp4']);
    });

    test('end to end: addMember reaches the pool without any manual refresh',
        () async {
      TagMembershipRevision.shared.reset();
      final coordinator = BgSourceRevision(
        relevanceOf: (tagId) async => true,
        coalesce: const Duration(milliseconds: 5),
      );
      addTearDown(() {
        coordinator.dispose();
        TagMembershipRevision.shared.reset();
      });
      coordinator.start();
      final live = BackgroundCandidateCache(
        ruleRepo: ruleRepo,
        tagRepo: tagRepo,
        nodeRepo: nodeRepo,
        dedupeOf: () async => false,
        sourceRevisionOf: () => coordinator.revision,
      );

      await insertNode('s1', 'Anime/A.mp4');
      final tagId = await reservedBgTagId();
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'A.mp4'],
          at: DateTime(2026, 1, 1, 0, 0, 0));
      expect(namesOf(await live.pool()), ['A.mp4']);

      // The user tags a second video while 副音 runs.
      await insertNode('s1', 'Anime/B.mp4');
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'B.mp4'],
          at: DateTime(2026, 1, 1, 0, 1, 0));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(namesOf(await live.pool()), ['B.mp4', 'A.mp4']);
    });

    test('an unrelated tag leaves the pool alone', () async {
      TagMembershipRevision.shared.reset();
      final coordinator = BgSourceRevision(
        // No 副音 source reads this tag: a write must cost nothing.
        relevanceOf: (tagId) async => false,
        coalesce: const Duration(milliseconds: 5),
      );
      addTearDown(() {
        coordinator.dispose();
        TagMembershipRevision.shared.reset();
      });
      coordinator.start();
      final live = BackgroundCandidateCache(
        ruleRepo: ruleRepo,
        tagRepo: tagRepo,
        nodeRepo: nodeRepo,
        dedupeOf: () async => false,
        sourceRevisionOf: () => coordinator.revision,
      );

      await insertNode('s1', 'Anime/A.mp4');
      final tagId = await reservedBgTagId();
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'A.mp4'],
          at: DateTime(2026, 1, 1, 0, 0, 0));
      expect(namesOf(await live.pool()), ['A.mp4']);

      await insertNode('s1', 'Anime/B.mp4');
      await tagRepo.addMember(
          tagId: tagId + 1000, // a tag the rules do not read
          storageId: 's1',
          pathSegments: ['Anime', 'B.mp4'],
          at: DateTime(2026, 1, 1, 0, 1, 0));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(coordinator.revision, 0);
      expect(namesOf(await live.pool()), ['A.mp4']);
    });

    test('invalidate forces a fresh resolve', () async {
      await insertNode('s1', 'Anime/A.mp4');
      final tagId = await reservedBgTagId();
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'A.mp4'],
          at: DateTime(2026, 1, 1, 0, 0, 0));
      expect(namesOf(await cache.pool()), ['A.mp4']);

      await insertNode('s1', 'Anime/B.mp4');
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'B.mp4'],
          at: DateTime(2026, 1, 1, 0, 1, 0));
      cache.invalidate();
      expect(namesOf(await cache.pool()), ['B.mp4', 'A.mp4']);
    });

    test('a rule change re-resolves automatically', () async {
      await insertNode('s1', 'Anime/A.mp4');
      await insertNode('s1', 'Anime/X.mp4');
      final tagId = await reservedBgTagId();
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'A.mp4'],
          at: DateTime(2026, 1, 1, 0, 0, 0));
      // No active rules → zero-active fallback to the reserved tag.
      expect(namesOf(await cache.pool()), ['A.mp4']);

      await ruleRepo.saveRule(const BgSourceRule(
        id: 'r1',
        kind: BgSourceRuleKind.file,
        fileStorageId: 's1',
        filePath: 'Anime/X.mp4',
      ));
      expect(namesOf(await cache.pool()), ['X.mp4']);

      await ruleRepo.setRuleEnabled('r1', false);
      expect(namesOf(await cache.pool()), ['A.mp4']);
    });

    test('pool is unguarded: the same-file guard is a selection rule', () async {
      await insertNode('s1', 'Anime/A.mp4');
      final tagId = await reservedBgTagId();
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'A.mp4'],
          at: DateTime(2026, 1, 1, 0, 0, 0));
      // The raw pool keeps every member — INCLUDING the foreground's own file.
      // The same-file guard decides what may play RIGHT NOW
      // (`BackgroundQueueLogic.pickStartIndex` / `jumpTo`), never what the
      // queue lists: the 音库 exists so a video the user just watched and liked
      // becomes the 副音 source for the videos after it.
      expect(namesOf(await cache.pool()), ['A.mp4']);
    });

    test('interleaved reads share the in-flight future for the same key',
        () async {
      await insertNode('s1', 'Anime/A.mp4');
      await insertNode('s1', 'Anime/X.mp4');
      final tagId = await reservedBgTagId();
      await tagRepo.addMember(
          tagId: tagId,
          storageId: 's1',
          pathSegments: ['Anime', 'A.mp4'],
          at: DateTime(2026, 1, 1, 0, 0, 0));

      final gateRepo = _GateNodeRepository(MediaNodesDao(db));
      final gatedCache = BackgroundCandidateCache(
        ruleRepo: ruleRepo,
        tagRepo: tagRepo,
        nodeRepo: gateRepo,
        dedupeOf: () async => false,
      );

      // Key A (empty rules → reserved-tag fallback) starts and blocks inside
      // its library probe.
      final a = gatedCache.pool();
      await gateRepo.firstCallStarted.future;

      // A DIFFERENT key B (file rule) resolves meanwhile.
      await ruleRepo.saveRule(const BgSourceRule(
        id: 'r1',
        kind: BgSourceRuleKind.file,
        fileStorageId: 's1',
        filePath: 'Anime/X.mp4',
      ));
      expect(namesOf(await gatedCache.pool()), ['X.mp4']);

      // Back to key A while its FIRST resolve is still in flight: the cache
      // must hand back that same future (one probe), not start a second scan.
      await ruleRepo.deleteRule('r1');
      final a2 = gatedCache.pool();

      gateRepo.releaseFirstCall();
      expect(namesOf(await a), ['A.mp4']);
      expect(namesOf(await a2), ['A.mp4']);
      expect(gateRepo.calls, 1,
          reason: 'a re-request of an in-flight key must share its future');
    });
  });
}
