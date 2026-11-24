import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:iris/features/video_transform/model/enum/video_rotation.dart';

part 'video_transform_state.freezed.dart';

/// Per-session picture-adjustment state.
///
/// Deliberately RUNTIME-ONLY: these values are never persisted. A mirror or a
/// rotation is a viewing adjustment for what is on screen now, so carrying it
/// into the next video (let alone the next app launch) would silently flip
/// everything the user opens. The store is reset when the media changes and on
/// app restart.
///
/// Color fields use a symmetric -1..1 range with 0 = neutral so the same number
/// maps cleanly onto both backend scales (mpv's -100..100 VO properties and
/// fvp's -1..1 controller API).
@freezed
abstract class VideoTransformState with _$VideoTransformState {
  const VideoTransformState._();

  const factory VideoTransformState({
    @Default(false) bool flipHorizontal,
    @Default(false) bool flipVertical,
    @Default(VideoRotation.none) VideoRotation rotation,
    @Default(0.0) double brightness,
    @Default(0.0) double contrast,
    @Default(0.0) double saturation,
  }) = _VideoTransformState;

  /// True when any geometric (flip/rotation) transform is active.
  bool get hasOrientation =>
      flipHorizontal || flipVertical || rotation != VideoRotation.none;

  /// True when any color adjustment is active.
  bool get hasColor => brightness != 0 || contrast != 0 || saturation != 0;

  /// True when the picture is untouched (default state).
  bool get isNeutral => !hasOrientation && !hasColor;
}
