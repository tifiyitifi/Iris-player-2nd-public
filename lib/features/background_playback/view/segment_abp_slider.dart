import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/background_playback/model/domain/background_mapping.dart';
import 'package:iris/features/background_playback/resolver/segment_span_math.dart';
import 'package:iris/features/background_playback/rule/segment_color.dart';
import 'package:iris/utils/format_duration_hms.dart';

/// Shared geometry of the editor's two axes.
///
/// Both rows use the SAME left/right label gutter and the same SliderTheme, so
/// their tracks line up pixel-for-pixel and the fg↔bg connector can be drawn as
/// a single straight line between them.
class SegmentAxisMetrics {
  const SegmentAxisMetrics({
    required this.trackLeft,
    required this.trackWidth,
  });

  /// Left edge of the visible track, in the coordinate space of the widget that
  /// owns this instance.
  final double trackLeft;

  /// Length of the visible track.
  final double trackWidth;

  double xOf(num ms, num totalMs) => trackLeft +
      (totalMs <= 0 ? 0 : (ms.clamp(0, totalMs) / totalMs)) * trackWidth;

  static double insetOf(BuildContext context) {
    final theme = SliderTheme.of(context);
    final thumbW = theme.thumbShape?.getPreferredSize(true, false).width ?? 0;
    final overlayW =
        theme.overlayShape?.getPreferredSize(true, false).width ?? 0;
    return math.max(thumbW, overlayW) / 2;
  }

  /// Metrics for the whole two-axis SECTION (padding + label gutter + track).
  factory SegmentAxisMetrics.section(BuildContext context, double width) {
    final inset = insetOf(context);
    return SegmentAxisMetrics(
      trackLeft: kSegmentRowPadding + kSegmentLabelWidth + inset,
      trackWidth: (width -
              2 * kSegmentRowPadding -
              2 * kSegmentLabelWidth -
              2 * inset)
          .clamp(1.0, double.infinity),
    );
  }

  /// Metrics for a single row's track area (the Expanded between the labels).
  factory SegmentAxisMetrics.row(BuildContext context, double width) {
    final inset = insetOf(context);
    return SegmentAxisMetrics(
      trackLeft: inset,
      trackWidth: (width - 2 * inset).clamp(1.0, double.infinity),
    );
  }
}

const double kSegmentLabelWidth = 52;
const double kSegmentRowPadding = 10;
const double kSegmentTrackRowHeight = 30;
const double kSegmentGapAfterFg = 2;

/// Vertical centre of the fg track inside the editor's timeline section.
const double kSegmentFgTrackCenter =
    kSegmentTrackRowHeight / 2;

/// Vertical centre of the bg track inside the editor's timeline section.
///
/// The section's column is `fg row → gap → bg row` ONLY (`_Timeline._build`).
/// Budgeting a bg file-NAME row that the layout never emits put this centre (and
/// the link painter drawing on it) 22px BELOW the bg track, with a blank strip
/// under the section.
const double kSegmentBgTrackCenter = kSegmentTrackRowHeight +
    kSegmentGapAfterFg +
    kSegmentTrackRowHeight / 2;

/// Total height of the two-axis section (both rows + the gap between them).
const double kSegmentTimelineHeight = kSegmentTrackRowHeight +
    kSegmentGapAfterFg +
    kSegmentTrackRowHeight;

/// A signed readout for the A handle: the bg time skipped before A
/// (`-mm:ss`), or empty when bg starts exactly at A.
String segmentLeadReadout(int leadInMs) =>
    leadInMs <= 0 ? '' : '-${formatDurationHms(Duration(milliseconds: leadInMs))}';

/// The foreground position the bg row's slider maps [value] to, or null when
/// that row has no axis at all.
///
/// With no 副音 file loaded ([bgDurMs] <= 0) the row still paints a live
/// [Slider] over a `0..1` track; dragging it projected `value - bgOffsetMs`
/// onto the foreground axis, so TOUCHING the empty row yanked the video
/// playhead. Null means "not a gesture": the row must be inert.
int? bgRowDragTargetMs({
  required double value,
  required int bgDurMs,
  required int bgOffsetMs,
  required int fgDurMs,
}) {
  if (bgDurMs <= 0 || fgDurMs <= 0) return null;
  return (value.round() - bgOffsetMs).clamp(0, fgDurMs);
}

/// The readout for the B handle: the UNUSED bg tail after B, always printed
/// with a `-` (「丢失了多少 bg 时间」). Empty when bg ends exactly at B. A raw
/// (unclamped) span may report a positive overflow — that is not a value the
/// user should ever see, so it is shown as empty rather than `+mm:ss`.
String segmentTailReadout(int tailMs) =>
    tailMs >= 0 ? '' : '-${formatDurationHms(Duration(milliseconds: tailMs.abs()))}';

/// The A/P/B track of the background (副音) axis.
///
/// A and B resize the mapped window; the centre handle P MOVES the whole
/// A–B window (A, B and therefore the mapped bg window travel together, 1:1).
/// Existing segments of the SAME bg file are drawn gray with white end ticks;
/// segments on other bg files are not representable on this axis and are
/// listed in the panel instead.
///
/// While A or B is being dragged the centre handle is HIDDEN so the endpoints
/// can move freely, even across the old centre, freely shrinking the window.
class SegmentAbpTrack extends HookWidget {
  const SegmentAbpTrack({
    super.key,
    required this.bgDurMs,
    required this.startMs,
    required this.endMs,
    required this.sameFileExisting,
    required this.editingId,
    this.snapActive = false,
    this.snapWallTicks = const <int>[],
    this.snapReleasedTicks = const <int>{},
    this.onChangeStart,
    this.onChangeEnd,
    this.onTranslate,
    this.onDragActive,
  });

  final int bgDurMs;
  final int startMs;
  final int endMs;
  final List<MappingSegment> sameFileExisting;
  final int editingId;

  /// Snap-to-saved-boundary (卡值） overlay, already mapped to bg ms by the
  /// host: wall ticks plus the released subset (not drawn).
  final bool snapActive;
  final List<int> snapWallTicks;
  final Set<int> snapReleasedTicks;
  final ValueChanged<int>? onChangeStart;
  final ValueChanged<int>? onChangeEnd;
  final ValueChanged<int>? onTranslate;

  /// Fires true while an A/B handle drag is in flight and false on release —
  /// the parent keeps the live span local for the duration of the gesture and
  /// hides P.
  final ValueChanged<bool>? onDragActive;

  @override
  Widget build(BuildContext context) {
    final activeHandle = useState<SegmentPoint?>(null);
    if (bgDurMs <= 0) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final centerColor = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final tick = Colors.white.withValues(alpha: 0.9);
    final readoutStyle = theme.textTheme.labelSmall?.copyWith(
      color: Colors.white.withValues(alpha: 0.92),
      fontSize: 10,
    );

    void setHandle(SegmentPoint? p) {
      if (activeHandle.value == p) return;
      activeHandle.value = p;
      onDragActive?.call(p != null);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final m = SegmentAxisMetrics.row(context, constraints.maxWidth);
        final trackW = m.trackWidth;
        final cy = constraints.maxHeight / 2;
        const barH = 6.0;

        double xOf(num ms) => m.xOf(ms, bgDurMs);
        final aX = xOf(startMs);
        final bX = xOf(endMs);
        final centerX = (aX + bX) / 2;

        final leadText = segmentLeadReadout(startMs);
        final tailText = segmentTailReadout(endMs - bgDurMs);
        final hideCenter = activeHandle.value == SegmentPoint.a ||
            activeHandle.value == SegmentPoint.b;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _AbpPainter(
                  m: m,
                  bgDurMs: bgDurMs,
                  startMs: startMs,
                  endMs: endMs,
                  existing: sameFileExisting,
                  editingId: editingId,
                  accent: accent,
                  tick: tick,
                  barH: barH,
                  snapActive: snapActive,
                  snapWallTicks: snapWallTicks,
                  snapReleasedTicks: snapReleasedTicks,
                ),
              ),
            ),
            _handle(
              key: const ValueKey('segment_handle_start'),
              left: aX - 8,
              top: cy - 8,
              color: accent,
              onDragStart: () => setHandle(SegmentPoint.a),
              onDragEnd: () => setHandle(null),
              onDeltaPx: (dx) => onChangeStart
                  ?.call((startMs + dx / trackW * bgDurMs).round()),
            ),
            if (!hideCenter)
              _handle(
                key: const ValueKey('segment_handle_center'),
                left: centerX - 8,
                top: cy - 8,
                color: centerColor,
                onDragStart: () => setHandle(SegmentPoint.p),
                onDragEnd: () => setHandle(null),
                onDeltaPx: (dx) =>
                    onTranslate?.call((dx / trackW * bgDurMs).round()),
              ),
            _handle(
              key: const ValueKey('segment_handle_end'),
              left: bX - 8,
              top: cy - 8,
              color: accent,
              onDragStart: () => setHandle(SegmentPoint.b),
              onDragEnd: () => setHandle(null),
              onDeltaPx: (dx) => onChangeEnd
                  ?.call((endMs + dx / trackW * bgDurMs).round()),
            ),
            if (leadText.isNotEmpty)
              _readout(
                key: const ValueKey('segment_lead_readout'),
                left: aX - 24,
                top: cy + 9,
                text: leadText,
                style: readoutStyle,
              ),
            if (tailText.isNotEmpty)
              _readout(
                key: const ValueKey('segment_tail_readout'),
                left: bX - 24,
                top: cy + 9,
                text: tailText,
                style: readoutStyle,
              ),
          ],
        );
      },
    );
  }

  static Widget _readout({
    required Key key,
    required double left,
    required double top,
    required String text,
    required TextStyle? style,
  }) =>
      Positioned(
        key: key,
        left: left,
        top: top,
        width: 48,
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: style,
        ),
      );

  static Widget _handle({
    required Key key,
    required double left,
    required double top,
    required Color color,
    ValueChanged<double>? onDeltaPx,
    VoidCallback? onDragStart,
    VoidCallback? onDragEnd,
  }) {
    return Positioned(
      key: key,
      left: left,
      top: top,
      width: 16,
      height: 16,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: onDragStart == null ? null : (_) => onDragStart(),
        onPanUpdate: (d) => onDeltaPx?.call(d.delta.dx),
        onPanEnd: onDragEnd == null ? null : (_) => onDragEnd(),
        onPanCancel: onDragEnd,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border:
                Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _AbpPainter extends CustomPainter {
  _AbpPainter({
    required this.m,
    required this.bgDurMs,
    required this.startMs,
    required this.endMs,
    required this.existing,
    required this.editingId,
    required this.accent,
    required this.tick,
    required this.barH,
    this.snapActive = false,
    this.snapWallTicks = const <int>[],
    this.snapReleasedTicks = const <int>{},
  });

  final SegmentAxisMetrics m;
  final int bgDurMs;
  final int startMs;
  final int endMs;
  final List<MappingSegment> existing;
  final int editingId;
  final Color accent;
  final Color tick;
  final double barH;

  /// Snap-to-saved-boundary (卡值） overlay (see [SegmentAbpTrack]).
  final bool snapActive;
  final List<int> snapWallTicks;
  final Set<int> snapReleasedTicks;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    double xOf(num ms) => m.xOf(ms, bgDurMs);

    final tickPaint = Paint()
      ..color = tick
      ..strokeWidth = 2;
    for (final s in existing) {
      if (s.id == editingId) continue;
      final bs = s.bgStartMs;
      final be = s.bgEndMs;
      if (bs == null || be == null) continue;
      final x0 = xOf(bs);
      final x1 = xOf(be);
      if (x1 > x0) {
        // Each saved segment keeps its own label colour (stable fallback when
        // the row predates v32) so the axis reads segment-by-segment.
        final color = Color(
          resolveSegmentColorArgb(explicit: s.colorArgb, seed: s.fgStartMs),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(x0, cy - barH / 2, x1, cy + barH / 2),
            const Radius.circular(3),
          ),
          Paint()..color = color.withValues(alpha: 0.72),
        );
      }
      for (final x in [x0, x1]) {
        canvas.drawLine(Offset(x, cy - barH - 3), Offset(x, cy + barH + 3),
            tickPaint);
      }
    }

    // The mapped window, clipped to the real bg file: a span longer than the bg
    // content only lights the covered part — it never grows beyond A–B.
    final aX = xOf(startMs);
    final bX = xOf(endMs.clamp(0, bgDurMs));
    if (bX > aX) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(aX, cy - barH / 2 - 1, bX, cy + barH / 2 + 1),
          const Radius.circular(4),
        ),
        Paint()..color = accent.withValues(alpha: 0.95),
      );
    }

    // Snap walls (卡值）: saved-boundary ticks, lighter than the saved-segment
    // ticks; released walls are not drawn.
    if (snapActive && snapWallTicks.isNotEmpty) {
      final snapPaint = Paint()
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.16)
        ..strokeWidth = 1.2;
      for (final t in snapWallTicks) {
        if (snapReleasedTicks.contains(t)) continue;
        final x = xOf(t);
        canvas.drawLine(Offset(x, cy - barH - 3), Offset(x, cy + barH + 3),
            snapPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_AbpPainter old) =>
      old.bgDurMs != bgDurMs ||
      old.startMs != startMs ||
      old.endMs != endMs ||
      old.existing != existing ||
      old.editingId != editingId ||
      old.accent != accent ||
      old.tick != tick ||
      old.snapActive != snapActive ||
      !_snapTicksEqual(old.snapWallTicks, snapWallTicks) ||
      !_snapTickSetsEqual(old.snapReleasedTicks, snapReleasedTicks);

  /// Value comparison for the snap overlay (the host hands fresh collections
  /// per build, so identity comparison would repaint every tick).
  static bool _snapTicksEqual(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _snapTickSetsEqual(Set<int> a, Set<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }
}

/// The 「实线-点虚线」 connector linking the foreground playhead to the
/// background playhead: the solid half leaves the fg dot, the dash-dot half
/// lands on the bg playhead's column, so a glance shows where fg position maps
/// on the bg timeline.
///
/// Only the FOREGROUND carries a playback dot: fg and bg progress are linked
/// (play/pause/step all mirror), so a second progress dot on the bg axis would
/// just repeat it. The APB window is the alignment layer, not a progress meter.
class SegmentLinkPainter extends CustomPainter {
  SegmentLinkPainter({
    required this.metrics,
    required this.fgDurMs,
    required this.bgDurMs,
    required this.fgPosMs,
    required this.bgPosMs,
    required this.color,
    required this.span,
    this.viewStartMs = 0,
    this.viewWidthMs = 0,
  });

  final SegmentAxisMetrics metrics;
  final int fgDurMs;
  final int bgDurMs;
  final int fgPosMs;
  final int bgPosMs;
  final Color color;
  final SegmentSpan span;

  /// APB foreground zoom window (0 width = the whole foreground).
  final int viewStartMs;
  final int viewWidthMs;

  /// Foreground-x of [ms] inside the visible window.
  double _fgX(num ms) {
    if (viewWidthMs <= 0) return metrics.xOf(ms, fgDurMs);
    final double f = ((ms - viewStartMs) / viewWidthMs).clamp(0.0, 1.0);
    return metrics.trackLeft + f * metrics.trackWidth;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (fgDurMs <= 0 || bgDurMs <= 0) return;

    final fgX = _fgX(fgPosMs);
    final bgX = metrics.xOf(bgPosMs, bgDurMs);
    final yFg = kSegmentFgTrackCenter;
    final yBg = kSegmentBgTrackCenter;
    final midY = (yFg + yBg) / 2;

    final up = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final dash = Paint()
      ..color = color.withValues(alpha: 0.75)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    // Solid half: fg playhead → the vertical midpoint.
    canvas.drawLine(Offset(fgX, yFg), Offset(fgX, midY), up);
    // Solid half continues horizontally to the bg column.
    canvas.drawLine(Offset(fgX, midY), Offset(bgX, midY), up);
    // Dash-dot half: down to the bg playhead column (no dot — see the class doc).
    _drawDashDot(canvas, Offset(bgX, midY), Offset(bgX, yBg), dash);

    // The ONE playback dot, bound to the foreground playhead.
    canvas.drawCircle(Offset(fgX, yFg), 3.5, Paint()..color = color);

    // A/B window edges on the bg axis, faint vertical rules so the link is
    // readable against the span.
    final edge = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (final ms in [span.bgStartMs, span.bgEndMs]) {
      final x = metrics.xOf(ms, bgDurMs);
      canvas.drawLine(Offset(x, yBg - 9), Offset(x, yBg + 9), edge);
    }
  }

  static void _drawDashDot(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 5.0;
    const gap = 3.0;
    const dot = 1.5;
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var t = 0.0;
    var on = true;
    while (t < total) {
      final len = on ? dash : (t > total / 2 ? dot : gap);
      final end = math.min(t + len, total);
      if (on || (t > total / 2)) {
        canvas.drawLine(a + dir * t, a + dir * end, paint);
      }
      t = end + (on ? gap : gap);
      on = !on;
      if (t >= total) break;
    }
  }

  @override
  bool shouldRepaint(SegmentLinkPainter old) =>
      old.fgPosMs != fgPosMs ||
      old.bgPosMs != bgPosMs ||
      old.metrics.trackLeft != metrics.trackLeft ||
      old.metrics.trackWidth != metrics.trackWidth ||
      old.fgDurMs != fgDurMs ||
      old.bgDurMs != bgDurMs ||
      old.viewStartMs != viewStartMs ||
      old.viewWidthMs != viewWidthMs ||
      old.span != span ||
      old.color != color;
}

/// Gray spans of the existing timeline plus the span under edit, drawn behind
/// the fg slider — the foreground-axis view of "which parts already have a
/// mapping" and "which part this edit will claim".
///
/// The active span is clipped to the part the bg file can actually cover; the
/// uncovered remainder is simply not lit, so a bogus span never looks longer
/// than the window A–B.
class SegmentFgMarksPainter extends CustomPainter {
  SegmentFgMarksPainter({
    required this.metrics,
    required this.fgDurMs,
    required this.existing,
    required this.editingId,
    required this.tick,
    this.activeStartMs,
    this.activeEndMs,
    this.activeSilence = false,
    this.accent,
    this.viewStartMs = 0,
    this.viewWidthMs = 0,
  });

  final SegmentAxisMetrics metrics;
  final int fgDurMs;
  final List<MappingSegment> existing;
  final int editingId;
  final Color tick;
  final int? activeStartMs;
  final int? activeEndMs;
  final bool activeSilence;
  final Color? accent;

  /// APB foreground zoom window (0 width = the whole foreground).
  final int viewStartMs;
  final int viewWidthMs;

  double _xOf(num ms) {
    if (viewWidthMs <= 0) return metrics.xOf(ms, fgDurMs);
    final double f = ((ms - viewStartMs) / viewWidthMs).clamp(0.0, 1.0);
    return metrics.trackLeft + f * metrics.trackWidth;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (fgDurMs <= 0) return;
    final cy = size.height / 2;
    const barH = 6.0;
    final tickPaint = Paint()
      ..color = tick
      ..strokeWidth = 2;
    for (final s in existing) {
      if (s.id == editingId) continue;
      final x0 = _xOf(s.fgStartMs);
      final x1 = _xOf(s.fgEndMs);
      if (x1 > x0) {
        // Per-segment label colour (stable fallback for pre-v32 rows): the fg
        // axis reads "which saved mapping claims which slice" at a glance.
        final color = Color(
          resolveSegmentColorArgb(explicit: s.colorArgb, seed: s.fgStartMs),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(x0, cy - barH / 2, x1, cy + barH / 2),
            const Radius.circular(3),
          ),
          Paint()..color = color.withValues(alpha: 0.72),
        );
      }
      for (final x in [x0, x1]) {
        canvas.drawLine(Offset(x, cy - barH - 3), Offset(x, cy + barH + 3),
            tickPaint);
      }
    }

    final a = activeStartMs;
    final b = activeEndMs;
    final c = accent;
    if (a != null && b != null && c != null && b > a) {
      final x0 = _xOf(a);
      final x1 = _xOf(b);
      if (x1 > x0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(x0, cy - barH / 2 - 1, x1, cy + barH / 2 + 1),
            const Radius.circular(4),
          ),
          Paint()..color = c.withValues(alpha: activeSilence ? 0.75 : 0.95),
        );
      }
    }
  }

  @override
  bool shouldRepaint(SegmentFgMarksPainter old) =>
      old.fgDurMs != fgDurMs ||
      old.existing != existing ||
      old.editingId != editingId ||
      old.activeStartMs != activeStartMs ||
      old.activeEndMs != activeEndMs ||
      old.activeSilence != activeSilence ||
      old.viewStartMs != viewStartMs ||
      old.viewWidthMs != viewWidthMs ||
      old.metrics.trackLeft != metrics.trackLeft ||
      old.metrics.trackWidth != metrics.trackWidth;
}
