import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/mp4_header_probe.dart';

/// Builds a minimal but structurally valid ISO-BMFF file so the parser is
/// exercised against real box layouts (no binary fixtures in the repo).
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('iris_mp4_probe_');
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

  test('reads duration and dimensions from a faststart mp4', () {
    final path = writeFile(
      'a.mp4',
      _mp4(timescale: 1000, duration: 65432, width: 1920, height: 1080),
    );

    final r = Mp4HeaderProbe.tryReadSync(path);

    expect(r, isNotNull);
    expect(r!.durationMs, 65432);
    expect(r.width, 1920);
    expect(r.height, 1080);
  });

  test('skips an mdat placed before moov (moov at end)', () {
    final bytes = _mp4(
      timescale: 600,
      duration: 600 * 90,
      width: 1280,
      height: 720,
      mdatBytes: 4096,
      moovFirst: false,
    );
    final path = writeFile('tail.mp4', bytes);

    final r = Mp4HeaderProbe.tryReadSync(path);

    expect(r, isNotNull);
    expect(r!.durationMs, 90000);
    expect(r.width, 1280);
  });

  test('handles version-1 mvhd/tkhd', () {
    final path = writeFile(
      'v1.mp4',
      _mp4(
        timescale: 90000,
        duration: 90000 * 42,
        width: 3840,
        height: 2160,
        version1: true,
      ),
    );

    final r = Mp4HeaderProbe.tryReadSync(path);

    expect(r!.durationMs, 42000);
    expect(r.width, 3840);
    expect(r.height, 2160);
  });

  test('handles 64-bit box sizes', () {
    final path = writeFile(
      'large.mp4',
      _mp4(
        timescale: 1000,
        duration: 5000,
        width: 640,
        height: 360,
        largeSize: true,
        mdatBytes: 2048,
      ),
    );

    final r = Mp4HeaderProbe.tryReadSync(path);

    expect(r!.durationMs, 5000);
    expect(r.width, 640);
  });

  test('returns null for a fragmented mvhd (duration 0) so the caller can '
      'fall back to the platform probe', () {
    final path = writeFile(
      'frag.mp4',
      _mp4(timescale: 1000, duration: 0, width: 1920, height: 1080),
    );

    expect(Mp4HeaderProbe.tryReadSync(path), isNull);
  });

  test('returns null for non-mp4 containers and missing files', () {
    final path = writeFile('a.mkv', List<int>.filled(64, 0));
    expect(Mp4HeaderProbe.tryReadSync(path), isNull);
    expect(Mp4HeaderProbe.tryReadSync('${tmp.path}/nope.mp4'), isNull);
  });

  test('ignores an audio-only tkhd (0x0) and reads the video track', () {
    final path = writeFile(
      'audio_first.mp4',
      _mp4(
        timescale: 1000,
        duration: 1234,
        width: 720,
        height: 480,
        audioTrackFirst: true,
      ),
    );

    final r = Mp4HeaderProbe.tryReadSync(path);

    expect(r!.width, 720);
    expect(r.height, 480);
  });
}

Uint8List _mp4({
  required int timescale,
  required int duration,
  required int width,
  required int height,
  int mdatBytes = 32,
  bool moovFirst = true,
  bool version1 = false,
  bool largeSize = false,
  bool audioTrackFirst = false,
}) {
  final moov = _box('moov', [
    ..._mvhd(timescale, duration, version1: version1),
    if (audioTrackFirst) ..._trak(0, 0, version1: version1),
    ..._trak(width, height, version1: version1),
  ]);
  final ftyp = _box('ftyp', 'isom'.codeUnits + _u32(0x200) + 'isom'.codeUnits);
  final mdatPayload = List<int>.filled(mdatBytes, 0);
  final mdat = largeSize
      ? [
          ..._u32(1), // size == 1 → 64-bit largesize follows the type
          ...'mdat'.codeUnits,
          ..._u64(mdatPayload.length + 16),
          ...mdatPayload,
        ]
      : _box('mdat', mdatPayload);
  return Uint8List.fromList([
    ...ftyp,
    if (moovFirst) ...moov,
    ...mdat,
    if (!moovFirst) ...moov,
  ]);
}

List<int> _mvhd(int timescale, int duration, {required bool version1}) {
  final b = BytesBuilder();
  b.addByte(version1 ? 1 : 0);
  b.add([0, 0, 0]);
  if (version1) {
    b.add(_u64(0)); // creation
    b.add(_u64(0)); // modification
    b.add(_u32(timescale));
    b.add(_u64(duration));
  } else {
    b.add(_u32(0)); // creation
    b.add(_u32(0)); // modification
    b.add(_u32(timescale));
    b.add(_u32(duration));
  }
  b.add(_u32(0x00010000)); // rate
  b.add([0, 0]); // volume + reserved
  b.add(List<int>.filled(10, 0));
  return _box('mvhd', b.takeBytes());
}

List<int> _trak(int width, int height, {required bool version1}) {
  final tkhd = BytesBuilder();
  tkhd.addByte(version1 ? 1 : 0);
  tkhd.add([0, 0, 0]);
  if (version1) {
    tkhd.add(_u64(0)); // creation
    tkhd.add(_u64(0)); // modification
    tkhd.add(_u32(1)); // track id
    tkhd.add(_u32(0)); // reserved
    tkhd.add(_u64(0)); // duration
  } else {
    tkhd.add(_u32(0)); // creation
    tkhd.add(_u32(0)); // modification
    tkhd.add(_u32(1)); // track id
    tkhd.add(_u32(0)); // reserved
    tkhd.add(_u32(0)); // duration
  }
  tkhd.add(_u64(0)); // reserved
  tkhd.add([0, 0]); // layer
  tkhd.add([0, 0]); // alternate group
  tkhd.add([0, 0, 0, 0]); // volume + reserved
  tkhd.add(List<int>.filled(36, 0)); // matrix
  tkhd.add(_u32(width << 16));
  tkhd.add(_u32(height << 16));
  return _box('trak', _box('tkhd', tkhd.takeBytes()));
}

List<int> _box(String type, List<int> payload) {
  return [..._u32(payload.length + 8), ...type.codeUnits, ...payload];
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

List<int> _u64(int v) => [..._u32(v >> 32), ..._u32(v & 0xFFFFFFFF)];
