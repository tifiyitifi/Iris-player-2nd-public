import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/paginated_browser/models/browser_toolbar_layout.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/paginated_browser_page.dart';
import 'package:iris/features/scenario_playback/logging/scenario_log_keys.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_queue_layout.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_queue_profile.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/coordinator/scenario_browser.dart';
import 'package:iris/features/scenario_playback/view/queue/paged_scenario_media_data_source.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_theme.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/widgets/popup.dart';

final areaKeyLog = AreaKeyLog(ScenarioLogKeys.queue);

/// Whether the queue page should be painted with the standalone floating-popup
/// theme.
///
/// The docked panel and the floating queue popup are both mounted with
/// `embeddedInStoragesDb: false, modeQueueOverride: true`, so those two flags
/// cannot distinguish them. The docked panel is already wrapped in its own
/// [resolvePlaylistDockTheme] by `_ScenarioDockBody`; painting it with the
/// popup theme instead produced dark-on-black text (the resolved page counter
/// inherited the app theme and vanished). Hence the explicit [dockedPanel].
bool isFloatingQueuePopup({
  required bool embeddedInStoragesDb,
  required bool modeQueueOverride,
  required bool dockedPanel,
}) =>
    !embeddedInStoragesDb && modeQueueOverride && !dockedPanel;

/// Queue sub-interface of the scenario browser.
///
/// Shows the resolved effective media items of the active scenario as a
/// paginated browser. Back and home go to the Playback Scenario tab (in-place
/// when embedded in [StoragesDb], otherwise via popup replacement).
///
/// When [modeQueueOverride] is true (temporary Playing Queue) the back button
/// destroys the page instead of navigating, so the next open rebuilds it fresh.
class ScenarioQueuePage extends HookWidget {
  final PopupDirection direction;
  final void Function(BuildContext context)? onExit;
  final bool embeddedInStoragesDb;
  final bool modeQueueOverride;

  /// True when hosted inside the right-side dock panel, which wraps the page in
  /// its own dock theme; see [isFloatingQueuePopup].
  final bool dockedPanel;

  const ScenarioQueuePage({
    super.key,
    required this.direction,
    this.onExit,
    this.embeddedInStoragesDb = false,
    this.modeQueueOverride = false,
    this.dockedPanel = false,
  });

  @override
  Widget build(BuildContext context) {
    final store = usePlaybackScenarioStore();
    final scenarioId = store.select(context, (s) => s.activeScenarioId);
    final mirror = store.select(context, (s) => s.currentOccurrenceKey);
    // CLOSE_DEBUG_LOG
    areaKeyLog.d(
        'queuePage scenarioId=$scenarioId mirror=$mirror sys=${store.systemPlayingScenario?.id}');

    final dataSource = useMemoized(
      () => PagedScenarioMediaDataSource(
        scenarioId: scenarioId ?? '',
        onBackExit: modeQueueOverride ? () => _close(context) : null,
        queueOverride: modeQueueOverride,
        dockedPanel: dockedPanel,
      ),
      [scenarioId, modeQueueOverride, dockedPanel],
    );
    useEffect(() => () => dataSource.dispose(), [dataSource]);

    if (scenarioId == null) {
      return const SizedBox.shrink();
    }

    // Playlist keyboard model (PotPlayer PL) is metadata-era only.
    final listKeyboard = useAppStore().select(
          context,
          (s) => s.useMetadataSettings,
        ) &&
        MetaSettingsModule.ready;

    // Toolbar layout + breadcrumb visibility. Both are user preferences read
    // here (not from the store) so flipping either restyles the mounted queue
    // without a reopen. Breadcrumb visibility is deliberately layout-INDEPENDENT
    // — the checkbox that drives it lives in the overflow menu of the layouts
    // that HAVE one, and V1 honours the choice without owning a control.
    //
    // The layout and the V3 bar's spot are per SCREEN SHAPE, so which of the
    // three stored values applies is resolved here, once, and every consumer
    // (this page, the data source's toggle button, the settings editor) asks the
    // same resolver — see `scenarioQueueProfileOf`.
    final appStore = useAppStore();
    final profile = scenarioQueueProfileOf(context, state: appStore.state);
    final queueLayout =
        appStore.select(context, (s) => s.scenarioQueueLayoutFor(profile));
    final showBreadcrumb =
        appStore.select(context, (s) => s.scenarioQueueShowBreadcrumb);
    // Follow the playing item when playback switches to another entry. Read
    // here (not in the data source) so flipping it restyles the mounted queue
    // without a reopen.
    final autoLocateOnCurrentChange =
        appStore.select(context, (s) => s.scenarioQueueAutoLocate);
    final compact = queueLayout == ScenarioQueueLayout.v2;
    final floating = queueLayout == ScenarioQueueLayout.v3;
    // Only V2 and V3 have an overflow button to host the checkbox.
    final withOverflow = compact || floating;
    // V3's bar position. Read here so the generic page stays ignorant of the
    // preference, and re-read on every commit so an external change (settings
    // import) is picked up without a reopen.
    final barOffset = floating
        ? appStore.select(context, (s) => s.scenarioQueueBarOffsetFor(profile))
        : null;

    // Floating popup theme (only when not embedded in dock; dock uses its own wrapper theme).
    final isFloatingPopup = isFloatingQueuePopup(
      embeddedInStoragesDb: embeddedInStoragesDb,
      modeQueueOverride: modeQueueOverride,
      dockedPanel: dockedPanel,
    );
    if (isFloatingPopup) {
      final popupThemeSetting = useAppStore().select(context, (s) => s.playlistPopupTheme);
      final appThemeMode = useAppStore().select(context, (s) => s.themeMode);
      final theme = resolvePlaylistPopupTheme(context, popupThemeSetting, appThemeMode: appThemeMode);
      return Theme(
        data: theme,
        child: PaginatedBrowserPage(
          dataSource: dataSource,
          onHomePage: () => goToScenarioTab(context, direction,
              embedded: embeddedInStoragesDb,
              queueOverride: modeQueueOverride),
          onClose: () => _close(context),
          showHomePage: false,
          showBackButton: false,
          goToCurrentInsertIndex: 2,
          listKeyboard: listKeyboard,
          toolbarLayout: _toolbarLayout(queueLayout),
          showBreadcrumb: showBreadcrumb,
          autoLocateOnCurrentChange: autoLocateOnCurrentChange,
          overflowActions: withOverflow
              ? [buildQueueBreadcrumbAction(context)]
              : const [],
          floatingBarOffset: barOffset,
          onFloatingBarMoved: (fraction) => unawaited(
              appStore.updateScenarioQueueBarOffset(profile, fraction)),
        ),
      );
    }

    return PaginatedBrowserPage(
      dataSource: dataSource,
      onHomePage: () => goToScenarioTab(context, direction,
          embedded: embeddedInStoragesDb, queueOverride: modeQueueOverride),
      onClose: () => _close(context),
      showHomePage: false,
      showBackButton: false,
      goToCurrentInsertIndex: 2,
      listKeyboard: listKeyboard,
      toolbarLayout: _toolbarLayout(queueLayout),
      showBreadcrumb: showBreadcrumb,
      autoLocateOnCurrentChange: autoLocateOnCurrentChange,
      overflowActions:
          withOverflow ? [buildQueueBreadcrumbAction(context)] : const [],
      floatingBarOffset: barOffset,
      onFloatingBarMoved: (fraction) => unawaited(
          appStore.updateScenarioQueueBarOffset(profile, fraction)),
    );
  }

  /// Maps the stored queue layout onto the generic page's toolbar enum.
  static BrowserToolbarLayout _toolbarLayout(ScenarioQueueLayout layout) =>
      switch (layout) {
        ScenarioQueueLayout.v1 => BrowserToolbarLayout.responsive,
        ScenarioQueueLayout.v2 => BrowserToolbarLayout.compactSingleLine,
        ScenarioQueueLayout.v3 => BrowserToolbarLayout.floatingGrid,
      };

  void _close(BuildContext context) {
    final exit = onExit;
    if (exit != null) {
      exit(context);
    } else {
      Navigator.of(context).pop();
    }
  }
}

/// The breadcrumb-visibility row of V2's overflow menu.
///
/// It lives on the PAGE rather than the data source because it describes the
/// page's own chrome, and because it is the single control for a preference
/// that BOTH layouts read — V1 has no overflow menu to host it.
PageAction buildQueueBreadcrumbAction(BuildContext context) {
  final appStore = useAppStore();
  final visible = appStore.select(context, (s) => s.scenarioQueueShowBreadcrumb);
  return PageAction(
    icon: const Icon(Icons.account_tree, size: 18),
    label: getLocalizations(context).browser_show_breadcrumb,
    checked: visible,
    onPressed: () => unawaited(
        appStore.updateScenarioQueueShowBreadcrumb(!visible)),
  );
}
