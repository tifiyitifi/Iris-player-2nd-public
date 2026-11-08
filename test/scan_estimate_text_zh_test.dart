import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/view/scan_options_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/storages/storage.dart';

// NOTE: zh companion of scan_estimate_text_test.dart — one locale per file.
Future<AppLocalizations> loadZh(WidgetTester tester) async {
  late AppLocalizations t;
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(builder: (ctx) {
      t = AppLocalizations.of(ctx)!;
      return const SizedBox();
    }),
  ));
  await tester.pumpAndSettle();
  return t;
}

void main() {
  testWidgets('zh windows local states the header-parse cost',
      (tester) async {
    final t = await loadZh(tester);
    final s = scanProbeEstimateText(
        t: t,
        isWindows: true,
        isAndroid: false,
        storageType: StorageType.internal);
    expect(s, contains('1 毫秒'));
  });

  testWidgets('zh android local shows slower per-file range', (tester) async {
    final t = await loadZh(tester);
    final s = scanProbeEstimateText(
        t: t,
        isWindows: false,
        isAndroid: true,
        storageType: StorageType.internal);
    expect(s, contains('50–200ms'));
  });

  testWidgets('zh network storages state that probing stays in the background',
      (tester) async {
    final t = await loadZh(tester);
    for (final type in [
      StorageType.ftp,
      StorageType.webdav,
      StorageType.network
    ]) {
      final s = scanProbeEstimateText(
          t: t, isWindows: true, isAndroid: false, storageType: type);
      expect(s, contains('后台'));
    }
  });

  testWidgets('zh platforms without a probe fall back to playback backfill',
      (tester) async {
    final t = await loadZh(tester);
    final s = scanProbeEstimateText(
        t: t,
        isWindows: false,
        isAndroid: false,
        storageType: StorageType.internal);
    expect(s, contains('播放时'));
  });
}
