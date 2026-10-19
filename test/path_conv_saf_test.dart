import 'package:flutter_test/flutter_test.dart';
import 'package:iris/utils/path_conv.dart';

/// SAF (Android content://) path-model contract.
///
/// A SAF storage path is `content://<authority>/tree/<encodedTreeId>` +
/// literal relative segments. Segment 0 must stay the WHOLE tree prefix so
/// DB rows / keys / URI rebuilds stay reversible — the scheme must never be
/// split into `['content:', ...]`, collapsed to `content:/`, or prefixed
/// with a leading `/` (which produced the unplayable `/content:/...` form).
void main() {
  const tree = 'content://com.android.externalstorage.documents'
      '/tree/primary%3ADownload';
  const deep = '$tree/Movies/a.mp4';

  test('isSafPath / isSafPathSegments', () {
    expect(isSafPath(tree), isTrue);
    expect(isSafPath(deep), isTrue);
    expect(isSafPath('/storage/emulated/0/x.mp4'), isFalse);
    expect(isSafPath(r'E:\x.mp4'), isFalse);
    expect(isSafPathSegments([tree, 'Movies']), isTrue);
    expect(isSafPathSegments(['storage', 'emulated', '0']), isFalse);
  });

  test('safSegmentsOf keeps tree prefix as segment 0 and splits the rest', () {
    expect(safSegmentsOf(tree), [tree]);
    expect(safSegmentsOf(deep), [tree, 'Movies', 'a.mp4']);
    expect(safSegmentsOf('$tree//a//b.mp4'), [tree, 'a', 'b.mp4']);
  });

  test('safSegmentsOf drops dot/traversal segments', () {
    expect(safSegmentsOf('$tree/../a.mp4'), [tree, 'a.mp4']);
    expect(safSegmentsOf('$tree/./a.mp4'), [tree, 'a.mp4']);
  });

  test('safJoin round-trips segment lists without collapsing scheme', () {
    expect(safJoin([tree, 'Movies', 'a.mp4']), deep);
    expect(safJoin([tree]), tree);
  });

  test('pathConv keeps SAF prefix as one segment', () {
    expect(pathConv(deep), [tree, 'Movies', 'a.mp4']);
    // Legacy POSIX / Windows inputs are untouched.
    expect(pathConv('/storage/emulated/0/x.mp4'),
        ['/', 'storage', 'emulated', '0', 'x.mp4']);
  });

  test('canonicalPath does NOT collapse content:// scheme', () {
    expect(canonicalPath(deep), deep);
    // Non-SAF behavior unchanged.
    expect(canonicalPath('//storage/emulated/0/x.mp4'),
        'storage/emulated/0/x.mp4');
  });

  test('playableUri returns content:// path verbatim (no leading slash)', () {
    expect(playableUri([tree, 'Movies', 'a.mp4']), deep);
    // Non-SAF unchanged.
    expect(playableUri(['storage', 'emulated', '0', 'a.mp4']),
        '/storage/emulated/0/a.mp4');
    expect(playableUri(['E:', 'a.mp4']), 'E:/a.mp4');
  });

  test('nodePlayableUri prefers persisted uri over rebuilt path', () {
    const doc =
        'content://com.android.externalstorage.documents/tree/'
        'primary%3ADownload/document/42';
    expect(nodePlayableUri([tree, 'a.mp4'], uri: doc), doc);
    expect(nodePlayableUri([tree, 'a.mp4'], uri: null), '$tree/a.mp4');
    expect(nodePlayableUri(['storage', 'a.mp4']), '/storage/a.mp4');
  });

  test('canonicalOccurrencePath round-trip keeps scheme', () {
    expect(canonicalOccurrencePath(deep), deep);
  });

  test('safTreeRelativeTo resolves picks to readable relative dirs', () {
    const base =
        'content://com.android.externalstorage.documents/tree/'
        'primary%3ADownload';
    // Pick of the storage root itself → ''.
    expect(safTreeRelativeTo(base, base), '');
    // Pick of a child dir: the tree id encodes the FULL provider path.
    expect(
      safTreeRelativeTo(
        'content://com.android.externalstorage.documents/tree/'
        'primary%3ADownload%2FMovies',
        base,
      ),
      'Movies',
    );
    expect(
      safTreeRelativeTo(
        'content://com.android.externalstorage.documents/tree/'
        'primary%3ADownload%2FMovies%2FSub',
        base,
      ),
      'Movies/Sub',
    );
    // Same authority but a DIFFERENT tree root does not match.
    expect(
      safTreeRelativeTo(
        'content://com.android.externalstorage.documents/tree/'
        'primary%3ADCIM',
        base,
      ),
      isNull,
    );
    // A descendant carrying a LITERAL tail after the tree prefix (the shape
    // the scanner/browser produce: `[treeUri, 'Movies', ...]`) is NOT the base
    // itself — its tail must survive.
    expect(safTreeRelativeTo('$base/Movies', base), 'Movies');
    expect(safTreeRelativeTo('$base/Movies/a.mp4', base), 'Movies/a.mp4');
    // The tail is literal: a `%20` in the actual name must survive intact.
    expect(
      safTreeRelativeTo('$base/My%20Movies/a.mp4', base),
      'My%20Movies/a.mp4',
    );
    // A base deeper than the raw tree prefix still resolves the tail against
    // the BASE's decoded path, not against the raw prefix.
    const inner = '$base%2FMovies';
    expect(safTreeRelativeTo('$base/Movies/Sub', inner), 'Sub');
    // Non-SAF inputs never match.
    expect(safTreeRelativeTo('/storage/emulated/0/Download', base), isNull);
    expect(safTreeRelativeTo(base, r'E:\Movies'), isNull);
    // A URI authority is case-INsensitive (RFC 3986): the same provider spelled
    // with a different authority case is still the same tree.
    expect(
      safTreeRelativeTo(
        'content://COM.Android.ExternalStorage.Documents/tree/'
        'primary%3ADownload/Movies',
        base,
      ),
      'Movies',
    );
  });

  test('safReadableRelative decodes any tree uri to a readable dir tail',
      () {
    // ExternalStorage provider: volume prefix `primary:` is dropped.
    expect(
      safReadableRelative('content://com.android.externalstorage.documents'
          '/tree/primary%3ADownload%2FMovies'),
      'Download/Movies',
    );
    // Storage root itself → its own readable path.
    expect(
      safReadableRelative('content://com.android.externalstorage.documents'
          '/tree/primary%3ADownload'),
      'Download',
    );
    // Other providers (SD card volume ids) work the same way.
    expect(
      safReadableRelative('content://com.android.externalstorage.documents'
          '/tree/ABCD-1234%3ADownload'),
      'Download',
    );
    // A LITERAL tail after the tree prefix is part of the readable path, not
    // something to drop: the prefix match stops at the encoded tree id.
    expect(
      safReadableRelative('content://com.android.externalstorage.documents'
          '/tree/primary%3ADownload/Movies/a.mp4'),
      'Download/Movies/a.mp4',
    );
    // The tail is LITERAL (what the scanner/browser store): `%20` in a real
    // file name must not be decoded, and `%2F` must not add a path level.
    expect(
      safReadableRelative('content://com.android.externalstorage.documents'
          '/tree/primary%3ADownload/My%20Movies/a.mp4'),
      'Download/My%20Movies/a.mp4',
    );
    expect(
      safReadableRelative('content://com.android.externalstorage.documents'
          '/tree/primary%3ADownload/a%2Fb.mp4'),
      'Download/a%2Fb.mp4',
    );
    expect(
      safReadableRelative('content://com.android.externalstorage.documents'
          '/tree/primary%3ADownload/100%/a.mp4'),
      'Download/100%/a.mp4',
    );
    // Non-SAF input → null (callers fall back to the raw trimmed value).
    expect(safReadableRelative('/storage/emulated/0/Download'), isNull);
    expect(safReadableRelative(r'E:\Download'), isNull);
  });

  test('a document uri without /tree/ is preserved verbatim (single pick)', () {
    // ACTION_OPEN_DOCUMENT single picks are `.../document/...`, NOT tree-shaped.
    // Splitting them collapsed `content://` to `content:/` (the v23 defect the
    // writer used to reintroduce); they must round-trip unchanged.
    const doc = 'content://com.android.providers.media.documents'
        '/document/video%3A101';
    expect(safSegmentsOf(doc), <String>[doc]);
    expect(safJoin(safSegmentsOf(doc)), doc);
    expect(canonicalPath(doc), doc);
    expect(canonicalDbPath(doc), doc);
    expect(canonicalOccurrencePath(doc), doc);
    expect(canonicalProgressKey('st1', const [], uri: doc), 'st1:$doc');
    // A tree uri is unaffected.
    expect(canonicalDbPath('$tree/Movies/a.mp4'), '$tree/Movies/a.mp4');
  });

  test('collapsedSafSchemePath yields the legacy key for content:// only', () {
    expect(collapsedSafSchemePath('content://a/b'), 'content:/a/b');
    expect(collapsedSafSchemePath('content:/a/b'), isNull);
    expect(collapsedSafSchemePath('/storage/emulated/0/a.mp4'), isNull);
  });
}
