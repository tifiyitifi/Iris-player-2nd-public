import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/amr_header_probe.dart';
import 'package:iris/features/media_library/scan/probe/local_header_probe.dart';
import 'package:iris/features/media_library/scan/probe/silk_header_probe.dart';

/// WeChat writes SILK v3 under an `.amr` name. Neither the AMR frame walk nor
/// `MediaMetadataRetriever` can read it, so those files were the only audio left
/// without a duration after a full phone scan (496 of them).
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('iris_silk_probe_');
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

  test('counts 20 ms packets', () {
    final path = writeFile('a.amr', _silk(packets: 50, payloadBytes: 20));

    final r = SilkHeaderProbe.tryReadSync(path);

    expect(r, isNotNull);
    expect(r!.durationMs, 1000);
  });

  test('accepts the magic without the leading version byte', () {
    final path = writeFile(
      'b.silk',
      [
        ...'#!SILK_V3'.codeUnits,
        ..._packets(20, 20),
      ],
    );

    expect(SilkHeaderProbe.tryReadSync(path)!.durationMs, 400);
  });

  test('a zero-length packet ends the walk', () {
    final path = writeFile(
      'c.amr',
      [..._silkHeader(), ..._packets(10, 20), 0, 0, ..._packets(10, 20)],
    );

    expect(SilkHeaderProbe.tryReadSync(path)!.durationMs, 200);
  });

  test('a packet that runs past EOF keeps the count so far', () {
    final path = writeFile(
      'd.amr',
      [..._silkHeader(), ..._packets(5, 20), 0xFF, 0x7F],
    );

    expect(SilkHeaderProbe.tryReadSync(path)!.durationMs, 100);
  });

  test('rejects a non-SILK file', () {
    final path = writeFile('e.amr', List<int>.filled(256, 0x41));
    expect(SilkHeaderProbe.tryReadSync(path), isNull);
  });

  test('the dispatcher prefers SILK over AMR for an .amr file', () {
    final silk = writeFile('voice.amr', _silk(packets: 50, payloadBytes: 20));
    expect(LocalHeaderProbe.tryReadSync(silk)!.durationMs, 1000);

    final amr = writeFile('recording.amr', [
      ...'#!AMR\n'.codeUnits,
      for (var i = 0; i < 10; i++)
        ...[7 << 3, ...List<int>.filled(31, 0)],
    ]);
    expect(AmrHeaderProbe.tryReadSync(amr)!.durationMs, 200);
    expect(LocalHeaderProbe.tryReadSync(amr)!.durationMs, 200);
  });
}

List<int> _silk({required int packets, required int payloadBytes}) => [
      ..._silkHeader(),
      ..._packets(packets, payloadBytes),
    ];

List<int> _silkHeader() => [0x02, ...'#!SILK_V3'.codeUnits];

List<int> _packets(int count, int payloadBytes) {
  final out = <int>[];
  for (var i = 0; i < count; i++) {
    out
      ..add(payloadBytes & 0xFF)
      ..add((payloadBytes >> 8) & 0xFF)
      ..addAll(List<int>.filled(payloadBytes, 0));
  }
  return out;
}
