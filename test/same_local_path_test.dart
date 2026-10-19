import 'package:flutter_test/flutter_test.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:path/path.dart' as p;

/// `sameLocalPath` is the identity check behind `getLocalPlayQueue`'s
/// picked-file lookup: the picker's path and the listing's `Directory.list()`
/// path can differ in separator / drive-letter case for the SAME file, and a
/// raw string compare (previously an unguarded `.first`) threw `StateError`
/// when they disagreed.
void main() {
  test('folds separators for the SAME file', () {
    // One side uses the host separator, the other the forward slash: after
    // normalisation they must be equal on every host.
    final hostStyle = 'C:${p.separator}Media${p.separator}Clip.mp4';
    expect(sameLocalPath(hostStyle, 'C:/Media/Clip.mp4'), isTrue);
  });

  test('folds case on a case-insensitive filesystem only', () {
    // Windows drive path: case-insensitive (shape-driven, host-independent).
    expect(sameLocalPath(r'C:\Media\Clip.MP4', r'c:\Media\clip.mp4'), isTrue);
    // POSIX: case-SENSITIVE, so a case-only difference stays distinct.
    expect(sameLocalPath('/sdcard/Clip.MP4', '/sdcard/clip.mp4'), isFalse);
  });

  test('normalizes redundant separators and dot segments', () {
    expect(sameLocalPath('/sdcard/a.mp4', '/sdcard//./a.mp4'), isTrue);
  });

  test('never equates two different files', () {
    expect(sameLocalPath(r'C:\Media\a.mp4', r'C:\Media\b.mp4'), isFalse);
    expect(sameLocalPath('/sdcard/a.mp4', '/sdcard/b.mp4'), isFalse);
  });
}
