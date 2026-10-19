import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/services/background_sync_logic.dart';

/// 高同步 (linked + high) 的「连续锁步」判定。
///
/// Previously the mirror only ever acted on a discrete jump: a settled sample
/// (`!fgJump && !bgJump`) unconditionally re-anchored. That left the pair free
/// to drift apart whenever one runtime stalled — the reported "enabling 副音
/// freezes the foreground counter" bug: the bg kept advancing while the fg sat
/// at one position and every sample logged `anchor`. The drift branch makes the
/// master's timeline pull the follower back once the gap exceeds the tolerance,
/// in BOTH directions.
void main() {
  group('resolveBgMirrorAction continuous drift', () {
    BgMirrorAction resolve({
      bool enabled = true,
      bool positionSync = true,
      bool standDown = false,
      bool bgIsMaster = false,
      bool fgJump = false,
      bool bgJump = false,
      bool pendingStep = false,
      bool lockOffsetReady = true,
      int driftMs = 0,
    }) =>
        resolveBgMirrorAction(
          enabled: enabled,
          positionSync: positionSync,
          standDown: standDown,
          bgIsMaster: bgIsMaster,
          fgJump: fgJump,
          bgJump: bgJump,
          fgSystemSeekLanding: false,
          bgSystemSeekLanding: false,
          pendingStep: pendingStep,
          mirrorStep: true,
          lockOffsetReady: lockOffsetReady,
          driftMs: driftMs,
        );

    test('a settled sample inside the tolerance re-anchors', () {
      expect(resolve(), BgMirrorAction.anchor);
      expect(
        resolve(driftMs: BackgroundSyncLogic.kContinuousDriftToleranceMs),
        BgMirrorAction.anchor,
      );
    });

    test('bg master pulls the foreground once the drift exceeds tolerance', () {
      expect(
        resolve(
          bgIsMaster: true,
          driftMs: BackgroundSyncLogic.kContinuousDriftToleranceMs + 1,
        ),
        BgMirrorAction.bgDrivesFg,
      );
    });

    test('fg master pulls 副音 once the drift exceeds tolerance', () {
      expect(
        resolve(
          bgIsMaster: false,
          driftMs: BackgroundSyncLogic.kContinuousDriftToleranceMs + 1,
        ),
        BgMirrorAction.fgDrivesBg,
      );
    });

    test('a drift is never mirrored before the offset is settled', () {
      expect(
        resolve(
          bgIsMaster: true,
          driftMs: 5000,
          lockOffsetReady: false,
        ),
        BgMirrorAction.anchor,
      );
      expect(
        resolve(bgIsMaster: false, driftMs: 5000, lockOffsetReady: false),
        BgMirrorAction.anchor,
      );
    });

    test('a pending step suppresses the continuous correction', () {
      // The step's own landing is still in flight; re-driving from the drifted
      // sample would fight it.
      expect(
        resolve(
          bgIsMaster: true,
          driftMs: 5000,
          pendingStep: true,
        ),
        BgMirrorAction.anchor,
      );
    });

    test('an unlinked or disabled pair never drift-corrects', () {
      expect(resolve(enabled: false, driftMs: 5000), BgMirrorAction.none);
      expect(resolve(positionSync: false, driftMs: 5000), BgMirrorAction.none);
      expect(resolve(standDown: true, driftMs: 5000), BgMirrorAction.none);
    });

    test('our own landing still wins over a drift sample', () {
      expect(
        resolveBgMirrorAction(
          enabled: true,
          positionSync: true,
          standDown: false,
          bgIsMaster: true,
          fgJump: false,
          bgJump: false,
          fgSystemSeekLanding: true,
          bgSystemSeekLanding: false,
          pendingStep: false,
          mirrorStep: true,
          lockOffsetReady: true,
          driftMs: 5000,
        ),
        BgMirrorAction.stayFg,
      );
    });
  });

  group('bgMasterMaySeekFg (drift never rewinds the video)', () {
    test('a drift correction may pull the follower forward', () {
      expect(
        bgMasterMaySeekFg(fromRealBgMove: false, fgTarget: 8000, fgMs: 5000),
        isTrue,
      );
      expect(
        bgMasterMaySeekFg(fromRealBgMove: false, fgTarget: 5000, fgMs: 5000),
        isTrue,
      );
    });

    test('a drift correction must never rewind the video', () {
      // 副音 still reports its head right after an activation whose alignment
      // seek has not landed: mapping that onto the video is `seek(0)` — the
      // 「开启副音把播放进度归 0」 report.
      expect(
        bgMasterMaySeekFg(fromRealBgMove: false, fgTarget: 0, fgMs: 5000),
        isFalse,
      );
      expect(
        bgMasterMaySeekFg(fromRealBgMove: false, fgTarget: -1200, fgMs: 5000),
        isFalse,
      );
    });

    test('a REAL 副音 move may rewind the video', () {
      expect(
        bgMasterMaySeekFg(fromRealBgMove: true, fgTarget: 0, fgMs: 5000),
        isTrue,
      );
    });
  });
}
