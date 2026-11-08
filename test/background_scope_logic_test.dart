import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_scope_logic.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/model/enum/bg_cross_action.dart';

/// Activation scope of one 副音 run (作用范围).
///
/// - all        → keeps playing across foreground media switches;
/// - currentOnly→ anchored to one media: leaving pauses, returning resumes;
/// - smart      → a media with a saved 副音 pairing starts 副音, others pause.
///
/// A media the user explicitly closed 副音 for always pauses, whatever the
/// scope.
void main() {
  group('resolveBgScopeOnFgChange', () {
    test('副音 off is a no-op regardless of the scope fields', () {
      expect(
        resolveBgScopeOnFgChange(
          enabled: false,
          applyScope: BgApplyScope.currentOnly,
          anchorKey: 'a',
          newFgKey: 'b',
        ),
        BgScopeAction.none,
      );
      expect(
        resolveBgScopeOnFgChange(
          enabled: false,
          applyScope: BgApplyScope.all,
          anchorKey: null,
          newFgKey: null,
        ),
        BgScopeAction.none,
      );
    });

    test('a null foreground key (no media loaded) is not a switch', () {
      expect(
        resolveBgScopeOnFgChange(
          enabled: true,
          applyScope: BgApplyScope.currentOnly,
          anchorKey: 'a',
          newFgKey: null,
        ),
        BgScopeAction.none,
      );
    });

    test('all keeps playing across foreground media switches', () {
      expect(
        resolveBgScopeOnFgChange(
          enabled: true,
          applyScope: BgApplyScope.all,
          anchorKey: null,
          newFgKey: 'b',
        ),
        BgScopeAction.none,
      );
    });

    test('currentOnly pauses when leaving the anchored media', () {
      expect(
        resolveBgScopeOnFgChange(
          enabled: true,
          applyScope: BgApplyScope.currentOnly,
          anchorKey: 'a',
          newFgKey: 'b',
        ),
        BgScopeAction.pauseBg,
      );
    });

    test('currentOnly resumes when returning to the anchored media', () {
      expect(
        resolveBgScopeOnFgChange(
          enabled: true,
          applyScope: BgApplyScope.currentOnly,
          anchorKey: 'a',
          newFgKey: 'a',
        ),
        BgScopeAction.resumeBg,
      );
    });

    test('currentOnly without an anchor never touches playback', () {
      expect(
        resolveBgScopeOnFgChange(
          enabled: true,
          applyScope: BgApplyScope.currentOnly,
          anchorKey: null,
          newFgKey: 'b',
        ),
        BgScopeAction.none,
      );
    });

    test('smart starts on a media with a saved 副音 pairing', () {
      expect(
        resolveBgScopeOnFgChange(
          enabled: true,
          applyScope: BgApplyScope.smart,
          anchorKey: null,
          newFgKey: 'b',
          newFgHasSavedMapping: true,
        ),
        BgScopeAction.startBg,
      );
    });

    test('smart leaves a new media off when it has no pairing', () {
      expect(
        resolveBgScopeOnFgChange(
          enabled: true,
          applyScope: BgApplyScope.smart,
          anchorKey: null,
          newFgKey: 'b',
          newFgHasSavedMapping: false,
        ),
        BgScopeAction.pauseBg,
      );
    });

    test('smart auto-starts even while 副音 is off', () {
      // The scope observer only ever produces [BgScopeAction.startBg] while the
      // run is enabled; if an enabled run made it a no-op the "已保存副音自动播放"
      // feature could never fire. It must also fire from a cold (disabled) state.
      expect(
        resolveBgScopeOnFgChange(
          enabled: false,
          applyScope: BgApplyScope.smart,
          anchorKey: null,
          newFgKey: 'b',
          newFgHasSavedMapping: true,
        ),
        BgScopeAction.startBg,
      );
    });

    test('smart stays idle while 副音 is off and the media has no pairing', () {
      expect(
        resolveBgScopeOnFgChange(
          enabled: false,
          applyScope: BgApplyScope.smart,
          anchorKey: null,
          newFgKey: 'b',
          newFgHasSavedMapping: false,
        ),
        BgScopeAction.none,
      );
    });

    test('an explicitly closed media pauses whatever the scope', () {
      for (final scope in BgApplyScope.values) {
        expect(
          resolveBgScopeOnFgChange(
            enabled: true,
            applyScope: scope,
            anchorKey: 'b',
            newFgKey: 'b',
            offMediaKeys: const {'b'},
            newFgHasSavedMapping: true,
          ),
          BgScopeAction.pauseBg,
          reason: '$scope must not outrank the per-media off set',
        );
      }
    });

    test('简播 pauses 副音 under EVERY scope, even on the anchor', () {
      // The cut owns the picture and a virtual timeline 副音 cannot align to.
      // It is temporary, so this is a pause — never a `none` that would leave
      // an untethered track playing against the cut.
      for (final scope in BgApplyScope.values) {
        expect(
          resolveBgScopeOnFgChange(
            enabled: true,
            applyScope: scope,
            anchorKey: 'a',
            newFgKey: 'a',
            newFgHasSavedMapping: true,
            fakeCutActive: true,
          ),
          BgScopeAction.pauseBg,
          reason: '$scope must stand down for a fake cut',
        );
      }
    });

    test('简播 outranks the smart auto-start', () {
      expect(
        resolveBgScopeOnFgChange(
          enabled: true,
          applyScope: BgApplyScope.smart,
          anchorKey: null,
          newFgKey: 'a',
          newFgHasSavedMapping: true,
          fakeCutActive: true,
        ),
        BgScopeAction.pauseBg,
      );
    });

    test('a terminal stopRestoreFg run never resumes on a return', () {
      // Leaving and coming back used to resolve to `resumeBg`, which set the
      // transport on a run whose 副音 track is muted to 0 — a silent engine
      // occupying the control bar. Exhausted wins over every scope.
      for (final scope in BgApplyScope.values) {
        expect(
          resolveBgScopeOnFgChange(
            enabled: true,
            applyScope: scope,
            anchorKey: 'a',
            newFgKey: 'a',
            newFgHasSavedMapping: true,
            exhausted: true,
          ),
          BgScopeAction.none,
          reason: '$scope must not revive a terminal run',
        );
      }
    });
  });

  group('mappingMayDrive (E 節 driver gate)', () {
    bool may({
      bool enabled = true,
      bool gateOpen = true,
      bool mappingEnabled = true,
      bool scopeApplied = true,
      bool exhausted = false,
      bool queueEnded = false,
    }) =>
        mappingMayDrive(
          enabled: enabled,
          gateOpen: gateOpen,
          mappingEnabled: mappingEnabled,
          scopeApplied: scopeApplied,
          exhausted: exhausted,
          queueEnded: queueEnded,
        );

    test('drives only with every switch on', () {
      expect(may(), isTrue);
      expect(may(enabled: false), isFalse);
      expect(may(gateOpen: false), isFalse);
      expect(may(mappingEnabled: false), isFalse);
      expect(may(scopeApplied: false), isFalse);
      expect(may(exhausted: true), isFalse);
    });

    test('a queue that ran off its end must not be re-entered', () {
      // `Repeat.none` at the list's end handed the pair back to the video. The
      // driver re-entering a mapped segment sets `bgAutoPlay: true`, which the
      // engine's autoplay sync turns into a real play() — 副音 sounds while the
      // UI reports "not in effect" (no duck, no title, controls on the video)
      // and the transport mirror stands down, so a fg pause no longer reaches
      // it. Same gate as `bgMirrorStandsDown`.
      expect(may(queueEnded: true), isFalse);
    });
  });

  group('bgCrossStepAllowed (副音 队列 under a fake cut)', () {
    /// 全部 scope + 切新bg = the one case that advances 副音's own queue.
    bool allowed({
      bool enabled = true,
      bool vmSessionActive = false,
      bool gateOpen = true,
      BgCrossAction itemSwitch = BgCrossAction.newBg,
      bool fakeCutActive = false,
      bool prevFakeCutActive = false,
      bool fgChanged = true,
      BgScopeAction scopeAction = BgScopeAction.none,
    }) =>
        bgCrossStepAllowed(
          enabled: enabled,
          vmSessionActive: vmSessionActive,
          gateOpen: gateOpen,
          itemSwitch: itemSwitch,
          fakeCutActive: fakeCutActive,
          prevFakeCutActive: prevFakeCutActive,
          fgChanged: fgChanged,
          scopeAction: scopeAction,
        );

    test('a plain 全部 switch advances', () {
      expect(allowed(), isTrue);
    });

    test('a cut suppresses the step in BOTH directions', () {
      // A'(no cut) → A(cut): entering must not move the silent queue.
      expect(allowed(fakeCutActive: true), isFalse);
      // A(cut) → B(cut): the reported defect.
      expect(allowed(fakeCutActive: true, prevFakeCutActive: true), isFalse);
      // B(cut) → C(no cut): leaving must leave the queue where resume finds it.
      expect(allowed(prevFakeCutActive: true), isFalse);
    });

    test('every other guard still wins', () {
      expect(allowed(enabled: false), isFalse);
      expect(allowed(vmSessionActive: true), isFalse);
      expect(allowed(gateOpen: false), isFalse);
      expect(allowed(itemSwitch: BgCrossAction.keepPlaying), isFalse);
      expect(allowed(fgChanged: false), isFalse);
      expect(allowed(scopeAction: BgScopeAction.pauseBg), isFalse);
    });
  });

  group('resolveApplyToCurrent (quick-bar apply toggle)', () {
    test('off while 副音 is not running', () {
      expect(
        resolveApplyToCurrent(
          enabled: false,
          applyScope: BgApplyScope.all,
          anchorKey: null,
          offMediaKeys: const <String>{},
          fgKey: 'a',
        ),
        isFalse,
      );
    });

    test('on for all / smart while 副音 runs', () {
      for (final scope in [BgApplyScope.all, BgApplyScope.smart]) {
        expect(
          resolveApplyToCurrent(
            enabled: true,
            applyScope: scope,
            anchorKey: 'a',
            offMediaKeys: const <String>{},
            fgKey: 'a',
          ),
          isTrue,
        );
      }
    });

    test('currentOnly is on only for its anchored media', () {
      expect(
        resolveApplyToCurrent(
          enabled: true,
          applyScope: BgApplyScope.currentOnly,
          anchorKey: 'a',
          offMediaKeys: const <String>{},
          fgKey: 'a',
        ),
        isTrue,
      );
      expect(
        resolveApplyToCurrent(
          enabled: true,
          applyScope: BgApplyScope.currentOnly,
          anchorKey: 'a',
          offMediaKeys: const <String>{},
          fgKey: 'b',
        ),
        isFalse,
      );
    });

    test('an explicitly closed media reads as not applied', () {
      expect(
        resolveApplyToCurrent(
          enabled: true,
          applyScope: BgApplyScope.all,
          anchorKey: null,
          offMediaKeys: const {'a'},
          fgKey: 'a',
        ),
        isFalse,
      );
    });

    test('简播 reads as not applied under every scope', () {
      for (final scope in BgApplyScope.values) {
        expect(
          resolveApplyToCurrent(
            enabled: true,
            applyScope: scope,
            anchorKey: 'a',
            offMediaKeys: const <String>{},
            fgKey: 'a',
            fakeCutActive: true,
          ),
          isFalse,
          reason: '$scope must grey out on a fake cut',
        );
      }
    });
  });

  group('isForwardQueueMove (副音 队列 direction on a foreground switch)', () {
    test('a normal step forward / backward follows the position', () {
      expect(
        isForwardQueueMove(
            previousIndex: 3, currentIndex: 4, firstIndex: 1, lastIndex: 9),
        isTrue,
      );
      expect(
        isForwardQueueMove(
            previousIndex: 4, currentIndex: 3, firstIndex: 1, lastIndex: 9),
        isFalse,
      );
    });

    test('an unknown or missing previous index counts as forward', () {
      expect(
          isForwardQueueMove(
              previousIndex: null, currentIndex: 5, firstIndex: 1, lastIndex: 9),
          isTrue);
      expect(
          isForwardQueueMove(
              previousIndex: -1, currentIndex: 5, firstIndex: 1, lastIndex: 9),
          isTrue);
      expect(
          isForwardQueueMove(
              previousIndex: 5, currentIndex: -1, firstIndex: 1, lastIndex: 9),
          isTrue);
    });

    test('a last → head wrap is a forward move, whatever the id gap', () {
      // `PlayQueueStore.next()` wraps to `playQueue.first.index`. The ids are
      // NOT dense positions (an insert takes `maxIndex + 1`, a removal leaves a
      // hole), so comparing against `playQueue.length - 1` missed the wrap and
      // stepped 副音 BACKWARD on it.
      expect(
        isForwardQueueMove(
            previousIndex: 412, currentIndex: 7, firstIndex: 7, lastIndex: 412),
        isTrue,
      );
    });

    test('a genuine backward move is never read as a forward wrap', () {
      expect(
        isForwardQueueMove(
            previousIndex: 30, currentIndex: 7, firstIndex: 7, lastIndex: 412),
        isFalse,
      );
    });

    test('a two-entry queue is only resolvable with the direction stamp', () {
      // 「下一集」 at the head wraps onto the tail and 「上一集」 at the head does
      // the very same thing: both produce (first → last), so the ids alone
      // cannot tell them apart. Whatever the queue itself stamped wins.
      expect(
        isForwardQueueMove(
            previousIndex: 1, currentIndex: 2, firstIndex: 1, lastIndex: 2),
        isTrue,
        reason: 'ids alone: indistinguishable, so they read as forward',
      );
      expect(
        isForwardQueueMove(
          previousIndex: 1,
          currentIndex: 2,
          firstIndex: 1,
          lastIndex: 2,
          moveWasForward: false,
        ),
        isFalse,
        reason: 'the queue said 「上一集」 — it wrapped backwards',
      );
    });

    test('the stamp also resolves the head → tail wrap on a long queue', () {
      // 3+ entries: the same (first → last) pair is ALSO what tapping the last
      // row produces, so only the stamp can separate a wrap from a jump.
      expect(
        isForwardQueueMove(
          previousIndex: 7,
          currentIndex: 412,
          firstIndex: 7,
          lastIndex: 412,
          moveWasForward: false,
        ),
        isFalse,
      );
      expect(
        isForwardQueueMove(
          previousIndex: 7,
          currentIndex: 412,
          firstIndex: 7,
          lastIndex: 412,
          moveWasForward: true,
        ),
        isTrue,
        reason: 'a row tap onto the last entry is a forward jump',
      );
    });

    test('a stamp is not overruled by the id order in the normal direction', () {
      expect(
        isForwardQueueMove(
          previousIndex: 4,
          currentIndex: 3,
          firstIndex: 1,
          lastIndex: 9,
          moveWasForward: true,
        ),
        isTrue,
      );
    });
  });
}
