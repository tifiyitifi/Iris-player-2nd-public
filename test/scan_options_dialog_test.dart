import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/media_library/scan/view/scan_info_dialog.dart';
import 'package:iris/features/media_library/scan/view/scan_options_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/storages/storage.dart';

Storage _storage() => Storage.local(
      type: StorageType.internal,
      name: 'Test storage',
      basePath: const <String>[],
    );

Future<void> _pumpHost(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open,
) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('entry point shows the explainer, not the probe checkbox',
      (tester) async {
    await _pumpHost(tester, (context) async {
      await showScanOptionsDialog(context, storage: _storage());
    });

    expect(find.byType(ScanInfoDialog), findsOneWidget);
    expect(find.byType(ScanOptionsDialog), findsNothing);
    expect(find.text('尝试读取媒体信息（时长 / 分辨率）'), findsNothing,
        reason: 'duration/resolution are always read; the option is hidden');
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('开始扫描'), findsOneWidget);
  });

  testWidgets('cancel dismisses with null (scan not started)', (tester) async {
    bool? popped;
    await _pumpHost(tester, (context) async {
      popped = await showScanOptionsDialog(context, storage: _storage());
    });

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(popped, isNull);
  });

  testWidgets('confirm always starts a probe scan', (tester) async {
    bool? popped;
    await _pumpHost(tester, (context) async {
      popped = await showScanOptionsDialog(context, storage: _storage());
    });

    await tester.tap(find.text('开始扫描'));
    await tester.pumpAndSettle();

    expect(popped, isTrue);
  });

  // The legacy dialog is KEPT (not dead code) behind `kShowScanProbeOption`.
  // These assertions lock its restored behaviour so flipping the constant back
  // to `true` cannot silently resurrect a half-removed variant.
  group('legacy ScanOptionsDialog (kept for re-enabling)', () {
    testWidgets('always shows the checkbox and confirms its value',
        (tester) async {
      bool? popped;
      await _pumpHost(tester, (context) async {
        popped = await showDialog<bool>(
          context: context,
          builder: (_) => const ScanOptionsDialog(storageType: StorageType.internal),
        );
      });

      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(find.text('尝试读取媒体信息（时长 / 分辨率）'), findsOneWidget);

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始扫描'));
      await tester.pumpAndSettle();

      expect(popped, isFalse,
          reason: 'an unchecked box means "start without probing"');
    });

    testWidgets('cancel returns null', (tester) async {
      bool? popped;
      await _pumpHost(tester, (context) async {
        popped = await showDialog<bool>(
          context: context,
          builder: (_) => const ScanOptionsDialog(storageType: StorageType.internal),
        );
      });

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(popped, isNull);
    });
  });

  testWidgets('silent checkbox persists the completion prompt preference',
      (tester) async {
    final store = useRecursiveScanStore();
    // Fire-and-forget reset: state transitions are synchronous, while the KV
    // write rides a platform channel that never resolves under the test zone.
    unawaited(store.updateAutoClosePrompt(true));

    await _pumpHost(tester, (context) async {
      await showScanOptionsDialog(context, storage: _storage());
    });

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始扫描'));
    await tester.pumpAndSettle();

    expect(store.state.autoClosePrompt, isFalse,
        reason: 'checking "skip the countdown" must turn the prompt off');
  });
}
