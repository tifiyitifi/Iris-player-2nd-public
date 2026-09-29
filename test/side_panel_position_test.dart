import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/utils/platform.dart'
    show
        debugIsDesktopOverride,
        debugIsMobilePlatformOverride,
        isMobilePlatform;

AppState _state({
  required bool gate,
  PhoneLandscapeUseMode mode = PhoneLandscapeUseMode.rightSide,
  PhoneSidePositionH h = PhoneSidePositionH.right,
  PhoneSidePositionV v = PhoneSidePositionV.bottom,
  PhoneSidePositionH mobileH = PhoneSidePositionH.right,
  PhoneLandscapeSliderType sliderType = PhoneLandscapeSliderType.circleRight,
}) =>
    AppState(
      useMetadataSettings: gate,
      phoneLandscapeUseMode: mode,
      phoneSidePositionH: h,
      phoneSidePositionV: v,
      mobileSidePositionH: mobileH,
      phoneLandscapeSliderType: sliderType,
    );

/// Pins BOTH platform seams and clears them when the case ends.
///
/// [debugIsMobilePlatformOverride] alone is not enough. Every consumer here
/// reaches the platform through one of two expressions, and the desktop test
/// runner satisfies both: `sidewayPanelHostSupported` reads `isDesktop`, and
/// `resolveSidePanelAlignmentFrom` reads `isMobilePlatformForSidePanel()`. Set
/// only the mobile flag and `isDesktop` stays true, so either one re-derived as
/// `isDesktop` still answers the runner's platform and the case goes green
/// while the phone it is meant to pin is broken. Forcing both is the only way
/// the production expression becomes observable to a test at all.
void asPhone() {
  debugIsMobilePlatformOverride = true;
  debugIsDesktopOverride = false;
  addTearDown(_clearPlatformSeams);
}

void asDesktop() {
  debugIsDesktopOverride = true;
  debugIsMobilePlatformOverride = false;
  addTearDown(_clearPlatformSeams);
}

void _clearPlatformSeams() {
  debugIsMobilePlatformOverride = null;
  debugIsDesktopOverride = null;
}

void main() {
  group('resolveSidePanelAlignment — meta gate ON (9-grid anchors)', () {
    test('horizontal × vertical combos map to the matching Alignment', () {
      final cases = <(PhoneSidePositionH, PhoneSidePositionV, Alignment)>[
        (PhoneSidePositionH.left, PhoneSidePositionV.top, Alignment.topLeft),
        (
          PhoneSidePositionH.center,
          PhoneSidePositionV.top,
          Alignment.topCenter
        ),
        (
          PhoneSidePositionH.right,
          PhoneSidePositionV.top,
          Alignment.topRight
        ),
        (
          PhoneSidePositionH.left,
          PhoneSidePositionV.middle,
          Alignment.centerLeft
        ),
        (PhoneSidePositionH.center, PhoneSidePositionV.middle, Alignment.center),
        (
          PhoneSidePositionH.right,
          PhoneSidePositionV.middle,
          Alignment.centerRight
        ),
        (
          PhoneSidePositionH.left,
          PhoneSidePositionV.bottom,
          Alignment.bottomLeft
        ),
        (
          PhoneSidePositionH.center,
          PhoneSidePositionV.bottom,
          Alignment.bottomCenter
        ),
        (
          PhoneSidePositionH.right,
          PhoneSidePositionV.bottom,
          Alignment.bottomRight
        ),
      ];
      for (final (h, v, expected) in cases) {
        expect(
          resolveSidePanelAlignment(_state(gate: true, h: h, v: v)),
          expected,
          reason: '$h × $v should anchor at $expected',
        );
      }
    });
  });

  group('resolveSidePanelAlignment — degradation', () {
    test('gate OFF falls back to the mode-derived corner', () {
      expect(
        resolveSidePanelAlignment(_state(
          gate: false,
          mode: PhoneLandscapeUseMode.leftSide,
          h: PhoneSidePositionH.right,
          v: PhoneSidePositionV.top,
        )),
        Alignment.bottomLeft,
      );
      expect(
        resolveSidePanelAlignment(_state(
          gate: false,
          mode: PhoneLandscapeUseMode.rightSide,
        )),
        Alignment.bottomRight,
      );
    });

    test('normal mode always anchors bottom-center', () {
      expect(
        resolveSidePanelAlignment(_state(
          gate: true,
          mode: PhoneLandscapeUseMode.normal,
          h: PhoneSidePositionH.left,
          v: PhoneSidePositionV.top,
        )),
        Alignment.bottomCenter,
      );
    });
  });

  group('resolveControlPanelAnchor — where the panel box ACTUALLY lands', () {
    // Host-gated through the seam rather than through the running machine, and
    // the PLATFORM seams pinned too. `resolveSidePanelAlignmentFrom` still
    // branches on `isMobilePlatformForSidePanel()`, which reads neither host
    // seam — so without `asDesktop()` this group's desktop-ness is an accident
    // of the runner, not a fact the file states.
    group('desktop host', () {
      setUp(() => debugSidewayPanelHostOverride = true);
      tearDown(() => debugSidewayPanelHostOverride = null);

      test('one-handed desk keeps the 9-grid anchor in either orientation', () {
        asDesktop();
        expect(
          resolveControlPanelAnchor(
            _state(gate: true, h: PhoneSidePositionH.left),
            isLandscape: false,
            width: 1920,
          ),
          Alignment.bottomLeft,
        );
        expect(
          resolveControlPanelAnchor(
            _state(gate: true, h: PhoneSidePositionH.left),
            isLandscape: true,
            width: 1920,
          ),
          Alignment.bottomLeft,
        );
      });

      // The parity that the four hand-written copies of the mount gate broke:
      // the resolver must place the panel off-centre exactly when
      // isSidewayPanelMounted says a panel is on screen. Any anchor that
      // bottom-centres a MOUNTED panel (or docks an unmounted one) is the bug.
      test('anchor and the mount gate agree over the whole 9-grid', () {
        asDesktop();
        expect(
          isSidewayPanelMounted(
            oneHanded: true,
            isPhone: isMobilePlatform,
            isLandscape: true,
          ),
          isTrue,
          reason: 'precondition: this host mounts the one-handed panel',
        );
        for (final PhoneSidePositionH h in PhoneSidePositionH.values) {
          for (final PhoneSidePositionV v in PhoneSidePositionV.values) {
            final Alignment anchor = resolveControlPanelAnchor(
              _state(gate: true, h: h, v: v, mode: PhoneLandscapeUseMode.leftSide),
              isLandscape: true,
              width: 1920,
            );
            expect(
              anchor != Alignment.bottomCenter ||
                  h == PhoneSidePositionH.center,
              isTrue,
              reason: '$h × $v: a MOUNTED panel must never collapse to '
                  'bottom-centre — that is the Linux/macOS-host bug, where the '
                  'bar mounted a side panel the overlay placed as a linear bar',
            );
          }
        }
      });
    });

    group('host without the side panel', () {
      setUp(() => debugSidewayPanelHostOverride = false);
      tearDown(() => debugSidewayPanelHostOverride = null);

      // A one-handed mode persisted on a shipping platform must not dock a
      // panel on a host that has none — the bar would render a side panel the
      // overlay then places and hides as a linear bottom bar.
      test('a one-handed mode never docks the panel off-centre', () {
        for (final PhoneSidePositionH h in PhoneSidePositionH.values) {
          for (final PhoneSidePositionV v in PhoneSidePositionV.values) {
            for (final PhoneLandscapeUseMode mode
                in <PhoneLandscapeUseMode>[
              PhoneLandscapeUseMode.leftSide,
              PhoneLandscapeUseMode.rightSide,
            ]) {
              expect(
                resolveControlPanelAnchor(
                  _state(gate: true, mode: mode, h: h, v: v),
                  isLandscape: true,
                  width: 1920,
                ),
                Alignment.bottomCenter,
                reason: '$mode at $h × $v: no panel on this host, so nothing '
                    'may dock off-centre',
              );
            }
          }
        }
      });
    });

    // [asPhone] pins the real Android combination (desktop=false, mobile=true)
    // and leaves the host seam at its production value — see its doc for why the
    // desktop flag is the half that matters.
    test('one-handed phone landscape follows the phone anchor', () {
      asPhone();

      expect(
        resolveControlPanelAnchor(
          _state(gate: true, mobileH: PhoneSidePositionH.left),
          isLandscape: true,
          width: 800,
        ),
        Alignment.bottomLeft,
      );
      expect(
        resolveControlPanelAnchor(
          _state(gate: true, mobileH: PhoneSidePositionH.right),
          isLandscape: true,
          width: 800,
        ),
        Alignment.bottomRight,
      );
    });

    test('one-handed mode wins over the plain circle corner', () {
      asPhone();

      // One-handed (anchor right) + a circle-LEFT slider type: the panel follows
      // the one-handed anchor, NOT the circle's own bottom-left corner.
      //
      // `phonePosH` is set to `left` so the desktop row and the phone row
      // DISAGREE (dx -1 vs +1). Leaving both at their `right` default made the
      // two platform branches of `resolveSidePanelAlignmentFrom` coincide, so
      // this case could not tell which one answered — a seam mis-derived as
      // `isDesktop` still returned the expected corner and stayed green.
      expect(
        resolveControlPanelAnchor(
          _state(
            gate: true,
            mode: PhoneLandscapeUseMode.rightSide,
            h: PhoneSidePositionH.left,
            sliderType: PhoneLandscapeSliderType.circleLeft,
          ),
          isLandscape: true,
          width: 800,
        ),
        Alignment.bottomRight,
      );
    });

    test('the plain circle-left/right slider docks at its own corner', () {
      asPhone();

      // Gate OFF: the legacy circle corner is the ONLY placement authority.
      // The band below is half a case on its own, so this one is the case that
      // pins the corner is reached AT ALL — and reaching it is a phone-only
      // branch, which is why the desktop flag has to be cleared with the mobile
      // one.
      Alignment dockedAt(PhoneLandscapeSliderType type) =>
          resolveControlPanelAnchor(
            _state(
              gate: false,
              mode: PhoneLandscapeUseMode.normal,
              sliderType: type,
            ),
            isLandscape: true,
            width: 800,
          );

      expect(dockedAt(PhoneLandscapeSliderType.circleLeft),
          Alignment.bottomLeft);
      expect(dockedAt(PhoneLandscapeSliderType.circleRight),
          Alignment.bottomRight);
    });

    test('the circle corner only applies inside the mobile/tablet band', () {
      asPhone();

      final AppState state = _state(
        gate: false,
        mode: PhoneLandscapeUseMode.normal,
        sliderType: PhoneLandscapeSliderType.circleLeft,
      );

      expect(resolveControlPanelAnchor(state, isLandscape: true, width: 639),
          Alignment.bottomCenter);
      expect(resolveControlPanelAnchor(state, isLandscape: true, width: 1024),
          Alignment.bottomCenter);
    });

    // No platform seam here, on purpose: gate ON shorts the legacy branch on
    // `!useMetadataSettings` and mode=normal mounts no side panel, so this case
    // is platform-insensitive by construction. Pinning a phone here would only
    // read as coverage it does not have.
    test('normal mode and a normal slider stay bottom-centre', () {
      expect(
        resolveControlPanelAnchor(
          _state(
            gate: true,
            mode: PhoneLandscapeUseMode.normal,
            sliderType: PhoneLandscapeSliderType.normal,
          ),
          isLandscape: true,
          width: 800,
        ),
        Alignment.bottomCenter,
      );
    });

    // Platform-insensitive for the same reason as the case above: gate ON
    // short-circuits the legacy branch, so only `isCircle` varies here.
    test('gate ON ignores a stale circleLeft/circleRight slider type', () {
      // The AppState factory default is mode=normal + sliderType=circleRight,
      // so a fresh gate-ON install would ship a right-docked circle slider
      // while the settings dialog reads "normal" — and no UI choice can reach
      // that pair again. Under the gate the use mode is the only authority, so
      // leftover legacy state must never steer placement.
      for (final PhoneLandscapeSliderType type in PhoneLandscapeSliderType
          .values
          .where((t) => t != PhoneLandscapeSliderType.normal)) {
        expect(
          resolveControlPanelAnchor(
            _state(
              gate: true,
              mode: PhoneLandscapeUseMode.normal,
              sliderType: type,
            ),
            isLandscape: true,
            width: 800,
          ),
          Alignment.bottomCenter,
          reason: 'gate ON: a stale $type must not dock the panel off-centre',
        );
      }
    });
  });

  // The bar mounts CircleSliderLayout from `phoneLandscapeSliderType`; the
  // anchor resolver above ignores that field under the meta gate. The two
  // answers used to disagree: gate ON + mode=normal + a stored `circleRight`
  // made the bar mount a panel the overlay placed bottom-centre, hid with the
  // linear downward slide and passed `isSide: false` to the align editor, while
  // the settings dialog refused to dodge the very control it edits — a state
  // `AppState.phoneLandscapeSliderType`'s own doc claimed "cannot move anything"
  // under the gate. [useLegacyCircleSliderPanel] is the mount-side mirror of
  // the resolver's gate branch, so the pair can no longer answer differently.
  group('useLegacyCircleSliderPanel — agrees with the anchor resolver', () {
    // The REAL Android/iOS platform pair (desktop=false, mobile=true) with the
    // host seam left at its production value, via the file-level [asPhone] /
    // [asDesktop] — a desktop runner would otherwise answer every question here
    // with its own platform.
    bool mounted({
      required bool gate,
      required bool isPhone,
      required bool isLandscape,
      required PhoneLandscapeSliderType sliderType,
    }) =>
        useLegacyCircleSliderPanel(
          metadataEnabled: gate,
          isPhone: isPhone,
          isLandscape: isLandscape,
          sliderType: sliderType,
        );

    test('gate ON never mounts it, whatever the stored placement says', () {
      asPhone();
      for (final PhoneLandscapeSliderType type in PhoneLandscapeSliderType
          .values) {
        for (final PhoneLandscapeUseMode mode
            in kLivePhoneLandscapeUseModes) {
          expect(
            mounted(
              gate: true,
              isPhone: isMobilePlatform,
              isLandscape: true,
              sliderType: type,
            ),
            isFalse,
            reason: 'gate ON + $mode + $type: the use mode is the only placement '
                'authority, so the leftover enum must mount nothing',
          );
        }
      }
    });

    test('gate ON one-handed still mounts the panel, by the phone anchor', () {
      asPhone();
      // The fix must not take the feature with it: the one-handed panel is the
      // reason the phone carries this machinery at all.
      expect(
        isSidewayPanelMounted(
          oneHanded: true,
          isPhone: isMobilePlatform,
          isLandscape: true,
        ),
        isTrue,
      );
      expect(
        mounted(
          gate: true,
          isPhone: isMobilePlatform,
          isLandscape: true,
          sliderType: PhoneLandscapeSliderType.circleRight,
        ),
        isFalse,
        reason: 'the paired value under the gate is the SHADOW of the mode, '
            'never an independent mount reason',
      );
      expect(
        resolveControlPanelAnchor(
          _state(gate: true, mode: PhoneLandscapeUseMode.rightSide),
          isLandscape: true,
          width: 800,
        ),
        Alignment.bottomRight,
      );
    });

    test('gate OFF mounts it exactly when the anchor is its own corner', () {
      asPhone();
      const Map<PhoneLandscapeSliderType, Alignment> corners =
          <PhoneLandscapeSliderType, Alignment>{
        PhoneLandscapeSliderType.circleLeft: Alignment.bottomLeft,
        PhoneLandscapeSliderType.circleRight: Alignment.bottomRight,
      };
      for (final MapEntry<PhoneLandscapeSliderType, Alignment> e
          in corners.entries) {
        expect(
          mounted(
            gate: false,
            isPhone: isMobilePlatform,
            isLandscape: true,
            sliderType: e.key,
          ),
          isTrue,
          reason: 'gate OFF + ${e.key}: the legacy placement is the only '
              'authority, so the bar mounts the panel',
        );
        expect(
          resolveControlPanelAnchor(
            _state(
              gate: false,
              mode: PhoneLandscapeUseMode.normal,
              sliderType: e.key,
            ),
            isLandscape: true,
            width: 800,
          ),
          e.value,
          reason: 'a MOUNTED legacy circle panel must dock at its own corner — '
              'anything else is the bar/anchor disagreement this fixes',
        );
      }
    });

    // The resolver's legacy branch is width-BANDED (640..1024) and
    // [useLegacyCircleSliderPanel] deliberately is not, so outside that band the
    // two answers differ by construction. A parity case is therefore not
    // writable there — what CAN be pinned is the divergence itself, so the next
    // reader sees a known, dated residue of the frozen gate-OFF path rather than
    // either a silent bug or a fresh decision. Banding the helper would change
    // gate-OFF behaviour, which the legacy persistence path forbids.
    test('gate OFF: outside the band the panel mounts but the anchor is centre',
        () {
      asPhone();
      for (final PhoneLandscapeSliderType type in <PhoneLandscapeSliderType>[
        PhoneLandscapeSliderType.circleLeft,
        PhoneLandscapeSliderType.circleRight,
      ]) {
        for (final double width in <double>[500, 1100]) {
          expect(
            mounted(
              gate: false,
              isPhone: isMobilePlatform,
              isLandscape: true,
              sliderType: type,
            ),
            isTrue,
            reason: 'the mount is deliberately un-banded, so $type still mounts '
                'at $width',
          );
          expect(
            resolveControlPanelAnchor(
              _state(
                gate: false,
                mode: PhoneLandscapeUseMode.normal,
                sliderType: type,
              ),
              isLandscape: true,
              width: width,
            ),
            Alignment.bottomCenter,
            reason: 'but the anchor IS banded, so at $width the $type panel '
                'renders as a centred narrow column instead of its named '
                'corner. Known residue of the frozen gate-OFF path — banding '
                // the mount would change that path, so fix it there, not here',
          );
        }
      }
      // Inside the band they agree, which is the case the band exists for.
      expect(
        resolveControlPanelAnchor(
          _state(
            gate: false,
            mode: PhoneLandscapeUseMode.normal,
            sliderType: PhoneLandscapeSliderType.circleLeft,
          ),
          isLandscape: true,
          width: 800,
        ),
        Alignment.bottomLeft,
      );
    });

    test('normal placement, portrait and desktop mount nothing', () {
      asPhone();
      expect(
        mounted(
          gate: false,
          isPhone: true,
          isLandscape: true,
          sliderType: PhoneLandscapeSliderType.normal,
        ),
        isFalse,
        reason: 'the linear phone bar is not the circle panel',
      );
      expect(
        mounted(
          gate: false,
          isPhone: true,
          isLandscape: false,
          sliderType: PhoneLandscapeSliderType.circleRight,
        ),
        isFalse,
        reason: 'portrait renders a linear bottom row',
      );
      asDesktop();
      expect(
        mounted(
          gate: false,
          isPhone: false,
          isLandscape: true,
          sliderType: PhoneLandscapeSliderType.circleRight,
        ),
        isFalse,
        reason: 'the legacy circle placement never reached a desktop host',
      );
    });
  });

  // The anchors above answer "where WOULD the panel sit"; this one answers
  // "is there a panel at all". A phone stores the one-handed mode in portrait
  // too, yet renders a linear bottom bar there — reasoning about a footprint
  // that does not exist is what squeezed the settings card into a strip.
  group('isSidewayPanelMounted', () {
    setUp(() => debugSidewayPanelHostOverride = true);
    tearDown(() => debugSidewayPanelHostOverride = null);

    bool mounted({
      required bool oneHanded,
      required bool isPhone,
      required bool isLandscape,
    }) =>
        isSidewayPanelMounted(
          oneHanded: oneHanded,
          isPhone: isPhone,
          isLandscape: isLandscape,
        );

    test('a phone mounts the side panel in landscape only', () {
      expect(
          mounted(oneHanded: true, isPhone: true, isLandscape: true), isTrue);
      expect(
          mounted(oneHanded: true, isPhone: true, isLandscape: false), isFalse,
          reason: 'portrait renders a linear bottom bar, not the panel');
    });

    test('a desktop mounts it in either orientation', () {
      expect(
          mounted(oneHanded: true, isPhone: false, isLandscape: false), isTrue);
      expect(mounted(oneHanded: true, isPhone: false, isLandscape: true), isTrue);
    });

    test('normal mode never mounts a side panel', () {
      expect(
          mounted(oneHanded: false, isPhone: true, isLandscape: true), isFalse);
      expect(
          mounted(oneHanded: false, isPhone: false, isLandscape: false),
          isFalse);
    });

    // The host gate is what the four call sites used to re-derive by hand, and
    // they derived it two different ways: `isWindows` in the anchor resolver /
    // overlay, `isDesktop` in the bar / menu. A host that opted out must
    // therefore report "not mounted" no matter which orientation it claims.
    test('a host that does not ship the side panel never mounts it', () {
      debugSidewayPanelHostOverride = false;
      for (final bool isLandscape in <bool>[false, true]) {
        for (final bool isPhone in <bool>[false, true]) {
          expect(
            mounted(
                oneHanded: true, isPhone: isPhone, isLandscape: isLandscape),
            isFalse,
            reason: 'isPhone=$isPhone isLandscape=$isLandscape: the host gate '
                'must win over the orientation half',
          );
        }
      }
    });
  });

  // "Is a ONE-HANDED side panel on screen in the layout the player actually
  // RENDERS", which is a strictly narrower question than [isSidewayPanelMounted]
  // once the legacy control bar is the child: `LegacyControlBar` never imports
  // `CircleSliderLayout` or `PhoneOneHandedScrubber`, so a one-handed mode under
  // it produces a FULL-WIDTH linear bar. Answering with the bare mount gate put
  // the overlay on the side anchor, slid that bar out sideways (leaving a strip
  // on screen), handed `isSide: true` to the 副音 align editor and made the
  // slider-type dialog dodge a panel that does not exist.
  group('isSidePanelLayoutMounted — the legacy bar is never a side panel', () {
    bool layoutMounted({
      required PhoneLandscapeUseMode mode,
      required bool legacyControlBar,
      required bool isPhone,
      required bool isLandscape,
    }) =>
        isSidePanelLayoutMounted(
          mode: mode,
          legacyControlBar: legacyControlBar,
          isPhone: isPhone,
          isLandscape: isLandscape,
        );

    test('the legacy control bar vetoes it under every mode and orientation',
        () {
      // The REAL Android pair. Under it the bare gate is genuinely true, so the
      // only thing that can turn this false is the veto itself.
      asPhone();
      for (final PhoneLandscapeUseMode mode in kLivePhoneLandscapeUseModes) {
        for (final bool isLandscape in <bool>[false, true]) {
          for (final bool legacy in <bool>[false, true]) {
            expect(
              layoutMounted(
                mode: mode,
                legacyControlBar: legacy,
                isPhone: isMobilePlatform,
                isLandscape: isLandscape,
              ),
              legacy ? false : mode.usesOneHandedControls && isLandscape,
              reason: 'mode=$mode legacy=$legacy landscape=$isLandscape: the '
                  'legacy bar renders a full-width linear layout, so a '
                  'one-handed mode must not place, hide or dodge a side panel '
                  'there',
            );
          }
        }
      }
    });

    test('it tracks the bare mount gate when the legacy bar is off', () {
      // Parity, so the authority cannot drift from [isSidewayPanelMounted]: the
      // veto must be the ONLY difference between the two.
      asPhone();
      for (final PhoneLandscapeUseMode mode in kLivePhoneLandscapeUseModes) {
        for (final bool isLandscape in <bool>[false, true]) {
          for (final bool isPhone in <bool>[false, true]) {
            expect(
              layoutMounted(
                mode: mode,
                legacyControlBar: false,
                isPhone: isPhone,
                isLandscape: isLandscape,
              ),
              isSidewayPanelMounted(
                oneHanded: mode.usesOneHandedControls,
                isPhone: isPhone,
                isLandscape: isLandscape,
              ),
              reason: 'mode=$mode isPhone=$isPhone landscape=$isLandscape',
            );
          }
        }
      }
    });

    test('a legacy-bar phone stays linear even where the anchor says side', () {
      // The divergence this authority exists to make harmless, pinned: the bar
      // is a full-width linear layout, so the placement must be linear TOO. The
      // anchor still reports the one-handed corner (it answers "where WOULD a
      // panel sit"), which is exactly why these two used to disagree.
      asPhone();
      expect(
        layoutMounted(
          mode: PhoneLandscapeUseMode.rightSide,
          legacyControlBar: true,
          isPhone: isMobilePlatform,
          isLandscape: true,
        ),
        isFalse,
      );
      expect(
        resolveControlPanelAnchor(
          _state(gate: true, mode: PhoneLandscapeUseMode.rightSide),
          isLandscape: true,
          width: 800,
        ),
        Alignment.bottomRight,
        reason: 'precondition: the anchor is still side, so only the layout '
            'gate can keep the hide and the dodge linear',
      );
    });
  });

  // The whole point of [asPhone]: every case above runs on a desktop host, where
  // `isDesktop` is unconditionally true, so a gate of the form `isDesktop && …`
  // passes on the runner no matter what the phone half does — the phone
  // regression this group guards shipped with a fully green suite. Pinning the
  // REAL Android combination (desktop=false, mobile=true) and leaving the host
  // seam at its production value is the only way the production expression
  // becomes observable to a test at all.
  group('phone host — the real Android/iOS platform pair', () {
    // Set inline rather than through [asPhone]: `addTearDown` belongs to a test
    // body, and this group's own `tearDown` already clears both seams.
    setUp(() {
      debugIsMobilePlatformOverride = true;
      debugIsDesktopOverride = false;
    });
    tearDown(_clearPlatformSeams);

    test('a one-handed phone in landscape mounts the side panel', () {
      expect(
        isSidewayPanelMounted(
          oneHanded: true,
          isPhone: isMobilePlatform,
          isLandscape: true,
        ),
        isTrue,
        reason: 'the phone is a supported host — the gate must not be the '
            'desktop umbrella alone, or the feature is off on the one platform '
            'it was designed for',
      );
    });

    test('portrait still renders a linear bar, not the panel', () {
      expect(
        isSidewayPanelMounted(
          oneHanded: true,
          isPhone: isMobilePlatform,
          isLandscape: false,
        ),
        isFalse,
        reason: 'the orientation half is independent of the host half',
      );
    });

    test('normal mode mounts nothing on a phone either', () {
      expect(
        isSidewayPanelMounted(
          oneHanded: false,
          isPhone: isMobilePlatform,
          isLandscape: true,
        ),
        isFalse,
      );
    });

    test('the panel anchor and the mount gate agree on a phone', () {
      // The parity the four hand-written copies broke, restated for the host
      // that actually ships the feature: a MOUNTED panel must dock by the
      // phone's own `phonePosH` row, or that row is saved and never used.
      expect(
        isSidewayPanelMounted(
          oneHanded: true,
          isPhone: isMobilePlatform,
          isLandscape: true,
        ),
        isTrue,
        reason: 'precondition: a one-handed phone in landscape mounts it',
      );
      const Map<PhoneSidePositionH, double> expectedDx =
          <PhoneSidePositionH, double>{
        PhoneSidePositionH.left: -1.0,
        PhoneSidePositionH.center: 0.0,
        PhoneSidePositionH.right: 1.0,
      };
      for (final MapEntry<PhoneSidePositionH, double> e
          in expectedDx.entries) {
        expect(
          resolveControlPanelAnchor(
            _state(gate: true, mode: PhoneLandscapeUseMode.rightSide,
                mobileH: e.key),
            isLandscape: true,
            width: 800,
          ),
          Alignment(e.value, 1.0),
          reason: '${e.key}: the mounted phone panel must dock by the phone '
              'anchor (a centre row is a deliberate bottom-centre dock, not a '
              'collapsed one)',
        );
      }
    });
  });

  // Pins the platform-support decision itself (every platform IRIS ships gets
  // the panel) instead of leaving it to a code comment: with NEITHER seam set,
  // a host is supported as long as it is a desktop OR a phone. Should a future
  // platform ever have to opt out, this test is the thing that must change.
  group('host support — the shipped-platform matrix', () {
    tearDown(() {
      debugIsDesktopOverride = null;
      debugIsMobilePlatformOverride = null;
    });

    test('a desktop host is supported', () {
      debugIsDesktopOverride = true;
      debugIsMobilePlatformOverride = false;
      expect(sidewayPanelHostSupported, isTrue);
    });

    test('a phone host is supported', () {
      debugIsDesktopOverride = false;
      debugIsMobilePlatformOverride = true;
      expect(sidewayPanelHostSupported, isTrue);
    });

    test('a host that is neither desktop nor phone is not supported', () {
      debugIsDesktopOverride = false;
      debugIsMobilePlatformOverride = false;
      expect(sidewayPanelHostSupported, isFalse);
    });
  });
}
