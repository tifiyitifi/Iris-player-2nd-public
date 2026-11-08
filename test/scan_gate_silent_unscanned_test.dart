import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
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

/// A playback action on a folder that was merely never indexed must not ask
/// anything: no "scan fully now?" gate, no probe-options dialog, and no
/// "continue playing?" confirmation afterwards. The tap was the explicit
/// request, the scan it starts covers exactly that root, and the play resumes
/// as soon as the rows exist.
///
/// The run is also PLAYBACK-ORIGINATED, so its progress panel is marked quiet
/// (no completion countdown) and the batch dismisses it once it settles.
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

  late RecursiveScanStore store;

  setUp(() {
    store = useRecursiveScanStore();
  });

  tearDown(() {
    debugScanRunner = null;
  });

  tearDownAll(() => db.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('an unscanned folder play scans silently and resumes once',
      (tester) async {
    const storageId = 'gate-silent-unscanned';
    await useStorageStore().addStorage(Storage.local(
      id: storageId,
      type: StorageType.internal,
      name: 't',
      basePath: const ['root'],
    ));
    // No media_nodes row at all → "never scanned".

    late String scanNowLabel;
    late String scanStartLabel;
    late String cancelLabel;
    Future<bool>? gate;
    var scans = 0;
    var resumeCalls = 0;

    debugScanRunner = (service, roots, context) async {
      scans++;
      await store.startScan(
        storageId: storageId,
        depthPaths: {0: roots},
        quietCompletion: service.playbackOriginated,
      );
      // The production seam the gate relies on for its resume anchor.
      service.onScanStarted?.call();
      expect(store.quietCompletion, isTrue,
          reason: 'a playback-originated run must not linger once settled');
      await store.completeScan();
    };

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(builder: (context) {
          final t = getLocalizations(context);
          scanNowLabel = t.gate_scan_now;
          scanStartLabel = t.scan_start;
          cancelLabel = t.scan_cancel;
          return Center(
            child: TextButton(
              onPressed: () {
                gate = ensureDirsScannedWithPendingPlay(
                  context,
                  const <ScenarioSourceSpec>[
                    (
                      storageId: storageId,
                      path: 'never-visited',
                      recursive: true,
                      kind: ScenarioSourceKind.folder,
                    ),
                  ],
                  playOnScanNow: () async => resumeCalls++,
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
    await settle(tester);

    // Nothing asked: not the gate, not the probe options, not a resume prompt.
    expect(find.text(scanNowLabel), findsNothing);
    expect(find.text(scanStartLabel), findsNothing);
    expect(find.text(cancelLabel), findsNothing);
    expect(scans, 1, reason: 'the silent increment must still scan the root');

    final proceed = await gate!;
    expect(proceed, isFalse, reason: 'the scan took over this play action');

    await settle(tester);
    expect(resumeCalls, 1, reason: 'the play must resume exactly once');

    // The batch dismissed the quiet panel: no countdown left running.
    expect(store.state.phase, ScanPhase.idle);
  });
}
