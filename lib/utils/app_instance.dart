import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:iris/utils/app_paths.dart';
import 'package:iris/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = AreaKeyLog(LogKeys.legacyUtil);

/// Identity of THIS IRIS process among several simultaneously running windows.
///
/// WHY: session state (play queue, history, active scenario) must not be shared
/// by two windows — whichever writes last would win and the other window would
/// restore someone else's queue on the next launch. Every instance therefore
/// owns a numbered SLOT and scopes its session keys with [sessionPrefix]:
///
/// - slot 1 (the first/only window) keeps the historical unprefixed keys, so
///   existing users' queue/history are untouched;
/// - slot 2+ reads/writes `s2.`-prefixed keys and starts with an empty session.
///
/// The slot is an OS file lock (`<data>/instances/slot-<n>.lock`), so a crashed
/// window releases it automatically and the next launch reuses the lowest free
/// slot. If every slot is taken (or the slots directory itself is unusable), the
/// instance still starts — but with a THROWAWAY session: it is neither primary
/// nor scoped to a numbered slot, and its session store lives in memory only.
/// Falling back to slot 1 used to make the ninth window silently share (and
/// overwrite) the primary's queue, history and active scenario.
abstract final class AppInstance {
  static const int maxSlots = 8;

  static int _slot = 1;
  static bool _ephemeral = false;
  static InstanceSlotLock? _lock;

  /// 1-based slot of this process.
  static int get slot => _slot;

  /// True for the first/only window (historical behavior, unprefixed keys).
  static bool get isPrimary => !_ephemeral && _slot == 1;

  /// True when this process could not claim a slot (all slots busy, or the
  /// slots directory is unusable) and got a throwaway session.
  ///
  /// Such a window must never write shared config from its snapshot and its
  /// session keys never reach the disk (see `getSessionKvStore`).
  static bool get isEphemeral => _ephemeral;

  /// Prefix for session-scoped KV keys ('' for the primary instance).
  static String get sessionPrefix =>
      _ephemeral ? 'ephemeral.' : (_slot == 1 ? '' : 's$_slot.');

  /// Human-readable slot marker for window titles and workspace names.
  static String get slotLabel => _ephemeral ? 'tmp' : '$_slot';

  /// Resolves the slots directory: the portable `userdata` root when active,
  /// otherwise the app support dir (same root the progress claims use).
  static Future<String> instancesDirPath([String sub = '']) async {
    final PortableLayout? layout = AppPaths.layout;
    final String root = AppPaths.isPortable && layout != null
        ? p.join(layout.rootPath, 'instances')
        : p.join((await getApplicationSupportDirectory()).path, 'instances');
    return sub.isEmpty ? root : p.join(root, sub);
  }

  /// Claims the lowest free slot. MUST run after [AppPaths.init] (portable mode
  /// decides the directory) and before any store is constructed.
  static Future<void> init({
    @visibleForTesting String? dirOverride,
    int slots = maxSlots,
  }) async {
    if (_lock != null || _ephemeral) return;
    try {
      final String dirPath = dirOverride ?? await instancesDirPath();
      final InstanceSlotLock? lock = await InstanceSlotLock.acquire(
        dirPath: dirPath,
        maxSlots: slots,
      );
      if (lock == null) {
        // EVERY slot is taken. Sharing slot 1 would let this window's queue /
        // history / active scenario overwrite the primary's; a throwaway in-
        // memory session keeps the window usable without touching disk.
        _ephemeral = true;
        _log.w('all $slots instance slots busy; running with a throwaway '
            '(non-persisted) session');
        return;
      }
      _lock = lock;
      _slot = lock.slot;
      _log.i('IRIS instance slot $_slot (session prefix "$sessionPrefix")');
    } catch (e) {
      // Fail open WITHOUT adopting an identity: a broken slot directory must
      // never block startup, but it must not fall back to slot 1 either — a
      // second window would then share the primary's session keys and both
      // would persist the same snapshot. Take the throwaway session instead
      // (same contract as "every slot is busy" above).
      _ephemeral = true;
      _log.w('instance slot resolution failed; running with a throwaway '
          '(non-persisted) session: $e');
    }
  }

  /// Hands the slot back (window close). The OS does this on process exit too;
  /// releasing early lets a new window take the lowest slot immediately.
  static Future<void> release() async {
    final InstanceSlotLock? lock = _lock;
    _lock = null;
    await lock?.release();
  }

  @visibleForTesting
  static void debugSetSlot(int slot) {
    _ephemeral = false;
    _slot = slot < 1 ? 1 : slot;
  }

  @visibleForTesting
  static void debugSetEphemeral(bool value) {
    _ephemeral = value;
    if (value) _slot = 1;
  }

  @visibleForTesting
  static void debugReset() {
    _lock = null;
    _ephemeral = false;
    _slot = 1;
  }
}

/// One held slot: an exclusively locked `<dir>/slot-<n>.lock` file.
class InstanceSlotLock {  InstanceSlotLock._(this.slot, this._file);

  final int slot;
  final RandomAccessFile _file;

  /// Locks the lowest free slot, or null when every slot is busy.
  ///
  /// A single unusable slot file (locked by another live window, or one this
  /// process cannot open at all — AV scanner, permissions) skips ONLY that
  /// slot: aborting the loop would drop the window into the throwaway session
  /// while slots further down the table are still free.
  static Future<InstanceSlotLock?> acquire({
    required String dirPath,
    int maxSlots = AppInstance.maxSlots,
  }) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    for (var slot = 1; slot <= maxSlots; slot++) {
      RandomAccessFile? raf;
      try {
        // Append mode: creates the file without truncating a lock another
        // process may be holding.
        raf = await File(p.join(dirPath, 'slot-$slot.lock'))
            .open(mode: FileMode.append);
        await raf.lock(FileLock.exclusive);
        return InstanceSlotLock._(slot, raf);
      } on FileSystemException catch (e) {
        if (raf == null) {
          // Cannot even open the file: a per-slot problem, not contention.
          _log.w('instance slot $slot lock file unopenable, trying the next '
              'one: $e');
        }
        // Contention: another live window owns this slot (expected, silent).
        await _closeQuietly(raf);
        continue;
      } catch (_) {
        // Never leak the handle on an unexpected failure; fail open to the
        // caller (AppInstance.init takes the throwaway session).
        await _closeQuietly(raf);
        rethrow;
      }
    }
    return null;
  }

  Future<void> release() async {
    try {
      await _file.unlock();
    } catch (_) {
      // Closing below drops the lock anyway.
    }
    await _file.close();
  }

  static Future<void> _closeQuietly(RandomAccessFile? raf) async {
    if (raf == null) return;
    try {
      await raf.close();
    } catch (_) {
      // Closing is best-effort: the failure that brought us here already
      // decided this slot is unusable.
    }
  }
}

/// A single cross-process exclusive lock on one file (e.g. the scan lease).
///
/// Same primitive as the slot locks, without the numbering: the first process
/// to lock the file owns it until it unlocks or dies. Unexpected IO failures are
/// thrown so the caller can fail OPEN (never block work because a directory is
/// missing) while a genuine contention returns null.
class AppFileLock {
  AppFileLock._(this._file);

  final RandomAccessFile _file;

  static Future<AppFileLock?> acquire(String filePath) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    // Append mode: creates the file without truncating a lock another process
    // may be holding.
    final raf = await file.open(mode: FileMode.append);
    try {
      await raf.lock(FileLock.exclusive);
    } on FileSystemException {
      await raf.close();
      return null;
    }
    return AppFileLock._(raf);
  }

  Future<void> release() async {
    try {
      await _file.unlock();
    } catch (_) {
      // Closing below drops the lock anyway.
    }
    await _file.close();
  }
}

/// Base for one named cross-window lease (scan, update, …).
///
/// Holds at most one [AppFileLock] and is safe to call from any window:
/// - disabled (`lockPath == null`): every [acquire] succeeds (single-instance
///   platforms, unit tests);
/// - a broken lock directory fails OPEN — a missing folder must never block the
///   feature;
/// - re-entrant inside one process (batch work acquires/releases per item).
class AppLease {
  AppLease({required this.lockPath});

  /// No-op lease: every request succeeds.
  AppLease.disabled() : lockPath = null;

  /// Absolute path of the lock file; null when the lease is disabled.
  final String? lockPath;

  AppFileLock? _held;

  bool get isHeld => _held != null;

  /// True when this window may run the leased work. A false result means
  /// another LIVE window holds the lease.
  Future<bool> acquire() async {
    final String? path = lockPath;
    if (path == null) return true;
    if (_held != null) return true;
    try {
      final AppFileLock? lock = await AppFileLock.acquire(path);
      if (lock == null) return false;
      _held = lock;
      return true;
    } catch (_) {
      // Fail open: a broken lock directory must never block the work.
      return true;
    }
  }

  Future<void> release() async {
    final AppFileLock? lock = _held;
    _held = null;
    await lock?.release();
  }
}
