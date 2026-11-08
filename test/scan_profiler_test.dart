import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/service/scan_profiler.dart';

/// The scan profiler exists so "why is the phone slow" is answered by numbers
/// from the device instead of by platform assumptions: the same code is IO-bound
/// on a desktop and per-directory-statement-bound on a phone.
void main() {
  test('summary orders phases by total time so the first name is the culprit',
      () {
    final profiler = ScanProfiler();
    profiler.record('list', const Duration(milliseconds: 600));
    profiler.record('kv', const Duration(seconds: 41));
    profiler.record('sync', const Duration(seconds: 24, milliseconds: 300));

    expect(profiler.summary(), startsWith('kv=41.00s'));
    expect(profiler.summary(), contains('sync=24.30s'));
    expect(profiler.summary(), endsWith('list=600ms'));
  });

  test('per-item average is reported when the work count is known', () {
    final profiler = ScanProfiler();
    profiler.record('list', const Duration(milliseconds: 300), items: 100);

    expect(profiler.summary(), 'list=300ms/100(3ms/it)');
  });

  test('repeated blocks accumulate into one phase total', () {
    final profiler = ScanProfiler();
    for (var i = 0; i < 4; i++) {
      profiler.record('sync', const Duration(milliseconds: 25), items: 1);
    }

    expect(profiler.total('sync'), const Duration(milliseconds: 100));
    expect(profiler.calls('sync'), 4);
    expect(profiler.summary(), 'sync=100ms/4(25ms/it)');
  });

  test('time() records even when the body throws', () async {
    final profiler = ScanProfiler();
    await expectLater(
      profiler.time('list', () async => throw StateError('boom')),
      throwsStateError,
    );

    expect(profiler.calls('list'), 1);
  });

  test('time() returns the body result unchanged', () async {
    final profiler = ScanProfiler();
    final value = await profiler.time('list', () async => 42);

    expect(value, 42);
    expect(profiler.calls('list'), 1);
  });

  test('an empty profiler never fabricates a number', () {
    expect(ScanProfiler().summary(), 'no-phase-timings');
  });
}
