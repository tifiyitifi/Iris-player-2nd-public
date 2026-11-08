import 'dart:async';
import 'dart:convert';

import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/model/scan_timing.dart';
import 'package:iris/features/media_library/scan/service/scan_eta_estimator.dart';
import 'package:iris/features/media_library/scan/service/scan_profiler.dart';
import 'package:iris/features/meta_settings/bridge/scan_state_bridge.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/persistent_store.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);

const _scanStateKey = 'recursive_scan_state';

/// Monotonic time source for scan elapsed accounting.
///
/// Injectable so tests can drive it deterministically; the default is backed by
/// a single long-lived [Stopwatch] (monotonic 鈥?immune to wall-clock changes).
typedef MonotonicClock = Duration Function();

class RecursiveScanStore extends PersistentStore<RecursiveScanState> {
  RecursiveScanStore({MonotonicClock? clock})
      : _clock = clock ?? _defaultMonotonic,
        super(const RecursiveScanState());

  static final Stopwatch _monotonic = Stopwatch()..start();
  static Duration _defaultMonotonic() => _monotonic.elapsed;

  /// Window-scoped scan snapshot: the KV key is session-scoped, so a second
  /// window's scan view never shows (or rewrites) the first one's progress.

  final MonotonicClock _clock;

  final KvStore _storage = getSessionKvStore();

  /// Phase timings for the run in flight, attached by
  /// [RecursiveScanService] so the state writes it triggers land in the same
  /// breakdown as listing / statements / probing.
  ///
  /// On Android the snapshot write is not a detail: it is a JSON encode plus an
  /// EncryptedSharedPreferences commit, and it used to carry the whole resume
  /// map (up to 1.5 MB) every 300 ms.
  ScanProfiler? profiler;

  Timer? _saveDebounce;
  bool _disposed = false;

  /// Directory paths whose queue row should be marked done, not yet written.
  ///
  /// One UPDATE per directory is one transaction per directory; a 34k-directory
  /// phone volume turned that into 34k commits for bookkeeping nobody reads
  /// until the next resume. Losing up to [queueDoneFlushSize] marks to a crash
  /// is harmless: the resume path re-scans them (idempotent).
  final List<String> _pendingQueueDone = <String>[];

  /// Marks buffered before one batch UPDATE is issued.
  static const int queueDoneFlushSize = 32;

  /// Newly discovered directories whose `scan_queue` rows are not written yet.
  ///
  /// Same reasoning as [_pendingQueueDone]: one enqueue per directory is one
  /// transaction per directory (7.3 s measured on a 34k-directory phone
  /// volume). Order matters on a resume — a directory marked done must never
  /// outrun its children's rows — so the enqueue buffer is always flushed
  /// BEFORE the done buffer (see [_flushQueueBookkeeping]).
  final Map<int, List<String>> _pendingEnqueue = <int, List<String>>{};
  int _pendingEnqueueCount = 0;

  /// Discovered paths buffered before one batch insert is issued.
  static const int enqueueFlushSize = 256;

  /// Directories the STORED snapshot already knows under this run's roots.
  ///
  /// The progress denominator's floor. A depth-first scan discovers a directory
  /// right before visiting it, so "discovered so far" reads as ~99% for the
  /// whole run; the previous run's row count is the only honest estimate of the
  /// tree's size. 0 means "never scanned" — the overlay then shows a discovering
  /// line instead of a fabricated fraction.
  int _knownTotalDirs = 0;

  /// Directories this run has discovered, maintained incrementally.
  ///
  /// [RecursiveScanState.depthPaths] cannot be summed on demand: it was summed
  /// once per directory, i.e. O(n²) over a 20k-entry map (~200 µs per directory,
  /// 7 s per 34k-directory run).
  int _discoveredDirs = 0;

  /// Whether [RecursiveScanState.depthPaths] hit its in-memory cap this run, so
  /// the full discovered set only exists in `scan_queue`.
  bool _depthPathsCapped = false;

  /// Test seam: pretend the stored snapshot knows [total] directories.
  ///
  /// The real value comes from `media_nodes` at [startScan]; a unit test without
  /// a database would otherwise always run with an UNKNOWN total (0), which is
  /// exactly the state that suppresses the percentage and the ETA.
  @visibleForTesting
  void debugSetKnownTotalDirs(int total) {
    _knownTotalDirs = total < 0 ? 0 : total;
    _refreshTotalDirs();
  }

  /// See [_depthPathsCapped].
  bool get depthPathsCapped => _depthPathsCapped;

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

  /// Completer behind [enumerationSettled]: fired when the DFS has listed the
  /// tree and every row is written, BEFORE the metadata pass and aggregates.
  ///
  /// This is the signal that makes "play as soon as the folder is listable"
  /// possible without inventing a second scan lifecycle: the same run still
  /// reports `scanning` until [completeScan].
  Completer<void>? _enumerationCompleter;

  /// Playable files discovered by the current run. Read by the play gate right
  /// after [enumerationSettled] to choose the "wait for metadata" tier vs the
  /// "play now, fill later" tier.
  int _filesSeen = 0;

  /// Whether the run's waiters should wait for the metadata pass (tier A) or
  /// only for the enumeration (tier B/C). Set at start, and downgraded by the
  /// service when the tree turns out to exceed [kFastMetadataFileLimit].
  bool _waitForMetadata = true;
  bool _enumerationDone = false;
  Completer<void>? _playableCompleter;

  int _probeDone = 0;
  int _probeTotal = 0;

  /// True when the current run was started as a SIDE EFFECT of a play action
  /// (desktop drag-drop, the play gate's silent increment) rather than by the
  /// user asking to scan.
  ///
  /// The progress panel exists to explain "why hasn't playback started yet", so
  /// for such a run it stays hidden while the run is fast, never counts down,
  /// and is hidden for good once playback resumed ([dismissQuietPanel]) 鈥?the
  /// aggregate / metadata tail then finishes without covering the video.
  ///
  /// Transient: reset by every [startScan] and [resetScan], never persisted.
  bool _quietCompletion = false;

  bool get quietCompletion => _quietCompletion;

  /// Set once playback has resumed for a [quietCompletion] run: the panel has
  /// explained the wait and is hidden for the rest of THIS run, without touching
  /// its lifecycle (the aggregate / metadata tail keeps running). Without this
  /// a cold 30k-file scan would keep a panel over the video for the time the
  /// tail needs, which is exactly what the quiet mode is meant to avoid.
  ///
  /// Cleared by every [startScan].
  final ValueNotifier<bool> quietPanelDone = ValueNotifier<bool>(false);

  /// Hides the quiet panel now (no-op for a user-initiated run).
  void dismissQuietPanel() {
    if (!_quietCompletion) return;
    quietPanelDone.value = true;
  }

  /// When true a higher-level orchestrator (e.g. the scenario-source refresh
  /// batch) owns the user-facing progress UI, so the generic
  /// [ScanProgressOverlay] must yield. Transient: never persisted, and it does
  /// not alter the scan lifecycle 鈥?the same [RecursiveScanService] still
  /// drives phase/progress.
  final ValueNotifier<bool> overlaySuppressed = ValueNotifier<bool>(false);

  /// Hands the progress UI to / back from an external orchestrator.
  void setOverlaySuppressed(bool value) => overlaySuppressed.value = value;

  // --- Actions ---

  /// Monotonic id of the CURRENT run, bumped by every [startScan].
  ///
  /// A metadata pass outlives the call that started it (it continues after
  /// [completeScan]), and the run that supersedes it is a DIFFERENT
  /// `RecursiveScanService` instance 鈥?so "does my run still own this storage?"
  /// cannot be an instance field on the service; the two runs share nothing but
  /// this store. See [isSupersededByNewerRun].
  int get runToken => _runToken;
  int _runToken = 0;

  /// Identity of the run that owns the store right now.
  ///
  /// A caller-allocated object, not a counter: two runs can start inside the
  /// same interleaving window (the second one is admitted because the scan lease
  /// is re-entrant within a window), so reading `runToken` after an await could
  /// hand the OLDER run the NEWER run's token and let it keep walking. An owner
  /// object is allocated before the first await, so identity can never be
  /// adopted by a superseded run.
  Object? get runOwner => _runOwner;
  Object? _runOwner;

  /// Whether [owner] is still the run that owns the store.
  bool ownsRun(Object owner) => identical(_runOwner, owner);

  Future<void> startScan({
    required String storageId,
    required Map<int, List<String>> depthPaths,
    int carryElapsedMs = 0,
    bool waitForMetadata = true,
    bool quietCompletion = false,
    Object? owner,
  }) async {
    _runOwner = owner ?? Object();
    // A new run supersedes whatever was in flight: release its waiters first so
    // they can re-evaluate (they would otherwise wait on a run that is gone).
    _settleScan();
    // Marks the superseded run buffered still belong to ITS rows; flush before
    // this run clears the queue, or they would be lost for good. Guarded so a
    // clean hand-over keeps startScan synchronous for its callers.
    if (_pendingQueueDone.isNotEmpty || _pendingEnqueue.isNotEmpty) {
      await _flushQueueBookkeeping();
    }
    _runToken++;
    _waitForMetadata = waitForMetadata;
    // A new run decides its own completion style: manual scans show the
    // "task complete" panel, playback-originated ones re-arm right after.
    final previousQuiet = _quietCompletion;
    _quietCompletion = quietCompletion;
    // A CHAINED quiet run (second root of the same drop) must stay hidden once
    // playback already started; anything else may show the panel again.
    if (!quietCompletion || !previousQuiet) {
      quietPanelDone.value = false;
    }
    _beginEnumeration();
    final previousDelay = state.autoCloseDelay;
    final previousPrompt = state.autoClosePrompt;
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
      autoClosePrompt: previousPrompt,
    ));
    // Progress accounting for THIS run: a fresh start (or a resume) has no
    // discovered count of its own yet, and the stored snapshot supplies the
    // denominator floor.
    _discoveredDirs = 0;
    for (final paths in depthPaths.values) {
      _discoveredDirs += paths.length;
    }
    _depthPathsCapped = false;
    _knownTotalDirs =
        await _countKnownDirs(storageId, depthPaths[0] ?? const <String>[]);
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

  /// Directory rows the stored snapshot already knows under [roots].
  ///
  /// Best-effort by contract: an unreadable count only costs the percentage
  /// readout, never the scan, so it must not fail the run.
  Future<int> _countKnownDirs(String storageId, List<String> roots) async {
    if (roots.isEmpty) return 0;
    try {
      final count = await DbModule.mediaNodesDao.countDirsUnder(storageId, roots);
      // Observability: "why does the bar show 99% / why does it start at 0" is
      // answered by this one line.
      areaKeyLog.w('Scan progress floor: stored=${count}D '
          'roots=${roots.length} storage=$storageId');
      return count;
    } catch (e) {
      areaKeyLog.w('Scan progress: known directory count failed: $e');
      return 0;
    }
  }

  Future<void> updateDepth({
    required int depth,
    required List<String> paths,
  }) async {
    final newDepthPaths = Map<int, List<String>>.from(state.depthPaths);
    final existing = newDepthPaths[depth] ?? [];
    // Cap in-memory map to avoid 50w OOM: keep first 20000 entries, rest via queue table.
    const cap = 20000;
    final totalBefore = _discoveredDirs;
    if (totalBefore < cap) {
      newDepthPaths[depth] = [...existing, ...paths];
      _discoveredDirs += paths.length;
      set(state.copyWith(depthPaths: newDepthPaths));
    } else {
      // Spill to queue only, keep map truncated for UI fraction.
      _depthPathsCapped = true;
      set(state.copyWith(depthPaths: newDepthPaths));
    }
    await _enqueueBuffered(depth, paths);
    await _countAndScheduleSave();
  }

  /// Buffers [paths] for the `scan_queue` write instead of issuing one
  /// transaction per directory (see [_pendingEnqueue]).
  Future<void> _enqueueBuffered(int depth, List<String> paths) async {
    if (paths.isEmpty) return;
    _pendingEnqueue.putIfAbsent(depth, () => <String>[]).addAll(paths);
    _pendingEnqueueCount += paths.length;
    if (_pendingEnqueueCount >= enqueueFlushSize) {
      await _flushQueueEnqueue();
    }
  }

  Future<void> _flushQueueEnqueue() async {
    if (_pendingEnqueue.isEmpty) return;
    final pending = Map<int, List<String>>.from(_pendingEnqueue);
    _pendingEnqueue.clear();
    _pendingEnqueueCount = 0;
    final sid = state.storageId;
    if (sid == null) return;
    for (final entry in pending.entries) {
      try {
        await DbModule.scanQueueDao.enqueue(sid, entry.value, entry.key);
      } catch (_) {}
    }
  }

  /// Flushes the queue bookkeeping in DEPENDENCY ORDER.
  ///
  /// A directory's "done" mark may only be written once the rows of the
  /// directories it discovered exist, otherwise a resume would skip a subtree
  /// the previous process had already entered.
  Future<void> _flushQueueBookkeeping() async {
    await _flushQueueEnqueue();
    await _flushQueueDone();
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
    // Progress is high-frequency UI state 鈥?debounce persistence so the
    // player timer (1s) and DB writes never contend on the KV store.
    _scheduleSave();
  }

  Future<void> addProgress(double delta) async {
    final newProgress = (state.progress + delta).clamp(0.0, 1.0);
    set(state.copyWith(progress: newProgress));
    _scheduleSave();
  }

  /// Atomically increments the scanned-directory count by one.
  ///
  /// WHY a dedicated method: concurrent child scans must not pre-read
  /// `state.scannedDirs` in the caller (`state.scannedDirs + 1` loses an
  /// increment when two workers evaluate before either writes). The read and
  /// the `set` here run synchronously with no `await` between them, so each
  /// event-loop turn observes the previous turn's write.
  Future<void> incrementScannedDirs() async {
    set(state.copyWith(scannedDirs: state.scannedDirs + 1));
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
    // Every directory this run finished must land BEFORE the queue is cleared.
    await _flushQueueBookkeeping();
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
    await _flushQueueBookkeeping();
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

  /// Stop the scan 鈥?terminal state. Service loop exits.
  /// Overlay shows auto-close countdown with only a close button.
  Future<void> stopScan() async {
    _saveDebounce?.cancel();
    await _flushQueueBookkeeping();
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
  ///
  /// Buffered: the mark is bookkeeping for the NEXT resume, and one UPDATE (one
  /// transaction) per directory is a measurable share of a 34k-directory phone
  /// scan. [queueDoneFlushSize] marks are written per batch; every terminal
  /// phase flushes whatever is left.
  Future<void> markQueueDone(String path) async {
    _pendingQueueDone.add(path);
    if (_pendingQueueDone.length >= queueDoneFlushSize) {
      await _flushQueueBookkeeping();
    }
  }

  Future<void> _flushQueueDone() async {
    if (_pendingQueueDone.isEmpty) return;
    final paths = List<String>.from(_pendingQueueDone);
    _pendingQueueDone.clear();
    try {
      final sid = state.storageId;
      if (sid == null) return;
      await DbModule.scanQueueDao.markDoneBatch(sid, paths);
    } catch (_) {}
  }

  Future<void> markQueueError(String path) async {
    // Order the mark against the buffer: a path that failed must not be
    // re-marked done by a stale entry for the same directory.
    await _flushQueueBookkeeping();
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

  /// Turn the completion countdown on/off ("silent completion" is `false`).
  ///
  /// Keeps [autoCloseDelay] as-is so re-enabling restores the user's previous
  /// duration instead of resetting it to the default.
  Future<void> updateAutoClosePrompt(bool enabled) async {
    set(state.copyWith(autoClosePrompt: enabled));
    await save(state);
    await _mirrorPreference();
  }

  Future<void> resetScan() async {
    if (_pendingQueueDone.isNotEmpty) await _flushQueueDone();
    _pendingEnqueue.clear();
    _pendingEnqueueCount = 0;
    try {
      final sid = state.storageId;
      if (sid != null) await DbModule.scanQueueDao.clearForStorage(sid);
    } catch (_) {}
    _stopTiming();
    _elapsedMs = 0;
    _probeDone = 0;
    _probeTotal = 0;
    _knownTotalDirs = 0;
    _discoveredDirs = 0;
    _depthPathsCapped = false;
    // Back to the default completion style: the next run decides its own.
    _quietCompletion = false;
    quietPanelDone.value = false;
    timing.value = const ScanTiming.idle();
    // Completion preferences are SETTINGS, not run state: wiping them here
    // used to silently restore the default countdown after every scan (and
    // would re-enable the countdown for a user who chose silent completion).
    set(RecursiveScanState(
      autoCloseDelay: state.autoCloseDelay,
      autoClosePrompt: state.autoClosePrompt,
    ));
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
  /// instead of starting a duplicate run 鈥?the scan gate's action-resume anchor.
  /// With no run in flight it returns an already-completed future, so a caller
  /// can await unconditionally.
  Future<void> get scanSettled {
    if (!isScanning) return Future<void>.value();
    return (_settledCompleter ??= Completer<void>()).future;
  }

  /// Whether the metadata pass started by run [runToken] on [storageId] over
  /// [roots] has been overtaken by the run that owns the store now 鈥?and that
  /// newer run re-examines EVERY one of those roots.
  ///
  /// Only then may the older pass stop, because its rows are redundant. A run on
  /// another storage, or on a different subtree of the same storage, touches
  /// disjoint rows: cancelling it would abandon metadata no later pass covers
  /// (a chained multi-root / multi-storage batch would leave permanent holes).
  bool isSupersededByNewerRun({
    required Object owner,
    required String storageId,
    required List<String> roots,
  }) {
    if (ownsRun(owner)) return false;
    if (state.storageId != storageId) return false;
    final running = state.depthPaths[0] ?? const <String>[];
    if (running.isEmpty || roots.isEmpty) return false;
    for (final root in roots) {
      if (!running.any((r) => _runRootCovers(r, root))) return false;
    }
    return true;
  }

  /// Ancestor-or-equal test in the DOMAIN path form both runs record, folding
  /// case only where the filesystem does (two differently-cased Windows drive /
  /// UNC paths are one folder; POSIX / SAF paths are not).
  static bool _runRootCovers(String ancestor, String path) {
    final fold = pathRidesCaseInsensitiveFs(canonicalDbPath(ancestor));
    String norm(String value) {
      final canonical = canonicalDbPath(value);
      return fold ? canonical.toLowerCase() : canonical;
    }

    final a = norm(ancestor);
    if (a.isEmpty) return true; // storage root covers everything
    final p = norm(path);
    return p == a || p.startsWith('$a/');
  }

  /// Releases every [scanSettled] waiter. Called on each terminal phase and
  /// when a NEW run supersedes the current one 鈥?a superseded run must never
  /// leave a waiter hanging forever.
  void _settleScan() {
    final completer = _settledCompleter;
    _settledCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
    _settleEnumeration();
  }

  /// A future that completes when the CURRENT run has finished listing and
  /// writing every row (metadata may still be filling in).
  ///
  /// With no run in flight it is already complete, so callers can await it
  /// unconditionally and then decide whether to also wait for [scanSettled].
  Future<void> get enumerationSettled {
    final completer = _enumerationCompleter;
    if (completer == null || completer.isCompleted) return Future<void>.value();
    return completer.future;
  }

  /// Playable files discovered by the current (or last finished) run.
  int get filesSeen => _filesSeen;

  /// Called by the scan service per directory as rows are written.
  void addFilesSeen(int count) {
    if (count > 0) _filesSeen += count;
  }

  /// Called by the scan service once the DFS is done (before metadata).
  void markEnumerationComplete() {
    _enumerationDone = true;
    final completer = _enumerationCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
    if (!_waitForMetadata) markPlayableReady();
  }

  /// Downgrades the run to "play as soon as it is listable" (tier B/C): the
  /// metadata pass will keep running after [completeScan].
  void disableMetadataWait() {
    if (!_waitForMetadata) return;
    _waitForMetadata = false;
    if (_enumerationDone) markPlayableReady();
  }

  /// Releases [playableSettled] waiters (metadata done, or the run does not
  /// wait for it).
  void markPlayableReady() {
    final completer = _playableCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// A future that completes when the run produced a scope that can be played
  /// in its final order: after metadata for a small local scope, after the
  /// enumeration for a large/network one.
  ///
  /// Already complete when no run is in flight, so the play gate can await it
  /// unconditionally.
  Future<void> get playableSettled {
    if (!isScanning) return Future<void>.value();
    final completer = _playableCompleter;
    if (completer == null || completer.isCompleted) return Future<void>.value();
    return completer.future;
  }

  void _beginEnumeration() {
    final previous = _enumerationCompleter;
    if (previous != null && !previous.isCompleted) previous.complete();
    _enumerationCompleter = Completer<void>();
    final previousPlayable = _playableCompleter;
    if (previousPlayable != null && !previousPlayable.isCompleted) {
      previousPlayable.complete();
    }
    _playableCompleter = Completer<void>();
    _enumerationDone = false;
    _filesSeen = 0;
  }

  void _settleEnumeration() {
    final completer = _enumerationCompleter;
    _enumerationCompleter = null;
    _enumerationDone = false;
    if (completer != null && !completer.isCompleted) completer.complete();
    final playable = _playableCompleter;
    _playableCompleter = null;
    if (playable != null && !playable.isCompleted) playable.complete();
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

  /// Refreshes the progress denominator and saves (immediate, for init).
  Future<void> _countAndSave() async {
    _refreshTotalDirs();
    await save(state);
  }

  Future<void> _countAndScheduleSave() async {
    _refreshTotalDirs();
    _scheduleSave();
  }

  /// Publishes the scan's denominator.
  ///
  /// The denominator is the size of the tree, not the size of the work that
  /// happens to have been discovered: a depth-first walk discovers a directory
  /// immediately before scanning it, so `scannedDirs / discoveredDirs` sits near
  /// 100% from the first minute (measured: 97.7% at 32% of the elapsed time,
  /// "3 s left" for 3 more minutes) and the ETA is fiction. The stored snapshot
  /// is the floor; a tree that grew raises it.
  ///
  /// No stored rows at all means the volume has never been scanned and nobody
  /// knows the total. Reporting 0 makes the overlays show "discovering" and an
  /// indeterminate bar, which is the truth.
  void _refreshTotalDirs() {
    final int total;
    if (_knownTotalDirs <= 0) {
      total = 0;
    } else {
      total = _knownTotalDirs > _discoveredDirs
          ? _knownTotalDirs
          : _discoveredDirs;
    }
    if (state.totalDirs == total) return;
    set(state.copyWith(totalDirs: total));
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
    await _flushQueueBookkeeping();
    _stopTiming();
    timing.dispose();
    overlaySuppressed.dispose();
    quietPanelDone.dispose();
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
      for (final entry in ScanStateBridge.encodeRows(state).entries) {
        await MetaSettingsModule.persistAuxRow(entry.key, entry.value);
      }
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

      // Gate ON 鈫?the DB row is authoritative for preferences; overlay it.
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
      // ... and, when no run is live in THIS store, the persisted `scanning`
      // phase is stale: a restart cannot resume by itself, because the DFS lives
      // in a service that was in the dead process. Reporting it as `scanning`
      // left a frozen progress panel (its clock deliberately does not tick) over
      // the app with no scan behind it, and the user could neither wait it out
      // nor start a new one — the panel had to be dismissed by hand.
      //
      // `error` is the honest state: the next scan offers "resume" (the work
      // list was just rebuilt above from scan_queue) or "start new". A reload()
      // while a scan is genuinely running keeps its phase.
      if (!isScanning && loaded != null && loaded.phase == ScanPhase.scanning) {
        loaded = loaded.copyWith(
          phase: ScanPhase.error,
          paused: false,
          currentScanningPath: null,
          error: kScanInterruptedByRestart,
        );
      }
      return loaded;
    } catch (e) {
      areaKeyLog.e('RecursiveScanStore.load error: $e');
      return null;
    }
  }

  /// Persists the snapshot WITHOUT the resume map.
  ///
  /// The map is the scan's working set, not durable state: `scan_queue` already
  /// stores every pending directory and [load] rebuilds the map from it. Writing
  /// it here made the value grow to ~1.5 MB on a 34k-directory phone volume, and
  /// Android's KV backend is EncryptedSharedPreferences 鈥?a JSON encode plus an
  /// AES commit every save (twice a second), on the UI isolate. Measured on a
  /// 2019 device that was the largest single cost of a full-volume scan.
  @override
  Future<void> save(RecursiveScanState state) async {
    final stopwatch = profiler == null ? null : (Stopwatch()..start());
    try {
      final trimmed = state.depthPaths.isEmpty
          ? state
          : state.copyWith(depthPaths: const <int, List<String>>{});
      final json = jsonEncode(trimmed.toJson());
      await _storage.write(key: _scanStateKey, value: json);
    } catch (e) {
      areaKeyLog.e('RecursiveScanStore.save error: $e');
    } finally {
      if (stopwatch != null) {
        profiler?.record('kv.write', stopwatch.elapsed);
      }
    }
  }
}

RecursiveScanStore useRecursiveScanStore() =>
    create(() => RecursiveScanStore());
