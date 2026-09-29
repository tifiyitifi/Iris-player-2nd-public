import 'package:flutter/material.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/utils/layout_breakpoints.dart';
import 'package:iris/utils/platform.dart' show isDesktop, isMobilePlatform;

/// The live (non-deprecated) one-handed modes, in picker order.
///
/// [PhoneLandscapeUseMode] keeps the deprecated `rightHanded` / `leftHanded`
/// members ONLY so an old persisted blob can still be parsed; the loader
/// normalises them to `rightSide` / `leftSide` before anything reads the
/// state. They must never be rendered as a choice — a picker that lists all
/// `.values` shows two duplicated label pairs and lets the user persist a
/// deprecated value back.
const List<PhoneLandscapeUseMode> kLivePhoneLandscapeUseModes =
    <PhoneLandscapeUseMode>[
  PhoneLandscapeUseMode.normal,
  PhoneLandscapeUseMode.rightSide,
  PhoneLandscapeUseMode.leftSide,
];

/// The legacy circle placement that pairs with [mode].
///
/// One-handed mode and the legacy `circleLeft` / `circleRight` slider type are
/// the same decision stored twice, so they are written together (see
/// `updatePhoneLandscapeUseMode`); a stored pair that disagrees would let the
/// stale value steer [resolveControlPanelAnchor].
PhoneLandscapeSliderType sliderTypeForUseMode(PhoneLandscapeUseMode mode) =>
    switch (mode) {
      PhoneLandscapeUseMode.normal => PhoneLandscapeSliderType.normal,
      PhoneLandscapeUseMode.rightSide || PhoneLandscapeUseMode.rightHanded =>
        PhoneLandscapeSliderType.circleRight,
      PhoneLandscapeUseMode.leftSide || PhoneLandscapeUseMode.leftHanded =>
        PhoneLandscapeSliderType.circleLeft,
    };

extension PhoneLandscapeSliderTypeHelper on PhoneLandscapeSliderType {
  /// Whether this mode uses the circular slider
  bool get isCircle => this == PhoneLandscapeSliderType.circleLeft || this == PhoneLandscapeSliderType.circleRight;

  /// Whether the circular slider is placed on the left side
  bool get isLeft => this == PhoneLandscapeSliderType.circleLeft;

  /// Alignment for the control panel
  Alignment get alignmentBottom {
    switch (this) {
      case PhoneLandscapeSliderType.circleLeft:
        return Alignment.bottomLeft;
      case PhoneLandscapeSliderType.circleRight:
        return Alignment.bottomRight;
      case PhoneLandscapeSliderType.normal:
        return Alignment.bottomCenter;
    }
  }

  /// Alignment for the control panel
  Alignment get alignmentTop {
    switch (this) {
      case PhoneLandscapeSliderType.circleLeft:
        return Alignment.topLeft;
      case PhoneLandscapeSliderType.circleRight:
        return Alignment.topRight;
      case PhoneLandscapeSliderType.normal:
        return Alignment.topCenter;
    }
  }
}

extension PhoneLandscapeUseModeHelper on PhoneLandscapeUseMode {
  bool get usesOneHandedControls => this != PhoneLandscapeUseMode.normal;

  /// The live members only. [PhoneLandscapeUseMode.rightHanded] /
  /// [PhoneLandscapeUseMode.leftHanded] exist so an old persisted blob still
  /// parses; the loader folds them into `rightSide` / `leftSide` before
  /// anything reads the state, so every getter below may ignore them.
  bool get isLeftSide => this == PhoneLandscapeUseMode.leftSide;
  bool get isRightSide => this == PhoneLandscapeUseMode.rightSide;

  /// This mode with the deprecated members folded onto their replacements.
  ///
  /// The getters above deliberately ignore `rightHanded` / `leftHanded`, so a
  /// value that reached them un-folded reads as NO side and the hand is lost —
  /// [resolvePanelSideIsLeft] then judges a left-handed mode as the right hand.
  /// `_normalizeLoaded` is the only reader that folds a persisted value today,
  /// and a settings import writes a snapshot straight into the state WITHOUT it
  /// (`app_settings_coder` applies `AppState.fromJson` verbatim), so an old
  /// export can install a deprecated mode. Any function that PERSISTS a mode
  /// therefore has to fold it here, or the migration loop re-creates the value
  /// it was meant to erase.
  PhoneLandscapeUseMode get live => switch (this) {
        // ignore: deprecated_member_use_from_same_package
        PhoneLandscapeUseMode.rightHanded => PhoneLandscapeUseMode.rightSide,
        // ignore: deprecated_member_use_from_same_package
        PhoneLandscapeUseMode.leftHanded => PhoneLandscapeUseMode.leftSide,
        final PhoneLandscapeUseMode other => other,
      };

  Alignment get controlBarAlignment {
    switch (this) {
      case PhoneLandscapeUseMode.normal:
        return Alignment.bottomCenter;
      case PhoneLandscapeUseMode.rightSide:
      case PhoneLandscapeUseMode.rightHanded:
        return Alignment.bottomRight;
      case PhoneLandscapeUseMode.leftSide:
      case PhoneLandscapeUseMode.leftHanded:
        return Alignment.bottomLeft;
    }
  }
}

/// The 9-grid anchor's horizontal value, as a one-handed mode.
///
/// [PhoneSidePositionH.center] has no hand of its own, so it KEEPS [current]
/// instead of being rewritten to a side: a purely positional move
/// (left → centre) must not silently re-mirror the ring dial, the
/// inward/outward zones or the hide-direction fallback. A [current] of
/// [PhoneLandscapeUseMode.normal] has no hand to preserve, so it falls back to
/// the right hand (the historical default).
///
/// A kept hand is written BACK to the state, so it must be folded through
/// [PhoneLandscapeUseModeHelper.live] first: a deprecated `leftHanded` kept as
/// is would be persisted again and read back as no side at all, turning
/// [resolvePanelSideIsLeft] into a coin flip.
PhoneLandscapeUseMode useModeForAnchorH(
  PhoneSidePositionH pos,
  PhoneLandscapeUseMode current,
) =>
    switch (pos) {
      PhoneSidePositionH.left => PhoneLandscapeUseMode.leftSide,
      PhoneSidePositionH.right => PhoneLandscapeUseMode.rightSide,
      PhoneSidePositionH.center => current.usesOneHandedControls
          ? current.live
          : PhoneLandscapeUseMode.rightSide,
    };

/// Which HAND the panel is being operated with — the single authority for
/// handedness semantics (ring-dial mirroring, the inward/outward zones, the
/// pure-centre hide-direction fallback).
///
/// The panel's POSITION comes from the 9-grid anchor while its handedness came
/// from the 2-valued use mode, so the two could disagree: a centre anchor
/// parked the panel in the middle yet the scrubber still mirrored as one
/// specific hand, while the button rows aligned by the anchor
/// ([sidewayButtonAlignForAnchor]). Resolving the hand ONCE — from the anchor
/// when it has an opinion, from the mode only when it does not — makes those
/// consumers structurally unable to disagree.
bool resolvePanelSideIsLeft({
  required Alignment anchor,
  required PhoneLandscapeUseMode mode,
}) {
  if (anchor.x < 0) return true;
  if (anchor.x > 0) return false;
  return mode.isLeftSide;
}

/// [resolvePanelSideIsLeft] over the state's own resolved side-panel anchor.
///
/// Use this overload in widgets and `context.select` so the hand follows the
/// anchor; the named-argument form is for pure callers that already hold an
/// anchor.
bool panelIsLeftHanded(AppState state) => resolvePanelSideIsLeft(
      anchor: resolveSidePanelAlignment(state),
      mode: state.phoneLandscapeUseMode,
    );

/// Meta-settings presentation of the slider type. The one-handed right/left
/// modes auto-select the matching classic circle placement (the old
/// circleRight/circleLeft options are folded away).
enum MetaSliderTypeOption { normal, rightSide, leftSide }

MetaSliderTypeOption metaSliderTypeOption(PhoneLandscapeUseMode mode) {
  switch (mode) {
    case PhoneLandscapeUseMode.rightSide:
    case PhoneLandscapeUseMode.rightHanded:
      return MetaSliderTypeOption.rightSide;
    case PhoneLandscapeUseMode.leftSide:
    case PhoneLandscapeUseMode.leftHanded:
      return MetaSliderTypeOption.leftSide;
    case PhoneLandscapeUseMode.normal:
      return MetaSliderTypeOption.normal;
  }
}

String metaSliderTypeLabel(MetaSliderTypeOption option, AppLocalizations t) =>
    switch (option) {
      MetaSliderTypeOption.normal => t.phone_slider_normal,
      MetaSliderTypeOption.rightSide => t.phone_slider_right,
      MetaSliderTypeOption.leftSide => t.phone_slider_left,
    };

/// Whether the sideway total panel requires a tap/click to appear (hover
/// still shows title/cursor via normal `showControl`). Requires the gate +
/// `slider.requireClick` (default OFF).
///
/// Desktop has its own hover policy: the `app.desktopHoverShowControlBar`
/// snapshot bit (also gate-gated) keeps a mouse move from revealing the bar —
/// it appears on click instead. Both rules funnel through this one function so
/// every hover/tap/panel-visibility path stays consistent.
bool shouldRequireClickToShowPanel(AppState state) =>
    shouldRequireClickToShowPanelFrom(
      useMetadataSettings: state.useMetadataSettings,
      desktopHoverShowControlBar: state.desktopHoverShowControlBar,
      sidewayPanelRequireClick: state.sidewayPanelRequireClick,
      oneHandedControls: state.phoneLandscapeUseMode.usesOneHandedControls,
    );

/// [shouldRequireClickToShowPanel] over already-selected fields.
///
/// Lets a widget subscribe to a narrow AppState slice (record selector) instead
/// of the whole object, so it does not rebuild on unrelated app-state changes.
/// The AppState overload delegates here — this stays the single authority.
bool shouldRequireClickToShowPanelFrom({
  required bool useMetadataSettings,
  required bool desktopHoverShowControlBar,
  required bool sidewayPanelRequireClick,
  required bool oneHandedControls,
}) {
  if (!useMetadataSettings) return false;
  if (isDesktop) return !desktopHoverShowControlBar;
  if (!sidewayPanelRequireClick) return false;
  if (!oneHandedControls) return false;
  return true;
}

/// Whether a PASSIVE desktop hover reveals the title bar. The control-bar
/// toggle implies the title (a full bar always carries its title); with both
/// switches OFF a hover reveals only the cursor. Non-desktop and gate-OFF keep
/// today's hover-reveals-everything behavior so legacy installs are untouched.
/// Explicit shows never consult this — only `isHoverReveal` states do.
bool desktopHoverRevealsTitle(AppState state) =>
    desktopHoverRevealsTitleFrom(
      useMetadataSettings: state.useMetadataSettings,
      desktopHoverShowTitle: state.desktopHoverShowTitle,
      desktopHoverShowControlBar: state.desktopHoverShowControlBar,
    );

/// [desktopHoverRevealsTitle] over already-selected fields. The AppState
/// overload delegates here — this stays the single authority.
bool desktopHoverRevealsTitleFrom({
  required bool useMetadataSettings,
  required bool desktopHoverShowTitle,
  required bool desktopHoverShowControlBar,
}) {
  if (!useMetadataSettings || !isDesktop) return true;
  return desktopHoverShowTitle || desktopHoverShowControlBar;
}

/// Screen anchor of the sideway one-handed panel.
///
/// Meta gate ON:
/// - phone (`isMobilePlatform`) → `slider.phonePosH` left/right only, posV fixed
///   bottom; desktop `slider.posH/posV` rows are ignored so the two never
///   overwrite each other.
/// - desktop → 9-grid `slider.posH/posV` rows.
/// Gate OFF → legacy mode-derived corner (bottom-left/right), so a stale
/// stored anchor can never leak into legacy runs. Non-side modes always
/// anchor bottom-center.
Alignment resolveSidePanelAlignment(AppState state) =>
    resolveSidePanelAlignmentFrom(
      mode: state.phoneLandscapeUseMode,
      useMetadataSettings: state.useMetadataSettings,
      mobileSidePositionH: state.mobileSidePositionH,
      phoneSidePositionH: state.phoneSidePositionH,
      phoneSidePositionV: state.phoneSidePositionV,
    );

/// [resolveSidePanelAlignment] over already-selected fields. The AppState
/// overload delegates here — this stays the single authority.
Alignment resolveSidePanelAlignmentFrom({
  required PhoneLandscapeUseMode mode,
  required bool useMetadataSettings,
  required PhoneSidePositionH mobileSidePositionH,
  required PhoneSidePositionH phoneSidePositionH,
  required PhoneSidePositionV phoneSidePositionV,
}) {
  if (!mode.usesOneHandedControls) {
    return Alignment.bottomCenter;
  }
  if (!useMetadataSettings) {
    return mode.controlBarAlignment;
  }
  if (isMobilePlatformForSidePanel()) {
    final double dx = switch (mobileSidePositionH) {
      PhoneSidePositionH.left => -1.0,
      PhoneSidePositionH.center => 0.0,
      PhoneSidePositionH.right => 1.0,
    };
    return Alignment(dx, 1.0);
  }
  final double dx = switch (phoneSidePositionH) {
    PhoneSidePositionH.left => -1.0,
    PhoneSidePositionH.center => 0.0,
    PhoneSidePositionH.right => 1.0,
  };
  final double dy = switch (phoneSidePositionV) {
    PhoneSidePositionV.top => -1.0,
    PhoneSidePositionV.middle => 0.0,
    PhoneSidePositionV.bottom => 1.0,
  };
  return Alignment(dx, dy);
}

/// Corner-hide direction in force on THIS platform.
///
/// The two platforms persist their own row (`slider.cornerHideMode` desktop,
/// `slider.phoneCornerHideMode` phone) and each one only ever offers an entry
/// for its own field, so this is the single place that says which one the
/// overlay obeys — a consumer reading the field directly would be right on
/// desktop and silently wrong on a phone.
SidePanelCornerHideMode resolveSidePanelCornerHideMode(AppState state) =>
    resolveSidePanelCornerHideModeFrom(
      isPhone: isMobilePlatformForSidePanel(),
      desktop: state.sidePanelCornerHideMode,
      phone: state.mobileSidePanelCornerHideMode,
    );

/// [resolveSidePanelCornerHideMode] over already-selected fields. The AppState
/// overload delegates here — this stays the single authority.
SidePanelCornerHideMode resolveSidePanelCornerHideModeFrom({
  required bool isPhone,
  required SidePanelCornerHideMode desktop,
  required SidePanelCornerHideMode phone,
}) =>
    isPhone ? phone : desktop;

/// Screen anchor of the control panel box as it is ACTUALLY placed.
///
/// [resolveSidePanelAlignment] answers "where does the one-handed panel want to
/// sit"; this answers "where does the panel end up on screen", which is what the
/// overlay aligns the panel box with AND what that box uses to decide which way
/// its bottom button rows face. Single authority, so the panel and its rows can
/// never disagree about which side is which.
///
/// Precedence mirrors the historical inline chain: the one-handed panel
/// (Windows desk or phone landscape) docks by the 9-grid anchor; the plain
/// circle-left/right slider docks by its own corner inside the mobile/tablet
/// width band; anything else stays bottom-centre.
Alignment resolveControlPanelAnchor(
  AppState state, {
  required bool isLandscape,
  required double width,
}) =>
    resolveControlPanelAnchorFrom(
      mode: state.phoneLandscapeUseMode,
      useMetadataSettings: state.useMetadataSettings,
      mobileSidePositionH: state.mobileSidePositionH,
      phoneSidePositionH: state.phoneSidePositionH,
      phoneSidePositionV: state.phoneSidePositionV,
      sliderType: state.phoneLandscapeSliderType,
      isLandscape: isLandscape,
      width: width,
    );

/// [resolveControlPanelAnchor] over already-selected fields. The AppState
/// overload delegates here — this stays the single authority.
Alignment resolveControlPanelAnchorFrom({
  required PhoneLandscapeUseMode mode,
  required bool useMetadataSettings,
  required PhoneSidePositionH mobileSidePositionH,
  required PhoneSidePositionH phoneSidePositionH,
  required PhoneSidePositionV phoneSidePositionV,
  required PhoneLandscapeSliderType sliderType,
  required bool isLandscape,
  required double width,
}) {
  if (isSidewayPanelMounted(
    oneHanded: mode.usesOneHandedControls,
    isPhone: isMobilePlatform,
    isLandscape: isLandscape,
  )) {
    return resolveSidePanelAlignmentFrom(
      mode: mode,
      useMetadataSettings: useMetadataSettings,
      mobileSidePositionH: mobileSidePositionH,
      phoneSidePositionH: phoneSidePositionH,
      phoneSidePositionV: phoneSidePositionV,
    );
  }
  // The plain circle corner is LEGACY placement: gate-ON runs derive the
  // panel from the use mode, so a stored circleLeft/circleRight left over from
  // the frozen blob must not dock the panel off-centre. The two fields are
  // written together (sliderTypeForUseMode), so under the gate the value is
  // already consistent and skipping it costs nothing.
  if (!useMetadataSettings &&
      isMobilePlatform &&
      sliderType.isCircle &&
      width >= kMobileBreakpoint &&
      width < kTabletBreakpoint) {
    return sliderType.alignmentBottom;
  }
  return Alignment.bottomCenter;
}

/// Test-only seam for [sidewayPanelHostSupported]: the host gate reads the
/// platform, so a test could otherwise only ever exercise whichever host it
/// happens to run on. Production never writes it; a getter (not a final) so
/// tests can flip it per-case at runtime.
bool? debugSidewayPanelHostOverride;

/// Hosts that mount the one-handed side panel.
///
/// True on EVERY platform IRIS actually ships (see `.github/workflows/ci.yml`):
/// the desktop hosts via [isDesktop] and the phones via [isMobilePlatform] —
/// Android is where the one-handed panel was designed, so gating it on the
/// desktop umbrella alone silently switched the whole feature off on the one
/// platform that is supposed to have it. Both halves are listed HERE, once,
/// rather than re-derived at the four sites that mount, place and hide the
/// panel — that drift is what pinned the panel bottom-centre (and the hide
/// sliding downward) while the bar rendered a side panel.
///
/// A future platform that must NOT get the panel (a web build, say) is a
/// one-line flip in this getter, and [debugSidewayPanelHostOverride] lets a
/// test stand in for it without inventing a platform.
bool get sidewayPanelHostSupported =>
    debugSidewayPanelHostOverride ?? (isDesktop || isMobilePlatform);

/// Whether a one-handed side panel is on screen RIGHT NOW — the ONE gate every
/// side-panel consumer reads: `ControlBar` picks `CircleSliderLayout` with it,
/// the More menu and the overlay read it to agree with the bar, and
/// `resolveControlPanelAnchor` to place the panel box.
///
/// The anchors above only say where a panel *would* sit, which is meaningless
/// when there is none: a phone keeps the one-handed mode in portrait too, yet
/// renders a linear bottom row there. Anything reasoning about the panel's
/// on-screen footprint (the side-panel settings dialog, which must never cover
/// the slider it edits) has to ask here first, or it dodges a panel that does
/// not exist and squeezes itself into a strip for nothing.
///
/// [isPhone] is the platform seam's single value — never pass a host-derived
/// `isDesktop` in its place, which is simultaneously true in widget tests. The
/// host itself is decided by [sidewayPanelHostSupported] in here, so no caller
/// has to re-derive the platform half of the question.
bool isSidewayPanelMounted({
  required bool oneHanded,
  required bool isPhone,
  required bool isLandscape,
}) => oneHanded && sidewayPanelHostSupported && (!isPhone || isLandscape);

/// Whether a ONE-HANDED side panel is on screen in the layout the player
/// actually RENDERS — the authority the overlay's bar placement / hide
/// direction / corner radius / 副音 `isSide` and the slider-type dialog's dodge
/// region read.
///
/// [isSidewayPanelMounted] alone answers a wider question: "would a one-handed
/// mode mount a panel", which is not the same thing once the legacy control bar
/// is the child. `LegacyControlBar` never imports `CircleSliderLayout` or
/// `PhoneOneHandedScrubber` — its four layout branches are linear, or its own
/// bottom-centred narrow column for the legacy circle slider — so under it a
/// one-handed mode renders a FULL-WIDTH linear bar. Placing that by the side
/// anchor slid it out sideways (a strip of it stayed on screen), handed
/// `isSide: true` to the 副音 align editor, and made the settings dialog dodge a
/// panel that does not exist.
///
/// The mount sites keep the bare [isSidewayPanelMounted]: `ControlBar` is only
/// ever in the tree when the legacy bar is not, so there the veto is already
/// structural. It is the readers of the RESULT that need it.
bool isSidePanelLayoutMounted({
  required PhoneLandscapeUseMode mode,
  required bool legacyControlBar,
  required bool isPhone,
  required bool isLandscape,
}) =>
    !legacyControlBar &&
    isSidewayPanelMounted(
      oneHanded: mode.usesOneHandedControls,
      isPhone: isPhone,
      isLandscape: isLandscape,
    );

/// Whether the LEGACY plain circle panel is on screen RIGHT NOW — the
/// `CircleSliderLayout` the bar mounts for a stored `circleLeft`/`circleRight`
/// placement, as opposed to the one-handed panel above.
///
/// Mirrors the GATE branch of [resolveControlPanelAnchorFrom]: under the meta
/// gate the use mode is the placement authority and the legacy enum is only its
/// persisted shadow, so anything that MOUNTS a panel from that enum has to ignore
/// it there too. Reading it ungated is what let the bar mount a panel the overlay
/// then placed bottom-centre, hid with the linear downward slide and never told
/// the settings dialog to dodge the control it edits — a state
/// `AppState.phoneLandscapeSliderType`'s own doc claimed "cannot move anything"
/// under the gate.
///
/// It is a mirror of the gate, NOT of the whole branch: see the width note below.
///
/// [isPhone] follows the same seam contract as [isSidewayPanelMounted]: pass the
/// platform value, never a host-derived `isDesktop`.
///
/// Deliberately NOT width-banded, unlike the resolver's legacy branch, which
/// requires `kMobileBreakpoint <= width < kTabletBreakpoint`. The bar's own
/// width-based layout choice is unchanged and the gate-OFF path is FROZEN, so
/// the mount and the anchor therefore answer DIFFERENTLY outside that band:
/// at `width < 640` (or `>= 1024`, e.g. a tablet in landscape) the bar mounts
/// the panel while the anchor stays bottom-centre, which reads as a centred
/// narrow column instead of the left/right corner the setting names. That is a
/// pre-existing residue of the frozen path, not a new decision — it is pinned
/// as such by the width cases in `side_panel_position_test.dart` rather than
/// papered over, because a parity case here is not writable: the two answers
/// differ by construction in that band.
bool useLegacyCircleSliderPanel({
  required bool metadataEnabled,
  required bool isPhone,
  required bool isLandscape,
  required PhoneLandscapeSliderType sliderType,
}) =>
    !metadataEnabled && isPhone && isLandscape && sliderType.isCircle;

/// Whether the control panel is visible.
///
/// Single authority: [ControlsOverlay] gates the bar (and its input, semantics
/// and tickers) with this, and the floating bottom-group switch button gates
/// itself with it too, so the two can never disagree about whether the bar is
/// up — the switch rides the panel's visibility instead of floating alone over
/// a hidden control bar.
///
/// The panel is FORCED up while the 副音 align editor owns it, while a non-video
/// file plays (audio pins the bar) or during a scrub session; otherwise it
/// follows [isShowControl] and the reveal policy.
bool resolveControlPanelVisible({
  required AppState appState,
  required bool isShowControl,
  required bool isHoverReveal,
  required bool isPanelClickArmed,
  required bool editing,
  required bool isVideo,
  required bool dragActive,
}) =>
    resolveControlPanelVisibleFrom(
      requireClick: shouldRequireClickToShowPanel(appState),
      isShowControl: isShowControl,
      isHoverReveal: isHoverReveal,
      isPanelClickArmed: isPanelClickArmed,
      editing: editing,
      isVideo: isVideo,
      dragActive: dragActive,
    );

/// [resolveControlPanelVisible] over an already-resolved [requireClick].
///
/// Same contract; the AppState overload delegates here so a caller that only
/// needs the click-to-show bit can avoid subscribing to the whole AppState.
bool resolveControlPanelVisibleFrom({
  required bool requireClick,
  required bool isShowControl,
  required bool isHoverReveal,
  required bool isPanelClickArmed,
  required bool editing,
  required bool isVideo,
  required bool dragActive,
}) {
  if (editing || !isVideo || dragActive) return true;
  // Desktop explicit shows (incl. startup) always reveal the bar; a passive
  // hover obeys the `app.desktopHoverShow*` switches. Mobile keeps the original
  // click-latch rule (`requireClick` is the one-handed side-panel gate there).
  final bool panelRevealed = isDesktop
      ? (!isHoverReveal || !requireClick || isPanelClickArmed)
      : (!requireClick || isPanelClickArmed);
  return isShowControl && panelRevealed;
}

bool isMobilePlatformForSidePanel() {
  try {
    return isMobilePlatform;
  } catch (_) {
    return false;
  }
}
