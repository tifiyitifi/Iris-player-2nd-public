import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/actions/pending_play_intent.dart';
import 'package:iris/features/scenario_playback/actions/scan_play_gate.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';

/// Regression: the scan gate must only arm a pending play intent when a scan
/// ACTUALLY started. Cancelling the scan-options dialog used to record the
/// intent anyway — the tap was silently dropped, and a later unrelated scan
/// completion popped a spurious "continue playing?" dialog.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
    useAppStore();
    await useAppStore().initialized;
    useStorageStore();
    await useStorageStore().initialized;
  });

  tearDownAll(() => db.close());

  testWidgets(
      'cancelling the scan-options dialog does not arm a pending play intent',
      (tester) async {
    const storageId = 'gate-pending-test';
    await useStorageStore().addStorage(Storage.local(
      id: storageId,
      type: StorageType.internal,
      name: 't',
      basePath: const ['root'],
    ));

    late String scanNowLabel;
    late String scanCancelLabel;
    Future<bool>? gate;

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(builder: (context) {
          final t = getLocalizations(context);
          scanNowLabel = t.gate_scan_now;
          scanCancelLabel = t.scan_cancel;
          return Center(
            child: TextButton(
              onPressed: () {
                gate = ensureDirsScannedWithPendingPlay(
                  context,
                  const <ScenarioSourceSpec>[
                    (
                      storageId: storageId,
                      path: 'unscanned',
                      recursive: true,
                      kind: ScenarioSourceKind.folder,
                    ),
                  ],
                  playOnScanNow: () async {},
                );
              },
              child: const Text('go'),
            ),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle(); // gate dialog
    expect(find.text(scanNowLabel), findsOneWidget);
    await tester.tap(find.text(scanNowLabel));
    await tester.pumpAndSettle(); // scan-options dialog
    expect(find.text(scanCancelLabel), findsWidgets);
    await tester.tap(find.text(scanCancelLabel).last);
    await tester.pumpAndSettle();

    final proceed = await gate!;
    expect(proceed, isFalse);
    expect(usePendingPlayIntentHolder().pending, isNull,
        reason: 'no scan started → no pending play intent may be armed');
  });
}
