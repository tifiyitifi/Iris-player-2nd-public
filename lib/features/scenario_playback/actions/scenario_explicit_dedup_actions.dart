import 'package:flutter/material.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/resolver/explicit_redundancy.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/get_localizations.dart';

/// "Remove redundant additions" cleanup: deletes the scenario's explicit items
/// that a DIRECTORY / whole-storage source already covers (see
/// [redundantExplicitItems]).
///
/// Kept separate from the raw removal paths so every surface (queue page row
/// menu, queue page action, sources page action, sources row menu) shares ONE
/// rule and ONE notification sequence.
abstract final class ScenarioExplicitDedupActions {
  const ScenarioExplicitDedupActions._();

  /// The redundant explicit items of [scenarioId] — no mutation.
  static Future<int> redundantCount(
    PlaybackScenarioStore store,
    String scenarioId,
  ) async {
    final sources = await store.getSources(scenarioId);
    final items = await store.getExplicitItems(scenarioId);
    return redundantExplicitItems(sources: sources, items: items).length;
  }

  /// Deletes every redundant explicit item of [scenarioId]. Returns the number
  /// removed (0 when the scenario had none). Notifies the playback layer ONCE
  /// for the whole batch.
  static Future<int> removeRedundant(
    PlaybackScenarioStore store,
    String scenarioId,
  ) async {
    final sources = await store.getSources(scenarioId);
    final items = await store.getExplicitItems(scenarioId);
    final redundant = redundantExplicitItems(sources: sources, items: items);
    if (redundant.isEmpty) return 0;
    await store.removeExplicitIncludes(redundant.map((e) => e.id));
    // A removed explicit row may have been the playing item.
    if (scenarioId == store.state.activeScenarioId) {
      await ScenarioPlaybackProvider(store: store).revalidateCurrent();
    }
    await store.notifyDefinitionChanged();
    return redundant.length;
  }

  /// UI entry point shared by the queue and sources pages: reports "nothing to
  /// clean up", otherwise confirms the count, removes, then reports the result.
  /// Returns the number removed.
  static Future<int> runWithDialogs(
    BuildContext context, {
    required String scenarioId,
  }) async {
    final store = usePlaybackScenarioStore();
    final count = await redundantCount(store, scenarioId);
    if (!context.mounted) return 0;
    final t = getLocalizations(context);

    if (count == 0) {
      await _info(
        context,
        t.scn_dedupe_explicit_none_title,
        t.scn_dedupe_explicit_none_body,
      );
      return 0;
    }

    final confirmed = await _confirm(context, t, count);
    if (confirmed != true || !context.mounted) return 0;

    final removed = await removeRedundant(store, scenarioId);
    if (!context.mounted) return removed;
    await _info(
      context,
      t.scn_dedupe_explicit_done_title,
      t.scn_dedupe_explicit_done_body(removed),
    );
    return removed;
  }

  static Future<bool?> _confirm(
    BuildContext context,
    AppLocalizations t,
    int count,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.cleaning_services_outlined),
        title: Text(t.scn_dedupe_explicit_confirm_title),
        content: Text(t.scn_dedupe_explicit_confirm_body(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.scn_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.scn_dedupe_explicit_confirm_ok),
          ),
        ],
      ),
    );
  }

  static Future<void> _info(
    BuildContext context,
    String title,
    String body,
  ) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(getLocalizations(ctx).close),
          ),
        ],
      ),
    );
  }
}
