import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

/// A listing's size/mtime are the WEAKEST metadata: the SAF / WebDAV / FTP
/// lanes cannot stat a file and report 0 / null. Those must never overwrite a
/// value a probe already learned, or the queue's size sort decays on every
/// rescan. Unknown is therefore written as ABSENT, not as 0.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MediaNode file({
    int? sizeInBytes,
    DateTime? modifiedAt,
    String path = 'a.mkv',
  }) =>
      MediaNode.file(
        id: 's:$path',
        storageId: 's',
        path: path.split('/'),
        name: path.split('/').last,
        mediaType: MediaType.video,
        sizeInBytes: sizeInBytes,
        modifiedAt: modifiedAt,
      );

  group('file companion', () {
    test('unknown size (0 / null) is absent', () {
      expect(file(sizeInBytes: 0).toCompanion().sizeInBytes.present, isFalse);
      expect(file().toCompanion().sizeInBytes.present, isFalse);
    });

    test('a known size is written', () {
      final companion = file(sizeInBytes: 4096).toCompanion();
      expect(companion.sizeInBytes.present, isTrue);
      expect(companion.sizeInBytes.value, 4096);
    });

    test('unknown mtime is absent, a known one is written', () {
      expect(file().toCompanion().modifiedAt.present, isFalse);
      final t = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      expect(file(modifiedAt: t).toCompanion().modifiedAt.value, t);
    });
  });

  group('upsert', () {
    late AppDatabase db;

    setUpAll(() async {
      db = AppDatabase(NativeDatabase.memory());
      DbModule.init(db);
    });

    tearDownAll(() => db.close());

    setUp(() async {
      await DbModule.mediaNodesDao
          .deleteNode('s', 'movies/a.mkv');
    });

    test('an unknown size/mtime never erases a known one', () async {
      final t = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      await DbModule.mediaNodesDao.insertNode(file(
        path: 'movies/a.mkv',
        sizeInBytes: 4096,
        modifiedAt: t,
      ));

      // A plain rescan of a lane that cannot stat the file.
      await DbModule.mediaNodesDao.batchUpsert([
        file(path: 'movies/a.mkv', sizeInBytes: 0).toCompanion(),
      ]);

      final node = await DbModule.mediaNodeRepo
          .getNodeByPath(storageId: 's', path: const ['movies', 'a.mkv']);
      final stored = node!.maybeMap(file: (f) => f, orElse: () => null)!;
      expect(stored.sizeInBytes, 4096);
      expect(stored.modifiedAt!.millisecondsSinceEpoch,
          t.millisecondsSinceEpoch);
    });

    test('a known size/mtime replaces the stored value', () async {
      await DbModule.mediaNodesDao.insertNode(file(
        path: 'movies/a.mkv',
        sizeInBytes: 4096,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      ));

      final t2 = DateTime.fromMillisecondsSinceEpoch(1800000000000);
      await DbModule.mediaNodesDao.batchUpsert([
        file(path: 'movies/a.mkv', sizeInBytes: 8192, modifiedAt: t2)
            .toCompanion(),
      ]);

      final node = await DbModule.mediaNodeRepo
          .getNodeByPath(storageId: 's', path: const ['movies', 'a.mkv']);
      final stored = node!.maybeMap(file: (f) => f, orElse: () => null)!;
      expect(stored.sizeInBytes, 8192);
      expect(stored.modifiedAt!.millisecondsSinceEpoch,
          t2.millisecondsSinceEpoch);
    });
  });
}
