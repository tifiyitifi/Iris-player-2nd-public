import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/paginated_browser_controller.dart';
import 'package:iris/features/paginated_browser/widgets/unified_item_tile.dart';
import 'package:iris/l10n/app_localizations.dart';

/// Desktop right-click on a row opens the SAME trailing actions as the "more"
/// button; surfaces that do not opt in keep the old behavior (no context menu).
class _MenuSource extends PaginatedBrowserDataSource<String> {
  _MenuSource({required this.supportsRowContextMenu});

  @override
  final bool supportsRowContextMenu;

  int invoked = 0;

  @override
  List<String> get items => const ['row-0'];
  @override
  int get totalItems => 1;
  @override
  int get currentPage => 0;
  @override
  int get totalPages => 1;
  @override
  int get pageSize => 20;
  @override
  bool get isLoading => false;
  @override
  bool get isError => false;
  @override
  String getItemId(String item) => item;
  @override
  String? buildItemTitle(String item) => item;

  @override
  bool handleItemTap(BuildContext context, String item) => true;
  @override
  Future<void> fetchPage(int targetPage, int currentSize) async {}
  @override
  Future<void> changePageSize(int newSize) async {}
  @override
  Future<void> changeSort(SortOption sortOption) async {}
  @override
  Future<bool> handleNavigationBack() async => true;
  @override
  Future<void> handleNavigationHome() async {}
  @override
  Future<void> navigateToCrumb(int index) async {}
  @override
  Future<void> openSearchDialog(
          BuildContext context, VoidCallback onSearchInitiated) async {}
  @override
  Widget buildTileInfoDialog(BuildContext context, String item) =>
      const SizedBox.shrink();
  @override
  Widget? buildItemLeading(BuildContext context, String item) => null;
  @override
  Widget? buildItemSubtitle(BuildContext context, String item) => null;
  @override
  Widget? buildTileContent(BuildContext context, String item) => null;
  @override
  Widget buildSortMenu(BuildContext context) => const SizedBox.shrink();
  @override
  List<PageAction> buildCustomPageActions(BuildContext context) => const [];
  @override
  List<CustomSelectionAction<String>> buildCustomSelectionActions(
          BuildContext context) =>
      const [];
  @override
  List<GenericItemAction<String>> getItemTrailingActions(
          BuildContext context, String item) =>
      [
        GenericItemAction<String>(
          label: 'Do thing',
          onPressed: (context, item) => invoked++,
        ),
      ];
  @override
  List<String>? get currentBreadcrumbs => null;
  @override
  bool get isRightToLeftBreadcrumbs => false;
}

Future<_MenuSource> _pump(WidgetTester tester,
    {bool contextMenu = true}) async {
  final ds = _MenuSource(supportsRowContextMenu: contextMenu);
  addTearDown(ds.dispose);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: UnifiedItemTile<String>(
        item: 'row-0',
        pageItems: const ['row-0'],
        controller: PaginatedBrowserController<String>(),
        dataSource: ds,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return ds;
}

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('right-click opens the trailing actions and invokes one',
      (tester) async {
    final ds = await _pump(tester, contextMenu: true);

    await _rightClick(tester, find.text('row-0'));
    expect(find.text('Do thing'), findsOneWidget);

    await tester.tap(find.text('Do thing'));
    await tester.pumpAndSettle();
    expect(ds.invoked, 1);
  });

  testWidgets('right-click does nothing when the surface opts out',
      (tester) async {
    final ds = await _pump(tester, contextMenu: false);

    await _rightClick(tester, find.text('row-0'));
    expect(find.text('Do thing'), findsNothing);
    expect(ds.invoked, 0);
  });
}
