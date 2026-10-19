import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/services/background_duration_probe.dart';
import 'package:iris/features/background_playback/services/background_lock_mapping.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/models/file.dart';

/// A 副音 queue entry whose duration cannot be read used to be recorded as 0,
/// which silently collapsed 副音's position onto its head (and, through the
/// 连续锁步 drift correction, dragged the VIDEO there — 「开启副音把播放进度归
/// 0」). These tests pin the two halves of the fix: the queue is PROBED instead
/// of faked, and the timeline refuses to fabricate a position.
FileItem _f(String name, {String storageId = ''}) =>
    FileItem(name: name, uri: 'file:///$name', path: [name], storageId: storageId);

class _FakeProbe implements MediaProbeService {
  _FakeProbe(this.durations);

  /// Probe target (`nodePlayableUri` output) → duration in ms (null = empty).
  final Map<String, int?> durations;

  @override
  Future<ProbeResult> probeFile(String target) async =>
      ProbeResult(durationMs: durations[target]);

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async =>
      [for (final t in targets) ProbeResult(durationMs: durations[t])];
}

void main() {
  group('BgQueueTimeline unknown durations', () {
    test('an unknown entry never fabricates a position', () {
      final t = BgQueueTimeline(
        const [0, 600000],
        unknownIndices: const {0},
      );
      // The OLD behavior (a 0 collapsed onto the head) is still available for
      // the foreground queue, but the 副音 mirror must read NULL.
      expect(t.virtualPositionOf(0, 5000), 0);
      expect(t.tryVirtualPositionOf(0, 5000), isNull);
      // A LATER entry's virtual position is still wrong (the prefix treats the
      // unknown entry as 0 ms), which is exactly why the mirror must consult
      // [mappingUsableThrough] before using any of these numbers.
      expect(t.tryVirtualPositionOf(1, 5000), 5000);
      expect(t.mappingUsableThrough(1), isFalse);
    });

    test('a zero duration counts as unknown even without an explicit mark', () {
      final t = BgQueueTimeline(const [600000, 0]);
      expect(t.tryVirtualPositionOf(1, 1000), isNull);
      expect(t.hasUnknown, isFalse, reason: 'no explicit mark was passed');
    });

    test('mappingUsableThrough only trusts a prefix with known durations', () {
      final t = BgQueueTimeline(
        const [600000, 0, 600000],
        unknownIndices: const {1},
      );
      expect(t.mappingUsableThrough(0), isTrue);
      expect(t.mappingUsableThrough(1), isFalse);
      expect(t.mappingUsableThrough(2), isFalse);
      expect(t.fullyKnown, isFalse);
    });

    test('a fully known timeline is usable and rollable', () {
      final t = BgQueueTimeline(const [600000, 300000]);
      expect(t.fullyKnown, isTrue);
      expect(t.mappingUsableThrough(1), isTrue);
      expect(t.knownAt(1), isTrue);
      expect(t.tryVirtualPositionOf(1, 0), 600000);
    });

    test('an empty timeline is never usable', () {
      final t = BgQueueTimeline(const []);
      expect(t.fullyKnown, isFalse);
      expect(t.mappingUsableThrough(0), isFalse);
      expect(t.tryVirtualPositionOf(0, 0), isNull);
    });
  });

  group('probeMissingBgDurations', () {
    test('resolves, fails and skips by storage in one pass', () async {
      final a = _f('a');
      final b = _f('b');
      final c = _f('c', storageId: 'net');
      final written = <String>[];
      final outcome = await probeMissingBgDurations(
        [a, b, c],
        probeService: _FakeProbe({
          'file:///a': 60000,
          // b: no result -> probe failure
        }),
        isNetwork: (id) => id == 'net',
        writeBack: ({required storageId, required path, required durationMs}) async {
          written.add('$storageId:$path=$durationMs');
          return 1;
        },
      );

      expect(outcome.resolvedKeys, [backgroundMediaKey(a)]);
      expect(outcome.failedKeys, [backgroundMediaKey(b)]);
      expect(outcome.skippedNetworkKeys, [backgroundMediaKey(c)]);
      expect(written, [':a=60000']);
    });

    test('a write-back with no matching DB row is a FAILURE, not a success',
        () async {
      final a = _f('a');
      final outcome = await probeMissingBgDurations(
        [a],
        probeService: _FakeProbe({'file:///a': 60000}),
        isNetwork: (_) => false,
        writeBack: ({required storageId, required path, required durationMs}) async => 0,
      );
      expect(outcome.resolvedKeys, isEmpty);
      expect(outcome.failedKeys, [backgroundMediaKey(a)]);
    });

    test('a non-positive probe duration is a failure', () async {
      final a = _f('a');
      final outcome = await probeMissingBgDurations(
        [a],
        probeService: _FakeProbe({'file:///a': 0}),
        isNetwork: (_) => false,
        writeBack: ({required storageId, required path, required durationMs}) async => 1,
      );
      expect(outcome.failedKeys, [backgroundMediaKey(a)]);
      expect(outcome.resolvedKeys, isEmpty);
    });

    test('a throwing probe batch degrades per file instead of failing all',
        () async {
      final a = _f('a');
      final b = _f('b');
      final outcome = await probeMissingBgDurations(
        [a, b],
        probeService: _ThrowingProbe(),
        isNetwork: (_) => false,
        writeBack: ({required storageId, required path, required durationMs}) async => 1,
      );
      expect(outcome.resolvedKeys, isEmpty);
      expect(outcome.failedKeys, [backgroundMediaKey(a), backgroundMediaKey(b)]);
    });
  });
}

class _ThrowingProbe implements MediaProbeService {
  @override
  Future<ProbeResult> probeFile(String target) async => throw StateError('boom');

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async =>
      throw StateError('boom');
}
