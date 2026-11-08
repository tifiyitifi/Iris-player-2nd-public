import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';

/// The ancestor backfill must not re-insert what the walk already created.
///
/// Depth-first order visits a directory's ancestors first, and every visited
/// directory writes its own row, so on a full-volume scan the chain is always
/// already there. Measured on a 34,005-directory phone volume (AOT profile):
/// 221,757 `INSERT OR IGNORE` rows / 44.6 s, every one of them a no-op.
void main() {
  const storageId = 'st1';

  test('a full-volume walk has no ancestor left to create', () {
    // 'a' and 'a/b' were walked before 'a/b/c'.
    final missing = missingAncestorNodes(
      storageId: storageId,
      rel: 'a/b/c',
      visited: {'a', 'a/b', 'a/b/c'},
    );
    expect(missing, isEmpty);
  });

  test('a scan starting mid-tree still creates the chain above it', () {
    // The run started at 'a/b/c', so nothing above it was ever walked.
    final missing = missingAncestorNodes(
      storageId: storageId,
      rel: 'a/b/c',
      visited: {'a/b/c'},
    );
    expect(missing.map((n) => n.path.join('/')), ['a', 'a/b']);
    expect(missing.first.parentPath, isNull);
    expect(missing.first.pathDepth, 1);
    expect(missing.last.parentPath, 'a');
    expect(missing.last.pathDepth, 2);
    expect(missing.last.id, '$storageId:a/b');
  });

  test('only the gaps in the chain are created', () {
    // A resume rebuilt the work list from the queue: the intermediate level is
    // known, the top one is not.
    final missing = missingAncestorNodes(
      storageId: storageId,
      rel: 'a/b/c',
      visited: {'a/b'},
    );
    expect(missing.map((n) => n.path.join('/')), ['a']);
  });

  test('the storage root needs no ancestors', () {
    expect(
      missingAncestorNodes(storageId: storageId, rel: '', visited: const {}),
      isEmpty,
    );
  });
}
