import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/wav_header_probe.dart';

/// RIFF/WAVE: `fmt ` carries the byte rate, `data` carries the payload size.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('iris_wav_probe_');
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

  test('reads duration from fmt + data', () {
    // 1764 bytes/s × 17,640 bytes = 10 s.
    final path = writeFile('a.wav', _wav(byteRate: 1764, dataBytes: 17640));

    final r = WavHeaderProbe.tryReadSync(path);

    expect(r, isNotNull);
    expect(r!.durationMs, 10000);
  });

  test('skips unknown chunks before fmt', () {
    final path = writeFile(
      'with_junk.wav',
      _wav(byteRate: 1764, dataBytes: 17640, leadingChunk: true),
    );

    expect(WavHeaderProbe.tryReadSync(path)!.durationMs, 10000);
  });

  test('handles a WAVE_FORMAT_EXTENSIBLE fmt (18 bytes)', () {
    final path = writeFile(
      'ext.wav',
      _wav(byteRate: 1764, dataBytes: 8820, fmtBytes: 18),
    );

    expect(WavHeaderProbe.tryReadSync(path)!.durationMs, 5000);
  });

  test('rejects a non-WAVE RIFF container', () {
    final bytes = _wav(byteRate: 1764, dataBytes: 17640);
    bytes.setAll(8, 'AVI '.codeUnits);
    final path = writeFile('notwave.wav', bytes);

    expect(WavHeaderProbe.tryReadSync(path), isNull);
  });

  test('a zero-length data chunk returns null', () {
    final path = writeFile('empty.wav', _wav(byteRate: 1764, dataBytes: 0));
    expect(WavHeaderProbe.tryReadSync(path), isNull);
  });

  test('a missing data chunk returns null', () {
    final path = writeFile(
      'nodata.wav',
      _wav(byteRate: 1764, dataBytes: 17640, includeData: false),
    );
    expect(WavHeaderProbe.tryReadSync(path), isNull);
  });
}

/// RIFF/WAVE with an optional junk chunk before `fmt `.
List<int> _wav({
  required int byteRate,
  required int dataBytes,
  bool leadingChunk = false,
  bool includeData = true,
  int fmtBytes = 16,
}) {
  final fmt = <int>[
    0x01, 0x00, // PCM
    0x02, 0x00, // channels
    ..._u32le(44100),
    ..._u32le(byteRate),
    0x04, 0x00, // block align
    0x10, 0x00, // bits per sample
    ...List<int>.filled(fmtBytes - 16, 0),
  ];
  final junk = <int>[
    ...'JUNK'.codeUnits,
    ..._u32le(4),
    ...List<int>.filled(4, 0),
  ];
  final data = <int>[
    ...'data'.codeUnits,
    ..._u32le(dataBytes),
    ...List<int>.filled(dataBytes, 0),
  ];
  final body = <int>[
    ...'WAVE'.codeUnits,
    if (leadingChunk) ...junk,
    ..._chunk('fmt ', fmt),
    if (includeData) ...data,
  ];
  return [
    ...'RIFF'.codeUnits,
    ..._u32le(body.length),
    ...body,
  ];
}

List<int> _chunk(String id, List<int> payload) => [
      ...id.codeUnits,
      ..._u32le(payload.length),
      ...payload,
      if (payload.length.isOdd) 0,
    ];

List<int> _u32le(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
