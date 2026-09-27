import 'package:collection/collection.dart';
import 'package:flutter/material.dart' hide Chip;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
  import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
  import 'package:iris/features/media_library/scan/probe/media_probe.dart';
  import 'package:iris/features/media_library/scan/view/scan_options_dialog.dart';
  import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/meta_settings/engine/browse_scope_snapshot.dart'
    show currentBrowseMediaScope;
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/store/storage_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/files_sort.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class FilesDbController {
  FilesDbController({
    required this.files,
    required this.isLoading,
    required this.isError,
    required this.play,
    required this.back,
    required this.refresh,
    required this.startRecursiveScan,
    required this.currentPath,
    required this.currentFavorite,
    required this.storage,
    required this.storageStore,
    required this.itemScrollController,
    required this.scrollOffsetController,
    required this.itemPositionsListener,
    required this.scrollOffsetListener,
  });

  final List<FileItem> files;
  final bool isLoading;
  final bool isError;

  final void Function(List<FileItem>, int) play;
  final VoidCallback back;
  final VoidCallback refresh;
  final VoidCallback startRecursiveScan;

  final List<String> currentPath;
  final Favorite? currentFavorite;

  final Storage storage;

  final UnifiedStorageStore storageStore;

  final ItemScrollController itemScrollController;
  final ScrollOffsetController scrollOffsetController;
  final ItemPositionsListener itemPositionsListener;
  final ScrollOffsetListener scrollOffsetListener;

  String get title {
    if (currentPath.isEmpty) return storage.name;

    if (currentPath.length > 1) {
      return currentPath.last;
    }

    if (storage.basePath.length > 1) {
      return currentPath.first;
    }

    return storage.name;
  }

  void toggleFavorite() {
    if (currentFavorite != null) {
      storageStore.removeFavorite(currentFavorite!);
    } else {
      storageStore.addFavorite(
        Favorite(
          storageId: storage.id,
          path: currentPath,
        ),
      );
    }
  }

  void openPathIndex(int index) {
    storageStore.updateCurrentPath(
      currentPath.sublist(0, index + 1),
    );
  }

  void openDirectory(String name) {
    if (name.isEmpty) return;
    storageStore.updateCurrentPath([...currentPath, name]);
  }

  void goHome() {
    storageStore.updateCurrentStorage(null);
    storageStore.updateCurrentPath([]);
  }
}

FilesDbController useFilesDbController(
  BuildContext context,
  Storage storage,
) {
  final refreshState = useState(false);
  void refresh() => refreshState.value = !refreshState.value;

  final appStore = useAppStore();
  final storageStore = useStorageStore();
  final playQueueStore = usePlayQueueStore();

  final sortBy = appStore.select(context, (s) => s.sortBy);
  final sortOrder = appStore.select(context, (s) => s.sortOrder);
  final folderFirst = appStore.select(context, (s) => s.folderFirst);

  final favorites = storageStore.select(context, (s) => s.favorites);
  final currentPath = storageStore.select(context, (s) => s.currentPath);
  final currentStorage = storageStore.select(context, (s) => s.currentStorage);

  final currentFavorite = useMemoized(
    () => favorites.firstWhereOrNull(
      (f) => f.storageId == storage.id && f.path == currentPath,
    ),
    [favorites, currentPath],
  );

  useEffect(() {
    if (storageStore.loaded &&
        currentPath.isEmpty &&
        currentStorage?.id == storage.id) {
      storageStore.updateCurrentPath(storage.basePath);
    }
    return null;
  }, [storageStore.loaded, currentStorage, currentPath]);

  final future = useMemoized(
    () => storage.getFiles(currentPath),
    [currentPath, refreshState.value],
  );

  final snapshot = useFuture(future);

  final files = useMemoized(() {
    final raw = snapshot.data ?? <FileItem>[];

    // isVisible drops non-playable files; the browse scope additionally
    // hides playable-but-out-of-scope ones (dirs stay scope-neutral).
    final scope = currentBrowseMediaScope();
    final filtered =
        raw.where((f) => f.isVisible && f.matchesBrowseScope(scope)).toList();

    return filesSort(
      files: filtered,
      sortBy: sortBy,
      sortOrder: sortOrder,
      folderFirst: folderFirst,
    );
  }, [snapshot.data, sortBy, sortOrder, folderFirst]);

  final itemScrollController = useMemoized(() => ItemScrollController(), []);
  final scrollOffsetController =
      useMemoized(() => ScrollOffsetController(), []);
  final itemPositionsListener =
      useMemoized(() => ItemPositionsListener.create(), []);
  final scrollOffsetListener =
      useMemoized(() => ScrollOffsetListener.create(), []);

  void play(List<FileItem> files, int index) async {
    final clicked = files[index];

    // final playable =
    //     files.where((f) => [ContentType.video, ContentType.audio].contains(f.type)).toList();

    final playable = files.where((f) => f.isPlayable).toList();

    final queue = playable
        .asMap()
        .entries
        .map((e) => PlayQueueItem(file: e.value, index: e.key))
        .toList();

    await appStore.updateAutoPlay(true);
    await appStore.updateShuffle(false);
    PlaybackProviderRegistry.beginExternalFeed();

    await playQueueStore.update(
      playQueue: queue,
      index: playable.indexOf(clicked),
    );
  }

  void back() {
    if (currentPath.length > storage.basePath.length) {
      storageStore.updateCurrentPath(
        currentPath.sublist(0, currentPath.length - 1),
      );
    } else {
      storageStore.updateCurrentStorage(null);
      storageStore.updateCurrentPath([]);
    }
  }

  void startRecursiveScan() async {
    // Scan options gate: null = cancelled by the user.
    final probeEnabled =
        await showScanOptionsDialog(context, storageType: storage.type);
    if (probeEnabled == null) return;
    if (!context.mounted) return;

    final scanStore = useRecursiveScanStore();
    final rootPath = currentPath.join('/');

    final service = RecursiveScanService(
      storage: storage,
      scanStore: scanStore,
      nodesDao: DbModule.mediaNodesDao,
      sourcesDao: DbModule.mediaLibSourcesDao,
      probeService:
          probeEnabled ? createMediaProbeService() : null,
    );

    await service.scanRecursively(rootPaths: [rootPath], context: context);
  }

  return FilesDbController(
    files: files,
    isLoading: snapshot.connectionState == ConnectionState.waiting,
    isError: snapshot.error != null,
    play: play,
    back: back,
    refresh: refresh,
    startRecursiveScan: startRecursiveScan,
    currentPath: currentPath,
    currentFavorite: currentFavorite,
    storage: storage,
    storageStore: storageStore,
    itemScrollController: itemScrollController,
    scrollOffsetController: scrollOffsetController,
    itemPositionsListener: itemPositionsListener,
    scrollOffsetListener: scrollOffsetListener,
  );
}
