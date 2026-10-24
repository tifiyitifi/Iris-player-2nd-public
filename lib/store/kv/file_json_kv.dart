import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:synchronized/synchronized.dart';

final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);

/// JSON-file-backed [KvStore] for portable mode.
///
/// Durability model: the whole map is rewritten atomically on every write
/// (sibling `.tmp` + rename) — state blobs are small, so full rewrite keeps
/// the format trivially debuggable and crash-safe (a torn `.tmp` never
/// touches the live file).
///
/// Multi-instance model: several IRIS windows may share this file. Each write
/// takes an exclusive OS lock on `<kv.json>.lock`, re-reads the current file,
/// merges the one changed key and rewrites — so a second window's write can
/// never drop the first window's keys.
///
/// The merge granularity is the KEY, not the value: a key whose JSON holds
/// several logical rows (e.g. `storage_state` = every storage + favorite +
/// navigation) is still replaced wholesale, so two windows editing it
/// concurrently are last-write-wins. The merge only guarantees that UNRELATED
/// keys survive. See `StorageEntryPersistence` for why that cannot be fixed at
/// this layer (no cross-process read-modify-write for a single value).
///
/// READ side is a startup snapshot, NOT a live sync channel: [read]/[readAll]
/// serve this process's in-memory copy, loaded once. A setting another window
/// changed becomes visible here only after a local write (which re-reads under
/// the lock) or an app restart. This is deliberate: stores are hydrated once and
/// their in-memory state must not be swapped underneath the UI. Session keys
/// are unaffected — each window only reads/writes its own.
///
/// Corruption containment: an unparsable store file is moved aside
/// (`kv.json.corrupt-<ts>`) and the store starts empty instead of throwing.
class FileJsonKv implements KvStore {
  FileJsonKv({required this.filePath});

  /// Absolute path of the backing JSON file (e.g. `<userdata>/settings/kv.json`).
  final String filePath;

  final Map<String, String> _values = {};
  bool _loaded = false;
  final Lock _lock = Lock();

  @override
  Future<String?> read({required String key}) =>
      _lock.synchronized(() async {
        await _ensureLoadedLocked();
        return _values[key];
      });

  @override
  Future<void> write({required String key, required String value}) =>
      _lock.synchronized(() async {
        await _withFileLock(() async {
          await _ensureLoadedLocked();
          // Another IRIS window may have written since this process loaded:
          // re-read under the cross-process lock so its keys survive our
          // whole-file rewrite (portable mode is shared by every window).
          await _reloadFromDiskLocked();
          _values[key] = value;
          await _persistLocked();
        });
      });

  @override
  Future<void> delete({required String key}) => _lock.synchronized(() async {
        await _withFileLock(() async {
          await _ensureLoadedLocked();
          await _reloadFromDiskLocked();
          if (_values.remove(key) != null) {
            await _persistLocked();
          }
        });
      });

  @override
  Future<bool> containsKey({required String key}) =>
      _lock.synchronized(() async {
        await _ensureLoadedLocked();
        return _values.containsKey(key);
      });

  @override
  Future<Map<String, String>> readAll() => _lock.synchronized(() async {
        await _ensureLoadedLocked();
        return Map.of(_values);
      });

  Future<void> _ensureLoadedLocked() async {
    if (_loaded) return;

    final file = File(filePath);
    if (!await file.exists()) {
      // Nothing on disk yet: an authoritative empty store.
      _loaded = true;
      return;
    }

    // A read failure must NOT be treated as an empty store: marking `_loaded`
    // here would let the next write rewrite the file with only the new key,
    // destroying every other persisted value. Rethrowing instead keeps the
    // store unloaded, so the caller's durability gate disables writes until a
    // real read succeeds.
    final String raw = await readRaw(file);

    try {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      _values
        ..clear()
        ..addAll(decoded.cast<String, String>());
    } catch (e) {
      // Preserve the evidence, then start from a clean slate.
      final backupPath =
          '$filePath.corrupt-${DateTime.now().millisecondsSinceEpoch}';
      try {
        await file.rename(backupPath);
        areaKeyLog.e('FileJsonKv corrupt store backed aside as '
            '$backupPath: $e');
      } catch (renameError) {
        areaKeyLog.e('FileJsonKv corrupt store could not be backed aside: '
            '$renameError');
      }
      _values.clear();
    }
    _loaded = true;
  }

  /// Reads the whole backing file. Overridable so tests can simulate a
  /// transient IO failure (locked file, AV scan) that must not be mistaken
  /// for an empty store.
  @visibleForTesting
  Future<String> readRaw(File file) => file.readAsString();

  /// Re-reads the backing file and replaces the in-memory map with its content.
  ///
  /// Called under the cross-process write lock, right before a whole-file
  /// rewrite: without it, a second IRIS window would persist only the keys it
  /// had loaded and silently drop everything the other window wrote since.
  ///
  /// Both failure modes ABORT the pending write: an IO read failure and an
  /// unparsable payload are equally fatal here. Keeping the previous in-memory
  /// snapshot and rewriting the whole file from it (the old behaviour) dropped
  /// every key the other window had written since the failed reload, i.e. a
  /// torn/unreadable file turned one write into a silent deletion of another
  /// process's data. The caller keeps the failure (it already logs it), so the
  /// value simply does not persist this time.
  ///
  /// The initial load, by contrast, quarantines a genuinely corrupt file and
  /// starts empty — that path has no live write to protect (see
  /// [_ensureLoadedLocked]).
  Future<void> _reloadFromDiskLocked() async {
    final file = File(filePath);
    if (!await file.exists()) {
      _values.clear();
      return;
    }
    final String raw = await readRaw(file);
    final Map<String, String> next;
    try {
      final decoded = json.decode(raw);
      if (decoded is! Map) {
        throw const FormatException('kv store is not a JSON object');
      }
      // EAGER on purpose: `decoded.cast<String, String>()` is a lazy view, so a
      // non-string value would throw midway through `addAll` and leave [_values]
      // cleared and half-filled — a corrupt in-memory snapshot on top of the
      // failed read above.
      next = Map<String, String>.from(decoded);
    } catch (e) {
      areaKeyLog.e(
        'FileJsonKv reload failed, write aborted ($filePath): $e',
      );
      rethrow;
    }
    _values
      ..clear()
      ..addAll(next);
  }

  /// Runs [body] while holding an exclusive lock on the sibling `.lock` file.
  ///
  /// Several IRIS windows (processes) share this JSON store in portable mode;
  /// a read-modify-write must be serialized across them or one window's write
  /// drops the other's keys. The lock is released by the OS even on a crash.
  Future<T> _withFileLock<T>(Future<T> Function() body) async {
    final lockFile = File('$filePath.lock');
    RandomAccessFile? raf;
    try {
      await lockFile.parent.create(recursive: true);
      raf = await lockFile.open(mode: FileMode.append);
      await raf.lock(FileLock.blockingExclusive);
      return await body();
    } finally {
      if (raf != null) {
        try {
          await raf.unlock();
        } catch (_) {
          // Closing the handle releases the lock anyway.
        }
        await raf.close();
      }
    }
  }

  Future<void> _persistLocked() async {
    final tmp = File('$filePath.tmp');
    await tmp.writeAsString(json.encode(_values), flush: true);
    await tmp.rename(filePath);
  }

  /// Test isolation: drop in-memory cache so a fresh load re-reads disk.
  @visibleForTesting
  void resetCacheForTest() {
    _values.clear();
    _loaded = false;
  }
}
