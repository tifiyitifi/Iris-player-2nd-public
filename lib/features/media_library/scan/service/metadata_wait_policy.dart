/// How long the play gate may hold playback back for metadata.
///
/// WHY a budget at all: the list is playable as soon as the rows exist, so the
/// wait only buys a fully duration-ordered queue. It must therefore stay in the
/// "a few seconds" range — a header parse is ~1 ms warm but ~8 ms cold on an
/// external drive, so a 1.3k-file folder is ~10 s of IO. Waiting that long is
/// exactly the "the folder takes forever to start" complaint.
const Duration kMetadataWaitBudget = Duration(seconds: 4);

/// Files that must be probed before the throughput projection is trusted.
///
/// The first batch pays the worker-pool spawn and a cold directory listing, so
/// projecting from it would understate throughput and release too early.
const int kMetadataWaitSample = 64;

/// Rows a pass may examine before "the probe resolves NOTHING" ends the wait.
///
/// A whole sample with zero usable durations is not bad luck — it is a probe
/// that cannot read these files (wrong path, unparseable container, broken
/// library). Continuing only repeats the same dead work against the budget.
/// Two batches, not one: a folder may legitimately START with a run of
/// unreadable files, and giving up on the rest of the list would leave it
/// unsorted for no reason.
const int kMetadataStallSample = 128;

/// Whether the remaining rows cannot be probed inside what is left of [budget].
///
/// The projection is deliberately about the REMAINING time, not the total: a
/// pass that is 90% done with 0.4 s of work left is worth finishing even after
/// 3.5 s. When this returns true the caller releases playback immediately and
/// lets a background pass keep filling, so the user never waits for a queue
/// order that was never going to arrive in time.
///
/// Returns false while [done] is below [kMetadataWaitSample] and when nothing is
/// left to do.
bool shouldReleaseMetadataWait({
  required int done,
  required int total,
  required Duration elapsed,
  required Duration budget,
}) {
  if (done <= 0 || done < kMetadataWaitSample) return false;
  if (total <= done) return false;
  final spentMicros = elapsed.inMicroseconds;
  if (spentMicros <= 0) return false;
  final perFileMicros = spentMicros / done;
  final projectedRestMicros = perFileMicros * (total - done);
  final restBudgetMicros = budget.inMicroseconds - spentMicros;
  return restBudgetMicros <= 0 || projectedRestMicros > restBudgetMicros;
}
