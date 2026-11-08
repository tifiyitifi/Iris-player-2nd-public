import 'package:freezed_annotation/freezed_annotation.dart';

part 'recursive_scan_state.freezed.dart';
part 'recursive_scan_state.g.dart';

enum ScanPhase { idle, scanning, done, error, stopped }

/// Stored in [RecursiveScanState.error] when a run was left `scanning` by a dead
/// process.
///
/// A marker, not a message: the store has no localization context, and printing
/// a developer sentence to the user is exactly what this avoids. The overlay
/// turns it into a localized line.
const String kScanInterruptedByRestart = 'scan.interrupted.restart';

@freezed
abstract class RecursiveScanState with _$RecursiveScanState {
  const RecursiveScanState._();

  const factory RecursiveScanState({
    @Default(ScanPhase.idle) ScanPhase phase,

    /// The storage being scanned.
    String? storageId,

    /// Depth-based path tracking.
    ///
    /// depth 0 = root paths to scan
    /// depth 1 = subdirs discovered from depth 0
    /// depth 2 = subdirs discovered from depth 1
    /// etc.
    ///
    /// On resume, incomplete paths are reconstructed from DB.
    @Default({}) Map<int, List<String>> depthPaths,

    /// Which depth level is currently being processed.
    @Default(0) int currentDepth,

    /// Overall progress [0.0, 1.0], weight-based.
    @Default(0.0) double progress,

    /// Total directories discovered so far.
    @Default(0) int totalDirs,

    /// Directories scanned so far.
    @Default(0) int scannedDirs,

    /// Absolute path of the directory currently being scanned.
    String? currentScanningPath,

    /// Accumulated ACTIVE scan time in milliseconds (paused time excluded).
    ///
    /// Persisted so a resumed scan keeps counting from where it stopped. The
    /// live, ticking value lives in [RecursiveScanStore.timing] — this field is
    /// only a coarse snapshot written on lifecycle transitions.
    @Default(0) int elapsedMs,

    /// Error message if scan failed.
    String? error,

    /// Whether the scan is currently paused.
    /// Service loop waits while this is true. Auto-resumes when cleared.
    @Default(false) bool paused,

    /// Seconds to wait before auto-close after completion.
    /// 0 = close immediately. Default 2.5.
    @Default(2.5) double autoCloseDelay,

    /// Whether the completion countdown is shown.
    ///
    /// `false` = "silent completion": the progress panel closes the moment the
    /// scan finishes. [autoCloseDelay] is kept untouched so re-enabling the
    /// countdown restores the user's previous duration.
    @Default(true) bool autoClosePrompt,
  }) = _RecursiveScanState;

  /// Count-based scan progress: `scannedDirs / totalDirs`, clamped to [0,1].
  ///
  /// This is the ONLY progress shown while `phase == scanning` — it can never
  /// reach 1.0 unless every discovered directory has actually completed, so
  /// "100% while still scanning" is structurally impossible. The [progress]
  /// weight field is only set to 1.0 by [RecursiveScanStore.completeScan].
  double get progressFraction {
    if (totalDirs <= 0) return 0;
    return (scannedDirs / totalDirs).clamp(0.0, 1.0);
  }

  factory RecursiveScanState.fromJson(Map<String, dynamic> json) =>
      _$RecursiveScanStateFromJson(json);
}
