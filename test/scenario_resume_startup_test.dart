import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/meta_settings/engine/playback_resume.dart';
import 'package:iris/features/scenario_playback/actions/scenario_resolved_actions.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

/// Cold-start resume contract:
/// 1. resume must survive the store's selection-restore race (slow IO);
/// 2. the autoplay decision comes from the `playback.resumeOnStartup`
///    policy — NEVER from the session flag `AppState.autoPlay`, which is
///    force-reset to false on every load.
void main() {
  setUpAll(() async {
    final db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
    await runZonedGuarded(() async {
      usePlaybackScenarioStore();
      await usePlaybackScenarioStore().initialized;
      usePlayQueueStore();
      await usePlayQueueStore().initialized;
      useAppStore();
      await useAppStore().initialized;
    }, (Object e, StackTrace st) {});
  });

  setUp(() async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await store.setActiveScenario(sys.id);
    await store.clearSources(sys.id);
    await DbModule.mediaNodesDao.deleteNode('st1', 'Anime/ep01.mp4');
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 'f:st1:Anime/ep01.mp4',
      storageId: 'st1',
      path: ['Anime', 'ep01.mp4'],
      name: 'ep01.mp4',
      mediaType: MediaType.video,
    ));
    await DbModule.scenarioRepo.addSource(
      scenarioId: sys.id,
      storageId: 'st1',
      path: 'Anime',
      recursive: true,
    );
    // Park the current occurrence on the first effective item.
    final resolver = _testResolver();
    final page = await resolver.resolvePage(
      scenarioId: sys.id,
      page: 0,
      pageSize: 10,
    );
    await store.setCurrentItem(occurrence: page.items.first.occurrenceId);
    // Reset the session autoplay latch: the loader force-normalizes it to
    // false on every start, so resume must not depend on it.
    useAppStore().set(useAppStore().state.copyWith(autoPlay: false));
  });

  test('resume immediately after store construction survives the '
      'selection-restore race', () async {
    // A FRESH store reproduces the cold start: its onReady → refreshScenarios
    // (which restores activeScenarioId) is still in flight when Home fires
    // the resume. Awaiting only `initialized` used to leave the resume
    // without an active scenario here.
    final fresh = PlaybackScenarioStore();
    await ScenarioResolvedActions.resumeScenarioPlayback(
      store: fresh,
      provider: ScenarioPlaybackProvider(store: fresh),
    );

    expect(useAppStore().state.autoPlay, isTrue,
        reason: 'resume feeds the queue with play intent');
    final queue = usePlayQueueStore().state.playQueue;
    expect(queue, isNotEmpty);
    expect(queue.first.file.name, 'ep01.mp4');
  });

  test('resume locates via the bounded hint without a full occurrence walk',
      () async {
    // A store that refuses getCurrentItem proves resume no longer depends on
    // the unbounded occurrence walk: establishCurrentPosition + itemAt(index)
    // recover the same item from the persisted hint.
    final noWalk = _NoWalkStore();
    await ScenarioResolvedActions.resumeScenarioPlayback(
      store: noWalk,
      provider: ScenarioPlaybackProvider(store: noWalk),
    );

    final queue = usePlayQueueStore().state.playQueue;
    expect(queue, isNotEmpty);
    expect(queue.first.file.name, 'ep01.mp4');
  });

  test('resume latches autoplay even though the loaded session flag is false',
      () async {
    expect(useAppStore().state.autoPlay, isFalse,
        reason: 'precondition: the loader normalized the session flag off');
    await ScenarioResolvedActions.resumeScenarioPlayback(
      provider: ScenarioPlaybackProvider(store: usePlaybackScenarioStore()),
    );
    expect(useAppStore().state.autoPlay, isTrue);
  });

  test('resume routes the playback-resume policy into advanceEntry', () async {
    final provider = _RecordingProvider(usePlaybackScenarioStore());
    await ScenarioResolvedActions.resumeScenarioPlayback(provider: provider);

    expect(provider.establishCalls, 1);
    expect(provider.autoplayCalls, [true],
        reason: 'default policy (gate OFF degrades to on) must autoplay');
  });

  group('resolveResumeOnStartup decision matrix', () {
    test('gate OFF degrades to resume-on (row absent, expected behavior)',
        () => expect(
              resolveResumeOnStartup(
                const AppState(resumeOnStartup: false),
                metadataEnabled: false,
              ),
              isTrue,
            ));

    test('gate ON honors the stored preference', () {
      expect(
        resolveResumeOnStartup(const AppState(), metadataEnabled: true),
        isTrue,
      );
      expect(
        resolveResumeOnStartup(
          const AppState(resumeOnStartup: false),
          metadataEnabled: true,
        ),
        isFalse,
      );
    });
  });
}

/// Locate-path guard: resume must recover the persisted current item without
/// re-resolving it by walking the whole occurrence stream.
class _NoWalkStore extends PlaybackScenarioStore {
  @override
  Future<EffectivePlaybackItem?> getCurrentItem() async {
    throw StateError(
        'getCurrentItem (full occurrence walk) must not run during resume');
  }
}

ScenarioResolver _testResolver() => ScenarioResolver(
      repo: DbModule.scenarioRepo,
      nodeRepo: DbModule.mediaNodeRepo,
      scopedMediaTypes: () => null,
    );

/// Records what resume feeds downstream without touching the global queue.
class _RecordingProvider extends ScenarioPlaybackProvider {
  _RecordingProvider(PlaybackScenarioStore store)
      : _store = store,
        super(store: store);

  final PlaybackScenarioStore _store;
  final ScenarioResolver _resolver = _testResolver();
  int establishCalls = 0;
  final List<bool> autoplayCalls = <bool>[];

  @override
  Future<PlaybackEntry?> current() async {
    final sys = await DbModule.scenarioRepo.getSystemPlayingScenario();
    if (sys == null) return null;
    final state = await _store.getState(sys.id);
    final occurrence = state?.currentPlaybackOccurrence;
    if (occurrence == null) return null;
    final item = await _resolver.resolveItemByOccurrenceFor(
      scenarioId: sys.id,
      occurrence: occurrence,
    );
    if (item == null) return null;
    return PlaybackEntry(
      file: FileItem(name: item.media.name, uri: 'test://${item.media.name}'),
      storageId: item.media.storageId,
      path: item.occurrenceId.path,
      key: item.mediaKey,
      occurrenceIndex: item.occurrenceId.occurrenceIndex,
      available: item.available,
    );
  }

  @override
  Future<int?> establishCurrentPosition() async {
    establishCalls++;
    return null;
  }

  @override
  Future<void> advanceEntry(PlaybackEntry entry,
      {bool autoplay = true, String? targetFileKey}) async {
    autoplayCalls.add(autoplay);
  }
}
