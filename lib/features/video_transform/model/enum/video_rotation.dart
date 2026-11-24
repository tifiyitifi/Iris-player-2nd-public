/// Clockwise display rotation steps.
///
/// Only quarter turns are supported: hardware decode without copy-back can
/// only rotate in 90-degree steps, and every backend we drive (Flutter
/// `RotatedBox`, the screenshot post-process) works in quarter turns. The
/// integer is the clockwise turn count, so `quarterTurns * 90` is the angle.
enum VideoRotation {
  none(0),
  cw90(1),
  cw180(2),
  cw270(3);

  const VideoRotation(this.quarterTurns);

  /// Clockwise quarter turns (0..3).
  final int quarterTurns;

  /// Next rotation in the clockwise cycle.
  VideoRotation get next => VideoRotation.values[(index + 1) % values.length];
}
