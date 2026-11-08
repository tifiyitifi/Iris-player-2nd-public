import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/actions/scenario_mirror_actions.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_state.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/app_instance.dart';

import 'helpers/sqlite3_loader.dart';

/// The RECEIVING window of a Shift+PageUp/PageDown gesture must play the entry
/// the SOURCE window decided on, or nothing at all.
///
/// The source resolves from its cached stream and ships an absolute index plus
/// that entry's file key; this window re-derives the stream from the cloned
/// scenario, so the indices can disagree after a membership/file change. The
/// shipped key is the identity check that keeps the OSD label and the played
/// file the same, and there is deliberately no "step instead" fallback: playing
/// a different video is worse than reporting that the neighbour is gone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  late String sourceId;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
    useStorageStore();
    await useStorageStore().initialized;
  });

  tearDownAll(() async {
    AppInstance.debugReset();
    await db.close();
  });

  setUp(() async {
    // The receiving window of a spawn is NEVER the primary: the mirror must land
    // in its own private workspace instead of overwriting the source's row.
    AppInstance.debugSetSlot(2);
    for (final t in const [
      'media_nodes',
      'scenario',
      'scenario_sources',
      'scenario_explicit_items',
      'scenario_excludes',
      'scenario_state',
      'scenario_queue_builds',
      'scenario_shared_index',
      'media_orders',
    ]) {
      await db.customStatement('DELETE FROM $t');
    }
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: true,
          useLegacyStoragePersistence: false,
          useScenarioDrivenPlayback: true,
        ));
    await usePlayQueueStore().clear();

    for (final p in ['a.mp4', 'b.mp4', 'c.mp4']) {
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: p,
        storageId: 'st1',
        path: [p],
        name: p,
        mediaType: MediaType.video,
      ));
    }
    final source = await DbModule.scenarioRepo.createScenario(name: 'source');
    sourceId = source.id;
    for (final p in ['a.mp4', 'b.mp4', 'c.mp4']) {
      await DbModule.scenarioRepo.addExplicitItem(
        scenarioId: source.id,
        storageId: 'st1',
        path: p,
      );
    }
    await DbModule.scenarioRepo.updateState(
      ScenarioState(
        scenarioId: source.id,
        currentPlaybackOccurrence: const PlaybackOccurrenceId(
          storageId: 'st1',
          path: 'a.mp4',
        ),
        currentVirtualPos: 0,
      ),
    );
    final store = usePlaybackScenarioStore();
    await store.setActiveScenario(source.id);
    await store.refreshScenarios();
  });

  /// Keys as the provider resolves them, so the test never guesses the path
  /// normalization the scenario layer applies.
  Future<String> keyAt(int index) async {
    final provider = ScenarioPlaybackProvider(store: usePlaybackScenarioStore());
    final entry = await provider.itemAt(index);
    expect(entry, isNotNull, reason: 'fixture: index $index must exist');
    return entry!.key;
  }

  test('replays the shipped index in the mirrored window', () async {
    final key = await keyAt(2);

    final ok = await ScenarioMirrorActions.playMirroredNeighbor(
      sourceScenarioId: sourceId,
      forward: true,
      targetIndex: 2,
      targetFileKey: key,
    );

    expect(ok, isTrue);
    expect(usePlayQueueStore().state.playQueue.single.file.name, 'c.mp4');
  });

  test('a shipped key that disagrees with the index is refused', () async {
    final wrongKey = await keyAt(1);

    final ok = await ScenarioMirrorActions.playMirroredNeighbor(
      sourceScenarioId: sourceId,
      forward: true,
      targetIndex: 2,
      targetFileKey: wrongKey,
    );

    expect(ok, isFalse,
        reason: 'a shifted index must never play a video the source did not name');
    expect(usePlayQueueStore().state.playQueue, isEmpty);
  });

  test('an unreachable target does not fall back to a step', () async {
    // No key, no entry: the request cannot be replayed. Stepping here used to
    // play the bookmark neighbour — the exact "OSD said one file, another
    // played" symptom.
    final ok = await ScenarioMirrorActions.playMirroredNeighbor(
      sourceScenarioId: sourceId,
      forward: true,
      targetIndex: 99,
    );

    expect(ok, isFalse);
    expect(usePlayQueueStore().state.playQueue, isEmpty);
  });

  test('a payload without an index still steps (older builds)', () async {
    final ok = await ScenarioMirrorActions.playMirroredNeighbor(
      sourceScenarioId: sourceId,
      forward: true,
    );

    expect(ok, isTrue);
    expect(usePlayQueueStore().state.playQueue.single.file.name, 'b.mp4',
        reason: 'the legacy path keeps its bookmark/step semantics');
  });
}
