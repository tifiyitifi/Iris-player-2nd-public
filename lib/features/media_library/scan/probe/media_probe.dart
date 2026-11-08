import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:iris/features/media_library/scan/probe/android_media_probe.dart';
import 'package:iris/features/media_library/scan/probe/fast_local_probe.dart';
import 'package:iris/features/media_library/scan/probe/isolated_media_probe.dart';
import 'package:iris/features/media_library/scan/probe/windows_shell_probe.dart';

/// Result of probing one media file.
///
/// Every field is nullable: "not obtainable" is a normal outcome (unsupported
/// container, restricted storage, corrupt header), not an error. Missing
/// values sort last regardless of direction and are lazily backfilled when
/// the file is played.
class ProbeResult {
  /// Duration in milliseconds.
  final int? durationMs;

  /// Video frame width in pixels (as encoded; rotation metadata ignored).
  final int? width;

  /// Video frame height in pixels.
  final int? height;

  const ProbeResult({this.durationMs, this.width, this.height});

  static const empty = ProbeResult();

  /// Cached resolution metric for sorting; NULL when either side unknown.
  int? get pixelCount =>
      width != null && height != null ? width! * height! : null;
}

/// Probes a single media file for duration / dimensions.
abstract class MediaProbeService {
  /// [target] is a real filesystem path on Windows; on Android it may be a
  /// plain path or a `content://` URI.
  ///
  /// Never throws: unprobeable inputs yield [ProbeResult.empty].
  Future<ProbeResult> probeFile(String target);

  /// Batch probe, default falls back to sequential single probes.
  Future<List<ProbeResult>> probeFiles(List<String> targets) async {
    final out = <ProbeResult>[];
    for (final t in targets) {
      out.add(await probeFile(t));
    }
    return out;
  }
}

/// No-op probe for platforms without a strategy (Linux CI, Web, ...).
class NullMediaProbeService implements MediaProbeService {
  const NullMediaProbeService();

  @override
  Future<ProbeResult> probeFile(String target) async => ProbeResult.empty;

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async =>
      List<ProbeResult>.filled(targets.length, ProbeResult.empty);
}

/// Returns the platform-appropriate probe strategy.
///
/// - Windows: container-header parse first (MP4/MOV `mvhd`+`tkhd`, Matroska
///   `Info`+`Tracks`, AVI `hdrl/avih` — ~1 ms per file) with the Shell Property
///   System as fallback. The Shell handler alone measured 30–70 ms/file on a
///   warm cache — that is what made "scan first, then play" take tens of
///   seconds.
/// - Android: the SAME Dart header parser first, with `MediaMetadataRetriever`
///   as fallback. It used to go straight to the retriever, which on a real
///   phone costs 5–30 ms per file through a binder call — and measured
///   300–450 ms under load on a 2019 device (logcat `Slow Binder …
///   IMediaMetadataRetriever`). Header parsing avoids the binder entirely for
///   the containers most libraries are made of; `content://` targets have no
///   path to read and fall through to the retriever unchanged.
/// - Elsewhere: [NullMediaProbeService] (values arrive via lazy backfill).
///
/// The per-platform instance is cached: [FastLocalProbeService] owns a
/// persistent isolate pool, and a fresh pool per call would spawn workers on
/// every scan.
MediaProbeService createMediaProbeService() => createMediaProbeServiceFor(
      isWindows: Platform.isWindows,
      isAndroid: Platform.isAndroid,
    );

/// Platform selection with the platform probe made explicit, so the routing is
/// testable on any host (the host itself is always Windows in CI).
@visibleForTesting
MediaProbeService createMediaProbeServiceFor({
  required bool isWindows,
  required bool isAndroid,
}) {
  if (isWindows) {
    return _windowsProbe ??= FastLocalProbeService(
      fallback: const IsolatedWindowsShellProbeService(),
    );
  }
  if (isAndroid) {
    return _androidProbe ??= FastLocalProbeService(
      fallback: const AndroidMediaProbeService(),
    );
  }
  return const NullMediaProbeService();
}

MediaProbeService? _windowsProbe;
MediaProbeService? _androidProbe;

/// Upper bound for trusting probed video dimensions. Shell handlers for
/// exotic containers return present-but-absurd values (A/B-pinned on real
/// files: height 667040 / 451896 for 720p content); persisting those
/// corrupts resolution sorting. 16384 covers 16K sources with margin.
const int kMaxSaneProbeDimension = 16384;

/// Returns [result] with absurd width/height nulled out. Duration is left
/// untouched — every caller already requires a positive duration before
/// writing. Identity-preserving when everything is already sane.
ProbeResult sanitizeProbeResult(ProbeResult result) {
  final w = result.width;
  final h = result.height;
  bool sane(int? v) => v != null && v > 0 && v <= kMaxSaneProbeDimension;
  final saneW = sane(w) ? w : null;
  final saneH = sane(h) ? h : null;
  if (saneW == w && saneH == h) return result;
  return ProbeResult(
      durationMs: result.durationMs, width: saneW, height: saneH);
}

/// Direct (UI-isolate) Windows probe — retained for tests / fallback when
/// isolate spawn fails. Production factory prefers the isolated variant.
MediaProbeService createDirectWindowsProbeService() => WindowsShellProbeService();
