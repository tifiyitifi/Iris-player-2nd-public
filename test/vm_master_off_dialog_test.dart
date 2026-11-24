import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/commands/vm_dir_toggle.dart';
import 'package:iris/features/virtual_media/view/vm_master_off_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';

/// The paused-master prompt must explain itself WITHOUT hiding the decision:
/// the three options always come first, the "选项说明" disclosure below them is
/// always collapsed on open, and the folder-only choice only goes grey (never
/// disappears) when there is no other enabled rule to close.
Future<NavigatorState> pumpNavigator(WidgetTester tester) async {
  late NavigatorState navigator;
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(builder: (context) {
      navigator = Navigator.of(context);
      return const Scaffold(body: Text('home'));
    }),
  ));
  await tester.pumpAndSettle();
  return navigator;
}

void main() {
  testWidgets('options come first, the details are collapsed by default',
      (tester) async {
    final navigator = await pumpNavigator(tester);
    showVmMasterOffDialog(navigator.context, otherEnabledCount: 2);
    await tester.pumpAndSettle();

    expect(find.text('只保留当前文件夹规则'), findsOneWidget);
    expect(find.text('直接开启总开关'), findsOneWidget);
    expect(find.text('取消本次操作'), findsOneWidget);
    expect(find.text('选项说明'), findsOneWidget);
    expect(find.textContaining('总开关是全部规则的电源'), findsNothing,
        reason: 'the details must start collapsed on every open');

    expect(
      tester.getTopLeft(find.text('取消本次操作')).dy,
      lessThan(tester.getTopLeft(find.text('选项说明')).dy),
      reason: 'the decision comes before the explanation',
    );

    await tester.tap(find.text('选项说明'));
    await tester.pumpAndSettle();
    expect(find.textContaining('总开关是全部规则的电源'), findsOneWidget);

    // Collapse again: the toggle is not a one-way door.
    await tester.tap(find.text('选项说明'));
    await tester.pumpAndSettle();
    expect(find.textContaining('总开关是全部规则的电源'), findsNothing);
  });

  testWidgets('keeping only the current folder is an explicit choice',
      (tester) async {
    final navigator = await pumpNavigator(tester);
    final future =
        showVmMasterOffDialog(navigator.context, otherEnabledCount: 3);
    await tester.pumpAndSettle();
    expect(find.textContaining('其它 3 条已启用的规则'), findsOneWidget);

    await tester.tap(find.text('只保留当前文件夹规则'));
    expect(await future, VmMasterOffChoice.keepOnlyCurrent);
  });

  testWidgets(
      'with no other rules the folder-only choice is greyed, not hidden',
      (tester) async {
    final navigator = await pumpNavigator(tester);
    final future =
        showVmMasterOffDialog(navigator.context, otherEnabledCount: 0);
    await tester.pumpAndSettle();

    // The dialog keeps its three-choice shape: the tile stays, disabled and
    // explained, instead of vanishing and making the prompt look truncated.
    expect(find.text('只保留当前文件夹规则'), findsOneWidget);
    expect(find.text('直接开启总开关'), findsOneWidget);
    expect(find.text('取消本次操作'), findsOneWidget);
    expect(find.text('当前没有其它已启用的规则，直接开启即可'), findsOneWidget);

    final keepOnly = tester.widget<ListTile>(
        find.byKey(const ValueKey('vm_master_off_keep_only')));
    expect(keepOnly.enabled, isFalse);
    expect(keepOnly.onTap, isNull);

    // A disabled tile must not act: the dialog is still waiting.
    await tester.tap(find.text('只保留当前文件夹规则'));
    await tester.pumpAndSettle();
    expect(find.text('虚拟合播总开关已关闭'), findsOneWidget);

    await tester.tap(find.text('直接开启总开关'));
    expect(await future, VmMasterOffChoice.enableAll);
  });

  testWidgets('cancel is a true no-op choice', (tester) async {
    final navigator = await pumpNavigator(tester);
    final future =
        showVmMasterOffDialog(navigator.context, otherEnabledCount: 1);
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消本次操作'));
    expect(await future, isNull);
  });
}
