import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/playback/mirror_target_policy.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyScenario);

/// Mirrors ANOTHER window's playback context into this window's private playing
/// workspace and starts the neighbour entry there.
///
/// WHY clone the scenario instead of shipping the resolved queue: the effective
/// stream is derived (sources + explicit items + excludes + sort + shuffle seed
/// + virtual-media merge). Copying the definition reproduces it EXACTLY — the
/// receiving window even re-derives merged groups itself — and stays independent
/// of the queue length, unlike serializing every entry into the spawn payload.
///
/// `copyState: true` (the [PlaybackScenarioStore.overrideWorkspace] default)
/// carries the source's current occurrence + ordering hint, so the step below is
/// an O(1) locate instead of a rescan. Temporary excludes are imported too: a
/// temporary exclude is a user-removed queue entry, and dropping it would make
/// the new window's playlist differ from the one the user is looking at.
class ScenarioMirrorActions {
  const ScenarioMirrorActions._();

  /// Returns true when a neighbour was fed. False means "nothing consumed" —
  /// the caller falls back to the generic startup resume.
  static Future<bool> playMirroredNeighbor({
    required String sourceScenarioId,
    int? tagViewId,
    required bool forward,
    int? targetIndex,
    String? targetFileKey,
  }) async {
    final store = usePlaybackScenarioStore();
    final source = await store.getScenario(sourceScenarioId);
    if (source == null) {
      _log.w('mirror: scenario $sourceScenarioId is gone');
      return false;
    }

    final ws = await ensurePlaybackWorkspace();
    await store.overrideWorkspace(
      workspace: ws,
      source: source,
      importPersistentExcludes: true,
      importTemporaryExcludes: true,
    );
    await store.bumpPlaybackVersion();
    // The clone is a snapshot of ANOTHER window's LIVE workspace, not a mirror
    // of a saved scenario: leaving `originScenarioId` on the row would offer
    // "sync back" and let this window overwrite that window's running queue.
    await resetManualScopeOrigin(ws.id);

    // The repeat mode came along with the definition, so the wrap decision
    // matches the source window's (only Repeat.all wraps a step).
    final bool wrap = store.state.activeScenarioRepeat == Repeat.all;

    if (tagViewId != null) {
      if (targetIndex != null) {
        // Explicit target: it is what the source window actually resolved (its
        // live anchor), which the bookmark anchor below can disagree with. The
        // controller validates the shipped file key itself, so a shifted index
        // fails here instead of playing a different entry.
        final entry = await PlaybackProviderRegistry.tagPlay.enterView(
          tagViewId,
          scenarioId: ws.id,
          startIndex: targetIndex,
          startFileKey: targetFileKey,
        );
        _log.i('mirror: tag=$tagViewId target=$targetIndex '
            'entry=${entry?.key ?? '-'}');
        // Deliberately NO bookmark-anchored retry: the source already named the
        // entry in its OSD, and a step from this window's bookmark would play
        // something else (the very mismatch this payload exists to remove).
        return entry != null;
      }
      final entry = await PlaybackProviderRegistry.tagPlay.enterView(
        tagViewId,
        scenarioId: ws.id,
        startStep: forward ? 1 : -1,
        wrap: wrap,
      );
      _log.i('mirror: tag=$tagViewId forward=$forward '
          'entry=${entry?.key ?? '-'}');
      return entry != null;
    }

    final provider = ScenarioPlaybackProvider(store: store);
    if (targetIndex != null) {
      // Same contract: replay the source's decision so the label it showed and
      // the file this window plays are the same entry.
      final entry = await provider.itemAt(targetIndex);
      if (entry == null) {
        _log.w('mirror: target $targetIndex no longer resolves '
            '(scenario=$sourceScenarioId); no neighbour');
        return false;
      }
      if (!neighborTargetMatches(
          expectedKey: targetFileKey, actualKey: entry.key)) {
        _log.w('mirror: index $targetIndex resolves to ${entry.key} but the '
            'source decided $targetFileKey; not playing another entry');
        return false;
      }
      await provider.advanceTo(entry, index: targetIndex);
      _log.i('mirror: fed ${entry.key}#${entry.occurrenceIndex} '
          'target=$targetIndex scenario=$sourceScenarioId');
      return true;
    }
    // Legacy payload (no index): the bookmark-anchored step, unchanged.
    var entry = forward ? await provider.next() : await provider.previous();
    if (entry == null && wrap) {
      entry =
          forward ? await provider.wrapToFirst() : await provider.wrapToLast();
    }
    if (entry == null) {
      _log.w('mirror: no neighbour in scenario $sourceScenarioId '
          '(forward=$forward wrap=$wrap)');
      return false;
    }
    await provider.advanceEntry(entry);
    _log.i('mirror: fed ${entry.key}#${entry.occurrenceIndex} '
        'forward=$forward scenario=$sourceScenarioId');
    return true;
  }
}
