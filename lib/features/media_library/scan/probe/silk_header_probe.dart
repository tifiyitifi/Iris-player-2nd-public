import 'dart:io';
import 'dart:typed_data';

import 'package:iris/features/media_library/scan/probe/media_probe.dart';

/// Reads duration from a Tencent SILK v3 voice file.
///
/// WHY: the phone library's 496 `.amr` files are not AMR at all — WeChat writes
/// SILK v3 (`\x02#!SILK_V3`) under an `.amr` name, and neither the platform
/// retriever nor an AMR frame walk can read it. Those 496 rows were the only
/// audio left without a duration after a full scan (measured: 19,859/20,356
/// resolved, the remainder exactly these).
///
/// SILK has no duration header: it is a flat sequence of `[uint16 length]`
/// packets, each holding 20 ms of speech (the rate WeChat records at). The
/// duration is therefore the packet count × 20 ms, which needs a sequential walk
/// of the length prefixes — the payload bytes themselves are skipped, never read.
abstract final class SilkHeaderProbe {
  static const Set<String> extensions = {'.amr', '.silk', '.slk'};

  static bool isSilkPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return extensions.contains(path.substring(dot).toLowerCase());
  }

  /// Tencent's container magic: a 0x02 version byte then `#!SILK_V3`.
  static const List<int> _magic = [
    0x23, 0x21, 0x53, 0x49, 0x4C, 0x4B, 0x5F, 0x56, 0x33, // "#!SILK_V3"
  ];

  /// One packet carries 20 ms of audio at WeChat's recording profile.
  static const int _packetMs = 20;

  /// Files above this size are estimated from a sample: a SILK voice note is
  /// tiny, so a huge one is already exceptional.
  static const int _fullWalkLimit = 8 * 1024 * 1024;

  static const int _maxDurationMs = 3153600000000;

  /// Sync parse for isolate entry points. Never throws.
  static ProbeResult? tryReadSync(String path) {
    if (!isSilkPath(path)) return null;
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final length = file.lengthSync();
      if (length < 16) return null;
      raf = file.openSync(mode: FileMode.read);

      final head = raf.readSync(11);
      final magicOffset = _magicOffset(head);
      if (magicOffset < 0) return null;
      final audioStart = magicOffset + _magic.length;
      if (audioStart >= length) return null;

      final packets = length - audioStart <= _fullWalkLimit
          ? _countPackets(raf, audioStart, length)
          : _estimatePackets(raf, audioStart, length);
      if (packets == null || packets <= 0) return null;

      final ms = packets * _packetMs;
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

  /// -1 when [head] is not SILK; otherwise the index of the `#!` magic (0 or 1,
  /// because the container puts a version byte in front).
  static int _magicOffset(Uint8List head) {
    for (var offset = 0; offset <= 1; offset++) {
      if (head.length < offset + _magic.length) continue;
      var match = true;
      for (var i = 0; i < _magic.length; i++) {
        if (head[offset + i] != _magic[i]) {
          match = false;
          break;
        }
      }
      if (match) return offset;
    }
    return -1;
  }

  /// Walks the packet chain, counting without reading payloads.
  static int? _countPackets(RandomAccessFile raf, int start, int length) {
    var pos = start;
    var packets = 0;
    while (pos + 2 <= length) {
      raf.setPositionSync(pos);
      final sizeBytes = raf.readSync(2);
      if (sizeBytes.length < 2) break;
      final size = sizeBytes[0] | (sizeBytes[1] << 8);
      // 0 / 0xFFFF are terminators, and a size past EOF means the chain is
      // damaged: either way the count so far is the honest answer.
      if (size <= 0 || size == 0xFFFF) break;
      pos += 2 + size;
      if (pos > length) break;
      packets++;
    }
    return packets;
  }

  /// Packet-count estimate for oversized files: measure the mean packet size
  /// over the first 64 KiB and extrapolate.
  static int? _estimatePackets(RandomAccessFile raf, int start, int length) {
    raf.setPositionSync(start);
    final window = raf.readSync(64 * 1024);
    if (window.length < 64) return null;
    var pos = 0;
    var packets = 0;
    while (pos + 2 <= window.length) {
      final size = window[pos] | (window[pos + 1] << 8);
      if (size <= 0 || size == 0xFFFF) break;
      pos += 2 + size;
      if (pos > window.length) break;
      packets++;
    }
    if (packets == 0 || pos == 0) return null;
    final meanBytes = pos / packets;
    return ((length - start) / meanBytes).round();
  }
}
