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

/// The one-shot latch in `startup_open_request.dart` must mean "this window
/// CONSUMED an intent".
///
/// The storage-gone fallback returns false (so Home runs the generic resume)
/// but used to leave the latch set, so the NEXT call — a remounted Home —
/// reported an already-consumed request that had never been applied, skipping
/// the resume it was supposed to get.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );

  late BuildContext ctx;

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

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      }),
    ));
  }

  testWidgets('a storage-gone intent is NOT consumed, on every call',
      (tester) async {
    // DB + stores are initialized INSIDE the body on purpose: a widget test
    // whose Drift database was created in `setUpAll` hangs at teardown (the
    // automated binding cannot settle a real-IO database opened outside the
    // test zone), and only this case needs them.
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    useStorageStore();
    await useStorageStore().initialized;

    globals.arguments = const NewWindowRequest(
      openStorageId: 'missing-storage',
      openPath: ['Movies'],
    ).toArguments();
    await pumpContext(tester);

    // First call: the row is gone, so nothing was applied -> fall back to the
    // generic resume.
    expect(await applyStartupOpenRequest(ctx), isFalse);
    // Regression: the latch stayed set, so this reported "consumed" and the
    // remounted Home skipped the resume it never got.
    expect(await applyStartupOpenRequest(ctx), isFalse);
  });

  testWidgets('a no-action payload is never consumed either', (tester) async {
    globals.arguments = const NewWindowRequest().toArguments();
    await pumpContext(tester);

    expect(await applyStartupOpenRequest(ctx), isFalse);
    expect(await applyStartupOpenRequest(ctx), isFalse);
  });
}
