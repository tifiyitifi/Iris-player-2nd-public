import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/view/scan_options_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/storages/storage.dart';

// NOTE: zh cases live apart (see scan_estimate_text_zh_test.dart) — one
// locale per file, since flutter test cannot reliably load a second deferred
// l10n chunk after another locale ran in the same file.
Future<AppLocalizations> loadEn(WidgetTester tester) async {
  late AppLocalizations t;
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
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

/// The scan dialog shows an immediately-visible, platform- and
/// storage-aware time estimate (no pre-count wait): general-case magnitudes
/// so users know what they signed up for before pressing start.
void main() {
  testWidgets('windows local states the header-parse cost', (tester) async {
    final t = await loadEn(tester);
    final s = scanProbeEstimateText(
        t: t,
        isWindows: true,
        isAndroid: false,
        storageType: StorageType.internal);
    expect(s, contains('1 ms'));
  });

  testWidgets('android local states the header-parse cost first', (tester) async {
    final t = await loadEn(tester);
    final s = scanProbeEstimateText(
        t: t,
        isWindows: false,
        isAndroid: true,
        storageType: StorageType.internal);
    // Local containers are parsed from their header (~1 ms); only the rest
    // falls back to the system prober, so the old "50–200 ms per file" is no
    // longer the headline number.
    expect(s, contains('1 ms'));
    expect(s, contains('50–200 ms'));
  });

  testWidgets('network storages state that probing stays in the background',
      (tester) async {
    final t = await loadEn(tester);
    for (final type in [
      StorageType.ftp,
      StorageType.webdav,
      StorageType.network
    ]) {
      final s = scanProbeEstimateText(
          t: t, isWindows: true, isAndroid: false, storageType: type);
      expect(s, contains('background'));
    }
  });

  testWidgets('platforms without a probe fall back to playback backfill',
      (tester) async {
    final t = await loadEn(tester);
    final s = scanProbeEstimateText(
        t: t,
        isWindows: false,
        isAndroid: false,
        storageType: StorageType.internal);
    expect(s, contains('backfill'));
  });
}
