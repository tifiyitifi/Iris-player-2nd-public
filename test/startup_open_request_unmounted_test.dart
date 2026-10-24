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

/// A window that is torn down WHILE the startup intent is being applied must
/// not report the intent as consumed.
///
/// The intent could not be applied (the file row / selection never reached the
/// player), so the one-shot latch must stay clear: the caller then falls back
/// to the generic startup resume instead of leaving a window that neither
/// played nor opened anything.
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

  testWidgets('an intent whose context dies mid-flight is NOT consumed',
      (tester) async {
    // DB + stores are initialized INSIDE the body: a widget test whose Drift
    // database was created in `setUpAll` hangs at teardown (the automated
    // binding cannot settle a real-IO database opened outside the test zone).
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().ensureReady();
    useStorageStore();
    await useStorageStore().initialized;

    globals.arguments = const NewWindowRequest(
      startFile: NewWindowFile(
        storageId: 's1',
        name: 'clip.mp4',
        uri: '/media/clip.mp4',
        path: ['clip.mp4'],
      ),
    ).toArguments();
    await pumpContext(tester);

    // The window's Home is torn down while the stores are loading: the intent
    // can no longer be applied.
    debugBeforeApply = () async {
      await tester.pumpWidget(const SizedBox.shrink());
    };

    expect(await applyStartupOpenRequest(ctx), isFalse,
        reason: 'an unapplied intent must not report "consumed"');
    // Regression: the latch stayed set, so a remounted Home skipped the
    // generic resume it never got.
    await pumpContext(tester);
    expect(await applyStartupOpenRequest(ctx), isFalse);
  });
}
