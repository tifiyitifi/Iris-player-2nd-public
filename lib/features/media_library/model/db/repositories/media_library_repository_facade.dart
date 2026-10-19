import 'package:iris/features/media_library/model/db/repositories/sub/library_repository.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_scan_repository.dart';
import 'package:iris/features/media_library/model/media_lib/media_library.dart';
import 'package:iris/features/media_library/model/media_lib/media_library_source.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/scan_state.dart';

/// The Facade:
///
/// provides a simple interface while hiding the coordination
/// logic between Libraries, Nodes, and Scan States.
class MediaLibraryFacade {
  final LibraryRepository _libraryRepo;
  final ScanStateRepository _scanRepo;

  MediaLibraryFacade({
    required LibraryRepository libraryRepo,
    required ScanStateRepository scanRepo,
  })  : _libraryRepo = libraryRepo,
        _scanRepo = scanRepo;

  // --- Library & Source Management ---

  Future<List<MediaLibrary>> getLibraries() => _libraryRepo.getLibraries();

  Future<MediaLibrary?> getLibraryById(String id) => _libraryRepo.getLibraryById(id);

  Future<void> saveLibrary(MediaLibrary library) => _libraryRepo.upsertLibrary(library);

  Future<void> deleteLibrary(String libraryId) async {
    await _libraryRepo.deleteLibrary(libraryId);
  }

  Future<List<MediaLibrarySource>> getSources(String libraryId) =>
      _libraryRepo.getSources(libraryId);

  Future<void> saveSource(MediaLibrarySource source) => _libraryRepo.upsertSource(source);

  Future<void> deleteSource(int sourceId) => _libraryRepo.removeSource(sourceId);

  // --- Scoped Content Discovery ---

/*  /// Lists media filtered specifically for a single library context.
  Future<List<MediaNode>> listLibraryMedia({
    required String libraryId,
    MediaType? mediaType,
    int limit = 100,
    int offset = 0,
  }) async {
    final sources = await _libraryRepo.getSources(libraryId);
    return _nodeRepo.listMediaInLibrary(
      sources: sources,
      mediaType: mediaType,
      limit: limit,
      offset: offset,
    );
  }*/

/*  /// Lists directories filtered by library sources.
  Future<List<MediaNode>> listLibraryDirectories({
    required String libraryId,
    int limit = 100,
    int offset = 0,
  }) async {
    final sources = await _libraryRepo.getSources(libraryId);
    return _nodeRepo.listDirectoriesInLibrary(
      sources: sources,
      limit: limit,
      offset: offset,
    );
  }

  /// Performs a search scoped to the specific library's sources.
  Future<List<MediaNode>> searchInLibrary({
    required String libraryId,
    required String keyword,
    MediaType? mediaType,
  }) async {
    final sources = await _libraryRepo.getSources(libraryId);
    return _nodeRepo.search(
      sources: sources,
      keyword: keyword,
      mediaType: mediaType,
    );
  }*/

  // --- Navigation & Node Detail ---

/*  /// Navigates the directory tree within a library.
  Future<List<MediaNode>> listDirectoryContents({
    required String libraryId,
    required int sourceId,
    required List<String>? path,
  }) async {
    final sources = await _libraryRepo.getSources(libraryId);

    final source = sources.firstWhereOrNull(
      (e) => e.id == sourceId,
    );

    if (source == null) {
      return [];
    }

    return _nodeRepo.listNodesInDirectory(
      storageId: source.storageId,
      parentPath: path,
      sources: [source],
    );
  }*/

/*  Future<MediaNode?> getNode(String storageId, List<String> path) =>
      _nodeRepo.getNodeByPath(storageId: storageId, path: path);*/

  // --- Synchronization (Scan Lifecycle) ---

  Future<ScanState?> getScanState(String storageId, List<String> path) =>
      _scanRepo.getScanState(storageId: storageId, path: path);

  Future<void> markAsScanning(String storageId, List<String> path) =>
      _scanRepo.markAsScanning(storageId: storageId, path: path);

  /// Coordinates the final database sync after a file system scan is complete.
  Future<void> commitScanResults({
    required String storageId,
    required List<String> path,
    required List<MediaNode> scannedNodes,
  }) {
    return _scanRepo.syncDirectory(
      storageId: storageId,
      path: path,
      scannedNodes: scannedNodes,
    );
  }

  // --- Maintenance ---

/*  /// Wipes all cached nodes for all storages defined in a library.
  Future<void> clearLibraryCache(String libraryId) async {
    final sources = await _libraryRepo.getSources(libraryId);
    // Potential Duplicate Storage
    final storageIds = sources.map((e) => e.storageId).toSet();

    for (final storageId in storageIds) {
      await _nodeRepo.deleteByStorage(storageId);
    }
  }*/
}
