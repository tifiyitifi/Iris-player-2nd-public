import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/commands/scenario_commands.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_shared_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/dao/app_meta_dao.dart';

/// Seeds the durable state a real queue-index build leaves behind for
/// [scenarioId]: the build-meta row, the `app_meta` signature/use stamps the
/// store writes, and the shared-index blob keyed by the build id.
Future<int> _seedQueueIndex(AppDatabase db, String scenarioId) async {
  final indexDao = ScenarioQueueIndexDao(db);
  final buildId = await indexDao.nextBuildId();
  await ScenarioSharedIndexDao(db).write(
    buildId,
    baseCount: 1,
    slices: Uint8List(0),
    accepted: Uint8List(0),
    absorbed: Uint8List(0),
    groupRows: Uint8List(0),
    placeholders: Uint8List(0),
    occurrence: Uint8List(0),
    flags: Uint8List(0),
  );
  await indexDao.writeBuildMeta(
    scenarioId: scenarioId,
    buildId: buildId,
    baseCount: 1,
    entryCount: 1,
  );
  await AppMetaDao(db)
      .write(ScenarioQueueIndexDao.signatureKey(scenarioId), 'sig');
  await AppMetaDao(db).write(ScenarioQueueIndexDao.usedKey(scenarioId), '1');
  return buildId;
}

/// The derived index of a deleted scenario must be gone WITH the row: build
/// meta, the `app_meta` bookkeeping keys and (through `gcStaleGenerations`) the
/// blob that only that build owned.
Future<void> _expectQueueIndexPurged(AppDatabase db, String scenarioId) async {
  final indexDao = ScenarioQueueIndexDao(db);
  expect(await indexDao.currentBuildId(scenarioId), 0);
  expect(await indexDao.materializedScenarioIds(), isNot(contains(scenarioId)));
  expect(
      await AppMetaDao(db).read(ScenarioQueueIndexDao.signatureKey(scenarioId)),
      isNull);
  expect(await AppMetaDao(db).read(ScenarioQueueIndexDao.usedKey(scenarioId)),
      isNull);
}

/// Independent desktop entries own their OWN workspace row
/// (`ScenarioKind.entryWorkspace`) in the shared database, so switching
/// entries never disturbs each other or the default SystemPlaying context.
void main() {
  group('entry workspace isolation', () {
    late AppDatabase db;
    late ScenarioRepository repo;

    setUp(() async {
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

    test('each independent entry gets a distinct workspace row', () async {
      final sys = await repo.ensureSystemPlayingScenario();
      final a = await repo.createEntryWorkspace();
      final b = await repo.createEntryWorkspace();

      expect(a.type, ScenarioKind.entryWorkspace);
      expect(b.type, ScenarioKind.entryWorkspace);
      expect(a.version, isNull);
      expect({sys.id, a.id, b.id}.length, 3);
    });

    test('workspaces are not deletable through the scenario UI', () async {
      final sys = await repo.ensureSystemPlayingScenario();
      final ws = await repo.createEntryWorkspace();
      expect(await repo.deleteScenario(sys.id), isFalse);
      expect(await repo.deleteScenario(ws.id), isFalse);

      final saved = await repo.createScenario(name: 'Saved');
      expect(await repo.deleteScenario(saved.id), isTrue);
    });

    test('deleteEntryWorkspace removes the row and its records', () async {
      final ws = await repo.createEntryWorkspace();
      await repo.addSource(
        scenarioId: ws.id,
        storageId: 'st1',
        path: 'Anime',
        recursive: true,
      );

      await repo.deleteEntryWorkspace(ws.id);

      expect(await repo.getScenario(ws.id), isNull);
      expect(await repo.getSources(ws.id), isEmpty);
    });

    test('deleteEntryWorkspace drops its derived queue index', () async {
      final live = await repo.ensureSystemPlayingScenario();
      final ws = await repo.createEntryWorkspace();
      await _seedQueueIndex(db, ws.id);
      final liveBuild = await _seedQueueIndex(db, live.id);

      await repo.deleteEntryWorkspace(ws.id);

      await _expectQueueIndexPurged(db, ws.id);
      expect(await ScenarioQueueIndexDao(db).currentBuildId(live.id), liveBuild,
          reason: 'an unrelated live generation must survive the purge');
      expect(await ScenarioSharedIndexDao(db).count(), 1,
          reason: 'only the deleted scenario\'s blob may go');
    });

    test('userSaved filter (the scenario list) excludes workspaces', () async {
      final sys = await repo.ensureSystemPlayingScenario();
      final ws = await repo.createEntryWorkspace();
      final saved = await repo.createScenario(name: 'Saved');

      final all = await repo.getAllScenarios();
      final listed = all
          .where((s) => s.type == ScenarioKind.userSaved)
          .map((s) => s.id)
          .toList();

      expect(all.map((s) => s.id), containsAll([sys.id, ws.id, saved.id]));
      expect(listed, [saved.id]);
    });

    test('overriding an entry workspace never touches SystemPlaying', () async {
      final sys = await repo.ensureSystemPlayingScenario();
      final ws = await repo.createEntryWorkspace();
      final saved = await repo.createScenario(name: 'Anime');

      await repo.addSource(
        scenarioId: sys.id,
        storageId: 'st1',
        path: 'Default',
      );
      await repo.addSource(
        scenarioId: saved.id,
        storageId: 'st1',
        path: 'Anime',
        recursive: true,
      );

      await ScenarioCommands.override(
        workspace: ws,
        source: saved,
        repo: repo,
      );

      final sysPaths = (await repo.getSources(sys.id)).map((s) => s.path);
      final wsPaths = (await repo.getSources(ws.id)).map((s) => s.path);

      expect(sysPaths, contains('Default'));
      expect(sysPaths, isNot(contains('Anime')));
      expect(wsPaths, contains('Anime'));
      expect(wsPaths, isNot(contains('Default')));
    });
  });

  /// Every context owns its own fg/bg PAIR: the default context pairs
  /// SystemPlaying with the single `background` row, and each independent entry
  /// pairs its `entryWorkspace` with its own `entryBackground` row.
  group('background workspace pairing', () {
    late AppDatabase db;
    late ScenarioRepository repo;

    setUp(() async {
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

    test('the default background is a single distinct row', () async {
      final sys = await repo.ensureSystemPlayingScenario();
      final bg = await repo.ensureBackgroundWorkspace();
      final again = await repo.ensureBackgroundWorkspace();

      expect(bg.type, ScenarioKind.background);
      expect(bg.version, isNull);
      expect(again.id, bg.id, reason: 'ensureBackgroundWorkspace is idempotent');
      expect(bg.id, isNot(sys.id));
    });

    test('each independent entry gets a distinct entryBackground row', () async {
      final fgA = await repo.createEntryWorkspace();
      final fgB = await repo.createEntryWorkspace();
      final bgA = await repo.createEntryBackgroundWorkspace();
      final bgB = await repo.createEntryBackgroundWorkspace();
      final def = await repo.ensureBackgroundWorkspace();

      expect(bgA.type, ScenarioKind.entryBackground);
      expect(
        {fgA.id, fgB.id, bgA.id, bgB.id, def.id}.length,
        5,
        reason: 'fg/bg workspaces never share a row',
      );
      expect([bgA.id, bgB.id], isNot(contains(def.id)));
    });

    test('deleteEntryBackgroundWorkspace removes the row and its records',
        () async {
      final bg = await repo.createEntryBackgroundWorkspace();
      await repo.addSource(
        scenarioId: bg.id,
        storageId: 'st1',
        path: 'Anime',
        recursive: true,
      );

      await repo.deleteEntryBackgroundWorkspace(bg.id);

      expect(await repo.getScenario(bg.id), isNull);
      expect(await repo.getSources(bg.id), isEmpty);
    });

    test('deleteEntryBackgroundWorkspace drops its derived queue index',
        () async {
      final bg = await repo.createEntryBackgroundWorkspace();
      await _seedQueueIndex(db, bg.id);

      await repo.deleteEntryBackgroundWorkspace(bg.id);

      await _expectQueueIndexPurged(db, bg.id);
      expect(await ScenarioSharedIndexDao(db).count(), 0);
    });

    test('the saved-scenario list excludes background rows', () async {
      final def = await repo.ensureBackgroundWorkspace();
      final entryBg = await repo.createEntryBackgroundWorkspace();
      final saved = await repo.createScenario(name: 'Saved');

      final all = await repo.getAllScenarios();
      final listed = all
          .where((s) => s.type == ScenarioKind.userSaved)
          .map((s) => s.id)
          .toList();

      expect(all.map((s) => s.id), containsAll([def.id, entryBg.id, saved.id]));
      expect(listed, [saved.id]);
    });
  });
}
