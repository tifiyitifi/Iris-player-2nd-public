import 'dart:io';
import 'dart:typed_data';

import 'package:iris/features/media_library/scan/probe/media_probe.dart';

/// Reads duration straight from a RIFF/WAVE header.
///
/// WHY: same reason as [Mp3HeaderProbe]. A WAV answers the question with two
/// chunk headers — `fmt ` carries the byte rate, `data` carries the payload
/// size — so duration is one division instead of a platform probe.
///
/// Deliberately NOT a demuxer: no sample decoding, no `LIST`/`INFO` tags. Files
/// with a `data` size of 0 or a streamed/unknown layout (RF64, W64) return null
/// so the platform probe still gets its turn.
abstract final class WavHeaderProbe {
  static const Set<String> extensions = {'.wav', '.wave'};

  static bool isWavPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return extensions.contains(path.substring(dot).toLowerCase());
  }

  /// Guard against a malformed file whose chunk sizes keep looking valid.
  static const int _maxChunks = 512;

  /// `fmt ` needs 16 bytes for the classic PCM layout; the byte rate is at 8.
  static const int _fmtBytes = 16;

  static const int _maxDurationMs = 3153600000000;

  /// Sync parse for isolate entry points. Never throws.
  static ProbeResult? tryReadSync(String path) {
    if (!isWavPath(path)) return null;
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final length = file.lengthSync();
      if (length < 24) return null;
      raf = file.openSync(mode: FileMode.read);

      final head = raf.readSync(12);
      if (head.length < 12) return null;
      if (_ascii(head, 0) != 'RIFF' || _ascii(head, 8) != 'WAVE') return null;
      // The RIFF size counts everything after the size field; clamp to the real
      // file length so a truncated download cannot make us walk past EOF.
      final riffSize = _u32le(head, 4);
      var end = 8 + riffSize;
      if (end > length || end <= 12) end = length;

      int? byteRate;
      int? dataSize;
      var offset = 12;
      for (var i = 0; i < _maxChunks && offset + 8 <= end; i++) {
        final chunkHead = _readAt(raf, offset, 8);
        if (chunkHead == null) break;
        final id = _ascii(chunkHead, 0);
        final size = _u32le(chunkHead, 4);
        final payloadStart = offset + 8;
        if (size < 0 || payloadStart + size > end) break;

        if (id == 'fmt ') {
          if (size < _fmtBytes) return null;
          final fmt = _readAt(raf, payloadStart, _fmtBytes);
          if (fmt == null) return null;
          byteRate = _u32le(fmt, 8);
        } else if (id == 'data') {
          dataSize = size;
          // `fmt ` precedes `data` in every well-formed file; with both values
          // there is nothing left to walk.
          if (byteRate != null) break;
        }
        offset = payloadStart + size + (size & 1); // chunks are word aligned
      }

      if (byteRate == null || dataSize == null) return null;
      if (byteRate <= 0 || dataSize <= 0) return null;
      final ms = (dataSize * 1000 / byteRate).round();
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

  static String _ascii(Uint8List bytes, int offset) =>
      String.fromCharCodes(bytes, offset, offset + 4);

  static int _u32le(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}
