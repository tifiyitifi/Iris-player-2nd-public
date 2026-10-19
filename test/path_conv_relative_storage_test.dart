import 'package:flutter_test/flutter_test.dart';
import 'package:iris/utils/path_conv.dart';

// `relativeToStoragePath` normalises a browser/DB path to the storage-relative
// directory form source/merge rules store.
void main() {
  test('strips a matching local base path', () {
    expect(relativeToStoragePath('E:/yb/sub', ['E:/yb']), 'sub');
  });

  test('a path equal to the base is the storage root (empty)', () {
    expect(relativeToStoragePath('E:/yb', ['E:/yb']), '');
  });

  test('base matching is case-insensitive', () {
    expect(relativeToStoragePath('e:/YB/sub', ['E:/yb']), 'sub');
  });

  test('decodes a SAF tree URI to a readable relative tail', () {
    const base =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload';
    expect(
      relativeToStoragePath(
        'content://com.android.externalstorage.documents/tree/'
        'primary%3ADownload%2FMovies%2FSub',
        [base],
      ),
      'Movies/Sub',
    );
  });

  test('a SAF path equal to the tree base is the storage root', () {
    const base =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload';
    expect(relativeToStoragePath(base, [base]), '');
  });

  test('a SAF descendant keeps the literal tail after the tree prefix', () {
    // Shape produced by the scanner/browser: `[treeUri, 'Movies', ...]`.
    const base =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload';
    expect(relativeToStoragePath('$base/Movies', [base]), 'Movies');
    // A deeper tree id in the base still resolves the tail against the base.
    const inner = '$base%2FMovies';
    expect(relativeToStoragePath('$base/Movies/Sub', [inner]), 'Sub');
  });

  test('a SAF descendant under NO registered base falls back to its tail', () {
    const base =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload';
    expect(
      relativeToStoragePath('$base/Movies/a.mp4', ['E:/yb']),
      'Download/Movies/a.mp4',
    );
  });

  test('falls through unchanged under no registered base', () {
    expect(relativeToStoragePath('other/dir', ['E:/yb']), 'other/dir');
  });

  test('empty input stays empty', () {
    expect(relativeToStoragePath('', ['E:/yb']), '');
  });

  test('overlapping bases take the LONGEST match', () {
    // First-match would strip 'E:/media' and leave 'sub/x'.
    expect(
      relativeToStoragePath('E:/media/sub/x', ['E:/media', 'E:/media/sub']),
      'x',
    );
    expect(
      relativeToStoragePath('E:/media/sub/x', ['E:/media/sub', 'E:/media']),
      'x',
    );
  });

  test('a longer base that does NOT match is ignored', () {
    expect(
      relativeToStoragePath('E:/media/other', ['E:/media', 'E:/media/sub']),
      'other',
    );
  });

  test('a sibling base that only shares a string prefix is NOT stripped', () {
    // 'E:/media' is a string prefix of 'E:/media2' but NOT a path-segment
    // boundary: the path is not under that base and must pass through whole.
    expect(relativeToStoragePath('E:/media2/x', ['E:/media']), 'E:/media2/x');
    expect(relativeToStoragePath('E:/media2', ['E:/media']), 'E:/media2');
  });

  test('boundary-aware longest match picks the real parent', () {
    // The shorter base matches only as a raw string prefix, so the deeper
    // base must win once the boundary rule is enforced.
    expect(
      relativeToStoragePath('E:/media2/x', ['E:/media', 'E:/media2']),
      'x',
    );
  });

  test('overlapping SAF tree bases take the most specific', () {
    const outer =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload';
    const inner = 'content://com.android.externalstorage.documents/tree/'
        'primary%3ADownload%2FMovies';
    const raw = 'content://com.android.externalstorage.documents/tree/'
        'primary%3ADownload%2FMovies%2FSub';
    expect(relativeToStoragePath(raw, [outer, inner]), 'Sub');
    expect(relativeToStoragePath(raw, [inner, outer]), 'Sub');
  });
}
