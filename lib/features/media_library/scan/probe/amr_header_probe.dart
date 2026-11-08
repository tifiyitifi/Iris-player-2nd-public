import 'dart:io';
import 'dart:typed_data';

import 'package:iris/features/media_library/scan/probe/media_probe.dart';

/// Reads duration from an AMR (adaptive multi-rate) voice stream.
///
/// WHY: the library's 496 `.amr` recordings are unsupported by every container
/// parser and are the slowest files for the platform prober, so they alone could
/// exhaust the metadata wait budget before any mp3 was reached.
///
/// AMR has no global header: it is a raw sequence of 20 ms frames, each
/// introduced by a one-byte header whose 4-bit frame type selects the frame
/// size from a fixed table. Duration is therefore exact only by walking the
/// frame chain — which is what this does, reading 64 KiB windows instead of one
/// byte at a time.
///
/// Deliberately NOT a decoder (no speech frames are touched beyond their length
/// byte). Unparseable chains stop early and return null.
abstract final class AmrHeaderProbe {
  static const Set<String> extensions = {'.amr', '.awb'};

  static bool isAmrPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return extensions.contains(path.substring(dot).toLowerCase());
  }

  /// One AMR frame is always 20 ms, independent of the mode.
  static const int _frameMs = 20;

  /// Bytes per frame INCLUDING the 1-byte header, indexed by frame type.
  /// Types 9–14 are speech-lost / no-data markers and 15 means "no data";
  /// anything outside the table ends the walk.
  static const List<int> _frameBytesNb = [13, 14, 16, 18, 20, 21, 27, 32, 6];
  static const List<int> _frameBytesWb = [18, 19, 21, 22, 24, 25, 28, 33, 6];

  /// Files above this size are estimated from a sample instead of a full walk:
  /// AMR is a speech format, so a multi-megabyte file is already exceptional and
  /// must not dominate a scan.
  static const int _fullWalkLimit = 32 * 1024 * 1024;

  /// Window used both for the walk and for the estimate.
  static const int _windowBytes = 64 * 1024;

  static const int _maxDurationMs = 3153600000000;

  /// Sync parse for isolate entry points. Never throws.
  static ProbeResult? tryReadSync(String path) {
    if (!isAmrPath(path)) return null;
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final length = file.lengthSync();
      if (length < 8) return null;
      raf = file.openSync(mode: FileMode.read);

      final head = raf.readSync(9);
      List<int> table;
      int audioStart;
      if (_matches(head, '#!AMR-WB\n')) {
        table = _frameBytesWb;
        audioStart = 9;
      } else if (_matches(head, '#!AMR\n')) {
        table = _frameBytesNb;
        audioStart = 6;
      } else {
        return null;
      }
      if (audioStart >= length) return null;

      final frames = length - audioStart <= _fullWalkLimit
          ? _countFrames(raf, audioStart, length, table)
          : _estimateFrames(raf, audioStart, length, table);
      if (frames == null || frames <= 0) return null;

      final ms = frames * _frameMs;
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

  /// Exact frame count by walking the frame chain over windowed reads.
  static int _countFrames(
    RandomAccessFile raf,
    int start,
    int length,
    List<int> table,
  ) {
    var pos = start;
    var frames = 0;
    Uint8List? window;
    var windowStart = -1;
    // The largest frame is 33 bytes; keep enough lookahead to read any header
    // without leaving the window.
    const lookahead = 40;

    while (pos < length) {
      if (window == null ||
          pos - windowStart + lookahead > window.length) {
        final want = (length - pos).clamp(0, _windowBytes);
        window = _readAt(raf, pos, want);
        windowStart = pos;
        if (window == null || window.isEmpty) break;
      }
      final index = pos - windowStart;
      if (index < 0 || index >= window.length) break;
      final frameType = (window[index] >> 3) & 0x0F;
      if (frameType >= table.length) break;
      final size = table[frameType];
      if (size <= 0 || pos + size > length) break;
      pos += size;
      frames++;
    }
    return frames;
  }

  /// Frame-count estimate for oversized files: measure the mean frame size over
  /// the first window and extrapolate. Mixed modes make this approximate, which
  /// is why it is only used where a full walk would be disproportionate.
  static int? _estimateFrames(
    RandomAccessFile raf,
    int start,
    int length,
    List<int> table,
  ) {
    final window = _readAt(raf, start, _windowBytes);
    if (window == null || window.length < 64) return null;
    var pos = 0;
    var frames = 0;
    while (pos < window.length) {
      final frameType = (window[pos] >> 3) & 0x0F;
      if (frameType >= table.length) break;
      final size = table[frameType];
      if (size <= 0 || pos + size > window.length) break;
      pos += size;
      frames++;
    }
    if (frames == 0 || pos == 0) return null;
    final meanBytes = pos / frames;
    return ((length - start) / meanBytes).round();
  }

  static bool _matches(Uint8List bytes, String magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic.codeUnitAt(i)) return false;
    }
    return true;
  }

  static Uint8List? _readAt(RandomAccessFile raf, int offset, int length) {
    if (offset < 0 || length < 0) return null;
    try {
      raf.setPositionSync(offset);
    } catch (_) {
      return null;
    }
    final bytes = raf.readSync(length);
    return bytes.isEmpty ? null : bytes;
  }
}
