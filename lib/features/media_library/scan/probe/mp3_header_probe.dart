import 'dart:io';
import 'dart:typed_data';

import 'package:iris/features/media_library/scan/probe/media_probe.dart';

/// Reads duration straight from an MPEG audio (MP3 / MP2 / MP1) stream.
///
/// WHY: measured on a 2019 Android 10 phone, the library was 19,688 mp3 + 496
/// amr + 551 mp4. The header dispatcher only knew MP4 / MKV / AVI, so 94% of the
/// files fell through to `MediaMetadataRetriever` at 14–28 ms each (~5 minutes
/// for the whole library) and the metadata wait budget gave up after 64 files.
/// The music library therefore had no durations at all and duration ordering was
/// useless for it. An MPEG frame header answers the same question in ~1 ms.
///
/// Deliberately NOT a decoder: no tag reading, no audio data. Three sources of
/// truth, in order of accuracy: an Xing/Info VBR header (exact frame count), a
/// Fraunhofer VBRI header (exact frame count), and the CBR byte rate. Files
/// whose header cannot be located return null so the platform probe still gets
/// its turn.
abstract final class Mp3HeaderProbe {
  /// `.mp3` is the common case; the older MPEG layers are free to support
  /// because the same frame header describes them.
  static const Set<String> extensions = {'.mp3', '.mp2', '.mp1', '.mpga'};

  static bool isMp3Path(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return extensions.contains(path.substring(dot).toLowerCase());
  }

  /// How far into the stream the first frame may hide (ID3v2 padding, junk).
  static const int _searchBytes = 64 * 1024;

  /// Same sanity ceiling as the other parsers: a corrupt header must not poison
  /// duration ordering with a century-long value.
  static const int _maxDurationMs = 3153600000000;

  /// Sync parse for isolate entry points. Never throws.
  static ProbeResult? tryReadSync(String path) {
    if (!isMp3Path(path)) return null;
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final length = file.lengthSync();
      if (length < 512) return null;
      raf = file.openSync(mode: FileMode.read);

      final audioStart = _skipId3v2(raf, length);
      final frame = _findFirstFrame(raf, audioStart, length);
      if (frame == null) return null;

      final vbrMs = _durationFromVbrHeader(raf, frame);
      final ms = vbrMs ?? _durationFromByteRate(raf, frame, length);
      if (ms == null || ms <= 0 || ms > _maxDurationMs) return null;
      // Plausibility gate. An `.mp3` extension does not prove an MPEG stream:
      // measured on a phone, a wallpaper tool had written an MP4 under `.mp3`,
      // and a false frame sync inside it produced a 49 ms "duration" for a
      // 67 KB file. Real MPEG audio lives between ~4 and 512 kbit/s, so a value
      // outside that window means the frame header was a coincidence.
      final audioBytes = (length - frame.offset).clamp(0, length);
      if (audioBytes <= 0) return null;
      final avgKbps = audioBytes * 8 / ms;
      if (avgKbps < 4 || avgKbps > 512) return null;
      return ProbeResult(durationMs: ms);
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  /// Offset of the first audio byte: past a leading ID3v2 tag, if any.
  ///
  /// ID3v2's size field is "syncsafe" (7 bits per byte, high bit always 0) and
  /// covers everything after the 10-byte header; a footer (flag 0x10) adds
  /// another 10 bytes.
  static int _skipId3v2(RandomAccessFile raf, int length) {
    if (length < 10) return 0;
    final head = _readAt(raf, 0, 10);
    if (head == null) return 0;
    if (head[0] != 0x49 || head[1] != 0x44 || head[2] != 0x33) return 0; // "ID3"
    final size = ((head[6] & 0x7F) << 21) |
        ((head[7] & 0x7F) << 14) |
        ((head[8] & 0x7F) << 7) |
        (head[9] & 0x7F);
    final footer = (head[5] & 0x10) != 0 ? 10 : 0;
    final end = 10 + size + footer;
    return end > 0 && end < length ? end : 0;
  }

  /// First frame whose header AND follower both look valid.
  ///
  /// Requiring the follower matters: a tag body or a stray 0xFF inside an ID3
  /// frame can look like a header on its own. When the follower would be past
  /// EOF (a single-frame file) the single valid header is accepted.
  static _Frame? _findFirstFrame(
    RandomAccessFile raf,
    int start,
    int length,
  ) {
    final windowSize = (length - start).clamp(0, _searchBytes);
    if (windowSize < 4) return null;
    final bytes = _readAt(raf, start, windowSize);
    if (bytes == null) return null;

    for (var i = 0; i + 4 <= bytes.length; i++) {
      if (bytes[i] != 0xFF) continue;
      final frame = _parseFrame(bytes, i, start);
      if (frame == null) continue;
      final next = i + frame.byteLength;
      if (next + 2 <= bytes.length) {
        // Two consecutive sync words is proof enough for a `.mp3`.
        if (bytes[next] != 0xFF || (bytes[next + 1] & 0xE0) != 0xE0) continue;
      }
      return frame;
    }
    return null;
  }

  static _Frame? _parseFrame(Uint8List bytes, int i, int baseOffset) {
    if (i + 4 > bytes.length) return null;
    final b1 = bytes[i + 1];
    final b2 = bytes[i + 2];
    final b3 = bytes[i + 3];
    if ((b1 & 0xE0) != 0xE0) return null;

    // 0 = MPEG 2.5, 1 = reserved, 2 = MPEG 2, 3 = MPEG 1.
    final versionBits = (b1 >> 3) & 0x03;
    if (versionBits == 1) return null;
    // 0 = reserved, 1 = Layer III, 2 = Layer II, 3 = Layer I.
    final layerBits = (b1 >> 1) & 0x03;
    if (layerBits == 0) return null;

    final bitrateIndex = (b2 >> 4) & 0x0F;
    if (bitrateIndex == 0 || bitrateIndex == 15) return null; // free / invalid
    final sampleRateIndex = (b2 >> 2) & 0x03;
    if (sampleRateIndex == 3) return null;

    final mpeg1 = versionBits == 3;
    final layer = switch (layerBits) {
      3 => 1,
      2 => 2,
      _ => 3,
    };
    final bitrateKbps = _bitrateKbps(mpeg1, layer, bitrateIndex);
    final sampleRate = _sampleRate(versionBits, sampleRateIndex);
    if (bitrateKbps == null || sampleRate == null) return null;

    final samplesPerFrame = switch (layer) {
      1 => 384,
      2 => 1152,
      _ => mpeg1 ? 1152 : 576,
    };
    final padding = (b2 >> 1) & 0x01;
    final frameBytes =
        (samplesPerFrame ~/ 8) * bitrateKbps * 1000 ~/ sampleRate + padding;
    if (frameBytes < 4) return null;

    return _Frame(
      offset: baseOffset + i,
      mpeg1: mpeg1,
      layer: layer,
      bitrateKbps: bitrateKbps,
      sampleRate: sampleRate,
      samplesPerFrame: samplesPerFrame,
      channelMode: (b3 >> 6) & 0x03,
      byteLength: frameBytes,
    );
  }

  /// Xing/Info (LAME and friends) or Fraunhofer VBRI frame count.
  static int? _durationFromVbrHeader(RandomAccessFile raf, _Frame frame) {
    // The VBR header sits inside the first frame: 4 header bytes + side info.
    final sideInfo = frame.mpeg1
        ? (frame.channelMode == 3 ? 17 : 32)
        : (frame.channelMode == 3 ? 9 : 17);

    final xing = _readAt(raf, frame.offset + 4 + sideInfo, 16);
    if (xing != null) {
      final tag = String.fromCharCodes(xing, 0, 4);
      if (tag == 'Xing' || tag == 'Info') {
        final flags = _u32be(xing, 4);
        // Bit 0 = the frame count is present.
        if (flags & 0x01 != 0) {
          final frames = _u32be(xing, 8);
          if (frames > 0) return _framesToMs(frame, frames);
        }
      }
    }

    // VBRI is fixed at 32 bytes after the frame header and always carries the
    // frame count at byte 14 ("VBRI" + version + delay + quality + bytes).
    final vbri = _readAt(raf, frame.offset + 4 + 32, 18);
    if (vbri != null && String.fromCharCodes(vbri, 0, 4) == 'VBRI') {
      final frames = _u32be(vbri, 14);
      if (frames > 0) return _framesToMs(frame, frames);
    }
    return null;
  }

  static int _framesToMs(_Frame frame, int frames) =>
      (frames * frame.samplesPerFrame * 1000 / frame.sampleRate).round();

  /// CBR estimate: audio bytes / byte rate, minus a trailing ID3v1 tag.
  ///
  /// A VBR file without Xing/VBRI is estimated at its FIRST frame's bitrate,
  /// which can be off; those files return a plausible-but-wrong number instead
  /// of nothing, which is still better for ordering than "unknown" — and a
  /// header-less VBR file is rare (every mainstream encoder writes Xing).
  static int? _durationFromByteRate(
    RandomAccessFile raf,
    _Frame frame,
    int length,
  ) {
    var end = length;
    // ID3v1: a 128-byte trailer starting with "TAG" (worth ~0.3 s at 320 kbps).
    if (end - 128 > frame.offset) {
      final tail = _readAt(raf, end - 128, 3);
      if (tail != null && tail[0] == 0x54 && tail[1] == 0x41 && tail[2] == 0x47) {
        end -= 128;
      }
    }
    final bytes = end - frame.offset;
    if (bytes <= 0) return null;
    final bytesPerSecond = frame.bitrateKbps * 125; // kbit/s -> byte/s
    if (bytesPerSecond <= 0) return null;
    return (bytes * 1000 / bytesPerSecond).round();
  }

  static int? _bitrateKbps(bool mpeg1, int layer, int index) {
    final table = mpeg1
        ? switch (layer) {
            1 => _brMpeg1L1,
            2 => _brMpeg1L2,
            _ => _brMpeg1L3,
          }
        : switch (layer) {
            1 => _brMpeg2L1,
            _ => _brMpeg2L23,
          };
    if (index < 1 || index >= table.length) return null;
    final v = table[index];
    return v == 0 ? null : v;
  }

  static int? _sampleRate(int versionBits, int index) {
    final table = switch (versionBits) {
      3 => _srMpeg1,
      2 => _srMpeg2,
      _ => _srMpeg25,
    };
    if (index < 0 || index >= table.length) return null;
    return table[index];
  }

  static const List<int> _brMpeg1L1 = [
    0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448,
  ];
  static const List<int> _brMpeg1L2 = [
    0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384,
  ];
  static const List<int> _brMpeg1L3 = [
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
  ];
  static const List<int> _brMpeg2L1 = [
    0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256,
  ];
  static const List<int> _brMpeg2L23 = [
    0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160,
  ];
  static const List<int> _srMpeg1 = [44100, 48000, 32000];
  static const List<int> _srMpeg2 = [22050, 24000, 16000];
  static const List<int> _srMpeg25 = [11025, 12000, 8000];

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

  static int _u32be(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

/// One parsed MPEG audio frame header plus its position.
class _Frame {
  const _Frame({
    required this.offset,
    required this.mpeg1,
    required this.layer,
    required this.bitrateKbps,
    required this.sampleRate,
    required this.samplesPerFrame,
    required this.channelMode,
    required this.byteLength,
  });

  final int offset;
  final bool mpeg1;
  final int layer;
  final int bitrateKbps;
  final int sampleRate;
  final int samplesPerFrame;

  /// 3 = single channel, anything else = stereo/joint/dual.
  final int channelMode;
  final int byteLength;
}
