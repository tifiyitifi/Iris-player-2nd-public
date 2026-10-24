import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_instance/services/new_window_launcher.dart';
import 'package:iris/features/app_instance/services/new_window_requests.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart'
    show SortDirection;
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';

/// The `--open-request` payload is the whole contract between a "play in new
/// window" entry and the spawned process: it must survive Windows command-line
/// quoting (spaces / CJK / `"` in paths) and be rejected wholesale when corrupt.
void main() {
  group('encode / decode', () {
    test('round-trips a mixed selection request', () {
      final request = NewWindowRequest(
        folders: const [
          NewWindowFolder(storageId: 'st1', path: 'Anime/Season 1'),
          NewWindowFolder(storageId: 'st1', path: '', recursive: false),
        ],
        files: const [
          NewWindowFile(
            storageId: 'st2',
            name: '第 01 集 「序章」.mkv',
            uri: 'file:///D:/Media/第 01 集 「序章」.mkv',
            path: ['Media', '第 01 集 「序章」.mkv'],
            type: ContentType.audio,
          ),
        ],
        sortField: ScenarioSortField.modifiedAt,
        sortDirection: SortDirection.desc,
      );

      final decoded = NewWindowRequest.decode(request.encode())!;
      expect(decoded.folders, hasLength(2));
      expect(decoded.folders.first.path, 'Anime/Season 1');
      expect(decoded.folders.last.recursive, isFalse);
      expect(decoded.files.single.name, '第 01 集 「序章」.mkv');
      expect(decoded.files.single.path, ['Media', '第 01 集 「序章」.mkv']);
      expect(decoded.files.single.type, ContentType.audio);
      expect(decoded.sortField, ScenarioSortField.modifiedAt);
      expect(decoded.sortDirection, SortDirection.desc);
    });

    test('round-trips the start file and the open-only intents', () {
      final play = newWindowRequestForFile(
        item: const FileItem(
          storageId: 'st',
          name: 'clip.mp4',
          uri: 'file:///a/clip.mp4',
          path: ['a', 'clip.mp4'],
        ),
        folderPath: 'a',
        itemPath: 'a/clip.mp4',
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
      );
      final decoded = NewWindowRequest.decode(play.encode())!;
      expect(decoded.startFile?.name, 'clip.mp4');
      expect(decoded.startFolderPath, 'a');
      expect(decoded.startItemPath, 'a/clip.mp4');
      expect(decoded.isPlaybackRequest, isTrue);

      final library = NewWindowRequest.decode(
        newWindowRequestForLibrary('lib-1').encode(),
      )!;
      expect(library.libraryId, 'lib-1');
      expect(library.isPlaybackRequest, isFalse);

      final open = NewWindowRequest.decode(
        newWindowRequestForPath(storageId: 'st', path: const ['', 'Anime']).encode(),
      )!;
      expect(open.openStorageId, 'st');
      expect(open.openPath, ['', 'Anime'],
          reason: 'favorite paths are replayed verbatim, leading empty included');
      expect(open.isPlaybackRequest, isFalse);
    });

    test('an all-default entry parses as-is (the action gate drops it)', () {
      // Parsing stays permissive on purpose: a malformed row must stay visible
      // in `describe()` logs instead of vanishing at decode time. The
      // "does this payload carry an action" decision is
      // `startupRequestHasAction`, which requires a non-empty storageId.
      final decoded = NewWindowRequest.fromJson(<String, dynamic>{
        'files': [<String, dynamic>{}],
        'start': {'f': <String, dynamic>{}},
        'open': {'s': ''},
      });
      expect(decoded.files, hasLength(1));
      expect(decoded.files.single.storageId, isEmpty);
      expect(decoded.startFile?.storageId, isEmpty);
      expect(decoded.openStorageId, isEmpty);
    });

    test('a scenario request carries only the id', () {
      final decoded = NewWindowRequest.decode(
        newWindowRequestForScenario('scn-42').encode(),
      )!;
      expect(decoded.scenarioId, 'scn-42');
      expect(decoded.isPlaybackRequest, isFalse);
    });
  });

  group('source-file rows', () {
    final webdav = WebDAVStorage(
      id: 's1',
      name: 'nas',
      host: '192.168.1.4',
      basePath: const <String>['/'],
      port: '8090',
      username: 'u',
      password: 'p',
      https: false,
    );
    final ftp = FTPStorage(
      id: 'f1',
      name: 'ftp',
      host: '192.168.1.9',
      basePath: const <String>['/'],
      port: '21',
      username: 'u',
      password: 'p',
    );

    test('derives the playable address from the storage record', () {
      final remote = newWindowFileItemForSourceFile(
        storageId: 's1',
        path: const <String>['anime', 'b.mp4'],
        storage: webdav,
        name: 'Episode 1',
      )!;
      expect(remote.uri, 'http://192.168.1.4:8090/anime/b.mp4',
          reason: 'a source row used to carry the local "/anime/b.mp4" guess');
      expect(remote.storageType, StorageType.webdav);
      expect(remote.name, 'Episode 1');
      expect(remote.type, ContentType.other);
      expect(fileRef(remote).uri, remote.uri);

      final ftpItem = newWindowFileItemForSourceFile(
        storageId: 'f1',
        path: const <String>['a.mp4'],
        storage: ftp,
      )!;
      expect(ftpItem.uri, 'ftp?host=192.168.1.9&port=21&path=/a.mp4');
      expect(ftpItem.name, 'a.mp4',
          reason: 'no label: the stored path leaf is the fallback');
    });

    test('a local or unknown storage keeps the local path form', () {
      final local = newWindowFileItemForSourceFile(
        storageId: 'l1',
        path: const <String>['sdcard', 'x.mp4'],
        storage: null,
        fallbackName: 'X',
      )!;
      expect(local.uri, '/sdcard/x.mp4');
      expect(local.storageType, StorageType.none);
      expect(local.name, 'X');
    });

    test('a row without an addressable path yields no item', () {
      expect(
        newWindowFileItemForSourceFile(
          storageId: 's1',
          path: null,
          storage: webdav,
        ),
        isNull,
      );
      expect(
        newWindowFileItemForSourceFile(
          storageId: 's1',
          path: const <String>['', ''],
          storage: webdav,
        ),
        isNull,
      );
    });
  });

  group('argument parsing', () {
    test('finds the flag among unrelated arguments', () {
      final encoded = newWindowRequestForScenario('scn-9').encode();
      final parsed = NewWindowRequest.parse([
        'some-bare-path.mkv',
        '--other=1',
        '${NewWindowRequest.flag}=$encoded',
      ]);
      expect(parsed?.scenarioId, 'scn-9');
    });

    test('a normal launch has no request', () {
      expect(NewWindowRequest.parse(const []), isNull);
      expect(NewWindowRequest.parse(const ['--new-window']), isNull);
      expect(NewWindowRequest.parse(const ['C:/a.mkv']), isNull);
    });

    test('a corrupt payload is rejected, never half-applied', () {
      expect(
        NewWindowRequest.parse(['${NewWindowRequest.flag}=not-base64!!']),
        isNull,
      );
      // Valid base64, but the JSON is not an object.
      expect(
        NewWindowRequest.parse(['${NewWindowRequest.flag}=WzEsMl0=']),
        isNull,
      );
    });
  });

  group('launcher arguments', () {
    test('the child receives exactly one opaque flag', () {
      final args = NewWindowLauncher.argumentsFor(
        newWindowRequestForFolder(storageId: 'st', path: 'a/b'),
      );
      expect(args, hasLength(1));
      expect(args.single, startsWith('${NewWindowRequest.flag}='));
      expect(args.single, isNot(contains('a/b')),
          reason: 'the payload is opaque so quoting cannot break it');
    });

    test('the child receives a round-trippable payload', () {
      final request = newWindowRequestForFolder(storageId: 'st', path: 'a/b');
      final parsed = NewWindowRequest.parse(
        NewWindowLauncher.argumentsFor(request),
      );
      expect(parsed?.folders.single.storageId, 'st');
      expect(parsed?.folders.single.path, 'a/b',
          reason: 'the argument must carry encode(), not the object toString()');
    });

    test('a normal request fits the Windows command-line limit', () {
      expect(
        NewWindowLauncher.commandLineLength(
          newWindowRequestForLibrary('lib-1'),
          executable: r'C:\Apps\IRIS\iris.exe',
        ),
        lessThanOrEqualTo(NewWindowLauncher.maxCommandLineChars),
      );
    });

    test('a huge selection is detected before spawning', () {
      final request = NewWindowRequest(
        files: [
          for (var i = 0; i < 800; i++)
            NewWindowFile(
              storageId: 'st',
              name: 'episode_${i.toString().padLeft(4, '0')}.mkv',
              uri: 'file:///D:/Media/Show/episode_'
                  '${i.toString().padLeft(4, '0')}.mkv',
              path: ['Media', 'Show', 'episode_$i.mkv'],
            ),
        ],
      );
      expect(
        NewWindowLauncher.commandLineLength(
          request,
          executable: r'C:\Apps\IRIS\iris.exe',
        ),
        greaterThan(NewWindowLauncher.maxCommandLineChars),
        reason: 'the caller must show the size dialog instead of a spawn error',
      );
    });

    test('package identity (not the install path) hides multi-window', () {
      addTearDown(() => debugIsPackagedBuildOverride = null);
      debugIsPackagedBuildOverride = true;
      expect(NewWindowLauncher.isPackagedBuild, isTrue);
      debugIsPackagedBuildOverride = false;
      expect(NewWindowLauncher.isPackagedBuild, isFalse);
    });

    test('the real package-identity probe answers on this host', () {
      if (!Platform.isWindows) return;
      debugIsPackagedBuildOverride = null;
      // `flutter test` runs as an unpackaged process; the probe must therefore
      // return false (a probe failure would conservatively return true and
      // disable multi-window, which is what this guards against).
      expect(NewWindowLauncher.isPackagedBuild, isFalse);
    });
  });
}
