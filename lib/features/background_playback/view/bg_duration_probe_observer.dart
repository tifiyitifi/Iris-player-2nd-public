import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/services/background_duration_probe.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/utils/logger.dart';
import 'package:provider/provider.dart';

final _log = AreaKeyLog(LogKeys.mediaProbe);

/// Membership fingerprint of a probe pass: the queue's media keys, in order.
///
/// A pass publishes its outcome ONLY while the live queue still carries the
/// same fingerprint. A probe is async (platform demux), so the queue can be
/// replaced while it is in flight; publishing the old keys then would flag the
/// NEW queue's rows red/unknown with stale data. The replacement pass (run when
/// the change lands) publishes its own outcome.
String bgProbeQueueFingerprint(List<FileItem> queue) =>
    [for (final f in queue) backgroundMediaKey(f)].join('|');

/// Whether a probe pass started for [passQueue] may still publish its outcome
/// against [liveQueue] (same membership).
bool bgProbeOutcomeStillApplies({
  required List<FileItem> passQueue,
  required List<FileItem> liveQueue,
}) =>
    bgProbeQueueFingerprint(passQueue) == bgProbeQueueFingerprint(liveQueue);

/// Resolves the durations the 副音 queue's virtual timeline needs.
///
/// A queue entry with no `media_nodes` duration used to be read as 0, which
/// collapsed 副音's position onto its head and let the 连续锁步 drift correction
/// drag the video there (「开启副音把播放进度归 0」). This observer makes the
/// duration REAL instead of faking it:
///
/// 1. every entry whose duration the DB does not carry is probed through the
///    platform probe service and written back to `media_nodes`;
/// 2. what still cannot be resolved is published to the store so the queue list
///    flags it (red row + explainer + retry) and the position mapping stands
///    down rather than acting on a fabricated position;
/// 3. the duration the engine reports for the file it just opened is written
///    back immediately — the cheapest probe there is, and the same lazy
///    backfill the foreground hook performs.
///
/// A separate zero-size widget on purpose (same reasoning as
/// `BgQueueSyncObserver`): a probe pass must not rebuild the runtime observer's
/// mirror/alignment effects.
class BgDurationProbeObserver extends HookWidget {
  const BgDurationProbeObserver({super.key});

  @override
  Widget build(BuildContext context) {
    final bg = useBackgroundPlaybackStore();
    final enabled = bg.select(context, (s) => s.enabled);
    final queue = bg.select(context, (s) => s.queue);
    final probeSeq = bg.select(context, (s) => s.bgDurationProbeSeq);
    final engine = context.read<BackgroundPlaybackEngine>();
    // Rebuild on engine snapshots so the live-duration backfill below sees the
    // freshly parsed duration.
    useListenable(engine);

    // A pass is keyed on the queue's membership + an explicit retry request.
    final fingerprint = useMemoized(
      () => '${bgProbeQueueFingerprint(queue)}#$probeSeq',
      [queue, probeSeq],
    );
    final busy = useRef(false);
    final lastHandled = useRef<String?>(null);
    final pending = useRef<List<FileItem>?>(null);
    final runOnce = useRef<void Function()>(() {});
    runOnce.value = () {
      final current = pending.value;
      if (current == null) return;
      if (busy.value) return;
      pending.value = null;
      lastHandled.value = fingerprint;
      busy.value = true;
      unawaited(_probe(current).whenComplete(() {
        busy.value = false;
        // A queue change that landed mid-pass is not lost.
        runOnce.value();
      }));
    };

    useEffect(() {
      if (!enabled || queue.isEmpty) return null;
      if (fingerprint == lastHandled.value) return null;
      pending.value = queue;
      runOnce.value();
      return null;
    }, [fingerprint, enabled, queue]);

    // Live duration backfill for the file the engine just opened: it is already
    // demuxed, so this resolves the one entry that matters most without a probe
    // round trip.
    final lastLiveKey = useRef<String?>(null);
    useEffect(() {
      final f = engine.file;
      final d = engine.duration.inMilliseconds;
      if (f == null || d <= 0) return null;
      final key = backgroundMediaKey(f);
      final stamp = '$key|$d';
      if (lastLiveKey.value == stamp) return null;
      lastLiveKey.value = stamp;
      unawaited(() async {
        final ok = await writeBackBgLiveDuration(
          storageId: f.storageId,
          // The row's canonical path (SAF single picks store their uri there).
          path: backgroundOccurrencePath(f),
          durationMs: d,
        );
        if (!ok) return;
        final store = useBackgroundPlaybackStore();
        if (!store.state.bgDurationFailedKeys.contains(key) &&
            !store.state.bgDurationUnknownKeys.contains(key)) {
          return;
        }
        store.setBgDurationProbeState(
          failed: Set<String>.of(store.state.bgDurationFailedKeys)..remove(key),
          unknown: Set<String>.of(store.state.bgDurationUnknownKeys)
            ..remove(key),
          probing: store.state.bgDurationProbing,
        );
      }());
      return null;
    }, [engine.file, engine.duration]);

    return const SizedBox.shrink();
  }

  /// One probe pass over [queue]; publishes the outcome for the LIVE queue (a
  /// queue replaced meanwhile is dropped — the next pass owns it).
  Future<void> _probe(List<FileItem> queue) async {
    final store = useBackgroundPlaybackStore();
    final keys = <String>{for (final f in queue) backgroundMediaKey(f)};
    store.setBgDurationProbeState(
      failed: store.state.bgDurationFailedKeys.intersection(keys),
      unknown: keys,
      probing: true,
    );
    BgDurationProbeOutcome outcome;
    try {
      outcome = await probeMissingBgDurations(queue);
    } catch (e) {
      _log.w('[bg-duration] probe pass failed: $e');
      outcome = BgDurationProbeOutcome.none;
    }
    // Post-write-back truth: what the timeline will actually read.
    final resolved = await resolvedBgDurationKeys(queue);
    // The queue may have been replaced while the probe was in flight: drop the
    // stale outcome so it cannot overwrite the NEW queue's flags (the
    // replacement pass publishes its own). See [bgProbeOutcomeStillApplies].
    if (!bgProbeOutcomeStillApplies(
      passQueue: queue,
      liveQueue: store.state.queue,
    )) {
      // Keep the LIVE queue's verdicts untouched but never leave the in-flight
      // flag up: the replacement pass will set it again (and an EMPTY live queue
      // has no pass left to clear it).
      store.setBgDurationProbeState(
        failed: store.state.bgDurationFailedKeys,
        unknown: store.state.bgDurationUnknownKeys,
        probing: false,
      );
      _log.d('[bg-duration] stale pass dropped (queue replaced mid-probe)');
      return;
    }
    final unknown = <String>{
      for (final k in keys)
        if (!resolved.contains(k)) k
    };
    final failed = outcome.failedKeys.where(keys.contains).toSet()
      ..removeAll(resolved);
    store.setBgDurationProbeState(
      failed: failed,
      unknown: unknown,
      probing: false,
    );
  }
}
