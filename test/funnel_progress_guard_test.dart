import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/playback/playback_progress.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';

import 'helpers/sqlite3_loader.dart';

/// RED tests for the funnel-level progress-write guard.
///
/// The 第8次 log proved the resume READ path works every time; the loss
/// happens on the WRITE side — some caller reduces a stored 42833ms row to
/// 0/633ms and the next open legitimately starts from the head. The hook
/// guards (persistPlaybackProgress) only cover hook callers; direct
/// `updatePlaybackProgress` writers bypass them. This guard moves the same
/// value-pattern protection into the single write funnel so NO caller can
/// clobber a large stored progress with a small/head sample unless it
/// declares an explicit non-live intent.
void main() {
  setUpAll(() async {
    ensureSqlite3Loaded();
    DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  FileItem file() => FileItem(
        storageId: 's',
        storageType: StorageType.internal,
        name: 'guard.mp4',
        uri: '/storage/guard.mp4',
        path: const ['guard.mp4'],
      );

  Future<void> seedNode({int? positionMs, int? durationMs}) async {
    await DbModule.mediaNodesDao.deleteNode('s', 'guard.mp4');
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 'f:s:guard.mp4',
      storageId: 's',
      path: const ['guard.mp4'],
      name: 'guard.mp4',
      mediaType: MediaType.video,
    ));
    if (durationMs != null) {
      await DbModule.mediaNodeRepo.updateFileMediaInfo(
        storageId: 's',
        path: 'guard.mp4',
        durationMs: durationMs,
      );
    }
    if (positionMs != null) {
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'guard.mp4',
        positionMs: positionMs,
      );
    }
  }

  group('shouldBlockFunnelWrite (pure decision)', () {
    test('blocks a live small head over large stored progress', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 42833,
          incomingPosMs: 633,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isTrue,
      );
    });

    test('blocks a live exact-0 over large stored progress', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 42833,
          incomingPosMs: 0,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isTrue,
      );
    });

    test('lets a live mid-file write through', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 42833,
          incomingPosMs: 45000,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isFalse,
      );
    });

    test('never blocks a targeted (VM pre-write) intent', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 42833,
          incomingPosMs: 0,
          durationMs: 72661,
          completed: false,
          intent: ProgressWriteIntent.targeted,
        ),
        isFalse,
      );
    });

    test('never blocks an explicit clear (completed:true)', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 42833,
          incomingPosMs: 0,
          durationMs: 72661,
          completed: true,
          intent: ProgressWriteIntent.live,
        ),
        isFalse,
      );
    });

    test('never blocks a user seek back to the head', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 42833,
          incomingPosMs: 0,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.userSeek,
        ),
        isFalse,
      );
    });

    test('lets live writes through when no progress is stored', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: null,
          incomingPosMs: 633,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isFalse,
      );
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 0,
          incomingPosMs: 633,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isFalse,
      );
    });

    // ── Monotonic ("greater-than") lock: natural writes may never regress ──
    // Only explicit user intents (slider tap/drag, rewind) may lower the
    // stored value; a small stored row is protected exactly like a large one.

    test('blocks a live regression over a SMALL stored position', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 8000,
          incomingPosMs: 633,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isTrue,
      );
    });

    test('blocks a live moderate regression (large → medium)', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 60000,
          incomingPosMs: 20000,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isTrue,
      );
    });

    test('lets a live forward write through at any size', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 5000,
          incomingPosMs: 6000,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isFalse,
      );
    });

    test('tolerates jitter within the backward tolerance', () {
      // 10000 -> 8500 (regress 1500 < 2000) allowed.
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 10000,
          incomingPosMs: 8500,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isFalse,
      );
      // 10000 -> 7000 (regress 3000 > 2000) blocked.
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 10000,
          incomingPosMs: 7000,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isTrue,
      );
    });

    test('stale stored position beyond duration is not a regression', () {
      // The media was re-encoded shorter; the stored 60000 cannot apply.
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 60000,
          incomingPosMs: 1000,
          durationMs: 30000,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isFalse,
      );
    });

    test('user seek may lower the stored value', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 60000,
          incomingPosMs: 20000,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.userSeek,
        ),
        isFalse,
      );
    });

    test('null incoming position never blocks (column untouched)', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 42833,
          incomingPosMs: null,
          durationMs: 72661,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isFalse,
      );
    });

    test('blocks a live decrease regardless of the file duration', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 42833,
          incomingPosMs: 633,
          durationMs: 120000,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isTrue,
      );
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 42833,
          incomingPosMs: 2500,
          durationMs: 120000,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isTrue,
      );
    });

    test('blocks a live decrease with unknown duration', () {
      expect(
        shouldBlockFunnelWrite(
          existingPosMs: 42833,
          incomingPosMs: 633,
          durationMs: null,
          completed: null,
          intent: ProgressWriteIntent.live,
        ),
        isTrue,
      );
    });
  });

  group('resolveTakeoverPositionMs (pure decision)', () {
    test('a live takeover may not rewind the stored position', () {
      expect(
        resolveTakeoverPositionMs(
          existingPosMs: 90000,
          incomingPosMs: 10000,
          completed: null,
          intent: ProgressWriteIntent.takeover,
        ),
        90000,
      );
    });

    test('a live takeover may move forward', () {
      expect(
        resolveTakeoverPositionMs(
          existingPosMs: 10000,
          incomingPosMs: 30000,
          completed: null,
          intent: ProgressWriteIntent.takeover,
        ),
        30000,
      );
    });

    test('explicit intents stay verbatim after a takeover', () {
      for (final intent in [
        ProgressWriteIntent.userSeek,
        ProgressWriteIntent.explicitClear,
        ProgressWriteIntent.targeted,
      ]) {
        expect(
          resolveTakeoverPositionMs(
            existingPosMs: 90000,
            incomingPosMs: 0,
            completed: null,
            intent: intent,
          ),
          0,
          reason: '${intent.name} is an explicit decision',
        );
      }
    });

    test('completed takeover keeps its verbatim value', () {
      expect(
        resolveTakeoverPositionMs(
          existingPosMs: 90000,
          incomingPosMs: 0,
          completed: true,
          intent: ProgressWriteIntent.takeover,
        ),
        0,
      );
    });

    test('nothing changes without a stored position or an incoming value', () {
      expect(
        resolveTakeoverPositionMs(
          existingPosMs: null,
          incomingPosMs: 10000,
          completed: null,
          intent: ProgressWriteIntent.takeover,
        ),
        10000,
      );
      expect(
        resolveTakeoverPositionMs(
          existingPosMs: 90000,
          incomingPosMs: null,
          completed: null,
          intent: ProgressWriteIntent.takeover,
        ),
        isNull,
      );
    });
  });

  group('funnel guard (repo write path)', () {
    test('a live 633ms write cannot clobber stored 42833', () async {
      await seedNode(positionMs: 42833);
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'guard.mp4',
        positionMs: 633,
        writeTag: 'timer',
      );
      expect(await readPlaybackProgress(file()), 42833);
    });

    test('a live 0 write cannot clobber stored 42833', () async {
      await seedNode(positionMs: 42833);
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'guard.mp4',
        positionMs: 0,
      );
      expect(await readPlaybackProgress(file()), 42833);
    });

    test('a targeted VM pre-write lands verbatim', () async {
      await seedNode(positionMs: 42833);
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'guard.mp4',
        positionMs: 0,
        completed: false,
        historyRestoreBudgetMs: 0,
        intent: ProgressWriteIntent.targeted,
        writeTag: 'vm-prewrite',
      );
      expect(await readPlaybackProgress(file()), 0);
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'guard.mp4',
        positionMs: 12345,
        completed: false,
        historyRestoreBudgetMs: 0,
        intent: ProgressWriteIntent.targeted,
        writeTag: 'vm-prewrite',
      );
      expect(await readPlaybackProgress(file()), 12345);
    });

    test('an explicit clear (completed:true) still clears', () async {
      await seedNode(positionMs: 42833);
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'guard.mp4',
        positionMs: 0,
        completed: true,
        writeTag: 'scenario-stop',
      );
      expect(await readPlaybackProgress(file()), 0);
      expect(await readPlaybackCompleted(file()), isTrue);
    });

    test('a user seek back to the head still writes 0', () async {
      await seedNode(positionMs: 42833);
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'guard.mp4',
        positionMs: 0,
        intent: ProgressWriteIntent.userSeek,
        writeTag: 'saveProgress',
      );
      expect(await readPlaybackProgress(file()), 0);
    });

    test('a live moderate regression cannot clobber stored 60000', () async {
      await seedNode(positionMs: 60000);
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'guard.mp4',
        positionMs: 20000,
        writeTag: 'timer',
      );
      expect(await readPlaybackProgress(file()), 60000);
    });

    test('a user seek may lower stored 60000 to 20000', () async {
      await seedNode(positionMs: 60000);
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'guard.mp4',
        positionMs: 20000,
        intent: ProgressWriteIntent.userSeek,
        writeTag: 'user-seek',
      );
      expect(await readPlaybackProgress(file()), 20000);
    });

    test('a genuine live mid-file write lands', () async {
      await seedNode(positionMs: 42833);
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'guard.mp4',
        positionMs: 45000,
        writeTag: 'timer',
      );
      expect(await readPlaybackProgress(file()), 45000);
    });

    test('a live head write on an empty row still lands', () async {
      await seedNode();
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'guard.mp4',
        positionMs: 633,
        writeTag: 'timer',
      );
      expect(await readPlaybackProgress(file()), 633);
    });

    test('a budget-only write (null position) leaves the row alone', () async {
      await seedNode(positionMs: 42833);
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'guard.mp4',
        historyRestoreBudgetMs: 1,
        writeTag: 'budget',
      );
      expect(await readPlaybackProgress(file()), 42833);
    });
  });

  group('persistPlaybackProgress intent classification', () {
    test('natural (live) hook save cannot lower stored progress', () async {
      await seedNode(positionMs: 60000);
      await persistPlaybackProgress(
        file: file(),
        position: const Duration(milliseconds: 20000),
        durationMs: 72661,
        writeTag: 'timer',
      );
      expect(await readPlaybackProgress(file()), 60000);
    });

    test('user seek lowers stored progress', () async {
      await seedNode(positionMs: 60000);
      await persistPlaybackProgress(
        file: file(),
        position: const Duration(milliseconds: 20000),
        durationMs: 72661,
        userSeek: true,
        writeTag: 'user-seek',
      );
      expect(await readPlaybackProgress(file()), 20000);
    });

    test('user seek back to the head clears stored progress', () async {
      await seedNode(positionMs: 60000);
      await persistPlaybackProgress(
        file: file(),
        position: Duration.zero,
        userSeek: true,
        writeTag: 'user-seek',
      );
      expect(await readPlaybackProgress(file()), 0);
    });

    test('completed write still clears stored progress', () async {
      await seedNode(positionMs: 60000);
      await persistPlaybackProgress(
        file: file(),
        position: Duration.zero,
        completed: true,
        writeTag: 'completed',
      );
      expect(await readPlaybackProgress(file()), 0);
      expect(await readPlaybackCompleted(file()), isTrue);
    });
  });
}
