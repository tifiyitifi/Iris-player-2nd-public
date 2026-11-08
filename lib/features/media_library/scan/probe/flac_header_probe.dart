import 'dart:io';

import 'package:iris/features/media_library/scan/probe/media_probe.dart';

/// Reads duration straight from a FLAC `STREAMINFO` metadata block.
///
/// WHY: same reason as [Mp3HeaderProbe] — without a parser every FLAC fell
/// through to the platform prober at tens of milliseconds per file, and the
/// metadata wait budget gave up long before the library was covered.
///
/// `STREAMINFO` is mandatory and is the first metadata block, so this is a
/// 42-byte read: 4-byte `fLaC` marker, 4-byte block header, then the 64-bit
/// field holding sample rate (20 bits) and total samples (36 bits).
/// Deliberately NOT a decoder: no frames, no tags, no audio data.
abstract final class FlacHeaderProbe {
  static const Set<String> extensions = {'.flac'};

  static bool isFlacPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return extensions.contains(path.substring(dot).toLowerCase());
  }

  /// `fLaC` (4) + block header (4) + STREAMINFO payload (34).
  static const int _headerBytes = 42;

  /// STREAMINFO block type in the metadata block header's low 7 bits.
  static const int _streamInfoType = 0;

  static const int _maxDurationMs = 3153600000000;

  /// Sync parse for isolate entry points. Never throws.
  static ProbeResult? tryReadSync(String path) {
    if (!isFlacPath(path)) return null;
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      if (file.lengthSync() < _headerBytes) return null;
      raf = file.openSync(mode: FileMode.read);

      final head = raf.readSync(_headerBytes);
      if (head.length < _headerBytes) return null;
      if (head[0] != 0x66 || head[1] != 0x4C ||
          head[2] != 0x61 || head[3] != 0x43) {
        return null; // "fLaC"
      }
      // The first block must be STREAMINFO (type 0). A stream id (0x7F) or
      // another type means this is not a plain FLAC header.
      final type = head[4] & 0x7F;
      if (type != _streamInfoType) return null;
      // Length is 24-bit big-endian and STREAMINFO is fixed at 34 bytes.
      final size = (head[5] << 16) | (head[6] << 8) | head[7];
      if (size < 34) return null;

      // Payload starts at byte 8. Both fields live in bytes 10..17:
      //   sample rate : 20 bits
      //   channels    : 3 bits
      //   bits/sample : 5 bits
      //   total samples: 36 bits
      final sampleRate = (head[18] << 12) | (head[19] << 4) | (head[20] >> 4);
      final totalSamples = ((head[21] & 0x0F) << 32) |
          (head[22] << 24) |
          (head[23] << 16) |
          (head[24] << 8) |
          head[25];
      if (sampleRate <= 0 || totalSamples <= 0) return null;

      final ms = (totalSamples * 1000 / sampleRate).round();
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
}
