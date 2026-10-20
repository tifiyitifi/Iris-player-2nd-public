import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/scenario_playback/actions/drag_drop_play_handler.dart';
import 'package:iris/features/scenario_playback/actions/scan_play_gate.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/db/storage_scope.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/storages/volume_identity.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/store/warning_dialogs.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:path/path.dart' as p;

/// Regression suite for the desktop drop → scan-gate → playback leg.
///
/// A dropped folder that is not fully scanned goes through the scan gate. The
/// scan runs asynchronously, and the original play must survive it. Two real
/// defects made that fail in the field:
///
/// 1. the resume was looked up in ONE global single-slot holder when a scan
///    settled, so a concurrent (or superseded) run settling first consumed or
///    cleared another action's intent — the drop that triggered the scan never
///    played, and only a second drop (folder now `scanDone`) worked;
/// 2. when the dropped root was already covered by a live scan but its DB stamp
///    had not landed yet, the gate offered 立即完整扫描 and then started nothing,
///    silently dropping the play.
///
/// The drop path now auto-plays when its OWN scan settles (no confirmation
/// step), and an already-live run is awaited instead of discarded.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  late Directory tempRoot;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
    PlaybackProviderRegistry.init();
    // Wire the production path/storage-scope resolvers the gateway relies on.
    StorageScope.resolver =
        (id) => useStorageStore().findById(id)?.dataScopeId ?? id;
    StoragePathCodec.baseResolver =
        (id) => useStorageStore().findById(id)?.basePath;
    // Hermetic volume identity (no drive enumeration in tests).
    VolumeIdentity.debugResolver = (_) async => 'test-volume';

    useAppStore();
    await useAppStore().initialized;
    useStorageStore();
    await useStorageStore().initialized;
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    useRecursiveScanStore();
    await useRecursiveScanStore().initialized;
    await runZonedGuarded(() async {
      usePlayQueueStore();
      await usePlayQueueStore().initialized;
    }, (e, st) {});
  });

  tearDownAll(() => db.close());

  setUp(() async {
    debugScanRunner = null;
    tempRoot = Directory.systemTemp.createTempSync('iris_drop_gate_');
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await store.refreshScenarios();
    await store.setActiveScenario(sys.id);
    await store.clearSources(sys.id);
    await store.clearExplicitItems(sys.id);
    await store.clearTemporaryExcludes(sys.id);
    await useAppStore().resetSuppressedWarnings();
    // These two prompts are unrelated to the flow under test; keeping them out
    // of the way makes the "no confirmation for a drop" assertion meaningful.
    await useAppStore().suppressWarning(kWarningScenarioWorkspace);
    await useAppStore().suppressWarning(kWarningDragDropScopeRestricted);
    await useRecursiveScanStore().resetScan();
  });

  tearDown(() {
    debugScanRunner = null;
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  var storageSeq = 0;

  /// Runs a drop through the real handler.
  ///
  /// `testWidgets` runs in a fake-async zone where real `dart:io` async (the
  /// handler's `FileStat.stat`) never completes; reading the stat synchronously
  /// keeps the production path identical while staying deterministic.
  Future<void> dropPaths(
    BuildContext context,
    List<String> paths,
    DragDropZone zone,
  ) {
    return IOOverrides.runZoned(
      () => DragDropPlayHandler.handle(context, paths, zone: zone),
      stat: (path) => Future<FileStat>.value(FileStat.statSync(path)),
    );
  }

  Future<Storage> addStorageFor(Directory root) async {
    final storage = Storage.local(
      id: 'drop-gate-test-${storageSeq++}',
      type: StorageType.internal,
      name: 'Temp',
      basePath: pathConv(root.path),
    );
    await useStorageStore().addStorage(storage);
    return storage;
  }

  Future<void> seedVideo(Storage storage, Directory dir, String name) async {
    final file = File(p.join(dir.path, name))..createSync();
    final segments = pathConv(file.path);
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 'seed:${storage.id}:${segments.join('/')}',
      storageId: storage.id,
      path: segments,
      name: name,
      mediaType: MediaType.video,
    ));
  }

  /// Drains async DB/scene work after a tap (same shape as the scenario tests).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Mounts a host with one button per [actions] entry and captures the
  /// localized gate/scan labels so the test never hardcodes user-facing text.
  Future<Map<String, String>> pumpHost(
    WidgetTester tester,
    Map<String, Future<void> Function(BuildContext)> actions,
  ) async {
    final labels = <String, String>{};
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) {
        final t = getLocalizations(context);
        labels['scanNow'] = t.gate_scan_now;
        labels['scanStart'] = t.scan_start;
        labels['resumeTitle'] = t.gate_resume_title;
        return Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in actions.entries)
                  TextButton(
                    onPressed: () => unawaited(entry.value(context)),
                    child: Text(entry.key),
                  ),
              ],
            ),
          ),
        );
      }),
    ));
    // Deferred l10n delegates load asynchronously.
    await tester.pumpAndSettle();
    return labels;
  }

  testWidgets(
      'a scan-gated drop auto-plays the dropped folder once its scan settles',
      (tester) async {
    final dropDir = Directory(p.join(tempRoot.path, 'dropA'))..createSync();
    final storage = await addStorageFor(tempRoot);
    await seedVideo(storage, dropDir, 'a.mp4');
    await seedVideo(storage, dropDir, 'b.mp4');

    // Fake scan: flip the shared store through its real lifecycle so the gate's
    // settle anchor is exercised, without walking the filesystem.
    debugScanRunner = (service, roots, context) async {
      final scanStore = useRecursiveScanStore();
      await scanStore.startScan(
        storageId: storage.id,
        depthPaths: {0: roots},
      );
      await scanStore.completeScan();
    };

    final labels = await pumpHost(tester, {
      'drop': (context) =>
          dropPaths(context, [dropDir.path], DragDropZone.override),
    });

    await tester.tap(find.text('drop'));
    await settle(tester);
    expect(find.text(labels['scanNow']!), findsOneWidget,
        reason: 'an unscanned folder must gate the drop');
    await tester.tap(find.text(labels['scanNow']!));
    await settle(tester);
    expect(find.text(labels['scanStart']!), findsOneWidget,
        reason: 'scan-now asks for scan options');
    await tester.tap(find.text(labels['scanStart']!));
    await settle(tester);

    final current = await usePlaybackScenarioStore().getCurrentItem();
    expect(current, isNotNull,
        reason: 'the drop must resume into playback after its scan settles');
    expect(current!.media.path.join('/'), contains('dropA/a.mp4'));
    // A drop is an explicit play request: no confirmation step may stand
    // between the finished scan and playback.
    expect(find.text(labels['resumeTitle']!), findsNothing);
  });

  testWidgets(
      'a drop covered by an already-live scan resumes when that run settles',
      (tester) async {
    final dropDir = Directory(p.join(tempRoot.path, 'dropB'))..createSync();
    final storage = await addStorageFor(tempRoot);
    await seedVideo(storage, dropDir, 'a.mp4');

    // A run is already scanning this exact root, but the DB stamp has not landed
    // yet (the gate therefore reports "unscanned" and offers scan-now).
    final scanStore = useRecursiveScanStore();
    final rootPath = '${storage.basePath.join('/')}/dropB';
    await scanStore.startScan(storageId: storage.id, depthPaths: {
      0: [rootPath],
    });

    var runnerCalls = 0;
    debugScanRunner = (service, roots, context) async => runnerCalls++;

    final labels = await pumpHost(tester, {
      'drop': (context) =>
          dropPaths(context, [dropDir.path], DragDropZone.override),
    });

    await tester.tap(find.text('drop'));
    await settle(tester);
    await tester.tap(find.text(labels['scanNow']!));
    await settle(tester);
    // Nothing new is started (the live run already covers the root) and the
    // user is not asked for scan options again.
    expect(find.text(labels['scanStart']!), findsNothing);
    expect(runnerCalls, 0,
        reason: 'a covering live run must not be duplicated');
    expect(await usePlaybackScenarioStore().getCurrentItem(), isNull,
        reason: 'playback waits for the live run to settle');

    // The live run finishes: the drop must resume instead of being swallowed.
    await scanStore.completeScan();
    await settle(tester);

    final current = await usePlaybackScenarioStore().getCurrentItem();
    expect(current, isNotNull,
        reason: 'a live covering scan must not drop the pending play');
    expect(current!.media.path.join('/'), contains('dropB/a.mp4'));
  });

  testWidgets(
      'one action settling first cannot consume another action\'s pending play',
      (tester) async {
    final storage = await addStorageFor(tempRoot);
    final settleA = Completer<void>();
    final settleB = Completer<void>();
    debugScanRunner = (service, roots, context) async {
      final root = roots.single;
      if (root.endsWith('/gateA')) {
        await settleA.future;
      } else {
        await settleB.future;
      }
    };

    var resumedA = 0;
    var resumedB = 0;

    ScenarioSourceSpec specFor(String name) => (
          storageId: storage.id,
          path: '${storage.basePath.join('/')}/$name',
          recursive: true,
          kind: ScenarioSourceKind.folder,
        );

    final labels = await pumpHost(tester, {
      'actionA': (context) => ensureDirsScannedWithAutoPlay(
            context,
            [specFor('gateA')],
            playOnScanNow: () async => resumedA++,
          ),
      'actionB': (context) => ensureDirsScannedWithAutoPlay(
            context,
            [specFor('gateB')],
            playOnScanNow: () async => resumedB++,
          ),
    });

    Future<void> startAction(String button) async {
      await tester.tap(find.text(button));
      await settle(tester);
      await tester.tap(find.text(labels['scanNow']!));
      await settle(tester);
      await tester.tap(find.text(labels['scanStart']!));
      await settle(tester);
    }

    await startAction('actionA');
    await startAction('actionB');
    expect(resumedA, 0);
    expect(resumedB, 0);

    // A's scan settles first. It must resume A only — B's intent lives in B's
    // own closure, not in a shared slot A could read (the old global holder).
    settleA.complete();
    await settle(tester);
    expect(resumedA, 1, reason: 'A resumes when its own scan settles');
    expect(resumedB, 0, reason: 'A must never resume B');

    settleB.complete();
    await settle(tester);
    expect(resumedB, 1,
        reason: 'B must still resume after A settled first (no cross-talk)');
  });
}
