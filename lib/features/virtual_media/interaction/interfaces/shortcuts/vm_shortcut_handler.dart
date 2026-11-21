import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';

/// Keyboard / desktop shortcut intents for virtual merge.
abstract final class VmShortcutHandler {
  static Future<void> handleNext() => _cross(true);
  static Future<void> handlePrev() => _cross(false);
  static Future<void> handleStop() => PlaybackProviderRegistry.stop();

  static Future<void> _cross(bool forward) async {
    if (VirtualMediaController.instance.isActive) {
      // Lightweight navigation: keep the queue + autoplay (the next feed
      // overwrites both) and the body's anchor so prev resumes it.
      await VirtualMediaController.instance.deactivateForNavigation();
    }
    await PlaybackProviderRegistry.step(forward: forward);
  }
}
