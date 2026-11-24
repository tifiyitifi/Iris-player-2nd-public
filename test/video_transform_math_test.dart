import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:iris/features/video_transform/model/enum/video_rotation.dart';
import 'package:iris/features/video_transform/model/video_transform_state.dart';
import 'package:iris/features/video_transform/services/video_transform_math.dart';
import 'package:iris/features/video_transform/store/video_transform_store.dart';

img.Image _twoByOne() {
  final img.Image im = img.Image(width: 2, height: 1);
  im.setPixelRgb(0, 0, 255, 0, 0); // red on the left
  im.setPixelRgb(1, 0, 0, 0, 255); // blue on the right
  return im;
}

img.Image _twoByTwo() {
  final img.Image im = img.Image(width: 2, height: 2);
  im.setPixelRgb(0, 0, 255, 0, 0); // A red
  im.setPixelRgb(1, 0, 0, 255, 0); // B green
  im.setPixelRgb(0, 1, 0, 0, 255); // C blue
  im.setPixelRgb(1, 1, 255, 255, 255); // D white
  return im;
}

Uint8List _png(img.Image im) => Uint8List.fromList(img.encodePng(im));
img.Image _decode(Uint8List bytes) => img.decodeImage(bytes)!;

void main() {
  test('quarter turns and color scale map to both backend ranges', () {
    expect(videoTransformQuarterTurns(const VideoTransformState()), 0);
    expect(
      videoTransformQuarterTurns(
          const VideoTransformState(rotation: VideoRotation.cw270)),
      3,
    );
    expect(mediaKitColorValue(0.5), 50);
    expect(mediaKitColorValue(-1), -100);
  });

  test('flip matrix mirrors the requested axes only', () {
    final horizontal =
        videoTransformFlipMatrix(const VideoTransformState(flipHorizontal: true));
    expect(horizontal.storage[0], -1);
    expect(horizontal.storage[5], 1);

    final vertical =
        videoTransformFlipMatrix(const VideoTransformState(flipVertical: true));
    expect(vertical.storage[0], 1);
    expect(vertical.storage[5], -1);

    final both = videoTransformFlipMatrix(
        const VideoTransformState(flipHorizontal: true, flipVertical: true));
    expect(both.storage[0], -1);
    expect(both.storage[5], -1);
  });

  test('capture is affected by orientation but not color', () {
    expect(videoTransformAffectsCapture(const VideoTransformState()), isFalse);
    expect(
      videoTransformAffectsCapture(
          const VideoTransformState(brightness: 0.5)),
      isFalse,
    );
    expect(
      videoTransformAffectsCapture(
          const VideoTransformState(flipHorizontal: true)),
      isTrue,
    );
    expect(
      videoTransformAffectsCapture(
          const VideoTransformState(rotation: VideoRotation.cw90)),
      isTrue,
    );
  });

  test('neutral png job returns the input unchanged', () {
    final Uint8List input = _png(_twoByOne());
    final Uint8List? out = applyVideoTransformPngJob(
      buildVideoTransformPngJob(input, const VideoTransformState()),
    );
    expect(out, same(input));
  });

  test('png job mirrors horizontally', () {
    final Uint8List input = _png(_twoByOne());
    final Uint8List out = applyVideoTransformPngJob(
      buildVideoTransformPngJob(
        input,
        const VideoTransformState(flipHorizontal: true),
      ),
    )!;
    final img.Image im = _decode(out);
    // The red pixel moved to the right edge.
    expect(im.getPixel(0, 0).r, 0);
    expect(im.getPixel(0, 0).b, 255);
    expect(im.getPixel(1, 0).r, 255);
  });

  test('screenshot snapshot is neutral -> no post-processor', () {
    expect(buildScreenshotTransform(const VideoTransformState()), isNull);
    expect(
      buildScreenshotTransform(const VideoTransformState(brightness: 0.5)),
      isNull,
      reason: 'color is not baked into a capture',
    );
  });

  test('screenshot snapshot keeps the state it was built from', () async {
    final VideoTransformStore store = VideoTransformStore()
      ..setRotation(VideoRotation.cw90);
    final Future<Uint8List?> Function(Uint8List)? processor =
        buildScreenshotTransform(store.state);
    expect(processor, isNotNull);

    // The live store can move on while the frame is still being grabbed; the
    // processor must stay on the snapshot it was built from.
    store.setRotation(VideoRotation.cw270);
    store.setFlipHorizontal(true);

    final Uint8List out = (await processor!(_png(_twoByTwo())))!;
    final img.Image im = _decode(out);
    // CW90 of  A B  is  C A
    //           C D      D B
    expect(im.width, 2);
    expect(im.height, 2);
    expect(im.getPixel(0, 0).b, 255); // C blue
    expect(im.getPixel(1, 0).r, 255); // A red
    expect(im.getPixel(0, 1).r, 255); // D white
    expect(im.getPixel(0, 1).g, 255);
    expect(im.getPixel(1, 1).g, 255); // B green
  });

  test('png job rotates clockwise before mirroring', () {
    final Uint8List input = _png(_twoByTwo());
    final Uint8List out = applyVideoTransformPngJob(
      buildVideoTransformPngJob(
        input,
        const VideoTransformState(
          rotation: VideoRotation.cw90,
          flipHorizontal: true,
        ),
      ),
    )!;
    final img.Image im = _decode(out);

    // Rotate CW:   C A      flip H:   A C
    //              D B                B D
    expect(im.width, 2);
    expect(im.height, 2);
    expect(im.getPixel(0, 0).r, 255); // A red
    expect(im.getPixel(0, 0).g, 0);
    expect(im.getPixel(1, 0).b, 255); // C blue
    expect(im.getPixel(0, 1).g, 255); // B green
    expect(im.getPixel(1, 1).r, 255); // D white
    expect(im.getPixel(1, 1).g, 255);
  });
}
