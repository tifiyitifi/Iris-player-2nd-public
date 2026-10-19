import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';

/// [MediaNode.occurrencePath] is the single identity form every file
/// occurrence producer/consumer must agree on: the storage-relative path, or —
/// for a SAF single-picked file whose path is empty — its document uri.
void main() {
  test('a normal file uses its storage-relative path', () {
    final node = MediaNode.file(
      id: 's1:Anime/a.mp4',
      storageId: 's1',
      path: const ['Anime', 'a.mp4'],
      name: 'a.mp4',
      mediaType: MediaType.video,
      uri: 'file:///Anime/a.mp4',
    );
    expect(node.occurrencePath, 'Anime/a.mp4');
  });

  test('a SAF single-picked file falls back to its uri', () {
    const safUri =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload/document/primary%3ADownload%2Fsaf.mp4';
    final node = MediaNode.file(
      id: 's1:',
      storageId: 's1',
      path: const [],
      name: 'saf.mp4',
      mediaType: MediaType.video,
      uri: safUri,
    );
    expect(node.occurrencePath, safUri);
  });

  test('an empty-path file with no uri stays empty', () {
    final node = MediaNode.file(
      id: 's1:',
      storageId: 's1',
      path: const [],
      name: 'unknown',
      mediaType: MediaType.unknown,
    );
    expect(node.occurrencePath, '');
  });

  test('a directory uses its path', () {
    final node = MediaNode.directory(
      id: 's1:Anime',
      storageId: 's1',
      path: const ['Anime'],
      name: 'Anime',
    );
    expect(node.occurrencePath, 'Anime');
  });
}
