import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/model/scan_timing.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';

/// Elapsed / ETA accounting contracts for the recursive scan.
///
/// The store owns a 1 Hz sampler whose clock is injectable, so these tests
/// drive time deterministically instead of sleeping.
void main() {
  late Duration now;
  late RecursiveScanStore store;

  setUp(() async {
    now = Duration.zero;
    store = RecursiveScanStore(clock: () => now);
    // PersistentStore kicks off an async load; wait so onReady() cannot clobber
    // the timeline this test drives.
    await store.initialized;
  });

  tearDown(() async {
    await store.dispose();
  });

  group('elapsed', () {
    test('accumulates active time across ticks', () async {
      await store.startScan(storageId: 's1', depthPaths: {0: ['A']});
      expect(store.timing.value.elapsed, Duration.zero);

      now = const Duration(seconds: 1);
      store.debugTick();
      expect(store.timing.value.elapsed, const Duration(seconds: 1));

      now = const Duration(seconds: 3);
      store.debugTick();
      expect(store.timing.value.elapsed, const Duration(seconds: 3));
    });

    test('paused time is excluded and resumes cleanly', () async {
      await store.startScan(storageId: 's1', depthPaths: {0: ['A']});
      now = const Duration(seconds: 1);
      store.debugTick();
      expect(store.timing.value.elapsed, const Duration(seconds: 1));

      await store.pauseScan();
      now = const Duration(seconds: 5);
      store.debugTick();
      expect(store.timing.value.elapsed, const Duration(seconds: 1),
          reason: 'a paused scan must not accrue time');

      await store.resumeScan();
      now = const Duration(seconds: 6);
      store.debugTick();
      expect(store.timing.value.elapsed, const Duration(seconds: 2));
    });

    test('terminal transitions snapshot elapsed into persisted state', () async {
      await store.startScan(storageId: 's1', depthPaths: {0: ['A']});
      now = const Duration(seconds: 4);
      store.debugTick();

      await store.completeScan();
      expect(store.state.elapsedMs, 4000);
    });

    test('reset zeroes the readout', () async {
      await store.startScan(storageId: 's1', depthPaths: {0: ['A']});
      now = const Duration(seconds: 4);
      store.debugTick();

      await store.resetScan();
      expect(store.timing.value.elapsed, Duration.zero);
      expect(store.state.elapsedMs, 0);
    });
  });

  group('eta', () {
    test('withheld until warmed up, then derived from the smoothed rate',
        () async {
      await store.startScan(storageId: 's1', depthPaths: {0: ['A']});
      // The stored snapshot supplies the tree size (the walk only DISCOVERS
      // directories, it never knows how many are left); a unit test has no
      // database, so state that total explicitly.
      store.debugSetKnownTotalDirs(101);
      // 100 dirs total so `remaining` stays positive.
      await store.updateDepth(
        depth: 0,
        paths: List.generate(100, (i) => 'd$i'),
      );

      now = const Duration(seconds: 1);
      await store.updateProgress(scannedDirs: 10);
      store.debugTick();
      expect(store.timing.value.eta, isNull,
          reason: 'below the warm-up sample count → estimating');

      now = const Duration(seconds: 2);
      await store.updateProgress(scannedDirs: 20);
      store.debugTick();
      // 10 dirs/s, remaining 101 - 20 = 81 → ~8s.
      expect(store.timing.value.eta, isNotNull);
      expect(store.timing.value.eta!.inSeconds, closeTo(8, 2));
    });
  });

  group('probe progress', () {
    test('is surfaced through the timing notifier', () async {
      await store.startScan(storageId: 's1', depthPaths: {0: ['A']});
      store.setProbeProgress(3, 10);
      expect(store.timing.value.probeDone, 3);
      expect(store.timing.value.probeTotal, 10);
      expect(store.timing.value.hasProbe, isTrue);

      // A new directory clears the previous counters.
      store.setProbeProgress(0, 0);
      expect(store.timing.value.hasProbe, isFalse);
    });
  });

  group('ScanTiming', () {
    test('copyWith can explicitly clear a known eta', () {
      const t = ScanTiming(eta: Duration(seconds: 5));
      expect(t.copyWith(clearEta: true).eta, isNull);
    });
  });
}
