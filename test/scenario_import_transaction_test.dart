import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/settings_transfer/engine/scenario_coder.dart';
import 'package:iris/features/settings_transfer/model/import_resolution.dart';
import 'package:iris/features/settings_transfer/services/transfer_service.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

/// An overwrite import CLEARS a scenario's sources / explicit items / excludes
/// before rewriting them. Without a transaction, a `skipErrors: false` abort in
/// between left the previous definition destroyed and the new one half written.
/// These tests pin that a failed overwrite changes NOTHING.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });
  tearDownAll(() => db.close());

  setUp(() async {
    // Each test owns the table contents.
    for (final s in await DbModule.scenarioRepo.getAllScenarios()) {
      await DbModule.scenarioRepo.deleteScenario(s.id);
    }
  });

  /// Payload shape the coder's `encode()` produces for ONE scenario.
  Map<String, dynamic> overwritePayload({
    required String name,
    required List<Map<String, dynamic>> sources,
    List<dynamic> explicitItems = const [],
  }) =>
      {
        'subVersion': 1,
        'payload': [
          {
            'scenario': {'id': 'imported', 'name': name, 'type': 'userSaved'},
            'sources': sources,
            'explicitItems': explicitItems,
            'excludes': const <Map<String, dynamic>>[],
          },
        ],
      };

  test('a failed overwrite leaves the previous definition intact', () async {
    final repo = DbModule.scenarioRepo;
    final existing = await repo.createScenario(name: 'X');
    await repo.addSource(
      scenarioId: existing.id,
      storageId: 's',
      path: 'keep-dir',
      recursive: true,
      kind: ScenarioSourceKind.folder,
    );
    await repo.addExplicitItems(
      scenarioId: existing.id,
      items: const [
        (
          storageId: 's',
          path: 'keep.mp4',
          batchId: null,
          mediaId: null,
          uiSortKey: null,
        ),
      ],
    );

    final results = await ScenarioCoder().importSection(
      overwritePayload(
        name: 'X',
        sources: [
          // A valid source lands inside the transaction ...
          {
            'storageId': 's',
            'path': 'new-dir',
            'recursive': false,
            'sourceKind': 'folder',
          },
          // ... then a malformed one aborts it (a non-string storageId).
          {'storageId': 123},
        ],
      ),
      resolution: TransferResolution.overwrite,
      skipErrors: false,
    );

    expect(results.single.ok, isFalse, reason: 'the row reports the failure');

    final sources = await repo.getSources(existing.id);
    expect(
      sources.map((s) => s.path),
      contains('keep-dir'),
      reason: 'the ORIGINAL source must survive a failed overwrite',
    );
    expect(sources.map((s) => s.path), isNot(contains('new-dir')));

    final items = await repo.getExplicitItems(existing.id);
    expect(items.map((e) => e.path), contains('keep.mp4'));
  });

  test('tolerant mode skips a malformed explicit item, not the scenario',
      () async {
    final repo = DbModule.scenarioRepo;

    final results = await ScenarioCoder().importSection(
      overwritePayload(
        name: 'Tolerant',
        sources: [
          {
            'storageId': 's',
            'path': 'keep-dir',
            'recursive': true,
            'sourceKind': 'folder',
          },
        ],
        // A non-map row is what a hand-edited / foreign export can carry. With
        // skipErrors=true it must cost the ITEM, never the scenario (sources,
        // excludes and the scenario row all used to roll back with it).
        explicitItems: ['not-a-map'],
      ),
      resolution: TransferResolution.overwrite,
      skipErrors: true,
    );

    final result = results.single;
    expect(result.ok, isTrue);
    expect(result.error, contains('malformed'));

    final imported = (await repo.getAllScenarios())
        .firstWhere((s) => s.name == 'Tolerant');
    final sources = await repo.getSources(imported.id);
    expect(sources.map((s) => s.path), contains('keep-dir'));
  });

  test('an unknown section is skipped, not fatal to later sections', () async {
    final raw = jsonEncode({
      'format': 2,
      'sections': {
        // A section this build cannot read (a newer export). It must be
        // reported and skipped — aborting here silently dropped every section
        // that followed it.
        'futureSection': {'anything': true},
        'scenarios': overwritePayload(
          name: 'AfterUnknown',
          sources: [
            {
              'storageId': 's',
              'path': 'kept',
              'recursive': true,
              'sourceKind': 'folder',
            },
          ],
        ),
      },
    });

    final report = await TransferService.importFromJson(
      raw,
      resolutions: const {},
      skipErrors: false,
    );

    final unknown = report.items
        .where((i) => i.section == 'futureSection')
        .single;
    expect(unknown.ok, isFalse);
    expect(unknown.error, contains('ignored'));

    final scenarios = report.items
        .where((i) => i.section == 'scenarios')
        .single;
    expect(scenarios.ok, isTrue, reason: scenarios.error);
    expect(
      (await DbModule.scenarioRepo.getAllScenarios())
          .any((s) => s.name == 'AfterUnknown'),
      isTrue,
      reason: 'the section after the unknown one must still import',
    );
  });

  test('a successful overwrite replaces the definition', () async {
    final repo = DbModule.scenarioRepo;
    final existing = await repo.createScenario(name: 'Y');
    await repo.addSource(
      scenarioId: existing.id,
      storageId: 's',
      path: 'old-dir',
      recursive: true,
      kind: ScenarioSourceKind.folder,
    );

    final results = await ScenarioCoder().importSection(
      overwritePayload(
        name: 'Y',
        sources: [
          {
            'storageId': 's',
            'path': 'new-dir',
            'recursive': false,
            'sourceKind': 'folder',
          },
        ],
      ),
      resolution: TransferResolution.overwrite,
      skipErrors: false,
    );

    expect(results.single.ok, isTrue);
    final sources = await repo.getSources(existing.id);
    expect(sources.map((s) => s.path), contains('new-dir'));
    expect(sources.map((s) => s.path), isNot(contains('old-dir')));
  });
}
