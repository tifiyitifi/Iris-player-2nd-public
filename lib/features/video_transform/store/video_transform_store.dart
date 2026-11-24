import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/video_transform/model/enum/video_rotation.dart';
import 'package:iris/features/video_transform/model/video_transform_state.dart';

/// Session-scoped picture adjustment (mirror / rotation / color).
///
/// A plain [Store] — NOT a `PersistentStore`: the state must not survive a
/// media change or an app restart (see [VideoTransformState]). Setters clamp the
/// color range so a slider can never push a backend out of its own scale.
class VideoTransformStore extends Store<VideoTransformState> {
  VideoTransformStore() : super(const VideoTransformState());

  static const double _kTolerance = 0.0001;

  /// The media the surface last reported, and whether it reported once.
  ///
  /// The tracker lives on the STORE, not in the surface's widget state: a
  /// backend switch remounts the surface, and a widget-local record would be
  /// lost, so a media that changed while unmounted would leak its transform
  /// into the next file (or a same-media remount would reset it). Runtime-only
  /// like the state itself.
  String? _lastMediaKey;
  bool _mediaKeySynced = false;

  /// Reports the media identity the surface is showing and clears the session
  /// when it changes.
  ///
  /// A `null` key means "nothing is playing yet" (a stop, or a transient queue
  /// rebuild) — NOT a new media — so it keeps the session: re-opening the SAME
  /// file through that gap must keep its adjustment. A real key decides:
  ///
  /// - the FIRST real key never resets (a state set before the surface mounted
  ///   must survive it);
  /// - re-reporting the same key (a surface remount after a backend switch)
  ///   keeps the adjustment;
  /// - a different real key resets.
  void syncMediaKey(String? mediaKey) {
    // Ignore "no media": the last real identity stays the comparison point.
    if (mediaKey == null) return;
    if (!_mediaKeySynced) {
      _mediaKeySynced = true;
      _lastMediaKey = mediaKey;
      return;
    }
    if (_lastMediaKey == mediaKey) return;
    _lastMediaKey = mediaKey;
    resetAll();
  }

  /// Drops the media-sync bookkeeping. Tests only: the store is a process-wide
  /// singleton, so a widget test that exercises a media change must start from
  /// "no media reported yet".
  @visibleForTesting
  void forgetMediaKey() {
    _lastMediaKey = null;
    _mediaKeySynced = false;
  }

  void setFlipHorizontal(bool value) {
    if (state.flipHorizontal == value) return;
    set(state.copyWith(flipHorizontal: value));
  }

  void toggleFlipHorizontal() => setFlipHorizontal(!state.flipHorizontal);

  void setFlipVertical(bool value) {
    if (state.flipVertical == value) return;
    set(state.copyWith(flipVertical: value));
  }

  void toggleFlipVertical() => setFlipVertical(!state.flipVertical);

  void setRotation(VideoRotation value) {
    if (state.rotation == value) return;
    set(state.copyWith(rotation: value));
  }

  void cycleRotation() => setRotation(state.rotation.next);

  void setBrightness(double value) {
    final double v = _clampColor(value);
    if ((state.brightness - v).abs() < _kTolerance) return;
    set(state.copyWith(brightness: v));
  }

  void setContrast(double value) {
    final double v = _clampColor(value);
    if ((state.contrast - v).abs() < _kTolerance) return;
    set(state.copyWith(contrast: v));
  }

  void setSaturation(double value) {
    final double v = _clampColor(value);
    if ((state.saturation - v).abs() < _kTolerance) return;
    set(state.copyWith(saturation: v));
  }

  /// Single-field resets. Each delegates to its setter so the clamp and
  /// early-out behaviour is identical to dragging the control.
  void resetFlipHorizontal() => setFlipHorizontal(false);

  void resetFlipVertical() => setFlipVertical(false);

  void resetRotation() => setRotation(VideoRotation.none);

  void resetBrightness() => setBrightness(0);

  void resetContrast() => setContrast(0);

  void resetSaturation() => setSaturation(0);

  /// Clears the geometric transform only (flip + rotation).
  void resetOrientation() {
    set(state.copyWith(
      flipHorizontal: false,
      flipVertical: false,
      rotation: VideoRotation.none,
    ));
  }

  /// Clears the color adjustments only.
  void resetColor() {
    set(state.copyWith(brightness: 0, contrast: 0, saturation: 0));
  }

  /// Restores the untouched picture.
  void resetAll() {
    if (state.isNeutral) return;
    set(const VideoTransformState());
  }

  static double _clampColor(double value) {
    if (value.isNaN) return 0;
    return value.clamp(-1.0, 1.0).toDouble();
  }
}

VideoTransformStore useVideoTransformStore() =>
    create(() => VideoTransformStore());
