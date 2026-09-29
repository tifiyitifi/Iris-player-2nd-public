import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/control_group/model/enum/player_control_group.dart';
import 'package:iris/features/control_group/store/use_control_group_store.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/sideway_panel_layout.dart';
import 'package:iris/globals.dart' show sidePanelLayoutWidthNotifier;
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/controls/circle_style_control.dart';
import 'package:iris/widgets/controls/normalized_slider_control.dart';
import 'package:iris/widgets/controls/ring_dial_style_control.dart';

Future<void> showSliderTypeDialog(BuildContext context) async {
  final Offset initialOffset = useAppStore().state.sidePanelDialogOffset;
  final label = getLocalizations(context).sld_title;
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: label,
    barrierColor: Colors.black54,
    pageBuilder: (ctx, _, __) => _DraggableSliderDialog(initialOffset: initialOffset),
  );
}

class _DraggableSliderDialog extends HookWidget {
  const _DraggableSliderDialog({required this.initialOffset});
  final Offset initialOffset;

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    final AppStore store = useAppStore();
    // Subscribe to the fields that move / resize the side panel so the free
    // region (and the card) re-adjust live: switching the panel side inside
    // this very dialog must NOT leave the card covering it. One record instead
    // of ten selectors — the desktop 9-grid (posH/posV) belongs here exactly
    // as much as the phone-side one, and a per-field subscription is how it
    // used to go missing.
    store.select(
      context,
      (AppState s) => (
        oneHanded: s.phoneLandscapeUseMode.usesOneHandedControls,
        posH: s.phoneSidePositionH,
        posV: s.phoneSidePositionV,
        mobilePosH: s.mobileSidePositionH,
        sliderType: s.phoneLandscapeSliderType,
        orientation: s.runtimeOrientation,
        metadataGate: s.useMetadataSettings,
        // The legacy control bar is a full-width linear layout, so the free
        // region must stop dodging a side panel when it is on — and the card
        // has to re-adjust the moment the user flips it, hence the subscription.
        legacyControlBar: s.useLegacyControlBar,
        desktopPhoneMode: s.desktopCenterZonePhoneMode,
        widthPct: s.sidewayPanelWidthPct,
        heightPct: s.sidewayPanelHeightPct,
        widthPx: s.sidewayPanelWidthPx,
        heightPx: s.sidewayPanelHeightPx,
        // The dial knobs: the panel box is widened by the dial, so a card
        // dodging a rect sized by the drag width alone would sit on the extra
        // strip the floor added.
        ringDialHeightPct: s.ringDialHeightPct,
        circleSliderScale: s.circleSliderScale,
        scrubberKind: s.phoneOneHandedScrubberKind,
      ),
    );
    // The 副音 quick strip is part of the panel's footprint, so its switch
    // moves the free region too.
    final bool quickBarEnabled = useBackgroundPlaybackStore()
        .select(context, (s) => s.quickBarEnabled);
    final PlayerControlGroup group =
        useControlGroupStore().select(context, (s) => s.group);
    // The bar's REAL layout zone, published while a side bar is mounted. The 副音
    // strip's cross-axis budget must come from it and NOT the window width: a
    // docked playlist shrinks the bar's zone, so budgeting off the window
    // reserves a strip the layout dropped. Null (no bar mounted) falls back to
    // the window, which is the zone in that case anyway.
    useListenable(sidePanelLayoutWidthNotifier);
    final double layoutWidth =
        sidePanelLayoutWidthNotifier.value ?? screen.width;

    final AppState s = store.state;
    final bool isPhone = isMobilePlatform;
    final bool isLandscape = isLandscapeOrientation(
      runtimeOrientation: s.runtimeOrientation,
      realOrientation: MediaQuery.orientationOf(context),
    );

    // Confine the card to the strip beside the side panel so the control slider
    // it edits stays fully visible — wherever the panel really is. Two phantoms
    // are dodged here, and both cost the card a strip it does not need: a phone
    // in portrait renders a linear bar, and so does the legacy control bar in
    // ANY orientation (`resolveSidePanelAlignment` would report a side corner
    // for both). `isSidePanelLayoutMounted` is the authority that knows which
    // layouts actually have a side panel.
    final Rect region = regionAvoidingPanel(
      screen: screen,
      safe: safe,
      panel: isSidePanelLayoutMounted(
        mode: s.phoneLandscapeUseMode,
        legacyControlBar: s.useLegacyControlBar,
        isPhone: isPhone,
        isLandscape: isLandscape,
      )
          ? _controlPanelFootprint(
              state: s,
              screen: screen,
              isLandscape: isLandscape,
              isPhone: isPhone,
              quickBarEnabled: quickBarEnabled,
              group: group,
              layoutWidth: layoutWidth,
            )
          : null,
    );
    final Size card = Size(
      math.min(380.0, region.width),
      math.min(560.0, region.height),
    );
    final ValueNotifier<Offset> frac = useState<Offset>(initialOffset);
    Offset fracToTopLeft(Offset f) => Offset(
          region.left +
              math.max(0, region.width - card.width) * f.dx.clamp(0.0, 1.0),
          region.top +
              math.max(0, region.height - card.height) * f.dy.clamp(0.0, 1.0),
        );
    final Offset initialTopLeft = fracToTopLeft(frac.value);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(color: Colors.transparent),
          ),
        ),
        Positioned(
          left: initialTopLeft.dx,
          top: initialTopLeft.dy,
          child: _DraggableSliderCard(
            frac: frac,
            region: region,
            cardSize: card,
            initialTopLeft: initialTopLeft,
            onDragEnd: (Offset newFrac) {
              // ignore: discarded_futures
              useAppStore().updateSidePanelDialogOffset(newFrac);
            },
          ),
        ),
      ],
    );
  }
}

/// On-screen footprint of the control panel: the panel box (anchored exactly
/// where `ControlsOverlay` puts it) plus the 副音 quick strip attached to its
/// centre-facing side.
Rect _controlPanelFootprint({
  required AppState state,
  required Size screen,
  required bool isLandscape,
  required bool isPhone,
  required bool quickBarEnabled,
  required PlayerControlGroup group,
  required double layoutWidth,
}) {
  final ({double panelW, double panelH}) panel = panelSizeForWindow(
    windowW: screen.width,
    windowH: screen.height,
    isPhone: isPhone,
    widthPct: state.sidewayPanelWidthPct,
    heightPct: state.sidewayPanelHeightPct,
    widthPx: state.sidewayPanelWidthPx,
    heightPx: state.sidewayPanelHeightPx,
  );
  // The dial the layout sizes against — computed ONCE and handed to both the
  // rect and the column budget, so the two cannot disagree about how wide the
  // panel box really is.
  final double dialDiameter = dialDiameterForHide(
    span: spanForTotalHeight(panel.panelH, sidewayBarHeight.value, 8),
    panelW: panel.panelW,
    scrubberKind: state.phoneOneHandedScrubberKind,
    ringDialHeightPct: state.ringDialHeightPct,
    classicScale: state.circleSliderScale,
  );
  final double boxW = renderedPanelWidthFor(
    windowW: screen.width,
    isPhone: isPhone,
    widthPct: state.sidewayPanelWidthPct,
    widthPx: state.sidewayPanelWidthPx,
    dialDiameter: dialDiameter,
  );
  final double quickAvail =
      sidewayQuickAvailWidth(layoutWidth: layoutWidth, panelW: boxW);
  final bool attached = showsSidewayQuickColumn(
    isPhone: isPhone,
    gateEnabled: BackgroundPlaybackGate.enabled,
    quickBarEnabled: quickBarEnabled,
    showingBackgroundGroup:
        (isPhone || state.desktopCenterZonePhoneMode) &&
            group == PlayerControlGroup.background,
    quickAvail: quickAvail,
  );
  return sidePanelRectForWindow(
    windowSize: screen,
    // The panel box is placed by the overlay's Align, so ask the very same
    // authority the overlay does — never the panel's *wish*.
    anchor: resolveControlPanelAnchor(
      state,
      isLandscape: isLandscape,
      width: screen.width,
    ),
    isPhone: isPhone,
    widthPct: state.sidewayPanelWidthPct,
    heightPct: state.sidewayPanelHeightPct,
    widthPx: state.sidewayPanelWidthPx,
    heightPx: state.sidewayPanelHeightPx,
    dialDiameter: dialDiameter,
    quickColumnWidth: attached
        ? sidewayQuickColumnWidth(quickAvail: quickAvail, panelH: panel.panelH)
        : 0,
  );
}

class _DraggableSliderCard extends HookWidget {
  const _DraggableSliderCard({
    required this.frac,
    required this.region,
    required this.cardSize,
    required this.initialTopLeft,
    required this.onDragEnd,
  });
  final ValueNotifier<Offset> frac;

  /// Allowed screen-space region for the card (never overlaps the side panel
  /// on phone); the card is clamped inside it on every pan frame.
  final Rect region;
  final Size cardSize;
  final Offset initialTopLeft;
  final ValueChanged<Offset> onDragEnd;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final ValueNotifier<Offset> topLeft = useState<Offset>(initialTopLeft);
    final double maxLeft = math.max(region.left, region.right - cardSize.width);
    final double maxTop = math.max(region.top, region.bottom - cardSize.height);
    Offset clampToRegion(Offset p) => Offset(
          p.dx.clamp(region.left, maxLeft).toDouble(),
          p.dy.clamp(region.top, maxTop).toDouble(),
        );
    Offset fracOf(Offset p) {
      final double dx = math.max(1.0, maxLeft - region.left);
      final double dy = math.max(1.0, maxTop - region.top);
      return Offset(
        ((p.dx - region.left) / dx).clamp(0.0, 1.0),
        ((p.dy - region.top) / dy).clamp(0.0, 1.0),
      );
    }

    // The PARENT positions this card (`Positioned(left: initialTopLeft)`) and
    // re-derives that from the stored fraction on every rebuild, so its copy
    // always tracks the free region while this one is a `useState` seed nothing
    // else touches. Clamping the stale value left the two disagreeing —
    // invisible until the next header drag, which snapped the card back to the
    // base it had been holding (76px on an 800px window). Adopt where the
    // parent actually put us instead: that value is already inside the region,
    // since `fracToTopLeft` scales by `max(0, region.width - card.width)`.
    //
    // The fraction is deliberately NOT written back here: it is the source the
    // parent derives the position FROM, so it can never be the stale one, and
    // this effect runs during the child's build — marking the parent dirty
    // there is illegal.
    useEffect(() {
      topLeft.value = initialTopLeft;
      return null;
    }, [region]);

    // Drag is confined to the HEADER: a card-wide pan recognizer competed
    // with the sliders / scroll view inside for the gesture arena.
    void onHeaderPanUpdate(DragUpdateDetails d) {
      final Offset next = clampToRegion(topLeft.value + d.delta);
      topLeft.value = next;
      frac.value = fracOf(next);
    }

    return Material(
      key: const Key('side-slider-panel-card'),
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      elevation: 8,
      child: SizedBox(
        width: cardSize.width,
        height: cardSize.height,
        child: Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: onHeaderPanUpdate,
              onPanEnd: (_) => onDragEnd(frac.value),
              child: Container(
                height: 40,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    const Icon(Icons.drag_indicator_rounded, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(t.sld_title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        onDragEnd(frac.value);
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: const SliderTypeDialogBody(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SliderTypeDialogBody extends HookWidget {
  const SliderTypeDialogBody({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final AppStore store = useAppStore();
    // Field-scoped subscriptions: a whole-state identity selector rebuilt this
    // dialog on EVERY app mutation (including the live drag it drives), which
    // was the phone-jank half of the per-frame problem.
    final bool sideway = store.select(
        context, (s) => s.phoneLandscapeUseMode.usesOneHandedControls);
    final bool isPhone = isMobilePlatform;
    final PhoneSidePositionH mobileH =
        store.select(context, (s) => s.mobileSidePositionH);
    final PhoneSidePositionH posH =
        store.select(context, (s) => s.phoneSidePositionH);
    final PhoneSidePositionV posV =
        store.select(context, (s) => s.phoneSidePositionV);
    final PhoneSideScrubberKind scrubberKind =
        store.select(context, (s) => s.phoneOneHandedScrubberKind);
    // Each platform persists its OWN corner-hide row, so the segment shows and
    // writes the field this device actually obeys — reading the desktop field
    // on a phone would display a value the overlay ignores.
    final SidePanelCornerHideMode cornerMode = store.select(
        context, (s) => resolveSidePanelCornerHideMode(s));
    final double widthPct =
        store.select(context, (s) => s.sidewayPanelWidthPct);
    final double heightPct =
        store.select(context, (s) => s.sidewayPanelHeightPct);
    final double widthPx = store.select(context, (s) => s.sidewayPanelWidthPx);
    final double heightPx =
        store.select(context, (s) => s.sidewayPanelHeightPx);
    // Bottom button-block position (side-relative 0..1, 0 = screen-centre edge).
    // Mode-agnostic: one knob drives the bar for both dial and classic circle.
    final double barPos = store.select(context, (s) => s.sidewayBarPos);

    // The store owns every mode/placement pairing (the legacy circle slider
    // type is derived from the mode, and the anchor writes carry the matching
    // handedness), so these only translate a widget choice into one call and
    // can never leave the two states disagreeing.
    Future<void> setMode(bool toSideway) async {
      final PhoneSidePositionH h = isPhone
          ? store.state.mobileSidePositionH
          : store.state.phoneSidePositionH;
      // ignore: discarded_futures
      store.updatePhoneLandscapeUseMode(toSideway
          ? useModeForAnchorH(h, store.state.phoneLandscapeUseMode)
          : PhoneLandscapeUseMode.normal);
    }

    Future<void> setHPhone(PhoneSidePositionH? h) async {
      if (h == null) return;
      // ignore: discarded_futures
      store.updateMobileSidePositionH(h);
    }

    Future<void> setHDesktop(PhoneSidePositionH? h) async {
      if (h == null) return;
      // ignore: discarded_futures
      store.updatePhoneSidePositionH(h);
    }

    Future<void> setV(PhoneSidePositionV? v) async {
      if (v == null) return;
      // ignore: discarded_futures
      store.updatePhoneSidePositionV(v);
    }

    Future<void> setKind(PhoneSideScrubberKind kind) async {
      await store.updatePhoneOneHandedScrubberKind(kind);
    }

    Future<void> setCornerMode(SidePanelCornerHideMode mode) async {
      if (isPhone) {
        await store.updateMobileSidePanelCornerHideMode(mode);
        return;
      }
      // ignore: discarded_futures
      store.updateSidePanelCornerHideMode(mode);
    }

    // The draggable card supplies the surface, header and close button, so the
    // body renders bare here (no nested AlertDialog → one title, one close).
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        DropdownButtonFormField<bool>(
          key: const ValueKey<String>('slider-mode-dropdown'),
          initialValue: sideway,
          decoration: InputDecoration(labelText: t.sld_mode_label),
          // The card is 380 wide and the option labels are sentences, so the
          // default shrink-to-fit DropdownButton overflows them (a long
          // translation does it too). `isExpanded` bounds the button to the
          // field and ellipsizes instead.
          isExpanded: true,
          items: <DropdownMenuItem<bool>>[
            DropdownMenuItem<bool>(
                value: false, child: Text(t.sld_mode_normal)),
            DropdownMenuItem<bool>(
                value: true, child: Text(t.sld_mode_sideway)),
          ],
          onChanged: (bool? v) => v == null ? null : setMode(v),
        ),
        IgnorePointer(
          ignoring: !sideway,
          child: Opacity(
            opacity: sideway ? 1.0 : 0.4,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SizedBox(height: 12),
                if (isPhone)
                  SegmentedButton<PhoneSidePositionH>(
                    key: const ValueKey<String>('slider-phone-posH-segmented'),
                    segments: <ButtonSegment<PhoneSidePositionH>>[
                      ButtonSegment<PhoneSidePositionH>(
                          value: PhoneSidePositionH.left,
                          label: Text(t.sld_side_left)),
                      ButtonSegment<PhoneSidePositionH>(
                          value: PhoneSidePositionH.right,
                          label: Text(t.sld_side_right)),
                    ],
                    selected: <PhoneSidePositionH>{
                      mobileH == PhoneSidePositionH.center
                          ? PhoneSidePositionH.right
                          : mobileH
                    },
                    onSelectionChanged: (Set<PhoneSidePositionH> sel) =>
                        setHPhone(sel.first),
                    showSelectedIcon: false,
                    style:
                        const ButtonStyle(visualDensity: VisualDensity.compact),
                  )
                else
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: DropdownButtonFormField<PhoneSidePositionH>(
                          key: const ValueKey<String>('slider-posH-dropdown'),
                          initialValue: posH,
                          decoration: InputDecoration(labelText: t.sld_pos_h),
                          // See the mode picker: bound to the field so a long
                          // translation ellipsizes rather than overflows.
                          isExpanded: true,
                          items: <DropdownMenuItem<PhoneSidePositionH>>[
                            DropdownMenuItem<PhoneSidePositionH>(
                                value: PhoneSidePositionH.left,
                                child: Text(t.sld_side_left)),
                            DropdownMenuItem<PhoneSidePositionH>(
                                value: PhoneSidePositionH.center,
                                child: Text(t.sld_side_center)),
                            DropdownMenuItem<PhoneSidePositionH>(
                                value: PhoneSidePositionH.right,
                                child: Text(t.sld_side_right)),
                          ],
                          onChanged: setHDesktop,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<PhoneSidePositionV>(
                          key: const ValueKey<String>('slider-posV-dropdown'),
                          initialValue: posV,
                          decoration: InputDecoration(labelText: t.sld_pos_v),
                          // See the mode picker: bound to the field so a long
                          // translation ellipsizes rather than overflows.
                          isExpanded: true,
                          items: <DropdownMenuItem<PhoneSidePositionV>>[
                            DropdownMenuItem<PhoneSidePositionV>(
                                value: PhoneSidePositionV.top,
                                child: Text(t.sld_pos_top)),
                            DropdownMenuItem<PhoneSidePositionV>(
                                value: PhoneSidePositionV.middle,
                                child: Text(t.sld_pos_middle)),
                            DropdownMenuItem<PhoneSidePositionV>(
                                value: PhoneSidePositionV.bottom,
                                child: Text(t.sld_pos_bottom)),
                          ],
                          onChanged: setV,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                SegmentedButton<PhoneSideScrubberKind>(
                  key: const ValueKey<String>('slider-design-segmented'),
                  segments: <ButtonSegment<PhoneSideScrubberKind>>[
                    ButtonSegment<PhoneSideScrubberKind>(
                      value: PhoneSideScrubberKind.dial,
                      label: Text(t.sld_kind_dial),
                      icon: const Icon(Icons.radio_button_checked),
                    ),
                    ButtonSegment<PhoneSideScrubberKind>(
                      value: PhoneSideScrubberKind.classic,
                      label: Text(t.sld_kind_circle),
                      icon: const Icon(Icons.circle_outlined),
                    ),
                  ],
                  selected: <PhoneSideScrubberKind>{scrubberKind},
                  onSelectionChanged: (Set<PhoneSideScrubberKind> sel) =>
                      setKind(sel.first),
                  showSelectedIcon: false,
                  style:
                      const ButtonStyle(visualDensity: VisualDensity.compact),
                ),
                const SizedBox(height: 12),
                // A phone panel is always anchored to a bottom corner, so the
                // corner modes are live there too — hiding this row on a phone
                // left the setting in force with no way to change it.
                Text(t.sld_corner_desc, style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                SegmentedButton<SidePanelCornerHideMode>(
                  key: const ValueKey<String>('slider-corner-hide-mode'),
                  segments: <ButtonSegment<SidePanelCornerHideMode>>[
                    ButtonSegment<SidePanelCornerHideMode>(
                        value: SidePanelCornerHideMode.vertical,
                        label: Text(t.sld_corner_vertical)),
                    ButtonSegment<SidePanelCornerHideMode>(
                        value: SidePanelCornerHideMode.horizontal,
                        label: Text(t.sld_corner_horizontal)),
                    ButtonSegment<SidePanelCornerHideMode>(
                        value: SidePanelCornerHideMode.diagonal,
                        label: Text(t.sld_corner_diagonal)),
                  ],
                  selected: <SidePanelCornerHideMode>{cornerMode},
                  onSelectionChanged: (Set<SidePanelCornerHideMode> sel) =>
                      setCornerMode(sel.first),
                  showSelectedIcon: false,
                  style:
                      const ButtonStyle(visualDensity: VisualDensity.compact),
                ),
                const SizedBox(height: 8),
                if (isPhone)
                  _PanelSizeSlider(
                    label: t.sld_panel_width,
                    value: widthPct,
                    onChanged: (v) =>
                        store.updateSidewayPanelWidthPct(v, persist: false),
                    onChangeEnd: (v) => store.updateSidewayPanelWidthPct(v),
                    isWidth: true,
                  )
                else
                  _PanelSizeSliderPx(
                    label: t.sld_panel_width,
                    value: widthPx,
                    onChanged: (v) =>
                        store.updateSidewayPanelWidthPx(v, persist: false),
                    onChangeEnd: (v) => store.updateSidewayPanelWidthPx(v),
                    isWidth: true,
                  ),
                const SizedBox(height: 4),
                if (isPhone)
                  _PanelSizeSlider(
                    label: t.sld_panel_height,
                    value: heightPct,
                    onChanged: (v) =>
                        store.updateSidewayPanelHeightPct(v, persist: false),
                    onChangeEnd: (v) => store.updateSidewayPanelHeightPct(v),
                    isWidth: false,
                  )
                else
                  _PanelSizeSliderPx(
                    label: t.sld_panel_height,
                    value: heightPx,
                    onChanged: (v) =>
                        store.updateSidewayPanelHeightPx(v, persist: false),
                    onChangeEnd: (v) => store.updateSidewayPanelHeightPx(v),
                    isWidth: false,
                  ),
                const SizedBox(height: 4),
                // Bottom button block position: one knob for BOTH scrubber
                // designs (dial ring + classic circle), so it lives here in the
                // shared panel section rather than in either style control.
                NormalizedSliderControl(
                  // Keyed so tests address the knob by identity rather than
                  // by its (deliberately descriptive) label copy.
                  key: const ValueKey<String>('slider-bar-pos-control'),
                  showControl: _noop,
                  icon: Icons.align_horizontal_left_rounded,
                  label: t.sld_bar_position,
                  value: barPos * 100,
                  min: 0,
                  max: 100,
                  divisions: 100,
                  onChanged: (v) =>
                      store.updateSidewayBarPos(v / 100.0, persist: false),
                  onChangeEnd: (v) => store.updateSidewayBarPos(v / 100.0),
                  valueBuilder: (v) => Text(t.sld_value_pct(v.round())),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),
                if (scrubberKind == PhoneSideScrubberKind.dial) ...[
                  Text(t.sld_dial_tuning,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const _DialRingInline(),
                  const SizedBox(height: 8),
                  _CenterActionInline(),
                ] else ...[
                  Text(t.sld_circle_tuning,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const _CircleInline(),
                  const SizedBox(height: 8),
                  _CenterActionInline(),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Inline style controls require a host callback; inside this dialog the player
/// already owns control visibility, so it is a no-op.
void _noop() {}

class _DialRingInline extends HookWidget {
  const _DialRingInline();
  @override
  Widget build(BuildContext context) {
    return const RingDialStyleControl(showControl: _noop);
  }
}

class _CircleInline extends HookWidget {
  const _CircleInline();
  @override
  Widget build(BuildContext context) {
    return const CircleStyleControl(showControl: _noop);
  }
}

/// Test seam: counts [_CenterActionInline] builds so a test can prove its
/// subscriptions stayed field-scoped. A whole-state `select(context, (s) => s)`
/// re-ran these four dropdown rows on EVERY AppState mutation. Lives at file
/// scope because the widget it watches is private.
@visibleForTesting
void Function()? debugOnCenterActionBuild;

class _CenterActionInline extends HookWidget {
  const _CenterActionInline();
  @override
  Widget build(BuildContext context) {
    debugOnCenterActionBuild?.call();
    final t = getLocalizations(context);
    final AppStore store = useAppStore();
    // Field-scoped, like [SliderTypeDialogBody]: a whole-state identity
    // selector rebuilt this section on every app mutation, including the live
    // panel drag this very dialog drives.
    final bool desktopCenterZonePhoneMode =
        store.select(context, (s) => s.desktopCenterZonePhoneMode);
    final CircleSliderCenterAction centerZoneInwardAction =
        store.select(context, (s) => s.centerZoneInwardAction);
    final CircleSliderCenterAction centerZoneOutwardAction =
        store.select(context, (s) => s.centerZoneOutwardAction);
    final CircleSliderCenterAction centerZoneTopAction =
        store.select(context, (s) => s.centerZoneTopAction);
    final CircleSliderCenterAction centerZoneBottomAction =
        store.select(context, (s) => s.centerZoneBottomAction);
    // The group-switch action only exists where a bottom group switch does:
    // phones, or desktop after the phone-mode opt-in.
    final bool allowSwitchGroup =
        isMobilePlatform || desktopCenterZonePhoneMode;
    final List<CircleSliderCenterAction> options = CircleSliderCenterAction
        .values
        .where((CircleSliderCenterAction a) =>
            allowSwitchGroup ||
            a != CircleSliderCenterAction.switchControlGroup)
        .toList();

    Widget zoneRow(
      CenterZone zone,
      String label,
      CircleSliderCenterAction current,
    ) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
            Expanded(
              child: DropdownButton<CircleSliderCenterAction>(
                isExpanded: true,
                value: options.contains(current) ? current : options.first,
                items: <DropdownMenuItem<CircleSliderCenterAction>>[
                  for (final CircleSliderCenterAction a in options)
                    DropdownMenuItem<CircleSliderCenterAction>(
                      value: a,
                      child: Text(
                        _zoneActionLabel(a, t),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
                onChanged: (CircleSliderCenterAction? v) {
                  if (v == null) return;
                  // ignore: discarded_futures
                  useAppStore().updateCenterZoneAction(zone, v);
                },
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.sld_center_action, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 6),
        zoneRow(CenterZone.inward, t.center_zone_inward,
            centerZoneInwardAction),
        zoneRow(CenterZone.outward, t.center_zone_outward,
            centerZoneOutwardAction),
        zoneRow(CenterZone.top, t.center_zone_top, centerZoneTopAction),
        zoneRow(
            CenterZone.bottom, t.center_zone_bottom, centerZoneBottomAction),
      ],
    );
  }
}

String _zoneActionLabel(CircleSliderCenterAction a, AppLocalizations t) =>
    switch (a) {
      CircleSliderCenterAction.none => t.sld_action_none,
      CircleSliderCenterAction.toggleControls => t.sld_action_toggle,
      CircleSliderCenterAction.togglePlayPause => t.sld_action_play_pause,
      CircleSliderCenterAction.switchControlGroup =>
        t.sld_action_switch_group,
    };

class _PanelSizeSlider extends StatelessWidget {
  const _PanelSizeSlider({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    required this.isWidth,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final bool isWidth;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final Size screen = MediaQuery.sizeOf(context);
    // Explicit axis flag: a localized-label substring check used to pick the
    // screen dimension and silently broke in every non-Chinese locale.
    final double windowDim = isWidth ? screen.width : screen.height;
    final double minPx = isWidth ? kPanelMinPxW : kPanelMinPxH;
    // Bound the slider by the floor the panel actually renders at, otherwise
    // the low end is a dead zone (thumb moves, panel does not).
    final double minPct =
        phonePanelMinPct(windowExtent: windowDim, minPx: minPx);
    final double shownPct = value.clamp(minPct, 100).toDouble();
    final double estPx = pxForPercent(shownPct, windowDim)
        .clamp(minPx, math.max(minPx, windowDim - 16))
        .toDouble();
    // Degenerate window: the floor leaves no draggable range (min == max).
    final bool canAdjust = (100 - minPct) >= 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.sld_size_pct(label, shownPct.round(), estPx.round()),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
        Slider(
          value: shownPct,
          min: minPct,
          max: 100,
          divisions: canAdjust ? (100 - minPct).round().clamp(1, 100) : null,
          label: t.sld_value_pct(shownPct.round()),
          onChanged: canAdjust ? onChanged : null,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }
}

class _PanelSizeSliderPx extends StatelessWidget {
  const _PanelSizeSliderPx({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    required this.isWidth,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final bool isWidth;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final Size screen = MediaQuery.sizeOf(context);
    final double maxPx = (isWidth ? screen.width * 0.8 : screen.height * 0.8)
        .clamp(
          isWidth ? 260 : 320,
          2000,
        )
        .toDouble();
    final double minPx = isWidth ? 260 : 320;
    final double shownPx = value.clamp(minPx, maxPx).toDouble();
    final bool canAdjust = (maxPx - minPx) >= 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.sld_size_px(label, shownPx.round(), maxPx.round()),
            style: Theme.of(context).textTheme.bodySmall),
        Slider(
          value: shownPx,
          min: minPx,
          max: maxPx,
          divisions:
              canAdjust ? ((maxPx - minPx) / 20).round().clamp(1, 100) : null,
          label: t.sld_value_px(shownPx.round()),
          onChanged: canAdjust ? onChanged : null,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }
}
