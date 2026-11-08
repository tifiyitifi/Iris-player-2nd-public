import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/paginated_browser_controller.dart';
import 'package:iris/features/paginated_browser/paginated_browser_page.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/enums/storage_list_error.dart';
/// A data source that can be put into the "background refresh" state while a
/// previous page is still on screen 鈥?exactly what the 鍓煶 queue does when the
/// duration probe writes back or the browser auto-locates to the current row.
class _RefreshDS extends PaginatedBrowserDataSource<String> {
  _RefreshDS() {
    _items = [for (var i = 0; i < 5; i++) 'row$i'];
  }

  List<String> _items = const [];
  bool _loading = false;

  void beginRefresh() {
    _loading = true;
    notifyListeners();
  }

  void endRefresh() {
    _loading = false;
    notifyListeners();
  }

  @override
  int get totalItems => _items.length;
  @override
  int get currentPage => 0;
  @override
  int get totalPages => 1;
  @override
  int get pageSize => 50;
  @override
  bool get isLoading => _loading;
  @override
  bool get isError => false;
  @override
  List<String> get items => _items;
  @override
  String getItemId(String item) => item;
  @override
  List<String>? get currentBreadcrumbs => null;
  @override
  bool get isRightToLeftBreadcrumbs => false;

  @override
  Future<void> fetchPage(int targetPage, int currentSize) async {
    _loading = true;
    notifyListeners();
    _loading = false;
    notifyListeners();
  }

  @override
  Future<void> changePageSize(int newSize) async {}
  @override
  Future<void> changeSort(SortOption sortOption) async {}
  @override
  Future<bool> handleNavigationBack() async => false;
  @override
  Future<void> handleNavigationHome() async {}
  @override
  Future<void> navigateToCrumb(int index) async {}
  @override
  bool get supportsSearch => false;
  @override
  Future<void> openSearchDialog(
      BuildContext context, VoidCallback onSearchInitiated) async {}
  @override
  bool handleItemTap(BuildContext context, String item) => true;
  @override
  Widget buildTileInfoDialog(BuildContext context, String item) =>
      const SizedBox();
  @override
  Widget? buildItemLeading(BuildContext context, String item) => null;
  @override
  String? buildItemTitle(String item) => item;
  @override
  Widget? buildItemSubtitle(BuildContext context, String item) => null;
  @override
  Widget? buildTileContent(BuildContext context, String item) => null;
  @override
  Widget buildSortMenu(BuildContext context) => const SizedBox.shrink();
  @override
  List<PageAction> buildCustomPageActions(BuildContext context) => [];
  @override
  List<CustomSelectionAction<String>> buildCustomSelectionActions(
          BuildContext context) =>
      [];
  @override
  List<GenericItemAction<String>> getItemTrailingActions(
          BuildContext context, String item) =>
      [];
}

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(width: 800, height: 600, child: child),
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  PaginatedBrowserDataSource<String> ds, {
  bool settle = true,
}) async {
  await tester.pumpWidget(_wrap(PaginatedBrowserPage<String>(
    dataSource: ds,
    controller: PaginatedBrowserController<String>(),
    onClose: () {},
    showHomePage: false,
    showBackButton: false,
  )));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // A permanent spinner never settles: pump a couple of frames only.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('a background refresh keeps the rows on screen', (tester) async {
    final ds = _RefreshDS();
    await _pump(tester, ds);
    expect(find.text('row0'), findsOneWidget);

    // Duration write-back / auto-locate starts a re-fetch: the list must not
    // blank itself into a full-surface spinner (the 銆屽垪琛ㄩ棯鐑併€?report).
    ds.beginRefresh();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('row0'), findsOneWidget);

    ds.endRefresh();
    await tester.pumpAndSettle();
    expect(find.text('row0'), findsOneWidget);
  });

  testWidgets('an empty first load still shows the spinner', (tester) async {
    // Nothing has been listed yet: the spinner is the only honest state.
    await _pump(tester, _EmptyRefreshDS(), settle: false);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a FAILED background refresh keeps the rows, not the error panel',
      (tester) async {
    // The sibling of the loading rule: a refresh that throws leaves the previous
    // page in place (`items` untouched, `isError = true`). Replacing the list
    // with the full-surface error panel is the same 銆屽垪琛ㄩ棯鐑併€?the loading fix
    // removed, only after the failure instead of during it.
    final ds = _ErrorRefreshDS()..failAfterLoad();
    await _pump(tester, ds);
    expect(find.text('row0'), findsOneWidget);

    ds.failRefresh();
    await tester.pumpAndSettle();
    expect(find.text('row0'), findsOneWidget);
    expect(find.text('Failed to load browser contents.'), findsNothing);
  });

  testWidgets('a failed FIRST load still shows the error panel', (tester) async {
    final ds = _ErrorRefreshDS()..failRefresh();
    await _pump(tester, ds);
    expect(find.text('Failed to load browser contents.'), findsOneWidget);
  });
}

/// Never resolves its first page: `items` stays empty while loading.
class _EmptyRefreshDS extends _RefreshDS {
  @override
  List<String> get items => const <String>[];
  @override
  bool get isLoading => true;
}

/// A refresh that FAILED after a page was already on screen: the row list is
/// retained and only the error flag flips (the real data sources do exactly
/// this 鈥?`_items` is assigned inside the try, `_isError` in the catch).
class _ErrorRefreshDS extends _RefreshDS {
  bool _failed = false;
  bool _hasRows = false;

  void failRefresh() {
    _failed = true;
    notifyListeners();
  }

  /// Marks the previous page as still on screen, then fails the next refresh.
  void failAfterLoad() {
    _hasRows = true;
    notifyListeners();
  }

  @override
  List<String> get items => _hasRows ? super.items : const <String>[];
  @override
  bool get isError => _failed;
  @override
  StorageListErrorKind? get listErrorKind => StorageListErrorKind.unknown;
}

