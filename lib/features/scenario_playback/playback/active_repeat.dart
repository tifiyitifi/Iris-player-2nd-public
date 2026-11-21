import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/store/use_app_store.dart';

/// Pure selector for the repeat mode governing the CURRENT playback mechanism.
///
/// Scenario/tag-driven playback owns its repeat on the active scenario; the
/// legacy queue keeps reading `AppState.repeat`. Virtual Merge completion/wrap
/// must read the SAME source the foreground player hook uses (see
/// `use_media_kit_player.dart`) — reading `AppState.repeat` directly let a
/// lingering legacy value (`Repeat.one`) make the VM hand a segment completion
/// to the outer provider, which then skipped the merged item's remaining
/// segments.
Repeat resolveActiveRepeat({
  required bool scenarioMode,
  required Repeat appRepeat,
  required Repeat scenarioRepeat,
}) =>
    scenarioMode ? scenarioRepeat : appRepeat;

/// [resolveActiveRepeat] against the live stores.
Repeat activePlaybackRepeat() {
  final app = useAppStore().state;
  final scenarioMode =
      !app.useLegacyStoragePersistence && app.useScenarioDrivenPlayback;
  return resolveActiveRepeat(
    scenarioMode: scenarioMode,
    appRepeat: app.repeat,
    scenarioRepeat: usePlaybackScenarioStore().state.activeScenarioRepeat,
  );
}
