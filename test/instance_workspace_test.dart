import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
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

/// Every extra IRIS window must play in ITS OWN workspace: a manual scope play
/// (folder / library / selection override) writes its queue into the playing
/// workspace row, so one shared row would let window B rewrite the queue window
/// A is playing. The primary window keeps the historical single row.
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

  test('the repository can mint several playing workspaces', () async {
    final repo = DbModule.scenarioRepo;
    final a = await repo.createSystemPlayingWorkspace(name: 'A');
    final b = await repo.createSystemPlayingWorkspace(name: 'B');

    expect(a.id, isNot(b.id));
    expect(a.type, ScenarioKind.systemPlaying);
    expect(b.type, ScenarioKind.systemPlaying);
  });

  test('an extra window owns a private workspace and hides foreign ones',
      () async {
    AppInstance.debugSetSlot(1);
    final primary = PlaybackScenarioStore();
    await primary.ensureReady();
    final shared = await primary.ensureSystemPlayingScenario();
    await primary.setActiveScenario(shared.id);

    AppInstance.debugSetSlot(2);
    final second = PlaybackScenarioStore();
    await second.ensureReady();

    final own = second.state.instanceWorkspaceId;
    expect(own, isNotNull, reason: 'a second window must own a workspace');
    expect(own, isNot(shared.id));
    expect(second.systemPlayingScenario?.id, own);
    expect(
      second.state.scenarios
          .where((s) => s.type == ScenarioKind.systemPlaying)
          .map((s) => s.id),
      [own],
      reason: "another window's playing workspace must not leak into this mirror",
    );
    expect(second.state.activeScenarioId, own,
        reason: 'the second window resumes its own queue, not the primary one');
  });

  test('the primary window keeps the single shared workspace', () async {
    AppInstance.debugSetSlot(2);
    final second = PlaybackScenarioStore();
    await second.ensureReady();
    final secondId = second.state.instanceWorkspaceId;
    expect(secondId, isNotNull);

    AppInstance.debugSetSlot(1);
    final primary = PlaybackScenarioStore();
    await primary.ensureReady();

    final system = primary.systemPlayingScenario;
    expect(system, isNotNull);
    expect(system!.id, isNot(secondId));
    expect(
      primary.state.scenarios
          .where((s) => s.type == ScenarioKind.systemPlaying)
          .length,
      1,
      reason: 'the primary still sees exactly one playing workspace',
    );
  });

  test('each extra window gets a distinct workspace', () async {
    AppInstance.debugSetSlot(2);
    final a = PlaybackScenarioStore();
    await a.ensureReady();

    AppInstance.debugSetSlot(3);
    final b = PlaybackScenarioStore();
    await b.ensureReady();

    expect(a.state.instanceWorkspaceId, isNotNull);
    expect(b.state.instanceWorkspaceId, isNotNull);
    expect(a.state.instanceWorkspaceId, isNot(b.state.instanceWorkspaceId));
  });

  test('deleting the active scenario falls back to this window workspace',
      () async {
    AppInstance.debugSetSlot(2);
    final store = PlaybackScenarioStore();
    await store.ensureReady();

    final mine = await store.ensureSystemPlayingScenario();
    final saved = await store.createScenario('Temp');

    await store.deleteScenario(saved.id);

    expect(store.state.activeScenarioId, mine.id);
    expect(
      await DbModule.scenarioRepo.getScenario(mine.id),
      isNotNull,
      reason: 'the workspace row must survive the delete fallback',
    );
  });

  /// An independent desktop entry has ONE canonical workspace (stored on the
  /// entry row, played by the primary). An extra window plays its own claimed
  /// row so a manual scope play in that window cannot rewrite the primary's
  /// queue. The definition is copied once; the queue is not.
  group('entry workspaces are per window', () {
    Future<PlaybackScenarioStore> storeForSlot(int slot) async {
      AppInstance.debugSetSlot(slot);
      final store = PlaybackScenarioStore();
      await store.ensureReady();
      return store;
    }

    test('an extra window claims its own row and copies the definition',
        () async {
      final primary = await storeForSlot(1);
      final canonical = await primary.ensureEntryWorkspace(null);
      await DbModule.scenarioRepo.addSource(
        scenarioId: canonical.id,
        storageId: 'st',
        path: 'Anime',
        recursive: true,
      );

      final second = await storeForSlot(2);
      final mine = await second.ensureWindowEntryWorkspace(
        entryId: 'e-copy',
        sharedId: canonical.id,
      );

      expect(mine.id, isNot(canonical.id),
          reason: 'the extra window must not play in the canonical row');
      expect(second.claimedEntryWorkspaceId('e-copy'), mine.id);
      expect(
        (await DbModule.scenarioRepo.getSources(mine.id)).map((s) => s.path),
        contains('Anime'),
        reason: 'the private row starts from the shared definition',
      );

      // The copy is one-shot: a later edit on the canonical row stays there.
      await DbModule.scenarioRepo.addSource(
        scenarioId: canonical.id,
        storageId: 'st',
        path: 'Movies',
      );
      expect(
        (await DbModule.scenarioRepo.getSources(mine.id)).map((s) => s.path),
        isNot(contains('Movies')),
      );
    });

    test('the claim is reused, and rebuilt when its row disappears', () async {
      final store = await storeForSlot(2);
      final first = await store.ensureWindowEntryWorkspace(entryId: 'e-reuse');
      final again = await store.ensureWindowEntryWorkspace(entryId: 'e-reuse');
      expect(again.id, first.id, reason: 'a claim must be stable');

      await DbModule.scenarioRepo.purgeInternalWorkspace(first.id);

      final recreated =
          await store.ensureWindowEntryWorkspace(entryId: 'e-reuse');
      expect(recreated.id, isNot(first.id));
      expect(store.claimedEntryWorkspaceId('e-reuse'), recreated.id);
    });

    test('the claim survives a new store (window restart)', () async {
      final first = await storeForSlot(2);
      final mine = await first.ensureWindowEntryWorkspace(entryId: 'e-restart');

      final again = PlaybackScenarioStore();
      await again.ensureReady();

      expect(again.claimedEntryWorkspaceId('e-restart'), mine.id);
      expect(
        (await again.ensureWindowEntryWorkspace(entryId: 'e-restart')).id,
        mine.id,
      );
    });

    test('the primary keeps playing in the canonical row', () async {
      final store = await storeForSlot(1);
      final canonical =
          await store.ensureWindowEntryWorkspace(entryId: 'e-primary');

      expect(store.claimedEntryWorkspaceId('e-primary'), isNull,
          reason: 'the primary never mints a private entry row');
      expect(
        (await store.ensureWindowEntryWorkspace(
          entryId: 'e-primary',
          sharedId: canonical.id,
        ))
            .id,
        canonical.id,
      );
    });

    test('two windows using the SAME entry get different queues', () async {
      final primary = await storeForSlot(1);
      final canonical = await primary.ensureEntryWorkspace(null);
      final second = await storeForSlot(2);
      final mine = await second.ensureWindowEntryWorkspace(
        entryId: 'e-same',
        sharedId: canonical.id,
      );

      expect(mine.id, isNot(canonical.id));
      // The canonical pointer the entry row stores is untouched by window 2.
      expect(canonical.id, isNot(mine.id));
    });
  });

  /// A throwaway (ephemeral) window has no persistent slot, so the rows IT
  /// minted are purged on exit. Canonical entry rows are shared state the entry
  /// row points at — purging them left the entry dangling and its definition
  /// lost on the next activation.
  group('ephemeral window exit purge', () {
    test('keeps the canonical entry rows, drops the window-owned rows',
        () async {
      AppInstance.debugSetEphemeral(true);
      final store = PlaybackScenarioStore();
      await store.ensureReady();

      final fg = await store.ensureEntryWorkspace(null);
      final bg = await store.ensureEntryBackgroundWorkspace(null);
      final claim = await store.ensureWindowEntryWorkspace(entryId: 'e-eph');
      final own = await store.ensureSystemPlayingScenario();

      await PlaybackScenarioStore.debugPurgeEphemeralWorkspaces();

      expect(await DbModule.scenarioRepo.getScenario(fg.id), isNotNull,
          reason: 'the entry canonical foreground row is shared state');
      expect(await DbModule.scenarioRepo.getScenario(bg.id), isNotNull,
          reason: 'the entry canonical background row is shared state');
      expect(await DbModule.scenarioRepo.getScenario(claim.id), isNull,
          reason: 'the private claim row dies with the window');
      expect(await DbModule.scenarioRepo.getScenario(own.id), isNull,
          reason: 'the private SystemPlaying row dies with the window');
    });
  });
}
