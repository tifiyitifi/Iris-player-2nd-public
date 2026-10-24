import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_query.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/play_queue/backends/play_queue_backend.dart';
import 'package:iris/features/media_library/play_queue/engine/shuffle_engine.dart';
import 'package:iris/features/media_library/play_queue/models/play_queue_source.dart';
import 'package:iris/features/media_library/play_queue/models/query_play_queue_state.dart';
import 'package:iris/features/meta_settings/engine/browse_scope_snapshot.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart'
    show clampPageSize, kMaxBrowserPageSize;
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart' show StorageType;
import 'package:iris/models/store/play_queue_state.dart';
import 'package:iris/store/persistent_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/utils/path_conv.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);

class QueryPlayQueueBackend extends PersistentStore<QueryPlayQueueState>
    implements PlayQueueBackend {
  late final MediaNodeRepository _nodeRepo;

  /// Browse-media-scope snapshot resolved at query time (defaults to the
  /// global funnel). Injectable so store-free test environments can pin the
  /// legacy unscoped semantics. Null result = no extra filter.
  final List<MediaType>? Function() scopedMediaTypes;

  final _oversizeWarningController = ValueNotifier<String?>(null);

  ValueNotifier<String?> get oversizeWarning => _oversizeWarningController;

  QueryPlayQueueBackend({
    required MediaNodeRepository nodeRepo,
    List<MediaType>? Function()? scopedMediaTypes,
  })  : _nodeRepo = nodeRepo,
        scopedMediaTypes = scopedMediaTypes ?? currentBrowseScopeMediaTypes,
        super(QueryPlayQueueState(totalCount: 0));

  @override
  bool get isQueryMode => true;

  @override
  List<PlayQueueItem> get playQueue => [];

  @override
  int get currentIndex => 0;

  @override
  int get totalCount => state.totalCount;

  @override
  int get currentVirtualPos => state.currentVirtualPos;

  @override
  int get itemsPerPage => state.itemsPerPage;

  @override
  int get sourceCount => state.sources.length;

  @override
  Future<void> setSource(PlayQueueSource source, {int initialPos = 0}) async {
    final count = await _countForSource(source);
    final clampedPos = initialPos.clamp(0, max(0, count - 1)) as int;
    set(state.copyWith(
      sources: [source],
      totalCount: count,
      currentVirtualPos: clampedPos,
      currentOriginalPos: clampedPos,
      order: PlayQueueOrder.sequential,
      shuffleSeed: null,
    ));
    await save(state);
  }

  @override
  Future<void> appendSource(PlayQueueSource source, {bool prepend = false}) async {
    final addCount = await _countForSource(source);
    if (addCount == 0) return;

    final List<PlayQueueSource> newSources;
    if (prepend) {
      newSources = [source, ...state.sources];
      set(state.copyWith(
        sources: newSources,
        totalCount: state.totalCount + addCount,
        currentVirtualPos: state.currentVirtualPos + addCount,
        currentOriginalPos: state.currentOriginalPos + addCount,
      ));
    } else {
      newSources = [...state.sources, source];
      set(state.copyWith(
        sources: newSources,
        totalCount: state.totalCount + addCount,
      ));
    }
    await save(state);
  }

  @override
  Future<void> removeSource(int index) async {
    if (index < 0 || index >= state.sources.length) return;
    final removedCount = await _countForSource(state.sources[index]);
    final newList = [...state.sources]..removeAt(index);
    final newTotal = state.totalCount - removedCount;
    int newPos = state.currentVirtualPos;
    // Determine global offset of the removed source
    int offsetBefore = 0;
    for (int i = 0; i < index; i++) {
      offsetBefore += await _countForSource(state.sources[i]);
    }
    if (newPos >= offsetBefore && newPos < offsetBefore + removedCount) {
      newPos = offsetBefore;
    } else if (newPos >= offsetBefore + removedCount) {
      newPos -= removedCount;
    }
    newPos = newPos.clamp(0, max(0, newTotal - 1));
    set(state.copyWith(
      sources: newList,
      totalCount: newTotal,
      currentVirtualPos: newPos,
      currentOriginalPos: newPos,
    ));
    await save(state);
  }

  @override
  Future<void> update({
    required List<PlayQueueItem> playQueue,
    int? index,
  }) async {
    final limit = state.maxMemoryListLimit;
    if (playQueue.length > limit) {
      _oversizeWarningController.value =
          'List has ${playQueue.length} items — truncated to $limit. '
          'Use folder or all-media mode for large collections.';
      final truncated = playQueue.sublist(0, limit);
      set(state.copyWith(
        sources: [PlayQueueSource.explicit(items: truncated)],
        totalCount: truncated.length,
        currentVirtualPos: (index ?? 0).clamp(0, max(0, truncated.length - 1)),
        currentOriginalPos: (index ?? 0).clamp(0, max(0, truncated.length - 1)),
        order: PlayQueueOrder.sequential,
        shuffleSeed: null,
      ));
      await save(state);
      return;
    }
    set(state.copyWith(
      sources: [PlayQueueSource.explicit(items: playQueue)],
      totalCount: playQueue.length,
      currentVirtualPos: (index ?? 0).clamp(0, max(0, playQueue.length - 1)),
      currentOriginalPos: (index ?? 0).clamp(0, max(0, playQueue.length - 1)),
      order: PlayQueueOrder.sequential,
      shuffleSeed: null,
    ));
    await save(state);
  }

  @override
  Future<void> updateCurrentIndex(int index) async {
    if (state.totalCount == 0) return;
    final clamped = index.clamp(0, state.totalCount - 1);
    set(state.copyWith(
      currentVirtualPos: clamped,
      currentOriginalPos: clamped,
    ));
    await save(state);
  }

  @override
  Future<void> clear() async {
    set(state.copyWith(
      sources: [],
      totalCount: 0,
      currentVirtualPos: 0,
      currentOriginalPos: 0,
    ));
    await save(state);
  }

  @override
  Future<void> add(List<FileItem> files) async {
    final explicit = _explicitItems;
    final maxIdx = explicit.isEmpty
        ? -1
        : explicit.map((e) => e.index).reduce(max);
    final newItems = files.asMap().entries.map((e) => PlayQueueItem(
          file: e.value,
          index: maxIdx + 1 + e.key,
        ));
    final combined = [...explicit, ...newItems];
    set(state.copyWith(
      sources: [PlayQueueSource.explicit(items: combined)],
      totalCount: combined.length,
    ));
    await save(state);
  }

  List<PlayQueueItem> get _explicitItems {
    final allExplicit = <PlayQueueItem>[];
    for (final source in state.sources) {
      source.maybeMap(
        explicit: (e) => allExplicit.addAll(e.items),
        orElse: () {},
      );
    }
    return allExplicit;
  }

  @override
  Future<void> remove(PlayQueueItem item) async {
    final items = _explicitItems;
    if (items.isEmpty) return;
    // Find and remove from whichever explicit source it belongs to
    final newSources = <PlayQueueSource>[];
    bool removed = false;
    for (final source in state.sources) {
      source.maybeMap(
        explicit: (e) {
          final list = List<PlayQueueItem>.from(e.items);
          if (!removed) {
            final idx = list.indexOf(item);
            if (idx >= 0) {
              list.removeAt(idx);
              removed = true;
            }
          }
          newSources.add(PlayQueueSource.explicit(items: list));
        },
        orElse: () => newSources.add(source),
      );
    }
    final newTotal = items.length - (removed ? 1 : 0);
    int newPos = state.currentVirtualPos;
    if (newTotal == 0) newPos = 0;
    else if (newPos >= newTotal) newPos = newTotal - 1;
    set(state.copyWith(
      sources: newSources,
      totalCount: newTotal,
      currentVirtualPos: newPos,
      currentOriginalPos: newPos,
    ));
    await save(state);
  }

  @override
  Future<void> previous() async {
    if (state.totalCount == 0) return;
    final int newPos = state.currentVirtualPos <= 0
        ? state.totalCount - 1
        : state.currentVirtualPos - 1;
    final int realPos = _resolveReal(newPos);
    set(state.copyWith(
      currentVirtualPos: newPos,
      currentOriginalPos: realPos,
    ));
    await save(state);
  }

  @override
  Future<void> next() async {
    if (state.totalCount == 0) return;
    final int newPos = state.currentVirtualPos >= state.totalCount - 1
        ? 0
        : state.currentVirtualPos + 1;
    final int realPos = _resolveReal(newPos);
    set(state.copyWith(
      currentVirtualPos: newPos,
      currentOriginalPos: realPos,
    ));
    await save(state);
  }

  @override
  Future<void> shuffle() async {
    if (state.totalCount <= 1) return;
    if (state.order == PlayQueueOrder.shuffled) return;
    final seed = Random().nextInt(1 << 30);
    final engine = FeistelShuffle(seed, state.totalCount);
    final int newVirtualPos = engine.inverse(state.currentOriginalPos);
    set(state.copyWith(
      order: PlayQueueOrder.shuffled,
      shuffleSeed: seed,
      currentVirtualPos: newVirtualPos,
    ));
    await save(state);
  }

  @override
  Future<void> sort() async {
    if (state.order == PlayQueueOrder.sequential) return;
    set(state.copyWith(
      order: PlayQueueOrder.sequential,
      shuffleSeed: null,
      currentVirtualPos: state.currentOriginalPos,
    ));
    await save(state);
  }

  @override
  Future<List<PlayQueueItem>> getPagedQueueItems({
    required int page,
    required int pageSize,
    MediaType? mediaType,
  }) async {
    final offset = (page - 1) * pageSize;
    final count = min(pageSize, max(0, state.totalCount - offset));
    if (count <= 0) return [];

    final sourceInfos = await _buildSourceInfos(mediaType);

    if (state.order == PlayQueueOrder.sequential) {
      return _fetchPagedSequential(offset, count, sourceInfos);
    }
    return _fetchPagedShuffled(offset, count, sourceInfos);
  }

  // ── Multi-source helpers ──

  Future<List<_SourceInfo>> _buildSourceInfos(MediaType? overrideMediaType) async {
    final infos = <_SourceInfo>[];
    for (final source in state.sources) {
      final count = await _countForSource(source);
      final effectiveMediaType = source.maybeMap(
        allMedia: (s) => s.mediaType,
        folder: (s) => s.mediaType,
        orElse: () => overrideMediaType,
      );
      infos.add(_SourceInfo(source, count, effectiveMediaType));
    }
    return infos;
  }

  Future<List<PlayQueueItem>> _fetchPagedSequential(
    int offset,
    int count,
    List<_SourceInfo> infos,
  ) async {
    final result = <PlayQueueItem>[];
    int remaining = count;
    int globalPos = offset;

    for (final info in infos) {
      if (remaining <= 0) break;
      if (globalPos >= info.count) {
        globalPos -= info.count;
        continue;
      }

      final localCount = min(remaining, info.count - globalPos);
      final items = await _fetchFromSource(
          info.source, globalPos, localCount, info.mediaType);
      result.addAll(items);
      remaining -= localCount;
      globalPos = 0;
    }
    return result;
  }

  Future<List<PlayQueueItem>> _fetchPagedShuffled(
    int offset,
    int count,
    List<_SourceInfo> infos,
  ) async {
    if (state.shuffleSeed == null) return [];

    final engine = FeistelShuffle(state.shuffleSeed!, state.totalCount);
    final result = <PlayQueueItem>[];

    for (int i = 0; i < count; i++) {
      final virtualPos = offset + i;
      if (virtualPos >= state.totalCount) break;
      final realPos = engine.forward(virtualPos);

      // Find which source this realPos falls in
      int pos = realPos;
      for (final info in infos) {
        if (pos < info.count) {
          final items = await _fetchFromSource(
              info.source, pos, 1, info.mediaType);
          if (items.isNotEmpty) {
            result.add(PlayQueueItem(
              file: items.first.file,
              index: virtualPos,
            ));
          }
          break;
        }
        pos -= info.count;
      }
    }
    return result;
  }

  Future<List<PlayQueueItem>> _fetchFromSource(
    PlayQueueSource source,
    int offset,
    int count,
    MediaType? mediaType,
  ) async {
    return source.when(
      explicit: (items) {
        final end = min(offset + count, items.length);
        if (offset >= items.length) return <PlayQueueItem>[];
        return items.sublist(offset, end);
      },
      allMedia: (srcMediaType, storageId) async {
        return _fetchAllMediaPage(offset, count, mediaType ?? srcMediaType);
      },
      folder: (storageId, parentPath, srcMediaType, recursive) async {
        return _fetchFolderPage(
            storageId, parentPath, offset, count,
            mediaType ?? srcMediaType, recursive);
      },
    );
  }

  Future<List<PlayQueueItem>> _fetchAllMediaPage(
    int offset, int count, MediaType? mediaType,
  ) async {
    final result = await _nodeRepo.getAllMedia(
      page: offset + 1,
      pageSize: count,
      mediaType: mediaType,
      mediaTypes: scopedMediaTypes(),
      sortField: MediaSortField.name,
      sortDirection: SortDirection.asc,
    );
    return _nodesToQueueItems(result.items, offset);
  }

  Future<List<PlayQueueItem>> _fetchFolderPage(
    String storageId,
    String parentPath,
    int offset,
    int count,
    MediaType? mediaType,
    bool recursive,
  ) async {
    final query = MediaNodePageQuery(
      page: offset + 1,
      pageSize: count,
      storageId: storageId,
      parentPath: parentPath.isEmpty ? null : parentPath,
      nodeKind: MediaNodeKind.file,
      mediaType: mediaType,
      mediaTypes: scopedMediaTypes(),
      sortField: MediaSortField.name,
      sortDirection: SortDirection.asc,
      recursive: recursive,
    );
    final result = await _nodeRepo.getPagedNodes(query);
    return _nodesToQueueItems(result.items, offset);
  }

  Future<FileItem> getCurrentFileItem() async {
    final realPos = _resolveReal(state.currentVirtualPos);
    final infos = await _buildSourceInfos(null);
    int pos = realPos;
    for (final info in infos) {
      if (pos < info.count) {
        final items = await _fetchFromSource(info.source, pos, 1, info.mediaType);
        if (items.isNotEmpty) return items.first.file;
        break;
      }
      pos -= info.count;
    }
    return FileItem(name: '', uri: '');
  }

  int _resolveReal(int virtualPos) {
    if (state.order == PlayQueueOrder.sequential) return virtualPos;
    if (state.shuffleSeed == null) return virtualPos;
    final engine = FeistelShuffle(state.shuffleSeed!, state.totalCount);
    return engine.forward(virtualPos);
  }

  Future<int> _countForSource(PlayQueueSource source) {
    // Count semantics MUST mirror the fetch queries (getAllMedia /
    // _fetchFolderPage) — FeistelShuffle walks [0, totalCount) and any
    // divergence desyncs virtual positions. The non-recursive folder branch
    // previously counted ALL children (directories included), a latent
    // mismatch now fixed to files-only.
    final scopedTypes = scopedMediaTypes();
    return source.when<Future<int>>(
      explicit: (items) async => items.length,
      allMedia: (mediaType, storageId) async {
        final result = await _nodeRepo.getAllMedia(
          page: 1,
          pageSize: 1,
          mediaType: mediaType,
          mediaTypes: scopedTypes,
        );
        return result.totalItems;
      },
      folder: (storageId, parentPath, mediaType, recursive) async {
        final query = MediaNodePageQuery(
          page: 1,
          pageSize: 1,
          storageId: storageId,
          parentPath: parentPath.isEmpty ? null : parentPath,
          nodeKind: MediaNodeKind.file,
          mediaType: mediaType,
          mediaTypes: scopedTypes,
          recursive: recursive,
        );
        final result = await _nodeRepo.getPagedNodes(query);
        return result.totalItems;
      },
    );
  }

  List<PlayQueueItem> _nodesToQueueItems(
      List<MediaNode> nodes, int startIndex) {
    return nodes.asMap().entries.map((e) {
      return _toPlayQueueItem(e.value, startIndex + e.key);
    }).toList();
  }

  PlayQueueItem _toPlayQueueItem(MediaNode node, int virtualPos) {
    return PlayQueueItem(
      file: _mediaFileToFileItem(node),
      index: virtualPos,
    );
  }

  FileItem _mediaFileToFileItem(MediaNode node) {
    final file = node.maybeMap(
      file: (f) => f,
      orElse: () => null,
    );
    if (file == null) {
      return FileItem(
        name: node.name,
        uri: playableUri(node.path),
        path: node.path,
      );
    }
    final storage = useStorageStore().resolveStorageForNodeId(file.storageId);
    return FileItem(
      storageId: file.storageId,
      storageType: storage?.type ?? StorageType.none,
      name: file.name,
      uri: mediaNodePlayableUri(storage, file.path, uri: file.uri),
      path: file.path,
      size: file.sizeInBytes ?? 0,
      durationMs: file.durationMs,
      type: _convertMediaType(file.mediaType),
      lastModified: file.modifiedAt,
      // Subtitle associations persisted at scan time (schema v50).
      subtitles: file.subtitles ?? const [],
    );
  }

  ContentType _convertMediaType(MediaType mt) {
    switch (mt) {
      case MediaType.video:
        return ContentType.video;
      case MediaType.audio:
        return ContentType.audio;
      case MediaType.unknown:
        return ContentType.other;
    }
  }

  @override
  Future<void> setItemsPerPage(int size) async {
    // Both bounds, not just this backend's own budget: the shared browser
    // ceiling is what the prompt enforces, so persisting past it would only be
    // rejected again by the read clamp.
    final clamped =
        size.clamp(1, min<int>(state.maxItemsPerPage, kMaxBrowserPageSize));
    set(state.copyWith(itemsPerPage: clamped));
    await save(state);
  }

  @override
  Future<bool> moveToTop(PlayQueueItem item) async {
    final items = _explicitItems;
    final idx = items.indexOf(item);
    if (idx <= 0) return false;
    final list = [...items]..removeAt(idx)..insert(0, item);
    set(state.copyWith(sources: [PlayQueueSource.explicit(items: list)]));
    await save(state);
    return true;
  }

  @override
  Future<bool> moveUp(PlayQueueItem item) async {
    final items = _explicitItems;
    final idx = items.indexOf(item);
    if (idx <= 0) return false;
    final list = [...items]..removeAt(idx)..insert(idx - 1, item);
    set(state.copyWith(sources: [PlayQueueSource.explicit(items: list)]));
    await save(state);
    return true;
  }

  @override
  Future<bool> moveDown(PlayQueueItem item) async {
    final items = _explicitItems;
    final idx = items.indexOf(item);
    if (idx < 0 || idx >= items.length - 1) return false;
    final list = [...items]..removeAt(idx)..insert(idx + 1, item);
    set(state.copyWith(sources: [PlayQueueSource.explicit(items: list)]));
    await save(state);
    return true;
  }

  @override
  Future<bool> moveToBottom(PlayQueueItem item) async {
    final items = _explicitItems;
    final idx = items.indexOf(item);
    if (idx < 0 || idx == items.length - 1) return false;
    final list = [...items]..removeAt(idx)..add(item);
    set(state.copyWith(sources: [PlayQueueSource.explicit(items: list)]));
    await save(state);
    return true;
  }

  @override
  int globalIndexOf(PlayQueueItem item) => _explicitItems.indexOf(item);

  Future<QueryPlayQueueState?> queryLoad() async {
    areaKeyLog.i('Loading QueryPlayQueueState');
    try {
      final KvStore sec = getSessionKvStore();
      final raw = await sec.read(key: 'query_play_queue_state');
      if (raw != null) {
        // Clamp ON READ: the queue's own page-size prompt caps at
        // kMaxBrowserPageSize, so anything above that in the blob was written by
        // an older build and must not be handed to the data source — it fetches
        // a whole page the moment the queue page opens.
        final loaded = QueryPlayQueueState.fromJson(json.decode(raw));
        return loaded.copyWith(itemsPerPage: clampPageSize(loaded.itemsPerPage));
      }
    } catch (e) {
      areaKeyLog.e('Error loading QueryPlayQueueState: $e');
    }
    return null;
  }

  @override
  Future<QueryPlayQueueState?> load() async {
    return queryLoad();
  }

  @override
  Future<void> save(QueryPlayQueueState s) async {
    try {
      final KvStore sec = getSessionKvStore();
      await sec.write(
        key: 'query_play_queue_state',
        value: json.encode(s.toJson()),
      );
    } catch (e) {
      areaKeyLog.e('Error saving QueryPlayQueueState: $e');
    }
  }

  Future<void> saveLegacy(PlayQueueState legacy) async {
    try {
      final KvStore sec = getSessionKvStore();
      await sec.write(
        key: 'playQueue_state',
        value: json.encode(legacy.toJson()),
      );
    } catch (e) {
      areaKeyLog.e('Error saving legacy play queue: $e');
    }
  }
}

class _SourceInfo {
  final PlayQueueSource source;
  final int count;
  final MediaType? mediaType;

  _SourceInfo(this.source, this.count, this.mediaType);
}
