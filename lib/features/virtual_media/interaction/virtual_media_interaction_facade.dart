import 'package:flutter/foundation.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';

/// Single entry-point for “single-media intent → hidden list operation”
///
/// Real media pass through unchanged; virtual merge enter the translation
/// layer. The player core never knows the layer exists — it still receives
/// single-file feeds via [VirtualMediaController._feedCurrent].
///
/// Design: Deep module — one facade, powerful implementation. Callers
/// (buttons/gestures/shortcuts/sliders) depend only on this facade, not on
/// individual controllers.
abstract final class VirtualMediaInteractionFacade {
  /// Whether a virtual session is active (PotPlayer mental model: “a single
  /// file being played”, even though it is a hidden playlist).
  static bool get isVirtual =>
      VirtualMediaController.instance.isActive;

  /// Play / pause: real → MediaPlayer directly; virtual → resume first
  /// unwatched segment when never played, otherwise pause/play the current
  /// physical segment.
  static Future<void> handlePlayPause({
    required bool isPlaying,
    required Future<void> Function() realPlay,
    required Future<void> Function() realPause,
  }) async {
    if (!isVirtual) {
      if (isPlaying) {
        await realPause();
      } else {
        await realPlay();
      }
      return;
    }
    // Virtual: play/pause maps directly onto the physical segment.
    if (isPlaying) {
      await realPause();
    } else {
      await realPlay();
    }
  }

  /// Stop: virtual merge clears its own virtual progress (0) and the first
  /// internal segment's persisted progress, then lands on segment 0 without
  /// auto-play. Real media follow the normal stop path.
  ///
  static Future<void> handleStop({
    required Future<void> Function() realStop,
  }) async {
    if (!isVirtual) {
      await realStop();
      return;
    }
    await VirtualMediaController.instance
        .stopToFirst(clearFirstSegmentProgress: true);
  }

  /// Next / Previous across *virtual items* (not inner segments).
  ///
  /// Contract §3: user “next/prev” always crosses virtual bodies. Inner
  /// stepping is reserved for natural completion / chapter clicks, not for the
  /// global next/prev buttons. This preserves the “one file” perception.
  static Future<void> handleNextPrev({
    required bool forward,
    required Future<void> Function() realNextPrev,
    required Future<void> Function(bool forward) virtualCrossItem,
  }) async {
    if (!isVirtual) {
      await realNextPrev();
      return;
    }
    await virtualCrossItem(forward);
  }

  /// Natural completion: current physical segment finished.
  /// Virtual controller consumes it; if it returns false the outer queue
  /// advances past the merged entry.
  static Future<bool> handleCompleted() =>
      VirtualMediaController.instance.maybeHandleCompleted();

  /// Segment open error: skip broken segment, survive session.
  static Future<bool> handleSegmentError() =>
      VirtualMediaController.instance.handleSegmentError();

  /// Debug: dump whether a seek target is virtual-translated.
  @visibleForTesting
  static bool debugIsVirtualActive() => isVirtual;
}
