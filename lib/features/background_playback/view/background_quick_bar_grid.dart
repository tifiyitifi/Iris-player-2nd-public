import 'dart:math' as math;

/// Deterministic arrangement of the vertical 副音 quick strip.
///
/// The strip lives beside the draggable one-handed side panel, so its height
/// changes on every drag frame. Measuring the real button size and writing it
/// back (post-frame `setState`) would create a layout/render feedback loop and
/// jank, therefore the column count is derived ONLY from the known button
/// extents — a pure function, cheap enough to run inline in `build`.

/// Row height of one quick-bar button: Material `IconButton` at the bar's
/// standard 48px size plus the 1px vertical padding above/below. Kept
/// deliberately larger than the real extent so the grid never claims more rows
/// fit than it can actually draw.
const double kQuickButtonExtent = 52;

/// Column width of one quick-bar button (same 48px capsule, rounded up for the
/// same safety margin).
const double kQuickColExtent = 52;

/// Gap between grid rows and between grid columns.
const double kQuickSpacing = 4;

/// Hard cap on the strip's column count so a short panel cannot claim the
/// whole screen width (product decision: 2).
const int kQuickMaxColumns = 2;

/// Number of actions the VERTICAL (side-panel) 副音 strip renders.
///
/// The widget builds its list from per-state tooltips, so the LENGTH is the
/// contract that lets the side panel's on-screen footprint be computed without
/// measuring the grid (see `sidewayQuickColumnWidth`). A new action must bump
/// this, or the settings dialog reserves the wrong width.
const int kQuickBarVerticalActionCount = 10;

/// Resolved layout of the vertical strip.
class QuickBarGrid {
  const QuickBarGrid({
    required this.columns,
    required this.rows,
    required this.width,
    required this.fits,
  });

  /// Number of columns to render (1..[kQuickMaxColumns]).
  final int columns;

  /// Rows per column; the LAST column may hold fewer (column-major fill).
  final int rows;

  /// Exact width the grid occupies, including inter-column gaps.
  final double width;

  /// Whether [rows] rows fit the available height. `false` → the caller must
  /// wrap the grid in a scroll view (the last-resort overflow), preserving the
  /// legacy single-column reachability of the rarest buttons.
  final bool fits;
}

/// Resolves the strip's column count and occupied width.
///
/// Prefers the FEWEST columns that fit, so a tall panel stays a single column
/// and only a short one widens into two — which keeps the primary (high
/// frequency) buttons in the first column and pushes the rarest ones to the
/// second column / overflow.
QuickBarGrid resolveQuickBarGrid({
  required int buttonCount,
  required double availableHeight,
  required double availableWidth,
}) {
  if (buttonCount <= 0) {
    return const QuickBarGrid(columns: 1, rows: 0, width: 0, fits: true);
  }

  final int rowsFit = availableHeight.isFinite
      ? math.max(1, (availableHeight / kQuickButtonExtent).floor())
      : buttonCount;
  final int maxCols = availableWidth.isFinite
      ? math.min(
          kQuickMaxColumns,
          math.max(
            1,
            ((availableWidth + kQuickSpacing) / (kQuickColExtent + kQuickSpacing))
                .floor(),
          ),
        )
      : kQuickMaxColumns;

  int rowsFor(int columns) => (buttonCount + columns - 1) ~/ columns;

  int columns = maxCols;
  bool fits = false;
  for (int candidate = 1; candidate <= maxCols; candidate++) {
    if (rowsFor(candidate) <= rowsFit) {
      columns = candidate;
      fits = true;
      break;
    }
  }

  final int rows = rowsFor(columns);
  final double width = columns * kQuickColExtent + (columns - 1) * kQuickSpacing;
  return QuickBarGrid(columns: columns, rows: rows, width: width, fits: fits);
}
