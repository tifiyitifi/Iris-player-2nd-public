import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/adaptive/keyboard_form_shell.dart';

/// Toolbar primitives shared by [DynamicResponsiveBar] (the responsive V1 bar),
/// [CompactSingleRowBar] (the single-row V2 bar) and [FloatingGridBar] (the
/// floating V3 grid).
///
/// All three layouts must present the SAME controls and the SAME prompts — the
/// page counter, the per-page chip and the go-to-current button are one feature,
/// not three — so the widgets and the two keyboard prompts live here instead of
/// being re-implemented per layout.

/// Estimated width of the page-navigation cluster, used by the responsive
/// bar's width budget.
const double kBrowserBarPageNavWidth = 108.0;

/// Fixed width of the total/per-page chip: a stable footprint regardless of how
/// many digits the total has, so the responsive bar's estimate stays honest.
const double kBrowserBarPerPageTextWidth = 64.0;

/// Estimated width of the selected-count badge.
const double kBrowserBarSelectedCountWidth = 80.0;

/// Side of one square tile in the V3 floating grid. Also the natural size of a
/// bare `IconButton` / `PopupMenuButton`, so a grid tile wraps either without
/// rescaling it.
const double kBrowserBarTileSize = 40.0;

/// Gap between grid tiles, and therefore the extra width a DOUBLE-WIDTH tile
/// adds: two squares plus the gap that would separate them.
const double kBrowserBarTileSpacing = 6.0;

/// Side of the go-to-current crosshair, below Material's 24px default.
///
/// `Icons.my_location` is one of the visually heaviest glyphs in the set — a
/// crosshair with a solid centre dot — so at 24px it dominated every bar it
/// appeared in, and inside the V3 tile it read as oversized next to the
/// line-art icons beside it. It is the same control in all three layouts, so the
/// size lives here rather than being repeated (and drifting) per bar.
const double kBrowserBarGoCurrentIconSize = 18.0;

/// The "locate the currently playing row" button, shared by all three layouts.
///
/// Returns null when there is nothing to locate (no callback, or a data source
/// with no current item), so a caller can render it unconditionally and get
/// exactly the gating it had before.
Widget? buildBrowserGoCurrentButton<T>(
  BuildContext context,
  PaginatedBrowserDataSource<T> dataSource,
  VoidCallback? onGoToCurrent,
) {
  if (onGoToCurrent == null || !dataSource.supportsCurrentItem) return null;
  return IconButton(
    tooltip: getLocalizations(context).browser_go_current,
    icon: const Icon(Icons.my_location, size: kBrowserBarGoCurrentIconSize),
    onPressed: onGoToCurrent,
  );
}

/// `‹ page/totalPages ›`. Tapping the counter opens the numeric jump prompt.
///
/// Three parts, exposed separately as well: the V3 grid renders prev / counter /
/// next as three square tiles instead of one cluster, so each part needs to be
/// buildable on its own. V1 and V2 still get the combined row.
Widget buildBrowserPageNav<T>(
  BuildContext context,
  PaginatedBrowserDataSource<T> dataSource,
) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      buildBrowserPagePrevButton(dataSource),
      buildBrowserPageCounter(context, dataSource),
      buildBrowserPageNextButton(dataSource),
    ],
  );
}

/// `‹` — one step back. Disabled on the first page, like every other layout.
Widget buildBrowserPagePrevButton<T>(PaginatedBrowserDataSource<T> dataSource) {
  return IconButton(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    icon: const Icon(Icons.navigate_before),
    onPressed: dataSource.currentPage > 0
        ? () => dataSource.fetchPage(dataSource.currentPage - 1, dataSource.pageSize)
        : null,
  );
}

/// `›` — one step forward. Disabled on the last page, like every other layout.
Widget buildBrowserPageNextButton<T>(PaginatedBrowserDataSource<T> dataSource) {
  return IconButton(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    icon: const Icon(Icons.navigate_next),
    onPressed: dataSource.currentPage < dataSource.totalPages - 1
        ? () => dataSource.fetchPage(dataSource.currentPage + 1, dataSource.pageSize)
        : null,
  );
}

/// The `page/totalPages` readout on its own. Tapping it opens the jump prompt.
Widget buildBrowserPageCounter<T>(
  BuildContext context,
  PaginatedBrowserDataSource<T> dataSource,
) {
  // The toolbar sits outside the browser list's `Material`, so a bare `Text`
  // would inherit the outermost Material's DefaultTextStyle (the app theme)
  // rather than this toolbar's theme. On the dark docked panel that rendered
  // app-dark text on a black background — invisible. Pin the foreground to the
  // toolbar theme explicitly.
  //
  // This readout is deliberately NOT keyboard-focusable (`canRequestFocus`):
  // it is status text, not a control. A focused readout turns Space/Enter
  // (the framework's ActivateIntent) into a tap that opens the jump prompt —
  // the "pressing Space in the list pops a Go dialog" defect. Keyboard users
  // reach the prompt via Ctrl+G instead (see `PlaylistAction.jumpToPage`).
  return InkWell(
    canRequestFocus: false,
    onTap: () => handleBrowserNumericJump(context, dataSource),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: Text(
        '${dataSource.currentPage + 1}/${dataSource.totalPages}',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 13,
          color: Theme.of(context).textTheme.bodyMedium?.color,
        ),
      ),
    ),
  );
}

/// `totalItems/pageSize` chip. Tapping it opens the items-per-page prompt.
///
/// Same focus rule as the page counter: status text, not a tab stop, so
/// Space/Enter can never activate it by accident.
Widget buildBrowserPerPageTotalChip<T>(
  BuildContext context,
  PaginatedBrowserDataSource<T> dataSource,
) {
  return ConstrainedBox(
    constraints:
        BoxConstraints.tightFor(width: kBrowserBarPerPageTextWidth),
    child: InkWell(
      canRequestFocus: false,
      onTap: () => handleBrowserChangePageSize(context, dataSource),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '${dataSource.totalItems}/${dataSource.pageSize}',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: Theme.of(context).colorScheme.primary,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ),
  );
}

/// `✓ selected/total` badge for selection mode.
Widget buildBrowserSelectedCountBadge<T>(
  BuildContext context,
  int selectedCount,
  PaginatedBrowserDataSource<T> dataSource,
) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle_outline, size: 18),
        const SizedBox(width: 4),
        Text(
          '$selectedCount/${dataSource.totalItems}',
          // Same reason as the page counter: pin to the toolbar theme instead
          // of the ambient DefaultTextStyle.
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 13,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
        ),
      ],
    ),
  );
}

/// A square control of the V3 floating grid: one translucent plate carrying one
/// control, sized [kBrowserBarTileSize] on both axes.
///
/// The plate is what makes the grid read as a GRID rather than a row of
/// differently-sized buttons — and it is also what lets the same control appear
/// in three layouts without changing its own widget.
///
/// [child] is laid out with the tile's exact constraints and then scaled DOWN if
/// it does not fit, so a control that wants more room (the text chips, whose
/// width grows with the digit count) degrades to a smaller font inside a square
/// instead of overflowing the plate. Text is not laid out unbounded, which is
/// what would make it wrap to two lines at a narrow tile.
class BrowserBarTile extends StatelessWidget {
  const BrowserBarTile({
    super.key,
    required this.child,
    this.color,
    this.scaleDown = false,
    this.semanticLabel,
  });

  final Widget child;

  /// Plate tint. Null uses the theme's default tile plate.
  final Color? color;

  /// Whether to shrink an oversized [child] to fit rather than clip it. On for
  /// the text chips, whose natural width depends on the numbers in them.
  final bool scaleDown;

  /// Read out by screen readers in place of the (icon-only) [child].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget content = Semantics(
      label: semanticLabel,
      child: child,
    );
    return SizedBox(
      width: kBrowserBarTileSize,
      height: kBrowserBarTileSize,
      child: Material(
        color: color ?? scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(kBrowserBarTileSize / 3),
        clipBehavior: Clip.antiAlias,
        child: Center(
          widthFactor: 1.0,
          heightFactor: 1.0,
          child: scaleDown
              ? FittedBox(fit: BoxFit.scaleDown, child: content)
              : content,
        ),
      ),
    );
  }
}

/// A tile twice as wide as [BrowserBarTile] — the plate the text readouts get
/// when a square would force the digits down to an unreadable size.
class BrowserBarWideTile extends StatelessWidget {
  const BrowserBarWideTile({super.key, required this.child, this.semanticLabel});

  final Widget child;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kBrowserBarTileSize * 2 + kBrowserBarTileSpacing,
      height: kBrowserBarTileSize,
      child: BrowserBarTile(
        // The width is this widget's job; the plate only paints and clips.
        scaleDown: true,
        semanticLabel: semanticLabel,
        child: child,
      ),
    );
  }
}

/// Numeric "jump to page" prompt.
void handleBrowserNumericJump<T>(
  BuildContext context,
  PaginatedBrowserDataSource<T> dataSource,
) {
  final t = getLocalizations(context);
  final int totalPages = dataSource.totalPages;
  final int currentPage = dataSource.currentPage;
  // Nothing to jump between: `totalPages` floors at 1 even for an empty list, so
  // the counter still reads "1/1" and stays tappable. Opening the prompt then
  // yields a dialog whose only legal input is a page that does not exist and
  // whose two shortcuts are both greyed out — no way out but Cancel.
  if (totalPages <= 1 && dataSource.totalItems == 0) return;
  // Phones only: the dialog shell is picked by width, so a phone held sideways
  // otherwise gets a 560px slab around one field. Desktop keeps the plain
  // centered dialog — its width is fine, and a drag bar there is clutter.
  final bool parkable = isMobilePlatform;
  final store = useAppStore();
  showKeyboardTextPrompt(
    context: context,
    title: t.browser_jump_title,
    label: t.browser_jump_label,
    hint: t.browser_jump_hint(totalPages),
    confirmLabel: t.browser_jump_go,
    cancelLabel: t.cancel,
    keyboardType: TextInputType.number,
    inputFormatters: <TextInputFormatter>[
      FilteringTextInputFormatter.digitsOnly,
    ],
    // Typing a page number is optional: both boundaries are one tap away. They
    // grey out when already on that page — same rule as the toolbar's
    // prev/next — so neither can fire a redundant fetch.
    bodyActions: <KeyboardTextPromptAction>[
      KeyboardTextPromptAction(
        label: t.browser_jump_first_page,
        icon: Icons.first_page,
        enabled: currentPage > 0,
        onSelected: () => dataSource.fetchPage(0, dataSource.pageSize),
      ),
      KeyboardTextPromptAction(
        label: t.browser_jump_last_page,
        icon: Icons.last_page,
        enabled: currentPage < totalPages - 1,
        onSelected: () =>
            dataSource.fetchPage(totalPages - 1, dataSource.pageSize),
      ),
    ],
    geometry: parkable ? store.state.keyboardFormGeometry : null,
    // Read `state` fresh in each callback: the two gestures own one axis each,
    // and a resize may land after a move within the same session.
    onPositionChanged: parkable
        ? (Offset fraction) => store.updateKeyboardFormGeometry(
              store.state.keyboardFormGeometry.withOffset(fraction),
            )
        : null,
    onWidthChanged: parkable
        ? (double? fraction) => store.updateKeyboardFormGeometry(
              store.state.keyboardFormGeometry.withWidthFraction(fraction),
            )
        : null,
    validate: (value) {
      final target = int.tryParse(value);
      if (target == null || target < 1 || target > totalPages) {
        return t.browser_jump_invalid;
      }
      return null;
    },
  ).then((value) {
    if (value == null) return;
    final target = int.tryParse(value);
    if (target == null) return;
    dataSource.fetchPage(target - 1, dataSource.pageSize);
  });
}

/// "Items per page" prompt.
void handleBrowserChangePageSize<T>(
  BuildContext context,
  PaginatedBrowserDataSource<T> dataSource,
) {
  final t = getLocalizations(context);
  showKeyboardTextPrompt(
    context: context,
    title: t.browser_size_title,
    label: t.browser_size_label,
    hint: t.browser_size_input_hint,
    helper: t.browser_size_helper(
      t.browser_size_total(dataSource.totalItems),
      t.browser_size_hint(kMaxBrowserPageSize),
    ),
    initialValue: '${dataSource.pageSize}',
    confirmLabel: t.browser_size_apply,
    cancelLabel: t.cancel,
    keyboardType: TextInputType.number,
    inputFormatters: <TextInputFormatter>[
      FilteringTextInputFormatter.digitsOnly,
    ],
    validate: (value) {
      final target = int.tryParse(value);
      if (target == null || target < 1 || target > kMaxBrowserPageSize) {
        return t.browser_size_invalid(kMaxBrowserPageSize);
      }
      return null;
    },
  ).then((value) {
    if (value == null) return;
    final target = int.tryParse(value);
    if (target == null) return;
    dataSource.changePageSize(target);
  });
}
