import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/ogg_header_probe.dart';

/// Ogg: the first page's identification header gives the sample rate, the last
/// page's granule position gives the total sample count.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('iris_ogg_probe_');
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

  test('Vorbis: reads duration from the last page granule', () {
    final path = writeFile(
      'a.ogg',
      _ogg(
        ident: _vorbisIdent(sampleRate: 44100),
        lastGranule: 441000,
      ),
    );

    final r = OggHeaderProbe.tryReadSync(path);

    expect(r, isNotNull);
    expect(r!.durationMs, 10000);
  });

  test('Opus: granule counts 48 kHz samples minus the pre-skip', () {
    final path = writeFile(
      'a.opus',
      _ogg(
        ident: _opusIdent(preSkip: 312),
        lastGranule: 48000 * 10 + 312,
      ),
    );

    expect(OggHeaderProbe.tryReadSync(path)!.durationMs, 10000);
  });

  test('a page that completes no packet (-1 granule) is skipped', () {
    final path = writeFile(
      'partial.ogg',
      [
        ..._page(
          granule: 0,
          payload: _vorbisIdent(sampleRate: 44100),
          headerType: 0x02,
        ),
        ..._page(granule: 441000, payload: List<int>.filled(64, 0), seq: 1),
        // -1 = "no packet finishes on this page", the normal shape of a page
        // cut short by an interrupted recording.
        ..._page(granule: -1, payload: List<int>.filled(32, 0), seq: 2),
      ],
    );

    expect(OggHeaderProbe.tryReadSync(path)!.durationMs, 10000);
  });

  test('rejects a non-Ogg file', () {
    final path = writeFile('not.ogg', List<int>.filled(256, 0x41));
    expect(OggHeaderProbe.tryReadSync(path), isNull);
  });

  test('rejects an unknown codec inside a valid Ogg page', () {
    final path = writeFile(
      'speex.ogg',
      _ogg(ident: [...'Speex   '.codeUnits, ...List<int>.filled(20, 0)],
          lastGranule: 441000),
    );
    expect(OggHeaderProbe.tryReadSync(path), isNull);
  });
}

List<int> _vorbisIdent({required int sampleRate}) => [
      0x01,
      ...'vorbis'.codeUnits,
      0x00, 0x00, 0x00, 0x00, // version
      0x02, // channels
      ..._u32le(sampleRate),
      ...List<int>.filled(12, 0), // bitrate max / nominal / min
    ];

List<int> _opusIdent({required int preSkip}) => [
      ...'OpusHead'.codeUnits,
      0x01, // version
      0x02, // channels
      ..._u16le(preSkip),
      ..._u32le(48000), // input sample rate
      0x00, 0x00, // output gain
      0x00, // mapping family
    ];

/// A two-page Ogg stream: the identification page (granule 0) and a final page
/// whose granule is [lastGranule].
List<int> _ogg({required List<int> ident, required int lastGranule}) => [
      ..._page(granule: 0, payload: ident, headerType: 0x02, seq: 0),
      ..._page(granule: lastGranule, payload: List<int>.filled(64, 0), seq: 1),
    ];

List<int> _page({
  required int granule,
  required List<int> payload,
  int headerType = 0,
  int seq = 0,
}) {
  final segments = <int>[];
  var remaining = payload.length;
  while (remaining > 0) {
    final n = remaining > 255 ? 255 : remaining;
    segments.add(n);
    remaining -= n;
  }
  return [
    ...'OggS'.codeUnits,
    0x00, // version
    headerType,
    ..._u64le(granule),
    ..._u32le(1), // serial
    ..._u32le(seq),
    ..._u32le(0), // crc
    segments.length,
    ...segments,
    ...payload,
  ];
}

List<int> _u16le(int v) => [v & 0xFF, (v >> 8) & 0xFF];

List<int> _u32le(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

List<int> _u64le(int v) => [
      for (var i = 0; i < 8; i++) (v >> (8 * i)) & 0xFF,
    ];
