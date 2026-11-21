import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/service/vm_duration_scan.dart';
import 'package:iris/l10n/app_localizations_en.dart';
import 'package:iris/l10n/app_localizations_zh.dart';
import 'package:iris/models/storages/storage.dart';

VirtualSegment seg(String name, {String storage = 'st1'}) {
  return VirtualSegment(
    mediaKey: '$storage:Shorts/$name',
    storageId: storage,
    path: ['Shorts', name],
    name: name,
    parentPath: 'Shorts',
  );
}

class FakeProbe implements MediaProbeService {
  final Map<String, int> durations;
  int batchCalls = 0;

  FakeProbe(this.durations);

  @override
  Future<ProbeResult> probeFile(String target) async {
    final name = target.split('/').last;
    final d = durations[name];
    return ProbeResult(durationMs: d);
  }

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async {
    batchCalls++;
    return [for (final t in targets) await probeFile(t)];
  }
}

class WriteBack {
  final List<({String storageId, String path, int durationMs})> calls = [];
}

void main() {
  test('batch scan writes back probed durations', () async {
    final probe = FakeProbe({'1.mp4': 60000, '2.mp4': 120000});
    final wb = WriteBack();
    final outcome = await scanVmGroupDurations(
      [seg('1.mp4'), seg('2.mp4')],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async {
        wb.calls.add(
            (storageId: storageId, path: path, durationMs: durationMs ?? 0));
        return true;
      },
      storageTypeOf: (_) => StorageType.internal,
    );
    expect(outcome.ok, isTrue);
    expect(outcome.scanned, 2);
    expect(wb.calls, hasLength(2));
    expect(probe.batchCalls, 1);
  });

  test('network segments are skipped, local still scanned', () async {
    final probe = FakeProbe({'1.mp4': 60000});
    final wb = WriteBack();
    final outcome = await scanVmGroupDurations(
      [seg('1.mp4'), seg('9.mp4', storage: 'ftp1')],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async {
        wb.calls.add(
            (storageId: storageId, path: path, durationMs: durationMs ?? 0));
        return true;
      },
      storageTypeOf: (id) => id == 'ftp1' ? StorageType.ftp : StorageType.internal,
    );
    expect(outcome.ok, isTrue);
    expect(outcome.scanned, 1);
    expect(outcome.skipped, 1);
    expect(wb.calls, hasLength(1));
    expect(wb.calls.single.storageId, 'st1');
  });

  test('probe failure yields per-segment failure, others still written', () async {
    final probe = FakeProbe({'1.mp4': 60000});
    final wb = WriteBack();
    final outcome = await scanVmGroupDurations(
      [seg('1.mp4'), seg('bad.mp4')],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async {
        wb.calls.add(
            (storageId: storageId, path: path, durationMs: durationMs ?? 0));
        return true;
      },
      storageTypeOf: (_) => StorageType.internal,
    );
    expect(outcome.ok, isFalse);
    expect(outcome.failedKeys, ['st1:Shorts/bad.mp4']);
    // A probe that returned no duration is genuinely Shell-empty: fast-skip
    // it for the rest of the session.
    expect(outcome.shellEmptyKeys, ['st1:Shorts/bad.mp4']);
    expect(wb.calls, hasLength(1));
  });

  test('cancellation stops after current batch, keeps partial results', () async {    final probe = FakeProbe({'1.mp4': 60000, '2.mp4': 60000});
    final wb = WriteBack();
    var calls = 0;
    final outcome = await scanVmGroupDurations(
      [seg('1.mp4'), seg('2.mp4')],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async {
        wb.calls.add(
            (storageId: storageId, path: path, durationMs: durationMs ?? 0));
        return true;
      },
      storageTypeOf: (_) => StorageType.internal,
      batchSize: 1,
      shouldCancel: () => calls++ >= 1,
    );
    expect(outcome.cancelled, isTrue);
    expect(wb.calls, hasLength(1));
  });

  test('summary reports success counts and elapsed', () async {
    final probe = FakeProbe({'1.mp4': 60000, '2.mp4': 120000});
    final outcome = await scanVmGroupDurations(
      [seg('1.mp4'), seg('2.mp4')],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async => true,
      storageTypeOf: (_) => StorageType.internal,
    );
    expect(outcome.ok, isTrue);
    expect(outcome.summary(AppLocalizationsZh()), contains('成功2'));
    expect(outcome.summary(AppLocalizationsZh()), contains('耗时'));
    expect(outcome.summary(AppLocalizationsEn()), contains('OK 2'));
    expect(outcome.summary(AppLocalizationsEn()), contains('took'));
  });

  test('summary reports skipped, failed and timedOut parts', () async {
    final probe = FakeProbe({'1.mp4': 60000});
    final outcome = await scanVmGroupDurations(
      [seg('1.mp4'), seg('bad.mp4'), seg('9.mp4', storage: 'ftp1')],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async => true,
      storageTypeOf: (id) => id == 'ftp1' ? StorageType.ftp : StorageType.internal,
    );
    expect(outcome.ok, isFalse);
    final zh = outcome.summary(AppLocalizationsZh());
    expect(zh, contains('成功1'));
    expect(zh, contains('跳过1'));
    expect(zh, contains('失败1'));
    final en = outcome.summary(AppLocalizationsEn());
    expect(en, contains('OK 1'));
    expect(en, contains('skipped 1'));
    expect(en, contains('failed 1'));
  });

  test('SAF segments probe the persisted content:// uri, not a mangled path',
      () async {
    const tree =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload';
    const doc = '$tree/document/42';
    final probe = _RecordingProbe({doc: 60000});
    final wb = WriteBack();
    final outcome = await scanVmGroupDurations(
      [
        VirtualSegment(
          mediaKey: '$tree/Movies/a.mp4',
          storageId: 'saf1',
          path: [tree, 'Movies', 'a.mp4'],
          name: 'a.mp4',
          parentPath: '$tree/Movies',
          uri: doc,
        ),
      ],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async {
        wb.calls.add(
            (storageId: storageId, path: path, durationMs: durationMs ?? 0));
        return true;
      },
      storageTypeOf: (_) => StorageType.internal,
    );
    expect(outcome.ok, isTrue);
    expect(probe.targets, [doc]);
    expect(wb.calls.single.path, '$tree/Movies/a.mp4');
  });

  test('batch throw retries as singles: one poison file spares the rest',
      () async {
    final probe = _BatchThrowProbe({'1.mp4': 60000, '2.mp4': 120000});
    final wb = WriteBack();
    final outcome = await scanVmGroupDurations(
      [seg('1.mp4'), seg('2.mp4'), seg('bad.mp4')],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async {
        wb.calls.add(
            (storageId: storageId, path: path, durationMs: durationMs ?? 0));
        return true;
      },
      storageTypeOf: (_) => StorageType.internal,
    );
    expect(outcome.ok, isFalse);
    expect(probe.singleCalls, greaterThanOrEqualTo(3));
    expect(wb.calls, hasLength(2));
    expect(outcome.failedKeys, ['st1:Shorts/bad.mp4']);
  });

    test('slow batch keeps in-hand results then reports timedOut', () async {    final probe = _DelayedProbe({'1.mp4': 60000, '2.mp4': 120000},
        delay: const Duration(milliseconds: 50));
    final wb = WriteBack();
    final outcome = await scanVmGroupDurations(
      [seg('1.mp4'), seg('2.mp4')],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async {
        wb.calls.add(
            (storageId: storageId, path: path, durationMs: durationMs ?? 0));
        return true;
      },
      storageTypeOf: (_) => StorageType.internal,
      // Setup stays microseconds; the 50ms probe blows past 20ms mid-batch.
      budget: const Duration(milliseconds: 20),
    );
    expect(outcome.timedOut, isTrue);
    expect(outcome.cancelled, isFalse);
    // In-hand batch persisted despite the timeout (incremental contract).
    expect(wb.calls, hasLength(2));
    expect(outcome.report, isNotNull);
  });

  test('batch write-backs overlap but results stay batch-ordered', () async {
    final probe = FakeProbe(
        {'1.mp4': 60000, '2.mp4': 120000, '3.mp4': 90000});
    // First completion is slowest: bare concurrency would reorder keys.
    final wb = _SlowWriteBack({'1.mp4': 60, '2.mp4': 5, '3.mp4': 5});
    final outcome = await scanVmGroupDurations(
      [seg('1.mp4'), seg('2.mp4'), seg('3.mp4')],
      probeService: probe,
      writeBack: wb.call,
      storageTypeOf: (_) => StorageType.internal,
    );
    expect(outcome.ok, isTrue);
    expect(outcome.succeededKeys, [
      'st1:Shorts/1.mp4',
      'st1:Shorts/2.mp4',
      'st1:Shorts/3.mp4',
    ]);
  });

  test('a skipKey that already carries a duration is not double-counted',
      () async {
    final probe = FakeProbe({'2.mp4': 60000});
    final progress = <int>[];
    final outcome = await scanVmGroupDurations(
      // 1.mp4 is in skipKeys AND already known: it must count exactly once.
      [seg('1.mp4').withDuration(60000), seg('2.mp4')],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async =>
          true,
      storageTypeOf: (_) => StorageType.internal,
      skipKeys: {'st1:Shorts/1.mp4'},
      onProgress: (done, total, _) => progress.add(done),
    );
    expect(outcome.ok, isTrue);
    expect(outcome.scanned, 1);
    expect(outcome.failedKeys, isEmpty);
    // Never overshoots the total (the old double-count printed 3/2).
    expect(progress.every((d) => d <= 2), isTrue);
    expect(progress.last, 2);
  });

  test('progress reaches 100% even when network segments are left unknown',
      () async {
    final probe = FakeProbe({'1.mp4': 60000});
    final progress = <int>[];
    final outcome = await scanVmGroupDurations(
      [seg('1.mp4'), seg('9.mp4', storage: 'ftp1')],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async =>
          true,
      storageTypeOf: (id) =>
          id == 'ftp1' ? StorageType.ftp : StorageType.internal,
      onProgress: (done, total, _) => progress.add(done),
    );
    expect(outcome.skipped, 1);
    // Terminal sample reports the caller-visible total, so the bar completes
    // instead of freezing below 100%.
    expect(progress.last, 2);
  });

  test('write-back no-op (missing media row) is a failure, not a success',
      () async {
    final probe = FakeProbe({'1.mp4': 60000});
    final outcome = await scanVmGroupDurations(
      [seg('1.mp4')],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async =>
          false,
      storageTypeOf: (_) => StorageType.internal,
    );
    expect(outcome.ok, isFalse);
    expect(outcome.scanned, 0);
    expect(outcome.failedKeys, ['st1:Shorts/1.mp4']);
    // The probe succeeded; only the row was missing. It must NOT be
    // fast-skipped for the session, or a later scan after the row appears
    // could never heal it.
    expect(outcome.shellEmptyKeys, isEmpty);
  });

  test('timeout report never shows a negative remainder on a mixed group',
      () async {
    final probe = FakeProbe({'3.mp4': 60000});
    final outcome = await scanVmGroupDurations(
      // Two known + one unknown: `done` includes the known rows, but the
      // remaining work is measured over `local` only.
      [
        seg('1.mp4').withDuration(60000),
        seg('2.mp4').withDuration(60000),
        seg('3.mp4'),
      ],
      probeService: probe,
      writeBack: ({
        required String storageId,
        required String path,
        int? durationMs,
        int? width,
        int? height,
      }) async {
        return true;
      },
      storageTypeOf: (_) => StorageType.internal,
      budget: Duration.zero,
      l10n: AppLocalizationsEn(),
    );
    expect(outcome.timedOut, isTrue);
    expect(outcome.report, isNotNull);
    expect(outcome.report, isNot(contains('-1')));
    expect(outcome.report, contains('1 left'));
  });
}

class _RecordingProbe implements MediaProbeService {  final Map<String, int> durations;
  final List<String> targets = [];

  _RecordingProbe(this.durations);

  @override
  Future<ProbeResult> probeFile(String target) async {
    targets.add(target);
    return ProbeResult(durationMs: durations[target]);
  }

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async {
    return [for (final t in targets) await probeFile(t)];
  }
}

/// Batch entry always throws (isolate spawn failure shape); singles work.
class _BatchThrowProbe implements MediaProbeService {
  final Map<String, int> durations;
  int singleCalls = 0;

  _BatchThrowProbe(this.durations);

  @override
  Future<ProbeResult> probeFile(String target) async {
    singleCalls++;
    final name = target.split('/').last;
    return ProbeResult(durationMs: durations[name]);
  }

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async {
    throw StateError('isolate spawn failed');
  }
}

/// Batch entry sleeps past tiny budgets so the post-probe gate fires.
class _DelayedProbe implements MediaProbeService {
  final Map<String, int> durations;
  final Duration delay;

  _DelayedProbe(this.durations, {required this.delay});

  @override
  Future<ProbeResult> probeFile(String target) async {
    final name = target.split('/').last;
    return ProbeResult(durationMs: durations[name]);
  }

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async {
    await Future<void>.delayed(delay);
    return [for (final t in targets) await probeFile(t)];
  }
}

/// Write-back with per-key delays to prove batch-ordered results.
class _SlowWriteBack {
  final Map<String, int> delaysMs;
  final List<String> calls = [];

  _SlowWriteBack(this.delaysMs);

  Future<bool> call({
    required String storageId,
    required String path,
    int? durationMs,
    int? width,
    int? height,
  }) async {
    final name = path.split('/').last;
    await Future<void>.delayed(Duration(milliseconds: delaysMs[name] ?? 0));
    calls.add(path);
    return true;
  }
}
