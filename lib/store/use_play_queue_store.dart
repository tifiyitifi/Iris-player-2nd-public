import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/play_queue/backends/play_queue_backend.dart';
import 'package:iris/features/media_library/play_queue/backends/query_play_queue_backend.dart';
import 'package:iris/features/media_library/play_queue/models/play_queue_source.dart';
import 'package:iris/features/media_library/play_queue/persistence/play_queue_persistence.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/store/play_queue_state.dart';
import 'package:iris/store/persistent_store.dart';
import 'package:iris/globals.dart' as globals;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/check_content_type.dart';
import 'package:iris/utils/get_shuffle_play_queue.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:saf_util/saf_util.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);

// ============================================================================
// Legacy in-memory backend — same algorithm as original PlayQueueStore
// ============================================================================
class InMemoryPlayQueueBackend implements PlayQueueBackend {
  PlayQueueState _state = PlayQueueState();
  final KvStore _storage;

  InMemoryPlayQueueBackend({KvStore? storage})
      : _storage = storage ?? getKvStore();

  @override
  bool get isQueryMode => false;

  @override
  List<PlayQueueItem> get playQueue => _state.playQueue;

  @override
  int get currentIndex => _state.currentIndex;

  @override
  int get totalCount => _state.playQueue.length;

  @override
  int get currentVirtualPos =>
      _state.playQueue.indexWhere((e) => e.index == _state.currentIndex);

  @override
  int get itemsPerPage => 50;

  @override
  int get sourceCount => 1;

  PlayQueueState get state => _state;

  set state(PlayQueueState v) => _state = v;

  Future<void> update({
    required List<PlayQueueItem> playQueue,
    int? index,
  }) async {
    _state = _state.copyWith(
      playQueue: playQueue,
      currentIndex: index ?? _state.currentIndex,
    );
    await _save();
  }

  Future<void> updateCurrentIndex(int index) async {
    _state = _state.copyWith(currentIndex: index);
    await _save();
  }

  @override
  Future<void> clear() async {
    _state = PlayQueueState(playQueue: [], currentIndex: -1);
    await _save();
  }

  Future<void> add(List<FileItem> files) async {
    final int maxIndex = _state.playQueue.isEmpty
        ? -1
        : _state.playQueue.map((e) => e.index).reduce(max);
    final int startIndex = maxIndex + 1;

    final List<PlayQueueItem> items = files
        .asMap()
        .entries
        .map((entry) =>
            PlayQueueItem(file: entry.value, index: startIndex + entry.key))
        .toList();

    _state = _state.copyWith(playQueue: [..._state.playQueue, ...items]);
    await _save();
  }

  Future<void> remove(PlayQueueItem item) async {
    if (_state.playQueue.length <= 1) {
      _state = _state.copyWith(playQueue: [], currentIndex: 0);
    } else {
      final index = _state.playQueue.indexOf(item);
      // Stale tile (e.g. after a shuffle or queue replacement): nothing to
      // remove, and indexing with -1 would throw RangeError.
      if (index < 0) return;
      if (_state.playQueue[index].index == _state.currentIndex) {
        if (index + 1 < _state.playQueue.length) {
          _state = _state.copyWith(
            playQueue: [..._state.playQueue]..remove(item),
            currentIndex: _state.playQueue[index + 1].index,
          );
        } else {
          _state = _state.copyWith(
            playQueue: [..._state.playQueue]..remove(item),
            currentIndex: _state.playQueue[index - 1].index,
          );
        }
      } else {
        _state = _state.copyWith(
          playQueue: [..._state.playQueue]..remove(item),
        );
      }
    }
    await _save();
  }

  Future<void> previous() async {
    if (_state.playQueue.isEmpty) return;
    final int currentPlayIndex = _state.playQueue
        .indexWhere((element) => element.index == _state.currentIndex);
    if (currentPlayIndex <= 0) {
      await updateCurrentIndex(_state.playQueue.last.index);
    } else {
      await updateCurrentIndex(
          _state.playQueue[currentPlayIndex - 1].index);
    }
  }

  Future<void> next() async {
    if (_state.playQueue.isEmpty) return;
    final int currentPlayIndex = _state.playQueue
        .indexWhere((element) => element.index == _state.currentIndex);
    if (currentPlayIndex < 0 || currentPlayIndex >= _state.playQueue.length - 1) {
      if (_state.playQueue.isNotEmpty) {
        await updateCurrentIndex(_state.playQueue.first.index);
      }
      return;
    }
    await updateCurrentIndex(
        _state.playQueue[currentPlayIndex + 1].index);
  }

  Future<void> shuffle() async => update(
        playQueue:
            getShufflePlayQueue(_state.playQueue, _state.currentIndex),
        index: _state.currentIndex,
      );

  Future<void> sort() async => update(
        playQueue: [..._state.playQueue]
          ..sort((a, b) => a.index.compareTo(b.index)),
        index: _state.currentIndex,
      );

  // ── Manual reorder (PotPlayer-style) ──────────────────────────────────
  // Operates on global index space; caller handles paging jump.
  Future<bool> moveToTop(PlayQueueItem item) async {
    final idx = _state.playQueue.indexOf(item);
    if (idx <= 0) return false;
    final list = [..._state.playQueue];
    final e = list.removeAt(idx);
    list.insert(0, e);
    _state = _state.copyWith(playQueue: list);
    await _save();
    return true;
  }

  Future<bool> moveUp(PlayQueueItem item) async {
    final idx = _state.playQueue.indexOf(item);
    if (idx <= 0) return false;
    final list = [..._state.playQueue];
    final e = list.removeAt(idx);
    list.insert(idx - 1, e);
    _state = _state.copyWith(playQueue: list);
    await _save();
    return true;
  }

  Future<bool> moveDown(PlayQueueItem item) async {
    final idx = _state.playQueue.indexOf(item);
    if (idx < 0 || idx >= _state.playQueue.length - 1) return false;
    final list = [..._state.playQueue];
    final e = list.removeAt(idx);
    list.insert(idx + 1, e);
    _state = _state.copyWith(playQueue: list);
    await _save();
    return true;
  }

  Future<bool> moveToBottom(PlayQueueItem item) async {
    final idx = _state.playQueue.indexOf(item);
    if (idx < 0 || idx == _state.playQueue.length - 1) return false;
    final list = [..._state.playQueue];
    final e = list.removeAt(idx);
    list.add(e);
    _state = _state.copyWith(playQueue: list);
    await _save();
    return true;
  }

  /// Global index of item (0-based in playQueue order), or -1 if not found.
  int globalIndexOf(PlayQueueItem item) => _state.playQueue.indexOf(item);

  Future<void> setSource(PlayQueueSource source, {int initialPos = 0}) async {
    final items = source.maybeMap(
      explicit: (e) => e.items,
      orElse: () => <PlayQueueItem>[],
    );
    if (items.isEmpty) {
      _state = PlayQueueState();
      await _save();
      return;
    }
    _state = PlayQueueState(
      playQueue: items,
      currentIndex: initialPos < items.length ? items[initialPos].index : 0,
    );
    await _save();
  }

  @override
  Future<void> appendSource(PlayQueueSource source, {bool prepend = false}) async {
    final items = source.maybeMap(
      explicit: (e) => e.items,
      orElse: () => <PlayQueueItem>[],
    );
    if (items.isEmpty) return;
    final int maxIndex = _state.playQueue.isEmpty
        ? -1
        : _state.playQueue.map((e) => e.index).reduce(max);
    final newEntries = items.asMap().entries.map((e) => PlayQueueItem(
          file: e.value.file,
          index: maxIndex + 1 + e.key,
        )).toList();

    if (prepend) {
      final shifted = _state.playQueue.map((e) => PlayQueueItem(
            file: e.file,
            index: e.index + items.length,
          )).toList();
      _state = _state.copyWith(playQueue: [...newEntries, ...shifted]);
    } else {
      _state = _state.copyWith(playQueue: [..._state.playQueue, ...newEntries]);
    }
    await _save();
  }

  @override
  Future<void> removeSource(int index) async {
    // Not applicable for single-source in-memory mode
  }

  Future<List<PlayQueueItem>> getPagedQueueItems({
    required int page,
    required int pageSize,
    MediaType? mediaType,
  }) async {
    final start = (page - 1) * pageSize;
    final end = min(start + pageSize, _state.playQueue.length);
    if (start >= _state.playQueue.length) return [];
    return _state.playQueue.sublist(start, end);
  }

  Future<void> setItemsPerPage(int size) async {
    // No-op for legacy backend
  }

  Future<PlayQueueState?> legacyLoad() async {
    areaKeyLog.i('Loading Legacy PlayQueueState');
    try {
      if (isDesktop && globals.arguments.isNotEmpty) {
        String uri = globals.arguments[0];
        if (RegExp(r'^(http://|https://)').hasMatch(uri)) {
          final s = PlayQueueState(
            playQueue: [
              PlayQueueItem(
                file: FileItem(name: uri, uri: uri),
                index: 0,
              )
            ],
            currentIndex: 0,
          );
          await useAppStore().updateAutoPlay(true);
          saveState(s);
          return s;
        }

        final filePath = uri;
        if (isMediaFile(filePath)) {
          final s = await getLocalPlayQueue(filePath);
          if (s != null && s.playQueue.isNotEmpty) {
            await useAppStore().updateAutoPlay(true);
            saveState(s);
            return s;
          }
        }
      }

      final uri = globals.initUri;

      if (uri != null && Platform.isAndroid) {
        final file = await SafUtil().documentFileFromUri(uri, false);
        if (file != null) {
          await useAppStore().updateAutoPlay(true);
          return PlayQueueState(
            playQueue: [
              PlayQueueItem(
                file: FileItem(
                  name: file.name,
                  uri: file.uri,
                  size: file.length,
                ),
                index: 0,
              ),
            ],
            currentIndex: 0,
          );
        }
      }

      String? appState = await _storage.read(key: 'playQueue_state');
      if (appState != null) {
        return PlayQueueState.fromJson(json.decode(appState));
      }
    } catch (e) {
      areaKeyLog.e('Error loading Legacy PlayQueueState: $e');
    }
    return null;
  }

  Future<void> saveState(PlayQueueState s) async {
    try {
      await _storage.write(
          key: 'playQueue_state', value: json.encode(s.toJson()));
    } catch (e) {
      areaKeyLog.e('Error saving Legacy PlayQueueState: $e');
    }
  }

  Future<void> _save() async {
    await saveState(_state);
  }
}

// ============================================================================
// UnifiedPlayQueueStore — Facade over legacy and query backends
// ============================================================================
class UnifiedPlayQueueStore extends PersistentStore<PlayQueueState> {
  final PlayQueuePersistence legacyPersistence;
  final PlayQueuePersistence queryPersistence;

  final InMemoryPlayQueueBackend _legacyBackend;
  QueryPlayQueueBackend? _queryBackend;

  late PlayQueueBackend _activeBackend;
  late PlayQueuePersistence _activePersistence;
  bool _initialized = false;

  UnifiedPlayQueueStore({
    required this.legacyPersistence,
    required this.queryPersistence,
    InMemoryPlayQueueBackend? legacyBackend,
  })  : _legacyBackend = legacyBackend ?? InMemoryPlayQueueBackend(),
        super(PlayQueueState()) {
    // Eagerly wire the legacy backend so pre-onReady readers (Player.build
    // title deps read totalCount/currentVirtualPos on the very first frame)
    // never hit the uninitialized late field on slow-IO devices. Legacy mode
    // needs no DB access; onReady() re-runs _setBackend with the
    // authoritative persistence flag.
    _activeBackend = _legacyBackend;
    _activePersistence = legacyPersistence;
    _setBackend(true);
  }

  PlayQueueBackend get activeBackend => _activeBackend;

  /// Reactive mirror of [totalCount].
  ///
  /// Why a notifier and not `select((s) => …)`: in query mode the SYNTHETIC
  /// state published to subscribers is pinned to a SINGLE item
  /// ([_syncSyntheticState]), so `playQueue.length` is always 1 and carries no
  /// information about the queue's real size — the total lives in the query
  /// backend's own state. A widget that only subscribed to `playQueue.length`
  /// therefore never learned that a search/filter moved the total 1↔N, and a
  /// bare `store.totalCount` read (no subscription) left prev/next visibility
  /// frozen. Published from [_syncSyntheticState] — the single funnel every
  /// mutation passes through — so both backends stay covered.
  ///
  /// `late final` on purpose: seeding it with [totalCount] at first ACCESS
  /// (not at construction) means a widget subscribing on the very first frame
  /// already sees the real queue size, matching what the previous bare read
  /// gave it. A field initializer would have pinned it to the empty-queue 0
  /// that [_activeBackend] holds during construction and hidden prev/next for
  /// one frame.
  late final ValueNotifier<int> totalCountNotifier =
      ValueNotifier<int>(totalCount);

  /// Lazy construction so ANY entry path (onReady, AppStore.onReady racing
  /// ahead of us, direct switchBackend calls) is safe regardless of order.
  void _ensureQueryBackend() {
    _queryBackend ??= QueryPlayQueueBackend(
      nodeRepo: DbModule.mediaNodeRepo,
    );
  }

  bool get _isQueryMode {
    if (!_initialized) return false;
    return identical(_activeBackend, _queryBackend);
  }

  @override
  void onReady() {
    _ensureQueryBackend();
    final useLegacy = useAppStore().state.useLegacyStoragePersistence;
    _setBackend(useLegacy);
    _initialized = true;
  }

  void _setBackend(bool useLegacy) {
    if (!useLegacy) _ensureQueryBackend();
    _activeBackend = useLegacy ? _legacyBackend : _queryBackend!;
    _activePersistence = useLegacy ? legacyPersistence : queryPersistence;
  }

  Future<void> switchBackend(bool useLegacy) async {
    _setBackend(useLegacy);
    final loaded = await _activePersistence.load();
    if (loaded != null) {
      set(loaded);
      if (!_isQueryMode) {
        _legacyBackend.state = loaded;
      }
      // This branch never runs `_syncSyntheticState`, so publish here or a
      // backend switch would leave subscribers on the OLD backend's total.
      // Unconditional on purpose: `QueryPlayQueuePersistence.load()` happens to
      // return null today, so the query side of this branch is unreachable — a
      // publish that costs nothing removes the question of whether it is.
      _publishTotalCount();
    } else if (_isQueryMode) {
      final qs = await _queryBackend!.queryLoad();
      if (qs != null) _queryBackend!.set(qs);
      await _syncSyntheticState();
    }
  }

  // ========== Public state accessors ==========

  @override
  PlayQueueState get state => super.state;

  bool get isQueryMode => _isQueryMode;

  int get totalCount {
    try {
      return _activeBackend.totalCount;
    } catch (_) {
      return state.playQueue.length;
    }
  }

  int get currentVirtualPos {
    try {
      return _activeBackend.currentVirtualPos;
    } catch (_) {
      return state.playQueue.indexWhere((e) => e.index == state.currentIndex);
    }
  }

  int get itemsPerPage {
    try {
      return _activeBackend.itemsPerPage;
    } catch (_) {
      return 50;
    }
  }

  // ========== Delegated API ==========

  Future<void> update({
    required List<PlayQueueItem> playQueue,
    int? index,
  }) async {
    await _activeBackend.update(playQueue: playQueue, index: index);
    await _afterMutation();
  }

  Future<void> updateCurrentIndex(int index) async {
    await _activeBackend.updateCurrentIndex(index);
    await _afterMutation();
  }

  Future<void> clear() async {
    await _activeBackend.clear();
    await _afterMutation();
  }

  Future<void> add(List<FileItem> files) async {
    await _activeBackend.add(files);
    await _afterMutation();
  }

  Future<void> remove(PlayQueueItem item) async {
    await _activeBackend.remove(item);
    await _afterMutation();
  }

  Future<void> next() async {
    await _activeBackend.next();
    await _afterMutation();
  }

  Future<void> previous() async {
    await _activeBackend.previous();
    await _afterMutation();
  }

  Future<void> shuffle() async {
    await _activeBackend.shuffle();
    await _afterMutation();
  }

  Future<void> sort() async {
    await _activeBackend.sort();
    await _afterMutation();
  }

  Future<bool> moveToTop(PlayQueueItem item) async {
    final res = await _activeBackend.moveToTop(item);
    if (res) await _afterMutation();
    return res;
  }

  Future<bool> moveUp(PlayQueueItem item) async {
    final res = await _activeBackend.moveUp(item);
    if (res) await _afterMutation();
    return res;
  }

  Future<bool> moveDown(PlayQueueItem item) async {
    final res = await _activeBackend.moveDown(item);
    if (res) await _afterMutation();
    return res;
  }

  Future<bool> moveToBottom(PlayQueueItem item) async {
    final res = await _activeBackend.moveToBottom(item);
    if (res) await _afterMutation();
    return res;
  }

  int globalIndexOf(PlayQueueItem item) => _activeBackend.globalIndexOf(item);

  Future<void> setSource(PlayQueueSource source, {int initialPos = 0}) async {
    await _activeBackend.setSource(source, initialPos: initialPos);
    await _afterMutation();
  }

  Future<void> appendSource(PlayQueueSource source, {bool prepend = false}) async {
    await _activeBackend.appendSource(source, prepend: prepend);
    await _afterMutation();
  }

  Future<void> removeSource(int index) async {
    await _activeBackend.removeSource(index);
    await _afterMutation();
  }

  int get sourceCount => _activeBackend.sourceCount;

  Future<List<PlayQueueItem>> getPagedQueueItems({
    required int page,
    required int pageSize,
    MediaType? mediaType,
  }) {
    return _activeBackend.getPagedQueueItems(
      page: page,
      pageSize: pageSize,
      mediaType: mediaType,
    );
  }

  Future<void> setItemsPerPage(int size) async {
    await _activeBackend.setItemsPerPage(size);
  }

  Future<FileItem> getCurrentFile() async {
    if (!_isQueryMode) {
      final pq = _legacyBackend.playQueue;
      final ci = _legacyBackend.currentIndex;
      final idx = pq.indexWhere((e) => e.index == ci);
      if (idx < 0 || idx >= pq.length) return FileItem(name: '', uri: '');
      return pq[idx].file;
    }
    return _queryBackend!.getCurrentFileItem();
  }

  // ========== Mutation post-processing ==========

  Future<void> _afterMutation() async {
    await _syncSyntheticState();
    if (_isQueryMode) {
      await _queryBackend!.save(_queryBackend!.state);
    } else {
      await _activePersistence.save(state);
    }
  }

  // ========== Synthetic state sync ==========

  Future<void> _syncSyntheticState() async {
    if (!_isQueryMode) {
      set(_legacyBackend.state);
      _publishTotalCount();
      return;
    }

    if (_queryBackend!.state.totalCount == 0) {
      set(PlayQueueState(playQueue: [], currentIndex: 0));
      _publishTotalCount();
      return;
    }

    final file = await _queryBackend!.getCurrentFileItem();
    if (file.uri.isNotEmpty) {
      set(PlayQueueState(
        playQueue: [PlayQueueItem(file: file, index: _queryBackend!.state.currentVirtualPos)],
        currentIndex: _queryBackend!.state.currentVirtualPos,
      ));
    } else {
      set(PlayQueueState(playQueue: [], currentIndex: 0));
    }
    _publishTotalCount();
  }

  /// Mirrors [totalCount] onto [totalCountNotifier] so UI can subscribe to it.
  void _publishTotalCount() {
    final int next = totalCount;
    if (totalCountNotifier.value != next) totalCountNotifier.value = next;
  }

  // ========== Load / Save ==========

  @override
  Future<PlayQueueState?> load() async {
    // PersistentStore._init fires load() DURING construction, before
    // onReady/_setBackend picks the configured backend — same defensive
    // pattern as UnifiedStorageStore.load's default-backend guard.
    if (!_initialized) return null;
    return _activePersistence.load();
  }

  @override
  Future<void> save(PlayQueueState s) async {
    if (!_initialized) return;
    await _activePersistence.save(s);
  }
}

// ========== Singleton factory ==========
UnifiedPlayQueueStore usePlayQueueStore() => create(() => UnifiedPlayQueueStore(
      legacyPersistence: LegacyPlayQueuePersistence(),
      queryPersistence: QueryPlayQueuePersistence(),
    ));
