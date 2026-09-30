/// How a LIVE 副音 run absorbs a membership change of a tag it reads from.
///
/// The running queue is a snapshot built at start time, so a video tagged into
/// 「副音备选」 (or any tag a source rule points at) does not reach the open
/// queue panel until something reconciles it. This setting only decides HOW
/// that reconciliation rewrites the queue; the decision to reconcile at all
/// lives in the relevance check + the coalescing window of
/// `BackgroundCandidateCache`.
///
/// Persisted as the `bg.queueSyncMode` AUX row.
enum BgQueueSyncMode {
  /// Re-resolve the whole candidate pool and REPLACE the queue, keeping the
  /// currently playing file (and its index) when it survived. The result
  /// matches the source rules' own sort, so removals also drop out of the
  /// queue. Default.
  rebuild,

  /// Only APPEND members the queue does not hold yet, in resolved order, and
  /// never touch what is already queued. The gentlest option — nothing
  /// restarts and the running file keeps its position — at the price of the
  /// queue no longer mirroring the rules' sort, and of a removed member
  /// staying queued until the next manual refresh.
  append,
}
