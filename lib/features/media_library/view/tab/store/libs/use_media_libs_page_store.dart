import 'dart:async';
import 'dart:convert';

import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:flutter_zustand/flutter_zustand.dart' as zustand;
import 'package:iris/features/media_library/model/db/adapters/media_library.dart';
import 'package:iris/features/media_library/model/db/repositories/media_library_repository_facade.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sort_by.dart';
import 'package:iris/features/media_library/model/media_lib/media_library.dart';
import 'package:iris/features/media_library/services/system_library_open_check.dart';
import 'package:iris/features/media_library/view/tab/store/libs/enum/load_state.dart';
import 'package:iris/features/media_library/view/tab/store/libs/media_libs_page_state.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/persistent_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:uuid/uuid.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);

class MediaLibsPageStore extends PersistentStore<MediaLibsPageState> {
  final MediaLibraryFacade facade;

  MediaLibsPageStore({
    required this.facade,
  }) : super(const MediaLibsPageState());

  // STORAGE

  static const _storageKey = 'media_libs_page_state';

  final KvStore _storage = getKvStore();

  // RUNTIME STATE

  //MediaLibsRuntimeState runtime = state.;

  // INTERNALS

  int _refreshVersion = 0;

// PERSISTENCE

  @override
  Future<MediaLibsPageState?> load() async {
    try {
      final raw = await _storage.read(key: _storageKey);

      if (raw != null) {
        final jsonMap = json.decode(raw) as Map<String, dynamic>;
        set(MediaLibsPageState.fromJson(jsonMap));
      }

      await refresh();
      return state;
    } catch (e) {
      // Never swallow: a failed load must keep loadOk false so the
      // PersistentStore durability gate blocks writes.
      areaKeyLog.e('load error: $e');
      rethrow;
    }
  }

  @override
  Future<void> save(
    MediaLibsPageState state,
  ) async {
    try {
      await _storage.write(
        key: _storageKey,
        value: json.encode(state.toJson()),
      );
    } catch (e) {
      areaKeyLog.e('save error: $e');
    }
  }

  Future<void> _update(
    MediaLibsPageState Function(MediaLibsPageState current) updater,
  ) async {
    final next = updater(state);
    set(next);
    unawaited(save(next));
  }
  // REFRESH

  Future<void> refresh() async {
    final refreshVersion = ++_refreshVersion;

    // Transition to loading.
    // We purposefully do not wipe the existing arrays
    // to prevent the UI from flickering while new data is fetched.
    set(
      state.copyWith(
        runtime: state.runtime.copyWith(
          state: LoadState.loading,
          error: null,
        ),
      ),
    );

    try {
      final libraries = await _loadLibraries();
      if (refreshVersion != _refreshVersion) return;

      // Update the reactive state
      // Transition to ready with fresh data
      set(
        state.copyWith(
          runtime: state.runtime.copyWith(
            state: LoadState.ready,
            libraries: libraries,
            error: null,
          ),
        ),
      );
    } catch (e) {
      // Transition to error
      set(
        state.copyWith(
          runtime: state.runtime.copyWith(
            state: LoadState.error,
            error: e,
          ),
        ),
      );
      areaKeyLog.e('refresh error: $e');
    }
  }

  // LOADERS

  Future<List<MediaLibrary>> _loadLibraries() async {
    final libraries = await facade.getLibraries();

    return _sortLibraries(
      libraries,
      sortBy: state.sortBy,
      sortDirection: state.sortDirection,
    );
  }

  // LIBRARY ACTIONS

  Future<void> createLibrary(
    MediaLibrary library,
  ) async {
    await facade.saveLibrary(library);

    await refresh();
  }

  /// Creates a new user library by name and refreshes the state.
  /// Hides UUID generation, timestamps, and type assignment from the UI.
  Future<void> createUserLibrary(String name) async {
    final now = DateTime.now();

    final newLibrary = MediaLibrary(
      id: const Uuid().v4(),
      name: name,
      type: MediaLibraryType.user,
      createdAt: now,
      updatedAt: now,
    );

    await facade.saveLibrary(newLibrary);
    await refresh();
  }

  Future<void> deleteLibrary(
    String id,
  ) async {
    await facade.deleteLibrary(id);
    await refresh();
  }

  Future<void> deleteLibraries(
    List<String> ids,
  ) async {
    await Future.wait(
      ids.map(facade.deleteLibrary),
    );
    await refresh();
  }

  Future<void> renameLibrary(
    String id,
    String newName,
  ) async {
    final library = await facade.getLibraryById(id);

    if (library == null) {
      throw Exception('Library not found');
    }

    await facade.saveLibrary(
      library.copyWith(
        name: newName,
        updatedAt: DateTime.now(),
      ),
    );
    await refresh();
  }

  // NAVIGATION

  Future<void> updateSort(
    MediaLibsListSortBy sortBy,
    SortDirection sortDirection,
  ) async {
    await _update(
      (current) => current.copyWith(
        sortBy: sortBy,
        sortDirection: sortDirection,
      ),
    );

    await refresh();
  }

  // SORTING

  List<MediaLibrary> _sortLibraries(
    List<MediaLibrary> libraries, {
    required MediaLibsListSortBy sortBy,
    required SortDirection sortDirection,
  }) {
    final systemLibraries = libraries.where((e) => e.isSystem).toList();

    final userLibraries = libraries.where((e) => e.isUser).toList();

    int compare(
      MediaLibrary a,
      MediaLibrary b,
    ) {
      switch (sortBy) {
        case MediaLibsListSortBy.name:
          return a.name.compareTo(b.name);

        case MediaLibsListSortBy.createdAt:
          return a.createdAt.compareTo(
            b.createdAt,
          );

        case MediaLibsListSortBy.updatedAt:
          return a.updatedAt.compareTo(
            b.updatedAt,
          );
      }
    }

    userLibraries.sort((a, b) {
      final result = compare(a, b);

      return sortDirection == SortDirection.asc ? result : -result;
    });

    // System libs: per-storage libs first (ordered by storage name via the
    // storage store), then the detached lib, then user libraries last (D6).
    final detachedLib = systemLibraries
        .where((e) => e.id == SystemLibraryOpenCheckService.detachedLibId)
        .toList();
    final perStorageSystem = systemLibraries
        .where((e) => e.id != SystemLibraryOpenCheckService.detachedLibId)
        .toList()
      ..sort((a, b) => _systemLibOrder(a).compareTo(_systemLibOrder(b)));

    return [
      ...perStorageSystem,
      ...detachedLib,
      ...userLibraries,
    ];
  }

  /// Sort key for a per-storage system lib: the current storage name (falls
  /// back to the lib id so ordering stays stable when a storage is removed).
  String _systemLibOrder(MediaLibrary lib) {
    final storageId = _storageIdFromSystemLib(lib.id);
    if (storageId == null) return lib.name;
    final storage = useStorageStore().findById(storageId);
    return storage?.name ?? lib.name;
  }

  static String? _storageIdFromSystemLib(String libId) {
    const prefix = 'sys_';
    if (!libId.startsWith(prefix)) return null;
    final sid = libId.substring(prefix.length);
    return sid.isEmpty ? null : sid;
  }

  // LIFECYCLE

  @override
  Future<void> dispose() async {
    await super.dispose();
  }

  Future<void> createLibrariesBatch({
    required String pattern,
    required int count,
    required int startIndex,
  }) async {
    final maxIndex = startIndex + count - 1;

    final padWidth = maxIndex.toString().length;

    final libraries = List.generate(count, (offset) {
      final now = DateTime.now();

      final index = startIndex + offset;

      final paddedIndex = index.toString().padLeft(padWidth, '0');

      final name = pattern.contains('{index}')
          ? pattern.replaceAll(
              '{index}',
              paddedIndex,
            )
          : '$pattern $paddedIndex';

      return MediaLibrary(
        id: const Uuid().v4(),
        name: name,
        type: MediaLibraryType.user,
        createdAt: now,
        updatedAt: now,
      );
    });

    await Future.wait(
      libraries.map(facade.saveLibrary),
    );

    await refresh();
  }
}

MediaLibsPageStore useMediaLibsStore() {
  return zustand.create(
    () => MediaLibsPageStore(
      facade: DbModule.mediaFacade,
    ),
  );
}
