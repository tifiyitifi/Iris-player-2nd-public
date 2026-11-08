import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/mkv_header_probe.dart';

import 'helpers/media_container_fixtures.dart';

/// Matroska/WebM headers carry duration + frame size in two small EBML elements.
/// Reading them costs ~1 ms instead of the 30–70 ms Shell property lookup, which
/// is what makes a folder of MKVs playable in seconds.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('iris_mkv_probe_');
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

  test('reads duration and dimensions from an mkv', () {
    final path = write(
      'a.mkv',
      buildMkv(durationMs: 90500, width: 1920, height: 1080),
    );

    final result = MkvHeaderProbe.tryReadSync(path);

    expect(result, isNotNull);
    expect(result!.durationMs, 90500);
    expect(result.width, 1920);
    expect(result.height, 1080);
  });

  test('honours a non-default timecode scale', () {
    final path = write(
      'scale.mkv',
      buildMkv(
        durationMs: 42000,
        width: 1280,
        height: 720,
        timecodeScaleNs: 500000,
      ),
    );

    final result = MkvHeaderProbe.tryReadSync(path);

    expect(result!.durationMs, 42000);
    expect(result.width, 1280);
  });

  test('handles a segment with an explicit size', () {
    final path = write(
      'sized.webm',
      buildMkv(
        durationMs: 1500,
        width: 640,
        height: 360,
        segmentUnknownSize: false,
      ),
    );

    final result = MkvHeaderProbe.tryReadSync(path);

    expect(result!.durationMs, 1500);
    expect(result.width, 640);
  });

  test('returns null without a duration so the platform probe can answer', () {
    final path = write(
      'live.mkv',
      buildMkv(durationMs: 0, width: 1920, height: 1080, includeDuration: false),
    );

    expect(MkvHeaderProbe.tryReadSync(path), isNull);
  });

  test('accepts a duration but reports unknown dimensions as null', () {
    // A `Tracks` element the parser cannot resolve must not cost the duration:
    // the list still sorts by duration, and play fills the resolution later.
    final bytes = buildMkv(durationMs: 7000, width: 0, height: 0);
    final path = write('nodims.mkv', bytes);

    final result = MkvHeaderProbe.tryReadSync(path);

    expect(result, isNotNull);
    expect(result!.durationMs, 7000);
    expect(result.width, isNull);
    expect(result.height, isNull);
  });

  test('rejects other extensions, missing files and garbage', () {
    expect(MkvHeaderProbe.tryReadSync(write('a.mp4', List<int>.filled(128, 0))),
        isNull);
    expect(MkvHeaderProbe.tryReadSync('${tmp.path}/nope.mkv'), isNull);
    expect(MkvHeaderProbe.tryReadSync(write('junk.mkv', List<int>.filled(256, 0xAA))),
        isNull);
  });
}
