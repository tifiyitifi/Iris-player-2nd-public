import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_members_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_pin_presets_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_view_states_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tags_dao.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_tag.dart';
import 'package:iris/features/tag_play/playback/tag_play_controller.dart';
import 'package:iris/features/tag_play/resolver/tag_view_resolver.dart';
import 'package:iris/features/tag_play/store/tag_play_state.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/path_conv.dart';

import 'helpers/sqlite3_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  // Secure-storage platform channel has no plugin under test — mock it so
  // awaited AppStore persists never hang the isolate.
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  late TagPlayRepository repo;

  setUpAll(() async {
    final bootstrap = AppDatabase(NativeDatabase.memory());
    await DbModule.init(bootstrap);
    // Initialize the global stores the controller touches (play queue backend
    // selection happens in onReady).
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    // Point the global coordinator at the fake scenario id used below so
    // view switching / revalidate resolve against it.
    final sc = usePlaybackScenarioStore();
    sc.set(sc.state.copyWith(activeScenarioId: 'sc'));
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = TagPlayRepository(
      tagsDao: VideoTagsDao(db),
      membersDao: VideoTagMembersDao(db),
      viewStatesDao: VideoTagViewStatesDao(db),
      presetsDao: VideoTagPinPresetsDao(db),
      db: db,
    );
  });

  tearDown(() async {
    await db.close();
  });

  EffectivePlaybackItem item(String path, String name) {
    return EffectivePlaybackItem(
      media: MediaNode.file(
        id: '-1',
        storageId: 's1',
        path: path.split('/').where((s) => s.isNotEmpty).toList(),
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
      occurrenceId: PlaybackOccurrenceId(storageId: 's1', path: path),
    );
  }

  Future<TagPlayController> makeController(List<EffectivePlaybackItem> items) {
    return Future.value(TagPlayController(
      repo: repo,
      resolverFactory: () => TagViewResolver(
        source: FakeControllerSource(items),
        repo: repo,
      ),
      noTagDelegate: _FakeNoTagDelegate(),
    ));
  }

  group('jump-back rules (resolveStartIndex)', () {
    test('never played → newest added member', () async {
      final tag = await repo.createTag(name: 't');
      final now = DateTime.utc(2026, 8, 10, 12);
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['a.mp4'],
          at: now.subtract(const Duration(hours: 3)));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['b.mp4'],
          at: now.subtract(const Duration(minutes: 5)));

      final snap = await TagViewResolver(
        source: FakeControllerSource([item('/a.mp4', 'a'), item('/b.mp4', 'b')]),
        repo: repo,
      ).resolve(tagId: tag.id, scenarioId: 'sc');

      final c = await makeController(const []);
      final idx = await c.resolveStartIndex(
        snap: snap, now: now);
      // Newest added is b; default addedAt-desc order puts it at 0.
      expect(idx, 0);
      expect(snap.items[0].occurrenceId.path.split('/').last, 'b.mp4');
    });

    test('played within window → resume bookmark position', () async {
      final tag = await repo.createTag(name: 't');
      final now = DateTime.utc(2026, 8, 10, 12);
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['a.mp4'],
          at: now.subtract(const Duration(hours: 3)));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['b.mp4'],
          at: now.subtract(const Duration(minutes: 30)));

      const bookmarkKey = 's1:/a.mp4';
      await repo.saveState(((await repo.stateOf(tag.id)) ?? TagViewResolver.defaultStateFor(tag.id)).copyWith(
            tagId: tag.id,
            lastMediaKey: canonicalKey('s1', '/a.mp4'),
            lastPlayedAt: now.subtract(const Duration(minutes: 10)),
          ));

      final snap = await TagViewResolver(
        source: FakeControllerSource([item('/a.mp4', 'a'), item('/b.mp4', 'b')]),
        repo: repo,
      ).resolve(tagId: tag.id, scenarioId: 'sc');
      expect(bookmarkKey, isNotNull);

      final c = await makeController(const []);
      final idx = await c.resolveStartIndex(
        snap: snap, now: now);
      expect(idx, snap.indexOfKey(canonicalKey('s1', '/a.mp4')));
    });

    test('last played beyond the tag resume window → newest added', () async {
      final tag = await repo.createTag(
        name: 't',
        resumeWindow: const Duration(hours: 2),
      );
      final now = DateTime.utc(2026, 8, 10, 12);
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['old.mp4'],
          at: now.subtract(const Duration(hours: 9)));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['fresh.mp4'],
          at: now.subtract(const Duration(hours: 1)));

      await repo.saveState(((await repo.stateOf(tag.id)) ?? TagViewResolver.defaultStateFor(tag.id)).copyWith(
        tagId: tag.id,
        lastMediaKey: canonicalKey('s1', '/old.mp4'),
        lastPlayedAt: now.subtract(const Duration(hours: 3)), // > 2h window
      ));

      final snap = await TagViewResolver(
        source: FakeControllerSource(
            [item('/old.mp4', 'o'), item('/fresh.mp4', 'f')]),
        repo: repo,
      ).resolve(tagId: tag.id, scenarioId: 'sc');
      expect(snap.resumeWindow, const Duration(hours: 2));

      final c = await makeController(const []);
      final idx = await c.resolveStartIndex(snap: snap, now: now);
      expect(idx, 0); // fresh.mp4 in addedAt-desc order
      expect(snap.items[idx].occurrenceId.path.split('/').last, 'fresh.mp4');
    });

    test('null resume window is PERMANENT: stale bookmark still resumes',
        () async {
      final tag = await repo.createTag(name: 't'); // resumeWindow = null
      final now = DateTime.utc(2026, 8, 10, 12);
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['a.mp4'],
          at: now.subtract(const Duration(days: 30)));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['b.mp4'],
          at: now.subtract(const Duration(days: 20)));

      await repo.saveState(
          ((await repo.stateOf(tag.id)) ?? TagViewResolver.defaultStateFor(tag.id))
              .copyWith(
        tagId: tag.id,
        lastMediaKey: canonicalKey('s1', '/a.mp4'),
        lastPlayedAt: now.subtract(const Duration(days: 10)), // ancient
      ));

      final snap = await TagViewResolver(
        source: FakeControllerSource([item('/a.mp4', 'a'), item('/b.mp4', 'b')]),
        repo: repo,
      ).resolve(tagId: tag.id, scenarioId: 'sc');

      final c = await makeController(const []);
      final idx = await c.resolveStartIndex(snap: snap, now: now);
      expect(snap.resumeWindow, isNull);
      expect(idx, snap.indexOfKey(canonicalKey('s1', '/a.mp4')));
    });

    test('bookmark vanished from view → newest added fallback', () async {
      final tag = await repo.createTag(name: 't');
      final now = DateTime.utc(2026, 8, 10, 12);
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['gone.mp4'],
          at: now.subtract(const Duration(hours: 5)));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['here.mp4'],
          at: now.subtract(const Duration(minutes: 20)));

      await repo.saveState(((await repo.stateOf(tag.id)) ?? TagViewResolver.defaultStateFor(tag.id)).copyWith(
        tagId: tag.id,
        lastMediaKey: canonicalKey('s1', '/gone.mp4'),
        lastPlayedAt: now.subtract(const Duration(minutes: 10)),
      ));

      // The scenario stream no longer produces gone.mp4.
      final snap = await TagViewResolver(
        source: FakeControllerSource([item('/here.mp4', 'h')]),
        repo: repo,
      ).resolve(tagId: tag.id, scenarioId: 'sc');

      final c = await makeController(const []);
      final idx = await c.resolveStartIndex(
        snap: snap, now: now);
      expect(idx, 0);
    });
  });

  group('bookmark identity (file gone → stop, Play → top)', () {
    test('in-window bookmark whose file vanished reports lost', () async {
      final tag = await repo.createTag(name: 't');
      final now = DateTime.utc(2026, 8, 10, 12);
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['gone.mp4'],
          at: now.subtract(const Duration(hours: 5)));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['here.mp4'],
          at: now.subtract(const Duration(minutes: 20)));

      await repo.saveState(
          ((await repo.stateOf(tag.id)) ?? TagViewResolver.defaultStateFor(tag.id))
              .copyWith(
        tagId: tag.id,
        lastMediaKey: canonicalKey('s1', '/gone.mp4'),
        lastPlayedAt: now.subtract(const Duration(minutes: 10)),
      ));

      // The scenario stream no longer produces gone.mp4.
      final snap = await TagViewResolver(
        source: FakeControllerSource([item('/here.mp4', 'h')]),
        repo: repo,
      ).resolve(tagId: tag.id, scenarioId: 'sc');

      final c = await makeController(const []);
      final decision = await c.resolveStart(snap: snap, now: now);
      expect(decision.bookmarkLost, isTrue);
      expect(decision.fileKey, isNull);
    });

    test('located bookmark carries the real file identity', () async {
      final tag = await repo.createTag(name: 't');
      final now = DateTime.utc(2026, 8, 10, 12);
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['a.mp4'],
          at: now.subtract(const Duration(hours: 3)));
      await repo.addMember(
          tagId: tag.id,
          storageId: 's1',
          pathSegments: ['b.mp4'],
          at: now.subtract(const Duration(minutes: 30)));
      await repo.saveState(
          ((await repo.stateOf(tag.id)) ?? TagViewResolver.defaultStateFor(tag.id))
              .copyWith(
        tagId: tag.id,
        lastMediaKey: canonicalKey('s1', '/a.mp4'),
        lastPlayedAt: now.subtract(const Duration(minutes: 10)),
      ));

      final snap = await TagViewResolver(
        source: FakeControllerSource([item('/a.mp4', 'a'), item('/b.mp4', 'b')]),
        repo: repo,
      ).resolve(tagId: tag.id, scenarioId: 'sc');

      final c = await makeController(const []);
      final decision = await c.resolveStart(snap: snap, now: now);
      expect(decision.bookmarkLost, isFalse);
      expect(decision.fileKey, canonicalKey('s1', '/a.mp4'));
      expect(decision.index, snap.indexOfFileKey(canonicalKey('s1', '/a.mp4')));
    });

    test('advanceFirst feeds the first item and re-stamps the bookmark',
        () async {
      final tag = await repo.createTag(name: 't');
      var at = DateTime.utc(2026, 8, 1);
      for (final p in ['x.mp4', 'y.mp4', 'z.mp4']) {
        await repo.addMember(
            tagId: tag.id, storageId: 's1', pathSegments: [p], at: at);
        at = at.add(const Duration(hours: 1));
      }

      final c = await makeController([
        item('/x.mp4', 'x'),
        item('/y.mp4', 'y'),
        item('/z.mp4', 'z'),
      ]);
      await useTagPlayStore().setActiveView(tag.id);
      c.bindScenario('sc');
      c.snapshot = await c.resolveSnapshot(tag.id, 'sc');

      final entry = await c.advanceFirst();
      expect(entry, isNotNull);
      // Default addedAt DESC → newest (z) is the first item.
      expect(c.currentCachedEntry!.key, canonicalKey('s1', '/z.mp4'));
      final state = await repo.stateOf(tag.id);
      expect(state!.lastMediaKey, canonicalKey('s1', '/z.mp4'));

      await useTagPlayStore().setActiveView(null);
    });
  });

  group('stepping inside the active view', () {
    test('next/previous persist bookmarks and stop at boundaries', () async {
      final tag = await repo.createTag(name: 't');
      var at = DateTime.utc(2026, 8, 1);
      for (final p in ['x.mp4', 'y.mp4', 'z.mp4']) {
        await repo.addMember(
            tagId: tag.id, storageId: 's1', pathSegments: [p], at: at);
        at = at.add(const Duration(hours: 1));
      }

      final c = await makeController([
        item('/x.mp4', 'x'),
        item('/y.mp4', 'y'),
        item('/z.mp4', 'z'),
      ]);

      await useTagPlayStore().setActiveView(tag.id);
      c.snapshot =
          await c.resolveSnapshot(tag.id, 'sc');

      final first = await c.next(); // no current → idx -1+1 = 0
      expect(first, isNotNull);
      // Default order is addedAt DESC → newest (z) sits at index 0.
      expect(c.currentCachedEntry!.key, canonicalKey('s1', '/z.mp4'));

      expect((await c.next())!.key, canonicalKey('s1', '/y.mp4'));
      expect((await c.next())!.key, canonicalKey('s1', '/x.mp4'));
      expect(await c.next(), isNull); // tail

      expect((await c.previous())!.key, canonicalKey('s1', '/y.mp4'));

      // Bookmark persisted with the last stepped position.
      final state = await repo.stateOf(tag.id);
      expect(state!.lastMediaKey, canonicalKey('s1', '/y.mp4'));
      expect(state.lastVirtualPos, 1);

      await useTagPlayStore().setActiveView(null);
    });

    test('toggleShuffle flips view order without touching members', () async {
      final tag = await repo.createTag(name: 't');
      var at = DateTime.utc(2026, 8, 1);
      for (final p in ['m1.mp4', 'm2.mp4', 'm3.mp4', 'm4.mp4']) {
        await repo.addMember(
            tagId: tag.id, storageId: 's1', pathSegments: [p], at: at);
        at = at.add(const Duration(hours: 1));
      }

      final c = await makeController([
        item('/m1.mp4', '1'),
        item('/m2.mp4', '2'),
        item('/m3.mp4', '3'),
        item('/m4.mp4', '4'),
      ]);
      await useTagPlayStore().setActiveView(tag.id);
      c.snapshot = await c.resolveSnapshot(tag.id, 'sc');

      await c.toggleShuffle(scenarioId: 'sc');

      final state = await repo.stateOf(tag.id);
      expect(state!.order, PlaybackOrder.shuffled);
      expect(state.shuffleSeed, isNotNull);
      expect(c.snapshot!.length, 4);

      // Deterministic re-resolve under the persisted seed.
      final again = await c.resolveSnapshot(tag.id, 'sc');
      expect(
        again.items.map(keyOf).toList(),
        c.snapshot!.items.map(keyOf).toList(),
      );

      await c.toggleShuffle();
      final back = await repo.stateOf(tag.id);
      expect(back!.order, PlaybackOrder.sequential);

      await useTagPlayStore().setActiveView(null);
    });
  });

  group('view stack (tag→tag stash & restore)', () {
    setUp(() async {
      // enterView is gated on the metadata-driven era; flip the master gate.
      final app = useAppStore();
      app.set(app.state.copyWith(useMetadataSettings: true));
      // The return stack is opt-in (`tagplay.viewStackEnabled`), OFF by
      // default; these cases pin the ON behavior.
      final tagStore = useTagPlayStore();
      tagStore.set(tagStore.state.copyWith(viewStackEnabled: true));
    });

    tearDown(() async {
      final store = useTagPlayStore();
      store.set(store.state.copyWith(
        activeViewTagId: null,
        viewStackTagIds: const [],
        viewStackEnabled: false,
      ));
    });

    Future<TagPlayTag> seedTag(
      String name,
      List<String> paths, {
      DateTime? base,
    }) async {
      final tag = await repo.createTag(name: name);
      var at = base ?? DateTime.utc(2026, 8, 1);
      for (final p in paths) {
        await repo.addMember(
            tagId: tag.id, storageId: 's1', pathSegments: [p], at: at);
        at = at.add(const Duration(hours: 1));
      }
      return tag;
    }

    test('enter A then B pushes A; popView restores A with its bookmark',
        () async {
      final a = await seedTag('A', ['a1.mp4', 'a2.mp4']);
      final b = await seedTag('B', ['b1.mp4', 'b2.mp4']);

      final c = await makeController([
        item('/a1.mp4', 'a1'),
        item('/a2.mp4', 'a2'),
        item('/b1.mp4', 'b1'),
        item('/b2.mp4', 'b2'),
      ]);

      final firstA = await c.enterView(a.id, scenarioId: 'sc');
      expect(firstA, isNotNull);
      expect(c.activeTagId, a.id);

      // Step inside A so its own bookmark moves off the head.
      await c.next();

      final firstB = await c.enterView(b.id, scenarioId: 'sc');
      expect(firstB, isNotNull);
      expect(c.activeTagId, b.id);
      expect(useTagPlayStore().state.viewStackTagIds, [a.id]);

      final restored = await c.popView(scenarioId: 'sc');
      expect(restored, isNotNull);
      expect(c.activeTagId, a.id);
      expect(useTagPlayStore().state.viewStackTagIds, isEmpty);

      // A's bookmark was preserved across the B detour (addedAt-desc order:
      // enter started at newest a2, the explicit next() moved it onto a1).
      final aState = await repo.stateOf(a.id);
      expect(aState!.lastMediaKey, canonicalKey('s1', '/a1.mp4'));
      expect(c.currentCachedEntry!.key, canonicalKey('s1', '/a1.mp4'));
    });

    test('popView on empty stack exits to the no-tag list and clears state',
        () async {
      final a = await seedTag('A', ['a1.mp4']);

      final c = await makeController([item('/a1.mp4', 'a1')]);
      await c.enterView(a.id, scenarioId: 'sc');
      await useTagPlayStore().clearViewStack(); // simulate direct exit path

      final entry = await c.popView();
      expect(c.isActive, isFalse);
      expect(entry, isNull); // fake delegate has no scenario current
      expect(useTagPlayStore().state.viewStackTagIds, isEmpty);
    });

    test('jump-back defaults OFF: entering B does not stash A', () async {
      // Opt back OUT of the group's ON setup: this pins the shipped default.
      final tagStore = useTagPlayStore();
      tagStore.set(tagStore.state.copyWith(viewStackEnabled: false));

      final a = await seedTag('A', ['a1.mp4']);
      final b = await seedTag('B', ['b1.mp4']);

      final c = await makeController([
        item('/a1.mp4', 'a1'),
        item('/b1.mp4', 'b1'),
      ]);

      await c.enterView(a.id, scenarioId: 'sc');
      await c.enterView(b.id, scenarioId: 'sc');

      expect(c.activeTagId, b.id);
      // Default OFF (`tagplay.viewStackEnabled`): no return path is offered,
      // so switching tags must not stash the outgoing one...
      expect(useTagPlayStore().state.viewStackTagIds, isEmpty);
      // ...while each tag still keeps its OWN bookmark: per-tag resume is
      // independent of the return stack.
      expect(await repo.stateOf(a.id), isNotNull);
      expect(await repo.stateOf(b.id), isNotNull);
    });

    test('exitToNoTag drops the whole stack (row-0 semantics)', () async {
      final a = await seedTag('A', ['a1.mp4']);
      final b = await seedTag('B', ['b1.mp4']);

      final c = await makeController([
        item('/a1.mp4', 'a1'),
        item('/b1.mp4', 'b1'),
      ]);

      await c.enterView(a.id, scenarioId: 'sc');
      await c.enterView(b.id, scenarioId: 'sc');
      expect(useTagPlayStore().state.viewStackTagIds, [a.id]);

      await c.exitToNoTag();
      expect(c.isActive, isFalse);
      expect(useTagPlayStore().state.viewStackTagIds, isEmpty);
      expect(await repo.stateOf(b.id), isNotNull); // B bookmark kept
    });
  });

  group('neighbour landing (explicit start index)', () {
    setUp(() async {
      // enterView is gated on the metadata-driven era; flip the master gate.
      final app = useAppStore();
      app.set(app.state.copyWith(useMetadataSettings: true));
    });

    tearDown(() async {
      final store = useTagPlayStore();
      store.set(store.state.copyWith(
        activeViewTagId: null,
        viewStackTagIds: const [],
      ));
    });

    Future<(TagPlayTag, TagPlayController)> seed() async {
      final tag = await repo.createTag(name: 'N');
      var at = DateTime.utc(2026, 8, 1);
      for (final p in ['n1.mp4', 'n2.mp4', 'n3.mp4']) {
        await repo.addMember(
            tagId: tag.id, storageId: 's1', pathSegments: [p], at: at);
        at = at.add(const Duration(hours: 1));
      }
      final c = await makeController([
        item('/n1.mp4', 'n1'),
        item('/n2.mp4', 'n2'),
        item('/n3.mp4', 'n3'),
      ]);
      return (tag, c);
    }

    Future<void> bookmarkOldest(TagPlayTag tag) async {
      await repo.saveState(
        ((await repo.stateOf(tag.id)) ??
                TagViewResolver.defaultStateFor(tag.id))
            .copyWith(
          tagId: tag.id,
          lastMediaKey: canonicalKey('s1', '/n1.mp4'),
          lastPlayedAt: DateTime.now(),
        ),
      );
    }

    test('an explicit index wins over the bookmark anchor', () async {
      final (tag, c) = await seed();
      // The bookmark sits on the OLDEST member (index 2 in addedAt-desc order),
      // so a bookmark-derived anchor can never coincide with the shipped target.
      await bookmarkOldest(tag);

      final entry = await c.enterView(tag.id, scenarioId: 'sc', startIndex: 0);
      expect(entry, isNotNull);
      expect(entry!.key, canonicalKey('s1', '/n3.mp4'),
          reason: 'the index the SOURCE window resolved must win');
      expect(c.currentCachedEntry!.key, canonicalKey('s1', '/n3.mp4'));
    });

    test('a shipped file key opens that member of the entry', () async {
      final (tag, c) = await seed();
      await bookmarkOldest(tag);

      final entry = await c.enterView(
        tag.id,
        scenarioId: 'sc',
        startIndex: 1,
        startFileKey: canonicalKey('s1', '/n2.mp4'),
      );
      expect(entry?.key, canonicalKey('s1', '/n2.mp4'));
      expect(c.currentCachedEntry!.key, canonicalKey('s1', '/n2.mp4'));
    });

    test('the step fallback still applies when no index is shipped', () async {
      final (tag, c) = await seed();
      await bookmarkOldest(tag);

      // n1 is index 2; stepping back lands on index 1 (n2).
      final entry = await c.enterView(tag.id, scenarioId: 'sc', startStep: -1);
      expect(entry?.key, canonicalKey('s1', '/n2.mp4'));
    });

    test('an out-of-range index reports no neighbour instead of clamping',
        () async {
      final (tag, c) = await seed();
      final entry = await c.enterView(tag.id, scenarioId: 'sc', startIndex: 9);
      expect(entry, isNull);
    });

    test('a vanished bookmark cannot veto the shipped neighbour', () async {
      final (tag, c) = await seed();
      // The bookmark's file is NOT in the view and still inside the resume
      // window → `resolveStart` reports "bookmark lost". That verdict belongs
      // to a bookmarked resume; an EXPLICIT index never reads the bookmark, so
      // it must not be blocked (the source window's live position is the only
      // anchor for this gesture).
      await repo.saveState(
        ((await repo.stateOf(tag.id)) ??
                TagViewResolver.defaultStateFor(tag.id))
            .copyWith(
          tagId: tag.id,
          lastMediaKey: canonicalKey('s1', '/gone.mp4'),
          lastPlayedAt: DateTime.now(),
        ),
      );
      await usePlayQueueStore().clear();

      final entry = await c.enterView(tag.id, scenarioId: 'sc', startIndex: 0);
      expect(entry, isNotNull,
          reason: 'a dead bookmark must not cancel a valid neighbour');
      expect(entry!.key, canonicalKey('s1', '/n3.mp4'));
      expect(usePlayQueueStore().state.playQueue, isNotEmpty,
          reason: 'the bookmark-lost branch used to CLEAR the feed queue');
      expect(useAppStore().state.autoPlay, isTrue,
          reason: 'it also parked autoplay on a window that should be playing');
    });

    test('a mismatched target key is refused instead of playing the index',
        () async {
      final (tag, c) = await seed();
      await bookmarkOldest(tag);
      await usePlayQueueStore().clear();

      // The source shipped index 1 but named a DIFFERENT file: its cached view
      // and this window's fresh resolve disagree. Playing index 1 would show
      // the wrong video behind the OSD label the source displayed.
      final entry = await c.enterView(
        tag.id,
        scenarioId: 'sc',
        startIndex: 1,
        startFileKey: canonicalKey('s1', '/n1.mp4'),
      );
      expect(entry, isNull);
      expect(c.currentCachedEntry, isNull,
          reason: 'nothing may be fed when the decision cannot be replayed');
      expect(usePlayQueueStore().state.playQueue, isEmpty);
    });
  });

  group('view stack persistence (tagplay.viewStackEnabled)', () {
    tearDown(() async {
      // The meta rows live in the shared bootstrap DB — clear them so the
      // neighboring groups never observe this group's fixture.
      await MetaSettingsModule.persistAuxRow('tagplay.viewStackEnabled', '0');
      await MetaSettingsModule.persistAuxRow('tagplay.viewStack', '[]');
      useTagPlayStore().set(const TagPlayState());
    });

    test('load discards a persisted stack while the preference is OFF',
        () async {
      await MetaSettingsModule.persistAuxRow('tagplay.viewStackEnabled', '0');
      await MetaSettingsModule.persistAuxRow('tagplay.viewStack', '[7,8]');

      await useTagPlayStore().load();

      // The capability is disabled: a stale row must never resurface the
      // jump-back row.
      expect(useTagPlayStore().state.viewStackEnabled, isFalse);
      expect(useTagPlayStore().state.viewStackTagIds, isEmpty);
    });

    test('load restores the persisted stack once the preference is ON',
        () async {
      await MetaSettingsModule.persistAuxRow('tagplay.viewStackEnabled', '1');
      await MetaSettingsModule.persistAuxRow('tagplay.viewStack', '[7,8]');

      await useTagPlayStore().load();

      expect(useTagPlayStore().state.viewStackEnabled, isTrue);
      expect(useTagPlayStore().state.viewStackTagIds, [7, 8]);
    });
  });

  group('restart recovery (ensureSnapshot)', () {
    test('fresh controller without snapshot resumes via stored bookmark',
        () async {
      final app = useAppStore();
      app.set(app.state.copyWith(useMetadataSettings: true));

      final tag = await repo.createTag(name: 'r');
      var at = DateTime.utc(2026, 8, 1);
      for (final p in ['r1.mp4', 'r2.mp4', 'r3.mp4']) {
        await repo.addMember(
            tagId: tag.id, storageId: 's1', pathSegments: [p], at: at);
        at = at.add(const Duration(hours: 1));
      }

      final old = await makeController([
        item('/r1.mp4', 'r1'),
        item('/r2.mp4', 'r2'),
        item('/r3.mp4', 'r3'),
      ]);
      await old.enterView(tag.id, scenarioId: 'sc');
      await old.next(); // bookmark now on r2
      expect(old.currentCachedEntry!.key, canonicalKey('s1', '/r2.mp4'));

      // Simulate an app restart: brand-new controller instance (no snapshot,
      // no cached entry), same persisted activeViewTagId + bookmark rows.
      final reborn = TagPlayController(
        repo: repo,
        resolverFactory: () => TagViewResolver(
          source: FakeControllerSource([
            item('/r1.mp4', 'r1'),
            item('/r2.mp4', 'r2'),
            item('/r3.mp4', 'r3'),
          ]),
          repo: repo,
        ),
        noTagDelegate: _FakeNoTagDelegate(),
      );
      reborn.bindScenario('sc');
      expect(reborn.snapshot, isNull);
      expect(reborn.currentCachedEntry, isNull);

      final next = await reborn.next(); // must lazily recover, not dead-end
      expect(next, isNotNull);
      expect(reborn.snapshot, isNotNull);
      // addedAt-desc view: forward stepping continues to the OLDER neighbor.
      expect(next!.key, canonicalKey('s1', '/r1.mp4'));

      final total = await reborn.ensureSnapshot();
      expect(total!.length, 3);

      await useTagPlayStore().setActiveView(null);
    });
  });
}

class _FakeNoTagDelegate implements NoTagDelegate {
  @override
  Future<PlaybackEntry?> current() async => null;

  @override
  Future<void> advanceEntry(PlaybackEntry entry,
      {bool autoplay = true, String? targetFileKey}) async {}

  @override
  Future<void> captureCurrentSegment() async {}
}

/// In-memory stand-in mirroring production filter semantics.
class FakeControllerSource implements ScenarioEffectiveItemsSource {
  final List<EffectivePlaybackItem> items;
  FakeControllerSource(this.items);

  @override
  Future<List<EffectivePlaybackItem>> collect({
    required String scenarioId,
    Set<String>? mediaKeyFilter,
  }) async {
    if (mediaKeyFilter == null) return items;
    return items
        .where((e) =>
            mediaKeyFilter.contains(
                canonicalKey(e.occurrenceId.storageId, e.occurrenceId.path)))
        .toList();
  }
}
