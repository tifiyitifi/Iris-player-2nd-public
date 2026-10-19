import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/app_identity/store/use_app_identity_store.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/browser/paged_background_media_data_source.dart';
import 'package:iris/features/paginated_browser/paginated_browser_page.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/utils/get_localizations.dart';

/// Play queue panel of the 副音 playback subsystem.
///
/// 副音 is a second instance of the scenario mechanism, so this surface is the
/// SAME paginated browser the foreground uses — pointed at the background
/// scenario ([PagedBackgroundMediaDataSource]) instead of a bespoke list. The
/// scenario resolves with VM merge OFF, so every row is a real single file.
///
/// Shown from the play-queue button (and the docked side panel) whenever the
/// shared control target is the background engine. It reads ONLY the background
/// + scenario stores — never `Provider<MediaPlayer>` — so opening it from the
/// queue button never touches the foreground runtime.
class BackgroundQueuePanel extends HookWidget {
  const BackgroundQueuePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final bg = useBackgroundPlaybackStore();
    final enabled = bg.select(context, (s) => s.enabled);

    final scenarioStore = usePlaybackScenarioStore();
    // Rebuild whenever the RESOLVED background workspace id could have changed.
    // It is selected as that derived id rather than as `activeScenarioId`: the
    // id also depends on the scenario LIST, and `refreshScenarios()` keeps a
    // still-valid active id, so a workspace created or replaced in this process
    // notified nothing the old subscription could see — and the panel stayed on
    // "queue empty" even though a queue now existed.
    final bgScenarioId = scenarioStore.select(
      context,
      (_) => currentBackgroundWorkspace(scenarioStore)?.id,
    );
    // The per-entry pairing lives on the identity store: switching entries
    // re-resolves the workspace without touching the scenario list.
    useAppIdentityStore().select(context, (s) => s.activeEntryId);

    if (!enabled || bgScenarioId == null) {
      return _PanelCache(
        child: SizedBox(
          width: 320,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              t.bg_queue_empty,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }

    final dataSource = useMemoized(
      () => PagedBackgroundMediaDataSource(scenarioId: bgScenarioId),
      [bgScenarioId],
    );
    useEffect(() => () => dataSource.dispose(), [dataSource]);

    return _PanelCache(
      child: SizedBox(
        width: 320,
        child: PaginatedBrowserPage(
          dataSource: dataSource,
          showHomePage: false,
          showBackButton: false,
          showBreadcrumb: false,
        ),
      ),
    );
  }
}

/// Caches the panel's theme/layout chrome so rebuilding when a store notifies
/// only re-paints the browser body. Panel pops are full-screen routes; this
/// keeps the sheet cheap. (Shared with the dock body, which does not need the
/// player Stack's Positioned contract — this is a normal layout widget.)
class _PanelCache extends StatelessWidget {
  const _PanelCache({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('background_queue_panel_material'),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      child: child,
    );
  }
}
