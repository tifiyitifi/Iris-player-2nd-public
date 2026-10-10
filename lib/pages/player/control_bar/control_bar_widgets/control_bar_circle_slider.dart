import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/services/bg_seek_window.dart';
import 'package:iris/features/background_playback/services/bg_vm_visibility.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/control_group/domain/center_zone.dart';
import 'package:iris/features/control_group/domain/center_zone_actions.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_ring_dial_math.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_scrubber_live_seek_throttle.dart';
import 'package:iris/features/virtual_media/interaction/ui/vm_dual_time.dart';
import 'package:iris/features/virtual_media/rule/vm_tick_extent.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/features/virtual_media/view/vm_scrubber_marks.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/center_zone_x.dart';
import 'package:iris/utils/format_duration_to_minutes.dart';
import 'package:iris/utils/logger.dart';
import 'package:provider/provider.dart';

/// Scrub-surface diagnostics (`log.dial`): drag hit-test + commit decisions.
final AreaKeyLog _dialLog = AreaKeyLog(LogKeys.dial);

// What A Philosophy of Software Design requires from comments
//
// According to the book, good comments must:
//
// Explain intent, constraints, and reasoning
//
// Describe rules and invariants
//
// Explain why the design exists, not what Flutter already shows
//
// Sit at class / method boundaries, not every line
//
// Bad comment:
//
// // Draw the active track
//
//
// Good comment:
//
// // The active track visually represents playback progress within a
// // constrained seeking model that prevents jumps across circular
// // playback boundaries.

// One-line test from the book (apply it here)
//
// Ask this:
//
// If I remove the comments, could a future developer safely modify
// the quadrant logic without breaking playback edge behavior?
//
// For this code:
//
// ❌ Without comments → they will break it
//
// ✅ With these comments → they understand the rules
//
// That means the comments are required and correct.

/// Center readout styles. Shared with the 45° sector-X hole measurement so the
/// laid-out text and the lines that dodge it can never drift apart; only the
/// layout-relevant fields matter for the measurement.
TextStyle _centerCurrentStyle(Color color) =>
    TextStyle(fontSize: 20, color: color);

TextStyle _centerTotalStyle(Color color) =>
    TextStyle(fontSize: 14, color: color);

TextStyle _centerSubStyle(Color color) =>
    TextStyle(fontSize: 11, height: 1.1, color: color.withValues(alpha: 0.65));

enum Quadrant { q1, q2, q3, q4 }

/// Logical quadrants used for circular edge-locking.
///
/// Returns the quadrant for given dx/dy (canvas Y-axis increases downward)
///
/// Quadrants are defined in canvas coordinates (Y increases downward)
/// and are used to detect intentional vs accidental crossings near
/// playback boundaries (0% and 100%).
Quadrant quadrantOf(double dx, double dy) {
  if (dx >= 0 && dy <= 0) return Quadrant.q1; // top-right
  if (dx < 0 && dy <= 0) return Quadrant.q2; // top-left
  if (dx < 0 && dy > 0) return Quadrant.q3; // bottom-left
  return Quadrant.q4; // bottom-right
}

double angleFromCenter(Offset center, Offset local) {
  final dx = local.dx - center.dx;
  final dy = local.dy - center.dy;
  double angleDeg = (math.atan2(dy, dx) * 180 / math.pi + 360) % 360;
  return (angleDeg + 90) % 360;
}

/// Circular playback slider with edge-locking semantics.
///
/// The slider represents playback progress on an incomplete circular arc
/// (0 o’clock → 11 o’clock = 0% → 100%). Because media playback frequently
/// jumps directly to 0% or 100% (e.g. auto-complete, restart, next media),
/// naive circular seeking would cause accidental wrap-around.
///
/// To prevent this, the circle is divided into four logical quadrants:
///
/// - Q1 (top-right, near 0%): locks forward movement to prevent jumping to end
/// - Q2 (top-left, near 100%): locks backward movement to prevent jumping to start
/// - Q3 & Q4 (bottom): unlock seeking and allow free movement
///
/// Locks are released when the user explicitly interacts (tap or drag),
/// ensuring intentional seeks are always possible while accidental edge
/// oscillations are avoided.
class ControlBarCircleSlider extends HookWidget {
  const ControlBarCircleSlider({
    super.key,
    this.showControl,
    this.disabled = false,
    this.color,
    this.minSize = 100,
    this.maxSize = 260,
    this.circleScale = 0.5, // default mid
  });

  final void Function()? showControl;
  final bool disabled;
  final Color? color;
  final double minSize;
  final double maxSize;
  final double circleScale; // [0.0 - 1.0]

  @override
  Widget build(BuildContext context) {
    final autoPlay = useAppStore().select(context, (state) => state.autoPlay);

    // Centre sectors are relative to the screen centre: the panel's 9-grid
    // anchor decides which horizontal side is "inward". Read imperatively —
    // the value only matters when a tap fires, not for painting.
    final bool inwardOnLeft =
        resolveSidePanelAlignment(useAppStore().state).x > 0;

    final progress = context.select<
        MediaPlayer,
        ({
          Duration position,
          Duration duration,
          Duration buffer,
        })>(
      (player) => (
        position: player.position,
        duration: player.duration,
        buffer: player.buffer,
      ),
    );

    final play = context.read<MediaPlayer>().play;
    final pause = context.read<MediaPlayer>().pause;
    final seek = context.read<MediaPlayer>().seek;
    // Live drag seeks are throttled to one per 120ms, the same contract as the
    // ring dial (an unthrottled per-pointer-event seek floods the backend).
    final seekThrottle =
        useMemoized(LiveSeekThrottle.new, const <Object?>[]);

    // Virtual-media segment marks (boundaries + probe-failed red arcs).
    // Suppressed while the controls target 副音: bg is a real single file, so
    // the foreground's VM arcs must not decorate the bg circle.
    final vmItemRaw = useVmPlaybackStore().select(context, (s) => s.item);
    final bgStore = useBackgroundPlaybackStore();
    final bgIsControl =
        bgStore.select(context, (s) => s.bgOwnsControls);
    final int? bgSeekFloorMs =
        bgStore.select(context, (s) => s.bgSeekFloorLocalMs);
    final int? bgSeekCeilingMs =
        bgStore.select(context, (s) => s.bgSeekCeilingLocalMs);
    final vmItem = vmItemForControlTarget(vmItemRaw, bgIsControl: bgIsControl);
    final vmMarks = useMemoized(() => computeVmScrubberMarks(vmItem), [vmItem]);
    // Boundary ticks, user-tinted (opaque white default) with per-side
    // extent from `vmMarkTickExtent` (7px default, 0 = flush).
    final vmTickArgb =
        useAppStore().select(context, (s) => s.vmMarkTickColor);
    final vmTickExtent =
        useAppStore().select(context, (s) => s.vmMarkTickExtent);

    final double max =
        progress.duration.inMilliseconds.toDouble().clamp(1, double.infinity);
    // 仅当前 + 高同步 bg playable window. The circle maps the whole file, so the
    // unreachable part is clamped on commit and marked (dim + radial ticks).
    final BgSeekWindow? bgWindow = bgIsControl
        ? resolveBgSeekWindow(
            duration: progress.duration,
            floorMs: bgSeekFloorMs,
            ceilingMs: bgSeekCeilingMs,
          )
        : null;
    double clampToWindow(double ms) =>
        bgWindow == null ? ms : clampBgSeekMs(bgWindow, ms.toInt()).toDouble();
    final double positionValue = clampToWindow(
        progress.position.inMilliseconds.toDouble().clamp(0.0, max));
    final double bufferValue =
        progress.buffer.inMilliseconds.toDouble().clamp(0.0, max);

    // B-scheme dual time: total rows keep the legacy sizes, sub rows render
    // smaller/dimmer underneath. Collapses to the legacy two rows when no
    // VM session (or a single-segment merge) is active. Labels use the
    // sync-aligned display values; the ring geometry keeps raw ms.
    final vmSync = useAppStore().select(context, (s) => s.vmDualTimeSync);
    final vmDual = VmDualTime.resolve(vmItem, progress.position.inMilliseconds,
        sync: vmSync);
    final Duration vmTotalPos =
        Duration(milliseconds: vmDual.displayVirtualMs);
    final Duration? vmSubPos = vmDual.showSub
        ? Duration(milliseconds: vmDual.displayLocalMs)
        : null;
    final Duration? vmSubDur = (vmDual.showSub && vmDual.segDurMs != null)
        ? Duration(milliseconds: vmDual.segDurMs!)
        : null;
    final Color centerBase =
        color ?? Theme.of(context).colorScheme.primary;

    const double arcSweepDeg = 330.0;

    // Persisted states across rebuilds
    final lastValueRef = useRef(positionValue);
    final lastRawRef = useRef(positionValue); // raw before endGuard clamp, for quick 100%→next on release
    final lockQuadrantRef = useRef<Quadrant?>(null);

    /// Converts a pointer position into a playback value with edge locking.
    ///
    /// This method enforces asymmetric boundary rules:
    /// - Crossing Q1 → Q2 clamps to 0%
    /// - Crossing Q2 → Q1 clamps to (max - ε)
    ///
    /// The lock is automatically released when the pointer enters
    /// bottom quadrants (Q3 or Q4), allowing normal circular motion.
    ///
    /// This prevents circular wrap-around when playback auto-resets
    /// or completes, while preserving smooth interaction elsewhere.
    double computeValueWithEdgeLock(Offset local, Offset center) {
      final dx = local.dx - center.dx;
      final dy = local.dy - center.dy;
      final currentQuadrant = quadrantOf(dx, dy);

      // --- HARD LOCK LOGIC WITH BOUNDARIES ---
      if (lockQuadrantRef.value != null) {
        if (lockQuadrantRef.value == Quadrant.q1 &&
            currentQuadrant == Quadrant.q2) {
          // Crossing Q1 → Q2 → return start of arc
          return 0.0;
        } else if (lockQuadrantRef.value == Quadrant.q2 &&
            currentQuadrant == Quadrant.q1) {
          // Crossing Q2 → Q1 → stick at the sub-end residency value.
          // Shares endGuardMs with the commit guard so a held 100% never
          // lands on the exact duration (no accidental advance to the
          // next media) and remains draggable back at any time.
          return math.max(0.0, max - PhoneRingDialMath.endGuardMs);
        }

        // Unlock when entering bottom quadrants
        if (currentQuadrant == Quadrant.q3 || currentQuadrant == Quadrant.q4) {
          lockQuadrantRef.value = null;
        }
      }

      // Set lock when entering top quadrants if no current lock
      if ((currentQuadrant == Quadrant.q1 || currentQuadrant == Quadrant.q2) &&
          lockQuadrantRef.value == null) {
        lockQuadrantRef.value = currentQuadrant;
      }

      // --- ANGLE CONVERSION ---
      double angleDeg = angleFromCenter(center, local);
      double relDeg = angleDeg.clamp(0.0, arcSweepDeg);

      return (relDeg / arcSweepDeg) * max;
    }

    bool isPointOnRing({
      required Offset local,
      required Offset center,
      required double radius,
      required double tolerance,
    }) {
      final distance = (local - center).distance;
      return (distance - radius).abs() <= tolerance;
    }

    bool isPointInCenter({
      required Offset local,
      required Offset center,
      required double radius,
      required double innerRadiusFactor,
    }) {
      final distance = (local - center).distance;
      return distance <= radius * innerRadiusFactor;
    }

    const double centerHitFactor = 0.45;
// └─ everything inside 45% radius is "center"

    void handleCircleCenterTap({
      required BuildContext context,
      required Offset local,
      required Offset center,
    }) {
      final CenterZone zone =
          centerZoneForOffset(local, center, inwardOnLeft: inwardOnLeft);
      final CircleSliderCenterAction action =
          resolveCenterZoneAction(useAppStore().state, zone);
      handleCenterZoneAction(
        context: context,
        action: action,
        showControl: showControl,
      );
    }

    return ExcludeSemantics(
      child: ExcludeFocus(
        child: Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final media = MediaQuery.of(context);
              // final availableWidth = constraints.maxWidth;

              final double buttonAreaHeight =
                  96; // space used by buttons under the circle
              final double maxAvailableHeight =
                  media.size.height - buttonAreaHeight;

              final double effectiveMaxSize =
                  math.min(maxAvailableHeight, maxSize);

              double size = lerpDouble(minSize, effectiveMaxSize, circleScale)!
                  .clamp(minSize, effectiveMaxSize);

              final double stroke = 4.0;
              final double radius = size / 2 - stroke;
              const double hitTolerance = 14.0; // ring thickness

              // Center readout: rendered by the CustomPaint child below, and
              // measured with the very same strings/styles here so the 45°
              // sector X can leave a hole over the numbers instead of drawing
              // through them.
              final String centerCurrent =
                  formatDurationToMinutes(vmTotalPos);
              final String centerTotal =
                  formatDurationToMinutes(progress.duration);
              final String? centerSubCurrent = vmSubPos == null
                  ? null
                  : formatDurationToMinutes(vmSubPos);
              final String? centerSubTotal = vmSubDur == null
                  ? null
                  : formatDurationToMinutes(vmSubDur);
              final double centerGapRadius = centerZoneGapRadius(
                rows: <({String text, TextStyle style})>[
                  (text: centerCurrent, style: _centerCurrentStyle(centerBase)),
                  if (centerSubCurrent != null)
                    (text: centerSubCurrent, style: _centerSubStyle(centerBase)),
                  (text: centerTotal, style: _centerTotalStyle(centerBase)),
                  if (centerSubTotal != null)
                    (text: centerSubTotal, style: _centerSubStyle(centerBase)),
                ],
                radius: radius * centerHitFactor,
              );

              return SizedBox(
                width: size,
                height: size,
                child: GestureDetector(
                  onPanStart: disabled
                      ? null
                      : (details) {
                          final box = context.findRenderObject() as RenderBox;
                          final local =
                              box.globalToLocal(details.globalPosition);
                          final center = box.size.center(Offset.zero);
                          // Unified drag contract (see PhoneRingDialScrubber):
                          // a drag ALWAYS scrubs. The old ring-tolerance
                          // rejection silently dropped the whole gesture for a
                          // press slightly off the band, while a tap on the
                          // same spot still acted — "click jumps, drag does
                          // nothing". The value is derived from the pointer
                          // ANGLE, so accepting everywhere stays correct.
                          lastValueRef.value = positionValue;
                          lastRawRef.value = positionValue;
                          showControl?.call();
                          useScrubDragStore()
                              .beginSeek(ScrubOwners.circleSlider);
                          seekThrottle.reset();
                          _dialLog.d('[circle-drag] start dist='
                              '${(local - center).distance.toStringAsFixed(1)} '
                              'radius=${radius.toStringAsFixed(1)} '
                              'tol=$hitTolerance value=$positionValue');
                          pause();
                        },
                  onPanEnd: disabled
                      ? null
                      : (_) async {
                          // 放行 onPanEnd：快速拉到 100% 后抬手可进下一首（仅拖时驻留可回拖）
                          // 阈值 99% 即视为有意到头，避免需像素级精确到 max
                          final double raw = lastRawRef.value;
                          if (raw >= max * 0.99) {
                            // Clamped into the 仅当前 window: reaching the fg
                            // 100% must never roll the next episode.
                            await seek(
                                Duration(milliseconds: clampToWindow(raw).toInt()));
                          } else {
                            // Always commit the final value: a throttled tail
                            // tick used to be dropped, leaving the release at
                            // whatever landed last.
                            await seek(Duration(
                                milliseconds: clampToWindow(PhoneRingDialMath
                                        .clampSeekTarget(
                                      Duration(
                                          milliseconds:
                                              lastValueRef.value.toInt()),
                                      progress.duration,
                                    ).inMilliseconds
                                        .toDouble())
                                    .toInt()));
                          }
                          _dialLog.d('[circle-drag] end raw=$raw '
                              'committed=${lastValueRef.value} '
                              'autoPlay=$autoPlay');
                          if (autoPlay) play();
                          useScrubDragStore()
                              .endSeek(ScrubOwners.circleSlider);
                        },
                  onPanUpdate: (details) {
                    final box = context.findRenderObject() as RenderBox;
                    final local = box.globalToLocal(details.globalPosition);
                    final center = box.size.center(Offset.zero);

                    final rawValue = computeValueWithEdgeLock(local, center);
                    // 仅拖时驻留：clamp 到 max-100 可回拖，放开可进下一首
                    // Then clamp into the 仅当前 bg window so the thumb never
                    // leaves the marked playable range.
                    final newValue = clampToWindow(PhoneRingDialMath
                        .clampSeekTarget(
                      Duration(milliseconds: rawValue.toInt()),
                      progress.duration,
                    ).inMilliseconds.toDouble());

                    if (newValue != lastValueRef.value) {
                      lastValueRef.value = newValue;
                      lastRawRef.value = rawValue;
                      // Throttled to one seek per 120ms, same as the ring dial:
                      // an unthrottled per-event seek floods the backend and
                      // makes the drag feel dead (the release commit below
                      // carries the final value).
                      if (seekThrottle.allow(DateTime.now())) {
                        seek(Duration(milliseconds: newValue.toInt()));
                      }
                    } else {
                      // Even if clamped value unchanged, keep raw for onPanEnd decision
                      lastRawRef.value = rawValue;
                    }
                  },
                  onPanCancel: disabled
                      ? null
                      : () {
                          _dialLog.d('[circle-drag] cancel');
                          useScrubDragStore()
                              .endSeek(ScrubOwners.circleSlider);
                        },
                  // Taps explicitly clear quadrant locks.
                  // A tap is treated as intentional seeking and must not be constrained
                  // by edge-lock rules designed for continuous drag motion.
                  onTapDown: disabled
                      ? null
                      : (d) {
                          final box = context.findRenderObject() as RenderBox;
                          final local = box.globalToLocal(d.globalPosition);
                          final center = box.size.center(Offset.zero);

                          // 1️⃣ CENTER TAP → UI COMMAND
                          if (isPointInCenter(
                            local: local,
                            center: center,
                            radius: radius,
                            innerRadiusFactor: centerHitFactor,
                          )) {
                            handleCircleCenterTap(
                              context: context,
                              local: local,
                              center: center,
                            );
                            return;
                          }

                          if (!isPointOnRing(
                            local: local,
                            center: center,
                            radius: radius,
                            tolerance: hitTolerance,
                          )) {
                            return; // ignore center & outside taps
                          }
                          // tap not need to block .
                          lockQuadrantRef.value = null;

                          final newValue =
                              computeValueWithEdgeLock(local, center);
                          lastValueRef.value = newValue;
                          showControl?.call();
                          // Taps still clear the quadrant lock, but commit
                          // through the end guard too: a tap on the arc
                          // end must not jump to the next media either, and the
                          // 仅当前 window caps where the seek may land.
                          seek(Duration(
                            milliseconds: clampToWindow(
                              PhoneRingDialMath.clampSeekTarget(
                                Duration(milliseconds: newValue.toInt()),
                                progress.duration,
                              ).inMilliseconds.toDouble(),
                            ).toInt(),
                          ));
                        },
                  child: CustomPaint(
                    painter: _CircleSliderPainter(
                      pos: positionValue,
                      buf: bufferValue,
                      max: max,
                      activeTrackColor: color?.withAlpha(222) ??
                          Theme.of(context).colorScheme.primary,
                      secondaryActiveTrackColor: color?.withAlpha(120) ??
                          Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.4),
                      inactiveTrackColor: color?.withAlpha(70) ??
                          Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.25),
                      thumbColor:
                          color ?? Theme.of(context).colorScheme.primary,
                      marks:
                          vmMarks.isEmpty ? null : vmMarks,
                      tickColor: Color(vmTickArgb),
                      tickExtent: vmTickExtent.toDouble(),
                      failedColor:
                          Theme.of(context).colorScheme.error,
                      windowFloorFraction: (bgWindow?.hasLimit ?? false)
                          ? bgWindow!.floorFraction
                          : null,
                      windowCeilingFraction: (bgWindow?.hasLimit ?? false)
                          ? bgWindow!.ceilingFraction
                          : null,
                      centerZoneHitFactor: centerHitFactor,
                      centerGapRadius: centerGapRadius,
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            centerCurrent,
                            style: _centerCurrentStyle(centerBase),
                          ),
                          if (centerSubCurrent != null)
                            Text(
                              centerSubCurrent,
                              style: _centerSubStyle(centerBase),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          Text(
                            centerTotal,
                            style: _centerTotalStyle(centerBase),
                          ),
                          if (centerSubTotal != null)
                            Text(
                              centerSubTotal,
                              style: _centerSubStyle(centerBase),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CircleSliderPainter extends CustomPainter {
  final double pos;
  final double buf;
  final double max;
  final Color activeTrackColor;
  final Color inactiveTrackColor;
  // buffered color, if has.
  final Color secondaryActiveTrackColor;
  final Color thumbColor;

  /// Virtual-media segment marks; null when no VM session is active.
  final VmScrubberMarks? marks;
  final Color? tickColor;

  /// Pixels the radial tick sticks out on EACH side (0 = flush dot).
  final double tickExtent;
  final Color? failedColor;

  /// 仅当前 + 高同步 bg playable window (whole-file fractions); null when the
  /// window covers the whole file (no marks are drawn).
  final double? windowFloorFraction;
  final double? windowCeilingFraction;

  /// Fraction of the ring radius covered by the center hit circle. When > 0
  /// the faint 45° X marking the four tap sectors is drawn inside it.
  final double centerZoneHitFactor;

  /// Radius of the hole the X leaves over the center time readout, from
  /// [centerZoneGapRadius]. 0 = no readout, full X.
  final double centerGapRadius;

  _CircleSliderPainter({
    required this.pos,
    required this.buf,
    required this.max,
    required this.activeTrackColor,
    required this.inactiveTrackColor,
    required this.secondaryActiveTrackColor,
    required this.thumbColor,
    this.marks,
    this.tickColor,
    this.tickExtent = kVmTickExtentDefault,
    this.failedColor,
    this.windowFloorFraction,
    this.windowCeilingFraction,
    this.centerZoneHitFactor = 0,
    this.centerGapRadius = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.0;
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - stroke;
    final rect = Rect.fromCircle(center: center, radius: radius);

    const arcStart = -math.pi / 2; // 0 o’clock
    const arcSweep = math.pi * 11 / 6; // 330° → 11 o’clock

    final basePaint = Paint()
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
        rect, arcStart, arcSweep, false, basePaint..color = inactiveTrackColor);

    if (buf > 0) {
      canvas.drawArc(rect, arcStart, (buf / max) * arcSweep, false,
          basePaint..color = secondaryActiveTrackColor);
    }

    canvas.drawArc(rect, arcStart, (pos / max) * arcSweep, false,
        basePaint..color = activeTrackColor);

    _paintVmMarks(canvas, center, radius, arcStart, arcSweep);
    _paintBgWindow(canvas, center, radius, arcStart, arcSweep);

    final thumbAngle = arcStart + (pos / max) * arcSweep;
    final thumbOffset = Offset(
      center.dx + radius * math.cos(thumbAngle),
      center.dy + radius * math.sin(thumbAngle),
    );

    canvas.drawCircle(thumbOffset, 5, Paint()..color = thumbColor);

    _paintCenterZoneX(canvas, center, radius);
  }

  /// Faint 45° X inside the center hit circle, marking the four tap sectors
  /// (inward / outward / top / bottom) as four independent arms around
  /// [centerGapRadius] — the middle stays clear of the center time readout
  /// (see [paintCenterZoneX]). Deliberately very low alpha: it is a hint,
  /// never a decoration over the video.
  void _paintCenterZoneX(Canvas canvas, Offset center, double radius) {
    final double factor = centerZoneHitFactor;
    if (factor <= 0) return;
    paintCenterZoneX(
      canvas,
      center: center,
      radius: radius * factor,
      gapRadius: centerGapRadius,
    );
  }

  /// Red arcs over probe-failed segment extents, then radial ticks at every
  /// segment boundary (mapped onto the 330° arc, ±[tickExtent]).
  void _paintVmMarks(
      Canvas canvas, Offset center, double radius, double arcStart,
      double arcSweep) {
    final marks = this.marks;
    if (marks == null || marks.isEmpty || max <= 0) return;

    if (failedColor != null) {
      final failedPaint = Paint()
        ..strokeWidth = 6.0
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.butt
        ..color = failedColor!;
      for (final span in marks.failedSpans) {
        canvas.drawArc(rect0(center, radius), arcStart + span.start * arcSweep,
            (span.end - span.start) * arcSweep, false, failedPaint);
      }
    }

    if (tickColor != null) {
      final tickPaint = Paint()
        ..strokeWidth = 2.0
        ..color = tickColor!;
      final e = tickExtent
          .clamp(kVmTickExtentMinPx.toDouble(), kVmTickExtentMaxPx.toDouble())
          .toDouble();
      for (final f in marks.boundaries) {
        final angle = arcStart + f * arcSweep;
        final from = Offset(center.dx + (radius - e) * math.cos(angle),
            center.dy + (radius - e) * math.sin(angle));
        final to = Offset(center.dx + (radius + e) * math.cos(angle),
            center.dy + (radius + e) * math.sin(angle));
        canvas.drawLine(from, to, tickPaint);
      }
    }
  }

  /// 仅当前 + 高同步: dims the arc parts outside the bg window and draws a
  /// radial tick at both edges. No-op when the window is null or full
  /// ("bg对齐段都在fg可播放范围就不能画").
  void _paintBgWindow(Canvas canvas, Offset center, double radius,
      double arcStart, double arcSweep) {
    final double? lo = windowFloorFraction;
    final double? hi = windowCeilingFraction;
    if (lo == null || hi == null) return;
    if (lo <= 0 && hi >= 1) return;
    final Rect band = rect0(center, radius);
    final Paint dim = Paint()
      ..strokeWidth = 6.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..color = Colors.black.withValues(alpha: 0.5);
    if (lo > 0) {
      canvas.drawArc(band, arcStart, lo * arcSweep, false, dim);
    }
    if (hi < 1) {
      canvas.drawArc(
          band, arcStart + hi * arcSweep, (1 - hi) * arcSweep, false, dim);
    }
    final Paint tickPaint = Paint()
      ..strokeWidth = 2.0
      ..color = Colors.white.withValues(alpha: 0.85);
    for (final double f in <double>[lo, hi]) {
      final double angle = arcStart + f * arcSweep;
      final Offset dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(center + dir * (radius - 7), center + dir * (radius + 7),
          tickPaint);
    }
  }

  Rect rect0(Offset center, double radius) =>
      Rect.fromCircle(center: center, radius: radius);

  @override
  bool shouldRepaint(_) => true;
}
