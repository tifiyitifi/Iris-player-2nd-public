import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/db/storage_scope.dart';

/// Physical delete / repair identity.
///
/// The field failure this pins: the file was moved to the Recycle Bin through
/// the NEW storage entry (`5bb937…`) while its only `media_nodes` row lived
/// under the OLD entry's scope (`7fd08a43…`). `deleteNode` scoped the DELETE by
/// the caller's entry id, matched 0 rows and reported success — the library (and
/// the queue index) kept listing and playing a file that no longer existed.
void main() {
  late AppDatabase db;
  late MediaNodesDao dao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = MediaNodesDao(db);
    StoragePathCodec.baseResolver = (id) => const ['E:'];
    StorageScope.resolver = (id) => id; // independent entries by default
  });

  tearDown(() async {
    StorageScope.reset();
    StoragePathCodec.baseResolver = (_) => null;
    await db.close();
  });

  Future<void> insert({
    required String storageId,
    String name = 'a.mp4',
  }) =>
      dao.insertNode(MediaNode.file(
        id: '$storageId:yb/br/$name',
        storageId: storageId,
        path: ['yb', 'br', name],
        parentPath: 'yb/br',
        pathDepth: 2,
        name: name,
        mediaType: MediaType.video,
      ));

  Future<bool> present(String scopeId) async {
    final rows = await dao.rowsInScope(scopeId);
    return rows.any((r) => r.path == 'yb/br/a.mp4' && r.isPresent);
  }

  test('delete reaches a row owned by a sibling scope', () async {
    await insert(storageId: 'old');

    final removed = await dao.deleteNodeAcrossScopes(
      storageId: 'new',
      scopeIds: const {'new', 'old'},
      rawPath: 'E:/yb/br/a.mp4',
    );

    expect(removed, 1);
    expect(await dao.rowsInScope('old'), isEmpty);
  });

  test('a scope-only delete still misses (regression witness)', () async {
    await insert(storageId: 'old');

    final removed = await dao.deleteNodeAcrossScopes(
      storageId: 'new',
      scopeIds: const {'new'},
      rawPath: 'E:/yb/br/a.mp4',
    );

    expect(removed, 0);
    expect(await present('old'), isTrue);
  });

  test('every caller spelling of the path finds the row', () async {
    await insert(storageId: 'old');
    for (final spelling in <String>[
      r'E:\yb\br\a.mp4',
      '/E:/yb/br/a.mp4',
      'E://yb//br//a.mp4',
      'yb/br/a.mp4',
    ]) {
      final scopes = await dao.scopesContainingPath(
        storageId: 'new',
        candidateScopes: const {'new', 'old'},
        rawPath: spelling,
      );
      expect(scopes, {'old'}, reason: spelling);
    }
  });

  test('scopesContainingPath ignores unrelated scopes', () async {
    await insert(storageId: 'old');
    final scopes = await dao.scopesContainingPath(
      storageId: 'new',
      candidateScopes: const {'new', 'other'},
      rawPath: 'E:/yb/br/a.mp4',
    );
    expect(scopes, isEmpty);
  });

  test('mark absent keeps the row but hides it', () async {
    await insert(storageId: 'old');

    final marked = await dao.markNodeAbsentAcrossScopes(
      storageId: 'new',
      scopeIds: const {'new', 'old'},
      rawPath: '/E:/yb/br/a.mp4',
    );

    expect(marked, 1);
    final rows = await dao.rowsInScope('old');
    expect(rows, hasLength(1));
    expect(rows.single.isPresent, isFalse);
  });

  test('the scope family defaults to the entry itself', () {
    expect(StorageScope.familyOf('a'), {'a'});
  });

  test('a family always contains the entry id', () {
    StorageScope.familyResolver = (_) => {'old'};
    expect(StorageScope.familyOf('new'), {'new', 'old'});
  });

  test('rows of two independent entries can hold the same path', () async {
    await insert(storageId: 'new');
    await insert(storageId: 'old');
    expect(await dao.rowsInScope('new'), hasLength(1));
    expect(await dao.rowsInScope('old'), hasLength(1));

    final removed = await dao.deleteNodeAcrossScopes(
      storageId: 'new',
      scopeIds: const {'new', 'old'},
      rawPath: 'E:/yb/br/a.mp4',
    );
    expect(removed, 2);
  });
}
