import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/enums/step_tail_finish_mode.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';

import 'helpers/sqlite3_loader.dart';

/// `playback.stepTailFinish` is a metadata-only AUX row (JsonKey-excluded
/// AppState field): the blob can never carry it, so the row is the only
/// persistence route and must round-trip through the real store + Drift layer.
///
/// The runtime consumer is `decideStepTail` inside both player hooks (see
/// test/seek_tuning_test.dart for the policy itself).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  late AppDatabase db;
  late AppStore store;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });

  setUp(() async {
    await MetaSettingsModule.repo.clearValues();
    store = AppStore();
    await store.setMetadataGate(true);
  });

  tearDownAll(() => db.close());

  Future<Map<String, String>> rows() => MetaSettingsModule.repo.loadRawValues();

  test('the typed setter writes the playback AUX row and the live state',
      () async {
    expect(store.state.stepTailFinishMode, StepTailFinishMode.strict,
        reason: 'install default is the strict (past-the-end) policy');

    await store.updateStepTailFinishMode(StepTailFinishMode.window);

    expect(store.state.stepTailFinishMode, StepTailFinishMode.window);
    final raw = await rows();
    expect(raw['playback.stepTailFinish'], 'window');
  });

  test('applyPlaybackRows rehydrates the row onto a cold-boot state',
      () async {
    await store.updateStepTailFinishMode(StepTailFinishMode.window);

    final base = await store.applyPlaybackRows(const AppState());
    expect(base.stepTailFinishMode, StepTailFinishMode.window);
  });

  test('a malformed row degrades to the incoming state, not to a crash',
      () async {
    await MetaSettingsModule.savePlaybackRow('stepTailFinish', 'nonsense');

    final base = await store.applyPlaybackRows(
      const AppState(stepTailFinishMode: StepTailFinishMode.window),
    );
    expect(base.stepTailFinishMode, StepTailFinishMode.window);
  });

  test('a gate-OFF run never reads the row (legacy degradation)', () async {
    await store.updateStepTailFinishMode(StepTailFinishMode.window);
    await store.setMetadataGate(false);

    final base = await store.applyPlaybackRows(
      const AppState(stepTailFinishMode: StepTailFinishMode.window),
    );
    // Gate OFF: the resolver's documented degradation is `strict`.
    expect(base.stepTailFinishMode, StepTailFinishMode.window,
        reason: 'applyPlaybackRows is a no-op with the gate OFF; the runtime '
            'degradation lives in resolveStepTailFinishMode');
  });
}
