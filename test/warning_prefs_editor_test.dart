import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/warning_dialogs.dart';
import 'package:iris/widgets/dialogs/warning_prefs_editor.dart';
import 'package:zustand/zustand.dart';

import 'helpers/sqlite3_loader.dart';

class _TestStoreScope extends SingleChildStatefulWidget {
  const _TestStoreScope({required Widget child}) : super(child: child);
  @override
  State<_TestStoreScope> createState() => _TestStoreScopeState();
}

class _TestStoreScopeState extends SingleChildState<_TestStoreScope> {
  @override
  Widget buildWithChild(BuildContext context, Widget? child) {
    return InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (e, v) {
        final sub = v.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      child: child,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  setUpAll(() async {
    final db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });

  Widget harness() => const _TestStoreScope(
        child: MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: WarningDialogPrefsEditorDialog()),
        ),
      );

  testWidgets('WarningDialogPrefsEditorDialog is reactive to store changes',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    // Ensure clean start.
    await tester.runAsync(() async {
      final s = useAppStore();
      if (s.state.suppressedWarnings.isNotEmpty) {
        await s.resetSuppressedWarnings();
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Initial: unsuppressed -> ON.
    var tiles = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile));
    expect(tiles.length, kSuppressibleWarningIds.length);
    for (final t in tiles) {
      expect(t.value, isTrue);
    }
    expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Restore all warnings')).onPressed,
        isNull);

    // Suppress via store -> must rebuild to OFF.
    await tester.runAsync(() => useAppStore().suppressWarning(kWarningForceAppendNoMedia));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(useAppStore().state.suppressedWarnings, contains(kWarningForceAppendNoMedia));
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value, isFalse);
    expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Restore all warnings')).onPressed,
        isNotNull);

    // Tapping UI triggers suppressWarning (last warning in registry).
    final lastId = kSuppressibleWarningIds.last;
    final lastTile = find.byType(SwitchListTile).last;
    await tester.scrollUntilVisible(lastTile, 200);
    await tester.tap(lastTile);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(useAppStore().state.suppressedWarnings, contains(lastId));
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile).last).value, isFalse);

    // Reset one -> rebuild to ON.
    await tester.runAsync(() => useAppStore().resetWarning(kWarningForceAppendNoMedia));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value, isTrue);
    expect(useAppStore().state.suppressedWarnings, isNot(contains(kWarningForceAppendNoMedia)));

    // Suppress all, then reset-all.
    for (final id in kSuppressibleWarningIds) {
      await tester.runAsync(() => useAppStore().suppressWarning(id));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(useAppStore().state.suppressedWarnings, hasLength(kSuppressibleWarningIds.length));
    for (final t in tester.widgetList<SwitchListTile>(find.byType(SwitchListTile))) {
      expect(t.value, isFalse);
    }

    // Reset-all via the button (scroll into view: en labels are taller).
    // runAsync lets the secure-storage persist complete inside fake async.
    final resetBtn = find.widgetWithText(TextButton, 'Restore all warnings');
    await tester.scrollUntilVisible(resetBtn, 200);
    await tester.pump();
    expect(tester.widget<TextButton>(resetBtn).onPressed, isNotNull);
    await tester.runAsync(() async {
      await tester.tap(resetBtn);
      await tester.pump();
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(useAppStore().state.suppressedWarnings, isEmpty);
    // Tiles rebuild async via the store stream + secure-storage write —
    // poll until they flip back ON.
    var flipped = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final tiles =
          tester.widgetList<SwitchListTile>(find.byType(SwitchListTile));
      if (tiles.isNotEmpty && tiles.every((t) => t.value)) {
        flipped = true;
        break;
      }
    }
    expect(flipped, isTrue);
    expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Restore all warnings')).onPressed,
        isNull);
  });
}
