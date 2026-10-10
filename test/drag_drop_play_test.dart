import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/actions/drag_drop_play_handler.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/warning_dialogs.dart';

/// Builds a local storage entry for matching tests.
Storage _local(String name, List<String> basePath) =>
    Storage.local(type: StorageType.internal, name: name, basePath: basePath);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('classifyDropKind', () {
    test('missing target is ignored', () {
      expect(
        classifyDropKind(exists: false, isDirectory: false),
        DragDropEntryKind.ignored,
      );
    });

    test('directory wins over an extension-like name (Movie.2020)', () {
      expect(
        classifyDropKind(exists: true, isDirectory: true),
        DragDropEntryKind.directory,
      );
    });

    test('non-directory is classified as a file', () {
      expect(
        classifyDropKind(exists: true, isDirectory: false),
        DragDropEntryKind.file,
      );
    });
  });

  group('isPlayableContentType', () {
    test('video and audio are playable', () {
      expect(isPlayableContentType(ContentType.video), isTrue);
      expect(isPlayableContentType(ContentType.audio), isTrue);
    });

    test('image and other are not', () {
      expect(isPlayableContentType(ContentType.image), isFalse);
      expect(isPlayableContentType(ContentType.other), isFalse);
    });
  });

  group('matchDropStorage', () {
    test('matches a Windows drive and yields base-relative segments', () {
      final match = matchDropStorage(
        absoluteSegments: ['D:', 'Movies', 'x.mkv'],
        storages: [_local('Local Disk (D:)', ['D:'])],
      );
      expect(match, isNotNull);
      expect(match!.storage.basePath, ['D:']);
      expect(match.relative, ['Movies', 'x.mkv']);
    });

    test('matching is case-insensitive', () {
      final match = matchDropStorage(
        absoluteSegments: ['d:', 'movies', 'x.mkv'],
        storages: [_local('Local Disk (D:)', ['D:'])],
      );
      expect(match, isNotNull);
      expect(match!.relative, ['movies', 'x.mkv']);
    });

    test('a dropped drive root yields an empty relative path', () {
      final match = matchDropStorage(
        absoluteSegments: ['D:'],
        storages: [_local('Local Disk (D:)', ['D:'])],
      );
      expect(match, isNotNull);
      expect(match!.relative, isEmpty);
    });

    test('the longest base wins (UNC shortcut beats a drive mapping)', () {
      final drive = _local('Local Disk (Z:)', ['Z:']);
      final unc = _local('Share', [r'\\server\share']);
      final match = matchDropStorage(
        absoluteSegments: [r'\\server', 'share', 'Movies', 'x.mkv'],
        storages: [drive, unc],
      );
      expect(match, isNotNull);
      expect(match!.storage.name, 'Share');
      expect(match.relative, ['Movies', 'x.mkv']);
    });

    test('returns null when no storage owns the path', () {
      final match = matchDropStorage(
        absoluteSegments: ['E:', 'Movies'],
        storages: [_local('Local Disk (D:)', ['D:'])],
      );
      expect(match, isNull);
    });
  });

  group('rawStoragePath', () {
    test('prefixes the base and keeps the storage root as the base itself', () {
      final storage = _local('Local Disk (D:)', ['D:']);
      expect(rawStoragePath(storage, ['Movies', 'x.mkv']),
          'D:/Movies/x.mkv');
      expect(rawStoragePath(storage, const []), 'D:');
    });
  });

  group('dedupeDropDirs / dropFilesNotCoveredByDirs', () {
    test('de-duplicates by (storage, path) preserving order', () {
      const a = DragDropResolvedDir(
          storageId: 'st', path: 'Movies', relative: ['Movies']);
      const b = DragDropResolvedDir(
          storageId: 'st', path: 'Movies', relative: ['Movies']);
      const c = DragDropResolvedDir(
          storageId: 'st', path: 'Shows', relative: ['Shows']);
      expect(dedupeDropDirs([a, b, c]), hasLength(2));
    });

    test('drops files covered by a dropped directory subtree', () {
      const dir = DragDropResolvedDir(
          storageId: 'st', path: 'Movies', relative: ['Movies']);
      const covered = DragDropResolvedFile(
        rawPath: '/x/Movies/a.mkv',
        storageId: 'st',
        path: 'D:/Movies/a.mkv',
        relative: ['Movies', 'a.mkv'],
        contentType: ContentType.video,
        size: 0,
        modifiedAt: null,
      );
      const sibling = DragDropResolvedFile(
        rawPath: '/x/Other/b.mp4',
        storageId: 'st',
        path: 'D:/Other/b.mp4',
        relative: ['Other', 'b.mp4'],
        contentType: ContentType.video,
        size: 0,
        modifiedAt: null,
      );
      final kept = dropFilesNotCoveredByDirs(
        files: [covered, sibling],
        dirs: [dir],
      );
      expect(kept, hasLength(1));
      expect(kept.single.relative, ['Other', 'b.mp4']);
    });

    test('a sibling storage never covers a file', () {
      const dir = DragDropResolvedDir(
          storageId: 'other', path: 'Movies', relative: ['Movies']);
      const file = DragDropResolvedFile(
        rawPath: '/x/Movies/a.mkv',
        storageId: 'st',
        path: 'D:/Movies/a.mkv',
        relative: ['Movies', 'a.mkv'],
        contentType: ContentType.video,
        size: 0,
        modifiedAt: null,
      );
      expect(
        dropFilesNotCoveredByDirs(files: [file], dirs: [dir]),
        hasLength(1),
      );
    });

    test('Windows drive-letter paths fold case when deciding coverage', () {
      const dir = DragDropResolvedDir(
          storageId: 'st', path: 'D:/Movies', relative: ['Movies']);
      const file = DragDropResolvedFile(
        rawPath: r'd:\movies\a.mkv',
        storageId: 'st',
        path: 'D:/movies/a.mkv',
        relative: ['movies', 'a.mkv'],
        contentType: ContentType.video,
        size: 0,
        modifiedAt: null,
      );
      expect(
        dropFilesNotCoveredByDirs(files: [file], dirs: [dir]),
        isEmpty,
      );
    });

    test('POSIX paths stay byte-exact: a/A is not coverage', () {
      const dir = DragDropResolvedDir(
          storageId: 'st', path: '/sdcard/a', relative: ['a']);
      const file = DragDropResolvedFile(
        rawPath: '/sdcard/A.mkv',
        storageId: 'st',
        path: '/sdcard/A.mkv',
        relative: ['A.mkv'],
        contentType: ContentType.video,
        size: 0,
        modifiedAt: null,
      );
      expect(
        dropFilesNotCoveredByDirs(files: [file], dirs: [dir]),
        hasLength(1),
      );
    });

    test('Windows de-dupe folds a case-only variant to one row', () {
      const a = DragDropResolvedDir(
          storageId: 'st', path: 'D:/Movies', relative: ['Movies']);
      const b = DragDropResolvedDir(
          storageId: 'st', path: 'D:/movies', relative: ['movies']);
      expect(dedupeDropDirs([a, b]), hasLength(1));
    });

    test('POSIX de-dupe keeps case-only variants distinct', () {
      const a = DragDropResolvedDir(
          storageId: 'st', path: '/sdcard/Movies', relative: ['Movies']);
      const b = DragDropResolvedDir(
          storageId: 'st', path: '/sdcard/movies', relative: ['movies']);
      expect(dedupeDropDirs([a, b]), hasLength(2));
    });
  });

  group('warning registry', () {
    test('exposes the drag-drop scope notice as suppressible/restorable', () {
      expect(kSuppressibleWarningIds, contains(kWarningDragDropScopeRestricted));
    });
  });

  group('evaluateDropScopeRestriction', () {
    late AppDatabase db;
    late MediaNodesDao dao;
    late MediaNodeRepository repo;

    const storageId = 'st-dd';

    Future<void> seedFile(String path, MediaType mediaType) async {
      final segments = path.split('/');
      await dao.insertNode(MediaNode.file(
        id: '$storageId:$path',
        storageId: storageId,
        path: segments,
        parentPath: segments.length == 1
            ? null
            : segments.sublist(0, segments.length - 1).join('/'),
        pathDepth: segments.length,
        name: segments.last,
        mediaType: mediaType,
      ));
    }

    Future<void> seedDir(String path) async {
      final segments = path.split('/');
      await dao.insertNode(MediaNode.directory(
        id: '$storageId:$path',
        storageId: storageId,
        path: segments,
        parentPath: null,
        pathDepth: segments.length,
        name: segments.last,
      ));
    }

    DropDirCount countDir() => (dir, mediaTypes) async {
          final result = await repo.getPagedNodesForSources(
            sources: [
              (
                storageId: dir.storageId,
                path: dir.path.isEmpty ? null : dir.path,
                kind: MediaSourceKind.directory,
                recursive: true,
                scenarioSourceId: null,
              ),
            ],
            nodeKind: MediaNodeKind.file,
            mediaTypes: mediaTypes,
            page: 0,
            pageSize: 1,
          );
          return result.totalItems;
        };

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      dao = MediaNodesDao(db);
      repo = MediaNodeRepository(dao);
      await seedDir('AudOnly');
      await seedFile('AudOnly/a.mp3', MediaType.audio);
      await seedDir('VidOnly');
      await seedFile('VidOnly/v.mp4', MediaType.video);
    });

    tearDown(() => db.close());

    const audOnly = DragDropResolvedDir(
        storageId: storageId, path: 'AudOnly', relative: ['AudOnly']);
    const vidOnly = DragDropResolvedDir(
        storageId: storageId, path: 'VidOnly', relative: ['VidOnly']);

    test('audio-only dir is restricted and survives nothing under videoOnly',
        () async {
      final report = await evaluateDropScopeRestriction(
        files: const [],
        dirs: const [audOnly],
        scope: BrowseMediaScope.videoOnly,
        countDir: countDir(),
      );
      expect(report.restricted, isTrue);
      expect(report.hasScopedMedia, isFalse);
    });

    test('video-only dir is unrestricted and has in-scope media', () async {
      final report = await evaluateDropScopeRestriction(
        files: const [],
        dirs: const [vidOnly],
        scope: BrowseMediaScope.videoOnly,
        countDir: countDir(),
      );
      expect(report.restricted, isFalse);
      expect(report.hasScopedMedia, isTrue);
    });

    test('a mixed dir set is restricted but keeps the in-scope subset',
        () async {
      final report = await evaluateDropScopeRestriction(
        files: const [],
        dirs: const [audOnly, vidOnly],
        scope: BrowseMediaScope.videoOnly,
        countDir: countDir(),
      );
      expect(report.restricted, isTrue);
      expect(report.hasScopedMedia, isTrue);
    });

    test('scope=all is never restricted', () async {
      final report = await evaluateDropScopeRestriction(
        files: const [],
        dirs: const [audOnly, vidOnly],
        scope: BrowseMediaScope.all,
        countDir: countDir(),
      );
      expect(report.restricted, isFalse);
      expect(report.hasScopedMedia, isTrue);
    });

    test('an out-of-scope explicit file is restricted', () async {
      const audio = FileItem(
        storageId: storageId,
        name: 'a.mp3',
        uri: '/x/a.mp3',
        path: ['x', 'a.mp3'],
        type: ContentType.audio,
      );
      final report = await evaluateDropScopeRestriction(
        files: const [audio],
        dirs: const [],
        scope: BrowseMediaScope.videoOnly,
        countDir: countDir(),
      );
      expect(report.restricted, isTrue);
      expect(report.hasScopedMedia, isFalse);
    });
  });
}
