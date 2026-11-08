import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/playback/playback_progress.dart';

/// RED tests for the playback position lock (位置意图锁).
///
/// Contract: while an explicit position intent exists (open resume, VM
/// pre-write, user seek, drag release), every progress write for the file is
/// blocked until the player has been observed ONCE at the intended position.
/// Unlock-by-issue (the old OpenResumeGate) left the write window open when a
/// seek failed or landed late — the root of the "switch plays from head" bug.
void main() {
  group('isLandingAt (pure landing decision)', () {
    test('mid-file target lands within tolerance', () {
      expect(
        isLandingAt(posMs: 42833, targetMs: 42833, durationMs: 72661),
        isTrue,
      );
      expect(
        isLandingAt(posMs: 42833 + 1500, targetMs: 42833, durationMs: 72661),
        isTrue,
      );
      expect(
        isLandingAt(posMs: 42833 - 1500, targetMs: 42833, durationMs: 72661),
        isTrue,
      );
    });

    test('overshoot beyond tolerance does not land', () {
      // Position kept playing from an old spot (seek never landed).
      expect(
        isLandingAt(posMs: 50000, targetMs: 42833, durationMs: 72661),
        isFalse,
      );
    });

    test('far-before target does not land', () {
      expect(
        isLandingAt(posMs: 533, targetMs: 42833, durationMs: 72661),
        isFalse,
      );
    });

    test('target 0 lands for head positions up to the head cap', () {
      expect(isLandingAt(posMs: 0, targetMs: 0, durationMs: 72661), isTrue);
      expect(isLandingAt(posMs: 533, targetMs: 0, durationMs: 72661), isTrue);
      expect(
        isLandingAt(
            posMs: 2500, targetMs: 0, durationMs: 72661),
        isTrue,
      );
    });

    test('target 0 does not land mid-file', () {
      expect(
        isLandingAt(posMs: 42833, targetMs: 0, durationMs: 72661),
        isFalse,
      );
    });

    test('file end counts as landed for any target', () {
      expect(
        isLandingAt(posMs: 72661 - 200, targetMs: 10000, durationMs: 72661),
        isTrue,
      );
    });

    test('unknown duration still lands by tolerance', () {
      expect(isLandingAt(posMs: 42833, targetMs: 42833, durationMs: 0), isTrue);
      expect(isLandingAt(posMs: 533, targetMs: 42833, durationMs: 0), isFalse);
    });
  });

  group('PlaybackPositionLock', () {
    test('a fresh lock does not block writes', () {
      final lock = PlaybackPositionLock();
      expect(lock.phase, PositionLockPhase.unlocked);
      expect(lock.blocksWrites, isFalse);
    });

    test('armPending blocks writes with unknown target', () {
      final lock = PlaybackPositionLock();
      lock.armPending();
      expect(lock.phase, PositionLockPhase.pending);
      expect(lock.targetMs, isNull);
      expect(lock.blocksWrites, isTrue);
    });

    test('armTarget blocks until landing, unlock on landing', () {
      final lock = PlaybackPositionLock();
      lock.armPending();
      lock.armTarget(42833);
      expect(lock.phase, PositionLockPhase.locked);
      expect(lock.targetMs, 42833);
      expect(lock.blocksWrites, isTrue);
      // Pre-land head sample: still locked.
      expect(lock.checkLanding(533, 72661), isFalse);
      expect(lock.blocksWrites, isTrue);
      // Seek landed AND playback is observed past the intent: unlocked once.
      expect(lock.checkLanding(42900 + 1000, 72661), isTrue);
      expect(lock.phase, PositionLockPhase.unlocked);
      expect(lock.blocksWrites, isFalse);
    });

    test('a seek-target echo alone does not prove the landing', () {
      // mpv reports `last_seek_pts` (the requested position) through `time-pos`
      // as soon as the seek is queued — before a frame is decoded. Accepting
      // that echo is what let a media which restarted at the head (Android
      // video-output attach) unlock and persist the head position.
      final lock = PlaybackPositionLock();
      lock.armTarget(42833);
      expect(lock.checkLanding(42833, 72661), isFalse);
      expect(lock.blocksWrites, isTrue);
      expect(lock.checkLanding(42833, 72661), isFalse);
      expect(lock.blocksWrites, isTrue);
    });

    test('landing is confirmed once playback moves past the target', () {
      final lock = PlaybackPositionLock();
      lock.armTarget(42833);
      expect(lock.checkLanding(42833, 72661), isFalse);
      expect(lock.checkLanding(43233, 72661), isTrue);
      expect(lock.blocksWrites, isFalse);
    });

    test('landing is confirmed at the end of the media', () {
      final lock = PlaybackPositionLock();
      lock.armTarget(42833);
      expect(lock.checkLanding(72400, 72661), isTrue);
      expect(lock.blocksWrites, isFalse);
    });

    test('a pre-land head sample before any landing is not a restart', () {
      final lock = PlaybackPositionLock();
      lock.armTarget(42833);
      expect(lock.checkLanding(300, 72661), isFalse);
      expect(lock.takeRestartSeek(), isFalse);
      expect(lock.blocksWrites, isTrue);
    });

    test('restart to the head after a landed echo asks for exactly one re-seek',
        () {
      // Field log (Android): `lock landed pos=319799` (the target echo), then
      // the surface attached, the video output re-inited and `time-pos` fell to
      // 580ms while the media played from the head.
      final lock = PlaybackPositionLock();
      lock.armTarget(42833);
      expect(lock.checkLanding(42833, 72661), isFalse); // target echo
      expect(lock.takeRestartSeek(), isFalse);
      expect(lock.checkLanding(580, 72661), isFalse); // restarted at the head
      expect(lock.takeRestartSeek(), isTrue); // caller re-issues the intent seek
      expect(lock.takeRestartSeek(), isFalse); // consumed exactly once
      expect(lock.blocksWrites, isTrue);
      // The re-seek lands and playback moves past the intent.
      expect(lock.checkLanding(42833, 72661), isFalse);
      expect(lock.checkLanding(43833, 72661), isTrue);
      expect(lock.blocksWrites, isFalse);
    });

    test('restart re-seek is bounded, then the lock stops asking', () {
      final lock = PlaybackPositionLock();
      final t0 = DateTime(2026, 1, 1, 12);
      lock.armTarget(42833, now: t0);
      var seeks = 0;
      for (var i = 0; i < 10; i++) {
        lock.checkLanding(42833, 72661, now: t0);
        lock.checkLanding(580, 72661, now: t0);
        if (lock.takeRestartSeek()) seeks++;
      }
      expect(seeks, positionLockMaxRestartSeeks);
    });

    test('a paused open at the target still fails open on the timeout', () {
      final lock = PlaybackPositionLock();
      final t0 = DateTime(2026, 1, 1, 12);
      lock.armTarget(42833, now: t0);
      // The position rests exactly on the intent and never advances: the
      // confirmation rule alone would freeze saves for the whole session.
      expect(lock.checkLanding(42833, 72661, now: t0), isFalse);
      var action = PositionLockTimeoutAction.none;
      for (var s = 1; s <= 12; s++) {
        action = lock.tickTimeout(now: t0.add(Duration(seconds: s)));
        if (action == PositionLockTimeoutAction.released) break;
      }
      expect(action, PositionLockTimeoutAction.released);
      expect(lock.blocksWrites, isFalse);
    });

    test('fromBeginningExplicit target 0 lands at the head', () {
      final lock = PlaybackPositionLock();
      lock.armTarget(0);
      expect(lock.checkLanding(120, 72661), isTrue);
      expect(lock.phase, PositionLockPhase.unlocked);
    });

    test('checkLanding is a no-op while unlocked', () {
      final lock = PlaybackPositionLock();
      expect(lock.checkLanding(42833, 72661), isFalse);
      expect(lock.phase, PositionLockPhase.unlocked);
    });

    test('explicit unlock works from pending and locked', () {
      final lock = PlaybackPositionLock();
      lock.armPending();
      lock.unlock();
      expect(lock.blocksWrites, isFalse);
      lock.armTarget(1000);
      lock.unlock();
      expect(lock.blocksWrites, isFalse);
      expect(lock.targetMs, isNull);
    });

    test('pending timeout releases fail-open', () {
      final lock = PlaybackPositionLock();
      final open = DateTime(2026, 1, 1, 12);
      lock.armPending(now: open);
      // Duration never arrives: 8s later the lock must release so saves
      // cannot stay frozen for the whole session.
      expect(
        lock.tickTimeout(now: open.add(const Duration(seconds: 7))),
        PositionLockTimeoutAction.none,
      );
      expect(lock.blocksWrites, isTrue);
      expect(
        lock.tickTimeout(now: open.add(const Duration(seconds: 9))),
        PositionLockTimeoutAction.released,
      );
      expect(lock.blocksWrites, isFalse);
    });

    test('locked timeout retries the seek once, then releases', () {
      final lock = PlaybackPositionLock();
      final t0 = DateTime(2026, 1, 1, 12);
      lock.armTarget(42833, now: t0);
      expect(
        lock.tickTimeout(now: t0.add(const Duration(seconds: 4))),
        PositionLockTimeoutAction.none,
      );
      expect(
        lock.tickTimeout(now: t0.add(const Duration(seconds: 6))),
        PositionLockTimeoutAction.retrySeek,
      );
      // Still locked after the retry is armed.
      expect(lock.blocksWrites, isTrue);
      // Retry seek issued; another full window without landing releases.
      expect(
        lock.tickTimeout(now: t0.add(const Duration(seconds: 10))),
        PositionLockTimeoutAction.none,
      );
      expect(
        lock.tickTimeout(now: t0.add(const Duration(seconds: 12))),
        PositionLockTimeoutAction.released,
      );
      expect(lock.blocksWrites, isFalse);
    });

    test('re-armTarget resets the retry budget', () {
      final lock = PlaybackPositionLock();
      final t0 = DateTime(2026, 1, 1, 12);
      lock.armTarget(1000, now: t0);
      expect(
        lock.tickTimeout(now: t0.add(const Duration(seconds: 6))),
        PositionLockTimeoutAction.retrySeek,
      );
      // A NEW user intent (e.g. another seek) re-arms from scratch.
      lock.armTarget(20000, now: t0.add(const Duration(seconds: 6)));
      expect(
        lock.tickTimeout(now: t0.add(const Duration(seconds: 7))),
        PositionLockTimeoutAction.none,
      );
      expect(lock.blocksWrites, isTrue);
    });

    test('landing after retry releases', () {
      final lock = PlaybackPositionLock();
      lock.armTarget(42833, now: DateTime(2026, 1, 1, 12));
      expect(
        lock.tickTimeout(now: DateTime(2026, 1, 2)),
        PositionLockTimeoutAction.retrySeek,
      );
      expect(lock.checkLanding(42900 + 1000, 72661), isTrue);
      expect(lock.blocksWrites, isFalse);
    });
  });

  // The write lock and the restart watch are separate lifetimes.
  //
  // A paused open parks ON the target and never advances, so the write lock can
  // only fail open on its timeout — a ~10s window in which every save is
  // skipped (field logs: `lock timeout retry seek` + `persist skipped (locked
  // phase=locked …)` + `lock timeout released`). But the engine can still
  // restart the media ~1s after the resume seek (the Android video output
  // attaches late), and that restart happens exactly while paused in the
  // captured logs. So: the write lock must release on a paused landing, and the
  // restart watch must keep running after it.
  group('restart watch (independent of the write lock)', () {
    test('a paused landing at the target releases the write lock', () {
      final lock = PlaybackPositionLock();
      final t0 = DateTime(2026, 1, 1, 12);
      lock.armTarget(42833, now: t0);
      // A paused player cannot "advance past" the target, so the advance rule
      // would keep the write window (and every save) frozen for its timeout.
      expect(
        lock.checkLanding(42833, 72661, playing: false, now: t0),
        isTrue,
      );
      expect(lock.phase, PositionLockPhase.unlocked);
      expect(lock.blocksWrites, isFalse);
    });

    test('a paused pre-land head sample does not release the lock', () {
      final lock = PlaybackPositionLock();
      lock.armTarget(42833);
      expect(lock.checkLanding(533, 72661, playing: false), isFalse);
      expect(lock.blocksWrites, isTrue);
    });

    test('a restart after the paused release is still detected', () {
      final lock = PlaybackPositionLock();
      final t0 = DateTime(2026, 1, 1, 12);
      lock.armTarget(42833, now: t0);
      expect(
        lock.checkLanding(42833, 72661, playing: false, now: t0),
        isTrue,
      );
      expect(lock.takeRestartSeek(), isFalse);
      // 1s later the video output attaches and the media restarts from the
      // head while still paused (the captured `restartmedialog.txt` case).
      expect(
        lock.checkLanding(
            0, 72661, playing: false, now: t0.add(const Duration(seconds: 1))),
        isFalse,
      );
      expect(lock.takeRestartSeek(), isTrue);
      // The re-seek target must survive the write-lock release.
      expect(lock.restartSeekTargetMs, 42833);
      expect(lock.targetMs, isNull);
    });

    test('the watch is dropped once playback moves past the target', () {
      final lock = PlaybackPositionLock();
      lock.armTarget(42833);
      expect(lock.checkLanding(42833, 72661), isFalse);
      expect(lock.checkLanding(43833, 72661), isTrue);
      expect(lock.watchingRestart, isFalse);
      expect(lock.checkLanding(0, 72661), isFalse);
      expect(lock.takeRestartSeek(), isFalse);
    });

    test('the watch expires with its window', () {
      final lock = PlaybackPositionLock();
      final t0 = DateTime(2026, 1, 1, 12);
      final after = t0.add(positionLockWatchWindow + const Duration(seconds: 1));
      lock.armTarget(42833, now: t0);
      expect(lock.checkLanding(42833, 72661, playing: false, now: t0), isTrue);
      expect(lock.watchingRestart, isTrue);
      expect(
        lock.tickTimeout(now: after),
        PositionLockTimeoutAction.none,
      );
      expect(lock.watchingRestart, isFalse);
      expect(
        lock.checkLanding(0, 72661, playing: false, now: after),
        isFalse,
      );
      expect(lock.takeRestartSeek(), isFalse);
    });

    test('a user step inside the watch window is not a restart', () {
      final lock = PlaybackPositionLock();
      final t0 = DateTime(2026, 1, 1, 12);
      lock.armTarget(42833, now: t0);
      expect(lock.checkLanding(42833, 72661, now: t0), isFalse);
      // ← 5s: a step deliberately does NOT arm the write lock (its keyframe
      // landing is off-target), so it takes over the intent instead.
      lock.noteUserSeek();
      expect(lock.blocksWrites, isFalse);
      expect(lock.watchingRestart, isFalse);
      // 37900 is 4.9s BEHIND the resume target — the step landing, not an
      // engine restart.
      expect(lock.checkLanding(37900, 72661, now: t0), isFalse);
      expect(lock.takeRestartSeek(), isFalse);
    });

    test('noteUserSeek releases a still-locked write window', () {
      final lock = PlaybackPositionLock();
      final t0 = DateTime(2026, 1, 1, 12);
      lock.armTarget(42833, now: t0);
      expect(lock.checkLanding(533, 72661, now: t0), isFalse);
      expect(lock.blocksWrites, isTrue);
      lock.noteUserSeek();
      expect(lock.blocksWrites, isFalse);
      expect(lock.targetMs, isNull);
    });

    test('the sanitizer anchor survives the paused release, then goes away',
        () {
      final lock = PlaybackPositionLock();
      final t0 = DateTime(2026, 1, 1, 12);
      lock.armTarget(42833, now: t0);
      expect(lock.checkLanding(42833, 72661, playing: false, now: t0), isTrue);
      // The write lock is gone, but the restart watch keeps the sanitizer
      // anchored on the resume point so a restarted head sample cannot seed
      // `lastSane` (the paused release happens before any frame is decoded).
      expect(lock.intentTargetMs, 42833);
      expect(
        lock.checkLanding(43833, 72661, now: t0.add(const Duration(seconds: 2))),
        isFalse,
      );
      // Playback really moved past the intent: nothing left to anchor/watch.
      expect(lock.intentTargetMs, isNull);
    });

    test('a new arm resets the watch to the new intent', () {
      final lock = PlaybackPositionLock();
      lock.armTarget(42833);
      expect(lock.checkLanding(42833, 72661), isFalse);
      lock.armTarget(10000);
      expect(lock.watchingRestart, isTrue);
      expect(lock.restartSeekTargetMs, 10000);
      expect(lock.checkLanding(42833, 72661), isFalse);
      expect(lock.takeRestartSeek(), isFalse);
    });
  });
}
