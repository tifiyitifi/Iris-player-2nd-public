import 'package:flutter/material.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/models/tooltip_direction.dart';
import 'package:iris/models/enums/storage_list_error.dart';

/// Canonical no-tag breadcrumb payload: data sources emit this sentinel (never
/// display text) and the generic renderer localizes it via `tag_no_tag`.
/// The `\u0000muted:` prefix keeps the subdued grey and can never collide
/// with a real tag literally named like the no-tag label.
const String kNoTagCrumb = '\u0000muted:__no_tag__';

/// Largest page size any browser accepts.
///
/// A page is fully MATERIALIZED in memory (rows, tiles, selection sets), so
/// the number is a memory/work budget, not a preference. The prompt used to
/// accept 100000, which asks one resolve to build a hundred thousand rows on
/// the UI isolate — an OOM or a multi-second freeze from a single typo.
///
/// Clamping only the prompt is not enough: every browser page size is
/// PERSISTED, so a value typed before this ceiling existed is read straight
/// back from storage and reaches `fetchPage` without passing any prompt. Every
/// entry therefore clamps — the prompt, each data source's `changePageSize`,
/// and each store's load/import boundary — all through [clampPageSize], so the
/// copy, the validator and the stores can never disagree about what is legal.
const int kMaxBrowserPageSize = 1000;

/// Clamps a requested page size into the legal `1..[kMaxBrowserPageSize]` range.
///
/// Pure, so the prompt's validation and each data source's guard share ONE
/// definition instead of drifting apart.
int clampPageSize(int size) =>
    size < 1 ? 1 : (size > kMaxBrowserPageSize ? kMaxBrowserPageSize : size);

abstract class PaginatedBrowserDataSource<T> extends ChangeNotifier {
  // Pagination State Accessors
  int get totalItems;
  int get currentPage;
  int get totalPages;
  int get pageSize;

  // Visual Lifecycle Vectors
  bool get isLoading;
  bool get isError;

  /// Why the last load failed, when the implementation can classify it.
  ///
  /// The page renders this as a localized explanation above the raw
  /// [listErrorDetail], so a failure is never mistaken for an empty result.
  /// Implementations that cannot classify simply keep the null default.
  StorageListErrorKind? get listErrorKind => null;

  /// Raw technical detail of the last failure (exception text), shown verbatim
  /// for diagnosis. Null when unknown.
  String? get listErrorDetail => null;

  // Active Window Payload
  List<T> get items;

  // Unique Identifier Hook for Persistent Multi-Selection Matrix
  String getItemId(T item);

  // Optional Breadcrumbs Parameters
  List<String>? get currentBreadcrumbs;
  bool get isRightToLeftBreadcrumbs;

  // Paging and Structural Pipeline Dispatchers
  Future<void> fetchPage(int targetPage, int currentSize);

  /// Page displaying the item at the global [index] that
  /// [resolveCurrentItemIndex] returned. Defaults to dense paging, which holds
  /// for any source whose pages are exactly `pageSize` items.
  int pageForIndex(int index) => pageSize <= 0 ? 0 : index ~/ pageSize;

  /// Row of the item at the global [index] inside the CURRENT page. Defaults to
  /// the dense offset; a source whose pages are not dense over the index space
  /// (e.g. pages keyed by a base slot with skipped positions) overrides this.
  int rowInCurrentPage(int index) => index - currentPage * pageSize;

  /// Re-runs the last load (network). Defaults to a page refetch; storage
  /// browsers override it with a real reload so the error-page Retry button
  /// actually dials again after the host comes back.
  Future<void> retryLoad() => fetchPage(currentPage, pageSize);
  Future<void> changePageSize(int newSize);
  Future<void> changeSort(SortOption sortOption);

  /// Returns true if back was handled (breadcrumbs remain), false if at root.
  Future<bool> handleNavigationBack();
  Future<void> handleNavigationHome();
  Future<void> navigateToCrumb(int index);

  // Search Context Launchers
  bool get supportsSearch => true;
  Future<void> openSearchDialog(
      BuildContext context, VoidCallback onSearchInitiated);

  // Tap Handling — return true if handled, false to show default info dialog
  bool handleItemTap(BuildContext context, T item);

  // Default info dialog content (shown when handleItemTap returns false)
  Widget buildTileInfoDialog(BuildContext context, T item);

  // Presentation UI Delegations — Tile layout
  // New methods take priority; buildTileContent is fallback if these return null
  Widget? buildItemLeading(BuildContext context, T item);
  String? buildItemTitle(T item);
  Widget? buildItemSubtitle(BuildContext context, T item);

  /// Title as a widget (e.g. rich text with query-match highlighting). Takes
  /// priority over [buildItemTitle] when non-null (v10-D1).
  Widget? buildItemTitleWidget(BuildContext context, T item) => null;

  // Legacy fallback — prefer buildItemLeading/buildItemTitle/buildItemSubtitle
  @Deprecated('Use buildItemLeading, buildItemTitle, buildItemSubtitle instead')
  Widget? buildTileContent(BuildContext context, T item);

  // Toolbar UI Delegations
  Widget buildSortMenu(BuildContext context);
  List<PageAction> buildCustomPageActions(BuildContext context);

  /// Far-right toolbar actions — rendered just left of the close button,
  /// after the page navigation, in every responsive tier. Distinct from
  /// [buildCustomPageActions] so surfaces can pin actions (e.g. the
  /// dock/float toggle) at the trailing edge of the bar.
  List<PageAction> buildTrailingPageActions(BuildContext context) => const [];
  List<CustomSelectionAction<T>> buildCustomSelectionActions(
      BuildContext context);
  /// The row's trailing (more-menu) actions.
  ///
  /// Called in TWO distinct phases: during `build` by the trailing "more"
  /// button (`UnifiedItemTile`), and from a gesture callback by the desktop
  /// right-click menu when [supportsRowContextMenu] is on. Implementations must
  /// therefore be callable OUTSIDE build — notably, a reactive
  /// `store.select(context, …)` is FORBIDDEN here (provider asserts
  /// `debugDoingBuild`). Read store state as a snapshot (`store.state.x`);
  /// reactivity is only needed by [isCurrentItem] and friends, which are
  /// build-only.
  List<GenericItemAction<T>> getItemTrailingActions(
      BuildContext context, T item);

  /// Whether multi-select is available (long-press enters selection mode).
  ///
  /// Newer surfaces (e.g. the media search page) opt out; the generic tile
  /// gates the long-press/selection entry on this flag (O3/O8).
  bool get supportsSelection => true;

  /// Whether rows expose a desktop right-click context menu that reuses
  /// [getItemTrailingActions].
  ///
  /// Defaults to false so every existing surface keeps its exact interaction;
  /// only surfaces that opt in pay the extra [GestureDetector] on the row (and
  /// only on desktop). The menu items are the SAME trailing actions, so a
  /// surface never has to maintain two lists.
  bool get supportsRowContextMenu => false;

  /// Whether this item is the currently active/playing item.
  ///
  /// Takes a [BuildContext] so implementations can reactively read a store via
  /// `select(context, ...)` (called during build).
  bool isCurrentItem(BuildContext context, T item) => false;

  /// Whether [item] renders greyed-out / un-tappable (D28).
  ///
  /// Scenario queue/preview surfaces override this for `available: false`
  /// placeholders (missing explicit items / empty sources); the generic tile
  /// applies the dimmed style when this returns true.
  bool isItemUnavailable(BuildContext context, T item) => false;

  /// Whether [item] can take part in multi-selection (default true).
  ///
  /// Context-free so the selection controller can filter bulk operations
  /// (select-all / invert / range) without a [BuildContext]. Surfaces override
  /// this to grey out rows whose non-playback operations are unsupported —
  /// e.g. Virtual Media merged groups in scenario search (they stay tappable
  /// to play, but cannot be selected).
  bool isItemSelectable(T item) => true;

  /// Selection the host bar published for THIS build, so an action whose
  /// callback carries no payload ([PageAction.onPressed] is a `VoidCallback`)
  /// can still honour a selection.
  ///
  /// The bar resolves it from `controller.selectedIds ∩ items` — the CURRENT
  /// PAGE only — and rebuilds on every selection change
  /// (`useListenable(controller)`), so it is fresh at tap time. This mirrors
  /// the established "the owner hands selection in" pattern the page uses for
  /// `PlaylistKeyTarget.handlePlaylistAction`.
  ///
  /// A count badge may legitimately show the GLOBAL total; ACTIONS always
  /// operate on this page's intersection. Written during build, so never call
  /// `notifyListeners()` when publishing it.
  Set<T> selectionForActions = const {};

  /// Clears the source of [selectionForActions] (the page's controller).
  ///
  /// Published so a bulk action can drop the ids it just deleted — otherwise
  /// they linger and the action's next tap silently falls back to its
  /// no-selection path.
  VoidCallback? clearSelectionForActions;

  /// Whether this browser has a notion of "current item" that can be located
  /// to. When true the generic page shows the optional "Go to current" button
  /// and auto-locates to the current item's page on open.
  bool get supportsCurrentItem => false;

  /// 0-based position of the currently active/playing item within the whole
  /// list, or null when there is none. Used by the generic page to compute the
  /// target page (`index ~/ pageSize`) and the in-page row to center.
  Future<int?> resolveCurrentItemIndex() async => null;

  /// Direction long-press button tooltips pop out from. Defaults to above.
  TooltipDirection get tooltipDirection => TooltipDirection.above;

  // ── Optional inline row expansion ──
  //
  // Surfaces with bounded nested content (e.g. a merged virtual-media row's
  // child files, capped at 32) opt in by overriding these. The generic tile
  // then renders a disclosure chevron and lazily mounts the expanded content
  // under the row; every other surface pays nothing and keeps its exact prior
  // layout/rebuild behavior.

  /// Whether [item] can be expanded to reveal nested content. Default false.
  bool isItemExpandable(T item) => false;

  /// Whether [item] is currently expanded. Default false.
  bool isItemExpanded(T item) => false;

  /// Toggles [item]'s expansion state. Implementations must `notifyListeners()`
  /// so the mounted page rebuilds (expansion is a low-frequency user action).
  void toggleItemExpanded(T item) {}

  /// Content mounted under [item]'s row while expanded. Only invoked when
  /// [isItemExpandable] and [isItemExpanded] are both true, so building the
  /// nested children stays lazy. Default null.
  Widget? buildItemExpandedContent(BuildContext context, T item) => null;
}
