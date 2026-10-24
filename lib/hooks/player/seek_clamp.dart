import 'package:iris/utils/seek_tail_guard.dart';

/// Shared millisecond-precision seek clamp for the player hooks.
///
/// Both backends (media_kit, fvp) clamp a user seek target into
/// `[0, totalMs]`. A seconds-based comparison truncates sub-second precision
/// and misses negative sub-second targets entirely
/// (`Duration(-500ms).inSeconds == 0`), so this helper compares
/// [inMilliseconds] on both sides.
///
/// The upper bound is NOT the raw duration: see [SeekIntent] and
/// [kSeekTailGuardMs]. Landing exactly ON `duration` raises `completed`
/// immediately, which is what the "dragging the bar to 100% jumps to the next
/// episode" defect was — the ring dial already avoided it with a 100 ms guard,
/// the shared clamp did not. [SeekIntent.finishAtEnd] is the one case that may
/// still land on the end, and only a scrub release at 100% may ask for it.
Duration clampSeekTarget(
  Duration newPosition,
  Duration total, {
  SeekIntent intent = SeekIntent.stopAtTail,
}) =>
    Duration(
      milliseconds: clampSeekTargetMs(
        newPosition.inMilliseconds,
        total.inMilliseconds,
        intent: intent,
      ),
    );

/// Clamps a position that is being EXPOSED to the UI into `[0, duration]`.
///
/// mpv reports `time-pos` as `last_seek_pts` while a seek is in flight
/// (`player/playloop.c`: `get_current_time()`), and a step seek now hands mpv an
/// unclamped relative delta, so that intermediate sample can sit past the
/// duration. The engine's own sample is left untouched; only the value handed to
/// the widgets (progress bar, time labels) is bounded, so a 60:00 media can never
/// display 64:30.
Duration clampPositionToMedia(Duration position, Duration duration) {
  final int durMs = duration.inMilliseconds;
  if (durMs <= 0) return position;
  final int posMs = position.inMilliseconds;
  if (posMs <= 0) return Duration.zero;
  return posMs > durMs ? duration : position;
}
