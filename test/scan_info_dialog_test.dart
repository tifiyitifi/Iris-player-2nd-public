import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/view/scan_info_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/storages/storage.dart';

Storage _storage() => Storage.local(
      type: StorageType.internal,
      name: 'Test storage',
      basePath: const <String>[],
    );

Future<void> _pumpDialog(
  WidgetTester tester, {
  String? rootPath,
  ScanInfoScope? scope,
}) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => ScanInfoDialog(
                storage: _storage(),
                rootPath: rootPath,
                scope: scope,
              ),
            ),
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
  testWidgets('storage scope names the storage and explains what is read',
      (tester) async {
    await _pumpDialog(tester);

    expect(find.text('扫描前说明'), findsOneWidget);
    expect(find.text('范围：整个存储「Test storage」，包含全部子目录。'), findsOneWidget);
    expect(find.textContaining('会读取目录结构'), findsOneWidget);
    expect(find.textContaining('不会修改、移动或删除任何文件'), findsOneWidget);
    expect(find.text('尝试读取媒体信息（时长 / 分辨率）'), findsNothing,
        reason: 'the explainer replaces the probe checkbox');
  });

  testWidgets('folder scope names the last path segment', (tester) async {
    await _pumpDialog(tester, rootPath: 'D:/media/Movies');

    expect(find.text('范围：目录「Movies」及其全部子目录。'), findsOneWidget);
  });

  testWidgets('batch scope does not pretend to be one storage', (tester) async {
    await _pumpDialog(tester, scope: ScanInfoScope.sources);

    expect(find.text('范围：本场景的全部来源目录及其子目录。'), findsOneWidget);
  });

  testWidgets('silent-completion checkbox is offered before the scan',
      (tester) async {
    await _pumpDialog(tester);

    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.text('取消扫描完成倒计时（静默完成）'), findsOneWidget);
    expect(find.textContaining('扫描一结束就关闭进度面板'), findsOneWidget);
  });
}
