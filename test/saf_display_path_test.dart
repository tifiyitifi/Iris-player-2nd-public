import 'package:flutter_test/flutter_test.dart';
import 'package:iris/utils/path_conv.dart';

void main() {
  test('safDisplayPath tree form', () {
    expect(
      safDisplayPath(
        'content://com.android.externalstorage.documents'
        '/tree/primary%3Aa_all/vision/music',
      ),
      'a_all/vision/music',
    );
    expect(
      safDisplayPath(
        'content://com.android.externalstorage.documents'
        '/tree/primary%3Aa_all',
      ),
      'a_all',
    );
  });

  test('safDisplayPath document form (storage basePath shape)', () {
    expect(
      safDisplayPath(
        'content://com.android.externalstorage.documents'
        '/tree/primary%3Aa_all/document/primary%3Aa_all/vision/music',
      ),
      'a_all/vision/music',
    );
    expect(
      safDisplayPath(
        'content://com.android.externalstorage.documents'
        '/tree/primary%3Aa_all/document/primary%3Aa_all',
      ),
      'a_all',
    );
    // The encoded DOC ID is decoded; literal tail names are not.
    expect(
      safDisplayPath(
        'content://com.android.externalstorage.documents'
        '/tree/primary%3Aa_all/document/primary%3Aa_all%2Fvision',
      ),
      'a_all/vision',
    );
    expect(
      safDisplayPath(
        'content://com.android.externalstorage.documents'
        '/tree/primary%3Aa_all/document/primary%3Aa_all/My%20Movies',
      ),
      'a_all/My%20Movies',
      reason: 'a literal %20 in a real name must not be decoded',
    );
  });

  test('safDisplayPath non-SAF passthrough, displayScanPath local', () {
    expect(safDisplayPath('/storage/emulated/0/x'), '/storage/emulated/0/x');
    expect(displayScanPath('/storage/emulated/0/x'), '/storage/emulated/0/x');
    expect(
      displayScanPath(
        'content://com.android.externalstorage.documents'
        '/tree/primary%3Aa_all/document/primary%3Aa_all/vision',
      ),
      'a_all/vision',
    );
  });

  test('safDirectDocumentUri encodes the WHOLE document id', () {
    const prefix =
        'content://com.android.externalstorage.documents/tree/primary%3Aa_all';
    final docBase = '$prefix/document/primary%3Aa_all';
    // A document URI carries one encoded id — a literal `/vision` tail would be
    // dropped by DocumentFile.fromTreeUri and list the tree root again.
    expect(
      safDirectDocumentUri(safSegmentsOf('$docBase/vision')),
      '$prefix/document/primary%3Aa_all%2Fvision',
    );
    expect(
      safDirectDocumentUri(safSegmentsOf('$docBase/vision/music')),
      '$prefix/document/primary%3Aa_all%2Fvision%2Fmusic',
    );
    // Idempotent on the storage base itself.
    expect(safDirectDocumentUri(safSegmentsOf(docBase)), docBase);
    // An already-encoded id round-trips unchanged.
    expect(
      safDirectDocumentUri(safSegmentsOf('$prefix/document/primary%3Aa_all%2Fvision')),
      '$prefix/document/primary%3Aa_all%2Fvision',
    );
    // Tree-form: normal child resolution (null = not direct).
    expect(safDirectDocumentUri(safSegmentsOf('$prefix/vision')), isNull);
    expect(safDirectDocumentUri(safSegmentsOf(prefix)), isNull);
    // A real folder named `document` whose child is not a doc id stays null.
    expect(
      safDirectDocumentUri(safSegmentsOf('$prefix/document/foo')),
      isNull,
    );
  });
}
