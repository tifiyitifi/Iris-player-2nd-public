import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/service/vm_duration_scan.dart';
import 'package:iris/l10n/app_localizations.dart';

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
  testWidgets('scan dialog: 立即扫描 returns true', (tester) async {
    final navigator = await pumpNavigator(tester);
    final future = showVmDurationScanDialog(
      navigator,
      groupName: '短片合集',
      unknownNames: const ['1.mp4', '2.mp4'],
      totalSegments: 3,
    );
    await tester.pumpAndSettle();
    expect(find.text('虚拟合播缺失时长'), findsOneWidget);
    await tester.tap(find.text('立即扫描'));
    expect(await future, isTrue);
  });

  testWidgets('scan dialog: 取消合并 returns false', (tester) async {
    final navigator = await pumpNavigator(tester);
    final future = showVmDurationScanDialog(
      navigator,
      groupName: '短片合集',
      unknownNames: const ['1.mp4'],
      totalSegments: 2,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消合并，普通播放'));
    expect(await future, isFalse);
  });

  testWidgets('progress dialog completes with the task outcome', (tester) async {
    final navigator = await pumpNavigator(tester);
    final future = scanWithProgressDialog(
      navigator,
      title: '扫描缺失时长',
      total: 2,
      task: (onProgress, isCancelled) async {
        onProgress(2, 2, '2.mp4');
        return const VmScanOutcome(
          ok: true,
          scanned: 2,
          skipped: 0,
          succeededKeys: ['k1', 'k2'],
          failedKeys: [],
          elapsed: Duration.zero,
        );
      },
    );
    await tester.pumpAndSettle();
    final outcome = await future;
    expect(outcome.ok, isTrue);
    expect(outcome.succeededKeys, ['k1', 'k2']);
    await tester.pumpAndSettle();
    // Progress dialog dismissed, home visible again.
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('progress dialog cancel returns cancelled outcome', (tester) async {
    final navigator = await pumpNavigator(tester);
    final future = scanWithProgressDialog(
      navigator,
      title: '扫描缺失时长',
      total: 2,
      task: (onProgress, isCancelled) async {
        // Simulate a long scan that polls cancellation.
        for (var i = 0; i < 100 && !isCancelled(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return VmScanOutcome(
          ok: false,
          scanned: 0,
          skipped: 0,
          succeededKeys: const [],
          failedKeys: const [],
          elapsed: Duration.zero,
          cancelled: isCancelled(),
        );
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消扫描'));
    await tester.pumpAndSettle();
    final outcome = await future;
    expect(outcome.cancelled, isTrue);
    expect(find.text('home'), findsOneWidget);
  });
}
