import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/scenario_playback/scan/model/scenario_source_refresh_state.dart';

/// Transient store driving the scenario-source refresh overlay.
///
/// Deliberately NOT a [PersistentStore]: the durable scan state (resume queue,
/// last root) lives in [RecursiveScanStore]; this store only carries the
/// batch-level progress that spans multiple storages. It resets on restart.
class ScenarioSourceRefreshStore extends Store<ScenarioSourceRefreshState> {
  ScenarioSourceRefreshStore() : super(const ScenarioSourceRefreshState());

  /// Starts a batch over [units] (already ordered; skipped units included).
  void start(List<ScenarioSourceRefreshUnit> units) {
    set(ScenarioSourceRefreshState(
      phase: ScenarioSourceRefreshPhase.running,
      units: units,
    ));
  }

  /// Marks the unit at [index] as the active one.
  void beginUnit(int index) {
    set(state.copyWith(
      currentUnitIndex: index,
      currentPath: null,
      currentUnitTotalDirs: 0,
      currentUnitScannedDirs: 0,
    ));
  }

  /// Updates the active unit's in-scan counters (mirrored from the generic
  /// [RecursiveScanStore] progress events).
  void updateUnitProgress({
    required double fraction,
    String? currentPath,
    int? totalDirs,
    int? scannedDirs,
  }) {
    final index = state.currentUnitIndex;
    if (index < 0 || index >= state.units.length) return;
    final units = [...state.units];
    if (units[index].finished) return;
    units[index] = units[index].copyWith(
      fraction: fraction.clamp(0.0, 1.0),
    );
    set(state.copyWith(
      units: units,
      currentPath: currentPath ?? state.currentPath,
      currentUnitTotalDirs: totalDirs ?? state.currentUnitTotalDirs,
      currentUnitScannedDirs: scannedDirs ?? state.currentUnitScannedDirs,
    ));
  }

  /// Freezes the unit at [index] at 100% (scanned or skipped).
  void finishUnit(int index, {bool skipped = false}) {
    if (index < 0 || index >= state.units.length) return;
    final units = [...state.units];
    units[index] = units[index].copyWith(
      fraction: 1,
      finished: true,
      skipped: skipped,
    );
    set(state.copyWith(
      units: units,
      scannedStorages:
          skipped ? state.scannedStorages : state.scannedStorages + 1,
      skippedStorages:
          skipped ? state.skippedStorages + 1 : state.skippedStorages,
    ));
  }

  void recordDedupedSources(int count) {
    set(state.copyWith(dedupedSources: count));
  }

  void recordMissingExplicitFiles(int count) {
    set(state.copyWith(missingExplicitFiles: count));
  }

  /// Files whose metadata the targeted explicit-item probe refreshed.
  void recordProbedExplicitFiles(int count) {
    set(state.copyWith(probedExplicitFiles: count));
  }

  void complete() => set(state.copyWith(
        phase: ScenarioSourceRefreshPhase.done,
        currentPath: null,
      ));

  void stop() => set(state.copyWith(
        phase: ScenarioSourceRefreshPhase.stopped,
        currentPath: null,
      ));

  void fail(String error) => set(state.copyWith(
        phase: ScenarioSourceRefreshPhase.error,
        error: error,
        currentPath: null,
      ));

  void reset() => set(const ScenarioSourceRefreshState());
}

ScenarioSourceRefreshStore useScenarioSourceRefreshStore() =>
    create(() => ScenarioSourceRefreshStore());
