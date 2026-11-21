import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:iris/features/scenario_playback/logging/scenario_log_keys.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/utils/logger.dart';

final areaKeyLog = AreaKeyLog(ScenarioLogKeys.playback);

/// Keeps the ACTIVE scenario's current item in step with the Virtual Merge
/// session that is actually playing.
///
/// A merged group's row identity is one physical file (the group's anchor), and
/// a running session never wrote it back: after a tap the scenario kept
/// advertising the row that was TAPPED while the session walked through its own
/// segments and then crossed into sibling groups. The queue highlight, the
/// `[cur/total]` prefix and the ordering hint (`currentVirtualPos`, which the
/// bounded locate reads) therefore drifted from what the player was showing —
/// the merged row stayed highlighted while a different group played.
///
/// **Per GROUP change only.** A segment switch inside a group does not need a
/// write: the segment feed stamps that file's own `lastPlayedAt`/position
/// (`vm-prewrite`), which is exactly what the resume-by-recency contract reads.
/// So persisting per segment would add write pressure with no visible gain.
class VmGroupPositionSync {
  VmGroupPositionSync._();

  static final VmGroupPositionSync instance = VmGroupPositionSync._();

  StreamSubscription<VmPlaybackState>? _sub;

  /// The group whose row identity was last reported, so an unchanged group
  /// (segment ticks, transitioning flags, probes) never re-writes the DB.
  String? _reportedScopeKey;

  /// Subscribes to the VM session store. Idempotent — call once at startup.
  void start() {
    _sub ??= useVmPlaybackStore().stream.listen(_onState);
  }

  @visibleForTesting
  void resetForTest() {
    _sub?.cancel();
    _sub = null;
    _reportedScopeKey = null;
  }

  Future<void> _onState(VmPlaybackState state) async {
    final item = state.item;
    if (item == null) {
      // Session ended: the next start reports again, even for the same group.
      _reportedScopeKey = null;
      return;
    }
    if (item.scopeKey == _reportedScopeKey) return;
    // Book the change BEFORE the await: a second emission for the same group
    // (the session also rewrites state while feeding) must not queue a second
    // write.
    _reportedScopeKey = item.scopeKey;
    // Tag view owns the context: its controller books the session itself.
    if (!PlaybackProviderRegistry.scenarioModeActive ||
        PlaybackProviderRegistry.tagViewDriving) {
      return;
    }
    await _reportGroup(item);
  }

  Future<void> _reportGroup(VirtualMediaItem item) async {
    final store = usePlaybackScenarioStore();
    if (store.state.activeScenarioId == null) return;
    final anchor = item.segments.isEmpty ? null : item.segments.first;
    if (anchor == null) return;
    try {
      // The row's identity IS the group's anchor (see `_groupRowToItem`), so
      // persisting it keeps the queue highlight exact.
      await store.setCurrentItem(
        occurrence: PlaybackOccurrenceId(
          storageId: anchor.storageId,
          path: anchor.path.join('/'),
          occurrenceIndex: anchor.occurrenceIndex,
        ),
      );
      // A newer group may have replaced this one while the write was in flight
      // (rapid taps / advance): its own report must win, so leave the hint to it.
      if (useVmPlaybackStore().state.item?.scopeKey != item.scopeKey) return;
      // Fill the ordering hint + the bar's `[cur/total]` from the SAME bounded
      // locate the queue's auto-scroll uses; a per-group change is a rare event,
      // so the cost is paid once per merged block, not per second.
      await ScenarioPlaybackProvider(store: store).establishCurrentPosition();
      areaKeyLog.d('vm group position reported scope=${item.scopeKey}');
    } catch (e) {
      areaKeyLog.w('vm group position report failed: $e');
    }
  }
}
