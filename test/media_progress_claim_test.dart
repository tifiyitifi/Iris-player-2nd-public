import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/services/media_progress_claim.dart';
import 'package:iris/models/db/storage_scope.dart';
import 'package:path/path.dart' as p;

/// In-memory stand-in for the OS lock: one winner per id, shared by every
/// [MediaProgressClaim] that is handed the same backend (two "instances").
class _FakeLockBackend implements ProgressClaimLockBackend {
  final Set<String> _held = <String>{};
  int acquireCalls = 0;

  @override
  Future<bool> acquire(String id) async {
    acquireCalls++;
    if (_held.contains(id)) return false;
    _held.add(id);
    return true;
  }

  @override
  Future<void> release(String id) async {
    _held.remove(id);
  }

  @override
  Future<void> releaseAll() async {
    _held.clear();
  }
}

void main() {
  setUp(StorageScope.reset);
  tearDown(StorageScope.reset);

  group('keyFor', () {
    test('slash conventions resolve to one claim', () {
      expect(
        MediaProgressClaim.keyFor(storageId: 's', path: '/a/b.mp4'),
        MediaProgressClaim.keyFor(storageId: 's', path: 'a/b.mp4'),
      );
    });

    test('linked storage entries share the data scope key', () {
      StorageScope.resolver = (id) => id == 'b' ? 'a' : id;
      expect(
        MediaProgressClaim.keyFor(storageId: 'a', path: 'x.mp4'),
        MediaProgressClaim.keyFor(storageId: 'b', path: 'x.mp4'),
      );
    });

    test('different files differ', () {
      expect(
        MediaProgressClaim.keyFor(storageId: 's', path: 'x.mp4'),
        isNot(MediaProgressClaim.keyFor(storageId: 's', path: 'y.mp4')),
      );
    });
  });

  group('claim lifecycle', () {
    late _FakeLockBackend backend;
    late MediaProgressClaim first;
    late MediaProgressClaim second;

    setUp(() {
      backend = _FakeLockBackend();
      // These cases assert the immediate handover contract; the denial cache
      // (production: 2s) is exercised separately below.
      first = MediaProgressClaim(
        backend: backend,
        deniedRecheckInterval: Duration.zero,
      );
      second = MediaProgressClaim(
        backend: backend,
        deniedRecheckInterval: Duration.zero,
      );
    });

    test('first opener owns, later opener is denied', () async {
      expect(
        await first.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.owner,
      );
      expect(
        await second.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.denied,
      );
      expect(second.deniedKeys, isNotEmpty);
    });

    test('denied instance keeps its position in memory only', () async {
      await first.claim(storageId: 's', path: 'x.mp4');
      await second.claim(storageId: 's', path: 'x.mp4');
      second.remember(
        storageId: 's',
        path: 'x.mp4',
        positionMs: 20000,
        completed: false,
      );
      expect(
        second.memoryPosition(storageId: 's', path: 'x.mp4'),
        20000,
      );
      expect(
        first.memoryPosition(storageId: 's', path: 'x.mp4'),
        isNull,
      );
    });

    test('owner release hands over as a takeover, memory survives until flush',
        () async {
      final key = MediaProgressClaim.keyFor(storageId: 's', path: 'x.mp4');
      await first.claim(storageId: 's', path: 'x.mp4');
      await second.claim(storageId: 's', path: 'x.mp4');
      second.remember(storageId: 's', path: 'x.mp4', positionMs: 30000);

      // Still owned: no takeover.
      expect(
        await second.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.denied,
      );

      await first.release(key);
      expect(
        await second.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.takeover,
      );
      expect(second.memoryPosition(storageId: 's', path: 'x.mp4'), 30000);

      second.markPersisted(key);
      expect(second.memoryPosition(storageId: 's', path: 'x.mp4'), isNull);
      expect(
        await second.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.owner,
      );
    });

    test('releaseAll frees every file', () async {
      await first.claim(storageId: 's', path: 'x.mp4');
      await first.claim(storageId: 's', path: 'y.mp4');
      await first.releaseAll();
      expect(
        await second.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.owner,
      );
      expect(
        await second.claim(storageId: 's', path: 'y.mp4'),
        ProgressClaimResult.owner,
      );
    });

    test('two players of one instance hold the claim until the last leaves',
        () async {
      final key = MediaProgressClaim.keyFor(storageId: 's', path: 'x.mp4');
      // Main player + 副音 both showing the same file.
      await first.track(storageId: 's', path: 'x.mp4');
      await first.track(storageId: 's', path: 'x.mp4');

      await first.untrack(key);
      expect(
        await second.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.denied,
        reason: 'the other player still shows the file',
      );

      await first.untrack(key);
      expect(
        await second.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.owner,
      );
    });

    test('a denied instance keeps its memory position after switching away',
        () async {
      final key = MediaProgressClaim.keyFor(storageId: 's', path: 'x.mp4');
      await first.track(storageId: 's', path: 'x.mp4');
      await second.track(storageId: 's', path: 'x.mp4');
      second.remember(storageId: 's', path: 'x.mp4', positionMs: 5000);

      await second.untrack(key);
      expect(
        second.memoryPosition(storageId: 's', path: 'x.mp4'),
        5000,
        reason: 'memory-only progress must survive leaving the file',
      );
    });

    test('a denied file does not retry the OS lock on every tick', () async {
      final claim = MediaProgressClaim(
        backend: backend,
        deniedRecheckInterval: const Duration(minutes: 1),
      );
      await first.claim(storageId: 's', path: 'x.mp4');
      expect(
        await claim.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.denied,
      );
      final callsAfterFirstDenial = backend.acquireCalls;
      expect(
        await claim.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.denied,
      );
      expect(
        backend.acquireCalls,
        callsAfterFirstDenial,
        reason: 'a cached denial must not touch the lock file again',
      );
    });

    test('a denied file re-checks after the interval and takes over', () async {
      final claim = MediaProgressClaim(
        backend: backend,
        deniedRecheckInterval: Duration.zero,
      );
      await first.claim(storageId: 's', path: 'x.mp4');
      expect(
        await claim.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.denied,
      );
      await first.release(
        MediaProgressClaim.keyFor(storageId: 's', path: 'x.mp4'),
      );
      expect(
        await claim.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.owner,
      );
    });

    test('release waits for an in-flight progress write', () async {
      final key = MediaProgressClaim.keyFor(storageId: 's', path: 'x.mp4');
      await first.claim(storageId: 's', path: 'x.mp4');

      final write = first.beginWrite(key);
      var released = false;
      final releaseFuture = first.release(key).then((_) => released = true);
      await Future<void>.delayed(Duration.zero);
      expect(released, isFalse,
          reason: 'the final save has not landed yet, so the lock must stay');

      first.endWrite(key, write);
      await releaseFuture;
      expect(released, isTrue);
      expect(
        await second.claim(storageId: 's', path: 'x.mp4'),
        ProgressClaimResult.owner,
      );
    });
  });

  group('file lock backend', () {
    test('the first process lock wins and release hands over', () async {
      final dir = await Directory.systemTemp.createTemp('iris_claims_');
      addTearDown(() => dir.delete(recursive: true));
      final a = FileClaimLockBackend(dirPath: dir.path);
      final b = FileClaimLockBackend(dirPath: dir.path);

      expect(await a.acquire('hash1'), isTrue);
      expect(await b.acquire('hash1'), isFalse);
      await a.release('hash1');
      expect(await b.acquire('hash1'), isTrue);
      await b.releaseAll();
    }, skip: !Platform.isWindows);

    test('stale claim lock files are swept, recent ones kept', () async {
      final dir = await Directory.systemTemp.createTemp('iris_claim_sweep_');
      addTearDown(() => dir.delete(recursive: true));
      final stale = File(p.join(dir.path, 'old.lock'))
        ..writeAsStringSync('');
      final fresh = File(p.join(dir.path, 'new.lock'))
        ..writeAsStringSync('');
      // A non-lock file must never be touched.
      final other = File(p.join(dir.path, 'keep.txt'))
        ..writeAsStringSync('');
      await stale.setLastModified(
        DateTime.now().subtract(const Duration(days: 60)),
      );
      await other.setLastModified(
        DateTime.now().subtract(const Duration(days: 60)),
      );

      await MediaProgressClaim.sweepStaleLocks(dir.path);

      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(other.existsSync(), isTrue);
    });
  });
}
