import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
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

/// `playback.dropAutoScan` (ON by default) turns the whole scan gate silent for
/// the desktop drop: even an errored / stale root scans without a dialog, and
/// the drop resumes once the scan settles.
///
/// Failures must never be silent, though: every gate-started run is
/// playback-originated (quiet), and a quiet run deliberately keeps the overlay's
/// error dialog closed. The batch therefore reports its own failure exactly once
/// — and a batch where NOTHING became playable must not resume the play (that
/// would stack a misleading "nothing to play" prompt on the error).
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

  /// Seeds one errored directory: a status the gate treats as a real decision
  /// when asking, so seeing no dialog proves the silent-all bypass.
  Future<void> seedErrored(String storageId, List<String> path) async {
    await DbModule.mediaNodesDao.insertNode(MediaNode.directory(
      id: 'seed:$storageId:${path.join('/')}',
      storageId: storageId,
      path: path,
      name: path.last,
    ));
    await DbModule.mediaNodesDao.markDirScanError(storageId, path.join('/'));
  }

  Future<void> pumpGate(
    WidgetTester tester, {
    required List<ScenarioSourceSpec> specs,
    required void Function(Future<bool>) onStart,
    required void Function() onResume,
  }) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(builder: (context) {
          return Center(
            child: TextButton(
              onPressed: () {
                onStart(ensureDirsScannedWithAutoPlay(
                  context,
                  specs,
                  ask: false,
                  playOnScanNow: () async => onResume(),
                ));
              },
              child: const Text('go'),
            ),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('an errored root scans silently and resumes once', (tester) async {
    const storageId = 'gate-silent-all-ok';
    await useStorageStore().addStorage(Storage.local(
      id: storageId,
      type: StorageType.internal,
      name: 't',
      basePath: const ['root'],
    ));
    await seedErrored(storageId, const ['errored']);

    var scans = 0;
    var resumes = 0;
    Future<bool>? gate;

    debugScanRunner = (service, roots, context) async {
      scans++;
      await store.startScan(
        storageId: storageId,
        depthPaths: {0: roots},
        quietCompletion: service.playbackOriginated,
      );
      service.onScanStarted?.call();
      await store.completeScan();
    };

    await pumpGate(
      tester,
      specs: const <ScenarioSourceSpec>[
        (
          storageId: storageId,
          path: 'errored',
          recursive: true,
          kind: ScenarioSourceKind.folder,
        ),
      ],
      onStart: (g) => gate = g,
      onResume: () => resumes++,
    );
    await tester.tap(find.text('go'));
    await settle(tester);

    // No gate dialog, no probe explainer, no failure prompt.
    expect(find.byType(AlertDialog), findsNothing);
    expect(scans, 1, reason: 'the silent drop still scans the errored root');
    expect(await gate!, isFalse, reason: 'the scan took over the play');

    await settle(tester);
    expect(resumes, 1, reason: 'a playable scan resumes the drop exactly once');
  });

  testWidgets('a totally failed scan prompts once and never resumes',
      (tester) async {
    const storageId = 'gate-silent-all-fail';
    await useStorageStore().addStorage(Storage.local(
      id: storageId,
      type: StorageType.internal,
      name: 't',
      basePath: const ['root'],
    ));
    await seedErrored(storageId, const ['errored']);

    var resumes = 0;
    Future<bool>? gate;

    debugScanRunner = (service, roots, context) async {
      await store.startScan(
        storageId: storageId,
        depthPaths: {0: roots},
        quietCompletion: service.playbackOriginated,
      );
      service.onScanStarted?.call();
      await store.failScan('boom');
    };

    await pumpGate(
      tester,
      specs: const <ScenarioSourceSpec>[
        (
          storageId: storageId,
          path: 'errored',
          recursive: true,
          kind: ScenarioSourceKind.folder,
        ),
      ],
      onStart: (g) => gate = g,
      onResume: () => resumes++,
    );
    await tester.tap(find.text('go'));
    await settle(tester);

    expect(await gate!, isFalse);
    await settle(tester);

    // Exactly one prompt, and it explains the failure.
    expect(find.text('Scan failed'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);
    expect(resumes, 0,
        reason: 'a fully failed batch must not stack a "nothing to play" '
            'prompt on the scan error');
  });

  testWidgets('a partially failed batch resumes and still reports the failure',
      (tester) async {
    const storageId = 'gate-silent-all-partial';
    await useStorageStore().addStorage(Storage.local(
      id: storageId,
      type: StorageType.internal,
      name: 't',
      basePath: const ['root'],
    ));
    await seedErrored(storageId, const ['failRoot']);
    await seedErrored(storageId, const ['okRoot']);

    var resumes = 0;
    Future<bool>? gate;

    debugScanRunner = (service, roots, context) async {
      await store.startScan(
        storageId: storageId,
        depthPaths: {0: roots},
        quietCompletion: service.playbackOriginated,
      );
      service.onScanStarted?.call();
      if (roots.first.contains('failRoot')) {
        await store.failScan('boom');
      } else {
        await store.completeScan();
      }
    };

    await pumpGate(
      tester,
      specs: const <ScenarioSourceSpec>[
        (
          storageId: storageId,
          path: 'failRoot',
          recursive: true,
          kind: ScenarioSourceKind.folder,
        ),
        (
          storageId: storageId,
          path: 'okRoot',
          recursive: true,
          kind: ScenarioSourceKind.folder,
        ),
      ],
      onStart: (g) => gate = g,
      onResume: () => resumes++,
    );
    await tester.tap(find.text('go'));
    await settle(tester);

    expect(await gate!, isFalse);
    await settle(tester);

    expect(resumes, 1, reason: 'the successful root still plays');
    expect(find.text('Scan failed'), findsOneWidget,
        reason: 'the failed root is reported once, not hidden by the resume');
  });
}
