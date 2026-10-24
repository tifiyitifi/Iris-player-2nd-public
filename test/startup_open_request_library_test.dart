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

/// A new window spawned for a LIBRARY must verify the row still exists.
///
/// `MediaLibContentStore.setLibrary` accepts any id: adopting a stale one
/// consumed the one-shot intent while opening nothing, so Home skipped the
/// generic startup resume and the window stayed empty. The scenario and storage
/// branches already fall back; the library branch must too.
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

  testWidgets('a library-gone intent is NOT consumed (no empty window)',
      (tester) async {
    // The DB is initialized INSIDE the body: a widget test whose Drift database
    // was created in `setUpAll` hangs at teardown (the automated binding cannot
    // settle a real-IO database opened outside the test zone).
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    useStorageStore();
    await useStorageStore().initialized;

    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      }),
    ));

    globals.arguments =
        const NewWindowRequest(libraryId: 'gone-library').toArguments();

    // Nothing was applied -> fall back to the generic startup resume.
    expect(await applyStartupOpenRequest(ctx), isFalse);
    // Regression: the latch stayed set, so a remounted Home reported a consumed
    // request and skipped the very resume this window should have run.
    expect(await applyStartupOpenRequest(ctx), isFalse);
  });
}
