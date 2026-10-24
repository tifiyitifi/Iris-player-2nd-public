import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/services/media_progress_claim.dart';
import 'package:iris/features/scenario_playback/playback/playback_progress.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_scope.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';

import 'helpers/sqlite3_loader.dart';

/// Two IRIS windows playing the SAME file must not fight over its one
/// `media_nodes` progress row:
///   * the first opener owns the row and persists normally;
///   * a later opener keeps its position in MEMORY only;
///   * when the owner releases (switch / close / window close), the waiting
///     window takes over and its position lands — even when it is behind.
class _FakeLockBackend implements ProgressClaimLockBackend {
  final Set<String> _held = <String>{};

  @override
  Future<bool> acquire(String id) async {
    if (_held.contains(id)) return false;
    _held.add(id);
    return true;
  }

  @override
  Future<void> release(String id) async => _held.remove(id);

  @override
  Future<void> releaseAll() async => _held.clear();
}

void main() {
  late _FakeLockBackend backend;
  late MediaProgressClaim firstWindow;
  late MediaProgressClaim secondWindow;

  const storageId = 's';
  const path = 'same.mp4';

  FileItem file() => const FileItem(
        storageId: storageId,
        storageType: StorageType.internal,
        name: 'same.mp4',
        uri: '/media/same.mp4',
        path: [path],
      );

  Future<int?> dbPosition() async {
    final node = await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: storageId,
      path: const [path],
    );
    return node?.maybeMap(
      file: (f) => f.playbackPositionMs,
      orElse: () => null,
    );
  }

  setUpAll(() async {
    ensureSqlite3Loaded();
    DbModule.init(AppDatabase(NativeDatabase.memory()));
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 'f:$storageId:$path',
      storageId: storageId,
      path: const [path],
      name: path,
      mediaType: MediaType.video,
    ));
  });

  setUp(() async {
    StorageScope.reset();
    backend = _FakeLockBackend();
    // The handover cases below assert an immediate takeover; the denial cache
    // (production: 2s) has its own tests.
    firstWindow = MediaProgressClaim(
      backend: backend,
      deniedRecheckInterval: Duration.zero,
    );
    secondWindow = MediaProgressClaim(
      backend: backend,
      deniedRecheckInterval: Duration.zero,
    );
    MediaProgressClaim.debugSetInstance(firstWindow);
    await DbModule.mediaNodeRepo.updatePlaybackProgress(
      storageId: storageId,
      path: path,
      positionMs: 40000,
      intent: ProgressWriteIntent.userSeek,
    );
  });

  tearDown(() {
    MediaProgressClaim.debugReset();
    StorageScope.reset();
  });

  test('a denied completion remembers the head, not the tail', () async {
    await firstWindow.claim(storageId: storageId, path: path);
    MediaProgressClaim.debugSetInstance(secondWindow);

    await DbModule.mediaNodeRepo.updatePlaybackProgress(
      storageId: storageId,
      path: path,
      positionMs: 59000,
      completed: true,
      writeTag: 'second-window-finish',
    );

    expect(await dbPosition(), 40000,
        reason: 'a denied write must not touch the owner\'s row');
    expect(
      secondWindow.memoryPosition(storageId: storageId, path: path),
      0,
      reason: 'a finished file restarts from the head in this window too',
    );
    expect(await readPlaybackProgress(file()), 0);
  });

  test('the later opener only keeps its progress in memory', () async {
    // Window 1 is playing: it owns the file.
    expect(
      await firstWindow.claim(storageId: storageId, path: path),
      ProgressClaimResult.owner,
    );

    // Window 2 opens the same file.
    MediaProgressClaim.debugSetInstance(secondWindow);
    await persistPlaybackProgress(
      file: file(),
      position: const Duration(seconds: 20),
      writeTag: 'second-window',
    );

    // The row still carries window 1's position; window 2 has its own.
    expect(await dbPosition(), 40000);
    expect(
      secondWindow.memoryPosition(storageId: storageId, path: path),
      20000,
    );
    // Its own reopen resumes from its own position.
    expect(await readPlaybackProgress(file()), 20000);
  });

  test('the owner keeps writing while the other window is memory-only',
      () async {
    await firstWindow.claim(storageId: storageId, path: path);
    MediaProgressClaim.debugSetInstance(secondWindow);
    await persistPlaybackProgress(
      file: file(),
      position: const Duration(seconds: 20),
    );

    MediaProgressClaim.debugSetInstance(firstWindow);
    await persistPlaybackProgress(
      file: file(),
      position: const Duration(seconds: 45),
    );

    expect(await dbPosition(), 45000);
    // Window 2's memory is untouched by the owner's write.
    expect(
      secondWindow.memoryPosition(storageId: storageId, path: path),
      20000,
    );
  });

  test('after the owner releases, the waiting window takes over without rewinding',
      () async {
    await firstWindow.claim(storageId: storageId, path: path);
    MediaProgressClaim.debugSetInstance(secondWindow);
    await persistPlaybackProgress(
      file: file(),
      position: const Duration(seconds: 30),
    );
    expect(await dbPosition(), 40000);

    // Owner switches away / closes the player.
    await firstWindow.release(
      MediaProgressClaim.keyFor(storageId: storageId, path: path),
    );

    // Next tick by the waiting window flushes its memory position. 30s is
    // BEHIND the stored 40s, so the takeover keeps the larger stored value:
    // a handover must not roll the resume point back.
    await persistPlaybackProgress(
      file: file(),
      position: const Duration(seconds: 30),
    );

    expect(await dbPosition(), 40000);
    expect(
      secondWindow.memoryPosition(storageId: storageId, path: path),
      isNull,
      reason: 'the row is authoritative again after the takeover flush',
    );
  });

  test('an explicit seek after takeover may still rewind', () async {
    await firstWindow.claim(storageId: storageId, path: path);
    MediaProgressClaim.debugSetInstance(secondWindow);
    // Denied tick: keeps 30s in memory.
    await persistPlaybackProgress(
      file: file(),
      position: const Duration(seconds: 30),
    );
    await firstWindow.release(
      MediaProgressClaim.keyFor(storageId: storageId, path: path),
    );

    // The user drags to the head in the waiting window: an explicit decision
    // must land verbatim even though the handover clamp would keep 40s.
    await persistPlaybackProgress(
      file: file(),
      position: Duration.zero,
      userSeekToHead: true,
      userSeek: true,
    );

    expect(await dbPosition(), 0);
  });

  test('a takeover write is never skipped by the head-window guard',
      () async {
    await firstWindow.claim(storageId: storageId, path: path);
    MediaProgressClaim.debugSetInstance(secondWindow);
    // Denied tick: the waiting window keeps 30s in memory.
    await persistPlaybackProgress(
      file: file(),
      position: const Duration(seconds: 30),
    );
    // The owner switches away / closes the player: the waiting window may
    // take over on its next tick.
    await firstWindow.release(
      MediaProgressClaim.keyFor(storageId: storageId, path: path),
    );

    // The first write after the handover is a PRE-SEEK HEAD sample (the open
    // -> duration-arrival window reports ~533ms over a large stored progress).
    expect(
      shouldGuardHeadWrite(
        existingPosMs: 40000,
        incomingPosMs: 533,
        durationMs: 100000,
      ),
      isTrue,
      reason: 'the sample really is a pre-seek head sample',
    );
    await persistPlaybackProgress(
      file: file(),
      position: const Duration(milliseconds: 533),
      durationMs: 100000,
    );

    // A takeover write is exempt from the head-window guard: the funnel's
    // takeover clamp keeps the stored 40s instead of rewinding to the head.
    expect(await dbPosition(), 40000,
        reason: 'a takeover must not rewind the stored progress');
    expect(
      secondWindow.memoryPosition(storageId: storageId, path: path),
      isNull,
      reason: 'the row is authoritative again after the takeover flush',
    );
  });

  test('takeover intent is never blocked by the backward-write guard', () {
    expect(
      shouldBlockFunnelWrite(
        existingPosMs: 40000,
        incomingPosMs: 30000,
        durationMs: 100000,
        completed: null,
        intent: ProgressWriteIntent.takeover,
      ),
      isFalse,
    );
    expect(
      shouldBlockFunnelWrite(
        existingPosMs: 40000,
        incomingPosMs: 30000,
        durationMs: 100000,
        completed: null,
        intent: ProgressWriteIntent.live,
      ),
      isTrue,
    );
  });
}
