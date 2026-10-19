/// How a LIVE 副音 run absorbs a membership change of a tag it reads from.
///
/// The running queue is a snapshot built at start time, so a video tagged into
/// 「副音备选」 (or any tag the background scenario's sources read) does not
/// reach the open queue panel until something reconciles it. This setting only
/// decides HOW that reconciliation rewrites the queue; the decision to
/// reconcile at all lives in `BgQueueSyncObserver` (which reacts to
/// `BgPoolRevision`).
///
/// Persisted as the `bg.queueSyncMode` AUX row.
enum BgQueueSyncMode {
  /// Re-resolve the whole candidate pool and REPLACE the queue, keeping the
  /// currently playing file (and its index) when it survived. The result
  /// matches the source rules' own sort, so removals also drop out of the
  /// queue. Default.
  rebuild,

  /// Only RECONCILE when the pool GAINED a member: a pure reorder or a removal
  /// leaves the running window untouched, so an unrelated tag write never
  /// reorders or restarts anything. When it did grow, the window is re-resolved
  /// around the file that is playing, exactly like [rebuild].
  ///
  /// A truly append-only FLAT list cannot coexist with the window runtime
  /// (`offset == globalIndex − windowStart` would break for the appended
  /// entries, which then fall off the next slide), and materializing the whole
  /// stream to hold such a list would defeat the large-library design (a
  /// 500k-item scenario is only ever resolved page by page). So the growth is
  /// folded back into a window rebuild.
  append,
}
