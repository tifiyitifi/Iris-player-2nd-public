import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_identity/model/domain/app_identity_entry.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/services/workspace_gc.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/store/kv/secure_kv.dart';

import 'helpers/sqlite3_loader.dart';

/// Workspace GC: reclaim ONLY rows that nothing can ever point at again. The
/// rules are deliberately conservative — deleting a live window's queue is far
/// worse than leaving a stale row on disk.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  late AppDatabase db;
  late ScenarioRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = ScenarioRepository(
      scenariosDao: ScenariosDao(db),
      sourcesDao: ScenarioSourcesDao(db),
      itemsDao: ScenarioExplicitItemsDao(db),
      excludesDao: ScenarioExcludesDao(db),
      statesDao: ScenarioStatesDao(db),
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('sweep', () {
    late DateTime now;
    late DateTime old;

    setUp(() {
      now = DateTime(2026, 10, 1);
      old = now.subtract(const Duration(days: 60));
    });

    Future<String> agedSystemPlaying(String name) async {
      final ws = await repo.createSystemPlayingWorkspace(name: name);
      await repo.updateScenario(ws.copyWith(createdAt: old));
      return ws.id;
    }

    test('reclaims only unclaimed, unreferenced, old internal rows', () async {
      // The oldest systemPlaying row is the primary window's: never reclaimed.
      final primary = await repo.createSystemPlayingWorkspace(name: 'primary');
      await repo.updateScenario(primary.copyWith(createdAt: old));

      final staleWs = await agedSystemPlaying('stale');
      final recent = await repo.createSystemPlayingWorkspace(name: 'recent');
      await repo.updateScenario(
          recent.copyWith(createdAt: now.subtract(const Duration(days: 1))));
      final claimedWs = await agedSystemPlaying('claimed');

      final referenced = await repo.createEntryWorkspace();
      await repo.updateScenario(referenced.copyWith(createdAt: old));
      final staleEntry = await repo.createEntryWorkspace();
      await repo.updateScenario(staleEntry.copyWith(createdAt: old));
      final staleBg = await repo.createEntryBackgroundWorkspace();
      await repo.updateScenario(staleBg.copyWith(createdAt: old));

      // The single default 副音 row and user-saved scenarios are out of scope.
      final defaultBg = await repo.ensureBackgroundWorkspace();
      await repo.updateScenario(defaultBg.copyWith(createdAt: old));
      final saved = await repo.createScenario(name: 'Saved');
      await repo.updateScenario(saved.copyWith(createdAt: old));

      final removed = await WorkspaceGc.sweep(
        repo: repo,
        claimedWorkspaceIds: {claimedWs},
        referencedWorkspaceIds: {referenced.id},
        now: now,
      );

      expect(removed, 3);
      expect(await repo.getScenario(staleWs), isNull);
      expect(await repo.getScenario(staleEntry.id), isNull);
      expect(await repo.getScenario(staleBg.id), isNull);

      expect(await repo.getScenario(primary.id), isNotNull,
          reason: 'the oldest systemPlaying row is the primary workspace');
      expect(await repo.getScenario(recent.id), isNotNull,
          reason: 'a row younger than the age floor is kept');
      expect(await repo.getScenario(claimedWs), isNotNull,
          reason: "a live window's claim keeps its queue alive");
      expect(await repo.getScenario(referenced.id), isNotNull,
          reason: 'a desktop entry still points at this row');
      expect(await repo.getScenario(defaultBg.id), isNotNull,
          reason: 'the single default 副音 row is shared, never reclaimed');
      expect(await repo.getScenario(saved.id), isNotNull,
          reason: 'user-saved scenarios are out of scope');
    });

    test('a row with no date is never reclaimed', () async {
      final ws = await repo.createSystemPlayingWorkspace(name: 'undated');
      await repo.updateScenario(ws.copyWith(createdAt: null));

      final removed = await WorkspaceGc.sweep(
        repo: repo,
        claimedWorkspaceIds: const {},
        referencedWorkspaceIds: const {},
        now: now,
      );

      expect(removed, 0);
      expect(await repo.getScenario(ws.id), isNotNull);
    });

    test('the purge removes the definition rows with the workspace', () async {
      final ws = await repo.createEntryWorkspace();
      await repo.updateScenario(ws.copyWith(createdAt: old));
      await repo.addSource(
          scenarioId: ws.id, storageId: 'st', path: 'Anime', recursive: true);

      await WorkspaceGc.sweep(
        repo: repo,
        claimedWorkspaceIds: const {},
        referencedWorkspaceIds: const {},
        now: now,
      );

      expect(await repo.getScenario(ws.id), isNull);
      expect(await repo.getSources(ws.id), isEmpty,
          reason: 'definition rows must not outlive their workspace');
    });
  });

  group('claim collection', () {
    test('reads every slot prefix through the shared store', () async {
      final kv = MemoryKvStore();
      await kv.write(
        key: 'workspace_claims',
        value: jsonEncode({'entry:a:fg': 'id-1'}),
      );
      await kv.write(
        key: 'playback_scenario_active_id',
        value: jsonEncode({'instanceWorkspaceId': 'id-2'}),
      );
      await kv.write(
        key: 's2.workspace_claims',
        value: jsonEncode({'entry:a:fg': 'id-3', 'entry:a:bg': 'id-4'}),
      );
      await kv.write(
        key: 's3.playback_scenario_active_id',
        value: jsonEncode({'instanceWorkspaceId': 'id-5'}),
      );

      final claims = await WorkspaceGc.collectClaims(kv, maxSlots: 4);

      expect(claims, {'id-1', 'id-2', 'id-3', 'id-4', 'id-5'});
    });

    test('corrupt payloads never abort the sweep', () async {
      final kv = MemoryKvStore();
      await kv.write(key: 's2.workspace_claims', value: 'not json');
      await kv.write(key: 's3.playback_scenario_active_id', value: '[]');
      await kv.write(
        key: 's4.workspace_claims',
        value: jsonEncode({'entry:a:fg': 'id-9'}),
      );

      final claims = await WorkspaceGc.collectClaims(kv, maxSlots: 4);

      expect(claims, {'id-9'});
    });
  });

  test('an entry keeps both of its workspace rows', () {
    final entry = const AppIdentityEntry(
      id: 'e1',
      name: 'Anime',
      workspaceScenarioId: 'ws-fg',
      backgroundWorkspaceScenarioId: 'ws-bg',
    );

    expect(WorkspaceGc.entryWorkspaceRefs([entry]), {'ws-fg', 'ws-bg'});
    expect(WorkspaceGc.entryWorkspaceRefs(const []), isEmpty);
  });
}
