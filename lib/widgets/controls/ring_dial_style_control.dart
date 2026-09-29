import 'dart:math' as m;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_ring_dial_palette.dart';
import 'package:iris/globals.dart' show sidePanelKeyNotifier;
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/controls/normalized_slider_control.dart';
import 'package:popover/popover.dart';

/// Fixed width of the ring-dial style card.
const double kStyleCardWidth = 300;

/// Pure anchor geometry for the style card: it emerges from the PANEL's
/// screen-centreline edge ([innerIsLeft]) so it can never cover the dial,
/// clamped to stay fully on screen.
Rect ringDialStyleCardRect({
  required Rect panel,
  required Size screen,
  required bool innerIsLeft,
  double cardWidth = kStyleCardWidth,
}) {
  final double h =
      m.min(340.0, m.max(96.0, (screen.height - 16) * 0.86));
  final double rawLeft =
      innerIsLeft ? panel.left - 8 - cardWidth : panel.right + 8;
  final double left =
      rawLeft.clamp(8.0, m.max(8.0, screen.width - cardWidth - 8));
  final double top =
      panel.top.clamp(8.0, m.max(8.0, screen.height - h - 8)).toDouble();
  return Rect.fromLTWH(left, top, cardWidth, h);
}

/// Aggregated quick-adjust popover for the ring dial's look: colour palette,
/// height share of the screen-top↔button-bar span, shared inner/outer side,
/// precision-axis visibility and the two corridor slot knobs.
///
/// Anchoring: the card opens beside the ONE-HANDED PANEL (via
/// [oneHandedPanelKey]) on its centre-facing edge; without that panel (other
/// scrubber modes) it falls back to the legacy gear-anchored popover.
Future<void> showRingDialStyleControlPopover(
  BuildContext context,
  void Function() showControl,
) async {
  final BuildContext? panelCtx = sidePanelKeyNotifier.value?.currentContext;
  final Object? ro = panelCtx?.findRenderObject();
  if (ro is RenderBox && ro.attached && ro.hasSize) {
    final Size screen = MediaQuery.sizeOf(context);
    final Rect panel = Rect.fromPoints(
      ro.localToGlobal(Offset.zero),
      ro.localToGlobal(ro.size.bottomRight(Offset.zero)),
    );
    // Card side follows the PANEL's resolved hand, not the raw mode: a centre
    // anchor must not make the card jump to the other edge of a panel that
    // stayed put.
    final bool isLeftSide = panelIsLeftHanded(useAppStore().state);
    final Rect card = ringDialStyleCardRect(
      panel: panel,
      screen: screen,
      // Right-side panels sit on the right: their centre-facing edge is
      // the LEFT edge (and vice versa).
      innerIsLeft: !isLeftSide,
    );
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Ring dial style',
      barrierColor: Colors.transparent,
      pageBuilder: (BuildContext ctx, _, __) => Stack(
        children: <Widget>[
          Positioned(
            left: card.left,
            top: card.top,
            width: card.width,
            height: card.height,
            child: Material(
              color: Theme.of(ctx).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
                child: RingDialStyleControl(showControl: showControl),
              ),
            ),
          ),
        ],
      ),
    );
    return;
  }

  // Fallback: no live panel to anchor against — legacy viewport-safe
  // popover from the caller's own position.
  final double screenH = MediaQuery.sizeOf(context).height;
  double room = screenH * 0.86;
  final Object? selfRo = context.findRenderObject();
  if (selfRo is RenderBox && selfRo.attached && selfRo.hasSize) {
    final Offset tl = selfRo.localToGlobal(Offset.zero);
    final double topRoom = tl.dy;
    final double bottomRoom = screenH - (tl.dy + selfRo.size.height);
    room = m.max(topRoom, bottomRoom);
  }
  final double h = m.min(340.0, m.max(96.0, room * 0.92));
  await showPopover(
    context: context,
    bodyBuilder: (context) => Container(
      padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
      child: RingDialStyleControl(showControl: showControl),
    ),
    direction: PopoverDirection.top,
    width: kStyleCardWidth,
    height: h,
    arrowHeight: 0,
    arrowWidth: 0,
    backgroundColor: Theme.of(context).colorScheme.surface,
    barrierColor: Colors.transparent,
  );
}

class RingDialStyleControl extends HookWidget {
  const RingDialStyleControl({
    super.key,
    required this.showControl,
    this.color,
    this.overlayColor,
  });

  final VoidCallback showControl;
  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;

  /// Locked display order — mono first (the default), rainbow last.
  static const List<RingDialPalette> _palettes = <RingDialPalette>[
    RingDialPalette.mono,
    RingDialPalette.cold,
    RingDialPalette.warm,
    RingDialPalette.rainbow,
  ];

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    // The nine ring-dial fields this control renders, and nothing else: a
    // whole-state read re-ran the whole knob list on every AppState write
    // (`Store.set` emits unconditionally; Freezed's `==` is a deep compare),
    // including the per-frame gesture writes it never displays.
    final ({
      RingDialPalette palette,
      double heightPct,
      DialSide side,
      RingDialAssignment assignment,
      bool hideChunkWhenUnchunked,
      bool vmProgressLock,
      double ringSlotT,
      double outerRadius,
      double innerRadius,
    }) dial = useAppStore().select(
      context,
      (AppState s) => (
        palette: s.ringDialPalette,
        heightPct: s.ringDialHeightPct,
        side: s.ringDialSide,
        assignment: s.ringDialAssignment,
        hideChunkWhenUnchunked: s.ringDialHideChunkWhenUnchunked,
        vmProgressLock: s.ringDialVmProgressLock,
        ringSlotT: s.ringDialRingSlotT,
        outerRadius: s.ringDialOuterRadius,
        innerRadius: s.ringDialInnerRadius,
      ),
    );

    // Scroll-safe: on very short panels the knobs degrade to scrolling
    // instead of overflowing.
    return SingleChildScrollView(
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            for (final RingDialPalette p in _palettes)
              _PaletteSwatch(
                key: ValueKey<String>('ring-dial-palette-${p.name}'),
                palette: p,
                selected: dial.palette == p,
                onTap: () =>
                    // ignore: discarded_futures
                    useAppStore().updateRingDialPalette(p),
              ),
          ],
        ),
        NormalizedSliderControl(
          showControl: showControl,
          icon: Icons.crop_portrait_rounded,
          label: t.ring_box_height,
          value: dial.heightPct * 100,
          min: 30,
          max: 100,
          divisions: 70,
          onChanged: (v) =>
              // ignore: discarded_futures
              useAppStore().updateRingDialHeightPct(v / 100.0, persist: false),
          onChangeEnd: (v) =>
              // ignore: discarded_futures
              useAppStore().updateRingDialHeightPct(v / 100.0),
          valueBuilder: (v) => Text('${v.toInt()}%'),
          color: color,
          overlayColor: overlayColor,
        ),
        // Shared side + functional assignment: all platforms (per latest decision).
        if (true) ...[
          Row(
            children: <Widget>[
              Icon(Icons.swap_horiz_rounded,
                  size: 20,
                  color: color ?? Theme.of(context).colorScheme.primary),
              const SizedBox(width: 4),
              Expanded(
                child: SegmentedButton<DialSide>(
                  segments: <ButtonSegment<DialSide>>[
                    ButtonSegment<DialSide>(
                        value: DialSide.inner, label: Text(t.ring_side_inner)),
                    ButtonSegment<DialSide>(
                        value: DialSide.outer, label: Text(t.ring_side_outer)),
                  ],
                  selected: <DialSide>{dial.side},
                  onSelectionChanged: (Set<DialSide> sel) =>
                      // ignore: discarded_futures
                      useAppStore().updateRingDialSide(sel.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                ),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Icon(Icons.sync_alt_rounded,
                  size: 20,
                  color: color ?? Theme.of(context).colorScheme.primary),
              const SizedBox(width: 4),
              Expanded(
                child: SegmentedButton<RingDialAssignment>(
                  segments: <ButtonSegment<RingDialAssignment>>[
                    ButtonSegment<RingDialAssignment>(
                        value: RingDialAssignment.innerChunk,
                        label: Text(t.ring_assign_inner)),
                    ButtonSegment<RingDialAssignment>(
                        value: RingDialAssignment.outerChunk,
                        label: Text(t.ring_assign_outer)),
                  ],
                  selected: <RingDialAssignment>{dial.assignment},
                  onSelectionChanged: (Set<RingDialAssignment> sel) =>
                      // ignore: discarded_futures
                      useAppStore().updateRingDialAssignment(sel.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                ),
              ),
            ],
          ),
        ],
        // Requirement #8: short videos (no chunked chunk ring) can hide the
        // wayfinding ring entirely — now follows the chunk ring, not fixed inner.
        SwitchListTile(
          key: const Key('ring-dial-hide-chunk'),
          dense: true,
          visualDensity: VisualDensity.compact,
          title: Text(t.ring_hide_unchunked),
          value: dial.hideChunkWhenUnchunked,
          activeColor: color ?? Theme.of(context).colorScheme.primary,
          onChanged: (bool v) =>
              // ignore: discarded_futures
              useAppStore().updateRingDialHideChunkWhenUnchunked(v),
        ),
        // Virtual media only: keep the progress-ring drag inside the current
        // file instead of walking into the neighbour file at 0/100%.
        SwitchListTile(
          key: const Key('ring-dial-vm-progress-lock'),
          dense: true,
          visualDensity: VisualDensity.compact,
          title: Text(t.ring_lock_vm_progress),
          value: dial.vmProgressLock,
          activeColor: color ?? Theme.of(context).colorScheme.primary,
          onChanged: (bool v) =>
              // ignore: discarded_futures
              useAppStore().updateRingDialVmProgressLock(v),
        ),
        NormalizedSliderControl(
          showControl: showControl,
          icon: Icons.radio_button_unchecked,
          label: t.ring_position,
          value: dial.ringSlotT * 100,
          min: 0,
          max: 100,
          divisions: 100,
          onChanged: (v) =>
              // ignore: discarded_futures
              useAppStore().updateRingDialRingSlotT(v / 100.0, persist: false),
          onChangeEnd: (v) =>
              // ignore: discarded_futures
              useAppStore().updateRingDialRingSlotT(v / 100.0),
          valueBuilder: (v) => Text('${v.toInt()}%'),
          color: color,
          overlayColor: overlayColor,
        ),
        NormalizedSliderControl(
          showControl: showControl,
          icon: Icons.circle_outlined,
          label: t.ring_outer_radius,
          value: dial.outerRadius * 100,
          min: 80,
          max: 100,
          divisions: 20,
          onChanged: (v) =>
              // ignore: discarded_futures
              useAppStore().updateRingDialOuterRadius(v / 100.0, persist: false),
          onChangeEnd: (v) =>
              // ignore: discarded_futures
              useAppStore().updateRingDialOuterRadius(v / 100.0),
          valueBuilder: (v) => Text('${v.toInt()}%'),
          color: color,
          overlayColor: overlayColor,
        ),
        NormalizedSliderControl(
          showControl: showControl,
          icon: Icons.adjust_rounded,
          label: t.ring_inner_radius,
          value: dial.innerRadius * 100,
          min: 30,
          max: 81,
          divisions: 51,
          onChanged: (v) =>
              // ignore: discarded_futures
              useAppStore().updateRingDialInnerRadius(v / 100.0, persist: false),
          onChangeEnd: (v) =>
              // ignore: discarded_futures
              useAppStore().updateRingDialInnerRadius(v / 100.0),
          valueBuilder: (v) => Text('${v.toInt()}%'),
          color: color,
          overlayColor: overlayColor,
        ),
      ],
      ),
    );
  }
}

/// Miniature preview of one palette: a 12-sector donut rendered with the very
/// `dialBlockColor` mapping the dial painter uses, so what you pick is what
/// you get. The selected swatch carries an accent ring.
class _PaletteSwatch extends StatelessWidget {
  const _PaletteSwatch({
    super.key,
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final RingDialPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Widget donut = CustomPaint(
      size: const Size(30, 30),
      painter: _DonutPainter(palette: palette),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: selected
            ? KeyedSubtree(
                key: const Key('ring-dial-palette-selected'),
                child: Container(
                  foregroundDecoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.fromBorderSide(BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 1.6,
                    )),
                  ),
                  child: donut,
                ),
              )
            : donut,
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter({required this.palette});

  final RingDialPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;
    // Canvas arcs measure from +x clockwise; start at −90° so sector 0 sits
    // at 12 o'clock, matching the dial itself.
    const double sweep = 2 * m.pi / kDialSectorCount;
    for (int i = 0; i < kDialSectorCount; i++) {
      p.color = dialBlockColor(palette, i);
      canvas.drawArc(rect.deflate(2.5), -m.pi / 2 + i * sweep, sweep, false, p);
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) =>
      oldDelegate.palette != palette;
}
