import 'package:flutter_test/flutter_test.dart';
import 'package:iris/utils/path_conv.dart';

void main() {
  group('playableUri (DB segments -> player-openable uri)', () {
    test('Windows drive-letter paths stay unprefixed', () {
      expect(playableUri(['E:', 'yb', '20260514', 'yinlin6_1080p.mp4']),
          'E:/yb/20260514/yinlin6_1080p.mp4');
      expect(playableUri(['c:', 'Users', 'me', 'a.mkv']),
          'c:/Users/me/a.mkv');
    });

    test('explicit UNC markers stay untouched', () {
      // pathConv keeps a literal '//' marker segment for rooted inputs; a
      // joined '//server/...' form must not gain another prefix.
      expect(playableUri(['//server', 'share', 'x.mp4']),
          '//server/share/x.mp4');
      expect(playableUri([r'\\server\share', 'sub', 'x.mp4']),
          r'\\server\share/sub/x.mp4');
    });

    test('mangled UNC rebuilds as forward-slash UNC', () {
      // '\' is illegal inside NTFS file names, so an inner backslash can only
      // come from a UNC base mangled by canonicalization
      // ('\\server\share' -> 'server\share').
      expect(playableUri([r'server\share', 'sub', 'x.mp4']),
          '//server/share/sub/x.mp4');
      expect(playableUri([r'server\share']), '//server/share');
    });

    test('POSIX absolute paths keep their single leading slash', () {
      // Linux/macOS mounts lose the root in canonicalDbPath; the rebuilt
      // joined form needs exactly one '/'.
      expect(playableUri(['mnt', 'e', 'x.mp4']), '/mnt/e/x.mp4');
      expect(playableUri(['/storage', 'emulated', '0', 'a.mp4']),
          '/storage/emulated/0/a.mp4');
    });

    test('Android relative segments get the rooted prefix', () {
      expect(playableUri(['storage', 'emulated', '0', 'Movies', 'a.mp4']),
          '/storage/emulated/0/Movies/a.mp4');
    });

    test('empty and blank segments are handled gracefully', () {
      expect(playableUri([]), '');
      expect(playableUri(['', 'E:', '', 'a.mp4']), 'E:/a.mp4');
    });
  });

  group('sanitizePlayableUri (hook-level fallback)', () {
    test('strips the bogus slash before Windows drive letters', () {
      expect(sanitizePlayableUri('/E:/yb/20260514/yinlin6_1080p.mp4'),
          'E:/yb/20260514/yinlin6_1080p.mp4');
      expect(sanitizePlayableUri('/c:/a/b.mkv'), 'c:/a/b.mkv');
    });

    test('leaves every other local or remote form untouched', () {
      // Windows separators fold into the canonical forward-slash form (the
      // shape every identity key uses); the file name is unchanged.
      expect(sanitizePlayableUri(r'E:\yb\x.mp4'), 'E:/yb/x.mp4');
      expect(sanitizePlayableUri('E:/yb/x.mp4'), 'E:/yb/x.mp4');
      expect(sanitizePlayableUri('/storage/emulated/0/Movies/a.mp4'),
          '/storage/emulated/0/Movies/a.mp4');
      expect(sanitizePlayableUri('https://host/dav/a.mp4'),
          'https://host/dav/a.mp4');
      expect(sanitizePlayableUri('ftp://host/a.mp4'), 'ftp://host/a.mp4');
      expect(sanitizePlayableUri('file:///E:/yb/a.mp4'),
          'file:///E:/yb/a.mp4');
      expect(sanitizePlayableUri('content://downloads/document/9'),
          'content://downloads/document/9');
      expect(sanitizePlayableUri('//server/share/a.mp4'),
          '//server/share/a.mp4');
      expect(sanitizePlayableUri(''), '');
    });
  });
}
