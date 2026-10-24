import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/utils/app_instance.dart';

import 'helpers/sqlite3_loader.dart';

class _MemoryKv implements KvStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }

  @override
  Future<bool> containsKey({required String key}) async =>
      values.containsKey(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
}

/// The active-selection pick must degrade to "nothing selected" whenever the
/// window has no playing workspace and there is no saved scenario. A non-empty
/// mirror (e.g. only the 副音 background row) used to reach `.first` on an empty
/// list and abort the whole `ensureReady()` chain — startup resume included.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  setUp(() {
    setKvStoreForTest(_MemoryKv());
    AppInstance.debugReset();
  });

  tearDown(() {
    resetKvStoreForTest();
    AppInstance.debugReset();
  });

  test('no playing workspace and no saved scenario leaves no selection',
      () async {
    // First launch of a primary window on a store that only has 副音 rows.
    await DbModule.scenarioRepo.ensureBackgroundWorkspace();

    final store = PlaybackScenarioStore();
    await store.ensureReady();

    expect(store.state.activeScenarioId, isNull);
    expect(
      store.state.scenarios.where((s) => s.type == ScenarioKind.systemPlaying),
      isEmpty,
    );
  });

  test('an extra window whose workspace row vanished still gets a selection',
      () async {
    AppInstance.debugSetSlot(2);
    final store = PlaybackScenarioStore();
    await store.ensureReady();

    final mine = store.state.instanceWorkspaceId;
    expect(mine, isNotNull);
    // Simulate the dangling-id case: the row is gone (GC / cleared data) while
    // the session blob still names it.
    await DbModule.scenariosDao.deleteScenario(mine!);

    await store.refreshScenarios();

    expect(store.state.activeScenarioId, isNull,
        reason: 'a dangling workspace id must not abort the refresh chain');
  });

  test('an extra window never adopts a shared saved scenario', () async {
    // A saved scenario the user played before. Its state row (current
    // occurrence / virtual position) is SHARED with the primary, so adopting it
    // as this window's active selection would let two windows stomp one queue.
    final saved = await DbModule.scenarioRepo.createScenario(name: 'saved');
    await DbModule.scenarioRepo.touchState(saved.id);

    AppInstance.debugSetSlot(2);
    final store = PlaybackScenarioStore();
    await store.ensureReady();
    final mine = store.state.instanceWorkspaceId!;
    expect(store.state.activeScenarioId, mine,
        reason: 'a healthy extra window resumes its OWN workspace');

    // The workspace row disappears (bootstrap failure / purge) while the
    // session blob keeps naming it: the saved fallback must not apply here.
    await DbModule.scenariosDao.deleteScenario(mine);
    await store.refreshScenarios();

    expect(store.state.scenarios.any((c) => c.id == saved.id), isTrue,
        reason: 'the saved scenario stays listed (only the selection is empty)');
    expect(store.state.activeScenarioId, isNull,
        reason: 'no own workspace ⇒ no selection, never a shared queue');

    // The PRIMARY still falls back to the saved scenario for the same data —
    // the guard above must only apply to extra windows.
    AppInstance.debugReset();
    final primary = PlaybackScenarioStore();
    await primary.ensureReady();
    expect(primary.state.activeScenarioId, saved.id);
  });

  test('active-bound operations no-op when nothing is selected', () async {
    // "Nothing selected" is a legal state (an extra window whose own
    // workspace vanished). The active-bound operations must degrade to a
    // no-op: most of them are reached from unawaited UI / keyboard callbacks,
    // where a thrown StateError becomes an unhandled zone error.
    AppInstance.debugSetSlot(2);
    final store = PlaybackScenarioStore();
    await store.ensureReady();
    await DbModule.scenariosDao.deleteScenario(store.state.instanceWorkspaceId!);
    await store.refreshScenarios();
    expect(store.state.activeScenarioId, isNull);

    await store.toggleShuffle();
    await store.toggleShuffleDirection();
    await store.shuffleRefresh();
    await store.setRepeat(Repeat.all);
    await store.setSourceInternalFirst(true);
    await store.setCurrentItem(
      occurrence: PlaybackOccurrenceId(
        storageId: 'st1',
        path: 'Anime/ep01.mp4',
        occurrenceIndex: 0,
      ),
    );
    await store.addSource(storageId: 'st1', path: 'Anime');

    expect(await store.activeState(), isNull);
    expect(await store.getCurrentItem(), isNull);
    final page = await store.resolvePage(page: 0, pageSize: 10);
    expect(page.items, isEmpty);
    expect(page.totalItems, 0);
  });
}
