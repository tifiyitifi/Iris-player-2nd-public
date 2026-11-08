import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/android_media_probe.dart';
import 'package:iris/features/media_library/scan/probe/fast_local_probe.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';

/// Phone-side probe routing.
///
/// Measured on a 2019 Android 10 device: `MediaMetadataRetriever` costs 5–30 ms
/// per file through a binder call, and 300–450 ms under load — while the Dart
/// header parser that already ships for Windows answers in ~1 ms. Android used
/// to be wired straight to the retriever, so the desktop speed-up never reached
/// the phone.
class _FakeProbe implements MediaProbeService {
  int singleCalls = 0;
  int batchCalls = 0;
  final List<String> seen = <String>[];

  @override
  Future<ProbeResult> probeFile(String target) async {
    singleCalls++;
    seen.add(target);
    return const ProbeResult(durationMs: 1);
  }

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async {
    batchCalls++;
    seen.addAll(targets);
    return List<ProbeResult>.filled(
        targets.length, const ProbeResult(durationMs: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('iris/media_probe');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('platform selection', () {
    test('android uses the header parser with the retriever as fallback', () {
      final service = createMediaProbeServiceFor(
        isWindows: false,
        isAndroid: true,
      );

      expect(service, isA<FastLocalProbeService>(),
          reason: 'the ~1 ms header path must not be Windows-only');
    });

    test('windows keeps its existing strategy', () {
      expect(
        createMediaProbeServiceFor(isWindows: true, isAndroid: false),
        isA<FastLocalProbeService>(),
      );
    });

    test('other platforms stay on the null probe', () {
      expect(
        createMediaProbeServiceFor(isWindows: false, isAndroid: false),
        isA<NullMediaProbeService>(),
      );
    });
  });

  group('android fast-path routing', () {
    test('content:// targets bypass the header parser', () async {
      final fake = _FakeProbe();
      final service = FastLocalProbeService(fallback: fake);

      await service.probeFiles(const [
        'content://com.android.externalstorage.documents/tree/x/a.mp4',
      ]);

      expect(fake.batchCalls, 1,
          reason: 'a SAF document has no filesystem path to parse');
      await service.dispose();
    });
  });

  group('android probe channel', () {
    test('probeFiles sends ONE batch call and keeps input order', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        final targets =
            (call.arguments as Map)['targets'] as List<dynamic>;
        return <Map<String, dynamic>>[
          for (final _ in targets) const {'durationMs': 5000, 'width': 1920},
        ];
      });

      final results = await const AndroidMediaProbeService()
          .probeFiles(const ['a.mp4', 'b.mkv', 'c.avi']);

      expect(calls, ['probeBatch'],
          reason: 'one round trip per batch, not one per file');
      expect(results, hasLength(3));
      expect(results.every((r) => r.durationMs == 5000), isTrue);
      expect(results.every((r) => r.width == 1920), isTrue);
    });

    test('unprobeable entries decode to empty without shifting the list',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <dynamic>[
          const {'durationMs': 1000},
          const <String, dynamic>{},
          const {'durationMs': 3000},
        ];
      });

      final results = await const AndroidMediaProbeService()
          .probeFiles(const ['a.mp4', 'b.mp4', 'c.mp4']);

      expect(results.map((r) => r.durationMs).toList(), [1000, null, 3000]);
    });

    test('a missing batch method falls back to one call per file', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'probeBatch') {
          throw MissingPluginException('probeBatch');
        }
        return <String, dynamic>{'durationMs': 7000};
      });

      final results = await const AndroidMediaProbeService()
          .probeFiles(const ['a.mp4', 'b.mp4']);

      expect(calls, ['probeBatch', 'probe', 'probe']);
      expect(results.map((r) => r.durationMs).toList(), [7000, 7000]);
    });

    test('an empty target list never reaches the channel', () async {
      var called = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        called = true;
        return null;
      });

      expect(await const AndroidMediaProbeService().probeFiles(const []),
          isEmpty);
      expect(called, isFalse);
    });
  });
}
