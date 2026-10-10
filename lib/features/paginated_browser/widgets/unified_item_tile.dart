import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/paginated_browser_controller.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/a11y_tooltip.dart';

/// Alpha of the left cursor bar while the list does NOT hold keyboard focus —
/// visible enough to remember where the cursor is, weak enough to not claim
/// `↑/↓` ownership the list has handed to the picture.
const double kCursorAccentInactiveAlpha = 0.35;

class UnifiedItemTile<T> extends HookWidget {
  final T item;
  final List<T> pageItems;
  final PaginatedBrowserController<T> controller;
  final PaginatedBrowserDataSource<T> dataSource;

  /// True when this row currently holds the playlist keyboard cursor. Only the
  /// opt-in list-keyboard surfaces set it; everywhere else it stays false.
  final bool keyboardCursor;

  /// Whether that cursor is LIVE, i.e. the list currently holds keyboard
  /// focus. False dims the accent (the row keeps its cursor) so the highlight
  /// never claims `↑/↓` ownership the list has already handed to the picture.
  final bool keyboardCursorActive;

  /// Optional override for the disclosure-chevron toggle. The host page wires
  /// it to also restore the row's on-screen position after the in-flow height
  /// change (the `ScrollablePositionedList` centered anchor would shift it).
  /// Falls back to a plain [PaginatedBrowserDataSource.toggleItemExpanded].
  final VoidCallback? onToggleExpanded;

  const UnifiedItemTile({
    super.key,
    required this.item,
    required this.pageItems,
    required this.controller,
    required this.dataSource,
    this.keyboardCursor = false,
    this.keyboardCursorActive = true,
    this.onToggleExpanded,
  });

  @override
  Widget build(BuildContext context) {
    // Selection state is scoped: only the leading checkbox and the row tint
    // listen to the controller, so a selection change repaints the affected
    // row instead of rebuilding every mounted tile.
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildTile(context),
    );
  }

  Widget _buildTile(BuildContext context) {
    final isSelected = controller.isSelected(item, dataSource);
    final hasSelection = controller.isSelectionMode;
    final isCurrent = dataSource.isCurrentItem(context, item);
    // D28/D38: `available: false` placeholders (missing explicit items / empty
    // sources) render greyed and un-tappable.
    final unavailable = dataSource.isItemUnavailable(context, item);
    // Non-selectable rows (e.g. VM merged groups) grey out and lose their
    // checkbox in selection mode; they remain tappable to play.
    final selectable = dataSource.isItemSelectable(item);
    final nonSelectableInMode = hasSelection && !selectable;
    final greyed = unavailable || nonSelectableInMode;

    // Leading: checkbox in selection mode, or item icon
    final leadingBase = hasSelection
        ? (selectable
            ? SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: isSelected,
                  onChanged: (_) => _handleInteraction(context),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              )
            : Opacity(
                opacity: 0.45,
                child: dataSource.buildItemLeading(context, item) ??
                    const SizedBox.shrink(),
              ))
        : dataSource.buildItemLeading(context, item);

    // Inline expansion (opt-in): the disclosure chevron sits in the trailing,
    // immediately left of the "more" button, and only outside selection mode so
    // bulk selection stays clutter-free. Tapping the row still plays the item.
    final expandable = dataSource.isItemExpandable(item);
    final expanded = expandable && dataSource.isItemExpanded(item);
    final showChevron = expandable && !hasSelection;

    // Title: prefer buildItemTitleWidget (e.g. match highlighting), then
    // buildItemTitle, fallback to buildTileContent (v10-D1).
    final titleWidget = dataSource.buildItemTitleWidget(context, item);
    final titleText =
        titleWidget == null ? dataSource.buildItemTitle(item) : null;
    final renderedTitle = titleWidget ??
        (titleText != null
            ? Text(
                titleText,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: isCurrent
                    ? TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
              )
            : const SizedBox.shrink());

    // Subtitle
    final subtitleWidget = dataSource.buildItemSubtitle(context, item);

    // Trailing: disclosure chevron (when expandable) immediately left of the
    // more-actions popup (non-selection mode only).
    Widget? trailingWidget;
    if (!hasSelection) {
      final trailingActions = dataSource.getItemTrailingActions(context, item);
      Widget? moreButton;
      if (trailingActions.isNotEmpty) {
        moreButton = GestureDetector(
          behavior: HitTestBehavior.opaque,
          child: PopupMenuButton<int>(
            icon: const Icon(Icons.more_vert),
            // Windows drops the payload (AXTree graft race, see rowTooltip);
            // other platforms keep the localized "Show menu" label.
            tooltip: rowTooltip(null),
            onSelected: (index) {
              trailingActions[index].onPressed(context, item);
            },
            itemBuilder: (context) => _actionItems(trailingActions),
          ),
        );
      }
      final trailingChildren = <Widget>[
        if (showChevron)
          VmRowExpandChevron(
            expanded: expanded,
            onTap: onToggleExpanded ??
                () => dataSource.toggleItemExpanded(item),
          ),
        if (moreButton != null) moreButton,
      ];
      if (trailingChildren.isNotEmpty) {
        trailingWidget = Row(
          mainAxisSize: MainAxisSize.min,
          children: trailingChildren,
        );
      }
    }

    // See `rowTooltip` — the Windows-only hover-tooltip suppression keeps
    // the row popup's OverlayPortal out of the root overlay (#182444).
    final tile = ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        visualDensity: const VisualDensity(horizontal: 0, vertical: -4),
        leading: greyed
            ? Opacity(opacity: 0.45, child: leadingBase)
            : leadingBase,
        title: greyed
            ? Opacity(
                opacity: 0.45,
                child: renderedTitle,
              )
            : renderedTitle,
        subtitle: subtitleWidget,
        trailing: trailingWidget,
        tileColor: greyed
            ? Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.4)
            : isCurrent
                ? Theme.of(context).hoverColor
                : isSelected
                    ? Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.08)
                    : null,
        onTap: () => _handleTap(context),
        onLongPress: () {
          // O8: surfaces that opt out of selection (supportsSelection == false)
          // never enter selection mode, even though the controller supports it.
          if (!dataSource.supportsSelection) return;
          // Non-selectable rows cannot anchor a selection; other rows still can.
          if (!selectable) return;
          if (!hasSelection) {
            controller.enterSelectionMode(item, dataSource);
          } else {
            controller.processRangeXorSelection(item, pageItems, dataSource);
          }
        },
    );

    // In-flow expansion: children live in the list, so they scroll with it and
    // never cover the rows after them. An overlay dropdown was rejected because
    // on phones it blocked scrolling to subsequent items.
    final content = !expandable
        ? tile
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              tile,
              if (expanded && !hasSelection)
                dataSource.buildItemExpandedContent(context, item) ??
                    const SizedBox.shrink(),
            ],
          );
    // Desktop right-click context menu, opted in per data source. Reuses the
    // SAME trailing actions as the "more" button, so the two can never drift.
    // Suppressed in selection mode, mirroring the hidden trailing button.
    final withContextMenu =
        !isMobilePlatform && dataSource.supportsRowContextMenu && !hasSelection
            ? GestureDetector(
                behavior: HitTestBehavior.deferToChild,
                onSecondaryTapDown: (details) =>
                    _showRowContextMenu(context, details.globalPosition),
                child: content,
              )
            : content;
    return keyboardCursor
        ? _withCursorAccent(context, withContextMenu, active: keyboardCursorActive)
        : withContextMenu;
  }

  /// Renders [GenericItemAction]s as popup entries. Shared by the trailing
  /// "more" button and the right-click context menu so both stay identical.
  List<PopupMenuItem<int>> _actionItems(List<GenericItemAction<T>> actions) => [
        for (int i = 0; i < actions.length; i++)
          PopupMenuItem<int>(
            value: i,
            // Offline-grey: disabled entry, no tap reaction.
            enabled: actions[i].enabled,
            child: Row(
              children: [
                if (actions[i].icon != null) ...[
                  actions[i].icon!,
                  const SizedBox(width: 8),
                ],
                Text(actions[i].label),
              ],
            ),
          ),
      ];

  /// Opens the row's trailing actions at the right-click position.
  Future<void> _showRowContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final actions = dataSource.getItemTrailingActions(context, item);
    if (actions.isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & overlay.size,
      ),
      items: _actionItems(actions),
    );
    if (selected == null || !context.mounted) return;
    actions[selected].onPressed(context, item);
  }

  Widget _withCursorAccent(BuildContext context, Widget child,
      {required bool active}) {
    final Color primary = Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            // Unfocused list → dimmed bar: the accent must not outlive the
            // focus that made it meaningful (the row keeps its cursor so
            // returning to the list resumes at the same item).
            color: active
                ? primary
                : primary.withValues(alpha: kCursorAccentInactiveAlpha),
            width: 3,
          ),
        ),
      ),
      child: child,
    );
  }

  void _handleTap(BuildContext context) {
    final inSelection = controller.isSelectionMode;
    if (inSelection) {
      if (!dataSource.isItemSelectable(item)) return;
      controller.toggleSelection(item, dataSource);
      return;
    }
    final handled = dataSource.handleItemTap(context, item);
    if (!handled) {
      _showInfoDialog(context);
    }
  }

  void _showInfoDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => dataSource.buildTileInfoDialog(context, item),
    );
  }

  void _handleInteraction(BuildContext context) {
    final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
    if (isShiftPressed) {
      controller.processRangeXorSelection(item, pageItems, dataSource);
    } else {
      controller.toggleSelection(item, dataSource);
    }
  }
}

/// Disclosure chevron for an expandable row (e.g. a virtual-merged group).
///
/// State deliberately lives in the data source, so this widget is storage-free
/// and survives row recycling. 40x40 keeps the mobile minimum touch target.
class VmRowExpandChevron extends StatelessWidget {
  const VmRowExpandChevron({
    super.key,
    required this.expanded,
    required this.onTap,
  });

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    return SizedBox(
      width: 40,
      height: 40,
      child: a11yTooltip(
        context: context,
        // Windows drops row-level hover tooltips (AXTree graft race); other
        // platforms announce the localized action.
        message: rowTooltip(
                  expanded ? t.vm_children_collapse : t.vm_children_expand,
                ) ??
                '',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            child: Icon(
              Icons.expand_more,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
