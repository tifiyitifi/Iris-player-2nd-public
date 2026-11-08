import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/avi_header_probe.dart';

import 'helpers/media_container_fixtures.dart';

/// Legacy AVI libraries: `hdrl/avih` already has frames-per-second and the frame
/// count, so a header read answers duration in ~1 ms. Without it every AVI fell
/// into the 30–70 ms/frame Shell property handler.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('iris_avi_probe_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String write(String name, List<int> bytes) {
    final file = File('${tmp.path}/$name');
    file.writeAsBytesSync(bytes);
    return file.path;
  }

  test('reads duration and dimensions from an avi', () {
    final path = write(
      'a.avi',
      buildAvi(durationMs: 61000, width: 720, height: 480),
    );

    final result = AviHeaderProbe.tryReadSync(path);

    expect(result, isNotNull);
    expect(result!.durationMs, 61000);
    expect(result.width, 720);
    expect(result.height, 480);
  });

  test('handles a different frame rate', () {
    // 25 fps: 40 ms per frame.
    final path = write(
      'pal.avi',
      buildAvi(durationMs: 20000, width: 352, height: 288, microsPerFrame: 40000),
    );

    final result = AviHeaderProbe.tryReadSync(path);

    expect(result!.durationMs, 20000);
  });

  test('rejects a non-RIFF file, a wrong form type and missing files', () {
    final notRiff = write('junk.avi', List<int>.filled(64, 0));
    expect(AviHeaderProbe.tryReadSync(notRiff), isNull);

    final wrongForm = write('movie.avi', [
      ...'RIFF'.codeUnits,
      4, 0, 0, 0,
      ...'WAVE'.codeUnits,
    ]);
    expect(AviHeaderProbe.tryReadSync(wrongForm), isNull);

    expect(AviHeaderProbe.tryReadSync('${tmp.path}/nope.avi'), isNull);
  });

  test('returns null when the file was truncated mid-header', () {
    final full = buildAvi(durationMs: 30000, width: 640, height: 360);
    final path = write('trunc.avi', full.sublist(0, 20));

    expect(AviHeaderProbe.tryReadSync(path), isNull);
  });
}
