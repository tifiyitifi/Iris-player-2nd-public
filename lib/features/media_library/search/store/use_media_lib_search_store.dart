import 'dart:async';
import 'dart:convert';

import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/search/model/media_search_state.dart';
import 'package:iris/features/media_library/search/model/search_scope.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart'
    show clampPageSize;
import 'package:iris/store/persistent_store.dart';
import 'package:iris/utils/logger.dart';

final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);

/// The only persistence entry of the search feature (F-010 / §6.1).
///
/// History is a deduplicated MRU list capped at 50; page size, the last chosen
/// scope (echo-only) and the `respectExcludes` modifier are persisted too.
class MediaLibSearchStore extends PersistentStore<MediaLibSearchState> {
  MediaLibSearchStore() : super(const MediaLibSearchState());

  /// Window-scoped view state: the KV key is session-scoped, so two windows
  /// keep independent search history/scope.

  static const _storageKey = 'media_lib_search_state';
  static const int historyLimit = 50;

  final KvStore _storage = getSessionKvStore();

  @override
  Future<MediaLibSearchState?> load() async {
    try {
      final raw = await _storage.read(key: _storageKey);
      if (raw != null) {
        // Clamp ON READ: a size persisted by an older build (the prompt used to
        // allow 100000) would otherwise materialize a huge page on upgrade.
        final loaded = MediaLibSearchState.fromJson(
            json.decode(raw) as Map<String, dynamic>);
        return loaded.copyWith(pageSize: clampPageSize(loaded.pageSize));
      }
    } catch (e) {
      areaKeyLog.e('Search store load error: $e');
    }
    return null;
  }

  @override
  Future<void> save(MediaLibSearchState state) async {
    try {
      await _storage.write(key: _storageKey, value: json.encode(state.toJson()));
    } catch (e) {
      areaKeyLog.e('Search store save error: $e');
    }
  }

  Future<void> _persist(MediaLibSearchState next) async {
    set(next);
    await save(next);
  }

  /// Records [q] into history on explicit submit (F-009): dedupe + MRU + cap 50.
  Future<void> addHistory(String q) async {
    final query = q.trim();
    if (query.isEmpty) return;
    await initialized;
    final history = <String>[
      query,
      ...state.history.where((h) => h != query),
    ];
    await _persist(state.copyWith(
      history: history.take(historyLimit).toList(),
    ));
  }

  /// Moves [q] to the front after a history-panel click (v4-D6): treated as a
  /// use, but the click itself does not re-record (no new entry).
  Future<void> bumpHistory(String q) async {
    await initialized;
    if (!state.history.contains(q)) {
      await addHistory(q);
      return;
    }
    await _persist(state.copyWith(
      history: <String>[q, ...state.history.where((h) => h != q)],
    ));
  }

  /// Clears all search history (Q3 / v6-D5).
  Future<void> clearHistory() async {
    await initialized;
    if (state.history.isEmpty) return;
    await _persist(state.copyWith(history: const []));
  }

  Future<void> updatePageSize(int size) async {
    if (size < 1 || size == state.pageSize) return;
    await initialized;
    await _persist(state.copyWith(pageSize: size));
  }

  Future<void> updateScope(SearchScope scope) async {
    if (state.lastScope == scope) return;
    await initialized;
    await _persist(state.copyWith(lastScope: scope));
  }

  Future<void> updateRespectExcludes(bool value) async {
    if (state.respectExcludes == value) return;
    await initialized;
    await _persist(state.copyWith(respectExcludes: value));
  }
}

MediaLibSearchStore useMediaLibSearchStore() =>
    create(() => MediaLibSearchStore());
