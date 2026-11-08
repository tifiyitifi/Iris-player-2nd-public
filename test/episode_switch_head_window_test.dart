import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/playback/playback_progress.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';

import 'helpers/sqlite3_loader.dart';

/// RED tests for the "上集/下集时丢时不丢" head-window overwrite.
///
/// Evidence (第8次 log): open → resume seek dbPos=42833 issued, but
/// `watch t=1` still shows pos=533ms (pre-seek head). A next/prev tap inside
/// that ~1-2s window persists the 533ms head over the real 42833 progress —
/// the existing zero-write guard lets it through because 533 > 0, and the
/// next open then takes seekDb(533) without ever consulting History.
void main() {
  setUpAll(() async {
    ensureSqlite3Loaded();
    DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  FileItem file() => FileItem(
        storageId: 's',
        storageType: StorageType.internal,
        name: 'episode.mp4',
        uri: '/storage/episode.mp4',
        path: const ['episode.mp4'],
      );

  Future<void> seedNode({int? positionMs}) async {
    await DbModule.mediaNodesDao.deleteNode('s', 'episode.mp4');
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 'f:s:episode.mp4',
      storageId: 's',
      path: const ['episode.mp4'],
      name: 'episode.mp4',
      mediaType: MediaType.video,
    ));
    // insertNode's companion intentionally omits progress columns
    // (rescan-preserving rule) — seed progress via the update path.
    if (positionMs != null) {
      await DbModule.mediaNodeRepo.updatePlaybackProgress(
        storageId: 's',
        path: 'episode.mp4',
        positionMs: positionMs,
      );
    }
  }

  group('head-window overwrite (persistPlaybackProgress head guard)', () {
    test('a 533ms head save must not clobber stored 42833 progress', () async {
      await seedNode(positionMs: 42833);
      final ok = await persistPlaybackProgress(
        file: file(),
        position: const Duration(milliseconds: 533),
        durationMs: 72661,
      );
      expect(ok, isTrue);
      expect(await readPlaybackProgress(file()), 42833);
    });

    test('a genuine mid-file save still goes through', () async {
      await seedNode(positionMs: 42833);
      final ok = await persistPlaybackProgress(
        file: file(),
        position: const Duration(milliseconds: 45000),
        durationMs: 72661,
      );
      expect(ok, isTrue);
      expect(await readPlaybackProgress(file()), 45000);
    });

    test('first-ever play from the head still writes', () async {
      await seedNode();
      final ok = await persistPlaybackProgress(
        file: file(),
        position: const Duration(milliseconds: 533),
        durationMs: 72661,
      );
      expect(ok, isTrue);
      expect(await readPlaybackProgress(file()), 533);
    });

    test('explicit finish (completed:true) still force-clears', () async {
      await seedNode(positionMs: 42833);
      final ok = await persistPlaybackProgress(
        file: file(),
        position: Duration.zero,
        completed: true,
      );
      expect(ok, isTrue);
      expect(await readPlaybackProgress(file()), 0);
    });
  });

  group('shouldGuardHeadWrite (pure decision)', () {
    test('guards a small head over large stored progress', () {
      expect(
        shouldGuardHeadWrite(
          existingPosMs: 42833,
          incomingPosMs: 533,
          durationMs: 72661,
        ),
        isTrue,
      );
    });

    test('lets genuine mid-file writes through', () {
      expect(
        shouldGuardHeadWrite(
          existingPosMs: 42833,
          incomingPosMs: 45000,
          durationMs: 72661,
        ),
        isFalse,
      );
    });

    test('lets first-play head writes through (no stored progress)', () {
      expect(
        shouldGuardHeadWrite(
          existingPosMs: null,
          incomingPosMs: 533,
          durationMs: 72661,
        ),
        isFalse,
      );
    });

    test('never guards an explicit finish', () {
      expect(
        shouldGuardHeadWrite(
          existingPosMs: 42833,
          incomingPosMs: 0,
          durationMs: 72661,
          forceClear: true,
        ),
        isFalse,
      );
    });

    test('never guards a user seek back to the head', () {
      expect(
        shouldGuardHeadWrite(
          existingPosMs: 42833,
          incomingPosMs: 0,
          durationMs: 72661,
          userSeekToHead: true,
        ),
        isFalse,
      );
    });
  });

  group('PlaybackPositionLock (per-open position-intent lock)', () {
    test('a fresh open must not persist until the resume LANDS', () {
      final lock = PlaybackPositionLock();
      lock.armPending();
      expect(lock.blocksWrites, isTrue);
      // Decision known (dbPos=42833): still blocked — issued ≠ landed.
      lock.armTarget(42833);
      expect(lock.checkLanding(533, 72661), isFalse);
      expect(lock.blocksWrites, isTrue);
      // The seek target echoed back is NOT proof (mpv reports `last_seek_pts`
      // before decoding a frame): playback must be observed past the intent.
      expect(lock.checkLanding(42833, 72661), isFalse);
      expect(lock.blocksWrites, isTrue);
      // Landing observed and decoded past the intent: writes resume.
      expect(lock.checkLanding(43833, 72661), isTrue);
      expect(lock.blocksWrites, isFalse);
    });
  });
}
