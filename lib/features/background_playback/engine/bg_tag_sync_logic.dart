import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/model/enum/bg_queue_sync_mode.dart';
import 'package:iris/models/file.dart';

/// What a live 副音 run does with a candidate pool that changed under it.
enum BgTagSyncAction {
  /// Leave the running queue alone (not running, nothing new, or no change).
  none,

  /// Re-resolved the whole pool and replaced the queue, keeping the current
  /// file where it survived.
  rebuild,

  /// Added only the candidates the queue is missing.
  append,
}

/// Decides how a freshly resolved candidate pool folds into a running queue.
///
/// Pure on purpose: this is the whole behavioural contract of the setting
/// (see [BgQueueSyncMode]), so it is decided here and unit-tested rather than
/// discovered through a running pair.
///
/// Two guards keep a background write from disturbing playback for nothing:
/// - a run that is off, or stopped by the user gate, is never rewritten (its
///   queue is re-resolved on the next launch anyway);
/// - a resolve that yields exactly what is queued is a no-op, so the common
///   "a tag someone else uses changed" case costs no store write and no
///   persist.
///
/// [shuffled] must mirror `BackgroundPlaybackState.shuffle`, because it decides
/// what "the same queue" means: with shuffle on, the order is random and only
/// the MEMBERSHIP can be compared, otherwise every unrelated write would look
/// like a change and re-shuffle the whole list. With shuffle off the rules own
/// the order, so a reordering IS the change [BgQueueSyncMode.rebuild] exists to
/// apply.
BgTagSyncAction resolveBgTagSyncAction({
  required BgQueueSyncMode mode,
  required List<FileItem> queue,
  required List<FileItem> candidates,
  required bool enabled,
  required bool gateOpen,
  bool shuffled = false,
}) {
  if (!enabled || !gateOpen) return BgTagSyncAction.none;
  // An empty resolve must not empty a live queue — same contract as
  // `BackgroundPlaybackStore.replaceQueue`.
  if (candidates.isEmpty) return BgTagSyncAction.none;
  return switch (mode) {
    BgQueueSyncMode.rebuild => (shuffled
            ? holdsSameMedia(queue, candidates)
            : queueMatchesPool(queue, candidates))
        ? BgTagSyncAction.none
        : BgTagSyncAction.rebuild,
    BgQueueSyncMode.append => appendedBgQueue(
          queue: queue,
          candidates: candidates,
        ).length ==
            queue.length
        ? BgTagSyncAction.none
        : BgTagSyncAction.append,
  };
}

/// Whether both lists cover the same media, in ANY order.
///
/// The order-insensitive comparison, used when the queue is shuffled: the
/// queue order is then random and carries no meaning, so a pool that came back
/// reordered is not a change worth rewriting for. A [queue] holding its own
/// duplicate reports `false` because a set comparison cannot tell that state
/// apart from a plain set.
bool holdsSameMedia(List<FileItem> queue, List<FileItem> candidates) {
  if (queue.length != candidates.length) return false;
  final keys = {for (final f in queue) backgroundMediaKey(f)};
  if (keys.length != queue.length) return false;
  for (final f in candidates) {
    if (!keys.contains(backgroundMediaKey(f))) return false;
  }
  return true;
}

/// [queue] followed by every candidate it does not already hold, in resolved
/// order. Identity is [backgroundMediaKey], so the same physical media is never
/// queued twice.
List<FileItem> appendedBgQueue({
  required List<FileItem> queue,
  required List<FileItem> candidates,
}) {
  if (candidates.isEmpty) return List<FileItem>.of(queue);
  final seen = {for (final f in queue) backgroundMediaKey(f)};
  final next = List<FileItem>.of(queue);
  for (final file in candidates) {
    if (seen.add(backgroundMediaKey(file))) next.add(file);
  }
  return next;
}

/// Whether the queue already IS the resolved pool, entry for entry.
///
/// Order is part of the answer on purpose: the source rules own the order, so
/// a pool that came back with the same media in a different order (a new
/// member pushing the tag-time ranking along) is a REAL change that
/// [BgQueueSyncMode.rebuild] must apply. Comparing as sets would silently
/// swallow exactly the reordering the mode exists to perform.
bool queueMatchesPool(List<FileItem> queue, List<FileItem> candidates) {
  if (queue.length != candidates.length) return false;
  for (var i = 0; i < queue.length; i++) {
    if (backgroundMediaKey(queue[i]) != backgroundMediaKey(candidates[i])) {
      return false;
    }
  }
  return true;
}
