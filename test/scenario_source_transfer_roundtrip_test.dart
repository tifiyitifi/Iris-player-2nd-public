import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/settings_transfer/engine/scenario_coder.dart';
import 'package:iris/features/settings_transfer/model/import_resolution.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

import 'helpers/sqlite3_loader.dart';

/// A scenario source must survive export/import WHOLE (its storageId, path,
/// recursive and sourceKind) — a file source must not come back as a folder one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });

  tearDownAll(() async {
    await db.close();
  });

  test('scenario sources round-trip sourceKind', () async {
    final repo = DbModule.scenarioRepo;
    final scenario = await repo.createScenario(name: 'Round Trip');

    await repo.addSource(
      scenarioId: scenario.id,
      storageId: 's1',
      path: 'Anime',
      recursive: true,
    );
    await repo.addSource(
      scenarioId: scenario.id,
      storageId: 's1',
      path: 'Anime/movie.mp4',
      kind: ScenarioSourceKind.file,
    );

    final payload = await ScenarioCoder().encode();
    expect(payload, isNotNull);

    // Re-import over the same scenario (overwrite clears then re-adds sources).
    final results = await ScenarioCoder().importSection(
      payload,
      resolution: TransferResolution.overwrite,
      skipErrors: false,
    );
    expect(results.every((r) => r.ok), isTrue, reason: results.toString());

    final sources = await repo.getSources(scenario.id);
    final byKind = <ScenarioSourceKind, ScenarioSource>{
      for (final s in sources) s.sourceKind: s,
    };
    expect(sources, hasLength(2));
    expect(byKind[ScenarioSourceKind.folder]!.recursive, isTrue);
    expect(byKind[ScenarioSourceKind.folder]!.path, 'Anime');
    expect(byKind[ScenarioSourceKind.file], isNotNull,
        reason: 'a file source must not come back as a folder');
    expect(byKind[ScenarioSourceKind.file]!.path, 'Anime/movie.mp4');
  });

  test('a scenario whose header cannot be written is reported failed',
      () async {
    final repo = DbModule.scenarioRepo;
    final scenario = await repo.createScenario(name: 'Header');
    await repo.addSource(
      scenarioId: scenario.id,
      storageId: 's1',
      path: 'Keep',
      recursive: true,
    );

    final payload = await ScenarioCoder().encode();
    final items = payload!['payload'] as List;
    final header = items.firstWhere(
      (e) => (e as Map)['scenario'] is Map &&
          ((e['scenario'] as Map)['name'] as Object?) == 'Header',
    );
    // `name` still parses, but the header itself is unreadable: the overwrite
    // clears the old sources first, so swallowing this error wrote the content
    // under the stale header and reported ok.
    ((header as Map)['scenario'] as Map).cast<String, dynamic>()['type'] =
        'bogus';

    final results = await ScenarioCoder().importSection(
      payload,
      resolution: TransferResolution.overwrite,
      skipErrors: true,
    );

    final headerResult = results.firstWhere((r) => r.label == 'Header');
    expect(headerResult.ok, isFalse,
        reason: 'a failed header update must fail the scenario: $results');
  });

  test('import overwrite never targets an internal workspace by name',
      () async {
    final repo = DbModule.scenarioRepo;
    // An internal background workspace — its row name is 'Background'.
    final bg = await repo.ensureBackgroundWorkspace();
    await repo.addSource(
      scenarioId: bg.id,
      storageId: 's1',
      path: 'Keep',
      recursive: true,
    );

    // A userSaved scenario that HAPPENS to share the internal row's name.
    final payload = <String, dynamic>{
      'subVersion': 1,
      'payload': [
        {
          'scenario': {
            'id': 'imported',
            'name': 'Background',
            'type': 'userSaved',
          },
          'sources': [
            {
              'storageId': 's2',
              'path': 'Imported',
              'recursive': false,
              'sourceKind': 'folder',
            },
          ],
        },
      ],
    };

    final results = await ScenarioCoder().importSection(
      payload,
      resolution: TransferResolution.overwrite,
      skipErrors: false,
    );
    expect(results.every((r) => r.ok), isTrue, reason: results.toString());

    // The internal workspace is untouched...
    final bgSources = await repo.getSources(bg.id);
    expect(bgSources.map((s) => s.path), contains('Keep'));
    expect(bgSources.any((s) => s.path == 'Imported'), isFalse,
        reason: 'overwrite must not rewrite the internal background row');

    // ...and a NEW userSaved 'Background' was created instead.
    final saved = (await repo.getAllScenarios())
        .where(
            (s) => s.type == ScenarioKind.userSaved && s.name == 'Background')
        .toList();
    expect(saved, hasLength(1));
    expect((await repo.getSources(saved.single.id)).single.path, 'Imported');
  });

  test('an older export without sourceKind still imports as a folder',
      () async {
    final repo = DbModule.scenarioRepo;
    final payload = <String, dynamic>{
      'subVersion': 1,
      'payload': [
        {
          'scenario': {
            'id': 'legacy-scenario',
            'name': 'Legacy Source',
            'type': 'userSaved',
          },
          // Older export: no sourceKind key at all.
          'sources': [
            {'storageId': 's1', 'path': 'Music', 'recursive': true},
          ],
        },
      ],
    };

    final results = await ScenarioCoder().importSection(
      payload,
      resolution: TransferResolution.append,
      skipErrors: false,
    );
    expect(results.every((r) => r.ok), isTrue, reason: results.toString());

    final imported = (await repo.getAllScenarios())
        .firstWhere((s) => s.name == 'Legacy Source');
    final sources = await repo.getSources(imported.id);
    expect(sources, hasLength(1));
    expect(sources.single.sourceKind, ScenarioSourceKind.folder);
    expect(sources.single.path, 'Music');
    expect(sources.single.recursive, isTrue);
  });

  test('a pre-v49 tag source is dropped, never resurrected as a folder',
      () async {
    final repo = DbModule.scenarioRepo;
    final payload = <String, dynamic>{
      'subVersion': 1,
      'payload': [
        {
          'scenario': {
            'id': 'legacy-tag',
            'name': 'Legacy Tag',
            'type': 'userSaved',
          },
          // A pre-v49 export: a concrete tag source and the reserved-tag
          // default both carried sourceKind:'tag' — v49 deleted exactly these
          // rows, and re-importing them as folder sources would resurrect them
          // (pointing at a `tag:<id>`/'' storage that does not exist).
          'sources': [
            {
              'storageId': 'tag:3',
              'path': '/',
              'sourceKind': 'tag',
              'tagId': 3,
              'tagName': 'My Tag',
            },
            {
              'storageId': '',
              'path': '/',
              'sourceKind': 'tag',
              'tagId': null,
            },
            // A real folder source in the same export must still import.
            {'storageId': 's1', 'path': 'Music', 'sourceKind': 'folder'},
          ],
        },
      ],
    };

    final results = await ScenarioCoder().importSection(
      payload,
      resolution: TransferResolution.append,
      skipErrors: false,
    );
    expect(results.every((r) => r.ok), isTrue, reason: results.toString());
    // The drop is REPORTED, not silent: the row carries what was skipped.
    expect(
      results.first.error,
      contains('retired tag source'),
      reason: 'a pre-v49 backup must not read as "had no sources"',
    );

    final imported = (await repo.getAllScenarios())
        .firstWhere((s) => s.name == 'Legacy Tag');
    final sources = await repo.getSources(imported.id);
    expect(sources, hasLength(1),
        reason: 'the retired tag sources must not become folder rows');
    expect(sources.single.sourceKind, ScenarioSourceKind.folder);
    expect(sources.single.path, 'Music');
  });

  test('imported excludes never overwrite an unrelated occupied id', () async {
    final repo = DbModule.scenarioRepo;

    // An unrelated scenario already owns an exclude row (auto-increment id N).
    final other = await repo.createScenario(name: 'Other');
    await repo.addExcludeRule(
      scenarioId: other.id,
      rule: ScenarioExcludeRule(
        id: 0,
        scenarioId: other.id,
        kind: ExcludeRuleKind.media,
        storageId: 's1',
        path: 'keep.mp4',
      ),
    );
    final occupied = (await repo.getExcludeRules(other.id)).single;

    // A foreign export whose exclude carries that very id: the coder serializes
    // the whole rule, so the id is the EXPORTING database's autoincrement.
    final foreign = occupied.toJson()..['id'] = occupied.id;
    final payload = <String, dynamic>{
      'subVersion': 1,
      'payload': [
        {
          'scenario': {
            'id': 'imported-x',
            'name': 'Imported X',
            'type': 'userSaved',
          },
          'excludes': [foreign],
        },
      ],
    };

    final results = await ScenarioCoder().importSection(
      payload,
      resolution: TransferResolution.append,
      skipErrors: false,
    );
    expect(results.every((r) => r.ok), isTrue, reason: results.toString());

    // The unrelated scenario keeps its own rule, untouched.
    final otherRules = await repo.getExcludeRules(other.id);
    expect(otherRules, hasLength(1));
    expect(otherRules.single.scenarioId, other.id);
    expect(otherRules.single.path, 'keep.mp4');

    // The imported scenario owns a rule of its own instead.
    final imported = (await repo.getAllScenarios())
        .firstWhere((s) => s.name == 'Imported X');
    expect(await repo.getExcludeRules(imported.id), hasLength(1));
  });

  test('import drops a repeated source instead of aborting the scenario',
      () async {
    final repo = DbModule.scenarioRepo;
    // A hand-edited / foreign export may repeat a row the UNIQUE key rejects.
    final payload = <String, dynamic>{
      'subVersion': 1,
      'payload': [
        {
          'scenario': {'id': 'dup-src', 'name': 'Dup Src', 'type': 'userSaved'},
          'sources': [
            {'storageId': 's1', 'path': 'A', 'sourceKind': 'folder'},
            {'storageId': 's1', 'path': 'A', 'sourceKind': 'folder'},
          ],
        },
      ],
    };

    final results = await ScenarioCoder().importSection(
      payload,
      resolution: TransferResolution.append,
      skipErrors: false,
    );
    expect(results.every((r) => r.ok), isTrue, reason: results.toString());

    final imported = (await repo.getAllScenarios())
        .firstWhere((s) => s.name == 'Dup Src');
    final sources = await repo.getSources(imported.id);
    expect(sources, hasLength(1), reason: 'the repeated folder collapses');
    expect(sources.single.sourceKind, ScenarioSourceKind.folder);
  });

  test('imported explicit items keep batch fields and never abort the file',
      () async {
    final repo = DbModule.scenarioRepo;
    final payload = <String, dynamic>{
      'subVersion': 1,
      'payload': [
        {
          'scenario': {
            'id': 'explicit-x',
            'name': 'Explicit X',
            'type': 'userSaved',
          },
          'explicitItems': [
            {
              'storageId': 's1',
              'path': 'A/a.mp4',
              'batchId': 'b1',
              'mediaId': 7,
              'addOrder': 1,
              'uiSortKey': 'k1',
            },
            // A repeat — the table's UNIQUE(scenario_id, storage_id, path)
            // rejects it, so it must be collapsed rather than thrown.
            {
              'storageId': 's1',
              'path': 'A/a.mp4',
              'batchId': 'b1',
              'mediaId': 7,
              'addOrder': 2,
              'uiSortKey': 'k1',
            },
            {
              'storageId': 's1',
              'path': 'A/b.mp4',
              'batchId': 'b1',
              'mediaId': 8,
              'addOrder': 3,
              'uiSortKey': 'k2',
            },
          ],
        },
        // Must still be imported even though the row above repeated.
        {
          'scenario': {'id': 'after-x', 'name': 'After X', 'type': 'userSaved'},
          'explicitItems': [
            {'storageId': 's1', 'path': 'A/c.mp4'},
          ],
        },
      ],
    };

    final results = await ScenarioCoder().importSection(
      payload,
      resolution: TransferResolution.append,
      skipErrors: false,
    );
    expect(results.every((r) => r.ok), isTrue, reason: results.toString());

    final imported = (await repo.getAllScenarios())
        .firstWhere((s) => s.name == 'Explicit X');
    final items = await repo.getExplicitItems(imported.id);
    expect(items.map((e) => e.path).toList(), ['A/a.mp4', 'A/b.mp4']);
    expect(items.first.batchId, 'b1');
    expect(items.first.mediaId, 7);
    expect(items.first.uiSortKey, 'k1');
    expect(items.map((e) => e.addOrder).toList(), [1, 2]);

    final after = (await repo.getAllScenarios())
        .firstWhere((s) => s.name == 'After X');
    expect(await repo.getExplicitItems(after.id), hasLength(1),
        reason: 'the scenario after the repeated row still imports');
  });

  test('an imported payload can neither create nor retype an internal scenario',
      () async {
    final repo = DbModule.scenarioRepo;
    final saved = await repo.createScenario(name: 'Editable');
    final payload = await ScenarioCoder().encode();
    expect(payload, isNotNull);

    // Scoped to this file's shared DB: an earlier test legitimately leaves a
    // background workspace behind, so the assertion is "the set did not change".
    final before = (await repo.getAllScenarios())
        .where((s) => s.type != ScenarioKind.userSaved)
        .map((s) => s.id)
        .toSet();

    // `type` is plain JSON in a file the user can edit, and `updateScenario` is
    // an upsert with no type guard, so trusting it is how a hand-edited export
    // becomes a SECOND Background/Playing row — after which `getByType`'s
    // LIMIT 1 and the store's own lookup can pick different rows.
    final items = (payload!['payload'] as List).cast<Map>();
    final scenarioJson =
        (items.first['scenario'] as Map).cast<String, dynamic>();
    expect(scenarioJson.containsKey('type'), isTrue,
        reason: 'the payload does carry the field being forged');
    scenarioJson['type'] = 'background';

    await ScenarioCoder().importSection(
      payload,
      resolution: TransferResolution.overwrite,
      skipErrors: false,
    );

    expect(
      (await repo.getAllScenarios())
          .where((s) => s.type != ScenarioKind.userSaved)
          .map((s) => s.id)
          .toSet(),
      before,
      reason: 'an import must not be able to mint an internal workspace',
    );
    // And the existing saved row kept its own kind instead of being retyped
    // (which would have dropped it out of the saved list).
    expect(
      (await repo.getAllScenarios())
          .singleWhere((s) => s.id == saved.id)
          .type,
      ScenarioKind.userSaved,
    );

    // The append path takes the same fork: a fresh row is a SAVED one.
    await ScenarioCoder().importSection(
      payload,
      resolution: TransferResolution.append,
      skipErrors: false,
    );
    expect(
      (await repo.getAllScenarios())
          .where((s) => s.type != ScenarioKind.userSaved)
          .map((s) => s.id)
          .toSet(),
      before,
    );
  });
}
