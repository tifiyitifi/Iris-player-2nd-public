import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/media_library/scan/view/scan_progress_overlay.dart';
import 'package:iris/l10n/app_localizations.dart';

/// Silent completion: with the countdown disabled the panel must disappear the
/// moment the scan settles, without ever rendering a countdown.
void main() {
  Future<void> pumpManager(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      locale: Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ScanProgressOverlayManager()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('countdown disabled → panel closes immediately, no countdown',
      (tester) async {
    final store = useRecursiveScanStore();
    // Fire-and-forget: `set()` is synchronous, the KV save is not awaited
    // because its platform channel never resolves inside the test zone.
    unawaited(store.updateAutoClosePrompt(false));
    await pumpManager(tester);

    store.startScan(storageId: 's1', depthPaths: {0: ['C:/a']});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    store.completeScan();
    // Give the store listener + post-frame close a couple of frames.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Closing in'), findsNothing,
        reason: 'silent completion must not render a countdown');
    expect(store.state.phase, ScanPhase.idle,
        reason: 'the panel must reset as soon as the scan settles');
  });

  testWidgets('countdown enabled → the same run still counts down',
      (tester) async {
    final store = useRecursiveScanStore();
    unawaited(store.updateAutoClosePrompt(true));
    await pumpManager(tester);

    store.startScan(storageId: 's2', depthPaths: {0: ['C:/b']});
    await tester.pump();
    store.completeScan();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('Closing in'), findsOneWidget);
    expect(store.state.phase, ScanPhase.done,
        reason: 'the countdown keeps the panel up until the delay elapses');
  });
}
