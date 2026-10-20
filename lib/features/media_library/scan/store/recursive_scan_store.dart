import 'dart:async';
import 'dart:convert';

import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/model/scan_timing.dart';
import 'package:iris/features/media_library/scan/service/scan_eta_estimator.dart';
import 'package:iris/features/meta_settings/bridge/scan_state_bridge.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/persistent_store.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/logger.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);

const _scanStateKey = 'recursive_scan_state';

/// Monotonic time source for scan elapsed accounting.
///
/// Injectable so tests can drive it deterministically; the default is backed by
/// a single long-lived [Stopwatch] (monotonic — immune to wall-clock changes).
typedef MonotonicClock = Duration Function();

class RecursiveScanStore extends PersistentStore<RecursiveScanState> {
  RecursiveScanStore({MonotonicClock? clock})
      : _clock = clock ?? _defaultMonotonic,
        super(const RecursiveScanState());

  static final Stopwatch _monotonic = Stopwatch()..start();
  static Duration _defaultMonotonic() => _monotonic.elapsed;

  final MonotonicClock _clock;

  final KvStore _storage = getKvStore();

  Timer? _saveDebounce;
  bool _disposed = false;

  /// Live elapsed/ETA readout for the progress overlays.
  ///
  /// Transient by design: it ticks every second, so persisting it would churn
  /// the KV store for zero durability value. The coarse snapshot lives in
  /// [RecursiveScanState.elapsedMs].
  final ValueNotifier<ScanTiming> timing =
      ValueNotifier<ScanTiming>(const ScanTiming.idle());

  Timer? _timingTimer;
  Duration? _lastTickAt;

  /// Active milliseconds accumulated for the current run (paused time excluded).
  int _elapsedMs = 0;

  final ScanEtaEstimator _eta = ScanEtaEstimator();

  /// Completer behind [scanSettled] for the run currently in flight. Null while
  /// no one waits; cleared (and completed) on every settle.
  Completer<void>? _settledCompleter;

  int _probeDone = 0;
  int _probeTotal = 0;

  /// When true a higher-level orchestrator (e.g. the scenario-source refresh
  /// batch) owns the user-facing progress UI, so the generic
  /// [ScanProgressOverlay] must yield. Transient: never persisted, and it does
  /// not alter the scan lifecycle — the same [RecursiveScanService] still
  /// drives phase/progress.
  final ValueNotifier<bool> overlaySuppressed = ValueNotifier<bool>(false);

  /// Hands the progress UI to / back from an external orchestrator.
  void setOverlaySuppressed(bool value) => overlaySuppressed.value = value;

  // --- Actions ---

  Future<void> startScan({
    required String storageId,
    required Map<int, List<String>> depthPaths,
    int carryElapsedMs = 0,
  }) async {
    // A new run supersedes whatever was in flight: release its waiters first so
    // they can re-evaluate (they would otherwise wait on a run that is gone).
    _settleScan();
    final previousDelay = state.autoCloseDelay;
    set(const RecursiveScanState(
      phase: ScanPhase.scanning,
    ));
    set(state.copyWith(
      storageId: storageId,
      depthPaths: depthPaths,
      currentDepth: 0,
      progress: 0.0,
      totalDirs: 0,
      scannedDirs: 0,
      currentScanningPath: null,
      elapsedMs: carryElapsedMs,
      error: null,
      paused: false,
      autoCloseDelay: previousDelay,
    ));
    // Resume continuity: a resumed scan keeps counting from where it stopped.
    _startTiming(carryMs: carryElapsedMs);
    // Persist queue for 50w resume (best-effort).
    try {
      await DbModule.scanQueueDao.clearForStorage(storageId);
      for (final e in depthPaths.entries) {
        if (e.value.isNotEmpty) {
          await DbModule.scanQueueDao.enqueue(storageId, e.value, e.key);
        }
      }
    } catch (_) {}
    await _countAndSave();
  }

  Future<void> updateDepth({
    required int depth,
    required List<String> paths,
  }) async {
    final newDepthPaths = Map<int, List<String>>.from(state.depthPaths);
    final existing = newDepthPaths[depth] ?? [];
    // Cap in-memory map to avoid 50w OOM: keep first 20000 entries, rest via queue table.
    const cap = 20000;
    final totalBefore = newDepthPaths.values.fold<int>(0, (a, b) => a + b.length);
    if (totalBefore < cap) {
      newDepthPaths[depth] = [...existing, ...paths];
      set(state.copyWith(depthPaths: newDepthPaths));
    } else {
      // Spill to queue only, keep map truncated for UI fraction.
      set(state.copyWith(depthPaths: newDepthPaths));
    }
    try {
      final sid = state.storageId;
      if (sid != null) {
        await DbModule.scanQueueDao.enqueue(sid, paths, depth);
      }
    } catch (_) {}
    await _countAndScheduleSave();
  }

  Future<void> updateProgress({
    double? progress,
    String? currentScanningPath,
    int? scannedDirs,
  }) async {
    set(state.copyWith(
      progress: progress ?? state.progress,
      currentScanningPath: currentScanningPath,
      scannedDirs: scannedDirs ?? state.scannedDirs,
    ));
    // Progress is high-frequency UI state — debounce persistence so the
    // player timer (1s) and DB writes never contend on the KV store.
    _scheduleSave();
  }

  Future<void> addProgress(double delta) async {
    final newProgress = (state.progress + delta).clamp(0.0, 1.0);
    set(state.copyWith(progress: newProgress));
    _scheduleSave();
  }

  Future<void> advanceDepth() async {
    final nextDepth = state.currentDepth + 1;
    set(state.copyWith(currentDepth: nextDepth));
    await _countAndScheduleSave();
  }

  Future<void> setDepth(int depth) async {
    set(state.copyWith(currentDepth: depth));
    await _countAndScheduleSave();
  }

  Future<void> completeScan() async {
    _saveDebounce?.cancel();
    // Clear queue on success.
    try {
      final sid = state.storageId;
      if (sid != null) await DbModule.scanQueueDao.clearForStorage(sid);
    } catch (_) {}
    _stopTiming();
    set(state.copyWith(
      phase: ScanPhase.done,
      progress: 1.0,
      currentScanningPath: null,
      elapsedMs: _elapsedMs,
      paused: false,
    ));
    _settleScan();
    await save(state);
  }

  Future<void> failScan(String error) async {
    _saveDebounce?.cancel();
    _stopTiming();
    set(state.copyWith(
      phase: ScanPhase.error,
      error: error,
      currentScanningPath: null,
      elapsedMs: _elapsedMs,
      paused: false,
    ));
    _settleScan();
    await save(state);
  }

  /// Stop the scan — terminal state. Service loop exits.
  /// Overlay shows auto-close countdown with only a close button.
  Future<void> stopScan() async {
    _saveDebounce?.cancel();
    _stopTiming();
    set(state.copyWith(
      phase: ScanPhase.stopped,
      currentScanningPath: null,
      elapsedMs: _elapsedMs,
      paused: false,
    ));
    _settleScan();
    await save(state);
  }

  /// Mark a queue entry done (called per directory by service for 50w resume).
  Future<void> markQueueDone(String path) async {
    try {
      final sid = state.storageId;
      if (sid == null) return;
      await DbModule.scanQueueDao.markStatus(sid, path, 'done');
    } catch (_) {}
  }

  Future<void> markQueueError(String path) async {
    try {
      final sid = state.storageId;
      if (sid == null) return;
      await DbModule.scanQueueDao.markStatus(sid, path, 'error');
    } catch (_) {}
  }

  Future<void> pauseScan() async {
    // Freeze the accounting window so the paused gap is never counted.
    _lastTickAt = _clock();
    set(state.copyWith(paused: true));
    _emitTiming();
  }

  Future<void> resumeScan() async {
    _lastTickAt = _clock();
    set(state.copyWith(paused: false));
    _emitTiming();
  }

  /// Deep-probe counters for the directory currently being probed.
  ///
  /// The service reports these instead of concatenating a (unlocalizable)
  /// progress string into [RecursiveScanState.currentScanningPath].
  void setProbeProgress(int done, int total) {
    _probeDone = done;
    _probeTotal = total;
    _emitTiming();
  }

  Future<void> updateAutoCloseDelay(double delay) async {
    // Same clamp as SettingDef(scan.autoCloseDelay).clampMin/clampMax — the
    // parity test asserts the two stay in lockstep.
    set(state.copyWith(autoCloseDelay: delay.clamp(0.0, 15.0)));
    await save(state);
    await _mirrorPreference();
  }

  Future<void> resetScan() async {
    try {
      final sid = state.storageId;
      if (sid != null) await DbModule.scanQueueDao.clearForStorage(sid);
    } catch (_) {}
    _stopTiming();
    _elapsedMs = 0;
    _probeDone = 0;
    _probeTotal = 0;
    timing.value = const ScanTiming.idle();
    set(const RecursiveScanState());
    _settleScan();
    await save(state);
  }

  // --- Helpers ---

  bool get isScanning => state.phase == ScanPhase.scanning;
  bool get isIdle =>
      state.phase == ScanPhase.idle ||
      state.phase == ScanPhase.done ||
      state.phase == ScanPhase.error;
  bool get hasIncompleteScan =>
      state.phase == ScanPhase.error;

  /// A future that completes when the scan run currently in flight settles
  /// (`done` / `stopped` / `error`, or an explicit [resetScan]).
  ///
  /// A caller that was told "a scan is already refreshing your root" awaits THIS
  /// instead of starting a duplicate run — the scan gate's action-resume anchor.
  /// With no run in flight it returns an already-completed future, so a caller
  /// can await unconditionally.
  Future<void> get scanSettled {
    if (!isScanning) return Future<void>.value();
    return (_settledCompleter ??= Completer<void>()).future;
  }

  /// Releases every [scanSettled] waiter. Called on each terminal phase and
  /// when a NEW run supersedes the current one — a superseded run must never
  /// leave a waiter hanging forever.
  void _settleScan() {
    final completer = _settledCompleter;
    _settledCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  List<String> get currentDepthPaths =>
      state.depthPaths[state.currentDepth] ?? [];

  // --- Timing (elapsed / ETA) ---

  /// Seeds the live clock from a resumed run and starts the 1 Hz sampler.
  void _startTiming({int carryMs = 0}) {
    _elapsedMs = carryMs;
    _lastTickAt = _clock();
    _eta.reset();
    _probeDone = 0;
    _probeTotal = 0;
    _timingTimer?.cancel();
    _timingTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _emitTiming();
  }

  void _stopTiming() {
    _timingTimer?.cancel();
    _timingTimer = null;
    _lastTickAt = null;
  }

  /// Accumulates active time, feeds the rate estimator and refreshes the UI.
  ///
  /// Only 1 Hz: the elapsed/ETA text is decorative and must not rebuild the
  /// overlay on every progress event (AXTree flood, see the overlay docs).
  void _tick() {
    final now = _clock();
    final last = _lastTickAt;
    if (last != null && !state.paused) {
      final delta = (now - last).inMilliseconds;
      if (delta > 0) _elapsedMs += delta;
    }
    _lastTickAt = now;
    _eta.sample(state.scannedDirs, Duration(milliseconds: _elapsedMs));
    _emitTiming();
  }

  void _emitTiming() {
    timing.value = ScanTiming(
      elapsed: Duration(milliseconds: _elapsedMs),
      eta: _eta.eta(state.scannedDirs, state.totalDirs),
      probeDone: _probeDone,
      probeTotal: _probeTotal,
    );
  }

  /// Test seam: drives one sampler tick without waiting on a real timer.
  @visibleForTesting
  void debugTick() => _tick();

  /// Counts total dirs across all depths and saves (immediate, for init).
  Future<void> _countAndSave() async {
    int total = 0;
    for (final entry in state.depthPaths.entries) {
      total += entry.value.length;
    }
    try {
      final sid = state.storageId;
      if (sid != null && total >= 20000) {
        final qTotal = await DbModule.scanQueueDao.countAll(sid);
        if (qTotal > total) total = qTotal;
      }
    } catch (_) {}
    set(state.copyWith(totalDirs: total));
    await save(state);
  }

  Future<void> _countAndScheduleSave() async {
    int total = 0;
    for (final entry in state.depthPaths.entries) {
      total += entry.value.length;
    }
    // For 50w, depthPaths is capped; supplement with queue count.
    try {
      final sid = state.storageId;
      if (sid != null && total >= 20000) {
        final qTotal = await DbModule.scanQueueDao.countAll(sid);
        if (qTotal > total) total = qTotal;
      }
    } catch (_) {}
    set(state.copyWith(totalDirs: total));
    _scheduleSave();
  }

  void _scheduleSave() {
    if (_disposed) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () {
      if (_disposed) return;
      // Fire-and-forget debounced write; errors logged inside save().
      save(state);
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _saveDebounce?.cancel();
    _stopTiming();
    timing.dispose();
    overlaySuppressed.dispose();
    await super.dispose();
  }

  // --- Persistence ---

  /// Seeds the live clock from a persisted snapshot.
  ///
  /// Deliberately does NOT auto-start the sampler: after a process restart the
  /// service loop is not running until the scan is explicitly resumed, so a
  /// ticking clock would fabricate elapsed time. The overlay shows the frozen
  /// persisted value until then.
  @override
  void onReady() {
    _elapsedMs = state.elapsedMs;
    _emitTiming();
  }

  /// Metadata mirror for the scan PREFERENCE fields (gate ON only).
  ///
  /// Preference rows are auxiliary (`scan.` namespace): they upsert single
  /// keys and must never touch the `app.` snapshot. The runtime progress
  /// part of the state deliberately never mirrors.
  Future<void> _mirrorPreference() async {
    try {
      if (!MetaSettingsModule.ready) return;
      if (!useAppStore().state.useMetadataSettings) return;
      await MetaSettingsModule.persistAuxRow(
        ScanStateBridge.key,
        jsonEncode(state.autoCloseDelay),
      );
    } catch (e) {
      areaKeyLog.e('Scan preference mirror failed: $e');
    }
  }

  @override
  Future<RecursiveScanState?> load() async {
    try {
      final json = await _storage.read(key: _scanStateKey);
      var loaded = json == null
          ? null
          : RecursiveScanState.fromJson(
              jsonDecode(json) as Map<String, dynamic>);

      // Gate ON → the DB row is authoritative for preferences; overlay it.
      // Error containment: any failure keeps the blob value.
      if (useAppStore().state.useMetadataSettings &&
          MetaSettingsModule.ready) {
        try {
          final rows = await MetaSettingsModule.repo.loadRawValues();
          loaded = ScanStateBridge.apply(rows, loaded ?? state);
        } catch (e) {
          areaKeyLog.e('Scan preference row read failed: $e');
        }
      }
      // 50w resume: if blob depthPaths was truncated, hydrate from queue table.
      try {
        final sid = loaded?.storageId;
        if (loaded != null && sid != null && loaded.phase == ScanPhase.scanning) {
          final pending = await DbModule.scanQueueDao.getPendingPaths(sid);
          if (pending.isNotEmpty) {
            final fromQueue = await DbModule.scanQueueDao.loadDepthPaths(sid);
            if (fromQueue.isNotEmpty) {
              loaded = loaded.copyWith(depthPaths: fromQueue);
            }
          }
        }
      } catch (_) {}
      return loaded;
    } catch (e) {
      areaKeyLog.e('RecursiveScanStore.load error: $e');
      return null;
    }
  }

  @override
  Future<void> save(RecursiveScanState state) async {
    try {
      final json = jsonEncode(state.toJson());
      await _storage.write(key: _scanStateKey, value: json);
    } catch (e) {
      areaKeyLog.e('RecursiveScanStore.save error: $e');
    }
  }
}

RecursiveScanStore useRecursiveScanStore() =>
    create(() => RecursiveScanStore());
