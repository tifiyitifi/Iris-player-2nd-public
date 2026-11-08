import 'dart:io';
import 'dart:typed_data';

import 'package:iris/features/media_library/scan/probe/media_probe.dart';

/// Reads duration / dimensions straight from a RIFF/AVI header.
///
/// WHY: same reason as the MP4 parser — the Windows Shell property handler is
/// 30–70 ms per file, while `hdrl/avih` already carries everything needed
/// (`dwMicroSecPerFrame` × `dwTotalFrames`, plus the frame size). Two chunk
/// walks and ~24 bytes of payload give an answer in ~1 ms.
///
/// Deliberately NOT a demuxer: no index, no streams, no decoding. Files without
/// a usable `avih` (rare, or OpenDML variants that keep frames elsewhere) return
/// null so the caller falls back to the platform probe.
abstract final class AviHeaderProbe {
  static const Set<String> extensions = {'.avi', '.divx'};

  static bool isAviPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return extensions.contains(path.substring(dot).toLowerCase());
  }

  /// Guard against a malformed file whose chunk sizes keep looking valid.
  static const int _maxChunks = 256;

  /// `avih` (AVIMAINHEADER) is fixed at 56 bytes; the first 40 carry the values.
  static const int _avihBytes = 40;

  /// Sync parse for isolate entry points. Never throws.
  static ProbeResult? tryReadSync(String path) {
    if (!isAviPath(path)) return null;
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final length = file.lengthSync();
      if (length < 24) return null;
      raf = file.openSync(mode: FileMode.read);

      final head = _readAt(raf, 0, 12);
      if (head == null || _ascii(head, 0) != 'RIFF' || _ascii(head, 8) != 'AVI ') {
        return null;
      }
      final riffSize = _u32le(head, 4);
      // The RIFF size counts everything after the size field; clamp to the real
      // file length so a truncated download cannot make us read past EOF.
      final end = (8 + riffSize).clamp(12, length);

      final hdrl = _findList(raf, 'hdrl', 12, end);
      if (hdrl == null) return null;
      final avih = _findChunk(raf, 'avih', hdrl.$1, hdrl.$2);
      if (avih == null || avih.size < _avihBytes) return null;
      final payload = _readAt(raf, avih.payloadStart, _avihBytes);
      if (payload == null) return null;

      final microsPerFrame = _u32le(payload, 0);
      final totalFrames = _u32le(payload, 16);
      final width = _u32le(payload, 32);
      final height = _u32le(payload, 36);
      if (microsPerFrame <= 0 || totalFrames <= 0) return null;
      final ms = (microsPerFrame * totalFrames) ~/ 1000;
      if (ms <= 0 || ms > 3153600000000) return null;
      return ProbeResult(
        durationMs: ms,
        width: width > 0 ? width : null,
        height: height > 0 ? height : null,
      );
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  /// Finds a top-level `LIST` chunk of type [type] and returns its child range.
  static (int, int)? _findList(
    RandomAccessFile raf,
    String type,
    int start,
    int end,
  ) {
    var offset = start;
    for (var i = 0; i < _maxChunks && offset + 8 <= end; i++) {
      final chunk = _readChunk(raf, offset, end);
      if (chunk == null) return null;
      if (chunk.id == 'LIST') {
        final typeBytes = _readAt(raf, chunk.payloadStart, 4);
        if (typeBytes != null && _ascii(typeBytes, 0) == type) {
          final childStart = chunk.payloadStart + 4;
          return (childStart, chunk.payloadStart + chunk.size);
        }
      }
      offset = _nextChunkOffset(chunk);
    }
    return null;
  }

  static _Chunk? _findChunk(
    RandomAccessFile raf,
    String id,
    int start,
    int end,
  ) {
    var offset = start;
    for (var i = 0; i < _maxChunks && offset + 8 <= end; i++) {
      final chunk = _readChunk(raf, offset, end);
      if (chunk == null) return null;
      if (chunk.id == id) return chunk;
      offset = _nextChunkOffset(chunk);
    }
    return null;
  }

  /// Chunks are word aligned: an odd payload is followed by one pad byte.
  static int _nextChunkOffset(_Chunk chunk) =>
      chunk.payloadStart + chunk.size + (chunk.size & 1);

  static _Chunk? _readChunk(RandomAccessFile raf, int offset, int limit) {
    if (offset + 8 > limit) return null;
    final head = _readAt(raf, offset, 8);
    if (head == null) return null;
    final id = _ascii(head, 0);
    final size = _u32le(head, 4);
    final payloadStart = offset + 8;
    if (size < 0 || payloadStart + size > limit) return null;
    return _Chunk(id: id, size: size, payloadStart: payloadStart);
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

class _Chunk {
  const _Chunk({
    required this.id,
    required this.size,
    required this.payloadStart,
  });

  final String id;
  final int size;
  final int payloadStart;
}
