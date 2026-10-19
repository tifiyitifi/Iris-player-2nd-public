import 'package:flutter/material.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/models/player.dart';
import 'package:provider/provider.dart';

/// The physical-file window of the foreground that an align edit targets.
///
/// The align editor persists a mapping against ONE physical file, so it must
/// see that file's own duration and local position — never the merged virtual
/// timeline the player exposes during a Virtual Media session.
///
/// Lives on the Virtual Media side on purpose: undoing the VM virtualization is
/// a VM-interaction concern, and the bg feature's architecture guard forbids it
/// from reaching into the VM controller directly.
class ForegroundWindow {
  const ForegroundWindow({
    required this.durationMs,
    required this.positionMs,
    required this.virtualActive,
    this.virtualOffsetMs = 0,
  });

  /// Duration of the physical file under edit.
  final int durationMs;

  /// Position INSIDE that file (0..[durationMs]).
  final int positionMs;

  final bool virtualActive;

  /// Virtual timeline offset of the current segment (0 when not virtualized).
  final int virtualOffsetMs;

  /// Converts a local (physical) position back to the value the player's
  /// `seek` expects — virtualized during a VM session, raw otherwise.
  int playerPositionFor(int localMs) =>
      virtualActive ? localMs + virtualOffsetMs : localMs;
}

/// Projects the (possibly virtualized) foreground `MediaPlayer` onto the single
/// physical file playing right now.
///
/// During a Virtual Media session the exposed `MediaPlayer.duration` is the
/// whole merged total and `position` is translated onto the virtual axis (see
/// the player hooks' VM virtualization). Undoing that here is what fixes the
/// "超长的合并视频" axis: duration becomes the current segment's own duration,
/// position its local offset (`playerPosition - segmentOffset`).
///
/// Falls back to the raw player values whenever VM is inactive or the current
/// segment has no known duration — the ordinary single-file case is untouched.
ForegroundWindow resolveForegroundWindow({
  required bool virtualActive,
  required int playerDurationMs,
  required int playerPositionMs,
  required int virtualOffsetMs,
  int? segmentDurationMs,
}) {
  if (!virtualActive || segmentDurationMs == null || segmentDurationMs <= 0) {
    return ForegroundWindow(
      durationMs: playerDurationMs < 0 ? 0 : playerDurationMs,
      positionMs: playerPositionMs < 0 ? 0 : playerPositionMs,
      virtualActive: false,
    );
  }
  final int local =
      (playerPositionMs - virtualOffsetMs).clamp(0, segmentDurationMs);
  return ForegroundWindow(
    durationMs: segmentDurationMs,
    positionMs: local,
    virtualActive: true,
    virtualOffsetMs: virtualOffsetMs,
  );
}

/// Imperative variant for call sites that are NOT in a build phase (e.g. an
/// editor's open handler). Reads the Virtual Media controller directly so the
/// bg feature never has to import it.
ForegroundWindow foregroundWindowNow({
  required int playerDurationMs,
  required int playerPositionMs,
}) {
  final vm = VirtualMediaController.instance;
  final bool active = vm.isActive;
  // Null-safe segment read: a poisoned store value (active session with an
  // empty item) must degrade to raw player values, never throw on the UI
  // build path (resolveForegroundWindow already falls back on null).
  return resolveForegroundWindow(
    virtualActive: active,
    playerDurationMs: playerDurationMs,
    playerPositionMs: playerPositionMs,
    virtualOffsetMs: active ? vm.currentOffsetMs : 0,
    segmentDurationMs: active ? vm.currentSegmentOrNull?.durationMs : null,
  );
}

/// Build-phase view of [resolveForegroundWindow] backed by the live player and
/// the Virtual Media controller. Re-runs whenever the player snapshot changes
/// (position ticks), so a VM segment switch is picked up immediately.
ForegroundWindow useForegroundWindow(BuildContext context) {
  final player = context.select<MediaPlayer, ({int posMs, int durMs})>(
    (p) => (posMs: p.position.inMilliseconds, durMs: p.duration.inMilliseconds),
  );
  final vm = VirtualMediaController.instance;
  final bool active = vm.isActive;
  return resolveForegroundWindow(
    virtualActive: active,
    playerDurationMs: player.durMs,
    playerPositionMs: player.posMs,
    virtualOffsetMs: active ? vm.currentOffsetMs : 0,
    segmentDurationMs: active ? vm.currentSegmentOrNull?.durationMs : null,
  );
}

/// DURATION-only build-phase view: identical window semantics but WITHOUT
/// subscribing to the position.
///
/// A surface that renders per-tick positions must keep that subscription in the
/// LEAF that paints them; a whole editor that subscribes here rebuilds its
/// entire tree (panel, dial, button bar) on every playback tick. The live
/// position is then read with [fgPhysicalPositionNow] at event time.
ForegroundWindow useForegroundDuration(BuildContext context) {
  final int durMs =
      context.select<MediaPlayer, int>((p) => p.duration.inMilliseconds);
  final vm = VirtualMediaController.instance;
  final bool active = vm.isActive;
  return resolveForegroundWindow(
    virtualActive: active,
    playerDurationMs: durMs,
    playerPositionMs: 0, // not read here on purpose (see the doc above)
    virtualOffsetMs: active ? vm.currentOffsetMs : 0,
    segmentDurationMs: active ? vm.currentSegmentOrNull?.durationMs : null,
  );
}

/// EVENT-time physical foreground position (VM undone) — safe to call from a
/// handler or a leaf's `Listenable` builder; never subscribes.
int fgPhysicalPositionNow(BuildContext context) {
  final p = context.read<MediaPlayer>();
  return foregroundWindowNow(
    playerDurationMs: p.duration.inMilliseconds,
    playerPositionMs: p.position.inMilliseconds,
  ).positionMs;
}

/// EVENT-time physical foreground DURATION (VM undone) — the duration twin of
/// [fgPhysicalPositionNow].
///
/// Needed by handlers that anchor a 副音 seek on the foreground FILE duration
/// (the 尾部锚定 alignment mode) after a dialog closed, where the build-phase
/// `useForegroundDuration` is not callable and a null duration silently degrades
/// the anchor to 同刻度.
int fgPhysicalDurationNow(BuildContext context) {
  final p = context.read<MediaPlayer>();
  return foregroundWindowNow(
    playerDurationMs: p.duration.inMilliseconds,
    // The duration is the whole answer here; the position is deliberately not
    // read (an event-time caller must not depend on a per-tick sample).
    playerPositionMs: 0,
  ).durationMs;
}
