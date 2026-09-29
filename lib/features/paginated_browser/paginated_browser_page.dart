import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/paginated_browser/data_source/playlist_key_target.dart';
import 'package:iris/features/paginated_browser/models/browser_toolbar_layout.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/models/tooltip_direction.dart';
import 'package:iris/features/paginated_browser/paginated_browser_controller.dart';
import 'package:iris/features/paginated_browser/widgets/compact_single_row_bar.dart';
import 'package:iris/features/paginated_browser/widgets/dynamic_responsive_bar.dart';
import 'package:iris/features/paginated_browser/widgets/floating_grid_bar.dart';
import 'package:iris/features/paginated_browser/widgets/list_keyboard_controller.dart';
import 'package:iris/features/paginated_browser/widgets/list_keyboard_scope.dart';
import 'package:iris/features/paginated_browser/widgets/unified_item_tile.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/playlist_key_map.dart';
import 'package:iris/features/windows/desktop_keyboard/model/playlist_action.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/enums/storage_list_error.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Localized explanation for a failed load, mapped from the data source's
/// classification. Unknown kinds fall back to a generic message.
String _listErrorMessage(StorageListErrorKind? kind, AppLocalizations t) =>
    switch (kind) {
      StorageListErrorKind.unreachable => t.browser_error_unreachable,
      StorageListErrorKind.unauthorized => t.browser_error_unauthorized,
      StorageListErrorKind.timeout => t.browser_error_timeout,
      StorageListErrorKind.httpBlocked => t.browser_error_http_blocked,
      StorageListErrorKind.permissionDenied => t.browser_error_permission_denied,
      _ => t.browser_error_unknown,
    };

class PaginatedBrowserPage<T> extends HookWidget {
  final PaginatedBrowserDataSource<T> dataSource;
  final PaginatedBrowserController<T>? controller;
  final VoidCallback? onClose;
  final VoidCallback? onHomePage;
  final bool showHomePage;
  final bool showBackButton;

  /// Insertion index of the "Go to current" button within the custom page
  /// actions; see [DynamicResponsiveBar.goToCurrentInsertIndex].
  final int? goToCurrentInsertIndex;

  /// Optional widget that replaces the breadcrumb/search-bar slot entirely
  /// (rendered between the content area and the bottom bar). The media search
  /// page injects its inline search bar here; it is never combined with the
  /// breadcrumbs.
  final Widget? headerOverride;

  /// Optional widget rendered in place of the hardcoded `'No items found.'`
  /// empty state (three states: "Type to search" / "No matches" / default).
  final Widget? emptyStateOverride;

  /// When true (only the media search page), the bottom section reacts to the
  /// keyboard inset (v7-D1, 方案 Y): with the IME open only the search-bar slot
  /// rises above the keyboard and the bottom toolbar is removed from the layout
  /// (its space is released to the content); with the IME closed (or on
  /// non-keyboard-aware browsers) the layout is unchanged.
  final bool keyboardAware;

  /// When true the list implements the PotPlayer playlist keyboard model: rows
  /// stop taking keyboard focus, a single list cursor is navigated with
  /// `↑/↓/Home/End`, and `PL >` keys are dispatched to the data source (see
  /// [PlaylistKeyTarget]). Opt-in and metadata-gated by the caller; the default
  /// (false) keeps every legacy/other browser byte-identical.
  final bool listKeyboard;

  /// Bottom-toolbar arrangement. [BrowserToolbarLayout.responsive] (the
  /// default) keeps every browser on the shared responsive bar;
  /// [BrowserToolbarLayout.compactSingleLine] swaps in [CompactSingleRowBar],
  /// which never reflows (the scenario play queue's V2 layout);
  /// [BrowserToolbarLayout.floatingGrid] drops the bottom section entirely and
  /// overlays [FloatingGridBar] on the list (its V3 layout).
  final BrowserToolbarLayout toolbarLayout;

  /// V3 only: the floating bar's remembered spot, as a fraction (0..1) of the
  /// available travel. Null centres it. The generic page deliberately does not
  /// own this preference — the caller reads and writes it, exactly as it owns
  /// [overflowActions] and [showBreadcrumb].
  final Offset? floatingBarOffset;

  /// V3 only: called ONCE per drag with the fraction the bar came to rest at.
  /// Null disables dragging; the bar still renders, pinned to centre.
  final ValueChanged<Offset>? onFloatingBarMoved;

  /// Page-level chrome that only the compact bar can host, because only it has
  /// an overflow button (e.g. the queue's breadcrumb-visibility checkbox). The
  /// responsive bar has nowhere to put these and ignores them.
  final List<PageAction> overflowActions;

  /// Whether the breadcrumb row renders. True by default, so every existing
  /// browser is unaffected; the scenario queue drives it from a user
  /// preference, which BOTH of its layouts honour.
  ///
  /// Only gates the breadcrumb itself — an in-page search's query banner keeps
  /// its slot, so hiding crumbs can never hide the search state.
  final bool showBreadcrumb;

  const PaginatedBrowserPage({
    super.key,
    required this.dataSource,
    this.controller,
    this.onClose,
    this.onHomePage,
    this.showHomePage = true,
    this.showBackButton = true,
    this.goToCurrentInsertIndex,
    this.headerOverride,
    this.emptyStateOverride,
    this.keyboardAware = false,
    this.listKeyboard = false,
    this.toolbarLayout = BrowserToolbarLayout.responsive,
    this.overflowActions = const [],
    this.showBreadcrumb = true,
    this.floatingBarOffset,
    this.onFloatingBarMoved,
  });

  @override
  Widget build(BuildContext context) {
    // v15-D5 hardening: memoize the fallback controller so a page that forgets
    // to pass one still keeps a stable instance across rebuilds — a fresh
    // controller per build would wipe the selection state the moment
    // `enterSelectionMode` notifies (the search page fix, see media_search_page).
    final PaginatedBrowserController<T> activeController =
        controller ?? useMemoized(() => PaginatedBrowserController(), const []);

    final itemScrollController = useMemoized(() => ItemScrollController(), []);
    final scrollOffsetController =
        useMemoized(() => ScrollOffsetController(), []);
    final itemPositionsListener =
        useMemoized(() => ItemPositionsListener.create(), []);
    final scrollOffsetListener =
        useMemoized(() => ScrollOffsetListener.create(), []);

    // Playlist keyboard layer (opt-in; metadata-gated by the caller). The list
    // owns a single focus node; cursor/type-ahead state lives in the controller.
    final listFocusNode = useMemoized(
      () => FocusNode(debugLabel: 'paginated-list'),
      const [],
    );
    final listKeyboardCtl =
        useMemoized(() => ListKeyboardController(), const []);
    useEffect(() {
      return () {
        listFocusNode.dispose();
        listKeyboardCtl.dispose();
      };
    }, const []);

    final autoLocated = useRef<bool>(false);

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (dataSource.isLoading || !dataSource.supportsCurrentItem) return;
        if (autoLocated.value) return;
        autoLocated.value = true;
        final index = await dataSource.resolveCurrentItemIndex();
        if (index == null || !context.mounted) return;
        final targetPage =
            dataSource.pageForIndex(index).clamp(0, dataSource.totalPages - 1);
        if (targetPage != dataSource.currentPage) {
          await dataSource.fetchPage(targetPage, dataSource.pageSize);
        }
        if (!context.mounted) return;
        await _centerCurrent(itemScrollController, dataSource, index);
      });
      return;
    }, [
      dataSource,
      dataSource.isLoading,
      dataSource.items,
      dataSource.currentPage
    ]);

    final isSearchActive = activeController.isSearchActive;

    final tooltipDirection = dataSource.tooltipDirection;

    return TooltipTheme(
      data: TooltipThemeData(
          preferBelow: tooltipDirection == TooltipDirection.below),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) return;
          if (activeController.isSelectionMode) {
            activeController.clearSelection();
          } else if (isSearchActive) {
            activeController.cancelSearch();
          } else {
            final handled = await dataSource.handleNavigationBack();
            if (!handled && context.mounted) {
              if (onHomePage != null) {
                onHomePage!();
              } else {
                Navigator.of(context).pop();
              }
            }
          }
        },
        child: _buildShell(
          context,
          activeController,
          itemScrollController,
          scrollOffsetController,
          itemPositionsListener,
          scrollOffsetListener,
          listFocusNode,
          listKeyboardCtl,
        ),
      ),
    );
  }

  /// The page shell, in one of two shapes.
  ///
  /// The default (V1/V2) is a Column: content on top, bottom section beneath.
  /// [BrowserToolbarLayout.floatingGrid] has no bottom section at all, so the
  /// content is the whole page and the bar is a sibling INSIDE the content's box
  /// — the list keeps its full height and the bar floats over it. The breadcrumb
  /// moves to the top in that layout, since there is no bottom slot left to hold
  /// it; hiding it is the default, so the common case shows nothing either way.
  Widget _buildShell(
    BuildContext context,
    PaginatedBrowserController<T> controller,
    ItemScrollController itemScrollController,
    ScrollOffsetController scrollOffsetController,
    ItemPositionsListener itemPositionsListener,
    ScrollOffsetListener scrollOffsetListener,
    FocusNode listFocusNode,
    ListKeyboardController listKeyboardCtl,
  ) {
    final Widget content = _wrapKeyboardShell(
      context,
      _buildBodyInScope(
        context,
        controller,
        itemScrollController,
        scrollOffsetController,
        itemPositionsListener,
        scrollOffsetListener,
        listKeyboardCtl,
      ),
      listFocusNode,
      listKeyboard,
      controller,
      itemScrollController,
      listKeyboardCtl,
    );

    if (toolbarLayout != BrowserToolbarLayout.floatingGrid) {
      return Column(
        children: [
          Expanded(child: content),
          // Bottom section: breadcrumb/search-bar slot + divider + toolbar.
          // keyboardAware → reacts to the IME inset (search bar rises,
          // toolbar hidden while typing) without rebuilding the content.
          _buildBottomBarInScope(context, controller, itemScrollController),
        ],
      );
    }

    return Column(
      children: [
        _buildFloatingHeaderInScope(context, controller),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                content,
                // The bar shrink-wraps its tiles and positions ITSELF from the
                // remembered fraction, so it is a `Positioned(left: 0, top: 0)`
                // child: the host Stack sizes itself from the list, and the bar
                // translates away from the origin. Wrapping it in
                // `Positioned.fill`/`Align` instead made the bar fill the whole
                // host, leaving it no room to move at all.
                Positioned(
                  left: 0,
                  top: 0,
                  child: FloatingGridBar<T>(
                    controller: controller,
                    dataSource: dataSource,
                    onClose: onClose,
                    onGoToCurrent: dataSource.supportsCurrentItem
                        ? () => _goToCurrent(itemScrollController, dataSource)
                        : null,
                    overflowActions: overflowActions,
                    offset: floatingBarOffset,
                    onMoved: onFloatingBarMoved,
                    // The list area's width, so the grid re-chunks instead of
                    // overflowing a narrow host. The bar is a `Positioned` child
                    // and cannot measure this itself.
                    maxWidth: constraints.maxWidth,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// V3's breadcrumb slot: the same [ListenableBuilder] scope the bottom section
  /// uses, minus the divider and the toolbar.
  ///
  /// It deliberately does NOT honour [keyboardAware]: the only V3 page is the
  /// scenario queue, which hosts no text field, and an IME inset has nothing to
  /// lift here.
  Widget _buildFloatingHeaderInScope(
    BuildContext context,
    PaginatedBrowserController<T> controller,
  ) {
    return ListenableBuilder(
      listenable: dataSource,
      builder: (context, _) => _buildBreadcrumbOrSearchBar(context, controller),
    );
  }

  Future<void> _goToCurrent(
    ItemScrollController itemScrollController,
    PaginatedBrowserDataSource<T> dataSource,
  ) async {
    final index = await dataSource.resolveCurrentItemIndex();
    if (index == null) return;
    final targetPage =
        dataSource.pageForIndex(index).clamp(0, dataSource.totalPages - 1);
    if (targetPage != dataSource.currentPage) {
      await dataSource.fetchPage(targetPage, dataSource.pageSize);
    }
    await _centerCurrent(itemScrollController, dataSource, index);
  }

  Future<void> _centerCurrent(
    ItemScrollController itemScrollController,
    PaginatedBrowserDataSource<T> dataSource,
    int index,
  ) async {
    final row = dataSource.rowInCurrentPage(index);
    if (row < 0 || row >= dataSource.items.length) return;
    if (!itemScrollController.isAttached) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (itemScrollController.isAttached) {
        itemScrollController.jumpTo(index: row, alignment: 0.5);
      }
    });
  }

  /// Toggles an expandable row and restores its on-screen position.
  ///
  /// The children render in-flow, so growing the row changes the list layout;
  /// `ScrollablePositionedList` keeps its centered anchor fixed and would
  /// otherwise shift the tapped row up by the added height
  /// (google/flutter.widgets#443). Re-jumping with the row's previous leading
  /// edge (which is exactly [ItemScrollController.jumpTo]'s `alignment` scale)
  /// pins the tapped row while the children unfold below it.
  void _toggleExpandWithAnchor(
    ItemScrollController itemScrollController,
    ItemPositionsListener itemPositionsListener,
    PaginatedBrowserDataSource<T> dataSource,
    int row,
    T item,
  ) {
    double? leadingEdge;
    for (final position in itemPositionsListener.itemPositions.value) {
      if (position.index == row) {
        leadingEdge = position.itemLeadingEdge;
        break;
      }
    }
    dataSource.toggleItemExpanded(item);
    if (leadingEdge == null) return;
    final alignment = leadingEdge;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (itemScrollController.isAttached) {
        itemScrollController.jumpTo(index: row, alignment: alignment);
      }
    });
  }

  Widget _buildBreadcrumbOrSearchBar(
    BuildContext context,
    PaginatedBrowserController<T> controller,
  ) {
    final override = headerOverride;
    if (override != null) {
      return override;
    }
    if (controller.isSearchActive) {
      return Container(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Row(
          children: [
            Icon(
              Icons.search,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                getLocalizations(context)
                    .browser_search_query(controller.activeSearchQuery),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    final breadcrumbs = dataSource.currentBreadcrumbs;
    if (!showBreadcrumb || breadcrumbs == null || breadcrumbs.isEmpty) {
      return const SizedBox.shrink();
    }

    final isRtl = dataSource.isRightToLeftBreadcrumbs;
    final items = isRtl ? breadcrumbs.reversed.toList() : breadcrumbs;
    final icon =
        isRtl ? Icons.chevron_left_rounded : Icons.chevron_right_rounded;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Align(
        alignment: isRtl ? Alignment.centerRight : Alignment.centerLeft,
        child: BreadCrumb.builder(
          itemCount: items.length,
          overflow: Platform.isAndroid || Platform.isIOS
              ? ScrollableOverflow(reverse: isRtl)
              : const WrapOverflow(),
          builder: (index) {
            final realIndex = isRtl ? breadcrumbs.length - index - 1 : index;
            final isLast = index == items.length - 1;

            return BreadCrumbItem(
              content: TextButton(
                onPressed: isLast
                    ? null
                    : () async {
                        await dataSource.navigateToCrumb(realIndex);
                      },
                child: Text(
                  _crumbLabel(items[index], getLocalizations(context)),
                  style: TextStyle(
                    fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
                    color: _crumbColor(
                            items[index], Theme.of(context).colorScheme) ??
                        (isLast ? null : Theme.of(context).colorScheme.primary),
                  ),
                ),
              ),
            );
          },
          divider: Icon(
            icon,
            color:
                Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(222),
          ),
        ),
      ),
    );
  }

  /// Rebuilds the content only when [dataSource] notifies, keeping selection
  /// and cursor changes out of this subtree.
  Widget _buildBodyInScope(
    BuildContext context,
    PaginatedBrowserController<T> controller,
    ItemScrollController itemScrollController,
    ScrollOffsetController scrollOffsetController,
    ItemPositionsListener itemPositionsListener,
    ScrollOffsetListener scrollOffsetListener,
    ListKeyboardController listKeyboardCtl,
  ) {
    return ListenableBuilder(
      listenable: dataSource,
      builder: (context, _) => _buildBody(
        context,
        controller,
        itemScrollController,
        scrollOffsetController,
        itemPositionsListener,
        scrollOffsetListener,
        listKeyboardCtl: listKeyboard ? listKeyboardCtl : null,
      ),
    );
  }

  /// Rebuilds the bottom section only when [dataSource] notifies (page change,
  /// loading, error, page-size change), keeping the content list out of this
  /// subtree.
  ///
  /// The toolbar and the breadcrumb read [dataSource] directly, so without this
  /// scope a `fetchPage` updated the list but left the page counter, the
  /// prev/next enablement, the per-page chip and the breadcrumbs stale — the
  /// page navigation looked dead. The selection controller still drives the
  /// bar's own rebuild ([DynamicResponsiveBar] listens to it), so selection and
  /// cursor changes stay out of both this scope and the content scope.
  Widget _buildBottomBarInScope(
    BuildContext context,
    PaginatedBrowserController<T> controller,
    ItemScrollController itemScrollController,
  ) {
    return ListenableBuilder(
      listenable: dataSource,
      builder: (context, _) => _BottomBarSection<T>(
        header: _buildBreadcrumbOrSearchBar(context, controller),
        keyboardAware: keyboardAware,
        divider: Divider(
          height: 0,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
        ),
        toolbar: _buildToolbar(context, controller, itemScrollController),
      ),
    );
  }

  /// Picks the bottom toolbar for [toolbarLayout]. Both variants receive the
  /// same data source and close/locate callbacks, so the layout choice cannot
  /// change what a control does.
  Widget _buildToolbar(
    BuildContext context,
    PaginatedBrowserController<T> controller,
    ItemScrollController itemScrollController,
  ) {
    final VoidCallback? onGoToCurrent = dataSource.supportsCurrentItem
        ? () => _goToCurrent(itemScrollController, dataSource)
        : null;

    if (toolbarLayout == BrowserToolbarLayout.compactSingleLine) {
      return CompactSingleRowBar<T>(
        controller: controller,
        dataSource: dataSource,
        onClose: onClose,
        onGoToCurrent: onGoToCurrent,
        overflowActions: overflowActions,
      );
    }

    return DynamicResponsiveBar<T>(
      controller: controller,
      dataSource: dataSource,
      onClose: onClose,
      onHomePage: onHomePage,
      showHomePage: showHomePage,
      showBackButton: showBackButton,
      goToCurrentInsertIndex: goToCurrentInsertIndex ?? 0,
      onGoToCurrent: onGoToCurrent,
    );
  }

  /// Wraps the content in the opt-in playlist keyboard shell.
  ///
  /// The [ListKeyboardScope] only owns keys when the page opted in; the guide
  /// layer must stay present for every caller so global player shortcuts behave
  /// exactly as before. The focus node itself is always mounted (it was
  /// hook-memoized before), so a non-opt-in page simply never focuses it.
  Widget _wrapKeyboardShell(
    BuildContext context,
    Widget child,
    FocusNode listFocusNode,
    bool listKeyboard,
    PaginatedBrowserController<T> controller,
    ItemScrollController itemScrollController,
    ListKeyboardController listKeyboardCtl,
  ) {
    if (!listKeyboard) return child;
    return ListKeyboardScope(
      child: Focus(
        focusNode: listFocusNode,
        // Track focus → the cursor accent dims when the keys leave the list
        // (ownership is decided by the primary focus, see ListKeyboardScope).
        onFocusChange: (hasFocus) =>
            listKeyboardCtl.listActive.value = hasFocus,
        onKeyEvent: (node, event) => _handleListKey(
          context,
          controller,
          itemScrollController,
          listKeyboardCtl,
          event,
        ),
        child: Listener(
          onPointerDown: (_) => listFocusNode.requestFocus(),
          child: ExcludeFocus(child: child),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    PaginatedBrowserController<T> controller,
    ItemScrollController itemScrollController,
    ScrollOffsetController scrollOffsetController,
    ItemPositionsListener itemPositionsListener,
    ScrollOffsetListener scrollOffsetListener, {
    ListKeyboardController? listKeyboardCtl,
  }) {
    if (dataSource.isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (dataSource.isError) {
      final t = getLocalizations(context);
      final detail = dataSource.listErrorDetail;
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                t.browser_load_failed,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              // WHY it failed — otherwise a failure is indistinguishable from
              // an empty directory.
              Text(
                _listErrorMessage(dataSource.listErrorKind, t),
                style: const TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              if (detail != null && detail.isNotEmpty) ...[
                const SizedBox(height: 12),
                SelectableText(
                  t.browser_error_detail(detail),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => dataSource.retryLoad(),
                child: Text(t.browser_retry),
              ),
            ],
          ),
        ),
      );
    }

    final items = dataSource.items;
    if (items.isEmpty) {
      final override = emptyStateOverride;
      if (override != null) {
        return override;
      }
      return Center(
        child: Text(
          getLocalizations(context).browser_empty,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }

    final list = Card(
      color: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: ScrollablePositionedList.builder(
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          // The cursor accent is the only cursor-driven visual, so it is
          // isolated into a leaf builder: moving the cursor repaints one row
          // instead of rebuilding the page shell and every visible tile.
          // NOTE: the listener must be mounted even while the cursor is still
          // null — otherwise the first ↑/↓ would set a value nothing is
          // listening to and the accent would only appear after an unrelated
          // rebuild. `listKeyboardCtl` is null exactly when the page opted out.
          final ctl = listKeyboardCtl;
          if (ctl == null) {
            return UnifiedItemTile<T>(
              item: item,
              pageItems: items,
              controller: controller,
              dataSource: dataSource,
              onToggleExpanded: () => _toggleExpandWithAnchor(
                itemScrollController,
                itemPositionsListener,
                dataSource,
                index,
                item,
              ),
            );
          }
          return ValueListenableBuilder<int?>(
            valueListenable: ctl.cursor,
            builder: (context, cursorIndex, _) => ValueListenableBuilder<bool>(
              // Focus-driven half of the accent: it dims the moment the keys
              // leave the list, so the highlight never claims an ownership the
              // list no longer has (the cursor INDEX is preserved, only the
              // emphasis changes).
              valueListenable: ctl.listActive,
              builder: (context, listActive, _) => UnifiedItemTile<T>(
                item: item,
                pageItems: items,
                controller: controller,
                dataSource: dataSource,
                keyboardCursor: cursorIndex == index,
                keyboardCursorActive: listActive,
                onToggleExpanded: () => _toggleExpandWithAnchor(
                  itemScrollController,
                  itemPositionsListener,
                  dataSource,
                  index,
                  item,
                ),
              ),
            ),
          );
        },
        itemScrollController: itemScrollController,
        scrollOffsetController: scrollOffsetController,
        itemPositionsListener: itemPositionsListener,
        scrollOffsetListener: scrollOffsetListener,
      ),
    );

    return list;
  }

  /// Dispatches a key event for the focused playlist list.
  ///
  /// Cursor navigation and selection are owned by the page; every other
  /// [PlaylistAction] is delegated to the data source (when it implements
  /// [PlaylistKeyTarget]). Unmapped keys (Space/PgUp/PgDn/Enter/←/→) are left
  /// `ignored` so the global player handler keeps them.
  KeyEventResult _handleListKey(
    BuildContext context,
    PaginatedBrowserController<T> controller,
    ItemScrollController itemScrollController,
    ListKeyboardController keyboardCtl,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final items = dataSource.items;
    final action = resolvePlaylistAction(event);
    if (action != null) {
      unawaited(_runPlaylistAction(
        context,
        controller,
        itemScrollController,
        keyboardCtl,
        action,
        items,
      ));
      return KeyEventResult.handled;
    }
    if (isPlaylistTypeAheadKey(event)) {
      final names = <String>[
        for (final item in items) dataSource.buildItemTitle(item) ?? '',
      ];
      final index = keyboardCtl.typeAhead(event.logicalKey.keyLabel, names);
      if (index != null)
        _moveCursorTo(itemScrollController, keyboardCtl, index);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _runPlaylistAction(
    BuildContext context,
    PaginatedBrowserController<T> controller,
    ItemScrollController itemScrollController,
    ListKeyboardController keyboardCtl,
    PlaylistAction action,
    List<T> items,
  ) async {
    switch (action) {
      case PlaylistAction.cursorUp:
        keyboardCtl.moveCursor(-1, items.length);
        _scrollCursorIntoView(itemScrollController, keyboardCtl);
        return;
      case PlaylistAction.cursorDown:
        keyboardCtl.moveCursor(1, items.length);
        _scrollCursorIntoView(itemScrollController, keyboardCtl);
        return;
      case PlaylistAction.cursorFirst:
        keyboardCtl.setFirst(items.length);
        _scrollCursorIntoView(itemScrollController, keyboardCtl);
        return;
      case PlaylistAction.cursorLast:
        keyboardCtl.setLast(items.length);
        _scrollCursorIntoView(itemScrollController, keyboardCtl);
        return;
      case PlaylistAction.selectAll:
        controller.selectAllOnPage(items, dataSource);
        return;
      case PlaylistAction.invertSelection:
        controller.invertSelectionOnPage(items, dataSource);
        return;
      default:
        break;
    }
    final target = dataSource is PlaylistKeyTarget
        ? dataSource as PlaylistKeyTarget
        : null;
    // No playlist-capable data source: consume the bound key as a no-op rather
    // than let a conflicting global shortcut fire.
    if (target == null) return;
    await target.handlePlaylistAction(
      context,
      action,
      cursorIndex: keyboardCtl.cursor.value,
      selectedIds: controller.selectedIds,
    );
  }

  void _moveCursorTo(
    ItemScrollController itemScrollController,
    ListKeyboardController keyboardCtl,
    int index,
  ) {
    keyboardCtl.setCursor(index);
    if (!itemScrollController.isAttached) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (itemScrollController.isAttached) {
        itemScrollController.scrollTo(
          index: index,
          duration: const Duration(milliseconds: 150),
          alignment: 0.5,
        );
      }
    });
  }

  void _scrollCursorIntoView(
    ItemScrollController itemScrollController,
    ListKeyboardController keyboardCtl,
  ) {
    final index = keyboardCtl.cursor.value;
    if (index == null) return;
    _moveCursorTo(itemScrollController, keyboardCtl, index);
  }
}

/// The bottom section of a [PaginatedBrowserPage]: the breadcrumb/search-bar
/// slot, the divider and the bottom toolbar.
///
/// v7-D1 (方案 Y): when [keyboardAware] is true it reads the keyboard inset
/// itself — with the IME open the [header] (the search bar) is padded up by the
/// inset while the divider + toolbar are dropped from the layout (their space
/// is released to the Expanded content). Reading `viewInsets` here isolates the
/// inset-driven rebuild to this small widget so the heavy content list only
/// relayouts (never rebuilds) while the keyboard animates.
class _BottomBarSection<T> extends StatelessWidget {
  final Widget header;
  final bool keyboardAware;
  final Widget divider;
  final Widget toolbar;

  const _BottomBarSection({
    required this.header,
    required this.keyboardAware,
    required this.divider,
    required this.toolbar,
  });

  @override
  Widget build(BuildContext context) {
    final inset = keyboardAware ? MediaQuery.viewInsetsOf(context).bottom : 0.0;
    final keyboardOpen = inset > 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Always wrap [header] in a Padding (tree shape stays constant, only
        // the value changes). Conditionally wrapping it would change the child
        // at this slot between header and Padding → the focused TextField would
        // be disposed and recreated mid-IME-appearance → crash.
        Padding(
          padding: EdgeInsets.only(bottom: keyboardOpen ? inset : 0),
          child: header,
        ),
        if (!keyboardOpen) ...[
          divider,
          toolbar,
        ],
      ],
    );
  }
}

/// Sentinel prefixes some data sources use on breadcrumb segments to request a
/// specific colour (`\u0000tag:` = tag name primary, `\u0000muted:` = subdued
/// "no tag" marker). Strips the sentinel for display. The sealed library root
/// crumb (`Sources`, stored unlocalized) renders localized. The canonical
/// no-tag payload ([kNoTagCrumb]) renders via `tag_no_tag` so it follows the
/// locale instead of hardcoding display text in the data source; legacy muted
/// payloads keep their verbatim passthrough.
String crumbLabel(String raw, AppLocalizations t) {
  if (raw == kNoTagCrumb) return t.tag_no_tag;
  const tagPrefix = '\u0000tag:';
  const mutedPrefix = '\u0000muted:';
  if (raw.startsWith(tagPrefix)) return raw.substring(tagPrefix.length);
  if (raw.startsWith(mutedPrefix)) return raw.substring(mutedPrefix.length);
  if (raw == 'Sources') return t.browser_sources;
  return raw;
}

/// Subdued grey for the no-tag marker, primary for a real tag name.
Color? crumbColor(String raw, ColorScheme scheme) {
  if (raw.startsWith('\u0000tag:')) return scheme.primary;
  if (raw.startsWith('\u0000muted:')) {
    return scheme.onSurfaceVariant.withValues(alpha: 0.7);
  }
  return null;
}

String _crumbLabel(String raw, AppLocalizations t) => crumbLabel(raw, t);

Color? _crumbColor(String raw, ColorScheme scheme) => crumbColor(raw, scheme);
