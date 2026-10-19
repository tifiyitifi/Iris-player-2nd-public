import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_identity/store/use_app_identity_store.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/services/background_duration_probe.dart';
import 'package:iris/features/background_playback/services/bg_pool_revision.dart';
import 'package:iris/features/background_playback/services/background_tag_pool.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/browser/paged_background_media_data_source.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/model/enum/tag_system_kind.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';

import 'helpers/sqlite3_loader.dart';

FileItem _f(String key) => FileItem(name: key, uri: 'file:///$key', path: [key]);

FileItem _bf(String name) => FileItem(
      storageId: 's1',
      path: ['Anime', name],
      name: name,
      uri: 'file:///Anime/$name',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;

  /// Seeds the reserved 「副音备选」tag's membership with a/b/c.
  Future<void> seedBg() async {
    for (final n in ['a.mp4', 'b.mp4', 'c.mp4']) {
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 's1:Anime/$n',
        storageId: 's1',
        path: ['Anime', n],
        name: n,
        mediaType: MediaType.video,
      ));
    }
    final tags = await DbModule.tagPlayRepo.ensureReservedTags();
    final tagId = tags
        .firstWhere(
            (t) => t.systemKind == TagSystemKind.backgroundVoiceCandidate)
        .id;
    for (final n in ['a.mp4', 'b.mp4', 'c.mp4']) {
      await DbModule.tagPlayRepo.addMember(
          tagId: tagId, storageId: 's1', pathSegments: ['Anime', n]);
    }
  }

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    await DbModule.scenarioRepo.ensureSystemPlayingScenario();
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    await usePlaybackScenarioStore().ensureReady();
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
    useStorageStore();
    await useStorageStore().initialized;
    useAppIdentityStore();
    await seedBg();
  });

  tearDownAll(() async {
    await db.close();
  });

  group('bg pool relevance and the queue panel subscription', () {
    test('only the reserved tag\'s membership is relevant to the pool',
        () async {
      final reserved = await reservedBackgroundTagId();
      expect(reserved, isNotNull,
          reason: 'the reserved 「副音备选」tag is seeded for this suite');

      expect(
        await BgPoolRevision.relevanceOfReservedBackgroundTag(reserved!),
        isTrue,
        reason: 'its membership IS the candidate stream',
      );
      // Any other tag — a 收藏 tag, another collection — cannot change the
      // pool, and re-resolving (plus persisting the queue) for it was the cost
      // the default "everything is relevant" probe paid.
      expect(
        await BgPoolRevision.relevanceOfReservedBackgroundTag(reserved + 1),
        isFalse,
      );
    });

    test('creating the workspace keeps activeScenarioId while the resolved id '
        'changes', () async {
      // This is the trap the panel sat in: `refreshScenarios()` deliberately
      // KEEPS a still-valid `activeScenarioId`, so a subscription to it alone
      // never fired for a workspace created (or replaced) in this process, and
      // the panel stayed on "queue empty" with a queue in hand.
      final store = usePlaybackScenarioStore();
      final activeBefore = store.state.activeScenarioId;

      final workspace = await ensureBackgroundPlaybackWorkspace();
      await store.refreshScenarios();

      expect(store.state.activeScenarioId, activeBefore,
          reason: 'the old subscription saw nothing at all');
      expect(currentBackgroundWorkspace(store)?.id, workspace.id,
          reason: 'the resolved id is what the panel must watch');
    });
  });

  group('PagedBackgroundMediaDataSource', () {    test('pages the background scenario (real single files)', () async {
      final id = (await ensureBackgroundPlaybackWorkspace()).id;
      final ds = PagedBackgroundMediaDataSource(scenarioId: id);
      addTearDown(ds.dispose);

      await ds.fetchPage(0, ds.pageSize);
      expect(ds.totalItems, 3);
      expect(
        ds.items.map((e) => e.media.name).toSet(),
        {'a.mp4', 'b.mp4', 'c.mp4'},
      );
      expect(ds.items.every((e) => !e.virtualMerged), isTrue);
      expect(ds.getItemId(ds.items.first), isNotEmpty);
    });

    test('a resolved duration reaches the rows (the page is re-resolved)',
        () async {
      final id = (await ensureBackgroundPlaybackWorkspace()).id;
      final bg = useBackgroundPlaybackStore();
      await bg.initialized;
      final ds = PagedBackgroundMediaDataSource(scenarioId: id);
      addTearDown(ds.dispose);
      await ds.fetchPage(0, ds.pageSize);

      int? durationOf(String name) => ds.items
          .firstWhere((e) => e.media.name == name)
          .media
          .maybeMap(file: (f) => f.durationMs, orElse: () => null);

      // The seeded node carries no duration: the row reads as a problem.
      expect(durationOf('c.mp4'), isNull);

      // A probe resolved it and wrote the duration back to `media_nodes`...
      expect(
        await writeBackBgLiveDuration(
          storageId: 's1',
          path: 'Anime/c.mp4',
          durationMs: 92000,
        ),
        isTrue,
      );
      // ...and published the pass (probing: true, then its outcome). The rows
      // read their duration from the PAGE SNAPSHOT, so a repaint alone left the
      // row an hourglass forever — the page must be re-resolved. The two
      // publishes are separated by the probe's async work (a fetch during the
      // pass could only read the pre-pass rows), so let the first land.
      bg.setBgDurationProbeState(
        failed: const <String>{},
        unknown: const <String>{},
        probing: true,
      );
      await pumpEventQueue();
      bg.setBgDurationProbeState(
        failed: const <String>{},
        unknown: const <String>{},
        probing: false,
      );
      await pumpEventQueue();
      await pumpEventQueue();

      expect(
        durationOf('c.mp4'),
        92000,
        reason: 'the row must read the freshly probed duration, not the '
            'snapshot taken when the panel opened',
      );
    });

    test('resolveCurrentItemIndex follows the bg store current file', () async {
      final id = (await ensureBackgroundPlaybackWorkspace()).id;
      final bg = useBackgroundPlaybackStore();
      await bg.initialized;
      // Play the second scenario row (b) on the engine.
      bg.set(bg.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: [_bf('a.mp4'), _bf('b.mp4')],
        currentIndex: 1,
      ));

      final ds = PagedBackgroundMediaDataSource(scenarioId: id);
      addTearDown(ds.dispose);
      await ds.fetchPage(0, ds.pageSize);

      final current = ds.items.firstWhere((e) => e.media.name == 'b.mp4');
      expect(ds.isCurrentItem(_FakeContext(), current), isTrue);
      final other = ds.items.firstWhere((e) => e.media.name == 'a.mp4');
      expect(ds.isCurrentItem(_FakeContext(), other), isFalse);
    });

    test('a SAF row highlights by its uri even when occurrenceId.path is empty',
        () async {
      // The current-queue key is `backgroundMediaKey` (uri-aware). A SAF row
      // whose occurrence identity carries no segment path (a tag member stored
      // empty) must still match — the old `canonicalKey(occurrenceId...)` built
      // `s1:` and never matched `s1:<uri>`, so the row showed no highlight.
      const safUri =
          'content://com.android.providers.media.documents/document/video%3A101';
      final id = (await ensureBackgroundPlaybackWorkspace()).id;
      final bg = useBackgroundPlaybackStore();
      await bg.initialized;
      bg.set(bg.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: [
          FileItem(storageId: 's1', name: 'saf.mp4', uri: safUri, path: const [])
        ],
        currentIndex: 0,
      ));

      final ds = PagedBackgroundMediaDataSource(scenarioId: id);
      addTearDown(ds.dispose);
      await ds.fetchPage(0, ds.pageSize);

      final item = EffectivePlaybackItem(
        media: MediaNode.file(
          id: 's1:',
          storageId: 's1',
          path: const <String>[],
          name: 'saf.mp4',
          mediaType: MediaType.video,
          uri: safUri,
        ),
        scenarioId: id,
        virtualIndex: 0,
        occurrenceId:
            const PlaybackOccurrenceId(storageId: 's1', path: ''),
      );
      expect(ds.isCurrentItem(_FakeContext(), item), isTrue);
    });
  });

  group('BackgroundPlaybackStore.jumpTo', () {
    late BackgroundPlaybackStore store;
    late UnifiedPlayQueueStore playQueueStore;

    setUp(() async {
      store = BackgroundPlaybackStore();
      await store.initialized;
      playQueueStore = usePlayQueueStore();
    });

    tearDown(() => store.dispose());

    test('jumps to a valid row and autoplays', () async {
      store.set(store.state.copyWith(
        enabled: true,
        queue: [_f('a'), _f('b')],
        currentIndex: 0,
        bgAutoPlay: false,
      ));
      await store.jumpTo(1);
      expect(store.state.currentIndex, 1);
      expect(store.state.bgAutoPlay, isTrue);
    });

    test('ignores out-of-range and disabled state', () async {
      store.set(store.state.copyWith(
        enabled: true,
        queue: [_f('a'), _f('b')],
        currentIndex: 0,
      ));
      expect(await store.jumpTo(-1), BgJumpOutcome.ignored);
      expect(store.state.currentIndex, 0);
      expect(await store.jumpTo(99), BgJumpOutcome.ignored);
      expect(store.state.currentIndex, 0);

      store.set(store.state.copyWith(enabled: false));
      expect(await store.jumpTo(0), BgJumpOutcome.ignored);
      expect(store.state.currentIndex, 0);
    });

    test('refuses the foreground file but keeps it listed', () async {
      await playQueueStore.update(
        playQueue: [PlayQueueItem(file: _f('a'), index: 0)],
        index: 0,
      );
      addTearDown(playQueueStore.clear);

      store.set(store.state.copyWith(
        enabled: true,
        queue: [_f('a'), _f('b')],
        currentIndex: 1,
      ));

      expect(await store.jumpTo(0), BgJumpOutcome.refusedForegroundFile);
      expect(store.state.currentIndex, 1, reason: 'no move on refusal');
      expect(store.state.queue, hasLength(2),
          reason: 'the row stays in the list');
    });

    test('allowSameFgBgFile lifts the jump refusal', () async {
      await playQueueStore.update(
        playQueue: [PlayQueueItem(file: _f('a'), index: 0)],
        index: 0,
      );
      addTearDown(playQueueStore.clear);

      final live = useBackgroundPlaybackStore();
      await live.initialized;
      live.set(live.state.copyWith(allowSameFgBgFile: true));
      addTearDown(() => live.set(live.state.copyWith(allowSameFgBgFile: false)));

      store.set(store.state.copyWith(
        enabled: true,
        queue: [_f('a'), _f('b')],
        currentIndex: 1,
      ));

      expect(await store.jumpTo(0), BgJumpOutcome.jumped);
      expect(store.state.currentIndex, 0);
    });

    test('step is a hard no-op while the A-B editor is open', () async {
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: [_f('a'), _f('b'), _f('c')],
        currentIndex: 0,
        segmentEditMode: true,
      ));

      expect(await store.step(forward: true), isFalse);
      expect(await store.step(forward: false), isFalse);
      expect(await store.step(forward: true, userInitiated: true), isFalse);
      expect(store.state.currentIndex, 0);
    });
  });
}

/// `isCurrentItem` only reads the store (no widget lookup), so a throwaway
/// context is enough for the unit assertion.
class _FakeContext extends Fake implements BuildContext {}
