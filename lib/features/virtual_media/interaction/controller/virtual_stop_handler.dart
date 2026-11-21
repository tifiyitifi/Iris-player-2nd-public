import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';

/// Stop semantics for virtual merge (§2).
///
/// Single implementation: [VirtualMediaController.stopToFirst] owns clearing
/// virtual progress + anchor + first-segment pre-write + landing on segment 0
/// without auto-play. This handler only routes (never duplicates its writes).
class VirtualStopHandler {
  const VirtualStopHandler();

  Future<void> handleStop() async {
    final ctrl = VirtualMediaController.instance;
    // Inactive: leave the ordinary single-file playback alone. Killing the
    // queue here would stop a normal video the user never merged.
    if (ctrl.state.item == null || !ctrl.isActive) return;
    // Land on first segment without auto-play.
    await ctrl.stopToFirst(clearFirstSegmentProgress: true);
  }
}
