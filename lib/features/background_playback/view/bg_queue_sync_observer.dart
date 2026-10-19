import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/actions/background_playback_actions.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/engine/bg_tag_sync_logic.dart';
import 'package:iris/features/background_playback/model/enum/bg_queue_sync_mode.dart';
import 'package:iris/features/background_playback/services/bg_pool_revision.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.player);

/// Folds candidate changes into a RUNNING 副音 queue.
///
/// A run's queue is a snapshot resolved at start time, so a video tagged into
/// 「副音备选」 (or any tag a source rule reads) never reached the open queue
/// panel on its own. This observer is the consumer of [BgPoolRevision]: it
/// re-resolves and rewrites the live queue according to
/// `BackgroundPlaybackState.queueSyncMode` ([BgQueueSyncMode]).
///
/// It is a separate zero-size widget on purpose. The signal arrives per
/// membership write, and rebuilding the 1147-line [BackgroundRuntimeScope] (the
/// mirror, alignment and scope effects) for a queue append would be a
/// spectacular waste; this widget selects only the three fields it needs, so a
/// reconcile re-renders nothing but itself.
///
/// Everything expensive is decided in [resolveBgTagSyncAction] and in the
/// candidate cache, so the common "nothing relevant changed" case ends here
/// without a resolve, a store write, or a persist.
class BgQueueSyncObserver extends HookWidget {
  const BgQueueSyncObserver({super.key});

  @override
  Widget build(BuildContext context) {
    final bg = useBackgroundPlaybackStore();
    final enabled = bg.select(context, (s) => s.enabled);
    final gateOpen = bg.select(context, (s) => s.gateOpen);
    final mode = bg.select(context, (s) => s.queueSyncMode);
    // Rebuilds on the signal; the effect below reads the live value.
    useListenable(BgPoolRevision.shared.notifier);

    final lastHandled = useRef(BgPoolRevision.shared.revision);
    final busy = useRef(false);
    final runOnce = useRef<void Function()>(() {});
    runOnce.value = () {
      if (busy.value) return;
      final revision = BgPoolRevision.shared.revision;
      if (revision == lastHandled.value) return;
      lastHandled.value = revision;
      final store = useBackgroundPlaybackStore();
      // A run that is off, or stopped by the user gate, keeps its queue: the
      // candidate cache already re-resolved, so the next launch starts from the
      // current sources.
      if (!store.state.enabled || !store.state.gateOpen) return;
      busy.value = true;
      unawaited(
        _reconcile(store.state.queueSyncMode).whenComplete(() {
          busy.value = false;
          // A membership write that landed mid-resolve is not lost.
          runOnce.value();
        }),
      );
    };

    useEffect(() {
      runOnce.value();
      return null;
    }, [BgPoolRevision.shared.revision, enabled, gateOpen, mode]);

    return const SizedBox.shrink();
  }

  /// Folds the freshly resolved pool into the running queue.
  ///
  /// Takes the FULL pool, not the start-filtered candidate list: tagging the
  /// file you are watching right now is the primary gesture behind the 音库
  /// (it becomes the 副音 source for the NEXT foreground), so a filtered
  /// resolve would drop exactly the file the user just tagged. The same-file
  /// guard is applied when a track is SELECTED, not here.
  Future<void> _reconcile(BgQueueSyncMode mode) async {
    final store = useBackgroundPlaybackStore();
    // Centre the fresh page on the file that is PLAYING, not on the scenario's
    // recorded occurrence: a system move (a lock rollover, a tiled entrance)
    // advances `currentIndex` without writing an occurrence, so a page centred
    // on the remembered item would slide the window — and the selection — back
    // to the old track (regression #1, 2026-10-16). The anchor is the playing
    // file's KEY: the numeric index is only valid against the order it was read
    // in, and the pool's own order can have changed under it (shuffle).
    final at = store.state.currentIndex;
    final around = (at < 0 || at >= store.state.queue.length)
        ? null
        : store.state.queueWindowStart + at;
    final current = store.currentFile;
    final window = await BackgroundPlaybackActions.resolveCandidateWindow(
      around: around,
      aroundKey: current == null ? null : backgroundMediaKey(current),
    );
    final candidates = window.files;
    if (candidates.isEmpty) return;
    final action = resolveBgTagSyncAction(
      mode: mode,
      queue: store.state.queue,
      candidates: candidates,
      enabled: store.state.enabled,
      gateOpen: store.state.gateOpen,
      // Mirror the live preference: a shuffled queue may only be compared by
      // membership, or every write would re-shuffle it.
      shuffled: store.state.shuffle,
      // The window's total against the running queue's: a membership change
      // OUTSIDE the resolved page leaves the page identical, and without this
      // the reconcile would answer `none` and leave `queueTotal` stale.
      total: window.total,
      knownTotal: store.state.queueTotal,
    );
    if (action == BgTagSyncAction.none) return;
    _log.i('bg queue sync: $action (${candidates.length} candidates)');
    switch (action) {
      // Both actions reconcile the running WINDOW: rebuild fires on any change,
      // append only when the pool grew. An append-only flat list cannot keep
      // `offset == globalIndex − windowStart` true — the appended entries have
      // no valid offset and fall off the next slide — and materializing the
      // whole (500k-item) stream to keep one would defeat the window design, so
      // the growth folds into the same window rebuild (keeping the playing
      // file).
      case BgTagSyncAction.rebuild:
      case BgTagSyncAction.append:
        await store.replaceQueue(candidates, window: window);
      case BgTagSyncAction.none:
        break;
    }
  }
}
