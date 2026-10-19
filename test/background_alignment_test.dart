import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/model/enum/bg_align_default.dart';
import 'package:iris/features/background_playback/model/enum/bg_align_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_exhausted_action.dart';
import 'package:iris/features/background_playback/services/background_alignment.dart';

/// 副音 alignment start position + the mandatory remaining-time threshold.
///
/// The mode is applied on every alignment (first file of a run, or a user
/// switch): `target = fgPos - (fgAnchor - bgAnchor)`, clamped into the file.
/// A natural completion is owned by the scope (BgExhaustedAction), not here.
void main() {
  group('bgAlignTargetMs', () {
    test('sameClock seeks the 副音 to the fg position (one clock)', () {
      expect(
        bgAlignTargetMs(
          mode: BgAlignMode.sameClock,
          fgPosMs: 40000,
          bgDurMs: 900000,
          percent: 30,
        ),
        40000,
      );
    });

    test('bgHeadAtFg starts the file at its own 00:00', () {
      expect(
        bgAlignTargetMs(
          mode: BgAlignMode.bgHeadAtFg,
          fgPosMs: 40000,
          bgDurMs: 900000,
          percent: 30,
        ),
        0,
      );
    });

    test('bgPercent starts at the remembered share', () {
      expect(
        bgAlignTargetMs(
          mode: BgAlignMode.bgPercent,
          fgPosMs: 40000,
          bgDurMs: 900000,
          percent: 30,
        ),
        270000,
      );
    });

    test('a target past the 副音 file is clamped to its end', () {
      expect(
        bgAlignTargetMs(
          mode: BgAlignMode.sameClock,
          fgPosMs: 1000000,
          bgDurMs: 900000,
          percent: 30,
        ),
        900000,
      );
    });

    test('an unknown 副音 duration degrades to 0', () {
      expect(
        bgAlignTargetMs(
          mode: BgAlignMode.sameClock,
          fgPosMs: 40000,
          bgDurMs: 0,
          percent: 30,
        ),
        0,
      );
    });
  });

  group('defaultForAlignMode', () {
    test('maps the manual modes onto their persisted default', () {
      expect(
        defaultForAlignMode(BgAlignMode.sameClock),
        BgAlignDefault.sameClock,
      );
      expect(
        defaultForAlignMode(BgAlignMode.bgHeadAtFg),
        BgAlignDefault.bgHead,
      );
      expect(
        defaultForAlignMode(BgAlignMode.bgPercent),
        BgAlignDefault.bgPercent,
      );
    });

    test('尾部锚定 has no persisted default: the automatic rule owns it', () {
      expect(defaultForAlignMode(BgAlignMode.tailAtFg), BgAlignDefault.sameClock);
    });

    test('the persisted keys are frozen at the pre-rename spelling', () {
      // The rename is code-only: a stored preference must keep decoding, and the
      // settings enum values must keep matching.
      expect(BgAlignDefault.sameClock.key, 'fgHead');
      expect(BgAlignDefault.bgHead.key, 'fgPosition');
      expect(BgAlignDefault.bgPercent.key, 'bgPercent');
      for (final v in BgAlignDefault.values) {
        expect(bgAlignDefaultFromName(v.key), v);
      }
    });
  });

  // The AUTOMATIC anchoring rule (see the function's docs): the two real
  // durations decide which 副音 moment maps to the video's current moment.
  group('resolveAutoAlignAnchor', () {
    test('副音 longer than the video: 同刻度 (offset 0)', () {
      final a = resolveAutoAlignAnchor(
        bgDurMs: 7200000,
        fgDurMs: 3600000,
        fgPosMs: 600000,
      );
      expect(a.mode, BgAlignMode.sameClock);
      expect(alignmentOffsetMs(fgAnchorMs: a.fgAnchorMs, bgAnchorMs: a.bgAnchorMs), 0);
      expect(
        bgAlignTargetMs(
          mode: a.mode,
          fgPosMs: 600000,
          bgDurMs: 7200000,
          percent: 30,
          fgDurMs: 3600000,
        ),
        600000,
      );
    });

    test('副音 shorter, video remaining fits inside it: 尾部锚定', () {
      // fg 60min at 40min → 20min left, 副音 30min: the 副音 ends with the video,
      // so it starts at 10min (its first 10min are skipped).
      final a = resolveAutoAlignAnchor(
        bgDurMs: 1800000,
        fgDurMs: 3600000,
        fgPosMs: 2400000,
      );
      expect(a.mode, BgAlignMode.tailAtFg);
      expect(a.fgAnchorMs, 3600000);
      expect(a.bgAnchorMs, 1800000);
      final offset = alignmentOffsetMs(
        fgAnchorMs: a.fgAnchorMs,
        bgAnchorMs: a.bgAnchorMs,
      );
      expect(offset, 1800000); // fgDur - bgDur
      expect(
        bgAlignTargetMs(
          mode: a.mode,
          fgPosMs: 2400000,
          bgDurMs: 1800000,
          percent: 30,
          fgDurMs: 3600000,
        ),
        600000,
      );
    });

    test('副音 shorter, video remaining exceeds it: 从当前位置从头开始', () {
      // fg 60min at 10min → 50min left, 副音 30min: the tail anchor would need a
      // negative 副音 position, so the 副音 starts at its head now.
      final a = resolveAutoAlignAnchor(
        bgDurMs: 1800000,
        fgDurMs: 3600000,
        fgPosMs: 600000,
      );
      expect(a.mode, BgAlignMode.bgHeadAtFg);
      expect(a.fgAnchorMs, 600000);
      expect(a.bgAnchorMs, 0);
      expect(
        bgAlignTargetMs(
          mode: a.mode,
          fgPosMs: 600000,
          bgDurMs: 1800000,
          percent: 30,
          fgDurMs: 3600000,
        ),
        0,
      );
    });

    test('continuous at the tail/head boundary (rem == bgDur)', () {
      // Both branches must seek to the 副音's 00:00, so a millisecond of
      // duration difference cannot flip the position.
      final tail = resolveAutoAlignAnchor(
        bgDurMs: 1800000,
        fgDurMs: 3600000,
        fgPosMs: 1800000,
      );
      final head = resolveAutoAlignAnchor(
        bgDurMs: 1799999,
        fgDurMs: 3600000,
        fgPosMs: 1800000,
      );
      expect(tail.mode, BgAlignMode.tailAtFg);
      expect(head.mode, BgAlignMode.bgHeadAtFg);
      int target(({BgAlignMode mode, int fgAnchorMs, int bgAnchorMs}) a) =>
          bgAlignTargetMs(
            mode: a.mode,
            fgPosMs: 1800000,
            bgDurMs: a.bgAnchorMs == 0 ? 1799999 : 1800000,
            percent: 30,
            fgDurMs: 3600000,
          );
      expect(target(tail), 0);
      expect(target(head), 0);
    });

    test('continuous at the 同刻度/尾部 boundary (bgDur == fgDur)', () {
      final same = resolveAutoAlignAnchor(
        bgDurMs: 3600000,
        fgDurMs: 3600000,
        fgPosMs: 600000,
      );
      final tail = resolveAutoAlignAnchor(
        bgDurMs: 3599000,
        fgDurMs: 3600000,
        fgPosMs: 600000,
      );
      expect(same.mode, BgAlignMode.sameClock);
      expect(tail.mode, BgAlignMode.tailAtFg);
      // Both map the video position onto itself (within the 1s difference).
      expect(
        bgAlignTargetMs(
          mode: same.mode,
          fgPosMs: 600000,
          bgDurMs: 3600000,
          percent: 30,
          fgDurMs: 3600000,
        ),
        600000,
      );
      expect(
        bgAlignTargetMs(
          mode: tail.mode,
          fgPosMs: 600000,
          bgDurMs: 3599000,
          percent: 30,
          fgDurMs: 3600000,
        ),
        599000,
      );
    });

    test('starting at 00:00 is the head branch for any shorter 副音', () {
      final a = resolveAutoAlignAnchor(
        bgDurMs: 600000,
        fgDurMs: 3600000,
        fgPosMs: 0,
      );
      expect(a.mode, BgAlignMode.bgHeadAtFg);
    });

    test('a video with no time left parks the 副音 at its own end', () {
      // The user owns this case (pause first, then align by hand): the rule only
      // has to stay well-defined, never to invent a negative position.
      final a = resolveAutoAlignAnchor(
        bgDurMs: 600000,
        fgDurMs: 3600000,
        fgPosMs: 3600000,
      );
      expect(a.mode, BgAlignMode.tailAtFg);
      expect(
        bgAlignTargetMs(
          mode: a.mode,
          fgPosMs: 3600000,
          bgDurMs: 600000,
          percent: 30,
          fgDurMs: 3600000,
        ),
        600000,
      );
    });

    test('a degenerate duration falls back to 同刻度, never a guess', () {
      for (final a in [
        resolveAutoAlignAnchor(bgDurMs: 0, fgDurMs: 3600000, fgPosMs: 600000),
        resolveAutoAlignAnchor(bgDurMs: 600000, fgDurMs: 0, fgPosMs: 600000),
        resolveAutoAlignAnchor(bgDurMs: -1, fgDurMs: -1, fgPosMs: -1),
      ]) {
        expect(a.mode, BgAlignMode.sameClock);
        expect(a.fgAnchorMs, 0);
        expect(a.bgAnchorMs, 0);
      }
    });

    test('尾部锚定 needs the foreground duration to resolve at all', () {
      // Without it the mode must degrade instead of anchoring on a fake 0.
      expect(
        resolveAlignmentAnchor(
          mode: BgAlignMode.tailAtFg,
          currentFgMs: 600000,
          bgDurMs: 1800000,
          percent: 30,
        ),
        (fgAnchorMs: 0, bgAnchorMs: 0),
      );
    });
  });

  group('modalCloseRealignTargetMs', () {
    // The dialog's close path is an async handler: it has no hooks, and it used
    // to compute its seek WITHOUT the foreground file duration. 尾部锚定 then
    // degraded to 同刻度 and the close seeked to the foreground moment instead of
    // the tail-anchored position.
    test('尾部锚定 lands on the tail-anchored position, not the fg moment', () {
      // fg 10:00 long, 副音 5:00 long, video 9:00 in -> the 副音 tail (5:00) maps
      // to the video's end, so the fg moment 9:00 maps to 副音 4:00.
      final int target = modalCloseRealignTargetMs(
        mode: BgAlignMode.tailAtFg,
        fgPosMs: 9 * 60 * 1000,
        fgDurMs: 10 * 60 * 1000,
        bgDurMs: 5 * 60 * 1000,
        percent: 30,
      );
      expect(target, 4 * 60 * 1000);
      expect(target, isNot(9 * 60 * 1000),
          reason: '9:00 is the 同刻度 degrade the missing duration produced');
    });

    test('the other modes are duration-independent', () {
      for (final mode in <BgAlignMode>[
        BgAlignMode.sameClock,
        BgAlignMode.bgHeadAtFg,
        BgAlignMode.bgPercent,
      ]) {
        expect(
          modalCloseRealignTargetMs(
            mode: mode,
            fgPosMs: 9 * 60 * 1000,
            fgDurMs: 10 * 60 * 1000,
            bgDurMs: 5 * 60 * 1000,
            percent: 30,
          ),
          bgAlignTargetMs(
            mode: mode,
            fgPosMs: 9 * 60 * 1000,
            bgDurMs: 5 * 60 * 1000,
            percent: 30,
          ),
          reason: 'mode=$mode',
        );
      }
    });
  });

  group('alignPercentTargetMs', () {
    test('clamps the share into 0..100', () {
      expect(alignPercentTargetMs(600000, -5), 0);
      expect(alignPercentTargetMs(600000, 0), 0);
      expect(alignPercentTargetMs(600000, 50), 300000);
      expect(alignPercentTargetMs(600000, 100), 600000);
      expect(alignPercentTargetMs(600000, 250), 600000);
    });
  });

  // The mandatory "对齐后 bg 可播放时间 < xxx" threshold: remaining =
  // bgDur - bgPos.
  group('shouldWarnBgRunningOut', () {
    test('warns once the remaining time is below the threshold', () {
      expect(
        shouldWarnBgRunningOut(bgDurMs: 600000, bgPosMs: 596000, thresholdSec: 5),
        isTrue,
      );
      expect(
        shouldWarnBgRunningOut(bgDurMs: 600000, bgPosMs: 590000, thresholdSec: 5),
        isFalse,
      );
    });

    test('a threshold of 0 still warns within a second (never disabled)', () {
      expect(
        shouldWarnBgRunningOut(bgDurMs: 600000, bgPosMs: 599500, thresholdSec: 0),
        isTrue,
      );
    });

    test('an unknown duration never warns', () {
      expect(
        shouldWarnBgRunningOut(bgDurMs: 0, bgPosMs: 0, thresholdSec: 5),
        isFalse,
      );
    });
  });

  // The prompt is suppressed under nextBg (the continuation is automatic) and
  // kept under stopRestoreFg (the user must learn 副音 will stop).
  group('shouldRaiseAlignThreshold', () {
    bool raise(BgExhaustedAction action) => shouldRaiseAlignThreshold(
          enabled: true,
          gateOpen: true,
          exhaustedAction: action,
          bgDurMs: 600000,
          bgPosMs: 599500,
          thresholdSec: 5,
        );

    test('nextBg never raises the prompt', () {
      expect(raise(BgExhaustedAction.nextBg), isFalse);
    });

    test('stopRestoreFg raises it when the remainder is below the threshold', () {
      expect(raise(BgExhaustedAction.stopRestoreFg), isTrue);
    });

    test('a tail-anchored pair never raises it: both end together', () {
      // The 副音 runs out exactly when the VIDEO does, so there is nothing to
      // react to (see [BgAlignMode.tailAtFg]).
      expect(
        shouldRaiseAlignThreshold(
          enabled: true,
          gateOpen: true,
          exhaustedAction: BgExhaustedAction.stopRestoreFg,
          bgDurMs: 600000,
          bgPosMs: 599500,
          thresholdSec: 5,
          tailAnchored: true,
        ),
        isFalse,
      );
    });

    test('a disabled subsystem or a closed gate never raises it', () {
      expect(
        shouldRaiseAlignThreshold(
          enabled: false,
          gateOpen: true,
          exhaustedAction: BgExhaustedAction.stopRestoreFg,
          bgDurMs: 600000,
          bgPosMs: 599500,
          thresholdSec: 5,
        ),
        isFalse,
      );
      expect(
        shouldRaiseAlignThreshold(
          enabled: true,
          gateOpen: false,
          exhaustedAction: BgExhaustedAction.stopRestoreFg,
          bgDurMs: 600000,
          bgPosMs: 599500,
          thresholdSec: 5,
        ),
        isFalse,
      );
    });
  });

  group('clampAlignWarnRemainSec', () {
    test('floors at 1s and caps at 120s (cannot be off)', () {
      expect(clampAlignWarnRemainSec(0), 1);
      expect(clampAlignWarnRemainSec(-5), 1);
      expect(clampAlignWarnRemainSec(5), 5);
      expect(clampAlignWarnRemainSec(500), 120);
    });
  });

  group('resolveBgAlignmentChoice (VM tiled manual)', () {
    test('from-head starts the 副音 file at 00:00', () {
      expect(
        resolveBgAlignmentChoice(
          choice: BgAlignChoice.fromHead,
          bgDurMs: 600000,
        ),
        0,
      );
    });

    test('percent starts at percent% of the 副音 file', () {
      expect(
        resolveBgAlignmentChoice(
          choice: BgAlignChoice.percent,
          bgDurMs: 600000,
          percent: 30,
        ),
        180000,
      );
    });

    test('an unknown duration degrades to the head', () {
      expect(
        resolveBgAlignmentChoice(
          choice: BgAlignChoice.percent,
          bgDurMs: 0,
          percent: 30,
        ),
        0,
      );
    });
  });

  group('bgEffectiveRemainingMs', () {
    test('without a window the raw file remainder applies', () {
      expect(
        bgEffectiveRemainingMs(bgDurMs: 600000, bgPosMs: 100000),
        500000,
      );
    });

    test('a 仅当前 ceiling caps the playable remainder', () {
      expect(
        bgEffectiveRemainingMs(
          bgDurMs: 600000,
          bgPosMs: 100000,
          ceilingLocalMs: 103000,
        ),
        3000,
      );
    });

    test('parked past the ceiling floors at zero (nothing playable)', () {
      expect(
        bgEffectiveRemainingMs(
          bgDurMs: 600000,
          bgPosMs: 200000,
          ceilingLocalMs: 103000,
        ),
        0,
      );
    });
  });

  group('shouldWarnBgRunningOut with a window ceiling', () {
    test('warns on the window remainder, not the raw remainder', () {
      // Raw remainder is ample (500s) but the window leaves 3s < 5s.
      expect(
        shouldWarnBgRunningOut(
          bgDurMs: 600000,
          bgPosMs: 100000,
          thresholdSec: 5,
          ceilingLocalMs: 103000,
        ),
        isTrue,
      );
    });

    test('stays quiet when the window remainder is ample', () {
      expect(
        shouldWarnBgRunningOut(
          bgDurMs: 600000,
          bgPosMs: 100000,
          thresholdSec: 5,
          ceilingLocalMs: 200000,
        ),
        isFalse,
      );
    });
  });

  group('modalCloseNeedsRealign', () {
    test('realigns when the file changed behind the modal', () {
      expect(
        modalCloseNeedsRealign(
          entryKey: 'a',
          exitKey: 'b',
          enabled: true,
          bgExhausted: false,
        ),
        isTrue,
      );
    });

    test('stays put when the file is unchanged, disabled, or terminal', () {
      expect(
        modalCloseNeedsRealign(
          entryKey: 'a',
          exitKey: 'a',
          enabled: true,
          bgExhausted: false,
        ),
        isFalse,
      );
      expect(
        modalCloseNeedsRealign(
          entryKey: 'a',
          exitKey: 'b',
          enabled: false,
          bgExhausted: false,
        ),
        isFalse,
      );
      expect(
        modalCloseNeedsRealign(
          entryKey: 'a',
          exitKey: 'b',
          enabled: true,
          bgExhausted: true,
        ),
        isFalse,
      );
      expect(
        modalCloseNeedsRealign(
          entryKey: null,
          exitKey: 'b',
          enabled: true,
          bgExhausted: false,
        ),
        isFalse,
      );
    });
  });

  group('shouldRestoreBgAfterModal', () {
    test('a terminal run is never revived, even when it was playing', () {
      expect(
        shouldRestoreBgAfterModal(bgWasPlaying: true, bgExhausted: true),
        isFalse,
      );
    });

    test('a live run resumes only when it was playing', () {
      expect(
        shouldRestoreBgAfterModal(bgWasPlaying: true, bgExhausted: false),
        isTrue,
      );
      expect(
        shouldRestoreBgAfterModal(bgWasPlaying: false, bgExhausted: false),
        isFalse,
      );
    });

    test('a gate closed behind the modal blocks the 副音 restore', () {
      expect(
        shouldRestoreBgAfterModal(
          bgWasPlaying: true,
          bgExhausted: false,
          gateOpen: false,
        ),
        isFalse,
        reason: 'a stop pressed while the dialog was up owns the transport',
      );
    });
  });

  group('resolveAlignAnchorIndex', () {
    // The pin is `fileLocalOffset - prefix`, and the prefix belongs to the
    // CURRENT window — so the aligned file is located by media KEY, never by a
    // numeric index: a window rebuild keeps the PLAYING file and re-pages around
    // it, and an index taken in the old order points at unrelated content.
    const List<String> window = <String>['s1:x', 's1:a', 's1:b'];

    test('finds the aligned file wherever the rebuild put it', () {
      expect(
        resolveAlignAnchorIndex(anchorKey: 's1:a', queueKeys: window),
        1,
      );
      expect(
        resolveAlignAnchorIndex(anchorKey: 's1:b', queueKeys: window),
        2,
      );
    });

    test('prefers the key over the stale fallback index', () {
      // A rebuild reordered the window: the recorded index (0) now names a
      // DIFFERENT file, so the key must win.
      expect(
        resolveAlignAnchorIndex(
          anchorKey: 's1:b',
          queueKeys: window,
          fallbackIndex: 0,
        ),
        2,
      );
    });

    test('falls back to the open index only while no key has been pinned', () {
      expect(
        resolveAlignAnchorIndex(
          anchorKey: null,
          queueKeys: window,
          fallbackIndex: 2,
        ),
        2,
      );
      // The fallback is a real index check, never a fabricated one.
      expect(
        resolveAlignAnchorIndex(
          anchorKey: null,
          queueKeys: window,
          fallbackIndex: 3,
        ),
        isNull,
      );
      expect(
        resolveAlignAnchorIndex(anchorKey: null, queueKeys: window),
        isNull,
      );
    });

    test('an aligned file that LEFT the window resolves to null (freeze)', () {
      // Its prefix is unknowable, so the caller must keep the previous pin
      // rather than re-derive one from another file's prefix.
      expect(
        resolveAlignAnchorIndex(
          anchorKey: 's1:gone',
          queueKeys: window,
          fallbackIndex: 1,
        ),
        isNull,
      );
    });
  });
}
