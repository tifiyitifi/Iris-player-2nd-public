import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/core/fake_cut_background_scope.dart';

/// 副音 stands down for a media only while a cut OWNS the picture.
///
/// A remembered plan is not a playing cut: the EDL can fail to be prepared
/// (temp dir, missing source), the open can be owned by another backend, or a
/// Virtual-Media session can hold the timeline. Suspending 副音 on the plan
/// alone left it silent under an untouched source.
void main() {
  group('fakeCutBlocksBackground', () {
    test('only the file whose open adopted the cut stands down', () {
      expect(fakeCutBlocksBackground('a', 'a'), isTrue);
      expect(fakeCutBlocksBackground('a', null), isFalse,
          reason: 'a remembered plan is not a playing cut');
      expect(fakeCutBlocksBackground('a', 'b'), isFalse,
          reason: 'another file playing a cut says nothing about this one');
    });

    test('no foreground media is never a block', () {
      expect(fakeCutBlocksBackground(null, 'a'), isFalse);
      expect(fakeCutBlocksBackground('', 'a'), isFalse);
    });
  });
}
