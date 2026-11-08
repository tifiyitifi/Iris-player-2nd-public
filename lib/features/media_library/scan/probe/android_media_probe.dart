import 'package:flutter/services.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.mediaProbe);

/// Android probe backed by `MediaMetadataRetriever` through a thin platform
/// channel (`iris/media_probe`). Accepts both real filesystem paths and
/// `content://` URIs, so SAF-scoped storages are covered too.
///
/// This is the SLOW path on purpose: only containers the Dart header parser
/// cannot read reach it (see `createMediaProbeService`). Two device-driven
/// details matter here:
///
/// * the batch method exists so a fallback pass pays ONE platform round trip per
///   batch — the old per-file `invokeMethod` loop turned a 2k-file pass into 2k
///   channel waits on top of the retrievals;
/// * the native handler answers from a worker pool, because
///   `setDataSource` opens and parses the file (300–450 ms under load on a 2019
///   device) and used to run on the platform main thread — a frozen UI for the
///   whole metadata pass.
///
/// Missing native side (desktop tests / other platforms) degrades to
/// [ProbeResult.empty] via [MissingPluginException] handling.
class AndroidMediaProbeService implements MediaProbeService {
  const AndroidMediaProbeService();

  static const MethodChannel _channel = MethodChannel('iris/media_probe');

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async {
    if (targets.isEmpty) return const [];
    try {
      final raw = await _channel.invokeListMethod<dynamic>(
        'probeBatch',
        <String, Object?>{'targets': targets},
      );
      if (raw == null) {
        return List<ProbeResult>.filled(targets.length, ProbeResult.empty);
      }
      return [
        for (var i = 0; i < targets.length; i++)
          i < raw.length ? _toResult(raw[i]) : ProbeResult.empty,
      ];
    } on MissingPluginException {
      return _probeSequentially(targets);
    } on PlatformException catch (e) {
      _log.w('probeBatch platform error: ${e.code}');
      return _probeSequentially(targets);
    } catch (e) {
      _log.w('probeBatch failed: $e');
      return _probeSequentially(targets);
    }
  }

  /// Compatibility path for an engine that predates `probeBatch` (or a
  /// partially-registered plugin): one call per file, exactly as before.
  Future<List<ProbeResult>> _probeSequentially(List<String> targets) async {
    final out = <ProbeResult>[];
    for (final t in targets) {
      out.add(await probeFile(t));
    }
    return out;
  }

  @override
  Future<ProbeResult> probeFile(String target) async {
    try {
      final result =
          await _channel.invokeMapMethod<String, Object?>(
        'probe',
        <String, Object?>{'target': target},
      );
      return _toResult(result);
    } on PlatformException catch (e) {
      _log.w('probeFile($target) platform error: ${e.code}');
      return ProbeResult.empty;
    } on MissingPluginException {
      return ProbeResult.empty;
    } catch (e) {
      _log.w('probeFile($target) failed: $e');
      return ProbeResult.empty;
    }
  }

  /// Decodes one probe payload (single map or batch element).
  ///
  /// A batch element is an empty map when the native side could not read the
  /// file, so "missing keys" and "unprobeable" share the same empty result.
  static ProbeResult _toResult(Object? payload) {
    if (payload is! Map) return ProbeResult.empty;
    int? readInt(String key) {
      final value = payload[key];
      return value is num ? value.toInt() : null;
    }

    final durationMs = readInt('durationMs');
    final width = readInt('width');
    final height = readInt('height');
    if (durationMs == null && width == null && height == null) {
      return ProbeResult.empty;
    }
    return ProbeResult(durationMs: durationMs, width: width, height: height);
  }
}
