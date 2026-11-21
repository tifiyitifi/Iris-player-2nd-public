import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/model/background_playback_state.dart';
import 'package:iris/features/background_playback/services/background_sync_logic.dart';

/// fg↔bg 位置镜像判定 (反馈环修复) 的真值表。
///
/// The runtime observer used to decide the mirror direction inline, with the
/// foreground→副音 branch checking neither the control master nor whether the
/// foreground jump was one it had just issued itself. The landed jumps were
/// therefore mirrored back, walking the 副音 queue (`wrap: true`) and jumping
/// the foreground across Virtual Merge segments — the ping-pong this file locks
/// down. The decision is now a pure function over the whole truth table.
void main() {
  group('resolveBgMirrorAction', () {
    BgMirrorAction resolve({
      bool enabled = true,
      bool positionSync = true,
      bool standDown = false,
      bool bgIsMaster = false,
      bool fgJump = false,
      bool bgJump = false,
      bool fgSystemSeekLanding = false,
      bool bgSystemSeekLanding = false,
      bool pendingStep = false,
      bool mirrorStep = true,
      bool lockOffsetReady = true,
    }) =>
        resolveBgMirrorAction(
          enabled: enabled,
          positionSync: positionSync,
          standDown: standDown,
          bgIsMaster: bgIsMaster,
          fgJump: fgJump,
          bgJump: bgJump,
          fgSystemSeekLanding: fgSystemSeekLanding,
          bgSystemSeekLanding: bgSystemSeekLanding,
          pendingStep: pendingStep,
          mirrorStep: mirrorStep,
          lockOffsetReady: lockOffsetReady,
        );

    test('a disabled or unlinked pair never mirrors', () {
      expect(resolve(enabled: false, fgJump: true), BgMirrorAction.none);
      expect(resolve(positionSync: false, fgJump: true), BgMirrorAction.none);
      expect(resolve(standDown: true, fgJump: true), BgMirrorAction.none);
    });

    test('a settled sample re-anchors the fixed offset', () {
      expect(resolve(), BgMirrorAction.anchor);
    });

    test('ambiguous (both moved) samples re-anchor', () {
      expect(resolve(fgJump: true, bgJump: true), BgMirrorAction.anchor);
    });

    test('our own bg landing is swallowed, never mirrored to the fg', () {
      expect(
        resolve(bgJump: true, bgIsMaster: true, bgSystemSeekLanding: true),
        BgMirrorAction.stayBg,
      );
    });

    test('our own fg landing is swallowed, never mirrored to bg', () {
      // The loop-break: the bg-master mirror seeks the foreground; the landing
      // must not be read as a user fg seek and mapped back onto the 副音 queue.
      expect(
        resolve(fgJump: true, fgSystemSeekLanding: true),
        BgMirrorAction.stayFg,
      );
      // Even when the bg is master and would otherwise drive the fg.
      expect(
        resolve(fgJump: true, bgIsMaster: true, fgSystemSeekLanding: true),
        BgMirrorAction.stayFg,
      );
    });

    test('fg master never lets a bg jump touch the foreground', () {
      expect(resolve(bgJump: true, bgIsMaster: false), BgMirrorAction.anchor);
    });

    test('bg master drives the foreground', () {
      expect(
          resolve(bgJump: true, bgIsMaster: true), BgMirrorAction.bgDrivesFg);
    });

    test('a swap-only step stays on the bg side', () {
      expect(
        resolve(
          bgJump: true,
          bgIsMaster: true,
          pendingStep: true,
          mirrorStep: false,
        ),
        BgMirrorAction.anchor,
      );
      expect(
        resolve(
          bgJump: true,
          bgIsMaster: true,
          pendingStep: true,
          mirrorStep: true,
        ),
        BgMirrorAction.bgDrivesFg,
      );
    });

    test('a jump without a settled offset only re-anchors', () {
      expect(
        resolve(bgJump: true, bgIsMaster: true, lockOffsetReady: false),
        BgMirrorAction.anchor,
      );
      expect(
          resolve(fgJump: true, lockOffsetReady: false), BgMirrorAction.anchor);
    });

    test('a user fg move still drives the 副音 queue', () {
      expect(resolve(fgJump: true), BgMirrorAction.fgDrivesBg);
    });

    test('the ping-pong settles: bg landing -> fg seek -> fg landing -> anchor',
        () {
      // Sample 1: the bg-master mirror arms the fg latch and seeks the fg.
      // Sample 2: the fg landing arrives -> swallowed (not mapped to bg).
      expect(
        resolve(bgJump: true, bgIsMaster: true),
        BgMirrorAction.bgDrivesFg,
      );
      expect(
        resolve(fgJump: true, bgIsMaster: true, fgSystemSeekLanding: true),
        BgMirrorAction.stayFg,
      );
      // Sample 3: settled, offset re-anchored, nothing moves again.
      expect(resolve(bgIsMaster: true), BgMirrorAction.anchor);
    });
  });

  group('clampFgTargetToWindow', () {
    test('a mid-window target is untouched', () {
      expect(
        clampFgTargetToWindow(
          fgTarget: 30000,
          windowStartMs: 10000,
          windowDurMs: 60000,
        ),
        30000,
      );
    });

    test('a target before the window floors at its start (no cross-segment)',
        () {
      expect(
        clampFgTargetToWindow(
          fgTarget: 5000,
          windowStartMs: 10000,
          windowDurMs: 60000,
        ),
        10000,
      );
    });

    test('a target past the window clamps below the completion guard', () {
      expect(
        clampFgTargetToWindow(
          fgTarget: 90000,
          windowStartMs: 10000,
          windowDurMs: 60000,
        ),
        69250,
      );
    });

    test('an unknown window only floors at its start', () {
      expect(
        clampFgTargetToWindow(
          fgTarget: 30000,
          windowStartMs: 10000,
          windowDurMs: 0,
        ),
        30000,
      );
      expect(
        clampFgTargetToWindow(
          fgTarget: 5000,
          windowStartMs: 10000,
          windowDurMs: 0,
        ),
        10000,
      );
    });

    test('a zero-start window matches the legacy single-file semantics', () {
      expect(
        clampFgTargetToWindow(
          fgTarget: 60000,
          windowStartMs: 0,
          windowDurMs: 60000,
        ),
        59250,
      );
      expect(clampScopedFgTarget(fgTarget: 60000, fgDurMs: 60000), 59250);
    });
  });

  group('fg system-seek contract', () {
    test('the fg system-seek seq starts at 0 (session-only)', () {
      const s = BackgroundPlaybackState();
      expect(s.fgSystemSeekSeq, 0);
    });
  });

  group('bgMirrorStandsDown', () {
    test('off, closed gate and terminal exhaustion all stand down', () {
      expect(
        bgMirrorStandsDown(enabled: false, gateOpen: true, exhausted: false),
        isTrue,
      );
      expect(
        bgMirrorStandsDown(enabled: true, gateOpen: false, exhausted: false),
        isTrue,
      );
      expect(
        bgMirrorStandsDown(enabled: true, gateOpen: true, exhausted: true),
        isTrue,
        reason: 'a stopRestoreFg terminal pause must not be mirrored back',
      );
    });

    test('an armed, open, non-exhausted run mirrors normally', () {
      expect(
        bgMirrorStandsDown(enabled: true, gateOpen: true, exhausted: false),
        isFalse,
      );
    });
  });
}
