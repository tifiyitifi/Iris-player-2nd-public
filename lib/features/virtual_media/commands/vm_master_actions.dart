import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';

/// Applies the global virtual-merge master switch.
///
/// OFF is a SEAMLESS hand-off, never a stop:
/// - the currently playing physical file keeps playing (no player re-open),
/// - the live segment is written back as the current item / tag bookmark,
/// - VM session state drops so the UI shows the plain single-file timeline,
/// - both re-resolution signals bump, so open lists rebuild without groups.
///
/// Individual rules are untouched: pausing only suspends resolution.
Future<void> setVmMasterEnabled({required bool enabled}) async {
  await VmPrefs.setMasterEnabled(enabled);

  final service = VirtualMediaService.instance;
  // Drop the cached rule snapshot BEFORE any re-resolve below: on a disable,
  // `enabledRules()` must already answer "empty" to the snapshot/index
  // rebuild this action triggers.
  service.invalidate();

  final tagDriving = PlaybackProviderRegistry.tagViewDriving;
  final vm = VirtualMediaController.instance;

  if (!enabled && vm.isActive) {
    try {
      if (tagDriving) {
        // Re-resolve the tag snapshot (now without groups) while the session
        // is still live, so its bookmark captures the ACTUAL playing file
        // rather than the merged row's anchor.
        await PlaybackProviderRegistry.tagPlay.revalidate();
      } else if (PlaybackProviderRegistry.scenarioModeActive) {
        // Persist the live physical segment as the scenario's current item so
        // the plain list highlight, next/prev and resume all follow it.
        await PlaybackProviderRegistry.scenario.captureCurrentVirtualSegment();
        await PlaybackProviderRegistry.scenario.establishCurrentPosition();
      }
    } catch (_) {
      // Bookmark/highlight refresh is best-effort; the hand-off below must
      // still drop VM state so playback continues as a plain file.
    } finally {
      // Lightweight deactivation: flush the anchor + drop VM state, but leave
      // the feed, play queue and autoplay untouched — the file keeps playing.
      await vm.deactivateForNavigation();
    }
  } else if (tagDriving) {
    // No live hand-off needed (enable, or already plain): refresh the active
    // tag snapshot so its rows match the new switch state.
    try {
      await PlaybackProviderRegistry.tagPlay.revalidate();
    } catch (_) {
      // Snapshot refresh is best-effort; the lists re-resolve below.
    }
  }

  await service.notifyRulesChanged();
  // Open queue surfaces listen to this revision (playbackVersion alone does
  // not re-fetch them). The persisted index signature includes the enabled
  // rule set, so this refetch rebuilds generations without groups when OFF.
  await usePlaybackScenarioStore().notifyQueueRefetch();
}
