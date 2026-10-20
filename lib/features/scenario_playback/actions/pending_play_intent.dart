import 'package:flutter/foundation.dart';

/// A play request that was interrupted by an on-demand scan.
///
/// When the scan gate meets a directory that has never been fully scanned, the
/// user may pick 立即完整扫描. The scan runs asynchronously, so the user's
/// intent — "play this" — must survive the gap. This captures that intent and is
/// bound to the scan run THIS action started (see
/// `ensureDirsScannedDetailed`); the resume runs once that run settles.
/// The browse/library surfaces confirm once before resuming; the desktop
/// drag-drop path resumes straight into playback (the drop was already an
/// explicit gesture).
///
/// In-memory only, deliberately: a process restart must not silently resume a
/// playback the user never re-requested, and stale parameters must not be
/// consumed by an unrelated scan after a restart.
///
/// One instance per ACTION, held locally by the caller. An earlier design put
/// every action in one global single-slot holder and read it back when a scan
/// completed. Because the shared scan store is single-flight and a new run
/// resets it, the run that settled first could consume (or clear) another
/// action's intent — the play that triggered the scan was then silently
/// dropped, and only a second drop played. Binding the intent to its own future
/// removes that cross-talk structurally.
@immutable
class PendingPlayIntent {
  const PendingPlayIntent({
    required this.resume,
  });

  /// Replays the interrupted action with the parameters captured at request
  /// time — equivalent to the user clicking it again after the scan.
  final Future<void> Function() resume;
}
