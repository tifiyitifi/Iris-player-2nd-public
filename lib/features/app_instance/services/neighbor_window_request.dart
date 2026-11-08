import 'package:collection/collection.dart';
import 'package:iris/features/app_instance/controller/neighbor_target.dart';
import 'package:iris/features/app_instance/model/new_window_request.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/playback/playback_position_signal.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/resolver/tag_view_resolver.dart' show keyOf;
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyScenario);

/// A spawn request plus the display name of the entry it will play (OSD text).
class NeighborWindowTarget {
  const NeighborWindowTarget({required this.request, required this.label});

  final NewWindowRequest request;
  final String label;
}

/// Resolves the previous/next entry of the CURRENT desktop playback context
/// into a "mirror and step" [NewWindowRequest], or null when there is no
/// neighbour (head/tail without Repeat.all, no queue context, …).
///
/// NO PLAYBACK SIDE EFFECTS: it never advances the source queue, never feeds the
/// player and never pauses anything. The caller resolves the neighbour FIRST, so
/// an unsupported build / boundary press leaves the current playback untouched;
/// only a real target leads to parking the player (and a failed spawn restores
/// it). The one write it can make is the source scenario's own position hint —
/// see [_scenarioTarget] — which re-records the SAME item.
///
/// Mode priority mirrors `PlaybackProviderRegistry`:
/// - a tag view owns its own filtered stream (and the scenario's position
///   signal does NOT describe it), so it is checked first;
/// - otherwise the scenario stream is used only while it OWNS the playback
///   context — an external single-file feed (history / open file) has no
///   neighbour, exactly like plain PageUp/PageDown there.
Future<NeighborWindowTarget?> buildNeighborWindowTarget({
  required bool forward,
}) async {
  if (PlaybackProviderRegistry.tagViewDriving) {
    return _tagTarget(forward: forward);
  }
  if (PlaybackProviderRegistry.scenarioModeActive &&
      PlaybackPositionSignal.instance.scenarioOwnsContext.value) {
    return _scenarioTarget(forward: forward);
  }
  return null;
}

/// ROW-ANCHORED variant of [buildNeighborWindowTarget]: the queue row the user
/// right-clicked is the anchor, not the live playback position.
///
/// WHY it exists: the Playing Queue is also a browse surface — the user picks
/// "previous/next in new window" on the row they are LOOKING at, which may be
/// any distance from the playing entry. Only the index arithmetic is shared
/// ([resolveNeighborIndex]); the target's file identity is resolved from the
/// scenario/tag stream this list rendered.
///
/// [tagViewId] must be the tag view the list is showing (null outside a tag
/// view): a tag view is ordered by the tag's own strategy, so stepping in the
/// scenario stream instead would open a file the row did not name.
///
/// NO PLAYBACK SIDE EFFECTS on the source window: nothing is fed, paused or
/// advanced here — the caller only spawns the child.
Future<NeighborWindowTarget?> buildRowNeighborTarget({
  required String scenarioId,
  int? tagViewId,
  required int anchorIndex,
  required int count,
  required bool forward,
  required bool wrap,
}) async {
  final int? target = resolveNeighborIndex(
    index: anchorIndex,
    count: count,
    forward: forward,
    wrap: wrap,
  );
  if (target == null) return null;

  if (tagViewId != null) {
    final snap = PlaybackProviderRegistry.tagPlay.snapshot;
    if (snap == null || target >= snap.length) return null;
    final item = snap.items[target];
    final String key = keyOf(item);
    _log.d('row neighbour(tag=$tagViewId): anchor=$anchorIndex target=$target/'
        '$count forward=$forward key=$key');
    return NeighborWindowTarget(
      request: NewWindowRequest(
        mirrorScenarioId: scenarioId,
        mirrorTagViewId: tagViewId,
        mirrorForward: forward,
        mirrorTargetIndex: target,
        mirrorTargetFileKey: key,
      ),
      label: item.media.name,
    );
  }

  // Only the target page is resolved (bounded, unlike page 0 + pageSize =
  // target, which would materialise the whole prefix of a huge queue).
  const int window = 200;
  final store = usePlaybackScenarioStore();
  final page = await store.resolvePageFor(
    scenarioId,
    page: target ~/ window,
    pageSize: window,
  );
  final EffectivePlaybackItem? item = page.items
      .firstWhereOrNull((e) => e.virtualIndex == target);
  if (item == null) return null;
  final String key = keyOf(item);
  _log.d('row neighbour(scenario=$scenarioId): anchor=$anchorIndex '
      'target=$target/$count forward=$forward key=$key');
  return NeighborWindowTarget(
    request: NewWindowRequest(
      mirrorScenarioId: scenarioId,
      mirrorForward: forward,
      mirrorTargetIndex: target,
      // Same contract as the key-driven variant: the receiver refuses a shifted
      // index instead of playing a different episode behind the row's title.
      mirrorTargetFileKey: key,
    ),
    label: item.media.name,
  );
}

Future<NeighborWindowTarget?> _tagTarget({required bool forward}) async {
  final ctrl = PlaybackProviderRegistry.tagPlay;
  // READ-ONLY discipline: `ensureSnapshot()` / `currentEntry()` both fall back
  // to a RECOVERY that can exit the view and feed the no-tag queue when the
  // view resolves empty. Resolving a neighbour must never touch the source's
  // playback, so take only what is already resolved and report "none" else.
  final snap = ctrl.snapshot;
  final current = ctrl.currentCachedEntry;
  if (snap == null || snap.isEmpty || current == null) return null;

  // `indexOfFileKey` resolves the physical file inside a virtual-merged group
  // (the bookmark identity); `indexOfKey` covers ordinary entries.
  final int? index =
      snap.indexOfFileKey(current.key) ?? snap.indexOfKey(current.key);
  if (index == null) return null;

  final store = usePlaybackScenarioStore();
  final bool wrap = store.state.activeScenarioRepeat == Repeat.all;
  final int? target = resolveNeighborIndex(
    index: index,
    count: snap.length,
    forward: forward,
    wrap: wrap,
  );
  if (target == null) return null;

  final String? scenarioId = store.state.activeScenarioId;
  final int? tagId = useTagPlayStore().state.activeViewTagId;
  if (scenarioId == null || tagId == null) return null;

  // The target entry's OWN file key: the child opens the merged group on it
  // instead of re-deriving the segment from recency.
  final String targetFileKey = keyOf(snap.items[target]);
  _log.d('neighbour(tag): idx=$index target=$target/${snap.length} '
      'forward=$forward wrap=$wrap key=$targetFileKey');
  return NeighborWindowTarget(
    request: NewWindowRequest(
      mirrorScenarioId: scenarioId,
      mirrorTagViewId: tagId,
      mirrorForward: forward,
      mirrorTargetIndex: target,
      mirrorTargetFileKey: targetFileKey,
    ),
    label: snap.items[target].media.name,
  );
}

Future<NeighborWindowTarget?> _scenarioTarget({required bool forward}) async {
  final provider = PlaybackProviderRegistry.scenario;
  var pos = PlaybackPositionSignal.instance.position.value;
  if (pos == null) {
    // The scenario owns the context but has not published its index yet (the
    // locate is still in flight). Re-establishing it is idempotent for the
    // PLAYBACK: it re-locates the CURRENT item and republishes the same
    // position. It does write the source scenario's row (same occurrence, same
    // virtual position, refreshed `lastActiveAt`), so this resolver is not
    // byte-for-byte read-only — it just must never change what is playing.
    await provider.establishCurrentPosition();
    pos = PlaybackPositionSignal.instance.position.value;
  }
  if (pos == null) return null;

  final store = usePlaybackScenarioStore();
  final bool wrap = store.state.activeScenarioRepeat == Repeat.all;
  final int? target = resolveNeighborIndex(
    index: pos.index,
    count: pos.count,
    forward: forward,
    wrap: wrap,
  );
  if (target == null) return null;

  final entry = await provider.itemAt(target);
  if (entry == null) return null;
  final String? scenarioId = store.state.activeScenarioId;
  if (scenarioId == null) return null;

  _log.d('neighbour(scenario): idx=${pos.index} target=$target/${pos.count} '
      'forward=$forward wrap=$wrap key=${entry.key}');
  return NeighborWindowTarget(
    request: NewWindowRequest(
      mirrorScenarioId: scenarioId,
      mirrorForward: forward,
      mirrorTargetIndex: target,
      // The receiver re-derives this stream from the cloned definition; ship
      // the identity so a shifted index is refused instead of playing a
      // different video behind the label this window just showed.
      mirrorTargetFileKey: entry.key,
    ),
    label: entry.file.name,
  );
}
