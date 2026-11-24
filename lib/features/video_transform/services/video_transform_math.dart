import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/widgets.dart' show Matrix4;
import 'package:image/image.dart' as img;
import 'package:iris/features/video_transform/model/video_transform_state.dart';

/// Clockwise quarter turns for `RotatedBox`.
///
/// `RotatedBox` is layout-aware (it swaps the child's constraints), so the
/// rotation keeps `BoxFit`, the fvp sizing box and the desktop window fit
/// correct without any manual width/height swap.
int videoTransformQuarterTurns(VideoTransformState state) =>
    state.rotation.quarterTurns;

/// Paint-only mirror matrix. A mirror never changes the child's bounding box,
/// so `Transform` (unlike `RotatedBox`) leaves layout untouched.
Matrix4 videoTransformFlipMatrix(VideoTransformState state) =>
    Matrix4.diagonal3Values(
      state.flipHorizontal ? -1 : 1,
      state.flipVertical ? -1 : 1,
      1,
    );

/// Maps the shared -1..1 color value onto mpv's -100..100 VO property range.
double mediaKitColorValue(double value) => value * 100;

/// Whether a captured frame needs the same geometric transform applied when it
/// is saved (mirror/rotation are paint-level for the live surface, so the raw
/// backend frame does not carry them).
bool videoTransformAffectsCapture(VideoTransformState state) =>
    state.hasOrientation;

/// Isolate job for [applyVideoTransformPngJob].
///
/// `compute` only accepts sendable primitives/collections, so the state is
/// flattened here instead of passing the Freezed object across the boundary.
Map<String, Object?> buildVideoTransformPngJob(
  Uint8List bytes,
  VideoTransformState state,
) =>
    <String, Object?>{
      'bytes': bytes,
      'flipH': state.flipHorizontal,
      'flipV': state.flipVertical,
      'quarterTurns': state.rotation.quarterTurns,
    };

/// Applies the live-surface display transform to PNG bytes.
///
/// Order is fixed to match the widget tree: rotate clockwise first
/// (`RotatedBox`), then mirror (`Transform`). Returns the input untouched when
/// the transform is neutral, and `null` when the bytes cannot be decoded (the
/// caller falls back to the original frame).
Uint8List? applyVideoTransformPngJob(Map<String, Object?> job) {
  final Object? raw = job['bytes'];
  if (raw is! Uint8List || raw.isEmpty) return null;
  final int quarterTurns = (job['quarterTurns'] as int?) ?? 0;
  final bool flipH = (job['flipH'] as bool?) ?? false;
  final bool flipV = (job['flipV'] as bool?) ?? false;
  if (quarterTurns % 4 == 0 && !flipH && !flipV) return raw;

  img.Image? decoded;
  try {
    decoded = img.decodeImage(raw);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;

  img.Image out = decoded;
  final int turns = quarterTurns % 4;
  if (turns != 0) {
    // copyRotate uses clockwise positive angles; 90 == one clockwise turn.
    out = img.copyRotate(out, angle: turns * 90);
  }
  if (flipH) out = img.flipHorizontal(out);
  if (flipV) out = img.flipVertical(out);
  return Uint8List.fromList(img.encodePng(out));
}

/// Builds the capture post-processor from a state SNAPSHOT.
///
/// The caller snapshots the state when the shot is REQUESTED, not when the
/// frame bytes arrive: a rotation/mirror changed while the backend is still
/// grabbing the frame must not be baked into a shot of the previous picture.
/// Returns null when the orientation is neutral — the raw frame is already
/// what the screen shows, so no decode/encode work is needed.
Future<Uint8List?> Function(Uint8List)? buildScreenshotTransform(
  VideoTransformState state,
) {
  if (!videoTransformAffectsCapture(state)) return null;
  return (Uint8List bytes) => compute(
      applyVideoTransformPngJob, buildVideoTransformPngJob(bytes, state));
}
