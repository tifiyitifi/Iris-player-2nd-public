import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/settings_transfer/engine/scenario_coder.dart';
import 'package:iris/features/settings_transfer/services/transfer_service.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

/// A scenario the encoder could not READ must be reported, not written as an
/// empty `payload: []` a reader takes for "the backup had no scenarios".
void main() {
  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });

  tearDownAll(() async {
    await db.close();
  });

  test('a healthy scenarios section carries no error', () async {
    final repo = DbModule.scenarioRepo;
    final s = await repo.createScenario(name: 'Keep');
    await repo.addSource(scenarioId: s.id, storageId: 'st1', path: 'Anime');

    final payload = await ScenarioCoder().encode();
    expect(payload, isNotNull);
    expect(payload!['error'], isNull);
    expect((payload['payload'] as List), hasLength(1));
    expect(failedExportSections({'scenarios': payload}), isEmpty);
  });

  test('a scenario whose sources read fails is reported, not dropped silently',
      () async {
    // Induce an INNER encode failure: the per-scenario sources read throws while
    // the scenarios list itself still resolves (`payload: []` used to be the
    // whole, invisible outcome).
    await db.customStatement('DROP TABLE scenario_sources');

    final payload = await ScenarioCoder().encode();
    expect(payload, isNotNull);
    expect((payload!['payload'] as List), isEmpty);
    expect(payload['error'], isNotNull);
    // The swallowed failure now trips the partial-export confirmation.
    expect(failedExportSections({'scenarios': payload}), ['scenarios']);
  });
}
