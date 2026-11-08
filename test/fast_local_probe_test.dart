import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/fast_local_probe.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';

import 'helpers/media_container_fixtures.dart';

void main() {
  late Directory tmp;
  late _FakeFallback fallback;
  late FastLocalProbeService probe;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('iris_fast_probe_');
    fallback = _FakeFallback();
    probe = FastLocalProbeService(fallback: fallback);
  });

  tearDownAll(() async {
    await probe.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() => fallback.calls.clear());

  test('answers local mp4 headers without touching the fallback', () async {
    final path = _writeMp4(tmp, 'fast.mp4', durationMs: 65432, w: 1920, h: 1080);

    final result = await probe.probeFiles([path]);

    expect(result.single.durationMs, 65432);
    expect(result.single.width, 1920);
    expect(fallback.calls, isEmpty);
  });

  test('answers local mkv headers without touching the fallback', () async {
    final path = _writeBytes(
      tmp,
      'fast.mkv',
      buildMkv(durationMs: 61000, width: 1280, height: 720),
    );

    final result = await probe.probeFiles([path]);

    expect(result.single.durationMs, 61000);
    expect(result.single.width, 1280);
    expect(fallback.calls, isEmpty);
  });

  test('answers local avi headers without touching the fallback', () async {
    final path = _writeBytes(
      tmp,
      'fast.avi',
      buildAvi(durationMs: 30000, width: 640, height: 480),
    );

    final result = await probe.probeFiles([path]);

    expect(result.single.durationMs, 30000);
    expect(result.single.height, 480);
    expect(fallback.calls, isEmpty);
  });

  test('delegates unreadable containers to the fallback', () async {
    final path = _writeRaw(tmp, 'clip.mkv');

    final result = await probe.probeFiles([path]);

    expect(fallback.calls, [path]);
    expect(result.single.durationMs, _FakeFallback.durationMs);
  });

  test('answers local mp3 headers without touching the fallback', () async {
    // 44,100 Hz MPEG1 Layer III at 128 kbit/s: a 41,700-byte stream is 2.6 s.
    final path = _writeBytes(tmp, 'fast.mp3', _buildMp3(frames: 100));

    final result = await probe.probeFiles([path]);

    expect(result.single.durationMs, 2606);
    expect(fallback.calls, isEmpty,
        reason: 'music used to reach MediaMetadataRetriever for every file');
  });

  test('delegates formats without a header parser to the fallback', () async {
    final path = _writeRaw(tmp, 'clip.wmv');

    final result = await probe.probeFiles([path]);

    expect(fallback.calls, [path]);
    expect(result.single.durationMs, _FakeFallback.durationMs);
  });

  test('delegates fragmented mp4 (duration 0) to the fallback', () async {
    final path = _writeMp4(tmp, 'frag.mp4', durationMs: 0, w: 1920, h: 1080);

    final result = await probe.probeFiles([path]);

    expect(fallback.calls, [path]);
    expect(result.single.durationMs, _FakeFallback.durationMs);
  });

  test('keeps input order across fast and fallback results', () async {
    final fast = _writeMp4(tmp, 'b.mp4', durationMs: 1111, w: 640, h: 360);
    final slow = _writeRaw(tmp, 'a.mkv');

    final result = await probe.probeFiles([fast, slow]);

    expect(result, hasLength(2));
    expect(result[0].durationMs, 1111);
    expect(result[1].durationMs, _FakeFallback.durationMs);
  });

  test('a multi-batch pass keeps both the fast order and the fallback order',
      () async {
    // More than one 32-file batch: the fast results of batch 0 must not be
    // reordered by batch 1, and the unresolved files must reach the fallback in
    // input order.
    final valid = [
      for (var i = 0; i < LocalHeaderProbePool.batchSize; i++)
        _writeMp4(tmp, 'mb_v$i.mp4', durationMs: 500 + i, w: 640, h: 360),
    ];
    final broken = [
      for (var i = 0; i < 6; i++) _writeRaw(tmp, 'mb_b$i.mp4'),
    ];

    final result = await probe.probeFiles([...valid, ...broken]);

    expect(result, hasLength(valid.length + broken.length));
    for (var i = 0; i < valid.length; i++) {
      expect(result[i].durationMs, 500 + i, reason: 'fast result $i moved');
    }
    expect(
      result.skip(valid.length).map((r) => r.durationMs),
      everyElement(_FakeFallback.durationMs),
    );
    expect(fallback.calls, broken,
        reason: 'unresolved headers must fall back in input order');
  });

  group('LocalHeaderProbePool.probeAll', () {
    test('dispatches batches concurrently, never above the worker count',
        () async {
      final pool = LocalHeaderProbePool();
      addTearDown(pool.dispose);
      final paths = [
        for (var i = 0; i < LocalHeaderProbePool.batchSize * 8; i++)
          _writeMp4(tmp, 'pool_$i.mp4', durationMs: 2000 + i, w: 640, h: 360),
      ];

      final results = await pool.probeAll(paths);

      expect(results, hasLength(paths.length));
      expect(pool.debugMaxInFlightBatches, greaterThan(1),
          reason: 'serial dispatch leaves all but one worker idle');
      expect(pool.debugMaxInFlightBatches, lessThanOrEqualTo(pool.size));
    });

    test('keeps input order when batches resolve differently', () async {
      final pool = LocalHeaderProbePool();
      addTearDown(pool.dispose);
      // Alternating readable / unreadable headers, spread over several batches
      // so completion order cannot be mistaken for input order.
      final paths = [
        for (var i = 0; i < 96; i++)
          i.isEven
              ? _writeMp4(tmp, 'mix_$i.mp4',
                  durationMs: 3000 + i, w: 320, h: 180)
              : _writeRaw(tmp, 'mix_$i.mp4'),
      ];

      final results = await pool.probeAll(paths);

      expect(results, hasLength(paths.length));
      for (var i = 0; i < paths.length; i++) {
        expect(results[i].durationMs, i.isEven ? 3000 + i : null,
            reason: 'result $i belongs to ${paths[i]}');
      }
    });

    test('a single batch never reports extra concurrency', () async {
      final pool = LocalHeaderProbePool();
      addTearDown(pool.dispose);
      final paths = [
        for (var i = 0; i < 4; i++)
          _writeMp4(tmp, 'one_$i.mp4', durationMs: 100 + i, w: 64, h: 64),
      ];

      await pool.probeAll(paths);

      expect(pool.debugMaxInFlightBatches, 1);
    });
  });
}

class _FakeFallback implements MediaProbeService {
  static const int durationMs = 999;
  final List<String> calls = [];

  @override
  Future<ProbeResult> probeFile(String target) async {
    calls.add(target);
    return const ProbeResult(durationMs: durationMs);
  }

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async {
    calls.addAll(targets);
    return List<ProbeResult>.filled(
        targets.length, const ProbeResult(durationMs: durationMs));
  }
}

String _writeRaw(Directory tmp, String name) {
  final file = File('${tmp.path}/$name');
  file.writeAsBytesSync(List<int>.filled(32, 0));
  return file.path;
}

String _writeBytes(Directory tmp, String name, List<int> bytes) {
  final file = File('${tmp.path}/$name');
  file.writeAsBytesSync(bytes);
  return file.path;
}

/// MPEG1 Layer III, 128 kbit/s, 44,100 Hz CBR: 417-byte frames.
List<int> _buildMp3({required int frames}) {
  const frameBytes = 417;
  final header = [0xFF, 0xFB, 0x90, 0x00];
  final out = <int>[];
  for (var i = 0; i < frames; i++) {
    out
      ..addAll(header)
      ..addAll(List<int>.filled(frameBytes - header.length, 0));
  }
  return out;
}

String _writeMp4(Directory tmp, String name,
    {required int durationMs, required int w, required int h}) {
  final mvhdPayload = <int>[
    0, 0, 0, 0, // version + flags
    ..._u32(0), ..._u32(0), // creation / modification
    ..._u32(1000), ..._u32(durationMs), // timescale / duration
  ];
  final tkhdPayload = <int>[
    0, 0, 0, 0,
    ..._u32(0), ..._u32(0), ..._u32(1), ..._u32(0), ..._u32(0),
    ..._u32(0), ..._u32(0), // reserved
    0, 0,// layer
    0, 0, // alternate group
    0, 0, 0, 0, // volume + reserved
    ...List<int>.filled(36, 0), // matrix
    ..._u32(w << 16), ..._u32(h << 16),
  ];
  final moov = _box('moov', [
    ..._box('mvhd', mvhdPayload),
    ..._box('trak', _box('tkhd', tkhdPayload)),
  ]);
  final bytes = <int>[
    ..._box('ftyp', 'isom'.codeUnits),
    ...moov,
  ];
  final file = File('${tmp.path}/$name');
  file.writeAsBytesSync(Uint8List.fromList(bytes));
  return file.path;
}

List<int> _box(String type, List<int> payload) =>
    [..._u32(payload.length + 8), ...type.codeUnits, ...payload];

List<int> _u32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
