import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/video_transform/model/enum/video_rotation.dart';
import 'package:iris/features/video_transform/store/video_transform_store.dart';

void main() {
  group('VideoTransformStore', () {
    test('defaults to the untouched picture', () {
      final VideoTransformStore store = VideoTransformStore();
      expect(store.state.isNeutral, isTrue);
      expect(store.state.hasOrientation, isFalse);
      expect(store.state.hasColor, isFalse);
      expect(store.state.rotation, VideoRotation.none);
    });

    test('toggling a mirror flips only its own axis', () {
      final VideoTransformStore store = VideoTransformStore();

      store.toggleFlipHorizontal();
      expect(store.state.flipHorizontal, isTrue);
      expect(store.state.flipVertical, isFalse);
      expect(store.state.hasOrientation, isTrue);

      store.toggleFlipVertical();
      expect(store.state.flipHorizontal, isTrue);
      expect(store.state.flipVertical, isTrue);

      store.setFlipHorizontal(false);
      expect(store.state.flipHorizontal, isFalse);
      expect(store.state.flipVertical, isTrue);
    });

    test('color setters clamp into -1..1 and treat NaN as neutral', () {
      final VideoTransformStore store = VideoTransformStore();

      store.setBrightness(2);
      expect(store.state.brightness, 1);
      store.setBrightness(-3);
      expect(store.state.brightness, -1);
      store.setBrightness(double.nan);
      expect(store.state.brightness, 0);

      store.setContrast(0.25);
      expect(store.state.contrast, 0.25);
      expect(store.state.hasColor, isTrue);
    });

    test('reset clears only the group it names', () {
      final VideoTransformStore store = VideoTransformStore()
        ..toggleFlipHorizontal()
        ..setRotation(VideoRotation.cw90)
        ..setBrightness(0.4)
        ..setSaturation(-0.2);

      store.resetOrientation();
      expect(store.state.flipHorizontal, isFalse);
      expect(store.state.rotation, VideoRotation.none);
      expect(store.state.brightness, 0.4);
      expect(store.state.saturation, -0.2);

      store.setRotation(VideoRotation.cw270);
      store.resetColor();
      expect(store.state.hasColor, isFalse);
      expect(store.state.rotation, VideoRotation.cw270);

      store.resetAll();
      expect(store.state.isNeutral, isTrue);
    });

    test('each per-field reset clears only its own value', () {
      final VideoTransformStore store = VideoTransformStore()
        ..toggleFlipHorizontal()
        ..toggleFlipVertical()
        ..setRotation(VideoRotation.cw180)
        ..setBrightness(0.3)
        ..setContrast(-0.4)
        ..setSaturation(0.5);

      store.resetFlipHorizontal();
      expect(store.state.flipHorizontal, isFalse);
      expect(store.state.flipVertical, isTrue);
      expect(store.state.rotation, VideoRotation.cw180);
      expect(store.state.brightness, 0.3);
      expect(store.state.contrast, -0.4);
      expect(store.state.saturation, 0.5);

      store.resetFlipVertical();
      expect(store.state.flipVertical, isFalse);
      expect(store.state.rotation, VideoRotation.cw180);

      store.resetRotation();
      expect(store.state.rotation, VideoRotation.none);
      expect(store.state.brightness, 0.3);

      store.resetBrightness();
      expect(store.state.brightness, 0);
      expect(store.state.contrast, -0.4);
      expect(store.state.saturation, 0.5);

      store.resetContrast();
      expect(store.state.contrast, 0);
      expect(store.state.saturation, 0.5);

      store.resetSaturation();
      expect(store.state.saturation, 0);
      expect(store.state.isNeutral, isTrue);
    });

    test(
        'media sync keeps the session across a null gap and resets on a change',
        () {
      final VideoTransformStore store = VideoTransformStore();

      store.setFlipHorizontal(true);
      // The first report is not a change: a state set before the surface
      // mounted must survive it.
      store.syncMediaKey('a');
      expect(store.state.flipHorizontal, isTrue);

      // Re-reporting the same key (a surface remount after a backend switch)
      // keeps the adjustment.
      store.syncMediaKey('a');
      expect(store.state.flipHorizontal, isTrue);

      // "Nothing playing" (a stop or a transient queue rebuild) is not a new
      // media; re-opening the SAME file must keep the adjustment.
      store.syncMediaKey(null);
      expect(store.state.flipHorizontal, isTrue);
      store.syncMediaKey('a');
      expect(store.state.flipHorizontal, isTrue);

      // A different real media resets.
      store.syncMediaKey('b');
      expect(store.state.isNeutral, isTrue);

      // A different media after a null gap also resets.
      store.setFlipHorizontal(true);
      store.syncMediaKey(null);
      expect(store.state.flipHorizontal, isTrue);
      store.syncMediaKey('c');
      expect(store.state.isNeutral, isTrue);
    });

    test('rotation cycles clockwise through four steps', () {
      final VideoTransformStore store = VideoTransformStore();

      store.cycleRotation();
      expect(store.state.rotation, VideoRotation.cw90);
      store.cycleRotation();
      expect(store.state.rotation, VideoRotation.cw180);
      store.cycleRotation();
      expect(store.state.rotation, VideoRotation.cw270);
      store.cycleRotation();
      expect(store.state.rotation, VideoRotation.none);
    });
  });
}
