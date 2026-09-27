import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_state.dart';
import 'package:iris/features/scenario_playback/playback/playback_position_signal.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/pages/player/title_prefix.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

/// The bar title's `[cur/total]` prefix is backed by a PROCESS-WIDE signal that
/// only [PlaybackProviderRegistry.scenario] resets (via `play()`). Feeds that
/// never touch the provider — history popup, file browsers, open file / link,
/// share intent — and playback teardown used to leave the previous stream's
/// numbers behind, so the title kept claiming e.g. `[37/120]` while unrelated
/// content played.
///
/// These cases cover the invalidation contract itself: an explicit
/// "playback is no longer scenario-driven" declaration clears the signal, and
/// resuming a stopped scenario re-establishes the position (the two are coupled
/// — clearing without re-establishing would blank the prefix after stop → play).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
    PlaybackProviderRegistry.init();
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    await runZonedGuarded(() async {
      usePlayQueueStore();
      await usePlayQueueStore().initialized;
      useAppStore();
      await useAppStore().initialized;
    }, (Object e, StackTrace st) {});
  });

  setUp(() async {
    final store = usePlaybackScenarioStore();
    await store.clearExplicitItems(store.state.activeScenarioId ?? '');
    await usePlayQueueStore().clear();
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: true,
          useLegacyStoragePersistence: false,
          useScenarioDrivenPlayback: true,
        ));
    VirtualMediaService.instance.invalidate();
    // Process-wide signal: each case must start from "nothing located".
    PlaybackPositionSignal.instance.clear();
  });

  tearDown(() {
    PlaybackPositionSignal.instance.clear();
  });

  Future<void> seedFile(String storageId, String p, {int? durationMs}) async {
    await DbModule.mediaNodesDao.deleteNode(storageId, p);
    final segments = p.split('/');
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 'f:$storageId:$p',
      storageId: storageId,
      path: segments,
      name: segments.last,
      mediaType: MediaType.video,
      durationMs: durationMs,
    ));
  }

  /// Creates + activates a scenario whose effective stream is the [count] files
  /// under [dir]. Nothing is persisted as the current item.
  Future<String> seedScenario(
    String dir, {
    int count = 3,
    int? durationMs,
  }) async {
    for (var i = 0; i < count; i++) {
      await seedFile('st1', '$dir/e$i.mp4', durationMs: durationMs);
    }
    final id = (await usePlaybackScenarioStore().createScenario(dir)).id;
    await DbModule.scenarioRepo.addSource(
        scenarioId: id, storageId: 'st1', path: dir, recursive: false);
    await usePlaybackScenarioStore().setActiveScenario(id);
    return id;
  }

  /// Publishes a located scenario position for a 3-item scenario, as a list tap
  /// would, and returns the scenario id.
  Future<String> locateThirdOfThree() async {
    final id = await seedScenario('A');
    await usePlaybackScenarioStore().setCurrentItem(
      occurrence:
          const PlaybackOccurrenceId(storageId: 'st1', path: 'A/e2.mp4'),
    );
    final index = await PlaybackProviderRegistry.scenario
        .establishCurrentPosition();
    expect(index, 2, reason: 'precondition: the tap located the third item');
    return id;
  }

  test('scenario mode is active for these cases', () {
    expect(PlaybackProviderRegistry.scenarioModeActive, isTrue);
  });

  test('beginExternalFeed drops a published position', () async {
    await locateThirdOfThree();
    expect(PlaybackProviderRegistry.scenario.position.value,
        (index: 2, count: 3));

    PlaybackProviderRegistry.beginExternalFeed();

    expect(PlaybackPositionSignal.instance.position.value, isNull);
  });

  /// Mirrors how `player.dart` composes the bar prefix, so the cases below
  /// assert the WIRING (which fact actually decides the gate) and not just the
  /// pure function in isolation — the pure function was already correct while
  /// the flag fed into it made every external feed prefix-less.
  String? resolvedBarPrefix() {
    final queue = usePlayQueueStore();
    final signal = PlaybackPositionSignal.instance;
    return resolveQueuePrefix(
      tagView: PlaybackProviderRegistry.tagPlay.tagViewStatus.value,
      scenarioPos: signal.position.value,
      scenarioOwnsPlayback: signal.scenarioOwnsContext.value,
      isQueryMode: queue.isQueryMode,
      queryVirtualPos: queue.currentVirtualPos,
      queryTotalCount: queue.totalCount,
      queueLength: queue.state.playQueue.length,
      currentQueueIndex: queue.state.currentIndex,
    );
  }

  /// The history popup / file browser feed: declare the hand-off, then push a
  /// real multi-item list at [index] without ever touching the provider.
  Future<void> feedExternalList({required int index, int length = 3}) async {
    for (var i = 0; i < length; i++) {
      await seedFile('st1', 'H/hist$i.mp4');
    }
    PlaybackProviderRegistry.beginExternalFeed();
    await usePlayQueueStore().update(
      playQueue: [
        for (var i = 0; i < length; i++)
          PlayQueueItem(
            file: FileItem(
              storageId: 'st1',
              name: 'hist$i.mp4',
              uri: 'file:///H/hist$i.mp4',
              type: ContentType.video,
            ),
            index: i,
          ),
      ],
      index: index,
    );
  }

  test('stop drops the published position', () async {
    await locateThirdOfThree();
    expect(PlaybackProviderRegistry.scenario.position.value,
        (index: 2, count: 3));

    await PlaybackProviderRegistry.stop();

    // Otherwise the bar title paired the placeholder title with a leftover
    // [3/3] after the feed was unloaded.
    expect(PlaybackPositionSignal.instance.position.value, isNull);
  });

  // The coupled regression guard: clearing on stop is only correct because
  // resume re-establishes. Without this the prefix would simply vanish for
  // "stop → play" instead of going stale.
  test('resumeActive re-establishes the position a stop cleared', () async {
    await locateThirdOfThree();
    await PlaybackProviderRegistry.stop();
    expect(PlaybackPositionSignal.instance.position.value, isNull);

    await PlaybackProviderRegistry.resumeActive();

    expect(PlaybackProviderRegistry.scenario.position.value,
        (index: 2, count: 3));
  });

  // ── Head fallback: nothing persisted to locate ──
  //
  // `resumeActive` locates the PERSISTED occurrence, so with no current item
  // ("file lost → play from the top") that locate resolves nothing and the
  // fallback's own index 0 was never published: the bar title sat prefix-less
  // while item 0 actually played. The fallback's index is known by
  // construction — it has to be published, not looked up.
  test('resumeActive publishes the head when nothing is persisted as current',
      () async {
    await seedScenario('H');
    expect(await PlaybackProviderRegistry.scenario.current(), isNull);

    await PlaybackProviderRegistry.resumeActive(autoplay: false);

    expect(PlaybackProviderRegistry.scenario.position.value,
        (index: 0, count: 3));
    expect(resolvedBarPrefix(), '[1/3]');
  });

  // ── 副音 cross-file roll ──
  //
  // The roll is a jump that arrives WITHOUT the scenario's own bookkeeping:
  // `advanceEntry` only feeds the player, so without an explicit re-locate the
  // scenario's current item and the bar title keep describing the file the
  // roll LEFT, and the next next/prev steps from the wrong index.
  test('a 副音 cross-file roll republishes the position it lands on', () async {
    const each = 60000;
    await seedScenario('R', count: 2, durationMs: each);
    await usePlaybackScenarioStore().setCurrentItem(
      occurrence:
          const PlaybackOccurrenceId(storageId: 'st1', path: 'R/e0.mp4'),
    );
    await PlaybackProviderRegistry.scenario.establishCurrentPosition();
    expect(PlaybackProviderRegistry.scenario.position.value,
        (index: 0, count: 2));

    // 90s into the concatenated 120s timeline lands 30s into the SECOND file.
    final rolled =
        await PlaybackProviderRegistry.seekVirtualTo(90000, keepPlaying: false);

    expect(rolled, isTrue);
    expect(PlaybackProviderRegistry.scenario.position.value,
        (index: 1, count: 2));
    expect((await PlaybackProviderRegistry.scenario.current())?.path,
        'R/e1.mp4');
    expect(resolvedBarPrefix(), '[2/2]');
  });

  test('a locate in flight cannot resurrect its position after a hand-off',
      () async {
    await locateThirdOfThree();

    final gate = Completer<void>();
    final gated = _GatedStore(gate);
    await gated.ensureReady();
    // Mirror the singleton's selection: the locate under test must resolve the
    // scenario the previous cases located, whatever this fresh instance picked.
    gated.set(usePlaybackScenarioStore().state);

    // A locate starts and parks on its first DB read...
    final pending =
        ScenarioPlaybackProvider(store: gated).establishCurrentPosition();
    await pumpEventQueue();

    // ...while an outside feed (history popup / file browser) takes the player.
    PlaybackProviderRegistry.beginExternalFeed();
    gate.complete();

    // The locate itself still resolves — it is only its PUBLISH that lost the
    // race. Without a hand-off generation it re-claimed the context and put
    // the previous stream's `[k/N]` over the external feed's own index.
    expect(await pending, 2);
    expect(PlaybackPositionSignal.instance.position.value, isNull);
    expect(PlaybackPositionSignal.instance.scenarioOwnsContext.value, isFalse);
  });

  // ── Context OWNERSHIP: the gate the prefix reads ──
  //
  // `scenarioOwnsPlayback` used to be the global `scenarioModeActive` flag,
  // which is true for EVERY playback in the default drift configuration. An
  // external list feed (history popup, both file browsers) feeds a real
  // multi-item queue whose numbers are meaningful, so gating on the global
  // flag suppressed them and left the bar title with no prefix at all. The
  // gate has to be the per-CONTEXT fact: did the scenario provider produce the
  // numbers, or did an outside feed take the player?
  group('context ownership drives the bar prefix', () {
    test('a located scenario position claims the context', () async {
      await locateThirdOfThree();

      expect(PlaybackPositionSignal.instance.scenarioOwnsContext.value, isTrue);
      expect(resolvedBarPrefix(), '[3/3]');
    });

    test('an external list feed hands the prefix to the queue index', () async {
      await locateThirdOfThree();
      // Exactly the history popup / file browser shape: a real list, with the
      // clicked item's own index, fed behind the provider's back.
      await feedExternalList(index: 1);

      // Precondition: in drift mode the feed lands in the query backend, whose
      // virtual position and total are both meaningful.
      final queue = usePlayQueueStore();
      expect(queue.isQueryMode, isTrue);
      expect(queue.currentVirtualPos, 1);
      expect(queue.totalCount, 3);

      expect(
          PlaybackPositionSignal.instance.scenarioOwnsContext.value, isFalse);
      expect(resolvedBarPrefix(), '[2/3]');
    });

    // The reason the global flag cannot be the gate: the two genuinely diverge
    // here. Scenario MODE is a configuration and stays on for the whole app;
    // context OWNERSHIP follows the hand-off. Re-coupling them (feeding
    // `scenarioModeActive` into the prefix again) is exactly this assertion
    // failing.
    test('the global mode flag stays true after the hand-off', () async {
      await locateThirdOfThree();
      await feedExternalList(index: 1);

      expect(PlaybackProviderRegistry.scenarioModeActive, isTrue);
      expect(
          PlaybackPositionSignal.instance.scenarioOwnsContext.value, isFalse);
    });

    test('a single-file external feed is honestly [1/1]', () async {
      await locateThirdOfThree();
      await feedExternalList(index: 0, length: 1);

      expect(resolvedBarPrefix(), '[1/1]');
    });

    // stop() unloads the feed AND empties the queue. Ownership is gone, so the
    // paged-queue branch becomes reachable — with nothing in it. Without the
    // total-count guard that rendered a bare `[1/0]`.
    test('a stop leaves no prefix at all', () async {
      await locateThirdOfThree();

      await PlaybackProviderRegistry.stop();

      final queue = usePlayQueueStore();
      expect(queue.totalCount, 0);
      expect(
          PlaybackPositionSignal.instance.scenarioOwnsContext.value, isFalse);
      expect(resolvedBarPrefix(), isNull);
    });

    // The mirror of the stop case: the scenario's own single-item hop also
    // leaves totalCount == 1 in the query backend, so "owns the context" is the
    // only thing standing between the user and a permanent `[1/1]`.
    test('the scenario re-claims the context on resume after a stop', () async {
      await locateThirdOfThree();
      await PlaybackProviderRegistry.stop();
      expect(resolvedBarPrefix(), isNull);

      await PlaybackProviderRegistry.resumeActive();

      expect(PlaybackPositionSignal.instance.scenarioOwnsContext.value, isTrue);
      expect(resolvedBarPrefix(), '[3/3]');
    });
  });
}

/// A scenario store whose FIRST [activeState] read parks until [gate] completes.
///
/// A real locate spends its window on DB reads — the signature probe, the
/// ordering-hint item seek, and on a big queue a `resolvePage` of up to 10k rows
/// — so a hand-off can always land mid-flight. This makes that window
/// deterministic instead of a sleep.
class _GatedStore extends PlaybackScenarioStore {
  _GatedStore(this.gate);

  final Completer<void> gate;
  bool _parked = false;

  @override
  Future<ScenarioState?> activeState() async {
    if (!_parked) {
      _parked = true;
      await gate.future;
    }
    return super.activeState();
  }
}
