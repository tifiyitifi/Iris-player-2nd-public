import 'dart:async';

import 'package:flutter/material.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/media_library/scan/view/scan_timing_text.dart';
import 'package:iris/features/scenario_playback/scan/model/scenario_source_refresh_state.dart';
import 'package:iris/features/scenario_playback/scan/store/scenario_source_refresh_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';

/// Floating batch-progress bar for the scenario-source refresh, inserted into
/// the Navigator's overlay.
///
/// This is the multi-storage counterpart of
/// `ScanProgressOverlayManager`: the generic bar is suppressed for the whole
/// batch (via [RecursiveScanStore.setOverlaySuppressed]) and this one shows
/// the CROSS-storage fraction, so the bar only reaches 100% after every
/// storage AND the explicit-file pass have finished.
///
/// Mount in [Home] next to `ScanProgressOverlayManager`.
class ScenarioSourceRefreshOverlayManager extends StatefulWidget {
  const ScenarioSourceRefreshOverlayManager({super.key});

  /// Test seam: whether this manager currently holds an inserted OverlayEntry.
  @visibleForTesting
  static bool debugEntryMountedForTest = false;

  @override
  State<ScenarioSourceRefreshOverlayManager> createState() =>
      _ScenarioSourceRefreshOverlayManagerState();
}

class _ScenarioSourceRefreshOverlayManagerState
    extends State<ScenarioSourceRefreshOverlayManager> {
  OverlayEntry? _entry;
  StreamSubscription<ScenarioSourceRefreshState>? _subscription;

  /// The pause flag lives in the generic scan store — the same flag the
  /// [RecursiveScanService] loop blocks on. This overlay holds a listener so
  /// a pause issued anywhere (here or the generic bar) flips this UI.
  StreamSubscription<RecursiveScanState>? _scanSubscription;
  Offset _position = Offset.zero;
  bool _hasInitializedPosition = false;
  bool _syncScheduled = false;

  ScenarioSourceRefreshStore get _store => useScenarioSourceRefreshStore();

  @override
  void initState() {
    super.initState();
    _subscription = _store.stream.listen((_) => _onStoreChanged());
    _scanSubscription =
        useRecursiveScanStore().stream.listen((_) => _onStoreChanged());
    // Live elapsed/ETA ticks on the transient timing notifier (1 Hz).
    useRecursiveScanStore().timing.addListener(_onStoreChanged);
    _scheduleSync();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  bool get _shouldShow => _store.state.phase != ScenarioSourceRefreshPhase.idle;

  void _onStoreChanged() {
    if (mounted && _entry != null && _shouldShow) {
      _entry!.markNeedsBuild();
    }
    _scheduleSync();
  }

  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    scheduleMicrotask(() {
      _syncScheduled = false;
      if (!mounted) return;
      _syncEntry();
    });
  }

  void _syncEntry() {
    final shouldShow = _shouldShow;
    if (shouldShow && _entry == null) {
      final overlay = Overlay.maybeOf(context);
      if (overlay == null) return;
      final entry = OverlayEntry(builder: _buildEntry);
      _entry = entry;
      overlay.insert(entry);
      ScenarioSourceRefreshOverlayManager.debugEntryMountedForTest = true;
    } else if (!shouldShow && _entry != null) {
      _entry!.remove();
      _entry!.dispose();
      _entry = null;
      ScenarioSourceRefreshOverlayManager.debugEntryMountedForTest = false;
      _hasInitializedPosition = false;
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scanSubscription?.cancel();
    useRecursiveScanStore().timing.removeListener(_onStoreChanged);
    final entry = _entry;
    if (entry != null) {
      entry.remove();
      entry.dispose();
      _entry = null;
      ScenarioSourceRefreshOverlayManager.debugEntryMountedForTest = false;
    }
    super.dispose();
  }

  Widget _buildEntry(BuildContext context) {
    final state = _store.state;
    if (state.phase == ScenarioSourceRefreshPhase.idle) {
      _hasInitializedPosition = false;
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }

    final t = getLocalizations(context);
    final colorScheme = Theme.of(context).colorScheme;
    final isRunning = state.isRunning;
    final isError = state.phase == ScenarioSourceRefreshPhase.error;
    // Single source of truth for pause: the generic scan store's flag, the
    // same one the service loop blocks on. Reading it here (and only here)
    // keeps the icon, the action and the service in lockstep.
    final scanStore = useRecursiveScanStore();
    final isPaused = scanStore.state.paused;

    if (!_hasInitializedPosition) {
      _hasInitializedPosition = true;
      final size = MediaQuery.of(context).size;
      _position = Offset((size.width - 300) / 2, (size.height - 140) / 2);
    }

    final unit = state.currentUnit;
    final scannedDirs = state.currentUnitScannedDirs;
    final totalDirs = state.currentUnitTotalDirs;

    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          _position += details.delta;
          _entry?.markNeedsBuild();
        },
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: state.overallFraction > 0
                            ? state.overallFraction
                            : null,
                        minHeight: 4,
                        color: isError ? colorScheme.error : null,
                        backgroundColor: colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ExcludeSemantics(
                    child: Text(
                      _statusText(t, state, isRunning, isPaused),
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isRunning && unit != null) ...[
                    const SizedBox(height: 2),
                    ExcludeSemantics(
                      child: Text(
                        totalDirs > 0
                            ? '${(state.overallFraction * 100).toStringAsFixed(1)}% · '
                                '$scannedDirs/$totalDirs · ${unit.storageName}'
                            : '${(state.overallFraction * 100).toStringAsFixed(1)}% · '
                                '${unit.storageName}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (state.currentPath != null) ...[
                      const SizedBox(height: 2),
                      ExcludeSemantics(
                        child: Text(
                          displayScanPath(state.currentPath!),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    const SizedBox(height: 2),
                    ScanTimingText(
                      timing: scanStore.timing.value,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isRunning)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 20,
                          icon: Icon(
                            isPaused ? Icons.play_arrow : Icons.pause,
                          ),
                          onPressed: () => isPaused
                              ? scanStore.resumeScan()
                              : scanStore.pauseScan(),
                        ),
                      if (isRunning)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 20,
                          icon: const Icon(Icons.stop),
                          onPressed: useRecursiveScanStore().stopScan,
                        ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 20,
                        icon: const Icon(Icons.close),
                        onPressed: _store.reset,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _statusText(
    AppLocalizations t,
    ScenarioSourceRefreshState state,
    bool isRunning,
    bool isPaused,
  ) {
    switch (state.phase) {
      case ScenarioSourceRefreshPhase.running:
        if (isPaused) return t.scn_scan_paused;
        final unit = state.currentUnit;
        final idx = state.currentUnitNumber;
        final total = state.units.length;
        final name = unit?.storageName ?? '';
        return t.scn_scan_sources_running(idx, total, name);
      case ScenarioSourceRefreshPhase.done:
        return t.scn_scan_summary_title;
      case ScenarioSourceRefreshPhase.stopped:
        return t.scn_scan_summary_title_stopped;
      case ScenarioSourceRefreshPhase.error:
        return '${t.scan_sources_error}: ${state.error ?? ''}';
      case ScenarioSourceRefreshPhase.idle:
        return '';
    }
  }
}
