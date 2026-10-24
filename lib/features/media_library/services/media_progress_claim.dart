import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:iris/models/db/storage_scope.dart';
import 'package:iris/utils/app_instance.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:path/path.dart' as p;

final _log = AreaKeyLog(LogKeys.player);

/// Result of asking for the per-file progress ownership.
enum ProgressClaimResult {
  /// This instance already owns the file (or just took it with no prior
  /// memory state): persist to the database as usual.
  owner,

  /// This instance just took ownership from a previously denied state. The
  /// first write must use the `takeover` write intent: it bypasses the
  /// backward-write guard, but a LIVE takeover sample may still only move the
  /// stored position forward (the waiting window may have played on from an
  /// older resume point). An explicit user rewind stays a `userSeek`.
  takeover,

  /// Another IRIS instance owns the file: keep the progress in memory only.
  denied,
}

/// Per-file playback-progress ownership across IRIS processes.
///
/// WHY: two windows may play the SAME file. `media_nodes.playback_position_ms`
/// is one global column, so without ownership both windows would overwrite each
/// other's progress (last writer wins) and the resume point would jump around.
/// Rule: the FIRST instance to open the file wins and is the only one allowed
/// to write its progress columns; a later opener keeps its position in memory
/// ([remember]/[memoryPosition]) and never touches the row.
///
/// Handover: when the owner stops playing the file (switches away, closes the
/// player or the window), it [release]s the claim; the waiting instance's next
/// progress tick acquires it and returns [ProgressClaimResult.takeover], then
/// flushes its position with [ProgressWriteIntent.takeover]. A live takeover
/// sample is clamped to the stored maximum (a handover must not rewind the
/// resume point); an explicit user seek still writes verbatim.
///
/// The claim is a per-file OS file lock (`<data>/instances/claims/<sha1>.lock`).
/// OS locks are released by the kernel when a process dies, so a crash never
/// leaves a file permanently claimed — no heartbeat table, no stale sweep.
///
/// Single-instance platforms (and unit tests) run with the default
/// [AlwaysOwnerClaimLockBackend], where every claim succeeds: behavior is
/// exactly the pre-multi-instance one.
class MediaProgressClaim {
  MediaProgressClaim({
    required this.backend,
    this.deniedRecheckInterval = const Duration(seconds: 2),
  });

  /// Active instance-level policy. Replaced at startup on desktop with a
  /// file-backed implementation; defaults to "everyone owns everything".
  static MediaProgressClaim instance = MediaProgressClaim(
    backend: const AlwaysOwnerClaimLockBackend(),
  );

  final ProgressClaimLockBackend backend;

  /// How long a denied file may skip the OS-lock re-check.
  ///
  /// A `denied` progress tick used to open + lock-fail + close the claim file
  /// on EVERY write. Re-checking at most this often removes that per-tick IO
  /// while keeping a handover responsive (the waiting window re-checks on its
  /// next tick, and its position stays in memory until then).
  final Duration deniedRecheckInterval;

  /// Files this instance currently owns.
  final Set<String> _owned = <String>{};

  /// Files this instance was denied and must keep in memory, with the time of
  /// the last failed acquisition (see [deniedRecheckInterval]).
  final Map<String, DateTime> _denied = <String, DateTime>{};

  /// Memory-only progress of files owned by another window, keyed by
  /// [keyFor]. Cleared when ownership is taken over and persisted.
  final Map<String, _MemoryProgress> _memory = <String, _MemoryProgress>{};

  /// Keys acquired but not yet flushed with a takeover write.
  final Set<String> _pendingTakeover = <String>{};

  /// How many players of THIS instance are showing a key (main + 副音 can both
  /// open the same file). The claim is released only when the last one leaves.
  final Map<String, int> _tracked = <String, int>{};

  /// DB writes currently in flight per key.
  ///
  /// A leaving file's final save is async; releasing its claim first would let
  /// another window take over and demote that save to memory-only. [release]
  /// therefore waits for an in-flight write to finish instead of relying on a
  /// fixed delay alone.
  final Map<String, Set<Completer<void>>> _pendingWrites =
      <String, Set<Completer<void>>>{};

  /// Canonical key of one file's progress claim.
  ///
  /// Uses the same storage-relative canonical form as the write funnel
  /// (`canonicalDbPath`) plus the data scope, so two entries linked to one
  /// scope resolve to the SAME claim (they share one `media_nodes` row).
  /// Deliberately independent of the DB path resolution: producers that pass
  /// different slash shapes still agree.
  static String keyFor({required String storageId, required String path}) =>
      '${StorageScope.of(storageId)}:${canonicalDbPath(path)}';

  /// Builds the desktop policy: claims live under the app data root (or the
  /// portable `userdata` root). Degrades to "always owner" when the directory
  /// cannot be resolved, so a broken path never blocks playback.
  static Future<MediaProgressClaim> createFileBacked() async {
    try {
      final String dir = await AppInstance.instancesDirPath('claims');
      _log.i('progress claims dir: $dir');
      // One lock file is minted per file ever played and never reused: sweep
      // the ones nobody touched for a month so the directory cannot grow
      // forever. Best-effort and off the critical path.
      unawaited(sweepStaleLocks(dir));
      return MediaProgressClaim(backend: FileClaimLockBackend(dirPath: dir));
    } catch (e) {
      _log.w('progress claims disabled (no usable dir): $e');
      return MediaProgressClaim(backend: const AlwaysOwnerClaimLockBackend());
    }
  }

  /// Deletes claim lock files untouched for [olderThan].
  ///
  /// WHY: `<claims>/<sha1>.lock` is created per file and never removed on
  /// release (the OS lock is what matters, not the file). A file held by a
  /// LIVE window cannot be deleted on Windows, so a failed delete is expected
  /// and skipped.
  static Future<void> sweepStaleLocks(
    String dirPath, {
    Duration olderThan = const Duration(days: 30),
  }) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().subtract(olderThan);
      var removed = 0;
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is! File || !entry.path.endsWith('.lock')) continue;
        try {
          final stat = await entry.stat();
          if (stat.modified.isAfter(cutoff)) continue;
          await entry.delete();
          removed++;
        } catch (_) {
          // Held by a live window: leave it for a later sweep.
        }
      }
      if (removed > 0) {
        _log.i('swept $removed stale progress claim lock(s)');
      }
    } catch (e) {
      _log.w('progress claim lock sweep failed: $e');
    }
  }

  /// Claims (or re-confirms) ownership of one file.
  Future<ProgressClaimResult> claim({
    required String storageId,
    required String path,
  }) async {
    final key = keyFor(storageId: storageId, path: path);
    if (_owned.contains(key)) {
      return _pendingTakeover.contains(key)
          ? ProgressClaimResult.takeover
          : ProgressClaimResult.owner;
    }
    // A denied file is re-checked at most once per [deniedRecheckInterval]:
    // its progress ticks are memory-only, so retrying the OS lock on every
    // tick is pure IO.
    final DateTime? deniedAt = _denied[key];
    if (deniedAt != null &&
        DateTime.now().difference(deniedAt) < deniedRecheckInterval) {
      return ProgressClaimResult.denied;
    }
    final acquired = await backend.acquire(_lockId(key));
    if (!acquired) {
      _denied[key] = DateTime.now();
      return ProgressClaimResult.denied;
    }
    _owned.add(key);
    _denied.remove(key);
    if (_memory.containsKey(key)) {
      // This instance kept a position while another window owned the file:
      // the first write after acquiring must be able to land backwards.
      _pendingTakeover.add(key);
      _log.i('progress claim taken over: $key');
      return ProgressClaimResult.takeover;
    }
    return ProgressClaimResult.owner;
  }

  /// Releases one file (switched away / player closed). Other instances may
  /// take over from this point.
  ///
  /// Waits for an in-flight progress write first: the leaving file's final
  /// save is async, and handing the lock over before it lands would make that
  /// save memory-only in the other window's row.
  Future<void> release(String key) async {
    await awaitPendingWrites(key);
    _owned.remove(key);
    _denied.remove(key);
    _pendingTakeover.remove(key);
    _tracked.remove(key);
    _memory.remove(key);
    await backend.release(_lockId(key));
  }

  /// Registers a DB write for [key] as in flight; always paired with
  /// [endWrite] in a `finally`.
  Completer<void> beginWrite(String key) {
    final completer = Completer<void>();
    (_pendingWrites[key] ??= <Completer<void>>{}).add(completer);
    return completer;
  }

  /// Marks the write registered by [beginWrite] as finished.
  void endWrite(String key, Completer<void> completer) {
    final pending = _pendingWrites[key];
    if (pending != null) {
      pending.remove(completer);
      if (pending.isEmpty) _pendingWrites.remove(key);
    }
    if (!completer.isCompleted) completer.complete();
  }

  /// Waits for every write in flight for [key].
  ///
  /// The timeout is a safety valve: a hung DB write must not keep the claim
  /// (and the window's shutdown) hostage forever.
  Future<void> awaitPendingWrites(
    String key, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final pending = _pendingWrites[key];
    if (pending == null || pending.isEmpty) return;
    await Future.wait([
      for (final completer in pending.toList())
        completer.future.timeout(timeout, onTimeout: () {}),
    ]);
  }

  /// A player of this instance started showing [storageId]/[path]. Unlike a
  /// bare [claim] (used by every progress write), a track is REFCOUNTED so the
  /// main player and 副音 opening the same file cannot release it out from
  /// under each other.
  Future<ProgressClaimResult> track({
    required String storageId,
    required String path,
  }) async {
    final result = await claim(storageId: storageId, path: path);
    if (result != ProgressClaimResult.denied) {
      final key = keyFor(storageId: storageId, path: path);
      _tracked[key] = (_tracked[key] ?? 0) + 1;
    }
    return result;
  }

  /// One player stopped showing [key]; ownership is handed over only when the
  /// last tracker leaves.
  ///
  /// A DENIED (memory-only) key is left alone on purpose: the position this
  /// instance accumulated while another window owned the file stays available
  /// if the user comes back to it.
  Future<void> untrack(String key) async {
    final count = _tracked[key] ?? 0;
    if (count > 1) {
      _tracked[key] = count - 1;
      return;
    }
    _tracked.remove(key);
    if (!_owned.contains(key)) return;
    await release(key);
  }

  /// Releases every claim held by this instance (window close).
  Future<void> releaseAll() async {
    // Window close: let every final progress save land before unlocking, or a
    // waiting window would take over and demote it to a memory-only write.
    await Future.wait([
      for (final key in _pendingWrites.keys.toList()) awaitPendingWrites(key),
    ]);
    _owned.clear();
    _denied.clear();
    _pendingTakeover.clear();
    _tracked.clear();
    _memory.clear();
    await backend.releaseAll();
  }

  /// Stores the position of a file this instance does NOT own. Memory only:
  /// the database row belongs to the owning window.
  void remember({
    required String storageId,
    required String path,
    int? positionMs,
    bool? completed,
  }) {
    if (positionMs == null && completed == null) return;
    final key = keyFor(storageId: storageId, path: path);
    if (_owned.contains(key)) return;
    final previous = _memory[key];
    _memory[key] = _MemoryProgress(
      positionMs: positionMs ?? previous?.positionMs,
      completed: completed ?? previous?.completed,
    );
  }

  /// Memory-only resume position of [storageId]/[path], or null.
  int? memoryPosition({required String storageId, required String path}) =>
      _memory[keyFor(storageId: storageId, path: path)]?.positionMs;

  /// Memory-only completed marker of [storageId]/[path], or null.
  bool? memoryCompleted({required String storageId, required String path}) =>
      _memory[keyFor(storageId: storageId, path: path)]?.completed;

  /// Called by the write funnel after a takeover write landed: the database is
  /// authoritative again for this file.
  void markPersisted(String key) {
    _pendingTakeover.remove(key);
    _memory.remove(key);
  }

  /// Files this instance was denied (diagnostics/tests).
  @visibleForTesting
  Set<String> get deniedKeys => Set.unmodifiable(_denied.keys);

  static String _lockId(String key) => sha1.convert(utf8.encode(key)).toString();

  @visibleForTesting
  static void debugSetInstance(MediaProgressClaim claim) {
    instance = claim;
  }

  @visibleForTesting
  static void debugReset() {
    instance = MediaProgressClaim(
      backend: const AlwaysOwnerClaimLockBackend(),
    );
  }
}

class _MemoryProgress {
  const _MemoryProgress({this.positionMs, this.completed});

  final int? positionMs;
  final bool? completed;
}

/// Lock primitive behind [MediaProgressClaim] (injectable for tests).
abstract interface class ProgressClaimLockBackend {
  /// Non-blocking: true when this holder now owns [id].
  Future<bool> acquire(String id);

  Future<void> release(String id);

  Future<void> releaseAll();
}

/// Single-instance behavior: every claim succeeds.
class AlwaysOwnerClaimLockBackend implements ProgressClaimLockBackend {
  const AlwaysOwnerClaimLockBackend();

  @override
  Future<bool> acquire(String id) async => true;

  @override
  Future<void> release(String id) async {}

  @override
  Future<void> releaseAll() async {}
}

/// OS file locks under one directory: the first process to lock `<id>.lock`
/// owns it until it unlocks (or dies).
class FileClaimLockBackend implements ProgressClaimLockBackend {
  FileClaimLockBackend({required this.dirPath});

  final String dirPath;
  final Map<String, RandomAccessFile> _held = <String, RandomAccessFile>{};

  @override
  Future<bool> acquire(String id) async {
    if (_held.containsKey(id)) return true;
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      // Append mode: creates the file without truncating a lock another
      // process may be holding.
      final raf = await File(p.join(dirPath, '$id.lock'))
          .open(mode: FileMode.append);
      try {
        await raf.lock(FileLock.exclusive);
      } on FileSystemException {
        await raf.close();
        return false;
      }
      _held[id] = raf;
      return true;
    } catch (e) {
      // Fail open: an unexpected IO problem must never stop progress saving.
      _log.w('progress claim acquire failed ($id): $e');
      return true;
    }
  }

  @override
  Future<void> release(String id) async {
    final raf = _held.remove(id);
    if (raf == null) return;
    try {
      await raf.unlock();
    } catch (_) {
      // The handle is closed below; the OS drops the lock either way.
    }
    await raf.close();
  }

  @override
  Future<void> releaseAll() async {
    final ids = _held.keys.toList();
    for (final id in ids) {
      await release(id);
    }
  }
}
