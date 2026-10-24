import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_scrubber_live_seek_throttle.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_snake_scrubber_math.dart';
import 'package:iris/features/phone/one_handed_scrubber/view/phone_scrubber_time.dart';
import 'package:iris/models/player.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:provider/provider.dart';

/// Serpentine 5-axis phone scrubber.
///
/// RETIRED — this surface can never render again: the `AppState` normalization
/// folds arc/timeLens/snake into the classic circle slider on load
/// (`use_app_store.dart`: "arc/timeLens/snake are FULLY retired"), and the
/// scrubber-kind dialog never offers it. Kept as the reference implementation
/// for the serpentine math and for a possible revival; do NOT spend behaviour
/// fixes on it (see [_commit]).
///
/// Path: 5 parallel horizontal bars joined by 4 outward semicircular turns;
/// progress is arc-length parameterized so the turns occupy playback too.
///
/// Interaction:
/// - On-line drag (narrow effective width) free-follows 0→100% with throttled
///   live seeking; off-line drag locks to the current bar's band.
/// - Holding still for [kHoldOnDelay] reveals the floating vertical fine axis;
///   a following vertical slide becomes locked ±Wfine adjust, a horizontal
///   slide cancels hold-on back to free follow.
/// - The inner fixed strip is a relative thin line + dot re-anchored at the
///   latest playback position on every fresh touch.
class PhoneSnakeScrubber extends HookWidget {
  const PhoneSnakeScrubber({
    super.key,
    required this.showControl,
    required this.color,
    required this.isLeftHanded,
  });

  final VoidCallback showControl;
  final Color? color;
  final bool isLeftHanded;

  /// Stillness duration that counts as a "precise stop".
  static const Duration kHoldOnDelay = Duration(milliseconds: 400);

  @override
  Widget build(BuildContext context) {
    // AXTree stability (flutter/flutter#182444): the scrubber rebuilds on
    // every playback position tick while its time texts carry zero assistive
    // value — the whole gesture canvas stays out of the semantics tree so it
    // cannot feed the engine's accessibility bridge.
    return ExcludeSemantics(child: _buildTree(context));
  }

  Widget _buildTree(BuildContext context) {
    final bool autoPlay = useAppStore().select(context, (state) => state.autoPlay);
    final bool isScrubbing =
        useScrubDragStore().select(context, (state) => state.isScrubbing);
    final int wFineSec = useAppStore().select(context, (state) => state.snakeFineWindowSeconds);
    final Duration wFine = Duration(seconds: wFineSec);
    final progress = context.select<MediaPlayer, ({Duration position, Duration duration})>(
      (MediaPlayer p) => (position: p.position, duration: p.duration),
    );
    final Duration duration = progress.duration > Duration.zero ? progress.duration : const Duration(milliseconds: 1);
    final preview = useState(_clamp(progress.position, duration));
    final session = useState<PhoneSnakeScrubSession?>(null);
    final MediaPlayer player = context.read<MediaPlayer>();

    // X of the floating fine line while visible; frozen at every hold-on
    // entry so the locked axis does not drift with the preview.
    final ValueNotifier<double?> floatLineX = useState<double?>(null);
    final ValueNotifier<Timer?> holdTimer = useState<Timer?>(null);
    // Preview snapshot the snake paint is locked to while a floating fine
    // adjust is active (hold-on → vertical slide); null means live follow.
    final ValueNotifier<Duration?> paintFreeze = useState<Duration?>(null);
    final LiveSeekThrottle seekThrottle =
        useMemoized(LiveSeekThrottle.new, const <Object?>[]);

    void cancelHold() {
      holdTimer.value?.cancel();
      holdTimer.value = null;
    }

    useEffect(() {
      return () => cancelHold();
    }, const <Object?>[]);

    useEffect(() {
      // The live session + the single-owner scrub flag together own the
      // preview; either alone could latch (a lost end event) and freeze the
      // thumb/time for the rest of the session.
      final bool dragOwns = isScrubbing && session.value != null;
      if (!dragOwns) {
        preview.value = _clamp(progress.position, duration);
      }
      return null;
    }, <Object>[progress.position, duration, isScrubbing]);

    const double innerStripW = 28;
    const double timeRowH = 20;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double panelW = constraints.maxWidth.isFinite ? constraints.maxWidth : 300;
        final double maxH = constraints.maxHeight.isFinite ? constraints.maxHeight : 280;
        // Compact sizing budget, mirroring ControlBarCircleSlider: reserve the
        // button row below so the whole control bar fits short landscape
        // screens without pushing the time row into the title area.
        const double kButtonReserveH = 96;
        const double kMinTracksH = 120;
        const double kMaxTracksH = 220;
        final double tracksBudget = maxH - timeRowH - kButtonReserveH;
        final double fittedTracksH = tracksBudget.clamp(kMinTracksH, kMaxTracksH).toDouble();
        final double axisH = fittedTracksH / PhoneSnakeScrubberMath.kAxisCount; // ∈ [24, 44]
        // Outward semicircular bulges extend past the bar ends by r on each
        // side; reserve that margin so the path never leaves the panel.
        final double bulgeR = axisH / 2;
        final double trackLeft = (isLeftHanded ? innerStripW : 0.0) + bulgeR;
        final double axisRightBound = isLeftHanded ? panelW : panelW - innerStripW;
        final double axisW = (axisRightBound - trackLeft - bulgeR).clamp(80.0, 600.0).toDouble();
        final double totalH = timeRowH + fittedTracksH;
        final double lineWidth = PhoneSnakeScrubberMath.effectiveLineWidth(axisH);
        // Pure value object; rebuilding it per layout pass is cheap and keeps
        // hooks out of LayoutBuilder (hooks must stay in build scope).
        final SerpentineGeometry geometry =
            PhoneSnakeScrubberMath.buildSerpentine(trackLeft: trackLeft, axisW: axisW, fittedTracksH: fittedTracksH);

        void armHold(Offset restPos) {
          cancelHold();
          holdTimer.value = Timer(kHoldOnDelay, () {
            final PhoneSnakeScrubSession? s = session.value;
            if (s == null || s.active != SnakeActiveMode.z || s.holdOn) return;
            s.enterHoldOn(touchPos: restPos);
            paintFreeze.value = preview.value;
            floatLineX.value = geometry.positionForU(PhoneSnakeScrubberMath.uForPosition(preview.value, duration)).dx;
            session.value = s;
            HapticFeedback.selectionClick();
          });
        }

        void liveSeek() {
          if (!seekThrottle.allow(DateTime.now())) return;
          final Duration target = preview.value;
          unawaited(player.seek(target).catchError((Object e) {}));
        }

        void startZ(Offset p) {
          final NearestOnPathResult proj = geometry.nearest(p);
          final int lockedBar = proj.isBar ? proj.barIndex : geometry.segments[proj.seg].index;
          final Duration anchor = PhoneSnakeScrubberMath.durationForU(geometry.uForSegFrac(proj.seg, proj.frac), duration);
          final PhoneSnakeScrubSession s = PhoneSnakeScrubSession(duration: duration, wFine: wFine);
          s.resetForZ(geometry: geometry, lockedBar: lockedBar, anchor: anchor);
          session.value = s;
          preview.value = anchor;
          floatLineX.value = null;
          showControl();
          useScrubDragStore().beginSeek(ScrubOwners.snake);
          unawaited(player.pause());
          armHold(p);
        }

        Future<void> endDrag(bool commit) async {
          cancelHold();
          seekThrottle.reset();
          session.value = null;
          floatLineX.value = null;
          paintFreeze.value = null;
          if (commit) {
            await _commit(player, preview.value, autoPlay);
          } else {
            await _cancel(player, autoPlay);
          }
        }

        final PhoneSnakeScrubSession? s = session.value;
        // While a fine adjust is locked in (hold-on → floating), the snake
        // paints the frozen anchor so the extension reads as continuing on
        // the fine axis; it jumps to the committed spot on release.
        final bool snakeLocked = s != null && (s.holdOn || s.active == SnakeActiveMode.floating);
        final Duration paintValue = snakeLocked ? (paintFreeze.value ?? preview.value) : preview.value;
        final Offset thumbTrackPos = geometry.positionForU(PhoneSnakeScrubberMath.uForPosition(paintValue, duration));
        final bool floatingAxisVisible = s != null && (s.holdOn || s.active == SnakeActiveMode.floating);
        final bool fixedActive = s?.active == SnakeActiveMode.fixed;
        final double floatLinePosX = floatLineX.value ?? thumbTrackPos.dx;
        // Signed pixel extension along the floating axis: + toward 100%
        // (downward slide), − toward 0%, scaled like updateFloating's inverse.
        final double halfSpan = fittedTracksH / 2;
        final double extPx = (floatingAxisVisible && wFine.inMilliseconds > 0)
            ? ((preview.value.inMilliseconds - paintValue.inMilliseconds) / wFine.inMilliseconds * halfSpan)
                .clamp(-halfSpan, halfSpan)
                .toDouble()
            : 0.0;

        Rect innerRectOf() => isLeftHanded
            ? Rect.fromLTWH(0, 0, innerStripW, fittedTracksH)
            : Rect.fromLTWH(panelW - innerStripW, 0, innerStripW, fittedTracksH);

        double fixedDotV() {
          final PhoneSnakeScrubSession? cur = session.value;
          if (cur == null || cur.active != SnakeActiveMode.fixed || wFine.inMilliseconds == 0) return 0;
          final double half = wFine.inMilliseconds / 2;
          return ((preview.value.inMilliseconds - cur.anchor.inMilliseconds) / half).clamp(-1.0, 1.0).toDouble();
        }

        return SizedBox(
          width: panelW,
          height: totalH,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: panelW,
                height: timeRowH,
                child: Center(
                  child: Text(
                    '${formatPhoneScrubberTime(preview.value)} / ${formatPhoneScrubberTime(duration)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: color ?? Colors.white,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: panelW,
                height: fittedTracksH,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (TapDownDetails d) {
                        if (innerRectOf().contains(d.localPosition)) return;
                        startZ(d.localPosition);
                      },
                      onTap: () async {
                        if (session.value != null) {
                          await endDrag(true);
                        }
                      },
                      onPanStart: (DragStartDetails d) {
                        if (innerRectOf().contains(d.localPosition)) return;
                        startZ(d.localPosition);
                      },
                      onPanUpdate: (DragUpdateDetails d) {
                        final PhoneSnakeScrubSession? cur = session.value;
                        if (cur == null || cur.active == SnakeActiveMode.fixed) return;
                        if (cur.active == SnakeActiveMode.floating) {
                          preview.value = cur.updateFloating(touchY: d.localPosition.dy, verticalSpan: fittedTracksH);
                          session.value = cur;
                          liveSeek();
                          return;
                        }
                        if (cur.holdOn) {
                          cur.moveFromHoldOn(touchPos: d.localPosition, verticalSpan: fittedTracksH);
                          if (cur.active == SnakeActiveMode.floating) {
                            session.value = cur;
                            return;
                          }
                          if (cur.holdOn) return; // jitter while holding
                          session.value = cur;
                          paintFreeze.value = null; // cancelled: resume live follow
                          armHold(d.localPosition); // cancelled: resume free follow
                        }
                        preview.value = cur.updateZPath(p: d.localPosition, lineWidth: lineWidth);
                        session.value = cur;
                        liveSeek();
                      },
                      onPanEnd: (DragEndDetails _) async {
                        if (session.value?.active == SnakeActiveMode.fixed) return;
                        await endDrag(true);
                      },
                      onPanCancel: () async {
                        if (session.value?.active == SnakeActiveMode.fixed) return;
                        await endDrag(false);
                      },
                      child: CustomPaint(
                        size: Size(panelW, fittedTracksH),
                        painter: _SnakePainter(
                          geometry: geometry,
                          preview: paintValue,
                          duration: duration,
                          color: color ?? Colors.white,
                          thumbPos: thumbTrackPos,
                        ),
                      ),
                    ),
                    // Floating vertical fine axis: hidden idle, hidden while
                    // sliding, revealed only on hold-on / floating adjust.
                    // Paints a guide line plus the signed fine extension
                    // growing out of the frozen snake thumb position.
                    Positioned(
                      left: (floatLinePosX - 1.5).clamp(0.0, panelW - 3).toDouble(),
                      top: 0,
                      width: 3,
                      height: fittedTracksH,
                      child: AnimatedOpacity(
                        opacity: floatingAxisVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 140),
                        child: IgnorePointer(
                          child: CustomPaint(
                            size: Size(3, fittedTracksH),
                            painter: _FloatAxisPainter(
                              color: color ?? Colors.white,
                              backColor: (color ?? Colors.white).withValues(alpha: 0.45),
                              anchorY: thumbTrackPos.dy,
                              extPx: extPx,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: (floatLinePosX - 22).clamp(0.0, panelW - 44).toDouble(),
                      top: (thumbTrackPos.dy - 16).clamp(0.0, fittedTracksH - 32).toDouble(),
                      width: 44,
                      height: 32,
                      child: AnimatedOpacity(
                        opacity: floatingAxisVisible ? 0.9 : 0,
                        duration: const Duration(milliseconds: 140),
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.black.withValues(alpha: 0.42),
                              border: Border.all(color: (color ?? Colors.white).withValues(alpha: 0.5)),
                            ),
                            child: Center(
                              child: Text(formatPhoneScrubberTime(preview.value),
                                  style: TextStyle(fontSize: 10, color: color ?? Colors.white)),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Inner fixed strip: relative thin line + dot.
                    Positioned(
                      left: isLeftHanded ? 0 : panelW - innerStripW,
                      top: 0,
                      width: innerStripW,
                      height: fittedTracksH,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (DragStartDetails d) {
                          final PhoneSnakeScrubSession ns = PhoneSnakeScrubSession(duration: duration, wFine: wFine);
                          // Always relative: anchor at the latest playback position.
                          ns.resetForFixed(anchor: _clamp(progress.position, duration), originY: d.localPosition.dy);
                          session.value = ns;
                          preview.value = ns.target;
                          showControl();
                          useScrubDragStore().beginSeek(ScrubOwners.snake);
                          unawaited(player.pause());
                        },
                        onPanUpdate: (DragUpdateDetails d) {
                          final PhoneSnakeScrubSession? cur = session.value;
                          if (cur == null || cur.active != SnakeActiveMode.fixed) return;
                          preview.value = cur.updateFixed(touchY: d.localPosition.dy, verticalSpan: fittedTracksH);
                          session.value = cur;
                          liveSeek();
                          // No per-tick showControl: onPanStart armed the bar.
                        },
                        onPanEnd: (DragEndDetails _) async {
                          await endDrag(true);
                        },
                        onPanCancel: () async {
                          await endDrag(false);
                        },
                        child: IgnorePointer(
                          child: CustomPaint(
                            size: Size(innerStripW, fittedTracksH),
                            painter: _FixedStripPainter(
                              color: color ?? Colors.white,
                              backColor: (color ?? Colors.white).withValues(alpha: 0.45),
                              dotV: fixedDotV(),
                              dotVisible: fixedActive,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Future<void> _commit(MediaPlayer player, Duration target, bool autoPlay) async {
  // NOT kept in sync with the live surfaces on purpose. They decide the tail
  // release with `isSeekReleaseFinish` (99 %, with the short-clip carve-out)
  // and always `play()` on release, while this one requires the very last
  // millisecond and pauses + latches a suppressed completion. The difference is
  // unreachable (see the class doc: the surface is retired), so unifying it
  // would only churn dead code — the live policies are the linear slider, the
  // circle slider and the ring dial.
  //
  // A release at the very end must land ON the end: the shared tail guard would
  // park 100 ms short, so the file would never complete. Everything else stays
  // inside the guard.
  final int durMs = player.duration.inMilliseconds;
  final bool atEnd = durMs > 0 && target.inMilliseconds >= durMs - 1;
  await (atEnd ? (player.finishSeek ?? player.seek) : player.seek)(target);
  if (target == Duration.zero) {
    await player.pause();
    useScrubDragStore().endSeek(ScrubOwners.snake);
    return;
  }
  if (atEnd) {
    await player.pause();
    usePlayerUiStore().updatePendingCompleted(true);
    useScrubDragStore().endSeek(ScrubOwners.snake);
    return;
  }
  if (autoPlay) await player.play();
  useScrubDragStore().endSeek(ScrubOwners.snake);
}

Future<void> _cancel(MediaPlayer player, bool autoPlay) async {
  if (autoPlay) await player.play();
  useScrubDragStore().endSeek(ScrubOwners.snake);
}

Duration _clamp(Duration candidate, Duration duration) {
  if (candidate < Duration.zero) return Duration.zero;
  if (candidate > duration) return duration;
  return candidate;
}

class _SnakePainter extends CustomPainter {
  _SnakePainter({
    required this.geometry,
    required this.preview,
    required this.duration,
    required this.color,
    required this.thumbPos,
  });

  final SerpentineGeometry geometry;
  final Duration preview;
  final Duration duration;
  final Color color;
  final Offset thumbPos;

  static const double kStroke = 4;

  Paint _strokePaint(Color c) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = kStroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = c;

  void _addSegment(Path path, SnakePathSegment seg, {required bool connect, double frac = 1}) {
    if (frac >= 1) {
      if (seg.isArc) {
        path.arcTo(Rect.fromCircle(center: seg.center, radius: seg.radius), seg.startAngle, seg.sweep, !connect);
      } else {
        if (!connect) path.moveTo(seg.start.dx, seg.start.dy);
        path.lineTo(seg.end.dx, seg.end.dy);
      }
      return;
    }
    if (seg.isArc) {
      path.arcTo(Rect.fromCircle(center: seg.center, radius: seg.radius), seg.startAngle, seg.sweep * frac, !connect);
    } else {
      final Offset pt = seg.pointAt(frac);
      if (!connect) path.moveTo(seg.start.dx, seg.start.dy);
      path.lineTo(pt.dx, pt.dy);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final List<SnakePathSegment> segs = geometry.segments;

    final Path trackPath = Path();
    for (int i = 0; i < segs.length; i++) {
      _addSegment(trackPath, segs[i], connect: i > 0);
    }
    canvas.drawPath(trackPath, _strokePaint(color.withValues(alpha: 0.24)));

    final double u = PhoneSnakeScrubberMath.uForPosition(preview, duration);
    final int segContaining = geometry.segForU(u);
    final double frac = geometry.fracForSegU(segContaining, u);
    final Path progressPath = Path();
    for (int i = 0; i <= segContaining; i++) {
      _addSegment(progressPath, segs[i], connect: i > 0, frac: i == segContaining ? frac : 1);
    }
    canvas.drawPath(progressPath, _strokePaint(color));

    canvas.drawCircle(thumbPos, 8, Paint()..color = color);
    canvas.drawCircle(thumbPos, 8, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = Colors.black.withValues(alpha: 0.4));
  }

  @override
  bool shouldRepaint(covariant _SnakePainter old) =>
      old.preview != preview || old.color != color || old.thumbPos != thumbPos;
}

/// Floating fine axis: faint full-height guide plus the signed extension
/// growing out of the frozen snake thumb — forward (toward 100%) uses the
/// normal color, backward (toward 0%) uses [backColor].
class _FloatAxisPainter extends CustomPainter {
  _FloatAxisPainter({
    required this.color,
    required this.backColor,
    required this.anchorY,
    required this.extPx,
  });

  final Color color;
  final Color backColor;
  final double anchorY;
  final double extPx;

  @override
  void paint(Canvas canvas, Size size) {
    final double x = size.width / 2;
    canvas.drawLine(
      Offset(x, 4),
      Offset(x, size.height - 4),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.22),
    );

    if (extPx.abs() < 0.5) return;
    final double y1 = anchorY.clamp(0.0, size.height);
    final double y2 = (anchorY + extPx).clamp(0.0, size.height);
    canvas.drawLine(
      Offset(x, y1),
      Offset(x, y2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = extPx > 0 ? color : backColor,
    );
    // Endpoint cap marks the live fine target on the axis.
    canvas.drawCircle(Offset(x, y2), 2.5, Paint()..color = extPx > 0 ? color : backColor);
  }

  @override
  bool shouldRepaint(covariant _FloatAxisPainter old) =>
      old.extPx != extPx || old.anchorY != anchorY || old.color != color || old.backColor != backColor;
}

/// Thin vertical guide line + relative offset dot for the inner fixed strip.
/// The segment between the center tick and the offset dot is colored by sign:
/// forward uses the normal color, backward uses [backColor].
class _FixedStripPainter extends CustomPainter {
  _FixedStripPainter({
    required this.color,
    required this.backColor,
    required this.dotV,
    required this.dotVisible,
  });

  final Color color;
  final Color backColor;
  final double dotV;
  final bool dotVisible;

  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final Paint linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.36);
    canvas.drawLine(Offset(cx, 6), Offset(cx, size.height - 6), linePaint);

    final double usableHalf = (size.height - 24) / 2;
    final double cy = size.height / 2 - dotV * usableHalf;
    final Paint tickPaint = Paint()..color = color.withValues(alpha: 0.5)..strokeWidth = 2;
    canvas.drawLine(Offset(cx - 5, size.height / 2), Offset(cx + 5, size.height / 2), tickPaint);

    if (!dotVisible) return;
    // Sign-colored extension: center tick → dot. Forward keeps the normal
    // color; backward (toward 0%) dims to the distinct back color.
    if ((cy - size.height / 2).abs() > 1) {
      canvas.drawLine(
        Offset(cx, size.height / 2),
        Offset(cx, cy),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..color = dotV > 0 ? color : backColor,
      );
    }
    canvas.drawCircle(Offset(cx, cy), 5, Paint()..color = dotV > 0 ? color : backColor);
    canvas.drawCircle(Offset(cx, cy), 5, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = Colors.black.withValues(alpha: 0.4));
  }

  @override
  bool shouldRepaint(covariant _FixedStripPainter old) =>
      old.dotV != dotV || old.dotVisible != dotVisible || old.color != color || old.backColor != backColor;
}
