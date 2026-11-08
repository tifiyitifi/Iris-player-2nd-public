import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/amr_header_probe.dart';

/// AMR has no global header: duration only exists as the sum of its 20 ms
/// frames, so the parser walks the frame chain.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('iris_amr_probe_');
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

  test('AMR-NB: 500 frames of 12.2 kbit/s = 10 s', () {
    final path = writeFile('nb.amr', _amr(magic: '#!AMR\n', frames: 500));

    final r = AmrHeaderProbe.tryReadSync(path);

    expect(r, isNotNull);
    expect(r!.durationMs, 10000);
    expect(r.width, isNull);
  });

  test('AMR-WB: the same frame count, different frame size', () {
    final path = writeFile('wb.amr', _amr(magic: '#!AMR-WB\n', frames: 300));

    expect(AmrHeaderProbe.tryReadSync(path)!.durationMs, 6000);
  });

  test('a chain that ends on an invalid frame type stops cleanly', () {
    final bytes = _amr(magic: '#!AMR\n', frames: 100);
    // Frame type 15 = "no data": the walk stops, the 100 real frames remain.
    bytes.add(15 << 3);
    final path = writeFile('tail.amr', bytes);

    expect(AmrHeaderProbe.tryReadSync(path)!.durationMs, 2000);
  });

  test('rejects a file without the AMR magic', () {
    final path = writeFile('fake.amr', List<int>.filled(256, 0x41));
    expect(AmrHeaderProbe.tryReadSync(path), isNull);
  });

  test('a bare magic with no frames returns null', () {
    final path = writeFile('empty.amr', '#!AMR\n'.codeUnits);
    expect(AmrHeaderProbe.tryReadSync(path), isNull);
  });
}

/// Magic followed by [frames] frames of frame type 7 (the widest mode).
List<int> _amr({required String magic, required int frames}) {
  final frameBytes = magic.contains('WB') ? 33 : 32;
  final out = <int>[...magic.codeUnits];
  for (var i = 0; i < frames; i++) {
    out
      ..add(7 << 3) // frame type 7, no padding
      ..addAll(List<int>.filled(frameBytes - 1, 0));
  }
  return out;
}
