import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/model/background_playback_state.dart';
import 'package:iris/features/background_playback/model/enum/bg_seek_link.dart';
import 'package:iris/features/background_playback/services/background_lock_mapping.dart';
import 'package:iris/features/background_playback/services/background_sync_logic.dart';
import 'package:iris/features/scenario_playback/playback/active_repeat.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;

/// 副音→前台跳集链路锁 (F-plan):
///
/// - 非高同步 (independent/low): 副音侧任何 jump 都不得触碰前台
///   ([bgMasterMayTouchFg] 为 false)。
/// - 高同步: 落尾精确值永不直 seek ([resolveBgMasterFgAction] → roll)。
/// - 仅当前 + 高同步: 副音本地 seek 上限 ([bgSeekCeilingLocalMs])。
void main() {
  group('bgMasterMayTouchFg', () {
    test('only linked + high lets the bg side touch the foreground', () {
      expect(
        bgMasterMayTouchFg(link: BgSeekLink.linked, level: BgLockLevel.high),
        isTrue,
      );
      expect(
        bgMasterMayTouchFg(link: BgSeekLink.linked, level: BgLockLevel.low),
        isFalse,
      );
      expect(
        bgMasterMayTouchFg(
            link: BgSeekLink.independent, level: BgLockLevel.high),
        isFalse,
      );
    });
  });

  group('resolveBgMasterFgAction', () {
    test('an in-range target seeks in place', () {
      expect(
        resolveBgMasterFgAction(fgTarget: 10000, fgDurMs: 60000),
        BgMasterFgAction.seek,
      );
    });

    test('landing exactly on the tail must roll, never seek', () {
      // Seeking to exactly duration parks the player at its end, raising a
      // genuine completed → auto-advance (= unexpected episode skip).
      expect(
        resolveBgMasterFgAction(fgTarget: 60000, fgDurMs: 60000),
        BgMasterFgAction.roll,
      );
      expect(
        resolveBgMasterFgAction(fgTarget: 59999, fgDurMs: 60000),
        BgMasterFgAction.roll,
      );
    });

    test('a target past the file rolls', () {
      expect(
        resolveBgMasterFgAction(fgTarget: 90000, fgDurMs: 60000),
        BgMasterFgAction.roll,
      );
    });

    test('a negative target rolls (backwards, never a raw seek)', () {
      expect(
        resolveBgMasterFgAction(fgTarget: -500, fgDurMs: 60000),
        BgMasterFgAction.roll,
      );
    });

    test('unknown duration cannot judge the tail — seek and let it clamp', () {
      expect(
        resolveBgMasterFgAction(fgTarget: 10000, fgDurMs: 0),
        BgMasterFgAction.seek,
      );
      expect(
        resolveBgMasterFgAction(fgTarget: 10000, fgDurMs: -1),
        BgMasterFgAction.seek,
      );
    });
  });

  group('bgSeekCeilingLocalMs', () {
    test('bg longer than fg with zero offset caps at the fg duration', () {
      // BG file 10min, FG file 6min, aligned head-to-head: the bg slider must
      // stop at 6min (the FG 100% point), never beyond.
      final timeline = BgQueueTimeline(const [600000]);
      expect(
        bgSeekCeilingLocalMs(
          timeline: timeline,
          currentIndex: 0,
          offsetMs: 0,
          fgDurMs: 360000,
        ),
        360000,
      );
    });

    test('a positive offset pulls the ceiling earlier', () {
      // FG runs 2min ahead of BG: BG may only reach FG-end-minus-2min.
      final timeline = BgQueueTimeline(const [600000]);
      expect(
        bgSeekCeilingLocalMs(
          timeline: timeline,
          currentIndex: 0,
          offsetMs: 120000,
          fgDurMs: 360000,
        ),
        240000,
      );
    });

    test('a negative offset lifts the ceiling to the mapped fg end', () {
      // FG runs 2min BEHIND bg (offset -2min): bgVirtual <= 8min maps to
      // fgTarget <= 6min. Still inside the 10min file, so 8min — not the
      // file end — is the ceiling.
      final timeline = BgQueueTimeline(const [600000]);
      expect(
        bgSeekCeilingLocalMs(
          timeline: timeline,
          currentIndex: 0,
          offsetMs: -120000,
          fgDurMs: 360000,
        ),
        480000,
      );
    });

    test('a far-negative offset clamps the ceiling to the file end', () {
      final timeline = BgQueueTimeline(const [600000]);
      expect(
        bgSeekCeilingLocalMs(
          timeline: timeline,
          currentIndex: 0,
          offsetMs: -600000,
          fgDurMs: 360000,
        ),
        600000,
      );
    });

    test('the ceiling accounts for the queue prefix of later files', () {
      // Two 5min BG files; second file starts at virtual 5min. FG 8min,
      // offset 0 → second file may play only its first 3min.
      final timeline = BgQueueTimeline(const [300000, 300000]);
      expect(
        bgSeekCeilingLocalMs(
          timeline: timeline,
          currentIndex: 1,
          offsetMs: 0,
          fgDurMs: 480000,
        ),
        180000,
      );
    });

    test('unknown timeline yields no ceiling (free seek)', () {
      expect(
        bgSeekCeilingLocalMs(
          timeline: BgQueueTimeline(const []),
          currentIndex: 0,
          offsetMs: 0,
          fgDurMs: 360000,
        ),
        isNull,
      );
      expect(
        bgSeekCeilingLocalMs(
          timeline: BgQueueTimeline(const [0, 0]),
          currentIndex: 0,
          offsetMs: 0,
          fgDurMs: 360000,
        ),
        isNull,
      );
      expect(
        bgSeekCeilingLocalMs(
          timeline: BgQueueTimeline(const [600000]),
          currentIndex: 5,
          offsetMs: 0,
          fgDurMs: 360000,
        ),
        isNull,
      );
      expect(
        bgSeekCeilingLocalMs(
          timeline: BgQueueTimeline(const [600000]),
          currentIndex: 0,
          offsetMs: 0,
          fgDurMs: 0,
        ),
        isNull,
      );
    });
  });

  group('bg skip-link session contracts', () {
    test('system/run seqs start at 0 and the seek ceiling starts null', () {
      // Locks the F-plan wiring contract: the mirror swallows system seeks
      // (tiled/alignment/replay) via bgSystemSeekSeq, restarts alignment via
      // bgRunSeq, and leaves bg seeks free until a ceiling is published.
      const s = BackgroundPlaybackState();
      expect(s.bgSystemSeekSeq, 0);
      expect(s.bgRunSeq, 0);
      expect(s.bgSeekCeilingLocalMs, isNull);
    });
  });

  group('shouldConsumeSystemSeekLatch', () {
    test('a disarmed latch is never consumed', () {
      expect(
        shouldConsumeSystemSeekLatch(
            armed: false, bgJump: true, deadlineExpired: true),
        isFalse,
      );
    });

    test('an armed latch stays armed until the landing jump is observed', () {
      // The whole point of the F-fix: consuming on the first (pre-landing)
      // sample let the later landing be mirrored onto the foreground and skip
      // the episode.
      expect(
        shouldConsumeSystemSeekLatch(
            armed: true, bgJump: false, deadlineExpired: false),
        isFalse,
      );
      expect(
        shouldConsumeSystemSeekLatch(
            armed: true, bgJump: true, deadlineExpired: false),
        isTrue,
      );
    });

    test('the deadline is the fallback for a same-position seek', () {
      expect(
        shouldConsumeSystemSeekLatch(
            armed: true, bgJump: false, deadlineExpired: true),
        isTrue,
      );
    });

    test('an armed latch with NO seek issued consumes at once', () {
      // A zero-target alignment skips its seek (see the zero--target latch in
      // `background_runtime_scope`): nothing was sent, so nothing can land, and
      // waiting for the deadline only froze the mirror for ~900ms.
      expect(
        shouldConsumeSystemSeekLatch(
          armed: true,
          bgJump: false,
          deadlineExpired: false,
          seekIssued: false,
        ),
        isTrue,
      );
      // The default stays "a seek went out", so every other arming site keeps
      // waiting for its landing.
      expect(
        shouldConsumeSystemSeekLatch(
            armed: true, bgJump: false, deadlineExpired: false),
        isFalse,
      );
    });
  });

  group('clampScopedFgTarget', () {
    test('a mid-file target is untouched', () {
      expect(clampScopedFgTarget(fgTarget: 10000, fgDurMs: 60000), 10000);
    });

    test('a tail target clamps below the completion guard', () {
      // Parking at the exact duration raises a genuine completed → the
      // 仅当前 path must clamp instead of rolling the foreground.
      expect(clampScopedFgTarget(fgTarget: 60000, fgDurMs: 60000), 59250);
      expect(clampScopedFgTarget(fgTarget: 90000, fgDurMs: 60000), 59250);
    });

    test('a negative/backward target floors at 0 (no roll)', () {
      expect(clampScopedFgTarget(fgTarget: -5000, fgDurMs: 60000), 0);
    });

    test('an unknown duration only floors at 0', () {
      expect(clampScopedFgTarget(fgTarget: 10000, fgDurMs: 0), 10000);
      expect(clampScopedFgTarget(fgTarget: -1, fgDurMs: 0), 0);
    });
  });

  group('resolveActiveRepeat', () {
    test('scenario mode reads the scenario repeat, not the legacy value', () {
      // A lingering legacy Repeat.one must not make the VM hand a segment
      // completion to the outer provider (which skipped the merged item).
      expect(
        resolveActiveRepeat(
          scenarioMode: true,
          appRepeat: Repeat.one,
          scenarioRepeat: Repeat.all,
        ),
        Repeat.all,
      );
    });

    test('legacy mode reads AppState.repeat', () {
      expect(
        resolveActiveRepeat(
          scenarioMode: false,
          appRepeat: Repeat.one,
          scenarioRepeat: Repeat.all,
        ),
        Repeat.one,
      );
    });
  });
}
