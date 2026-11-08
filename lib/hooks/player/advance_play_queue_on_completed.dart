import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/store/use_play_queue_store.dart';

/// Advances the play queue after the current media finished naturally.
///
/// This is the foreground's OWN end, and it stays ordinary playback: the queue
/// advances (or stops at the last entry with repeat off) exactly as it would
/// without 副音. 副音 is not told about it here — the 作用范围 observer owns what
/// the NEW foreground media does to the pair (全部 + 切新 bg may step the 副音
/// queue, 仅当前 pauses it, 智能 starts it only with a saved pairing), and the
/// 副音 FILE's own end is owned by `BgExhaustedAction`. The one deliberate
/// exception is 仅当前 + 高同步, where a 副音 mapped past the video's window pauses
/// both runtimes (see `shouldPauseBgPastWindow` in `BackgroundRuntimeScope`).
/// With 完全独立 the 副音 simply keeps playing across the switch.
///
/// Shared by both player hooks (media_kit + fvp) so their end-of-file
/// behavior cannot drift: in query/paged mode the synthetic queue is always
/// length 1, so the legacy "is this the last item?" check must be replaced by
/// the backend's virtual position/total count.
///
/// Returns whether the queue REALLY moved. The caller needs the difference: on
/// the last entry with repeat off nothing advances, and a tail-finish latch left
/// armed there would drop every later step press (a finished movie could not be
/// stepped or rewound again).
///
/// [store] defaults to the global store; it is injectable for tests.
Future<bool> advancePlayQueueOnCompleted(
  Repeat repeat, {
  UnifiedPlayQueueStore? store,
}) async {
  final queue = store ?? usePlayQueueStore();
  if (queue.isQueryMode) {
    if (queue.currentVirtualPos >= queue.totalCount - 1) {
      if (repeat == Repeat.all) {
        await queue.next();
        return true;
      }
      return false;
    }
    await queue.next();
    return true;
  }

  final playQueue = queue.state.playQueue;
  final currentPlayIndex = queue.state.currentIndex;
  final index = playQueue.indexWhere((e) => e.index == currentPlayIndex);
  if (playQueue.isEmpty || index < 0) return false;
  if (index == playQueue.length - 1) {
    if (repeat == Repeat.all) {
      await queue.updateCurrentIndex(playQueue[0].index);
      return true;
    }
    return false;
  }
  await queue.updateCurrentIndex(playQueue[index + 1].index);
  return true;
}
