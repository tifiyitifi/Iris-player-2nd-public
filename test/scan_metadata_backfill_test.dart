import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/media_library/scan/service/metadata_backfill_service.dart';
import 'package:iris/features/media_library/scan/service/metadata_wait_policy.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';

/// The two-phase contract:
/// 1. a directory's rows are written BEFORE any metadata is probed, so a folder
///    is listable/playable while metadata is still filling in;
/// 2. metadata is filled by a DB-driven, resumable pass that touches only rows
///    which still lack it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  final modifiedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  Storage localStorage(String id) => Storage.local(
        id: id,
        type: StorageType.internal,
        name: 'Local',
        basePath: const ['E:/library'],
      );

  FileItem video(String name) => FileItem(
        storageId: 'ignored',
        storageType: StorageType.internal,
        name: name,
        uri: 'E:/library/a/$name',
        path: ['a', name],
        size: 100,
        lastModified: modifiedAt,
        type: ContentType.video,
      );

  MediaNode seededFile({
    required String storageId,
    required String name,
    int? durationMs,
    int? width,
    int? height,
  }) =>
      MediaNode.file(
        id: '$storageId:a/$name',
        storageId: storageId,
        path: ['a', name],
        parentPath: 'a',
        pathDepth: 2,
        name: name,
        mediaType: MediaType.video,
        sizeInBytes: 100,
        modifiedAt: modifiedAt,
        durationMs: durationMs,
        width: width,
        height: height,
      );

  Future<BuildContext> contextOf(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ),
    );
    return ctx;
  }

  testWidgets('scan writes rows before probing them', (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const storageId = 'two-phase';
      var rowWasPresentDuringProbe = false;
      int? probedCount;

      final probe = _RecordingProbe(
        onProbe: () async {
          final row = await DbModule.mediaNodesDao
              .getByPath(storageId, 'a/v.mp4');
          rowWasPresentDuringProbe = row != null;
        },
      );

      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: localStorage(storageId),
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        probeService: probe,
        listDir: (_, __) async => FileListResult([video('v.mp4')]),
      );

      await service.scanRecursively(rootPaths: const ['a'], context: ctx);

      expect(rowWasPresentDuringProbe, isTrue,
          reason: 'the row must be visible before metadata probing');
      probedCount = probe.probed.length;
      expect(probedCount, 1);

      final row = await DbModule.mediaNodesDao.getByPath(storageId, 'a/v.mp4');
      final node = MediaNodeDriftAdapter.fromDb(row!);
      expect(node.maybeMap(file: (f) => f.durationMs, orElse: () => null),
          12345);
    });
  });

  testWidgets('a rescan RE-PROBES rows that already have a duration: a '
      're-encoded file must not keep the stale value', (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const storageId = 'rescan-heal';
      // The row was probed before the file was re-encoded: size/mtime heal from
      // the listing, but the duration can only come back from a probe.
      await DbModule.mediaNodesDao.batchUpsert([
        seededFile(storageId: storageId, name: 'v.mp4', durationMs: 5000)
            .toCompanion(),
      ]);

      final probe = _RecordingProbe(durationMs: 12345);
      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: localStorage(storageId),
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        probeService: probe,
        listDir: (_, __) async => FileListResult([video('v.mp4')]),
      );

      await service.scanRecursively(rootPaths: const ['a'], context: ctx);

      expect(probe.probed, isNotEmpty,
          reason: 'the pass the user waited for re-verifies metadata instead of '
              'only filling gaps');
      final row = await DbModule.mediaNodesDao.getByPath(storageId, 'a/v.mp4');
      final node = MediaNodeDriftAdapter.fromDb(row!);
      expect(node.maybeMap(file: (f) => f.durationMs, orElse: () => null),
          12345);
    });
  });

  testWidgets('backfill only probes rows that still lack a duration',
      (tester) async {
    await tester.runAsync(() async {
      const storageId = 'backfill';
      await DbModule.mediaNodesDao.batchUpsert([
        seededFile(storageId: storageId, name: 'known.mp4', durationMs: 5000)
            .toCompanion(),
        seededFile(storageId: storageId, name: 'miss1.mp4').toCompanion(),
        seededFile(storageId: storageId, name: 'miss2.mp4').toCompanion(),
      ]);

      final probe = _RecordingProbe(durationMs: 9000);
      final service = MetadataBackfillService(
        dao: DbModule.mediaNodesDao,
        batchSize: 1, // force keyset paging across several round trips
      );

      final outcome = await service.run(
        storageId: storageId,
        probe: probe,
        rootPath: 'a',
      );

      expect(probe.probed, hasLength(2),
          reason: 'the row that already knows its duration is not re-probed');
      expect(outcome.visited, 2);
      expect(outcome.written, 2);

      for (final name in ['miss1.mp4', 'miss2.mp4']) {
        final row =
            await DbModule.mediaNodesDao.getByPath(storageId, 'a/$name');
        final node = MediaNodeDriftAdapter.fromDb(row!);
        expect(node.maybeMap(file: (f) => f.durationMs, orElse: () => null),
            9000);
      }

      // Idempotent: a second pass finds nothing to do.
      final again = await service.run(storageId: storageId, probe: probe);
      expect(again.visited, 0);
      expect(probe.probed, hasLength(2));
    });
  });

  testWidgets('includeExisting verifies known rows, and an agreeing probe is '
      'not written back', (tester) async {
    await tester.runAsync(() async {
      const storageId = 'backfill-verify';
      await DbModule.mediaNodesDao.batchUpsert([
        seededFile(
          storageId: storageId,
          name: 'known.mp4',
          durationMs: 5000,
          width: 1920,
          height: 1080,
        ).toCompanion(),
      ]);

      final service = MetadataBackfillService(
          dao: DbModule.mediaNodesDao, batchSize: 8);

      // The probe agrees with the row: it must still be PROBED (that is how a
      // poisoned row is discovered) but must not produce a write.
      final same = _RecordingProbe(durationMs: 5000);
      final unchanged = await service.run(
        storageId: storageId,
        probe: same,
        includeExisting: true,
      );
      expect(same.probed, hasLength(1),
          reason: 'includeExisting widens the work list to known rows');
      expect(unchanged.visited, 1);
      expect(unchanged.resolved, 1,
          reason: 'resolved counts a usable probe, not only a changed row');
      expect(unchanged.written, 0,
          reason: 'an agreeing probe must not churn the row');

      // The probe disagrees (the file was re-encoded): the row is healed.
      final changed = _RecordingProbe(durationMs: 9000);
      final healed = await service.run(
        storageId: storageId,
        probe: changed,
        includeExisting: true,
      );
      expect(healed.written, 1);
      final row = await DbModule.mediaNodesDao.getByPath(storageId, 'a/known.mp4');
      final node = MediaNodeDriftAdapter.fromDb(row!);
      expect(node.maybeMap(file: (f) => f.durationMs, orElse: () => null), 9000);
    });
  });

  testWidgets('backfill keeps partial results when cancelled', (tester) async {
    await tester.runAsync(() async {
      const storageId = 'backfill-cancel';
      await DbModule.mediaNodesDao.batchUpsert([
        for (var i = 0; i < 4; i++)
          seededFile(storageId: storageId, name: 'c$i.mp4').toCompanion(),
      ]);

      final probe = _RecordingProbe(durationMs: 777);
      final service = MetadataBackfillService(
          dao: DbModule.mediaNodesDao, batchSize: 1);

      final outcome = await service.run(
        storageId: storageId,
        probe: probe,
        isCancelled: () => probe.probed.length >= 2,
      );

      expect(outcome.cancelled, isTrue);
      expect(outcome.written, greaterThan(0));
      expect(outcome.written, lessThan(4),
          reason: 'cancelling leaves the remaining rows for the next pass');
    });
  });

  /// Serves [count] playable files in any directory, so the scan itself writes
  /// the rows the metadata pass then fills.
  Future<FileListResult> Function(Storage, List<String>) listing(int count) =>
      (_, __) async =>
          FileListResult([for (var i = 0; i < count; i++) video('s$i.mp4')]);

  testWidgets(
      'probe targets restore the storage base: media_nodes paths are relative',
      (tester) async {
    await tester.runAsync(() async {
      const storageId = 'backfill-base';
      // The production wiring (app_startup) resolves the base from the storage
      // store; rows themselves are stored WITHOUT it (schema v38).
      StoragePathCodec.baseResolver =
          (id) => id == storageId ? const ['E:'] : null;
      addTearDown(() => StoragePathCodec.baseResolver = (_) => null);

      await DbModule.mediaNodesDao.batchUpsert([
        seededFile(storageId: storageId, name: 'v.mp4').toCompanion(),
      ]);

      final probe = _RecordingProbe(durationMs: 4242);
      final service = MetadataBackfillService(dao: DbModule.mediaNodesDao);
      await service.run(storageId: storageId, probe: probe, rootPath: 'a');

      // '/a/v.mp4' (no drive) is a nonexistent file on Windows: every probe
      // then "succeeds" with an empty result, the rows keep NULL durations and
      // the wait before playback burns its whole budget for nothing.
      expect(probe.probed.single, 'E:/a/v.mp4');
    });
  });

  testWidgets('a probe that never resolves anything stops after one sample',
      (tester) async {
    await tester.runAsync(() async {
      const storageId = 'backfill-stall';
      await DbModule.mediaNodesDao.batchUpsert([
        for (var i = 0; i < 200; i++)
          seededFile(storageId: storageId, name: 'st$i.mp4').toCompanion(),
      ]);

      final probe = _RecordingProbe(durationMs: 0);
      final service = MetadataBackfillService(
        dao: DbModule.mediaNodesDao,
        batchSize: 32,
      );

      final outcome = await service.run(
        storageId: storageId,
        probe: probe,
        stallSample: kMetadataStallSample,
      );

      expect(outcome.stalled, isTrue,
          reason: 'a probe that cannot read this content must not be retried '
              'until the budget runs out');
      expect(outcome.visited, kMetadataStallSample);
      expect(probe.probed, hasLength(kMetadataStallSample));
    });
  });

  testWidgets('a dead probe opens the play gate instead of spending the wait',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const storageId = 'wait-stall';
      final scanStore = RecursiveScanStore();
      await scanStore.initialized;

      // Grab the run's own settle completer from inside the pass: at this point
      // the scan is in flight, so `playableSettled` is the live one (not the
      // already-completed value a caller sees before a run starts).
      Future<void>? settled;
      final probe = _RecordingProbe(
        durationMs: 0,
        // Block body on purpose: an arrow would RETURN the future, and an async
        // callback awaits what it returns — deadlocking on the very completer it
        // is supposed to observe.
        onProbe: () async {
          settled ??= scanStore.playableSettled;
        },
      );

      final service = RecursiveScanService(
        storage: localStorage(storageId),
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        probeService: probe,
        listDir: listing(200),
      );

      await service.scanRecursively(rootPaths: const ['a'], context: ctx);

      expect(settled, isNotNull, reason: 'the metadata pass must have run');
      var released = false;
      settled!.then((_) => released = true);
      await Future<void>.delayed(Duration.zero);
      expect(released, isTrue,
          reason: 'the play gate must open even with unusable metadata');
      expect(probe.probed, hasLength(kMetadataStallSample),
          reason: 'the dead probe must not run over the whole list');

      // ... and no background repetition behind playback either.
      final probed = probe.probed.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(probe.probed, hasLength(probed));
    });
  });

  /// A run whose background pass is still in flight when it returns: the pass a
  /// newer run has to be able to supersede.
  Future<({
    RecursiveScanStore store,
    _RecordingProbe probe,
    Completer<void> gate,
  })> startBackgroundPass(
    BuildContext ctx, {
    required String storageId,
    required int files,
  }) async {
    final gate = Completer<void>();
    // Park the FIRST probe call so the pass is provably mid-batch when the
    // superseding run starts; the rest of the batch runs after [gate] opens.
    var parked = false;
    final probe = _RecordingProbe(
      durationMs: 8000,
      onProbe: () async {
        if (parked) return;
        parked = true;
        await gate.future;
      },
    );
    final scanStore = RecursiveScanStore();
    await scanStore.initialized;
    final service = RecursiveScanService(
      storage: localStorage(storageId),
      scanStore: scanStore,
      nodesDao: DbModule.mediaNodesDao,
      sourcesDao: DbModule.mediaLibSourcesDao,
      probeService: probe,
      // The pass runs AFTER completeScan, which is exactly the shape that used
      // to outlive its run.
      backgroundProbe: true,
      listDir: listing(files),
    );
    await service.scanRecursively(rootPaths: const ['a'], context: ctx);
    await _waitFor(() => probe.probed.isNotEmpty);
    return (store: scanStore, probe: probe, gate: gate);
  }

  testWidgets('a newer run on the SAME storage stops the superseded pass',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const storageId = 'supersede-same';
      const files = 40; // > one 32-file batch, so a stop is observable
      final run = await startBackgroundPass(
        ctx,
        storageId: storageId,
        files: files,
      );

      // A second run on the same storage/root takes the store over: its own
      // pass re-examines exactly these rows, so the stale one is redundant.
      await run.store
          .startScan(storageId: storageId, depthPaths: {0: ['a']});
      run.gate.complete();

      await _waitFor(() => run.probe.probed.length >= 32);
      // Give a stale pass that ignores the token time to reach the next batch.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(run.probe.probed.length, lessThan(files),
          reason: 'the superseded pass must stop at the batch boundary instead '
              'of racing the run that now owns the storage');
    });
  });

  testWidgets('a newer run on ANOTHER storage does not discard its work',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const storageId = 'supersede-other';
      const files = 40;
      final run = await startBackgroundPass(
        ctx,
        storageId: storageId,
        files: files,
      );

      // Disjoint rows: cancelling this pass would abandon metadata no later
      // pass covers (the chained multi-storage batch).
      await run.store
          .startScan(storageId: 'elsewhere', depthPaths: {0: ['b']});
      run.gate.complete();

      await _waitFor(() => run.probe.probed.length >= files);
      expect(run.probe.probed.length, files);
    });
  });

  test('a hung probe batch cannot outlive the wait budget', () async {
    const storageId = 'hung-probe';
    await DbModule.mediaNodesDao.batchUpsert([
      seededFile(storageId: storageId, name: 'hang.mp4').toCompanion(),
    ]);

    // The isolate pool's own ceiling is 30 s (one worker stuck on a cold or odd
    // file). The pass the user waits for only promised ~4 s, so the batch must
    // be bounded by what is LEFT of that budget instead of inheriting the pool
    // timeout — otherwise "play in ~1 s" becomes "play in 30 s".
    final probe = _RecordingProbe(onProbe: () => Completer<void>().future);
    final service =
        MetadataBackfillService(dao: DbModule.mediaNodesDao, batchSize: 8);
    final watch = Stopwatch()..start();
    final outcome = await service.run(
      storageId: storageId,
      probe: probe,
      rootPath: 'a',
      budget: const Duration(milliseconds: 200),
    );
    watch.stop();

    expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'the wait budget must bound a single batch, not the probe '
            'pool 30 s timeout');
    expect(outcome.resolved, 0);
    expect(outcome.timedOut, isTrue);
  });
}

/// Polls [condition] until it holds, failing the test on timeout. Used instead
/// of a fixed delay so the assertions stay timing-independent.
Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _RecordingProbe implements MediaProbeService {
  _RecordingProbe({
    this.durationMs = 12345,
    Future<void> Function()? onProbe,
  }) : _onProbe = onProbe;

  final int durationMs;
  final Future<void> Function()? _onProbe;
  final List<String> probed = [];

  @override
  Future<ProbeResult> probeFile(String target) async {
    probed.add(target);
    await _onProbe?.call();
    return ProbeResult(durationMs: durationMs, width: 1920, height: 1080);
  }

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async {
    final out = <ProbeResult>[];
    for (final t in targets) {
      out.add(await probeFile(t));
    }
    return out;
  }
}
