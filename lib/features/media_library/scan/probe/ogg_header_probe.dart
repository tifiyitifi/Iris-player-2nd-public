import 'dart:io';
import 'dart:typed_data';

import 'package:iris/features/media_library/scan/probe/media_probe.dart';

/// Reads duration straight from Ogg Vorbis / Opus.
///
/// WHY: same reason as [Mp3HeaderProbe] — every Ogg file otherwise pays a
/// platform probe, and the metadata wait budget gives up after a small sample.
///
/// Two reads replace the probe:
/// - the FIRST page's identification header gives the sample rate (Vorbis) or
///   the pre-skip (Opus);
/// - the LAST page's granule position gives the total number of samples.
///
/// Granule positions are in samples at the stream's rate, so `granule * 1000 /
/// rate` is the exact duration — no bitrate estimation involved.
///
/// Deliberately NOT a decoder: no packet assembly, no comments, no chained/log
/// files (those return null and fall back).
abstract final class OggHeaderProbe {
  static const Set<String> extensions = {'.ogg', '.oga', '.opus'};

  static bool isOggPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return extensions.contains(path.substring(dot).toLowerCase());
  }

  /// Opus granules always count 48 kHz samples, regardless of the input rate.
  static const int _opusRate = 48000;

  /// How much of the tail to scan for the last complete page.
  static const int _tailBytes = 128 * 1024;

  static const int _maxDurationMs = 3153600000000;

  /// Sync parse for isolate entry points. Never throws.
  static ProbeResult? tryReadSync(String path) {
    if (!isOggPath(path)) return null;
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final length = file.lengthSync();
      if (length < 64) return null;
      raf = file.openSync(mode: FileMode.read);

      final first = _readPage(raf, 0, length);
      if (first == null) return null;
      final payload = _readAt(raf, first.payloadStart, first.payloadSize);
      if (payload == null) return null;

      int sampleRate;
      var hasPreSkip = false;
      var preSkip = 0;
      if (_startsWith(payload, 'OpusHead')) {
        sampleRate = _opusRate;
        if (payload.length < 12) return null;
        hasPreSkip = true;
        preSkip = payload[10] | (payload[11] << 8);
      } else if (payload.length >= 16 &&
          payload[0] == 0x01 &&
          _startsWith(payload, 'vorbis', 1)) {
        sampleRate = _u32le(payload, 12);
      } else {
        return null; // Speex / Theora / unknown codec
      }
      if (sampleRate <= 0) return null;

      final granule = _lastGranule(raf, length);
      if (granule == null || granule <= 0) return null;

      final samples = granule - (hasPreSkip ? preSkip : 0);
      if (samples <= 0) return null;
      final ms = (samples * 1000 / sampleRate).round();
      if (ms <= 0 || ms > _maxDurationMs) return null;
      return ProbeResult(durationMs: ms);
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  /// Walks the tail backwards for the newest page that actually completes a
  /// packet (granule != -1). A partially written trailing page is common on
  /// interrupted recordings and must not be read as the duration.
  static int? _lastGranule(RandomAccessFile raf, int length) {
    final window = length < _tailBytes ? length : _tailBytes;
    final start = length - window;
    final bytes = _readAt(raf, start, window);
    if (bytes == null) return null;

    for (var i = bytes.length - 4; i >= 0; i--) {
      if (bytes[i] != 0x4F ||
          bytes[i + 1] != 0x67 ||
          bytes[i + 2] != 0x67 ||
          bytes[i + 3] != 0x53) {
        continue;
      }
      if (i + 27 > bytes.length) continue;
      if (bytes[i + 4] != 0) continue; // page version must be 0
      final granule = _u64le(bytes, i + 6);
      if (granule < 0 || granule == 0) continue;
      return granule;
    }
    // The stream may end with a page that does not fit in the window (a huge
    // trailing page); one page further back is still a valid duration source.
    return null;
  }

  static _Page? _readPage(RandomAccessFile raf, int offset, int limit) {
    if (offset + 27 > limit) return null;
    final head = _readAt(raf, offset, 27);
    if (head == null) return null;
    if (!(head[0] == 0x4F &&
        head[1] == 0x67 &&
        head[2] == 0x67 &&
        head[3] == 0x53)) {
      return null;
    }
    if (head[4] != 0) return null;
    final segments = head[26];
    if (segments == 0) return null;
    final table = _readAt(raf, offset + 27, segments);
    if (table == null) return null;
    var payloadSize = 0;
    for (final s in table) {
      payloadSize += s;
    }
    if (payloadSize <= 0) return null;
    final payloadStart = offset + 27 + segments;
    if (payloadStart + payloadSize > limit) return null;
    return _Page(payloadStart: payloadStart, payloadSize: payloadSize);
  }

  static bool _startsWith(Uint8List bytes, String magic, [int offset = 0]) {
    return String.fromCharCodes(bytes, offset, offset + magic.length) == magic;
  }

  static Uint8List? _readAt(RandomAccessFile raf, int offset, int length) {
    if (offset < 0 || length < 0) return null;
    try {
      raf.setPositionSync(offset);
    } catch (_) {
      return null;
    }
    final bytes = raf.readSync(length);
    return bytes.length == length ? bytes : null;
  }

  static int _u32le(Uint8List bytes, int offset) =>
      (bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24)) &
      0xFFFFFFFF;

  /// Little-endian 64-bit granule, kept as a Dart int.
  static int _u64le(Uint8List bytes, int offset) {
    var value = 0;
    for (var i = 7; i >= 0; i--) {
      value = (value << 8) | bytes[offset + i];
    }
    return value;
  }
}

class _Page {
  const _Page({required this.payloadStart, required this.payloadSize});

  final int payloadStart;
  final int payloadSize;
}
