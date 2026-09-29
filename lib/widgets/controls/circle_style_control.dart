import 'dart:math' as m;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/globals.dart' show sidePanelKeyNotifier;
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/controls/normalized_slider_control.dart';
import 'package:popover/popover.dart';

/// Fixed width of the circle style card (mirrors ring dial).
const double kCircleStyleCardWidth = 300;

/// Pure anchor geometry for the circle style card: emerges from the panel's
/// centre-facing edge so it never covers the circle, clamped to stay on screen.
Rect circleStyleCardRect({
  required Rect panel,
  required Size screen,
  required bool innerIsLeft,
  double cardWidth = kCircleStyleCardWidth,
}) {
  final double h = m.min(340.0, m.max(96.0, (screen.height - 16) * 0.86));
  final double rawLeft = innerIsLeft ? panel.left - 8 - cardWidth : panel.right + 8;
  final double left = rawLeft.clamp(8.0, m.max(8.0, screen.width - cardWidth - 8));
  final double top = panel.top.clamp(8.0, m.max(8.0, screen.height - h - 8)).toDouble();
  return Rect.fromLTWH(left, top, cardWidth, h);
}

/// Circle style popover for simple circle arc: scale (0..100%, default 90%)
/// and relative position X/Y (0..1, center 0.5) inside the sideway panel.
/// Anchored beside the panel like ring dial, fallback to gear-anchored popover.
Future<void> showCircleStyleControlPopover(
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
    // Card side follows the PANEL's resolved hand, not the raw mode (see
    // resolvePanelSideIsLeft).
    final bool isLeftSide = panelIsLeftHanded(useAppStore().state);
    final Rect card = circleStyleCardRect(
      panel: panel,
      screen: screen,
      innerIsLeft: !isLeftSide,
    );
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Circle style',
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
                child: CircleStyleControl(showControl: showControl),
              ),
            ),
          ),
        ],
      ),
    );
    return;
  }

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
      child: CircleStyleControl(showControl: showControl),
    ),
    direction: PopoverDirection.top,
    width: kCircleStyleCardWidth,
    height: h,
    arrowHeight: 0,
    arrowWidth: 0,
    backgroundColor: Theme.of(context).colorScheme.surface,
    barrierColor: Colors.transparent,
  );
}

class CircleStyleControl extends HookWidget {
  const CircleStyleControl({
    super.key,
    required this.showControl,
    this.color,
    this.overlayColor,
  });

  final VoidCallback showControl;
  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final double scale = useAppStore().select(context, (s) => s.circleSliderScale);
    final double posX = useAppStore().select(context, (s) => s.circlePosX);
    final double posY = useAppStore().select(context, (s) => s.circlePosY);

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Scale: 0..100% (default 90%), 1% steps — decides span share.
          NormalizedSliderControl(
            showControl: showControl,
            icon: Icons.zoom_out_map_rounded,
            label: t.circle_scale,
            value: scale * 100,
            min: 0,
            max: 100,
            divisions: 100,
            onChanged: (v) =>
                // ignore: discarded_futures
                useAppStore().updateCircleSliderScale(v / 100.0, persist: false),
            onChangeEnd: (v) =>
                // ignore: discarded_futures
                useAppStore().updateCircleSliderScale(v / 100.0),
            valueBuilder: (v) => Text('${v.round()}%'),
            color: color,
            overlayColor: overlayColor,
          ),
          // Position X: 0..1 (center 0.5) — relative inside panel, 1% steps.
          NormalizedSliderControl(
            showControl: showControl,
            icon: Icons.swap_horiz_rounded,
            label: t.circle_pos_x,
            value: posX * 100,
            min: 0,
            max: 100,
            divisions: 100,
            onChanged: (v) =>
                // ignore: discarded_futures
                useAppStore().updateCirclePosX(v / 100.0, persist: false),
            onChangeEnd: (v) =>
                // ignore: discarded_futures
                useAppStore().updateCirclePosX(v / 100.0),
            valueBuilder: (v) => Text('${v.round()}%'),
            color: color,
            overlayColor: overlayColor,
          ),
          // Position Y: 0..1 (center 0.5), 1% steps.
          NormalizedSliderControl(
            showControl: showControl,
            icon: Icons.swap_vert_rounded,
            label: t.circle_pos_y,
            value: posY * 100,
            min: 0,
            max: 100,
            divisions: 100,
            onChanged: (v) =>
                // ignore: discarded_futures
                useAppStore().updateCirclePosY(v / 100.0, persist: false),
            onChangeEnd: (v) =>
                // ignore: discarded_futures
                useAppStore().updateCirclePosY(v / 100.0),
            valueBuilder: (v) => Text('${v.round()}%'),
            color: color,
            overlayColor: overlayColor,
          ),
          const SizedBox(height: 4),
          Text(
            t.circle_note,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
