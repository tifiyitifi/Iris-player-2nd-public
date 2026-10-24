import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_instance/model/new_window_request.dart';
import 'package:iris/features/app_instance/services/startup_open_request.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/globals.dart' as globals;
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_storage_store.dart';

import 'helpers/sqlite3_loader.dart';

/// An intent that was NOT applied must never report itself as consumed.
///
/// The one-shot latch in `startup_open_request.dart` means "this window
/// consumed an intent". Every failure path used to leave it set and returned
/// true, so the caller skipped the generic startup resume AND a remounted
/// Home kept reporting "consumed" — the window stayed empty forever.
///
/// Everything happens in ONE case: a second widget case would build a fresh
/// store whose bootstrap needs real IO, which never settles inside the widget
/// test's fake clock.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );

  BuildContext? ctx;

  setUp(() {
    resetStartupOpenRequestLatch();
    resetStartupOpenRequestSeam();
    globals.arguments = const <String>[];
    ctx = null;
  });

  tearDown(() {
    resetStartupOpenRequestLatch();
    resetStartupOpenRequestSeam();
    globals.arguments = const <String>[];
    ctx = null;
  });

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      }),
    ));
    // The l10n delegates load asynchronously: the home widget (and with it the
    // context) only exists once they resolved.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final c = ctx;
      if (c != null && AppLocalizations.of(c) != null) return;
    }
    fail('the localization delegates never resolved');
  }

  testWidgets('a failed apply is NOT consumed and never activates a scenario',
      (tester) async {
    // The DB lives inside the test body on purpose: a widget test whose Drift
    // database was created in `setUpAll` hangs at teardown (see
    // `startup_open_request_unmounted_test.dart`).
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    final store = usePlaybackScenarioStore();
    await store.ensureReady();
    useStorageStore();
    await useStorageStore().initialized;
    final before = store.state.activeScenarioId;

    globals.arguments = const NewWindowRequest(
      scenarioId: 'scenario-that-never-applies',
    ).toArguments();
    await pumpContext(tester);

    // The seam runs INSIDE the apply block, so a throwing seam reproduces the
    // "the apply blew up" path deterministically.
    debugBeforeApply = () async => throw StateError('apply boom');

    final first = applyStartupOpenRequest(ctx!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text('The new window could not start playback'),
      findsOneWidget,
      reason: 'the user must be told that the intent failed',
    );
    await tester.tap(find.text('OK'));
    // The dialog's exit animation must run out before its future completes.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(await first, isFalse,
        reason: 'a failed apply must fall back to the generic resume');

    // The latch must be clear: a remounted Home still reports "not consumed",
    // so it runs the resume it never got. The seam is removed, so the retry
    // ends in the "unknown scenario" branch instead of failing again.
    debugBeforeApply = null;
    // Legacy mode keeps the retry inside the store: the scenario-driven
    // resume would open media, which no widget test can do.
    final app = useAppStore();
    await app.initialized;
    app.set(app.state.copyWith(useLegacyStoragePersistence: true));
    final second = applyStartupOpenRequest(ctx!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(store.state.activeScenarioId, before,
        reason: 'an unknown scenario must not become the active one');
    expect(await second, isFalse);
  });
}
