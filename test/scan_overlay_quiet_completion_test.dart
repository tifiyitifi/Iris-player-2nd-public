import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/media_library/scan/view/scan_progress_overlay.dart';
import 'package:iris/l10n/app_localizations.dart';

/// A PLAYBACK-ORIGINATED scan (drag-drop auto-play, the gate's silent
/// increment) is not a task the user asked for — the panel only explains why
/// playback has not started yet. It therefore:
///   - stays hidden while the scan finishes inside [kQuietScanOverlayDelay];
///   - never shows a "closing in…" countdown once visible;
///   - is dismissed by the batch that started it, not by a timer.
///
/// A user-initiated scan keeps the old behaviour (see
/// scan_progress_overlay_lifecycle_test.dart).
///
/// Store mutations are NOT awaited for the same reason as in the lifecycle
/// test: their state transitions are synchronous `set()` calls, while the KV
/// `save()` rides a platform channel that never resolves inside the test
/// binding's FakeAsync zone.
void main() {
  setUp(() {
    useRecursiveScanStore().resetScan();
    ScanProgressOverlayManager.debugEntryMountedForTest = false;
  });

  Future<void> pumpManager(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      locale: Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ScanProgressOverlayManager()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a fast playback scan never draws a panel', (tester) async {
    final store = useRecursiveScanStore();
    await pumpManager(tester);

    store.startScan(
      storageId: 's1',
      depthPaths: {
        0: ['C:/a']
      },
      quietCompletion: true,
    );
    await tester.pump();
    expect(ScanProgressOverlayManager.debugEntryMountedForTest, isFalse,
        reason: 'quiet runs stay invisible inside the delay window');

    store.completeScan();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(store.state.phase, ScanPhase.done);
    expect(ScanProgressOverlayManager.debugEntryMountedForTest, isFalse,
        reason: 'a run that finished inside the delay must not flash a panel');

    // The batch's dismissal.
    store.resetScan();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(store.state.phase, ScanPhase.idle);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a slow playback scan shows progress but never counts down',
      (tester) async {
    final store = useRecursiveScanStore();
    await pumpManager(tester);

    store.startScan(
      storageId: 's1',
      depthPaths: {
        0: ['C:/a']
      },
      quietCompletion: true,
    );
    await tester.pump();
    await tester.pump(kQuietScanOverlayDelay + const Duration(milliseconds: 100));

    expect(ScanProgressOverlayManager.debugEntryMountedForTest, isTrue,
        reason: 'a run slower than the delay must show why playback waits');

    store.completeScan();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('Closing in'), findsNothing,
        reason: 'a playback-originated run must not auto-close');
    expect(ScanProgressOverlayManager.debugEntryMountedForTest, isTrue,
        reason: 'the panel stays until its batch dismisses it');

    store.resetScan();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(ScanProgressOverlayManager.debugEntryMountedForTest, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playback starting hides the panel while the run continues',
      (tester) async {
    final store = useRecursiveScanStore();
    await pumpManager(tester);

    store.startScan(
      storageId: 's1',
      depthPaths: {
        0: ['C:/a']
      },
      quietCompletion: true,
    );
    await tester.pump();
    await tester.pump(kQuietScanOverlayDelay + const Duration(milliseconds: 100));
    expect(ScanProgressOverlayManager.debugEntryMountedForTest, isTrue);

    // Playback resumed; the run's aggregate / metadata tail keeps going.
    store.dismissQuietPanel();
    await tester.pump();
    expect(store.state.phase, ScanPhase.scanning,
        reason: 'hiding the panel must not disturb the run');
    expect(ScanProgressOverlayManager.debugEntryMountedForTest, isFalse,
        reason: 'the panel must be off the video once playback starts');

    store.completeScan();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(ScanProgressOverlayManager.debugEntryMountedForTest, isFalse,
        reason: 'it must not come back for the completion either');

    store.resetScan();
    await tester.pump();
  });

  testWidgets('a chained quiet root stays hidden after playback started',
      (tester) async {
    final store = useRecursiveScanStore();
    await pumpManager(tester);

    store.startScan(
      storageId: 's1',
      depthPaths: {
        0: ['C:/a']
      },
      quietCompletion: true,
    );
    store.dismissQuietPanel();
    store.completeScan();
    await tester.pump();

    // Second root of the SAME drop: playback is already running, so the panel
    // must not cover the video again.
    store.startScan(
      storageId: 's1',
      depthPaths: {
        0: ['C:/b']
      },
      quietCompletion: true,
    );
    await tester.pump();
    await tester.pump(kQuietScanOverlayDelay + const Duration(milliseconds: 100));
    expect(store.quietPanelDone.value, isTrue);
    expect(ScanProgressOverlayManager.debugEntryMountedForTest, isFalse);

    // A NEW drop after the batch reset may show it again when it is slow.
    store.resetScan();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    store.startScan(
      storageId: 's1',
      depthPaths: {
        0: ['C:/c']
      },
      quietCompletion: true,
    );
    await tester.pump();
    await tester.pump(kQuietScanOverlayDelay + const Duration(milliseconds: 100));
    expect(store.quietPanelDone.value, isFalse);
    expect(ScanProgressOverlayManager.debugEntryMountedForTest, isTrue);

    store.resetScan();
    await tester.pump();
  });

  testWidgets('a playback scan that fails still shows the error',
      (tester) async {
    final store = useRecursiveScanStore();
    await pumpManager(tester);

    store.startScan(
      storageId: 's1',
      depthPaths: {
        0: ['C:/a']
      },
      quietCompletion: true,
    );
    await tester.pump();
    store.failScan('boom');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(ScanProgressOverlayManager.debugEntryMountedForTest, isTrue,
        reason: 'a failure must never be hidden from the user');
    expect(find.textContaining('boom'), findsWidgets);

    store.resetScan();
    await tester.pump();
  });
}
