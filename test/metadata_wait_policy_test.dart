import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/service/metadata_wait_policy.dart';

/// The wait before playback is what the user feels, so it is bounded by a
/// MEASURED projection rather than a flat ceiling: finish the ordering when it
/// fits in the budget, otherwise play now and sort the rest while the video
/// runs.
void main() {
  const budget = kMetadataWaitBudget;

  test('never projects before the sample is measured', () {
    expect(
      shouldReleaseMetadataWait(
        done: kMetadataWaitSample - 1,
        total: 5000,
        elapsed: const Duration(seconds: 3),
        budget: budget,
      ),
      isFalse,
    );
  });

  test('keeps waiting when the remaining work fits', () {
    // 1 ms/file (warm cache): 1000 files → 64 ms for the sample, ~936 ms left.
    expect(
      shouldReleaseMetadataWait(
        done: 64,
        total: 1000,
        elapsed: const Duration(milliseconds: 64),
        budget: budget,
      ),
      isFalse,
    );
  });

  test('releases when the measured throughput cannot finish in time', () {
    // 8 ms/file (cold external drive): 1320 files ≈ 10 s, so the projection at
    // the 64-file mark already exceeds what is left of the budget.
    expect(
      shouldReleaseMetadataWait(
        done: 64,
        total: 1320,
        elapsed: const Duration(milliseconds: 512),
        budget: budget,
      ),
      isTrue,
    );
  });

  test('finishes a pass that is nearly done instead of giving up', () {
    // 990/1000 at 3.5 s: 35 ms of work left against 0.5 s of budget.
    expect(
      shouldReleaseMetadataWait(
        done: 990,
        total: 1000,
        elapsed: const Duration(milliseconds: 3500),
        budget: budget,
      ),
      isFalse,
    );
  });

  test('releases once the budget is already spent', () {
    expect(
      shouldReleaseMetadataWait(
        done: 100,
        total: 1000,
        elapsed: budget,
        budget: budget,
      ),
      isTrue,
    );
  });

  test('does nothing when the work list is already exhausted', () {
    expect(
      shouldReleaseMetadataWait(
        done: 1000,
        total: 1000,
        elapsed: const Duration(seconds: 3),
        budget: budget,
      ),
      isFalse,
    );
  });
}
