/// How a FORWARD step press (`←` / `→`, double-tap, dial corners) is treated
/// once its target reaches the media tail.
///
/// A tail step cannot land where it asks: the container duration overshoots the
/// last decodable frame and the last key frame sits up to a whole GOP earlier,
/// so a relative `keyframes` seek has no key frame at/after the target and
/// parks the decoder back inside that GOP. mpv solves this in its playloop, not
/// in the seek itself (`player/playloop.c:1240-1243`: "Continuous seeks past
/// EOF => treat as EOF instead of repeating seek"; `1247-1250`: EOF is not
/// decided while a seek is queued). IRIS ports exactly that pair — see
/// `MpvSeekTailState` — instead of converting the press into an absolute
/// `seek <duration>` (which re-queued a seek on every repeat and starved EOF).
///
/// This enum only decides WHEN a press counts as the tail:
///
/// Metadata-only AUX row (`playback.stepTailFinish`, JsonKey-excluded); legacy
/// mode degrades to [StepTailFinishMode.strict] via
/// `resolveStepTailFinishMode`.
enum StepTailFinishMode {
  /// A target that REACHES the media end finishes the item
  /// (`position + step >= duration`) — PotPlayer parity, and the install
  /// default. `target == duration` is as unreachable through a relative
  /// keyframe seek as a target past it, so that press must finish too — see
  /// `stepFinishesItem`.
  strict,

  /// A target that reaches the last reachable moment also finishes it, with a
  /// window of `max(step, kStepTailFinishWindowMs)` — capped at half the media,
  /// so the first press of a very short clip still steps. Covers the
  /// unreachable final GOP: the container duration overshoots the last decodable
  /// frame, so a target that is still short of `duration` can be just as
  /// unreachable as one past it.
  window,
}
