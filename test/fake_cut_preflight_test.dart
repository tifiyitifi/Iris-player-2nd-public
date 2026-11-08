import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/core/fake_cut_preflight.dart';
import 'package:iris/models/file.dart';

FakeCutBlockReason evaluate({
  bool mediaKit = true,
  ContentType type = ContentType.video,
  String uri = r'E:\media\movie.mp4',
}) =>
    FakeCutPreflight.evaluate(
      mediaKitBackend: mediaKit,
      contentType: type,
      uri: uri,
    );

void main() {
  group('isLocalFilePath', () {
    test('accepts absolute local paths on both hosts', () {
      expect(FakeCutPreflight.isLocalFilePath(r'E:\media\movie.mp4'), isTrue);
      expect(FakeCutPreflight.isLocalFilePath('E:/media/movie.mp4'), isTrue);
      expect(FakeCutPreflight.isLocalFilePath('/storage/emulated/0/a.mp4'),
          isTrue);
      expect(FakeCutPreflight.isLocalFilePath(r'\\nas\share\a.mp4'), isTrue);
    });

    test('rejects URI schemes, SAF and relative paths', () {
      expect(FakeCutPreflight.isLocalFilePath(''), isFalse);
      expect(FakeCutPreflight.isLocalFilePath('http://host/a.mp4'), isFalse);
      expect(FakeCutPreflight.isLocalFilePath('https://host/a.mp4'), isFalse);
      expect(
          FakeCutPreflight.isLocalFilePath(
              'content://com.android.externalstorage.documents/tree/x'),
          isFalse);
      expect(FakeCutPreflight.isLocalFilePath('media/a.mp4'), isFalse);
    });
  });

  group('evaluate', () {
    test('available for a local video on media_kit', () {
      expect(evaluate(), FakeCutBlockReason.none);
    });

    test('fvp blocks regardless of everything else', () {
      expect(evaluate(mediaKit: false), FakeCutBlockReason.backend);
    });

    test('non-video blocks', () {
      expect(evaluate(type: ContentType.audio), FakeCutBlockReason.notVideo);
    });

    test('remote storage blocks', () {
      expect(evaluate(uri: 'https://dav/a.mp4'),
          FakeCutBlockReason.unsupportedStorage);
      expect(
          evaluate(
              uri: 'content://com.android.externalstorage.documents/tree/x%2Fa.mp4'),
          FakeCutBlockReason.unsupportedStorage);
    });

    test('Virtual Media / 副音 are not block reasons any more', () {
      // The grouping pipeline skips a video with a sibling .llc instead, and
      // 副音 suspends itself for the cut — neither may block the tab.
      expect(
        FakeCutBlockReason.values.map((FakeCutBlockReason r) => r.name),
        <String>['none', 'backend', 'unsupportedStorage', 'notVideo'],
      );
      expect(evaluate(), FakeCutBlockReason.none);
    });

    test('an armed (not playing) 副音 never blocks', () {
      // There is no 副音 input to this decision at all any more: an armed run
      // (`enabled` true with the gate closed) used to read as "in use".
      expect(evaluate(uri: r'E:\media\movie.mp4'), FakeCutBlockReason.none);
    });
  });
}
