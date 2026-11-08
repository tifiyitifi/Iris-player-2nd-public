import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

/// The scan diffs its freshly listed entries against the stored rows, so the
/// slim projection it reads must agree with the full-row accessor field for
/// field: a missing/mis-decoded field would silently turn every rescan into a
/// full rewrite (or, worse, hide a real change).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late MediaNodesDao dao;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    dao = DbModule.mediaNodesDao;
  });

  tearDownAll(() async {
    await db.close();
  });

  setUp(() async {
    await db.delete(db.mediaNodesTable).go();
  });

  Future<void> seedVideo(String path, {DateTime? modifiedAt}) async {
    final segments = path.split('/');
    await dao.upsertNode(MediaNode.file(
      id: 's:$path',
      storageId: 's',
      path: segments,
      parentPath: segments.length == 1
          ? null
          : segments.sublist(0, segments.length - 1).join('/'),
      pathDepth: segments.length,
      name: segments.last,
      mediaType: MediaType.video,
      sizeInBytes: 4096,
      modifiedAt:
          modifiedAt ?? DateTime.fromMillisecondsSinceEpoch(1700000000123),
      durationMs: 65432,
      width: 1920,
      height: 1080,
    ));
  }

  test('carries every field the diff compares', () async {
    final mtime = DateTime.fromMillisecondsSinceEpoch(1700000000123);
    await seedVideo('Movie/a.mkv', modifiedAt: mtime);
    await dao.upsertNode(MediaNode.directory(
      id: 's:Movie/sub',
      storageId: 's',
      path: const ['Movie', 'sub'],
      parentPath: 'Movie',
      pathDepth: 2,
      name: 'sub',
    ));

    final rows = await dao.listChildrenForScanSync('s', 'Movie');

    expect(rows, hasLength(2));
    final video = rows.firstWhere((r) => r.name == 'a.mkv');
    expect(video.nodeKind, MediaNodeKind.file);
    expect(video.mediaType, MediaType.video);
    expect(video.sizeInBytes, 4096);
    expect(video.modifiedAt, mtime,
        reason: 'sub-second mtime precision must survive');
    expect(video.durationMs, 65432);
    expect(video.width, 1920);
    expect(video.height, 1080);
    expect(video.path, 'Movie/a.mkv');

    final dir = rows.firstWhere((r) => r.name == 'sub');
    expect(dir.nodeKind, MediaNodeKind.directory);
    expect(dir.mediaType, isNull);
    expect(dir.sizeInBytes, isNull);
  });

  test('agrees with getDirectChildren on every shared field', () async {
    await seedVideo('A/x.mp4');
    await seedVideo('A/y.mp4');

    final full = await dao.getDirectChildren('s', 'A');
    final slim = await dao.listChildrenForScanSync('s', 'A');

    expect(slim.length, full.length);
    for (final row in full) {
      final other = slim.firstWhere((r) => r.name == row.name);
      expect(other.path, row.path);
      expect(other.nodeKind, row.nodeKind);
      expect(other.sizeInBytes, row.sizeInBytes);
      expect(other.modifiedAt, row.modifiedAt);
      expect(other.mediaType, row.mediaType);
      expect(other.durationMs, row.durationMs);
      expect(other.width, row.width);
      expect(other.height, row.height);
      expect(other.subtitlesJson, row.subtitlesJson);
    }
  });

  test('the storage root lists its own children, not itself', () async {
    await dao.upsertNode(MediaNode.directory(
      id: 's:',
      storageId: 's',
      path: const [],
      parentPath: null,
      pathDepth: 0,
      name: 's',
    ));
    await seedVideo('top.mp4');

    final rows = await dao.listChildrenForScanSync('s', '');

    expect(rows.map((r) => r.path), ['top.mp4']);
  });

  test('another storage never leaks into the listing', () async {
    await seedVideo('A/x.mp4');
    expect(await dao.listChildrenForScanSync('other', 'A'), isEmpty);
  });
}
