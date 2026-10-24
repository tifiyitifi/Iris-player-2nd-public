import 'package:freezed_annotation/freezed_annotation.dart';

part 'scenario_source_refresh_state.freezed.dart';
part 'scenario_source_refresh_state.g.dart';

/// Lifecycle of a scenario-source refresh run.
///
/// Unlike the generic [ScanPhase] (one scan = one storage), this is a BATCH
/// over every storage a scenario draws from. The task is only `done` once all
/// storages AND the explicit-file pass have finished — so the progress bar can
/// legitimately reach 100% exactly once, at the end.
enum ScenarioSourceRefreshPhase {
  idle,

  /// Storages are being scanned / explicit files checked.
  running,

  /// Every storage finished (or was skipped as unreachable).
  done,

  /// The user stopped mid-run; already-scanned storages keep their results.
  stopped,

  /// The run aborted with an unexpected error.
  error,
}

/// One storage's slot in the refresh run (progress bookkeeping + outcome).
@freezed
abstract class ScenarioSourceRefreshUnit with _$ScenarioSourceRefreshUnit {
  const factory ScenarioSourceRefreshUnit({
    required String storageId,
    required String storageName,

    /// Estimated work weight; larger storages dominate the batch progress.
    @Default(1) int weight,

    /// 0..1 fraction of THIS unit that is complete.
    @Default(0) double fraction,

    /// True once the unit has been scanned (or skipped) and its fraction is
    /// frozen at its final value.
    @Default(false) bool finished,

    /// True when the unit was skipped because the storage was unreachable
    /// (preflight failed) — never scanned, never cleaned.
    @Default(false) bool skipped,
  }) = _ScenarioSourceRefreshUnit;

  factory ScenarioSourceRefreshUnit.fromJson(Map<String, dynamic> json) =>
      _$ScenarioSourceRefreshUnitFromJson(json);
}

/// In-memory state driving the scenario-source refresh overlay.
///
/// Purely transient UI state — never persisted (the underlying
/// [RecursiveScanStore] owns the durable scan queue/resume state).
@freezed
abstract class ScenarioSourceRefreshState
    with _$ScenarioSourceRefreshState {
  const factory ScenarioSourceRefreshState({
    @Default(ScenarioSourceRefreshPhase.idle) ScenarioSourceRefreshPhase phase,
    @Default(<ScenarioSourceRefreshUnit>[])
    List<ScenarioSourceRefreshUnit> units,
    @Default(0) int currentUnitIndex,

    /// Path currently being walked inside the active unit (display only).
    String? currentPath,

    /// Counts for the completion summary dialog.
    @Default(0) int scannedStorages,
    @Default(0) int skippedStorages,
    @Default(0) int dedupedSources,
    @Default(0) int missingExplicitFiles,

    /// Manually added (explicit) items whose metadata the refresh re-probed
    /// because no source scan covered them.
    @Default(0) int probedExplicitFiles,

    /// Root count of the active unit's scan (display only).
    @Default(0) int currentUnitTotalDirs,
    @Default(0) int currentUnitScannedDirs,

    String? error,
  }) = _ScenarioSourceRefreshState;

  factory ScenarioSourceRefreshState.fromJson(Map<String, dynamic> json) =>
      _$ScenarioSourceRefreshStateFromJson(json);
}

extension ScenarioSourceRefreshStateX on ScenarioSourceRefreshState {
  bool get isRunning => phase == ScenarioSourceRefreshPhase.running;

  bool get isTerminal =>
      phase == ScenarioSourceRefreshPhase.done ||
      phase == ScenarioSourceRefreshPhase.stopped ||
      phase == ScenarioSourceRefreshPhase.error;

  /// Weighted fraction across the whole batch; reaches 1.0 only when every
  /// unit is finished. Units that were skipped simply contribute their full
  /// weight (they are "done" by decision, not by scanning).
  double get overallFraction {
    if (units.isEmpty) return 0;
    var totalWeight = 0;
    var doneWeight = 0.0;
    for (final u in units) {
      totalWeight += u.weight;
      doneWeight += u.weight * (u.finished ? 1.0 : u.fraction).clamp(0.0, 1.0);
    }
    if (totalWeight <= 0) return 0;
    return (doneWeight / totalWeight).clamp(0.0, 1.0);
  }

  int get currentUnitNumber =>
      units.isEmpty ? 0 : (currentUnitIndex + 1).clamp(1, units.length);

  ScenarioSourceRefreshUnit? get currentUnit =>
      currentUnitIndex >= 0 && currentUnitIndex < units.length
          ? units[currentUnitIndex]
          : null;
}
