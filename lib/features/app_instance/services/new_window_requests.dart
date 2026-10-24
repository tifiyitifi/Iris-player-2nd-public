import 'package:iris/features/app_instance/model/new_window_request.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart'
    show SortDirection;
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';

export 'package:iris/features/app_instance/model/new_window_request.dart'
    show NewWindowFile, NewWindowFolder, NewWindowRequest;

/// Builders that translate a UI surface (file row, folder row, selection,
/// scenario tile, …) into the payload a spawned window replays.
///
/// WHY a separate layer: the payload must describe the SAME intent the source
/// window would execute (folder scope, directory source, selection override), so
/// the mapping lives here once instead of in each menu handler. Paths are
/// already canonicalised by the caller — the scenario layer matches them against
/// `media_nodes.parent_path` / `path`.

NewWindowFile fileRef(FileItem item) => NewWindowFile(
      storageId: item.storageId,
      name: item.name,
      uri: item.uri,
      path: item.path,
      type: item.type,
    );

/// [FileItem] for a LIBRARY SOURCE row of kind `file`, in the shape the
/// `--open-request` payload carries.
///
/// A source row stores only `storageId + path`: it has no media type and no
/// persisted document URI (both are `media_nodes` details). The item is
/// therefore rebuilt the same way a node-backed row is — the playable address is
/// DERIVED from the storage record ([mediaNodePlayableUri]: WebDAV `http(s)://`,
/// FTP proxy `ftp?…`, SAF `content://`, otherwise the local path form). The
/// previous hand-built `FileItem(uri: playableUri(segments))` guessed a LOCAL
/// path for every kind, so a remote/SAF source row carried a bogus uri.
///
/// Returns null when the row has no addressable segment (null / empty path):
/// such an entry cannot be replayed — the receiving window resolves every file
/// through `storageId + path`, and the uri fallback is only for SAF rows whose
/// document uri IS the path.
FileItem? newWindowFileItemForSourceFile({
  required String storageId,
  required List<String>? path,
  required Storage? storage,
  String? name,
  String? fallbackName,
}) {
  final segments =
      (path ?? const <String>[]).where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;
  return FileItem(
    storageId: storageId,
    storageType: storage?.type ?? StorageType.none,
    // A source row may carry a user-chosen label; the stored path is the
    // fallback when it has none.
    name: name ?? fallbackName ?? segments.last,
    uri: mediaNodePlayableUri(storage, segments),
    path: segments,
    // A source row never carries a media type, and the receiving window does not
    // read it back — `other` is the honest value instead of a video guess.
    type: ContentType.other,
  );
}

/// A file row: play its folder scope and land on the file.
NewWindowRequest newWindowRequestForFile({
  required FileItem item,
  required String folderPath,
  required String itemPath,
  required ScenarioSortField sortField,
  required SortDirection sortDirection,
}) =>
    NewWindowRequest(
      startFile: fileRef(item),
      startFolderPath: folderPath,
      startItemPath: itemPath,
      sortField: sortField,
      sortDirection: sortDirection,
    );

/// A directory row / the current folder / a whole storage: a recursive
/// directory SOURCE (the queue resolves from the database, not a file list).
NewWindowRequest newWindowRequestForFolder({
  required String storageId,
  required String path,
  bool recursive = true,
  ScenarioSortField sortField = ScenarioSortField.name,
  SortDirection sortDirection = SortDirection.asc,
}) =>
    NewWindowRequest(
      folders: [
        NewWindowFolder(
          storageId: storageId,
          path: path,
          recursive: recursive,
        ),
      ],
      sortField: sortField,
      sortDirection: sortDirection,
    );

/// A multi-selection: directory sources first, then explicit files — exactly
/// `playSelectionInDefaultScenario`'s ordering contract. Each folder carries its
/// own storage, so a library whose sources span storages stays representable.
NewWindowRequest newWindowRequestForSelection({
  required List<NewWindowFolder> folders,
  required List<FileItem> files,
  required ScenarioSortField sortField,
  required SortDirection sortDirection,
}) =>
    NewWindowRequest(
      folders: folders,
      files: [for (final f in files) fileRef(f)],
      sortField: sortField,
      sortDirection: sortDirection,
    );

/// A scenario tile: activate the scenario and resume it (the new window has its
/// own playing workspace, so it never disturbs the source window).
NewWindowRequest newWindowRequestForScenario(String scenarioId) =>
    NewWindowRequest(scenarioId: scenarioId);

/// A media-library tile: OPEN the library, do not play it.
NewWindowRequest newWindowRequestForLibrary(String libraryId) =>
    NewWindowRequest(libraryId: libraryId);

/// A favorites entry: OPEN the folder, do not play it.
NewWindowRequest newWindowRequestForPath({
  required String storageId,
  required List<String> path,
}) =>
    NewWindowRequest(openStorageId: storageId, openPath: path);
