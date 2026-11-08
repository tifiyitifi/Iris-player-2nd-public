import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/mp3_header_probe.dart';

/// Builds minimal but structurally valid MPEG audio streams, so the parser is
/// exercised against real frame layouts instead of binary fixtures.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('iris_mp3_probe_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String writeFile(String name, List<int> bytes) {
    final f = File('${tmp.path}/$name');
    f.writeAsBytesSync(bytes);
    return f.path;
  }

  test('CBR: duration follows the byte rate of the first frame', () {
    // MPEG1 Layer III, 128 kbit/s, 44100 Hz, no padding:
    //   frame bytes = 1152 / 8 * 128000 / 44100 = 417
    //   100 frames   = 41,700 bytes at 16,000 bytes/s = 2.606 s
    final path = writeFile('cbr.mp3', _frames(count: 100));

    final r = Mp3HeaderProbe.tryReadSync(path);

    expect(r, isNotNull);
    expect(r!.durationMs, 2606);
    expect(r.width, isNull);
  });

  test('skips an ID3v2 tag before the first frame', () {
    // 10-byte header + a 100-byte (syncsafe) body, then the same CBR stream.
    final path = writeFile('tagged.mp3', [
      ..._id3v2(bodyBytes: 100),
      ...List<int>.filled(100, 0),
      ..._frames(count: 100),
    ]);

    final r = Mp3HeaderProbe.tryReadSync(path);

    expect(r, isNotNull);
    expect(r!.durationMs, 2606,
        reason: 'tag bytes are not audio and must not inflate the duration');
  });

  test('Xing/Info frame count wins over the CBR estimate', () {
    // A VBR file: 2000 frames of 1152 samples at 44100 Hz = 52.245 s. The first
    // frame is 32 kbit/s while the rest are 128 kbit/s, so a byte-rate estimate
    // taken from the first frame would report ~208 s.
    final path = writeFile('vbr.mp3', _xingStream(frames: 2000));

    final r = Mp3HeaderProbe.tryReadSync(path);

    expect(r, isNotNull);
    expect(r!.durationMs, 52245);
  });

  test('an implausible Xing frame count is rejected', () {
    // The shape of a mislabeled container: a header that claims two frames
    // (52 ms) while the file is ~66 KB — 10 Mbit/s of "audio", i.e. the sync
    // word was a coincidence, not an MPEG stream.
    final path = writeFile('bogus.mp3', _xingStream(frames: 2, tailBytes: 66000));

    expect(Mp3HeaderProbe.tryReadSync(path), isNull);
  });

  test('a trailing ID3v1 tag is excluded from the CBR estimate', () {
    final base = _frames(count: 100);
    final path = writeFile('id3v1.mp3', [
      ...base,
      ...'TAG'.codeUnits,
      ...List<int>.filled(125, 0),
    ]);

    final r = Mp3HeaderProbe.tryReadSync(path);

    expect(r, isNotNull);
    expect(r!.durationMs, 2606,
        reason: 'a 128-byte trailer must not read as ~8 ms of audio');
  });

  test('MPEG2 Layer III halves the samples per frame', () {
    // 22050 Hz, 64 kbit/s: frame bytes = 576 / 8 * 64000 / 22050 = 208
    final path = writeFile(
      'mpeg2.mp3',
      _frames(count: 100, versionBits: 2, bitrateIndex: 8, sampleRateIndex: 0),
    );

    final r = Mp3HeaderProbe.tryReadSync(path);

    expect(r, isNotNull);
    // 100 * 208 bytes at 8000 bytes/s = 2.6 s (the CBR byte-rate model).
    expect(r!.durationMs, 2600);
  });

  test('garbage returns null so the platform probe still runs', () {
    final path = writeFile('noise.mp3', List<int>.generate(4096, (i) => i * 7));
    expect(Mp3HeaderProbe.tryReadSync(path), isNull);
  });

  test('a truncated header returns null', () {
    final path = writeFile('short.mp3', [0xFF, 0xFB, 0x90]);
    expect(Mp3HeaderProbe.tryReadSync(path), isNull);
  });

  test('non-mp3 extensions are not attempted', () {
    final path = writeFile('a.flac', _frames(count: 100));
    expect(Mp3HeaderProbe.tryReadSync(path), isNull);
    expect(Mp3HeaderProbe.isMp3Path('x/y.MP3'), isTrue);
  });
}

/// 100 frames of 417 bytes (MPEG1 Layer III, 128 kbit/s, 44100 Hz by default).
Uint8List _frames({
  required int count,
  int versionBits = 3,
  int layerBits = 1,
  int bitrateIndex = 9,
  int sampleRateIndex = 0,
}) {
  final b1 = 0xE0 | (versionBits << 3) | (layerBits << 1);
  final b2 = (bitrateIndex << 4) | (sampleRateIndex << 2);
  final mpeg1 = versionBits == 3;
  final layer3 = layerBits == 1;
  final samples = mpeg1 ? 1152 : (layer3 ? 576 : 1152);
  const bitrates = {
    9: 128,
    8: 64,
  };
  final kbps = bitrates[bitrateIndex]!;
  const rates = {0: 44100, 1: 48000, 2: 32000};
  final rate = mpeg1 ? rates[sampleRateIndex]! : 22050;
  final frameBytes = samples ~/ 8 * kbps * 1000 ~/ rate;
  final header = [0xFF, b1, b2, 0x00];
  final out = <int>[];
  for (var i = 0; i < count; i++) {
    out
      ..addAll(header)
      ..addAll(List<int>.filled(frameBytes - header.length, 0));
  }
  return Uint8List.fromList(out);
}

/// A Xing frame (32 kbit/s) followed by [frames]-1 ordinary 128 kbit/s frames,
/// plus optional trailing bytes to simulate a file whose size contradicts its
/// frame count.
Uint8List _xingStream({required int frames, int tailBytes = 0}) {
  // MPEG1 Layer III, stereo → 32 bytes of side info after the 4-byte header.
  final b1 = 0xE0 | (3 << 3) | (1 << 1);
  final xingFrame = Uint8List(1152 ~/ 8 * 32000 ~/ 44100); // 32 kbit/s = 104
  xingFrame[0] = 0xFF;
  xingFrame[1] = b1;
  xingFrame[2] = (1 << 4) | (0 << 2); // 32 kbit/s, 44100 Hz
  // Xing header at 4 + 32.
  final at = 4 + 32;
  xingFrame.setAll(at, 'Xing'.codeUnits);
  final data = ByteData.sublistView(xingFrame);
  data.setUint32(at + 4, 0x1, Endian.big); // flags: frames present
  data.setUint32(at + 8, frames, Endian.big);

  final frameBytes = 1152 ~/ 8 * 128000 ~/ 44100; // 417
  final out = BytesBuilder()..add(xingFrame);
  for (var i = 1; i < frames; i++) {
    final frame = Uint8List(frameBytes);
    frame[0] = 0xFF;
    frame[1] = b1;
    frame[2] = (9 << 4) | (0 << 2); // 128 kbit/s
    out.add(frame);
  }
  if (tailBytes > 0) out.add(Uint8List(tailBytes));
  return out.takeBytes();
}

/// An ID3v2.3 tag header whose size field is syncsafe.
List<int> _id3v2({required int bodyBytes}) => [
      0x49, 0x44, 0x33, // "ID3"
      0x03, 0x00, // version 2.3.0
      0x00, // flags
      (bodyBytes >> 21) & 0x7F,
      (bodyBytes >> 14) & 0x7F,
      (bodyBytes >> 7) & 0x7F,
      bodyBytes & 0x7F,
    ];
