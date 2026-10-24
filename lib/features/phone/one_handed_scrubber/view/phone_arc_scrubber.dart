import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_one_handed_scrubber_math.dart';
import 'package:iris/features/phone/one_handed_scrubber/view/phone_scrubber_time.dart';
import 'package:iris/models/player.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/seek_tail_guard.dart';
import 'package:provider/provider.dart';

/// Ring one-handed scrubber: outer band absolute, inner relative (x1/8, x1/32).
/// Merged: dv4 session continuity + musespark seam/hysteresis/isSeeking guard.
class PhoneArcScrubber extends HookWidget {
  const PhoneArcScrubber({
    super.key,
    required this.showControl,
    required this.color,
    this.isLeftHanded = false,
  });

  final VoidCallback showControl;
  final Color? color;
  final bool isLeftHanded;

  @override
  Widget build(BuildContext context) {
    // AXTree stability (flutter/flutter#182444): see PhoneSnakeScrubber —
    // per-tick rebuilds with zero assistive value stay out of semantics.
    return ExcludeSemantics(child: _buildTree(context));
  }

  Widget _buildTree(BuildContext context) {
    final bool autoPlay = useAppStore().select(context, (state) => state.autoPlay);
    final progress = context.select<MediaPlayer, ({Duration position, Duration duration})>(
      (MediaPlayer player) => (position: player.position, duration: player.duration),
    );
    final Duration duration = progress.duration > Duration.zero
        ? progress.duration
        : const Duration(milliseconds: 1);
    final preview = useState(_clampDuration(progress.position, duration));
    final session = useRef<PhoneArcScrubSession?>(null);
    final lastPrecision = useRef<PhoneArcScrubPrecision?>(null);
    final MediaPlayer player = context.read<MediaPlayer>();

    // Single-owner scrub flag (latch-proof): `session` alone is never cleared
    // on this surface, so it cannot gate the preview.
    final bool isScrubbing =
        useScrubDragStore().select(context, (s) => s.isScrubbing);

    useEffect(() {
      if (!isScrubbing) {
        preview.value = _clampDuration(progress.position, duration);
      }
      return null;
    }, <Object>[progress.position, duration, isScrubbing]);

    return SizedBox(
      width: 210,
      height: 210,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Offset center = Offset(constraints.maxWidth / 2, constraints.maxHeight / 2);
          final double radius = constraints.maxWidth / 2 - 12;

          double angleFor(Offset local) =>
              math.atan2(local.dy - center.dy, local.dx - center.dx);

          PhoneArcScrubPrecision precisionFor(Offset local, PhoneArcScrubPrecision previous) {
            final double normalizedRadius = ((local - center).distance / radius).clamp(0.0, 1.0);
            const double hysteresis = 0.06;
            if (previous == PhoneArcScrubPrecision.overview) {
              if (normalizedRadius < 0.72 - hysteresis) {
                if (normalizedRadius >= 0.45 + hysteresis) return PhoneArcScrubPrecision.coarse;
                if (normalizedRadius < 0.45 - hysteresis) return PhoneArcScrubPrecision.fine;
                return previous;
              }
              return PhoneArcScrubPrecision.overview;
            }
            if (previous == PhoneArcScrubPrecision.coarse) {
              if (normalizedRadius >= 0.72 + hysteresis) return PhoneArcScrubPrecision.overview;
              if (normalizedRadius < 0.45 - hysteresis) return PhoneArcScrubPrecision.fine;
              return PhoneArcScrubPrecision.coarse;
            }
            if (normalizedRadius >= 0.72 + hysteresis) return PhoneArcScrubPrecision.overview;
            if (normalizedRadius >= 0.45 + hysteresis) return PhoneArcScrubPrecision.coarse;
            return PhoneArcScrubPrecision.fine;
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (DragStartDetails details) {
              final PhoneArcScrubSession s =
                  PhoneArcScrubSession(duration: duration)..reset(start: _clampDuration(progress.position, duration));
              session.value = s;
              lastPrecision.value = precisionFor(details.localPosition, PhoneArcScrubPrecision.overview);
              preview.value = s.target;
              showControl();
              useScrubDragStore().beginSeek(ScrubOwners.arc);
              // ignore: discarded_futures
              player.pause();
            },
            onPanUpdate: (DragUpdateDetails details) {
              final s = session.value;
              if (s == null) return;
              final PhoneArcScrubPrecision precision = precisionFor(details.localPosition, lastPrecision.value ?? PhoneArcScrubPrecision.overview);
              if (precision != lastPrecision.value) {
                HapticFeedback.selectionClick();
                lastPrecision.value = precision;
              }
              preview.value = s.update(
                angleRadians: angleFor(details.localPosition),
                precision: precision,
              );
              // No per-tick showControl: onPanStart armed the bar and the
              // scrub flags hold it for the whole drag.
            },
            onPanEnd: (DragEndDetails details) async {
              await _commit(player, preview.value, autoPlay);
            },
            onPanCancel: () async {
              await _cancel(player, autoPlay);
            },
            child: CustomPaint(
              painter: _PhoneArcScrubberPainter(
                fraction: preview.value.inMilliseconds / duration.inMilliseconds,
                color: color ?? Theme.of(context).colorScheme.primary,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      formatPhoneScrubberTime(preview.value),
                      style: TextStyle(fontSize: 22, color: color),
                    ),
                    Text(
                      '/ ${formatPhoneScrubberTime(duration)}',
                      style: TextStyle(color: color?.withValues(alpha: 0.75)),
                    ),
                    Text(
                      getLocalizations(context).scrubber_ring,
                      style: TextStyle(fontSize: 12, color: color?.withValues(alpha: 0.75)),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

Future<void> _commit(MediaPlayer player, Duration target, bool autoPlay) async {
  // A release at the very end is the explicit "finish this item": it lands ON the
  // end so the file completes and advances. Every other release stays inside the
  // shared tail guard.
  final bool atEnd =
      isSeekReleaseFinish(target.inMilliseconds, player.duration.inMilliseconds);
  await (atEnd ? (player.finishSeek ?? player.seek) : player.seek)(target);
  if (autoPlay) await player.play();
  useScrubDragStore().endSeek(ScrubOwners.arc);
}

Future<void> _cancel(MediaPlayer player, bool autoPlay) async {
  if (autoPlay) await player.play();
  useScrubDragStore().endSeek(ScrubOwners.arc);
}

class _PhoneArcScrubberPainter extends CustomPainter {
  const _PhoneArcScrubberPainter({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double start = -math.pi / 2;
    const double sweep = math.pi * 11 / 6;
    final Rect rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.width / 2 - 12,
    );
    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.24);
    canvas.drawArc(rect, start, sweep, false, track);
    canvas.drawArc(rect, start, sweep * fraction, false, track..color = color);
  }

  @override
  bool shouldRepaint(_PhoneArcScrubberPainter oldDelegate) =>
      oldDelegate.fraction != fraction || oldDelegate.color != color;
}

Duration _clampDuration(Duration candidate, Duration duration) {
  if (candidate < Duration.zero) return Duration.zero;
  if (candidate > duration) return duration;
  return candidate;
}
