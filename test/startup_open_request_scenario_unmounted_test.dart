import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_instance/model/new_window_request.dart';
import 'package:iris/features/app_instance/services/startup_open_request.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/globals.dart' as globals;
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_storage_store.dart';

import 'helpers/sqlite3_loader.dart';

/// A SCENARIO / LIBRARY startup intent flips global stores (active scenario,
/// media library, browser popup). A window that was torn down while the stores
/// were loading can no longer apply it:
///
///   * it must not activate a scenario in the surviving windows, and
///   * it must not report the intent as consumed — the one-shot latch has to
///     stay clear so the caller falls back to the generic startup resume.
///
/// The file / selection branches already had this check; the scenario and
/// library branches did not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );

  setUp(() {
    resetStartupOpenRequestLatch();
    resetStartupOpenRequestSeam();
    globals.arguments = const <String>[];
  });

  tearDown(() {
    resetStartupOpenRequestLatch();
    resetStartupOpenRequestSeam();
    globals.arguments = const <String>[];
  });

  testWidgets('a scenario intent from a dead context is NOT applied',
      (tester) async {
    // The DB lives inside the test body on purpose: a widget test whose Drift
    // database is created in `setUpAll` hangs at teardown (see
    // `startup_open_request_unmounted_test.dart`).
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().ensureReady();
    final keep = await usePlaybackScenarioStore().createScenario('keep');
    final launch = await usePlaybackScenarioStore().createScenario('launch');
    await usePlaybackScenarioStore().setActiveScenario(keep.id);
    useStorageStore();
    await useStorageStore().initialized;

    globals.arguments = NewWindowRequest(scenarioId: launch.id).toArguments();

    BuildContext? ctx;
    Future<void> pumpContext() async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        }),
      ));
    }

    await pumpContext();

    // The window's Home is replaced while the stores were loading.
    debugBeforeApply = () async {
      await tester.pumpWidget(const SizedBox.shrink());
    };

    expect(await applyStartupOpenRequest(ctx!), isFalse,
        reason: 'a dead window consumed nothing');
    expect(
      usePlaybackScenarioStore().state.activeScenarioId,
      keep.id,
      reason: 'the intent belongs to a live window, not a dead one',
    );

    // Latch clear → a remounted Home runs the intent again instead of silently
    // skipping it (the seam still unmounts it here, so the second attempt is
    // again "not consumed" — the latch is what the regression was about).
    await pumpContext();
    expect(await applyStartupOpenRequest(ctx!), isFalse);
  });
}
