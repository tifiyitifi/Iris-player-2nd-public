import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/utils/platform.dart' show debugIsMobilePlatformOverride;

/// "Which side is this?" must have exactly ONE answer per state.
///
/// The panel's POSITION comes from the 9-grid anchor (3 horizontal values)
/// while its HANDEDNESS semantics (ring-dial mirror, inward/outward, hide
/// direction fallback) came from a 2-valued use mode — two states that can
/// disagree. Every consumer therefore resolves through this one function, so
/// the dial can no longer mirror one way while the buttons align the other.
void main() {
  bool resolve(Alignment anchor, PhoneLandscapeUseMode mode) =>
      resolvePanelSideIsLeft(anchor: anchor, mode: mode);

  group('resolvePanelSideIsLeft — the anchor decides when it has an opinion', () {
    test('a left-docked anchor is the left hand, whatever the mode says', () {
      for (final PhoneLandscapeUseMode mode in PhoneLandscapeUseMode.values) {
        for (final Alignment anchor in <Alignment>[
          Alignment.centerLeft,
          Alignment.topLeft,
          Alignment.bottomLeft,
        ]) {
          expect(resolve(anchor, mode), isTrue,
              reason: '$anchor must read as the left hand (mode $mode)');
        }
      }
    });

    test('a right-docked anchor is the right hand, whatever the mode says', () {
      for (final PhoneLandscapeUseMode mode in PhoneLandscapeUseMode.values) {
        for (final Alignment anchor in <Alignment>[
          Alignment.centerRight,
          Alignment.topRight,
          Alignment.bottomRight,
        ]) {
          expect(resolve(anchor, mode), isFalse,
              reason: '$anchor must read as the right hand (mode $mode)');
        }
      }
    });
  });

  group('resolvePanelSideIsLeft — a centre anchor keeps the stored hand', () {
    test('centre columns defer to the use mode instead of guessing', () {
      for (final Alignment anchor in <Alignment>[
        Alignment.topCenter,
        Alignment.center,
        Alignment.bottomCenter,
      ]) {
        expect(
          resolve(anchor, PhoneLandscapeUseMode.leftSide),
          isTrue,
          reason: '$anchor + leftSide must stay left-handed',
        );
        expect(
          resolve(anchor, PhoneLandscapeUseMode.rightSide),
          isFalse,
          reason: '$anchor + rightSide must stay right-handed',
        );
      }
    });

    test('normal mode is neither hand — it falls back to right', () {
      // [PhoneLandscapeUseMode.normal] never renders a side panel, so the
      // value is arbitrary; pinning it keeps the helper total.
      expect(resolve(Alignment.center, PhoneLandscapeUseMode.normal), isFalse);
    });
  });

  group('resolvePanelSideIsLeft — AppState overload tracks the resolved anchor',
      () {
    // Phones read `mobileSidePositionH`, desktop the 9-grid `posH`/`posV`, so
    // each group has to state which platform it is exercising.
    void runOn({required bool phone}) {
      debugIsMobilePlatformOverride = phone;
      addTearDown(() => debugIsMobilePlatformOverride = null);
    }

    const AppState state = AppState(
      useMetadataSettings: true,
      phoneLandscapeUseMode: PhoneLandscapeUseMode.leftSide,
      mobileSidePositionH: PhoneSidePositionH.left,
      phoneSidePositionH: PhoneSidePositionH.left,
      phoneSidePositionV: PhoneSidePositionV.middle,
    );

    test('reads the phone anchor on a phone', () {
      runOn(phone: true);
      expect(panelIsLeftHanded(state), isTrue);
      expect(
        panelIsLeftHanded(
          state.copyWith(mobileSidePositionH: PhoneSidePositionH.right),
        ),
        isFalse,
      );
    });

    test('agrees with the desktop anchor, hand included', () {
      runOn(phone: false);
      final Alignment anchor = resolveSidePanelAlignment(state);
      expect(anchor.x, lessThan(0));
      expect(panelIsLeftHanded(state), isTrue);
    });

    test('a centre desktop anchor keeps the stored hand', () {
      runOn(phone: false);
      final AppState centred = state.copyWith(
        phoneSidePositionH: PhoneSidePositionH.center,
      );
      expect(resolveSidePanelAlignment(centred).x, 0);
      expect(
        panelIsLeftHanded(centred),
        isTrue,
        reason: 'centre has no direction, so the stored hand must survive',
      );
    });
  });

  group('a deprecated one-handed mode never survives a write', () {
    // `leftHanded` / `rightHanded` stay parseable so an old blob loads, and
    // `AppStore._normalizeLoaded` folds them. But a settings import applies a
    // snapshot straight onto the state WITHOUT that normalization, so a mode
    // written back by any store setter has to fold it itself: `isLeftSide` /
    // `isRightSide` deliberately ignore the deprecated members, so an unfolded
    // value reads as NO side and the hand silently flips.
    test('live maps each deprecated member onto its replacement', () {
      expect(
        // ignore: deprecated_member_use_from_same_package
        PhoneLandscapeUseMode.leftHanded.live,
        PhoneLandscapeUseMode.leftSide,
      );
      expect(
        // ignore: deprecated_member_use_from_same_package
        PhoneLandscapeUseMode.rightHanded.live,
        PhoneLandscapeUseMode.rightSide,
      );
      for (final PhoneLandscapeUseMode live in kLivePhoneLandscapeUseModes) {
        expect(live.live, live, reason: '$live is already live');
      }
    });

    test('a centre anchor folds the kept hand instead of re-persisting it', () {
      expect(
        useModeForAnchorH(
          PhoneSidePositionH.center,
          // ignore: deprecated_member_use_from_same_package
          PhoneLandscapeUseMode.leftHanded,
        ),
        PhoneLandscapeUseMode.leftSide,
      );
      expect(
        useModeForAnchorH(
          PhoneSidePositionH.center,
          // ignore: deprecated_member_use_from_same_package
          PhoneLandscapeUseMode.rightHanded,
        ),
        PhoneLandscapeUseMode.rightSide,
      );
    });

    test('a folded hand still resolves to the hand it names', () {
      final PhoneLandscapeUseMode left = useModeForAnchorH(
        PhoneSidePositionH.center,
        // ignore: deprecated_member_use_from_same_package
        PhoneLandscapeUseMode.leftHanded,
      );
      expect(resolve(Alignment.center, left), isTrue,
          reason: 'a centre anchor + left hand must stay the left hand');
      final PhoneLandscapeUseMode right = useModeForAnchorH(
        PhoneSidePositionH.center,
        // ignore: deprecated_member_use_from_same_package
        PhoneLandscapeUseMode.rightHanded,
      );
      expect(resolve(Alignment.center, right), isFalse);
    });

    test('a positional anchor still wins over the folded hand', () {
      for (final PhoneLandscapeUseMode mode in <PhoneLandscapeUseMode>[
        PhoneLandscapeUseMode.normal,
        // ignore: deprecated_member_use_from_same_package
        PhoneLandscapeUseMode.leftHanded,
        // ignore: deprecated_member_use_from_same_package
        PhoneLandscapeUseMode.rightHanded,
      ]) {
        expect(useModeForAnchorH(PhoneSidePositionH.left, mode),
            PhoneLandscapeUseMode.leftSide);
        expect(useModeForAnchorH(PhoneSidePositionH.right, mode),
            PhoneLandscapeUseMode.rightSide);
      }
    });
  });
}
