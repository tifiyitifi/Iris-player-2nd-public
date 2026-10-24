import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyStore);

/// Base class for persistent stores with automatic load/save lifecycle.
///
/// Philosophy:
/// - Each store manages its own state.
/// - Async initialization is separated from construction to prevent race conditions.
/// - `onReady()` provides a safe hook for subclasses after state is loaded.
///
/// DURABILITY CONTRACT: a store whose [load] threw keeps its DEFAULT state, so
/// persisting that state would overwrite good data with nothing. Every write
/// path is therefore gated on [loadOk] — see [dispose].
abstract class PersistentStore<T> extends Store<T> {
  /// Completer that signals when the store is fully loaded.
  final _initCompleter = Completer<void>();

  /// True only when [load] returned WITHOUT throwing.
  ///
  /// A null result still counts as success — it means the backend simply holds
  /// nothing yet. A thrown error does not: the backing data is unknown, so it
  /// must never be replaced by this store's default state.
  bool _loadOk = false;

  /// Whether the initial [load] completed successfully.
  bool get loadOk => _loadOk;

  /// Future that completes once the store is initialized.
  /// Other stores or components can `await store.initialized`.
  Future<void> get initialized => _initCompleter.future;

  /// Constructor starts async loading immediately.
  /// Actual state is applied asynchronously via `set()`.
  PersistentStore(super.initialState) {
    _init();
  }

  /// Internal async initialization.
  /// Call `onReady()` for subclass post-load logic.
  Future<void> _init() async {
    try {
      final loaded = await load();
      _loadOk = true;
      if (loaded != null) set(loaded);
    } catch (e, s) {
      // Deliberately NOT silent: a failed load leaves the store on its default
      // state, and knowing that is what makes the write gate below trustworthy.
      _log.e('load failed for $runtimeType; writes stay disabled: $e\n$s');
    } finally {
      if (!_initCompleter.isCompleted) _initCompleter.complete();
      try {
        await Future.sync(() => onReady());
      } catch (_) {}
    }
  }

  /// Optional hook for subclasses after state is loaded.
  /// Override to perform actions like cross-store coordination
  /// or backend switching (e.g., `useStorageStore().switchBackend()`).
  @protected
  FutureOr<void> onReady() {}

  /// Re-runs [load] and applies the result.
  ///
  /// Used after one-time data imports that happen while the store is already
  /// alive (e.g. the portable first-run import runs after [AppStore]
  /// initialized with empty portable storage).
  Future<void> reload() async {
    try {
      final loaded = await load();
      _loadOk = true;
      if (loaded != null) set(loaded);
    } catch (e) {
      _log.e('reload failed for $runtimeType: $e');
    }
  }

  Future<T?> load();

  Future<void> save(T state);

  /// Whether [dispose] may persist the current state.
  ///
  /// Multi-window override point: an extra IRIS window holds a snapshot that may
  /// be stale for settings another window changed while it was open, so its
  /// shutdown must not rewrite the shared blob. Every immediate mutation already
  /// persists through the store's own write path, so nothing is lost.
  @protected
  bool get persistOnDispose => true;

  /// Dispose safely by saving state first.
  ///
  /// The save is SKIPPED when [loadOk] is false: several backends write as a
  /// full replace (delete-all + insert), so persisting a never-loaded store
  /// would erase the user's data on exit.
  @override
  @mustCallSuper
  Future<void> dispose() async {
    if (_loadOk && persistOnDispose) {
      try {
        await save(state);
      } catch (_) {}
    } else if (!_loadOk) {
      _log.w('skip save on dispose: $runtimeType never loaded successfully');
    }
    await super.dispose();
  }
}
