/// Rough cost model for a recursive scan, used only to show an "estimated
/// about X" line before the user starts one.
///
/// The numbers come from AOT (profile/release) measurements on 2026-11-06, and
/// are split into the two things a scan actually pays for:
///
/// - Android 10 / SD855 / internal storage: 34,005 directories and 20,916 media
///   files took 91.50 s, of which listing the tree took 62.89 s
///   (62.89 s / 34,005 ≈ 1.85 ms per directory) and the metadata pass made up
///   the rest (28.61 s / 20,916 ≈ 1.37 ms per file).
/// - Windows / D: drive, manually stopped after 201.61 s with 120,621
///   directories and only 720 media files (201.61 s / 120,621 ≈ 1.67 ms per
///   directory; the file term below is back-derived from the media-folder run,
///   where 5,479 files took ≈ 5 s).
///
/// A DEBUG build is roughly 4x slower on Windows (the same D: drive had not
/// finished after 14:18), so its numbers must never be quoted or fed back into
/// these constants.
///
/// Deliberately no per-byte/per-capacity term: capacity does not predict scan
/// time at all — folder and file counts do. The UI shows only the media-file
/// count (users understand files, not folders) while the estimate internally
/// keeps the directory term, because a drive with 120k folders and 720 media
/// files would otherwise be predicted at ~1 s instead of ~3.5 min.
library;

/// Measured listing cost per directory, Android (AOT).
const double kScanMsPerDirAndroid = 1.85;

/// Measured metadata-probe cost per media file, Android (AOT).
const double kScanMsPerFileAndroid = 1.37;

/// Measured listing cost per directory, Windows (AOT profile build).
const double kScanMsPerDirWindows = 1.67;

/// Metadata-probe cost per media file, Windows (AOT profile build).
const double kScanMsPerFileWindows = 0.60;

/// A first scan of an empty database additionally aggregates ancestor rows;
/// the measured media-folder run paid ~1.8 s of that on top of listing.
/// Callers only ever have stored counts after a COMPLETED scan, so this factor
/// documents the "1.5–2× on a first run" sentence rather than being applied to
/// a real estimate.
const double kScanFirstRunFactor = 1.8;

/// Rough estimate for a scan of [dirs] directories and [files] media files.
///
/// Returns null when there is nothing to estimate from (no stored snapshot),
/// which callers must treat as "show no estimate" rather than "zero".
Duration? estimatedScanDuration({
  required int dirs,
  required int files,
  required bool isWindows,
  bool firstRun = false,
}) {
  if (dirs <= 0 && files <= 0) return null;
  final msPerDir = isWindows ? kScanMsPerDirWindows : kScanMsPerDirAndroid;
  final msPerFile = isWindows ? kScanMsPerFileWindows : kScanMsPerFileAndroid;
  final double ms = dirs * msPerDir + files * msPerFile;
  return Duration(
    milliseconds: (ms * (firstRun ? kScanFirstRunFactor : 1)).round(),
  );
}
