import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:iris/features/playback_tools/services/screenshot_service.dart';
import 'package:iris/features/video_transform/model/enum/video_rotation.dart';
import 'package:iris/features/video_transform/services/video_transform_math.dart';
import 'package:iris/features/video_transform/store/video_transform_store.dart';

void main() {
  final DateTime now = DateTime(2026, 8, 29, 10, 20, 30);
  final Uint8List bytes =
      Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 1)));

  Future<ScreenshotResult> capture({
    required PngPostProcessor? postProcess,
    required void Function(Uint8List) onWrite,
  }) {
    return captureFrameCore(
      isMediaKit: true,
      frameSource: () async => bytes,
      resolveLocalVideoPath: () => null,
      customDirPath: '',
      defaultDirPath: 'default-shots',
      documentsDirPath: 'docs-root',
      now: now,
      writeBytes: (_, Uint8List written) async => onWrite(written),
      ensureDir: (_) async {},
      notifyGalleryVisible: (_) async {},
      skipPermission: true,
      postProcessPng: postProcess,
    );
  }

  test('captureFrameCore writes the post-processed bytes', () async {
    final Uint8List marker = Uint8List.fromList(<int>[1, 2, 3]);
    Uint8List? written;
    final ScreenshotResult result = await capture(
      postProcess: (Uint8List input) async {
        expect(input, bytes);
        return marker;
      },
      onWrite: (Uint8List b) => written = b,
    );

    expect(result, isA<ScreenshotSuccess>());
    expect(written, marker);
  });

  test('a failing post-processor keeps the original frame', () async {
    Uint8List? written;
    final ScreenshotResult result = await capture(
      postProcess: (_) async => null,
      onWrite: (Uint8List b) => written = b,
    );

    expect(result, isA<ScreenshotSuccess>());
    expect(written, bytes);
  });

  test('the saved frame uses the transform sampled at request time', () async {
    final img.Image src = img.Image(width: 2, height: 2);
    src.setPixelRgb(0, 0, 255, 0, 0); // A red
    src.setPixelRgb(1, 0, 0, 255, 0); // B green
    src.setPixelRgb(0, 1, 0, 0, 255); // C blue
    src.setPixelRgb(1, 1, 255, 255, 255); // D white
    final Uint8List png = Uint8List.fromList(img.encodePng(src));

    // The production call site snapshots the store BEFORE the frame arrives.
    final VideoTransformStore store = VideoTransformStore()
      ..setRotation(VideoRotation.cw90);
    final Future<Uint8List?> Function(Uint8List)? postProcess =
        buildScreenshotTransform(store.state);
    // The user rotates again while the backend is still grabbing the frame.
    store.setRotation(VideoRotation.cw270);
    store.setFlipHorizontal(true);

    Uint8List? written;
    final ScreenshotResult result = await captureFrameCore(
      isMediaKit: true,
      frameSource: () async => png,
      resolveLocalVideoPath: () => null,
      customDirPath: '',
      defaultDirPath: 'default-shots',
      documentsDirPath: 'docs-root',
      now: now,
      writeBytes: (_, Uint8List b) async => written = b,
      ensureDir: (_) async {},
      notifyGalleryVisible: (_) async {},
      skipPermission: true,
      postProcessPng: postProcess,
    );

    expect(result, isA<ScreenshotSuccess>());
    final img.Image out = img.decodeImage(written!)!;
    // CW90 of  A B  is  C A   (C blue lands top-left, A red top-right)
    //           C D      D B
    expect(out.getPixel(0, 0).b, 255);
    expect(out.getPixel(1, 0).r, 255);
  });
}
