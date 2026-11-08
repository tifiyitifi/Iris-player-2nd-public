import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/flac_header_probe.dart';

/// A FLAC header is 42 bytes: `fLaC`, the STREAMINFO block header, then the
/// fixed 34-byte STREAMINFO payload that carries rate + total samples.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('iris_flac_probe_');
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

  test('reads duration from STREAMINFO', () {
    final path = writeFile(
      'a.flac',
      _flac(sampleRate: 44100, totalSamples: 441000),
    );

    final r = FlacHeaderProbe.tryReadSync(path);

    expect(r, isNotNull);
    expect(r!.durationMs, 10000);
    expect(r.width, isNull);
  });

  test('handles a 96 kHz / 48-bit-sample header', () {
    final path = writeFile(
      'hires.flac',
      _flac(sampleRate: 96000, totalSamples: 96000 * 30),
    );

    expect(FlacHeaderProbe.tryReadSync(path)!.durationMs, 30000);
  });

  test('rejects a non-STREAMINFO first block', () {
    final bytes = _flac(sampleRate: 44100, totalSamples: 441000);
    bytes[4] = 0x84; // last block, type 4 (VORBIS_COMMENT)
    final path = writeFile('weird.flac', bytes);

    expect(FlacHeaderProbe.tryReadSync(path), isNull);
  });

  test('rejects a file without the fLaC marker', () {
    final bytes = _flac(sampleRate: 44100, totalSamples: 441000);
    bytes[0] = 0x00;
    final path = writeFile('fake.flac', bytes);

    expect(FlacHeaderProbe.tryReadSync(path), isNull);
  });

  test('a truncated file returns null', () {
    final path = writeFile(
      'short.flac',
      _flac(sampleRate: 44100, totalSamples: 441000).sublist(0, 20),
    );
    expect(FlacHeaderProbe.tryReadSync(path), isNull);
  });

  test('a zero sample count returns null instead of 0 ms', () {
    final path = writeFile(
      'empty.flac',
      _flac(sampleRate: 44100, totalSamples: 0),
    );
    expect(FlacHeaderProbe.tryReadSync(path), isNull);
  });
}

/// `fLaC` + STREAMINFO block header + 34-byte payload.
List<int> _flac({required int sampleRate, required int totalSamples}) {
  final payload = List<int>.filled(34, 0);
  payload[10] = (sampleRate >> 12) & 0xFF;
  payload[11] = (sampleRate >> 4) & 0xFF;
  payload[12] = (sampleRate & 0x0F) << 4;
  payload[13] = (totalSamples >> 32) & 0x0F;
  payload[14] = (totalSamples >> 24) & 0xFF;
  payload[15] = (totalSamples >> 16) & 0xFF;
  payload[16] = (totalSamples >> 8) & 0xFF;
  payload[17] = totalSamples & 0xFF;
  return [
    ...'fLaC'.codeUnits,
    0x80, // last metadata block, type 0 = STREAMINFO
    0x00, 0x00, 0x22, // 24-bit length: 34
    ...payload,
  ];
}
