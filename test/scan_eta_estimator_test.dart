import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/service/scan_eta_estimator.dart';

/// ETA policy contracts for the recursive scan.
///
/// `totalDirs` grows during discovery, so the estimate is rate-based and must
/// stay silent until it has warmed up, ignore frozen (paused) samples, and
/// never divide by a zero rate.
void main() {
  group('ScanEtaEstimator', () {
    test('returns null before any sample / warm-up threshold', () {
      final e = ScanEtaEstimator(minSamples: 5);
      expect(e.eta(0, 100), isNull);

      // First sample only seeds the baseline — no interval yet.
      e.sample(1, Duration.zero);
      expect(e.eta(1, 100), isNull);

      // Below minSamples still withholds an estimate.
      e.sample(4, const Duration(seconds: 4));
      expect(e.eta(4, 100), isNull);
    });

    test('produces an estimate once warmed up', () {
      final e = ScanEtaEstimator(minSamples: 5);
      // 5 dirs in 5s → 1 dir/s, remaining 95 → ~95s.
      e.sample(0, Duration.zero);
      e.sample(5, const Duration(seconds: 5));

      final eta = e.eta(5, 100);
      expect(eta, isNotNull);
      expect(eta!.inSeconds, closeTo(95, 2));
    });

    test('EWMA smooths a throughput spike instead of jumping', () {
      final e = ScanEtaEstimator(alpha: 0.3, minSamples: 0);
      // Warm up at 1 dir/s.
      e.sample(0, Duration.zero);
      e.sample(10, const Duration(seconds: 10));
      final before = e.eta(10, 1000)!;

      // A single 10 dir/s burst must move the rate, but not by the full jump.
      e.sample(20, const Duration(seconds: 11));
      final after = e.eta(20, 1000)!;

      // Raw burst would imply ~98s; smoothed must be well above that.
      expect(after.inSeconds, greaterThan(150));
      expect(after.inSeconds, lessThan(before.inSeconds));
    });

    test('paused sample (frozen elapsed) is ignored', () {
      final e = ScanEtaEstimator(minSamples: 0);
      e.sample(0, Duration.zero);
      e.sample(10, const Duration(seconds: 10));
      final before = e.eta(10, 100)!;

      // Same elapsed → zero interval → no rate update.
      e.sample(10, const Duration(seconds: 10));
      expect(e.eta(10, 100)!.inSeconds, before.inSeconds);
    });

    test('zero rate yields no estimate (never divides by zero)', () {
      final e = ScanEtaEstimator(minSamples: 0);
      e.sample(0, Duration.zero);
      // 10s elapsed with no progress → instant rate 0.
      e.sample(0, const Duration(seconds: 10));
      expect(e.eta(0, 100), isNull);
    });

    test('remaining <= 0 collapses to zero, not negative', () {
      final e = ScanEtaEstimator(minSamples: 0);
      e.sample(0, Duration.zero);
      e.sample(50, const Duration(seconds: 10));
      expect(e.eta(100, 100), Duration.zero);
      expect(e.eta(120, 100), Duration.zero);
    });

    test('an unknown total (never scanned) yields no estimate', () {
      // 0 is "nobody knows the tree size", not "zero directories left":
      // treating it as the latter made the overlay promise "0 s left" while the
      // walk had just begun.
      final e = ScanEtaEstimator(minSamples: 0);
      e.sample(0, Duration.zero);
      e.sample(50, const Duration(seconds: 10));
      expect(e.eta(50, 0), isNull);
    });

    test('reset clears the accumulated rate', () {
      final e = ScanEtaEstimator(minSamples: 0);
      e.sample(0, Duration.zero);
      e.sample(10, const Duration(seconds: 10));
      expect(e.eta(10, 100), isNotNull);

      e.reset();
      expect(e.eta(10, 100), isNull);
    });
  });
}
