import 'package:iris/features/background_playback/controller/background_playback_router.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';

/// One-time startup wiring of the 副音 playback subsystem (called right after
/// [PlaybackProviderRegistry.init] in app_startup):
/// - registers the background router so foreground nav actions retarget while
///   the control target is the background engine.
///
/// The candidate pool is no longer a registered source: it is resolved straight
/// from the background scenario (see `BackgroundScenarioPool`).
abstract final class BackgroundPlaybackBootstrap {
  static bool _done = false;

  static void init() {
    if (_done) return;
    _done = true;
    PlaybackProviderRegistry.registerBackgroundRouter(
      BackgroundPlaybackRouterImpl(),
    );
  }

  /// Test hook.
  static void resetForTests() => _done = false;
}
