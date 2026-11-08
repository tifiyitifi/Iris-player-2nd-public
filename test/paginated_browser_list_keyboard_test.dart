import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/paginated_browser/data_source/playlist_key_target.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/paginated_browser_page.dart';
import 'package:iris/features/paginated_browser/widgets/list_keyboard_scope.dart';
import 'package:iris/features/paginated_browser/widgets/unified_item_tile.dart';
import 'package:iris/features/windows/desktop_keyboard/model/playlist_action.dart';
import 'package:iris/l10n/app_localizations.dart';

class _FakeSource extends PaginatedBrowserDataSource<String>
    implements PlaylistKeyTarget {
  _FakeSource(this._items);

  final List<String> _items;

  final List<PlaylistAction> actions = [];
  final List<int?> cursors = [];

  @override
  List<String> get items => _items;

  @override
  int get totalItems => _items.length;
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
  bool handleItemTap(BuildContext context, String item) => true;

  @override
  Future<bool> handlePlaylistAction(
    BuildContext context,
    PlaylistAction action, {
    int? cursorIndex,
    Set<String> selectedIds = const {},
  }) async {
    actions.add(action);
    cursors.add(cursorIndex);
    return true;
  }

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
  String? buildItemTitle(String item) => item;
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
      const [];
  @override
  List<String>? get currentBreadcrumbs => null;
  @override
  bool get isRightToLeftBreadcrumbs => false;
}

Future<_FakeSource> _pump(
  WidgetTester tester, {
  required bool listKeyboard,
}) async {
  final source = _FakeSource(['a', 'b', 'c', 'd']);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: PaginatedBrowserPage<String>(
        dataSource: source,
        listKeyboard: listKeyboard,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return source;
}

void main() {
  testWidgets('listKeyboard=false mounts no scope and owns no keys',
      (tester) async {
    final source = await _pump(tester, listKeyboard: false);
    expect(find.byType(ListKeyboardScope), findsNothing);

    // A bare letter is not owned (no scope) and the global handler is absent in
    // this test, so the data source never sees a playlist action.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    expect(source.actions, isEmpty);
  });

  testWidgets('listKeyboard=true: P plays the cursor item after ↑/↓ navigation',
      (tester) async {
    final source = await _pump(tester, listKeyboard: true);
    expect(find.byType(ListKeyboardScope), findsOneWidget);

    // Focus the list via pointer-down, then move the cursor down twice.
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(source.actions, contains(PlaylistAction.play));
    // First ↓ enters the list at index 0, the second lands on index 1.
    expect(source.cursors.last, 1);
  });

  testWidgets('listKeyboard=true: Space / PageDown are NOT consumed by the list',
      (tester) async {
    final source = await _pump(tester, listKeyboard: true);
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();

    // Neither key maps to a PlaylistAction → the data source sees nothing.
    expect(source.actions, isEmpty);
  });

  testWidgets('listKeyboard=true: Ctrl+A selects all rows on the page',
      (tester) async {
    final source = await _pump(tester, listKeyboard: true);
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    // Selection is page-owned; no playlist action is delegated.
    expect(source.actions, isEmpty);
  });

  testWidgets('listKeyboard=true: a held Delete removes once, repeats swallowed',
      (tester) async {
    final source = await _pump(tester, listKeyboard: true);
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();

    // KeyDown + the auto-repeats an OS emits while the key stays held.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    await tester.pump();

    expect(
      source.actions.where((a) => a == PlaylistAction.removeSelected),
      hasLength(1),
      reason: 'each repeat would remove the next row that shifted under the '
          'cursor — a destructive action must never auto-repeat',
    );
  });

  testWidgets('listKeyboard=true: a held play key fires once, repeats swallowed',
      (tester) async {
    final source = await _pump(tester, listKeyboard: true);
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();

    // P is not destructive, but a repeat would toggle play/pause once per
    // auto-repeat tick. Only cursor movement is repeat-safe.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    await tester.pump();

    expect(
      source.actions.where((a) => a == PlaylistAction.play),
      hasLength(1),
      reason: 'a held play key must not flip the transport once per repeat',
    );
  });

  testWidgets('listKeyboard=true: held cursor keys keep moving', (tester) async {
    final source = await _pump(tester, listKeyboard: true);
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();

    // Navigation is the ONE repeat-safe class: ↓ + its auto-repeat = 2 steps.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(
      source.cursors.last,
      1,
      reason: 'the first ↓ enters at row 0 and the repeat advances to row 1',
    );
  });

  testWidgets('ListKeyboardScope owns PL keys but not global player keys',
      (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(MaterialApp(
      home: ListKeyboardScope(
        child: Focus(focusNode: node, child: const SizedBox.expand()),
      ),
    ));
    node.requestFocus();
    await tester.pump();

    KeyEvent down(LogicalKeyboardKey key) => KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: key,
          timeStamp: Duration.zero,
        );

    expect(ListKeyboardScope.ownsKey(down(LogicalKeyboardKey.arrowDown)), isTrue);
    expect(ListKeyboardScope.ownsKey(down(LogicalKeyboardKey.keyP)), isTrue);
    expect(ListKeyboardScope.ownsKey(down(LogicalKeyboardKey.delete)), isTrue);
    expect(ListKeyboardScope.ownsKey(down(LogicalKeyboardKey.space)), isFalse);
    expect(ListKeyboardScope.ownsKey(down(LogicalKeyboardKey.pageDown)), isFalse);
    expect(ListKeyboardScope.ownsKey(down(LogicalKeyboardKey.enter)), isFalse);
    expect(ListKeyboardScope.ownsKey(down(LogicalKeyboardKey.arrowLeft)), isFalse);
    // Speed keys are exempt from type-ahead: the focused list must NOT own
    // them, so the global handler keeps Z/X/C live during playback.
    expect(ListKeyboardScope.ownsKey(down(LogicalKeyboardKey.keyZ)), isFalse);
    expect(ListKeyboardScope.ownsKey(down(LogicalKeyboardKey.keyX)), isFalse);
    expect(ListKeyboardScope.ownsKey(down(LogicalKeyboardKey.keyC)), isFalse);
    // A regular letter is still owned as type-ahead.
    expect(ListKeyboardScope.ownsKey(down(LogicalKeyboardKey.keyD)), isTrue);
  });

  testWidgets(
      'cursor accent dims while the list is unfocused and the cursor '
      'position survives refocusing', (tester) async {
    await _pump(tester, listKeyboard: true);

    UnifiedItemTile<String> tile(int index) => tester
        .widgetList<UnifiedItemTile<String>>(find.byType(UnifiedItemTile<String>))
        .elementAt(index);

    // Focus the list by clicking INSIDE the list body but below the rows: the
    // tap must reach the page's pointer-down grab, and empty viewport space
    // keeps the check independent of how a row composes its title.
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(tile(0).keyboardCursor, isTrue);
    expect(tile(0).keyboardCursorActive, isTrue,
        reason: 'focused list → the accent is at full strength');

    // Focus goes elsewhere (e.g. the user clicked the picture): the accent
    // must stop claiming ownership of ↑/↓, but the cursor row stays known.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    expect(tile(0).keyboardCursor, isTrue);
    expect(tile(0).keyboardCursorActive, isFalse,
        reason: 'unfocused list → the accent dims so it cannot lie about '
            'who owns ↑/↓');
    KeyEvent down(LogicalKeyboardKey key) => KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: key,
          timeStamp: Duration.zero,
        );
    expect(ListKeyboardScope.ownsKey(down(LogicalKeyboardKey.arrowDown)),
        isFalse);

    // Clicking back into the list restores the accent and keeps the position:
    // the next ↓ must land on row 1 (a cursor reset by the unfocus would put
    // it back at the entry edge, i.e. row 0 again).
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(tile(0).keyboardCursorActive, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tile(1).keyboardCursor, isTrue,
        reason: 'the cursor survived the unfocus: ↓ moved it 0 → 1');
    expect(tile(0).keyboardCursor, isFalse);
  });

  testWidgets(
      'page counter and per-page chips are status text, not tab stops',
      (tester) async {
    await _pump(tester, listKeyboard: true);

    // The `1/1` page counter must never hold keyboard focus: a focused
    // readout turns Space/Enter (the framework ActivateIntent) into a tap
    // that opens the jump prompt.
    final counters = tester.widgetList<InkWell>(
      find.ancestor(
          of: find.text('1/1'), matching: find.byType(InkWell)),
    );
    expect(counters, isNotEmpty);
    for (final counter in counters) {
      expect(counter.canRequestFocus, isFalse);
    }

    // Same rule for the `total/pageSize` chip.
    final chips = tester.widgetList<InkWell>(
      find.ancestor(
          of: find.text('4/20'), matching: find.byType(InkWell)),
    );
    expect(chips, isNotEmpty);
    for (final chip in chips) {
      expect(chip.canRequestFocus, isFalse);
    }
  });

  testWidgets('listKeyboard=true: Space/Enter never open the page-jump prompt',
      (tester) async {
    await _pump(tester, listKeyboard: true);
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.text('Jump to Page'), findsNothing,
        reason: 'Space/Enter belong to the player, not to a toolbar readout');
    expect(find.text('a'), findsOneWidget);
  });

  testWidgets('listKeyboard=true: Ctrl+G opens the page-jump prompt',
      (tester) async {
    await _pump(tester, listKeyboard: true);
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('Jump to Page'), findsOneWidget,
        reason: 'the keyboard keeps a way to reach the prompt');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Jump to Page'), findsNothing);
  });
}
