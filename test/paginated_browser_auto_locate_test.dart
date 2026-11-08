import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/paginated_browser_controller.dart';
import 'package:iris/features/paginated_browser/paginated_browser_page.dart';
import 'package:iris/l10n/app_localizations.dart';

/// Fake data source that mimics a paginated queue: it can optionally expose a
/// "current item" position via [supportsCurrentItem]/[resolveCurrentItemIndex].
class _FakePagedDS extends PaginatedBrowserDataSource<String> {
  final int _totalItems;
  final int _pageSize;
  final bool supportCurrent;

  int _currentPage = 0;
  bool _loading = false;
  List<String> _items = [];
  final List<int> fetchedPages = [];
  int resolveCalls = 0;

  int? currentIndex;

  /// Identity of the current item, exactly like the real queue's occurrence key:
  /// it changes when playback switches to another entry, and does not change for
  /// content-only refreshes.
  Object? currentToken;

  _FakePagedDS({
    required int totalItems,
    int pageSize = 5,
    this.supportCurrent = false,
    this.currentIndex,
    this.currentToken,
  })  : _totalItems = totalItems,
        _pageSize = pageSize {
    fetchPage(0, _pageSize);
  }

  @override
  Object? get currentItemToken => currentToken;

  @override
  int get totalItems => _totalItems;

  @override
  int get currentPage => _currentPage;

  @override
  int get totalPages => (totalItems / _pageSize).ceil().clamp(1, 99999);

  @override
  int get pageSize => _pageSize;

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
    fetchedPages.add(targetPage);
    _loading = true;
    notifyListeners();
    await Future<void>.delayed(Duration.zero);
    _currentPage = targetPage;
    final start = targetPage * _pageSize;
    final end = (start + _pageSize).clamp(0, _totalItems);
    _items = [for (var i = start; i < end; i++) 'item$i'];
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

  @override
  bool get supportsCurrentItem => supportCurrent;

  @override
  Future<int?> resolveCurrentItemIndex() async {
    resolveCalls++;
    return currentIndex;
  }
}

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: child,
      ),
    ),
  );
}

void main() {
  testWidgets('auto-locates to the page of the current item on open',
      (tester) async {
    final ds = _FakePagedDS(
      totalItems: 20,
      pageSize: 5,
      supportCurrent: true,
      currentIndex: 12, // page 2
    );
    await tester.pumpWidget(_wrap(PaginatedBrowserPage<String>(
      dataSource: ds,
      controller: PaginatedBrowserController<String>(),
      onClose: () {},
      showHomePage: false,
      showBackButton: false,
    )));
    await tester.pumpAndSettle();

    // Initial constructor fetch(0) plus the generic auto-locate fetch(2).
    expect(ds.resolveCalls, greaterThanOrEqualTo(1));
    expect(ds.currentPage, 2);
    expect(ds.fetchedPages, contains(2));
    expect(ds.items, contains('item12'));
    expect(find.text('item12'), findsOneWidget);
  });

  testWidgets('does not auto-locate when the data source has no current item',
      (tester) async {
    final ds = _FakePagedDS(
      totalItems: 20,
      pageSize: 5,
      supportCurrent: false,
      currentIndex: 12,
    );
    await tester.pumpWidget(_wrap(PaginatedBrowserPage<String>(
      dataSource: ds,
      controller: PaginatedBrowserController<String>(),
      onClose: () {},
      showHomePage: false,
      showBackButton: false,
    )));
    await tester.pumpAndSettle();

    expect(ds.resolveCalls, 0);
    expect(ds.currentPage, 0);
    expect(ds.fetchedPages, [0]);
  });

  testWidgets('follows the playing item when auto-locate-on-switch is on',
      (tester) async {
    final ds = _FakePagedDS(
      totalItems: 20,
      pageSize: 5,
      supportCurrent: true,
      currentIndex: 0,
      currentToken: 'a',
    );
    await tester.pumpWidget(_wrap(PaginatedBrowserPage<String>(
      dataSource: ds,
      controller: PaginatedBrowserController<String>(),
      onClose: () {},
      showHomePage: false,
      showBackButton: false,
      autoLocateOnCurrentChange: true,
    )));
    await tester.pumpAndSettle();
    expect(ds.currentPage, 0);

    // Playback auto-advances to an item on page 3.
    ds.currentIndex = 17;
    ds.currentToken = 'b';
    ds.notifyListeners();
    await tester.pumpAndSettle();

    expect(ds.currentPage, 3,
        reason: 'switching the playing item must bring its page into view');
    expect(ds.items, contains('item17'));
    expect(find.text('item17'), findsOneWidget);
  });

  testWidgets('a switch whose first locate misses is retried on the next notify',
      (tester) async {
    final ds = _FakePagedDS(
      totalItems: 20,
      pageSize: 5,
      supportCurrent: true,
      currentIndex: 0,
      currentToken: 'a',
    );
    await tester.pumpWidget(_wrap(PaginatedBrowserPage<String>(
      dataSource: ds,
      controller: PaginatedBrowserController<String>(),
      onClose: () {},
      showHomePage: false,
      showBackButton: false,
      autoLocateOnCurrentChange: true,
    )));
    await tester.pumpAndSettle();
    expect(ds.currentPage, 0);

    // Playback switches while a media-content refresh is mid-flight: the token
    // advances, but the new item is not resolvable yet.
    ds.currentIndex = null;
    ds.currentToken = 'b';
    ds.notifyListeners();
    await tester.pumpAndSettle();
    expect(ds.currentPage, 0);

    // The same switch resolves a moment later with NO token change. Consuming
    // the token on the failed attempt (the old behaviour) meant this notify was
    // ignored and the queue stayed on the old page until the user switched
    // again.
    ds.currentIndex = 17;
    ds.notifyListeners();
    await tester.pumpAndSettle();

    expect(ds.currentPage, 3,
        reason: 'a missed locate must not consume the switch token');
    expect(ds.items, contains('item17'));
  });

  testWidgets('ignores current-item changes when auto-locate-on-switch is off',
      (tester) async {
    final ds = _FakePagedDS(
      totalItems: 20,
      pageSize: 5,
      supportCurrent: true,
      currentIndex: 0,
      currentToken: 'a',
    );
    await tester.pumpWidget(_wrap(PaginatedBrowserPage<String>(
      dataSource: ds,
      controller: PaginatedBrowserController<String>(),
      onClose: () {},
      showHomePage: false,
      showBackButton: false,
    )));
    await tester.pumpAndSettle();

    ds.currentIndex = 17;
    ds.currentToken = 'b';
    ds.notifyListeners();
    await tester.pumpAndSettle();

    expect(ds.currentPage, 0,
        reason: 'the option is opt-in; existing browsers must not move');
  });

  testWidgets('a content refresh with the same current token never moves the '
      'page', (tester) async {
    final ds = _FakePagedDS(
      totalItems: 20,
      pageSize: 5,
      supportCurrent: true,
      currentIndex: 0,
      currentToken: 'a',
    );
    await tester.pumpWidget(_wrap(PaginatedBrowserPage<String>(
      dataSource: ds,
      controller: PaginatedBrowserController<String>(),
      onClose: () {},
      showHomePage: false,
      showBackButton: false,
      autoLocateOnCurrentChange: true,
    )));
    await tester.pumpAndSettle();

    // The reader moves away from the playing item's page.
    await tester.runAsync(() => ds.fetchPage(1, ds.pageSize));
    await tester.pumpAndSettle();
    expect(ds.currentPage, 1);

    // A duration write-back / background scan refreshes the list without
    // changing what is playing.
    ds.notifyListeners();
    await tester.pumpAndSettle();

    expect(ds.currentPage, 1,
        reason: 'following the item must not fight manual navigation');
  });

  testWidgets('shows the Go to current button only when supported and taps '
      'jump to the current page', (tester) async {
    final ds = _FakePagedDS(
      totalItems: 20,
      pageSize: 5,
      supportCurrent: true,
      currentIndex: 12,
    );
    await tester.pumpWidget(_wrap(PaginatedBrowserPage<String>(
      dataSource: ds,
      controller: PaginatedBrowserController<String>(),
      onClose: () {},
      showHomePage: false,
      showBackButton: false,
    )));
    await tester.pumpAndSettle();

    // Auto-locate already moved to page 2.
    expect(find.byIcon(Icons.my_location), findsOneWidget);

    // Move playback to page 3 (index 18) and press the button.
    ds.currentIndex = 18;
    await tester.tap(find.byIcon(Icons.my_location));
    await tester.pumpAndSettle();

    expect(ds.currentPage, 3);
    expect(ds.fetchedPages, contains(3));
    expect(ds.items, contains('item18'));
  });

  testWidgets('hides the Go to current button when not supported',
      (tester) async {
    final ds = _FakePagedDS(
      totalItems: 20,
      pageSize: 5,
      supportCurrent: false,
      currentIndex: 12,
    );
    await tester.pumpWidget(_wrap(PaginatedBrowserPage<String>(
      dataSource: ds,
      controller: PaginatedBrowserController<String>(),
      onClose: () {},
      showHomePage: false,
      showBackButton: false,
    )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.my_location), findsNothing);
  });
}
