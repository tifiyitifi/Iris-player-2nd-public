import 'package:fvp/fvp.dart';
import 'package:iris/features/video_transform/model/video_transform_state.dart';
import 'package:iris/features/video_transform/services/video_transform_math.dart';
import 'package:media_kit/media_kit.dart';
import 'package:video_player/video_player.dart';

/// Applies the color adjustments to the running media_kit/mpv player.
///
/// Uses mpv's own VO properties (`brightness` / `contrast` / `saturation`,
/// range -100..100) rather than rebuilding a `vf` chain: they are smooth while a
/// slider drags and independent of the geometric transform, which Flutter owns.
/// A backend that does not support them keeps its defaults (the call is
/// best-effort, matching `applyMpvSeekTuning`).
Future<void> applyVideoColorToMediaKit(
  Object? platform,
  VideoTransformState state,
) async {
  if (platform is! NativePlayer) return;
  try {
    await platform.setProperty(
      'brightness',
      mediaKitColorValue(state.brightness).toStringAsFixed(2),
    );
    await platform.setProperty(
      'contrast',
      mediaKitColorValue(state.contrast).toStringAsFixed(2),
    );
    await platform.setProperty(
      'saturation',
      mediaKitColorValue(state.saturation).toStringAsFixed(2),
    );
  } catch (_) {
    // A VO without video-equalizer support keeps the picture untouched.
  }
}

/// Applies the color adjustments to the running fvp/mdk controller.
///
/// fvp exposes these as -1..1, the exact range [VideoTransformState] uses, so
/// no rescaling is needed.
void applyVideoColorToFvp(
  VideoPlayerController controller,
  VideoTransformState state,
) {
  if (!controller.value.isInitialized) return;
  try {
    controller
      ..setBrightness(state.brightness)
      ..setContrast(state.contrast)
      ..setSaturation(state.saturation);
  } catch (_) {
    // Best-effort: an unsupported platform keeps the picture untouched.
  }
}
