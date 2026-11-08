import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/media_library/scan/view/scan_progress_overlay.dart';
import 'package:iris/l10n/app_localizations.dart';

/// A manual scan that fails must announce itself with a dialog exactly once;
/// a playback-originated (quiet) run must not interrupt the video with one.
void main() {
  Future<void> pumpManager(WidgetTester tester) async {
    // Fresh store per test: a leftover `error` phase would (correctly) pop the
    // failure dialog at mount and pollute the assertions below.
    useRecursiveScanStore().set(const RecursiveScanState());
    await tester.pumpWidget(const MaterialApp(
      locale: Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ScanProgressOverlayManager()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('manual scan failure shows exactly one dialog', (tester) async {
    final store = useRecursiveScanStore();
    await pumpManager(tester);

    store.startScan(storageId: 's1', depthPaths: {0: ['C:/a']});
    await tester.pump();
    unawaited(store.failScan('boom'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('Scan failed'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);

    // Extra store ticks must not stack a second dialog.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing,
        reason: 'acknowledging must not schedule another dialog');
    expect(store.state.phase, ScanPhase.error);
  });

  testWidgets('quiet (playback-originated) failure never opens a dialog',
      (tester) async {
    final store = useRecursiveScanStore();
    await pumpManager(tester);

    store.startScan(
      storageId: 's2',
      depthPaths: {0: ['C:/b']},
      quietCompletion: true,
    );
    await tester.pump();
    unawaited(store.failScan('boom'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    // The floating panel still reports it — the reason is never hidden.
    expect(find.textContaining('boom'), findsOneWidget);
  });
}
