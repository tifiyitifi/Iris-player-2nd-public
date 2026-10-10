/// Step-seek (← / →, phone double-tap) strategy.
///
/// The seek itself stays PRECISE in both modes (`hr-seek=yes` +
/// `hr-seek-framedrop=yes`): a relaxed keyframe seek lands on the keyframe
/// BEFORE the target, so a re-tapped ←/→ re-shows the previous GOP instead of
/// advancing (回跳重播). The two modes differ only in how a RAPID burst is
/// scheduled, never in where a press lands.
enum StepSeekMode {
  /// Original serialized [StepSeekChain]: one precise seek in flight, the next
  /// only after the previous target was observed; the queue is capped at
  /// [kStepChainMaxPending] and drops its OLDEST pending target while a held
  /// key outpaces the painter.
  precise,

  /// Adaptive scheduling, same precise landing per press:
  ///  * the queue is NOT capped — every press is issued in order, so no step is
  ///    swallowed (a held key no longer drops its oldest queued target);
  ///  * the ~90ms landed-frame dwell is applied only when the queue is empty
  ///    (nothing is waiting), so a backlog is pumped as fast as the engine
  ///    observes each landing;
  ///  * the exposed position is held monotonic in the burst direction until the
  ///    newest target lands, so a pre-land raw sample can never read as a
  ///    visible rewind (回退时间).
  adaptive,
}
