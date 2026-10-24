import 'dart:convert';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/models/progress.dart';
import 'package:iris/models/store/history_state.dart';
import 'package:iris/store/persistent_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);

class HistoryStore extends PersistentStore<HistoryState> {
  HistoryStore() : super(HistoryState());

  Progress? findById(String id) {
    final direct = state.history[id];
    if (direct != null) return direct;
    // Defensive: legacy callers may pass a raw 'storageId:uri' id (the old
    // FileItem.getID() shape). Canonicalize the path portion so canonical-
    // keyed entries are still found.
    return state.history[_canonicalKeyFor(id)];
  }

  Future<void> add(Progress progress) async {
    // final key = progress.file.getID();  // legacy: surface-dependent uri key
    final key = canonicalProgressKey(progress.file.storageId, progress.file.path,
        uri: progress.file.uri); // unified
    final next = <String, Progress>{
      ...state.history,
      key: progress,
    };
    set(state.copyWith(history: trimHistory(next, state.maxHistoryRecords)));
    await save(state);
  }

  Future<void> remove(Progress progress) async {
    // final key = progress.file.getID();  // legacy: surface-dependent uri key
    final key = canonicalProgressKey(progress.file.storageId, progress.file.path,
        uri: progress.file.uri); // unified
    set(state.copyWith(
        history: {...state.history}..remove(key)));
    await save(state);
  }

  /// Re-keys history entries of [storageId] whose path sits under [oldBase] to
  /// [newBase] (drive-letter reassignment), rewriting both the map key and the
  /// stored [Progress.file] path. No-op and no save when nothing matched.
  Future<void> remapStoragePath({
    required String storageId,
    required String oldBase,
    required String newBase,
  }) async {
    final oldSegs = pathConv(oldBase);
    final newSegs = pathConv(newBase);
    if (oldSegs.isEmpty) return;
    var changed = false;
    final next = <String, Progress>{};
    state.history.forEach((key, progress) {
      final file = progress.file;
      if (file.storageId != storageId) {
        next[key] = progress;
        return;
      }
      final remapped = remapLeadingSegments(file.path, oldSegs, newSegs);
      if (remapped == null) {
        next[key] = progress;
        return;
      }
      changed = true;
      final newFile = file.copyWith(path: remapped);
      next[canonicalProgressKey(storageId, remapped, uri: newFile.uri)] =
          progress.copyWith(file: newFile);
    });
    if (!changed) return;
    set(state.copyWith(history: next));
    await save(state);
  }

  Future<void> clear() async {
    set(state.copyWith(history: {}));
    await save(state);
  }

  /// Trims [history] down to at most [max] records, evicting the oldest by
  /// insertion order (Dart maps preserve insertion order — a FIFO queue). A
  /// re-added key keeps its original position, so replayed files do not bump.
  static Map<String, Progress> trimHistory(
    Map<String, Progress> history,
    int max,
  ) {
    final next = Map<String, Progress>.from(history);
    while (next.length > max) {
      next.remove(next.keys.first);
    }
    return next;
  }

  /// Normalizes a persisted [HistoryState]: clamps a corrupt limit (>= 1) and
  /// trims history to that limit (bounding pre-cap oversized data).
  static HistoryState normalizeLoaded(HistoryState state) {
    final max = state.maxHistoryRecords < 1 ? 500 : state.maxHistoryRecords;
    return state.copyWith(
      maxHistoryRecords: max,
      history: trimHistory(state.history, max),
    );
  }

  /// Re-keys legacy `getID()`-form entries (`'storageId:uri'`) to the canonical
  /// progress key so old persisted history remains reachable after the key
  /// format change. Duplicate canonical keys keep the latest entry; when no
  /// key actually changed the state is returned untouched (no save).
  static HistoryState migrateCanonicalKeys(HistoryState state) {
    final migrated = <String, Progress>{};
    var changed = false;
    state.history.forEach((key, progress) {
      final canonical = canonicalProgressKey(progress.file.storageId,
          progress.file.path,
          uri: progress.file.uri);
      final existing = migrated[canonical];
      if (existing == null || progress.dateTime.isAfter(existing.dateTime)) {
        migrated[canonical] = progress;
      }
      if (key != canonical) changed = true;
    });
    if (!changed) return state;
    return state.copyWith(history: trimHistory(migrated, state.maxHistoryRecords));
  }

  /// Canonicalizes a raw `'storageId:path'` key string (legacy `getID()` shape)
  /// so lookups against canonical-keyed history still hit. An empty storageId
  /// produces a leading ':' (e.g. `:E:\Movies\a.mp4`), which is handled here.
  static String _canonicalKeyFor(String id) {
    final colon = id.indexOf(':');
    if (colon < 0) return id;
    return canonicalKey(id.substring(0, colon), canonicalOccurrencePath(id.substring(colon + 1)));
  }

  @override
  Future<HistoryState?> load() async {
    areaKeyLog.i('Loading HistoryState');
    try {
      final storage = getSessionKvStore();

      String? historyState = await storage.read(key: 'history_state');
      if (historyState != null) {
        final loaded =
            normalizeLoaded(HistoryState.fromJson(json.decode(historyState)));
        final migrated = migrateCanonicalKeys(loaded);
        // Persist the migrated (canonical) form once so the legacy keys are
        // not re-migrated on every launch (compat handling of old data).
        if (migrated != loaded) save(migrated);
        return migrated;
      }
    } catch (e) {
      // Never swallow: a failed load must keep loadOk false so the
      // PersistentStore durability gate blocks writes instead of
      // overwriting the user's history with an empty default.
      areaKeyLog.e('Error loading HistoryState: $e');
      rethrow;
    }
    return null;
  }

  @override
  Future<void> save(HistoryState state) async {
    // Durability gate (same as the storage store): persisting the default
    // state of a store whose load never succeeded would wipe the user's
    // real history.
    if (!loadOk) {
      areaKeyLog.w('skip save: history store never loaded successfully');
      return;
    }
    try {
      final storage = getSessionKvStore();

      await storage.write(
          key: 'history_state', value: json.encode(state.toJson()));
    } catch (e) {
      areaKeyLog.e('Error saving HistoryState: $e');
    }
  }
}

HistoryStore useHistoryStore() => create(() => HistoryStore());
