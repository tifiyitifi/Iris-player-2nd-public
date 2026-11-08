import 'dart:io';
import 'dart:typed_data';

import 'package:iris/features/media_library/scan/probe/media_probe.dart';

/// Reads duration / dimensions straight from a Matroska (MKV/WebM) header.
///
/// WHY this exists: the Windows Shell property handler costs 30–70 ms per file,
/// which is what made "wait for metadata, then play in duration order"
/// impossible for anything the MP4 header parser could not answer. The values
/// live in two small EBML elements — `Segment/Info` (`TimecodeScale` +
/// `Duration`) and `Segment/Tracks/TrackEntry/Video` (`PixelWidth/Height`) —
/// and reading them costs a couple of seeks plus a few hundred bytes, the same
/// order as the MP4 path.
///
/// Deliberately NOT a demuxer: no clusters, no codec info, no decoding. Files it
/// cannot answer (live/streaming recordings without a `Duration`, damaged
/// headers) return null so the caller falls back to the platform probe.
abstract final class MkvHeaderProbe {
  /// Extensions worth attempting. The parser also validates the EBML structure,
  /// so a mislabelled file simply returns null.
  static const Set<String> extensions = {'.mkv', '.webm', '.mka', '.mks'};

  static bool isMkvPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return extensions.contains(path.substring(dot).toLowerCase());
  }

  // EBML element ids, marker bits included (that is how they are stored).
  static const int _idSegment = 0x18538067;
  static const int _idInfo = 0x1549A966;
  static const int _idTimecodeScale = 0x2AD7B1;
  static const int _idDuration = 0x4489;
  static const int _idTracks = 0x1654AE6B;
  static const int _idTrackEntry = 0xAE;
  static const int _idVideo = 0xE0;
  static const int _idPixelWidth = 0xB0;
  static const int _idPixelHeight = 0xBA;
  static const int _idCluster = 0x1F43B675;

  /// Bounds so a malformed header cannot make the probe read a whole file.
  static const int _maxInfoBytes = 1 << 20;
  static const int _maxTracksBytes = 4 << 20;
  static const int _maxElements = 4096;

  /// Sync parse for isolate entry points. Never throws.
  static ProbeResult? tryReadSync(String path) {
    if (!isMkvPath(path)) return null;
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final length = file.lengthSync();
      if (length < 64) return null;
      raf = file.openSync(mode: FileMode.read);

      final segment = _findSegment(raf, length);
      if (segment == null) return null;

      final info = _findChild(raf, segment, _idInfo);
      if (info == null) return null;
      final durationMs = _readTiming(_readPayload(raf, info, _maxInfoBytes));
      if (durationMs == null) return null;

      final tracks = _findChild(raf, segment, _idTracks);
      final dims = tracks == null
          ? null
          : _readVideoDimensions(_readPayload(raf, tracks, _maxTracksBytes));
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

  /// Walks the top level for the `Segment` element.
  static _Element? _findSegment(RandomAccessFile raf, int length) {
    var offset = 0;
    for (var i = 0; i < 32 && offset < length; i++) {
      final element = _readElement(raf, offset, length);
      if (element == null) return null;
      if (element.id == _idSegment) return element;
      // A top-level element with an unknown size would swallow everything after
      // it; nothing else can be located then.
      if (element.unknownSize) return null;
      offset = element.payloadStart + element.payloadSize;
    }
    return null;
  }

  /// Finds [id] among the segment's direct children.
  static _Element? _findChild(
    RandomAccessFile raf,
    _Element parent,
    int id,
  ) {
    final end = parent.payloadStart + parent.payloadSize;
    var offset = parent.payloadStart;
    for (var i = 0; i < _maxElements && offset < end; i++) {
      final element = _readElement(raf, offset, end);
      if (element == null) return null;
      if (element.id == id) return element;
      // `Info` / `Tracks` precede the first cluster in every well-formed file;
      // once a cluster is reached the wanted header is simply not there.
      if (element.id == _idCluster) return null;
      if (element.unknownSize) return null;
      offset = element.payloadStart + element.payloadSize;
    }
    return null;
  }

  /// Reads `Info` → duration in ms (`Duration` is in `TimecodeScale` ticks).
  static int? _readTiming(Uint8List? info) {
    if (info == null) return null;
    int? timecodeScale; // nanoseconds per tick
    double? durationTicks;
    var offset = 0;
    for (var i = 0; i < 256 && offset < info.length; i++) {
      final element = _readMemoryElement(info, offset);
      if (element == null) return null;
      offset = element.payloadStart + element.payloadSize;
      if (element.id == _idTimecodeScale) {
        timecodeScale = _readUint(info, element.payloadStart, element.payloadSize);
      } else if (element.id == _idDuration) {
        durationTicks =
            _readFloat(info, element.payloadStart, element.payloadSize);
      }
      if (timecodeScale != null && durationTicks != null) break;
    }
    final ticks = durationTicks;
    if (ticks == null || !ticks.isFinite || ticks <= 0) return null;
    // Matroska's default scale is 1 000 000 ns (= 1 ms per tick).
    final nsPerTick = timecodeScale ?? 1000000;
    if (nsPerTick <= 0) return null;
    final ms = (ticks * nsPerTick / 1000000).round();
    // Same sanity ceiling as the MP4 parser: a corrupt header can encode
    // centuries, and that would poison duration sorting.
    if (ms <= 0 || ms > 3153600000000) return null;
    return ms;
  }

  /// First `TrackEntry` that carries a `Video` element with usable dimensions
  /// (audio/subtitle tracks have none).
  static (int, int)? _readVideoDimensions(Uint8List? tracks) {
    if (tracks == null) return null;
    var offset = 0;
    for (var i = 0; i < 512 && offset < tracks.length; i++) {
      final entry = _readMemoryElement(tracks, offset);
      if (entry == null) return null;
      offset = entry.payloadStart + entry.payloadSize;
      if (entry.id != _idTrackEntry) continue;
      final dims = _readVideo(tracks, entry);
      if (dims != null) return dims;
    }
    return null;
  }

  static (int, int)? _readVideo(Uint8List bytes, _Element entry) {
    final end = entry.payloadStart + entry.payloadSize;
    var offset = entry.payloadStart;
    for (var i = 0; i < 64 && offset < end; i++) {
      final element = _readMemoryElement(bytes, offset, end);
      if (element == null) return null;
      offset = element.payloadStart + element.payloadSize;
      if (element.id != _idVideo) continue;
      int? width;
      int? height;
      var inner = element.payloadStart;
      final videoEnd = element.payloadStart + element.payloadSize;
      for (var j = 0; j < 32 && inner < videoEnd; j++) {
        final child = _readMemoryElement(bytes, inner, videoEnd);
        if (child == null) break;
        inner = child.payloadStart + child.payloadSize;
        if (child.id == _idPixelWidth) {
          width = _readUint(bytes, child.payloadStart, child.payloadSize);
        } else if (child.id == _idPixelHeight) {
          height = _readUint(bytes, child.payloadStart, child.payloadSize);
        }
      }
      if (width != null && height != null && width > 0 && height > 0) {
        return (width, height);
      }
      // A video track without a usable size (an attached cover, a damaged
      // entry) must not hide the real one: keep looking at the next track.
    }
    return null;
  }

  static Uint8List? _readPayload(
    RandomAccessFile raf,
    _Element element,
    int cap,
  ) {
    if (element.payloadSize <= 0 || element.payloadSize > cap) return null;
    raf.setPositionSync(element.payloadStart);
    final bytes = raf.readSync(element.payloadSize);
    return bytes.length == element.payloadSize ? bytes : null;
  }

  static _Element? _readElement(RandomAccessFile raf, int offset, int limit) {
    if (offset < 0 || offset + 2 > limit) return null;
    raf.setPositionSync(offset);
    final id = _readVint(raf, keepMarker: true);
    if (id == null) return null;
    final size = _readVint(raf, keepMarker: false);
    if (size == null) return null;
    final payloadStart = offset + id.length + size.length;
    if (payloadStart > limit) return null;
    final available = limit - payloadStart;
    final payloadSize = size.unknown ? available : size.value;
    if (payloadSize < 0 || payloadSize > available) return null;
    return _Element(
      id: id.value,
      payloadStart: payloadStart,
      payloadSize: payloadSize,
      unknownSize: size.unknown,
    );
  }

  static ({int value, int length, bool unknown})? _readVint(
    RandomAccessFile raf, {
    required bool keepMarker,
  }) {
    final firstBytes = raf.readSync(1);
    if (firstBytes.isEmpty) return null;
    final first = firstBytes[0];
    final length = _vintLength(first);
    if (length == 0) return null;
    var value = keepMarker ? first : (first & (0xFF >> length));
    for (var i = 1; i < length; i++) {
      final b = raf.readSync(1);
      if (b.isEmpty) return null;
      value = (value << 8) | b[0];
    }
    final bool unknown =
        !keepMarker && value == (1 << (7 * length)) - 1;
    return (value: value, length: length, unknown: unknown);
  }

  /// Same walk as [_readElement] over an in-memory payload (a `Info` / `Tracks`
  /// body), which is cheaper than seeking per child.
  static _Element? _readMemoryElement(
    Uint8List bytes,
    int offset, [
    int? end,
  ]) {
    final limit = end ?? bytes.length;
    if (offset < 0 || offset + 2 > limit) return null;
    final idFirst = bytes[offset];
    final idLength = _vintLength(idFirst);
    if (idLength == 0 || offset + idLength >= limit) return null;
    var id = idFirst;
    for (var i = 1; i < idLength; i++) {
      id = (id << 8) | bytes[offset + i];
    }
    final sizeOffset = offset + idLength;
    final sizeFirst = bytes[sizeOffset];
    final sizeLength = _vintLength(sizeFirst);
    if (sizeLength == 0 || sizeOffset + sizeLength > limit) return null;
    var size = sizeFirst & (0xFF >> sizeLength);
    for (var i = 1; i < sizeLength; i++) {
      size = (size << 8) | bytes[sizeOffset + i];
    }
    final payloadStart = sizeOffset + sizeLength;
    final available = limit - payloadStart;
    if (available < 0) return null;
    final unknown = size == (1 << (7 * sizeLength)) - 1;
    final payloadSize = unknown ? available : size;
    if (payloadSize < 0 || payloadSize > available) return null;
    return _Element(
      id: id,
      payloadStart: payloadStart,
      payloadSize: payloadSize,
      unknownSize: unknown,
    );
  }

  /// Bytes of a VINT inspected from its first byte (marker/prefix determines
  /// the total length).
  static int _vintLength(int first) {
    if (first & 0x80 != 0) return 1;
    if (first & 0x40 != 0) return 2;
    if (first & 0x20 != 0) return 3;
    if (first & 0x10 != 0) return 4;
    if (first & 0x08 != 0) return 5;
    if (first & 0x04 != 0) return 6;
    if (first & 0x02 != 0) return 7;
    if (first & 0x01 != 0) return 8;
    return 0;
  }

  static int? _readUint(Uint8List bytes, int start, int length) {
    if (length <= 0 || length > 8 || start < 0 || start + length > bytes.length) {
      return null;
    }
    var value = 0;
    for (var i = 0; i < length; i++) {
      value = (value << 8) | bytes[start + i];
    }
    return value;
  }

  static double? _readFloat(Uint8List bytes, int start, int length) {
    if (start < 0 || start + length > bytes.length) return null;
    if (length != 4 && length != 8) return null;
    final view = ByteData.sublistView(bytes, start, start + length);
    return length == 4
        ? view.getFloat32(0, Endian.big)
        : view.getFloat64(0, Endian.big);
  }
}

/// One parsed EBML element header.
class _Element {
  const _Element({
    required this.id,
    required this.payloadStart,
    required this.payloadSize,
    required this.unknownSize,
  });

  final int id;
  final int payloadStart;
  final int payloadSize;
  final bool unknownSize;
}
