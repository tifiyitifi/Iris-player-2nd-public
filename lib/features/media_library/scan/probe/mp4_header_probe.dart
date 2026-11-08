import 'dart:io';
import 'dart:typed_data';

import 'package:iris/features/media_library/scan/probe/media_probe.dart';

/// Reads duration / dimensions straight from an ISO-BMFF (MP4/MOV/M4A) header.
///
/// WHY this exists: the Windows Shell property handler is the slowest possible
/// way to learn a duration (measured 30-70 ms/file on a warm cache — the
/// property handler is re-run on every access). The value itself lives in the
/// `moov` box: `mvhd` carries timescale/duration, `tkhd` carries the frame
/// size. Parsing those two boxes costs ~1 ms/file and reads a few hundred
/// bytes, because `mdat` is skipped with a seek and never transferred — the
/// same strategy VLC's demuxer uses (`libmp4.c`, mdat handled by
/// `MP4_ReadBoxSkip` + seek).
///
/// Deliberately NOT a demuxer: no sample tables, no codec info, no decoding.
/// Anything it cannot answer (fragmented MP4 whose `mvhd` duration is 0,
/// damaged headers, non-MP4 containers) returns null so the caller can fall
/// back to the platform probe.
abstract final class Mp4HeaderProbe {
  /// Extensions worth attempting. The parser also validates the box structure,
  /// so a mislabelled file simply returns null.
  static const Set<String> extensions = {
    '.mp4',
    '.m4v',
    '.mov',
    '.m4a',
    '.3gp',
    '.3g2',
    '.f4v',
  };

  /// Hard bound on boxes walked at one nesting level; guards against a
  /// malformed file whose sizes keep producing "valid" headers.
  static const int _maxBoxes = 1024;

  static bool isMp4Path(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return extensions.contains(path.substring(dot).toLowerCase());
  }

  /// Sync parse for isolate entry points. Never throws.
  ///
  /// Returns null when the file is not MP4, unreadable, fragmented (no usable
  /// `mvhd` duration) or structurally broken.
  static ProbeResult? tryReadSync(String path) {
    if (!isMp4Path(path)) return null;
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final length = file.lengthSync();
      if (length < 24) return null;
      raf = file.openSync(mode: FileMode.read);

      final moov = _findTopLevelBox(raf, length, 'moov');
      if (moov == null) return null;

      final mvhd = _findChildBox(raf, moov, 'mvhd', maxBoxes: 64);
      if (mvhd == null) return null;
      final durationMs = _readMvhdDurationMs(raf, mvhd);
      if (durationMs == null) return null;

      final dims = _readFirstTrackDimensions(raf, moov);
      return ProbeResult(
        durationMs: durationMs,
        width: dims?.$1,
        height: dims?.$2,
      );
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  static _Box? _findTopLevelBox(
      RandomAccessFile raf, int fileLength, String type) {
    var offset = 0;
    for (var i = 0; i < _maxBoxes; i++) {
      final box = _readBox(raf, offset, fileLength);
      if (box == null) return null;
      if (box.type == type) return box;
      offset = box.start + box.size;
      if (offset >= fileLength) return null;
    }
    return null;
  }

  static _Box? _findChildBox(
    RandomAccessFile raf,
    _Box parent,
    String type, {
    int maxBoxes = 256,
  }) {
    final end = parent.payloadStart + parent.payloadSize;
    var offset = parent.payloadStart;
    for (var i = 0; i < maxBoxes && offset + 8 <= end; i++) {
      final box = _readBox(raf, offset, end);
      if (box == null) return null;
      if (box.type == type) return box;
      offset = box.start + box.size;
    }
    return null;
  }

  static _Box? _readBox(RandomAccessFile raf, int offset, int limit) {
    if (offset < 0 || offset + 8 > limit) return null;
    raf.setPositionSync(offset);
    final head = raf.readSync(8);
    if (head.length != 8) return null;
    final shortSize = _u32(head, 0);
    final type = String.fromCharCodes(head.sublist(4, 8));

    var headerSize = 8;
    var size = shortSize;
    if (shortSize == 1) {
      // 64-bit largesize follows the type field.
      if (offset + 16 > limit) return null;
      final large = raf.readSync(8);
      if (large.length != 8) return null;
      size = _u64(large, 0);
      headerSize = 16;
    } else if (shortSize == 0) {
      // Extends to the end of the enclosing container.
      size = limit - offset;
    }
    if (size < headerSize || offset + size > limit) return null;

    return _Box(
      start: offset,
      size: size,
      payloadStart: offset + headerSize,
      payloadSize: size - headerSize,
      type: type,
    );
  }

  /// `mvhd` → timescale + duration, in the version-0/version-1 layouts.
  static int? _readMvhdDurationMs(RandomAccessFile raf, _Box mvhd) {
    // 4 (version+flags) + up to 16 (v1 creation/modification) + 4 timescale
    // + 8 duration = 32 bytes.
    raf.setPositionSync(mvhd.payloadStart);
    final b = raf.readSync(32);
    if (b.length < 20) return null;
    final version = b[0];
    final int timescale;
    final int duration;
    if (version == 1) {
      if (b.length < 32) return null;
      timescale = _u32(b, 20);
      duration = _u64(b, 24);
    } else {
      timescale = _u32(b, 12);
      duration = _u32(b, 16);
    }
    if (timescale <= 0 || duration <= 0) return null;
    final ms = (duration * 1000) ~/ timescale;
    // A corrupt header can encode an absurd duration; 100 years is far outside
    // anything playable and keeps the sort sane.
    if (ms <= 0 || ms > 3153600000000) return null;
    return ms;
  }

  /// Walks `moov` for the first `trak/tkhd` that declares a non-zero frame
  /// size (the audio track's tkhd reports 0×0 and is skipped).
  static (int, int)? _readFirstTrackDimensions(
      RandomAccessFile raf, _Box moov) {
    final end = moov.payloadStart + moov.payloadSize;
    var offset = moov.payloadStart;
    for (var i = 0; i < 64 && offset + 8 <= end; i++) {
      final box = _readBox(raf, offset, end);
      if (box == null) return null;
      if (box.type == 'trak') {
        final tkhd = _findChildBox(raf, box, 'tkhd', maxBoxes: 16);
        if (tkhd != null) {
          final dims = _readTkhdDimensions(raf, tkhd);
          if (dims != null) return dims;
        }
      }
      offset = box.start + box.size;
    }
    return null;
  }

  /// `tkhd` → width/height as 16.16 fixed point at the end of the box.
  ///
  /// Offsets: 4 (version+flags) + [v0: 20 / v1: 32] fixed fields
  /// + 52 (reserved, layer, group, volume, matrix) → width/height.
  static (int, int)? _readTkhdDimensions(RandomAccessFile raf, _Box tkhd) {
    raf.setPositionSync(tkhd.payloadStart);
    final b = raf.readSync(96);
    if (b.length < 84) return null;
    final version = b[0];
    final int base = version == 1 ? 36 : 24;
    final int widthAt = base + 52;
    if (b.length < widthAt + 8) return null;
    final w = _u32(b, widthAt) >> 16;
    final h = _u32(b, widthAt + 4) >> 16;
    if (w <= 0 || h <= 0) return null;
    return (w, h);
  }

  static int _u32(Uint8List b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static int _u64(Uint8List b, int o) => (_u32(b, o) << 32) | _u32(b, o + 4);
}

/// One parsed box header. [size] includes the header; [payloadStart] points at
/// the first payload byte and [payloadSize] excludes the header.
class _Box {
  const _Box({
    required this.start,
    required this.size,
    required this.payloadStart,
    required this.payloadSize,
    required this.type,
  });

  final int start;
  final int size;
  final int payloadStart;
  final int payloadSize;
  final String type;
}
