import 'package:iris/hooks/player/seek_tuning.dart';

/// Per-item "this media was already finished" latch, shared by BOTH player
/// hooks and by both advance doors (the engine's `completed` and a tail press).
///
/// WHY it exists: a tail STEP finishes the item WITHOUT seeking, so playback
/// keeps running to the real end and the engine raises `completed` for a media
/// that was just finished. `finishedDispatchInFlight` only spans the dispatch
/// itself, and the hook keeps the OLD media until the queue rebinds it, so that
/// engine door advanced the queue a SECOND time — the field log `finish now`
/// twice → `wrapToFirst` + `provider.next`, one entry skipped.
///
/// WHY the segment index is part of the key: inside a Virtual-Media session
/// consecutive segments are usually the SAME physical file, so a uri-only latch
/// would cover the NEXT segment too and swallow its `completed` — the session
/// would never advance again. The latch therefore belongs to the item, not to
/// the file.
class TailFinishLatch {
  String? _uri;
  int? _segmentIndex;

  /// The media a tail press finished, or null when no finish is latched.
  String? get uri => _uri;

  bool get isArmed => _uri != null;

  /// Locks the latch onto the item a tail press is finishing.
  ///
  /// [segmentIndex] is the Virtual-Media segment the press ran on, or null
  /// outside a session.
  void arm({required String uri, int? segmentIndex}) {
    _uri = uri;
    _segmentIndex = segmentIndex;
  }

  void clear() {
    _uri = null;
    _segmentIndex = null;
  }

  /// Whether the latch belongs to the item the hook is bound to right now.
  ///
  /// A different file — or a different segment of the same file — is a
  /// different item, so the latch does not apply to it.
  bool covers({required String? uri, int? segmentIndex}) =>
      _uri != null && _uri == uri && _segmentIndex == segmentIndex;

  /// Whether the item this latch holds is the CURRENT one.
  ///
  /// Convenience for the gate: [gateStepPress] wants a plain uri (it compares
  /// it with the bound media), so callers pass `latch.uriFor(...)`.
  String? uriFor({required String? uri, int? segmentIndex}) =>
      covers(uri: uri, segmentIndex: segmentIndex) ? _uri : null;

  /// Releases the latch once the picture demonstrably left that item's tail
  /// again (repeat-one restart, scrub/jump back, VM segment loop) or the item
  /// changed. Returns true when it was cleared.
  ///
  /// [positionMs] / [durationMs] must be on the CALLER axis: the latch is armed
  /// when a tail press judged the merged (virtual) timeline, so releasing it
  /// against the PHYSICAL file's position/duration compared two different
  /// axes — a rewind inside a late segment looked like "left the tail", and a
  /// long source could keep the latch while the item was at its head.
  bool releaseIfSpent({
    required String? uri,
    int? segmentIndex,
    required int positionMs,
    required int durationMs,
  }) {
    if (_uri == null) return false;
    if (!covers(uri: uri, segmentIndex: segmentIndex) ||
        stepTailLatchReusable(reportedMs: positionMs, durationMs: durationMs)) {
      clear();
      return true;
    }
    return false;
  }
}
