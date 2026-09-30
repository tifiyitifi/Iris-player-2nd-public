import 'dart:ui' show Offset;

import 'package:flutter/widgets.dart' show Axis;
import 'package:iris/features/speed/model/enum/speed_gesture_mode.dart';
import 'package:iris/globals.dart' show speedSelectorItemWidth;

const double kSpeedCoarseSensitivity = 120.0;
const double kSpeedDeadZone = 8.0;
const double kSpeedAxisHysteresis = 12.0;

int _stepsFor(double delta, double sens) {
  if (delta.abs() < kSpeedDeadZone) return 0;
  return (delta / sens).round();
}

Axis? resolveSpeedLockedAxis(Offset total, {Axis? previous}) {
  if (total.dx.abs() < kSpeedDeadZone && total.dy.abs() < kSpeedDeadZone) {
    return null;
  }
  if (previous != null) {
    final double lead = previous == Axis.horizontal
        ? total.dx.abs() - total.dy.abs()
        : total.dy.abs() - total.dx.abs();
    if (lead >= -kSpeedAxisHysteresis) return previous;
    return previous == Axis.horizontal ? Axis.vertical : Axis.horizontal;
  }
  return total.dx.abs() >= total.dy.abs() ? Axis.horizontal : Axis.vertical;
}

int resolveDualAxisSpeedIndex({
  required int baseIndex,
  required Offset total,
  required SpeedGestureMode mode,
  required bool isSelectorVisible,
  double hSens = speedSelectorItemWidth,
  double vSens = kSpeedCoarseSensitivity,
  Axis? previousAxis,
}) {
  if (mode == SpeedGestureMode.singleAxis || !isSelectorVisible) {
    final int h = _stepsFor(total.dx, hSens);
    if (h == 0) return baseIndex;
    return (baseIndex + h).clamp(0, 99);
  }
  final Axis axis =
      resolveSpeedLockedAxis(total, previous: previousAxis) ?? Axis.horizontal;
  if (axis == Axis.horizontal) {
    final int h = _stepsFor(total.dx, hSens);
    if (h == 0) return baseIndex;
    return (baseIndex + h).clamp(0, 99);
  }
  // Up stays +: negate dy so upward motion raises the coarse wheel.
  final int v = -_stepsFor(total.dy, vSens) * 10;
  if (v == 0) return baseIndex;
  return (baseIndex + v).clamp(0, 99);
}

/// Minimum horizontal travel before the transient speed window (the dual-axis
/// wheel overlay) may appear. The top long-press gesture must stay silent
/// (tip only) until the user makes a deliberate left/right slide; otherwise a
/// tiny vertical jitter would pop the whole window open.
const double kSpeedWindowOpenDx = 24.0;

bool shouldOpenTransientSpeedWindow({
  required Offset total,
  required Axis? lockedAxis,
}) =>
    lockedAxis == Axis.horizontal && total.dx.abs() >= kSpeedWindowOpenDx;

/// Splits a [speedStops] index into the two wheels: coarse integer 0..10
/// and cyclic fine digit 0..9. Linear index arithmetic already carries
/// fine overflow into coarse (1.9 +0.1 = 2.0); the wheels only visualize it.
({int coarse, int fine}) speedCoarseFine(int index) {
  final int v = index.clamp(0, 99) + 1;
  return (coarse: v ~/ 10, fine: v % 10);
}
