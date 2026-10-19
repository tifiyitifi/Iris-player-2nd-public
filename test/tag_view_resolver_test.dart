import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_members_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_pin_presets_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_view_states_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tags_dao.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_view_state.dart';
import 'package:iris/features/tag_play/model/enum/tag_play_sort_field.dart';
import 'package:iris/features/tag_play/resolver/tag_view_resolver.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/path_conv.dart';

import 'helpers/sqlite3_loader.dart';

void main() {
  ensureSqlite3Loaded();

  late AppDatabase db;
  late TagPlayRepository repo;
  late VideoTagMembersDao membersDao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    membersDao = VideoTagMembersDao(db);
    repo = TagPlayRepository(
      tagsDao: VideoTagsDao(db),
      membersDao: membersDao,
      viewStatesDao: VideoTagViewStatesDao(db),
      presetsDao: VideoTagPinPresetsDao(db),
      db: db,
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('TagViewResolver', () {
    test('empty tag yields empty snapshot', () async {
      final tag = await repo.createTag(name: 't');
      final r = TagViewResolver(source: FakeSource(const []), repo: repo);

      final snap = await r.resolve(tagId: tag.id, scenarioId: 'sc');
      expect(snap.isEmpty, isTrue);
    });

    test('intersection keeps only members present in the scenario stream',
        () async {
      final tag = await repo.createTag(name: 't');
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['a.mp4'],
          at: DateTime.utc(2026, 8, 1));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['b.mp4'],
          at: DateTime.utc(2026, 8, 2));
      // Not produced by the scenario → dropped.
      await repo.addMember(
          tagId: tag.id,
          storageId: 's9',
          pathSegments: ['ghost.mp4'],
          at: DateTime.utc(2026, 8, 3));

      final source = FakeSource([
        _item('s1', '/a.mp4', 'a'),
        _item('s1', '/c.mp4', 'c'),
        _item('s1', '/b.mp4', 'b'),
      ]);
      final r = TagViewResolver(source: source, repo: repo);

      final snap = await r.resolve(tagId: tag.id, scenarioId: 'sc');
      expect(snap.length, 2);
      expect(snap.items.map((e) => e.media.name).toSet(), {'a', 'b'});
    });

    test('default order = addedAt desc (newest first)', () async {
      final tag = await repo.createTag(name: 't');
      var at = DateTime.utc(2026, 8, 1);
      Future<void> add(String p) async {
        await repo.addMember(
            tagId: tag.id, storageId: 's1', pathSegments: [p], at: at);
        at = at.add(const Duration(hours: 1));
      }

      await add('first.mp4');
      await add('second.mp4');
      await add('third.mp4');

      final r = TagViewResolver(
        source: FakeSource([
          _item('s1', '/first.mp4', 'f'),
          _item('s1', '/second.mp4', 's'),
          _item('s1', '/third.mp4', 't'),
        ]),
        repo: repo,
      );

      final snap = await r.resolve(tagId: tag.id, scenarioId: 'sc');
      expect(snap.items.map((e) => e.media.name).toList(), ['t', 's', 'f']);
    });

    test('name asc ordering via persisted spec', () async {
      final tag = await repo.createTag(name: 't');
      await repo.saveState(TagPlayViewState(
        tagId: tag.id,
        sortField: TagPlaySortField.name,
        sortDirection: SortDirection.asc,
      ));

      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['mango.mp4'],
          at: DateTime.utc(2026, 8, 1));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['apple.mp4'],
          at: DateTime.utc(2026, 8, 2));

      final r = TagViewResolver(
        source: FakeSource([
          _item('s1', '/mango.mp4', 'mango'),
          _item('s1', '/apple.mp4', 'apple'),
        ]),
        repo: repo,
      );

      final snap = await r.resolve(tagId: tag.id, scenarioId: 'sc');
      expect(snap.items.map((e) => e.media.name).toList(), ['apple', 'mango']);
    });

    test('shuffled view is deterministic and bookmarks stay reachable',
        () async {
      final tag = await repo.createTag(name: 't');
      var at = DateTime.utc(2026, 8, 1);
      final names = ['a', 'b', 'c', 'd', 'e', 'f', 'g'];
      for (final n in names) {
        await repo.addMember(
            tagId: tag.id, storageId: 's1', pathSegments: ['$n.mp4'], at: at);
        at = at.add(const Duration(minutes: 10));
      }
      await repo.saveState(TagPlayViewState(
        tagId: tag.id,
        order: PlaybackOrder.shuffled,
        shuffleSeed: 42,
        shuffleItemCount: names.length,
      ));

      final source = FakeSource([
        for (final n in names) _item('s1', '/$n.mp4', n),
      ]);
      final r = TagViewResolver(source: source, repo: repo);

      final first = await r.resolve(tagId: tag.id, scenarioId: 'sc');
      final second = await r.resolve(tagId: tag.id, scenarioId: 'sc');

      // Deterministic permutation across resolves.
      expect(first.items.map(keyOf).toList(), second.items.map(keyOf).toList());
      expect(first.length, names.length);

      // Shuffle-proof bookmark property: every member locates by key.
      for (var i = 0; i < first.items.length; i++) {
        expect(first.indexOfKey(keyOf(first.items[i])), i);
        // The file→item index (bookmark identity) mirrors it when no group
        // merged the member away.
        expect(first.indexOfFileKey(keyOf(first.items[i])), i);
      }
      expect(first.indexOfFileKey('s1:/absent.mp4'), isNull);
    });
  });

  group('ignoreScenario', () {
    test('resolves the tag whole membership, not the scenario stream',
        () async {
      final tag = await repo.createTag(name: 't');
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['a.mp4'],
          at: DateTime.utc(2026, 8, 1));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['b.mp4'],
          at: DateTime.utc(2026, 8, 2));

      // The scenario produces only a.mp4 — b.mp4 must still be included.
      final r = TagViewResolver(
        source: FakeSource([_item('s1', '/a.mp4', 'a')]),
        repo: repo,
        nodesByKeys: (keys) async => [for (final k in keys) _node(k)],
      );

      final snap = await r.resolve(
        tagId: tag.id,
        scenarioId: 'sc',
        ignoreScenario: true,
      );
      expect(snap.length, 2);
      expect(snap.items.map((e) => e.media.name).toSet(), {'a.mp4', 'b.mp4'});
      // Pre-overlay stream mirrors the resolved items (no rules in tests).
      expect(snap.vmStream.length, 2);
      // Every synthesized item is explicit and carries the member identity.
      expect(snap.items.every((e) => e.explicit), isTrue);
      expect(
        snap.items.map(keyOf).toSet(),
        {'s1:a.mp4', 's1:b.mp4'},
      );
    });

    test('scenario path ignores members absent from the stream', () async {
      final tag = await repo.createTag(name: 't');
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['a.mp4'],
          at: DateTime.utc(2026, 8, 1));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['b.mp4'],
          at: DateTime.utc(2026, 8, 2));

      final r = TagViewResolver(
        source: FakeSource([_item('s1', '/a.mp4', 'a')]),
        repo: repo,
        nodesByKeys: (keys) async => [for (final k in keys) _node(k)],
      );

      final snap = await r.resolve(tagId: tag.id, scenarioId: 'sc');
      expect(snap.length, 1);
      expect(snap.items.single.media.name, 'a');
    });

    test('matches a member whose stored path is not canonical', () async {
      final tag = await repo.createTag(name: 't');
      // A pre-normalization row (canonicalization landed later): stored with a
      // ROOTED path, while the library row is canonical. The lookup key must be
      // canonical on both sides or the member is silently dropped.
      await membersDao.addMember(
        tagId: tag.id,
        storageId: 's1',
        canonicalPath: '/a.mp4',
        addedAt: DateTime.utc(2026, 8, 1),
      );

      final r = TagViewResolver(
        source: FakeSource(const []),
        repo: repo,
        // The library holds the canonical node — the fake echoes the queried
        // (canonical) key, exactly like `nodesByMediaKeys`.
        nodesByKeys: (keys) async => [for (final k in keys) _node(k)],
      );
      final snap = await r.resolve(
        tagId: tag.id,
        scenarioId: 'sc',
        ignoreScenario: true,
      );
      expect(snap.length, 1, reason: 'the rooted member must not be dropped');
      expect(snap.items.single.media.name, 'a.mp4');
      expect(snap.items.single.media.storageId, 's1');
    });

    test('empty membership stays empty even with ignoreScenario', () async {
      final tag = await repo.createTag(name: 't');
      final r = TagViewResolver(
        source: FakeSource(const []),
        repo: repo,
        nodesByKeys: (keys) async => [for (final k in keys) _node(k)],
      );
      final snap = await r.resolve(
        tagId: tag.id,
        scenarioId: 'sc',
        ignoreScenario: true,
      );
      expect(snap.isEmpty, isTrue);
      expect(snap.vmStream, isEmpty);
    });

    test('vanished files are skipped', () async {
      final tag = await repo.createTag(name: 't');
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['a.mp4'],
          at: DateTime.utc(2026, 8, 1));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['gone.mp4'],
          at: DateTime.utc(2026, 8, 2));

      final r = TagViewResolver(
        source: FakeSource(const []),
        repo: repo,
        // Only a.mp4 exists in the library.
        nodesByKeys: (keys) async => [
          for (final k in keys)
            if (k.endsWith('a.mp4')) _node(k)
        ],
      );
      final snap = await r.resolve(
        tagId: tag.id,
        scenarioId: 'sc',
        ignoreScenario: true,
      );
      expect(snap.length, 1);
      expect(snap.items.single.media.name, 'a.mp4');
    });

    test('virtualIndex is the resolved stream position, not membership order',
        () async {
      final tag = await repo.createTag(name: 't');
      // Membership order (addedAt desc) is the REVERSE of name asc, so the raw
      // membership index can never be mistaken for the resolved position.
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['apple.mp4'],
          at: DateTime.utc(2026, 8, 1));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['mango.mp4'],
          at: DateTime.utc(2026, 8, 2));
      await repo.saveState(TagPlayViewState(
        tagId: tag.id,
        sortField: TagPlaySortField.name,
        sortDirection: SortDirection.asc,
      ));

      final r = TagViewResolver(
        source: FakeSource(const []),
        repo: repo,
        nodesByKeys: (keys) async => [for (final k in keys) _node(k)],
      );

      final snap = await r.resolve(
        tagId: tag.id,
        scenarioId: 'sc',
        ignoreScenario: true,
      );
      expect(snap.vmStream.map((e) => e.media.name).toList(),
          ['apple.mp4', 'mango.mp4']);
      for (var i = 0; i < snap.vmStream.length; i++) {
        expect(snap.vmStream[i].virtualIndex, i,
            reason: 'virtualIndex must index the resolved stream');
      }
    });
  });

  group('TagMediaCountResolver', () {
    test('scenarioCount is the intersection, totalCount the membership',
        () async {
      final a = await repo.createTag(name: 'a');
      await repo.addMember(
          tagId: a.id,
          storageId: 's1',
          pathSegments: ['x.mp4'],
          at: DateTime.utc(2026, 8, 1));
      await repo.addMember(
          tagId: a.id,
          storageId: 's1',
          pathSegments: ['y.mp4'],
          at: DateTime.utc(2026, 8, 2));
      final b = await repo.createTag(name: 'b');
      await repo.addMember(
          tagId: b.id,
          storageId: 's1',
          pathSegments: ['z.mp4'],
          at: DateTime.utc(2026, 8, 1));

      final counts = await TagMediaCountResolver(
        source: FakeSource([_item('s1', '/x.mp4', 'x')]),
        repo: repo,
      ).resolveAll(scenarioId: 'sc');

      expect(counts[a.id]!.scenarioCount, 1);
      expect(counts[a.id]!.totalCount, 2);
      expect(counts[b.id]!.scenarioCount, 0);
      expect(counts[b.id]!.totalCount, 1);
    });

    test('expired members excluded from totalCount by retention', () async {
      final tag = await repo.createTag(
        name: 'r',
        retention: const Duration(minutes: 5),
      );
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['old.mp4'],
          at: DateTime.now().subtract(const Duration(hours: 1)));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['fresh.mp4'],
          at: DateTime.now());

      final counts = await TagMediaCountResolver(
        source: FakeSource([
          _item('s1', '/old.mp4', 'old'),
          _item('s1', '/fresh.mp4', 'fresh'),
        ]),
        repo: repo,
      ).resolveAll(scenarioId: 'sc');

      expect(counts[tag.id]!.totalCount, 1);
      expect(counts[tag.id]!.scenarioCount, 1);
    });

    test('empty scenario id yields zero scenarioCount but real totals',
        () async {
      final tag = await repo.createTag(name: 't');
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['x.mp4'],
          at: DateTime.utc(2026, 8, 1));

      final counts = await TagMediaCountResolver(
        source: FakeSource([_item('s1', '/x.mp4', 'x')]),
        repo: repo,
      ).resolveAll(scenarioId: '');

      expect(counts[tag.id]!.scenarioCount, 0);
      expect(counts[tag.id]!.totalCount, 1);
    });
  });
}

/// Builds a file node whose canonical key matches [key] (`storageId:path`).
MediaNode _node(String key) {
  final idx = key.indexOf(':');
  final storageId = key.substring(0, idx);
  final path = key.substring(idx + 1);
  return MediaNode.file(
    id: '-1',
    storageId: storageId,
    path: path.split('/').where((s) => s.isNotEmpty).toList(),
    name: path.split('/').last,
    mediaType: MediaType.video,
    isPresent: true,
  );
}

EffectivePlaybackItem _item(String storageId, String rootedPath, String name) {
  return EffectivePlaybackItem(
    media: MediaNode.file(
      id: '-1',
      storageId: storageId,
      path: rootedPath.split('/').where((s) => s.isNotEmpty).toList(),
      name: name,
      mediaType: MediaType.video,
      isPresent: true,
    ),
    scenarioId: 'sc',
    origins: const [],
    explicit: false,
    duplicated: false,
    available: true,
    virtualIndex: 0,
    occurrenceId: PlaybackOccurrenceId(storageId: storageId, path: rootedPath),
  );
}

/// In-memory stand-in for the scenario effective-stream source. Mirrors the
/// production filter semantics: membership keys are canonical, item paths may
/// be rooted — comparison goes through [canonicalKey].
class FakeSource implements ScenarioEffectiveItemsSource {
  final List<EffectivePlaybackItem> items;
  FakeSource(this.items);

  @override
  Future<List<EffectivePlaybackItem>> collect({
    required String scenarioId,
    Set<String>? mediaKeyFilter,
  }) async {
    if (mediaKeyFilter == null) return items;
    return items.where((e) => mediaKeyFilter.contains(_canonical(e))).toList();
  }

  static String _canonical(EffectivePlaybackItem e) =>
      canonicalKey(e.occurrenceId.storageId, e.occurrenceId.path);
}
