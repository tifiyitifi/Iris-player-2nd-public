import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/utils/path_conv.dart';

/// Path-identity regression matrix.
///
/// Every path-keyed operation (physical delete, duplicate-storage merge,
/// occurrence keys) once hand-built its own path and drifted from what the DB
/// stored, so one file could live under several keys or be unaddressable. These
/// cases pin the single normalization layer both paths now share.
void main() {
  group('normalizePathText', () {
    test('repairs the legacy /E:/ drive form', () {
      expect(normalizePathText('/E:/vault/a.mp4'), 'E:/vault/a.mp4');
      expect(normalizePathText('//E:/vault/a.mp4'), 'E:/vault/a.mp4');
    });

    test('converts Windows backslashes', () {
      expect(normalizePathText(r'E:\vault\a.mp4'), 'E:/vault/a.mp4');
      expect(normalizePathText(r'E:\vault\a.mp4\'), 'E:/vault/a.mp4');
    });

    test('collapses duplicated and trailing slashes', () {
      expect(normalizePathText('E://vault///a.mp4//'), 'E:/vault/a.mp4');
      expect(normalizePathText('E:/'), 'E:');
    });

    test('keeps a POSIX root (only a drive letter is repaired)', () {
      expect(normalizePathText('/storage/emulated/0/a.mp4'),
          '/storage/emulated/0/a.mp4');
      expect(normalizePathText('/'), '/');
    });

    test('keeps the UNC head literal', () {
      expect(normalizePathText(r'\\server\share\a.mp4'),
          '//server/share/a.mp4');
      expect(normalizePathText('//server/share//a.mp4'),
          '//server/share/a.mp4');
    });

    test('never touches a SAF content URI', () {
      const saf = 'content://com.android.externalstorage.documents/tree/'
          'primary%3AMovies/Movies/a%20b.mp4';
      expect(normalizePathText(saf), saf);
      expect(normalizePathText('  $saf  '), saf);
    });

    test('sanitizePlayableUri still repairs the player-facing shape', () {
      expect(sanitizePlayableUri('/E:/vault/a.mp4'), 'E:/vault/a.mp4');
      expect(sanitizePlayableUri('E:/vault/a.mp4'), 'E:/vault/a.mp4');
    });
  });

  group('StoragePathCodec.relativeKey with a Windows drive base', () {
    setUp(() {
      StoragePathCodec.baseResolver =
          (id) => id == 'sid' ? const ['E:'] : null;
    });
    tearDown(() => StoragePathCodec.baseResolver = (_) => null);

    test('every spelling of one file folds to one key', () {
      const expected = 'vault/br/a.mp4';
      for (final raw in <String>[
        'E:/vault/br/a.mp4',
        r'E:\vault\br\a.mp4',
        '/E:/vault/br/a.mp4',
        'E://vault//br//a.mp4',
        'vault/br/a.mp4',
        'E:/VAULT/BR/A.MP4', // NTFS: case-insensitive
      ]) {
        expect(StoragePathCodec.relativeKey('sid', raw), expected, reason: raw);
        // The stored relative form keeps the caller's case; only the comparison
        // key folds.
        expect(StoragePathCodec.relativizeRaw('sid', raw).toLowerCase(),
            expected,
            reason: raw);
      }
    });

    test('the relative path round-trips to the domain form', () {
      final relative = StoragePathCodec.relativizeRaw('sid', r'E:\vault\a.mp4');
      expect(StoragePathCodec.absolutize('sid', relative), 'E:/vault/a.mp4');
    });

    test('a sibling path is not mistaken for the base', () {
      // 'vault2' must not be treated as 'vault' by a raw prefix compare.
      expect(StoragePathCodec.relativeKey('sid', 'E:/vault2/a.mp4'),
          'vault2/a.mp4');
    });

    test('an unrelated drive keeps its absolute form', () {
      expect(StoragePathCodec.relativizeRaw('sid', 'F:/vault/a.mp4'),
          'F:/vault/a.mp4');
    });
  });

  group('StoragePathCodec explicit-base helpers', () {
    test('relativeKeyForBase folds only on NTFS-family bases', () {
      expect(StoragePathCodec.relativeKeyForBase(const ['E:'], 'E:/VAULT/a.mp4'),
          'vault/a.mp4');
      expect(
        StoragePathCodec.relativeKeyForBase(
          const ['/storage/emulated/0'],
          '/storage/emulated/0/Movies/A.mp4',
        ),
        'Movies/A.mp4',
      );
    });

    test('UNC bases fold case and keep the share identity', () {
      const base = <String>['//server', 'share'];
      expect(
        StoragePathCodec.relativeKeyForBase(base, r'\\SERVER\Share\A.mp4'),
        'a.mp4',
      );
    });

    test('SAF bases never re-root or fold', () {
      const tree =
          'content://com.android.externalstorage.documents/tree/primary%3AMovies';
      expect(
        StoragePathCodec.relativeKeyForBase(const [tree], '$tree/Movies/A.mp4'),
        '$tree/Movies/A.mp4',
      );
    });
  });
}
