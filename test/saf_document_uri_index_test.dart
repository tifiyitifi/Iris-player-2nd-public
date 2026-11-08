import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/storages/saf_document_uri_index.dart';

/// SAF descent cost is what makes a phone scan of a `content://` library slow:
/// every `SafUtil().child` call is a full child query of the parent, so scanning
/// a directory at depth `d` used to pay `d` extra queries. The listing that
/// discovered the directory already knows its document URI, so the index turns
/// that into O(1).
void main() {
  const tree =
      'content://com.android.externalstorage.documents/tree/primary%3AMovies';

  group('SafDocumentUriIndex', () {
    test('remembers and looks up a directory by its full path', () {
      final index = SafDocumentUriIndex();
      index.remember(
          const [tree, 'A', 'B'], 'content://doc/primary%3AMovies%2FA%2FB');

      expect(index.lookup(const [tree, 'A', 'B']),
          'content://doc/primary%3AMovies%2FA%2FB');
      expect(index.lookup(const [tree, 'A']), isNull);
      expect(index.length, 1);
    });

    test('clear() drops everything; forget() drops one subtree', () {
      final index = SafDocumentUriIndex();
      index.remember(const [tree, 'A'], 'u1');
      index.remember(const [tree, 'B'], 'u2');

      index.forget(const [tree, 'A']);
      expect(index.lookup(const [tree, 'A']), isNull);
      expect(index.lookup(const [tree, 'B']), 'u2');

      index.clear();
      expect(index.length, 0);
    });

    test('a full index drops its contents instead of growing without bound',
        () {
      final index = SafDocumentUriIndex(maxEntries: 2);
      index.remember(const [tree, 'A'], 'u1');
      index.remember(const [tree, 'B'], 'u2');
      index.remember(const [tree, 'C'], 'u3');

      expect(index.length, 1, reason: 'overflow resets the hint, not the scan');
      expect(index.lookup(const [tree, 'C']), 'u3');
    });
  });

  group('resolveSafContainerUri', () {
    test('a cached directory costs no provider query at all', () async {
      final index = SafDocumentUriIndex();
      index.remember(const [tree, 'A', 'B'], 'cached-uri');
      var calls = 0;

      final uri = await resolveSafContainerUri(
        treeUri: tree,
        relativeSegments: const ['A', 'B'],
        child: (parent, names) async {
          calls++;
          return 'fresh-uri';
        },
        index: index,
      );

      expect(uri, 'cached-uri');
      expect(calls, 0, reason: 'the listing already told us this URI');
    });

    test('a miss resolves the whole chain in ONE provider call', () async {
      final index = SafDocumentUriIndex();
      final calls = <List<String>>[];

      final uri = await resolveSafContainerUri(
        treeUri: tree,
        relativeSegments: const ['A', 'B', 'C'],
        child: (parent, names) async {
          calls.add(names);
          return 'content://doc/C';
        },
        index: index,
      );

      expect(uri, 'content://doc/C');
      expect(calls, [
        const ['A', 'B', 'C']
      ], reason: 'one call, not one per segment');
      expect(index.lookup(const [tree, 'A', 'B', 'C']), 'content://doc/C');
    });

    test('a broken chain returns the nearest existing ancestor', () async {
      final index = SafDocumentUriIndex();
      final calls = <List<String>>[];

      final uri = await resolveSafContainerUri(
        treeUri: tree,
        relativeSegments: const ['A', 'gone', 'C'],
        child: (parent, names) async {
          calls.add(names);
          // The one-shot walk fails as a whole ...
          if (names.length > 1) return null;
          // ... and the per-segment walk stops at the missing level.
          return names.single == 'A' ? 'content://doc/A' : null;
        },
        index: index,
      );

      expect(uri, 'content://doc/A');
      expect(calls.first, const ['A', 'gone', 'C']);
      expect(index.lookup(const [tree, 'A']), 'content://doc/A',
          reason: 'the reached ancestor is worth remembering');
    });

    test('a provider exception degrades to the ancestor walk, never throws',
        () async {
      final uri = await resolveSafContainerUri(
        treeUri: tree,
        relativeSegments: const ['A'],
        child: (parent, names) async => throw StateError('provider gone'),
      );

      expect(uri, tree,
          reason: 'a broken provider must not abort the scan of the storage');
    });

    test('the storage root is served without touching the provider', () async {
      var calls = 0;
      final uri = await resolveSafContainerUri(
        treeUri: tree,
        relativeSegments: const [],
        child: (parent, names) async {
          calls++;
          return null;
        },
      );

      expect(uri, tree);
      expect(calls, 0);
    });
  });
}
