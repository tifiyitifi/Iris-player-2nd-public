import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/rule/vm_title_composer.dart';

void main() {
  test('vmPlayerTitle honours a multi-character separator', () {
    expect(
      vmPlayerTitle(
        dirName: 'D',
        innerIndex: 1,
        innerTotal: 3,
        origName: 'a.mp4',
        separator: ' / ',
      ),
      'D / 1/3 / a.mp4',
    );
  });

  test('vmPlayerTitle falls back to a colon for an empty separator', () {
    expect(
      vmPlayerTitle(
        dirName: 'D',
        innerIndex: 1,
        innerTotal: 3,
        origName: 'a.mp4',
        separator: '',
      ),
      'D:1/3:a.mp4',
    );
  });
}
