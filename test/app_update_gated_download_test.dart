import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/features/app_update/services/update_downloader.dart';
import 'package:iris/features/app_update/view/gated_update_download.dart';
import 'package:iris/l10n/app_localizations.dart';

/// Counts dialog routes, so "the failure reused the progress window" and "the
/// window was closed at all" are both assertable — a pop + push would show up
/// as two pushes.
class _RouteCounter extends NavigatorObserver {
  _RouteCounter({this.onDialogPop});

  /// Runs synchronously inside `Navigator.pop`, which is what makes a cancel
  /// that lands *while the window closes* reproducible: the pop the gate makes
  /// on success is itself the moment such a cancel arrives, and no amount of
  /// pumping reproduces it, because the window is already pointer-ignored by
  /// then (see `DelayedProgressGate`'s own close).
  final void Function()? onDialogPop;

  int pushes = 0;
  int pops = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute) pushes++;
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute) {
      pops++;
      onDialogPop?.call();
    }
    super.didPop(route, previousRoute);
  }
}

/// One transfer under test, plus what the flow's caller would end up holding.
class _Harness {
  _Harness(this._counter, this.downloader);

  final _RouteCounter _counter;
  final AssetDownloader downloader;

  GatedUpdateDownload? download;
  File? result;

  int get pushes => _counter.pushes;
  int get pops => _counter.pops;
  bool get cancelled => download?.cancelled ?? false;
}

const _asset = ReleaseAsset(
  name: 'IRIS-android-universal-v2.0.7.apk',
  downloadUrl: 'https://example.invalid/IRIS.apk',
  size: 2 << 20,
);

/// Longer than the gate's delay, so the window is definitely up.
const _slow = Duration(milliseconds: 600);

/// Longer than [_slow], for a fake that must still be busy when the window is
/// first looked at.
const _dial = Duration(milliseconds: 900);

/// A completed-but-cancelled transfer has to hand back null, so a run needs a
/// real file to (not) return.
File _packageIn(Directory directory) =>
    File('${directory.path}/${_asset.name}')..writeAsStringSync('package');

/// Lets real file I/O the run started finish, then flushes what it queued.
///
/// Deleting the abandoned package is real work: it only completes outside the
/// test's fake clock, and its continuation is a microtask the fake zone holds
/// until the next pump.
Future<void> _settleRealIo(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

/// Mounts the app, starts one transfer from a tap and settles the first frame.
Future<_Harness> _startTransfer(
  WidgetTester tester,
  AssetDownloader downloader, {
  void Function(_Harness harness)? onDialogPop,
  bool Function()? stillWanted,
}) async {
  late final _Harness harness;
  final counter = _RouteCounter(
    onDialogPop: onDialogPop == null ? null : () => onDialogPop(harness),
  );
  harness = _Harness(counter, downloader);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: [counter],
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                harness.download = GatedUpdateDownload(
                  asset: _asset,
                  downloader: downloader,
                  stillWanted: stillWanted,
                );
                harness.result = await harness.download!.run(
                  navigator: Navigator.of(context, rootNavigator: true),
                );
              },
              child: const Text('start'),
            ),
          ),
        ),
      ),
    ),
  );
  // Deferred l10n delegates load asynchronously — settle before tapping.
  await tester.pumpAndSettle();
  await tester.tap(find.text('start'));
  await tester.pump();
  return harness;
}

void main() {
  late AppLocalizations t;

  setUpAll(() async {
    t = await AppLocalizations.delegate.load(const Locale('en'));
  });

  testWidgets('a slow transfer opens one window and closes it on success',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('iris-gated');
    addTearDown(() => directory.deleteSync(recursive: true));
    final package = _packageIn(directory);
    final release = Completer<void>();

    final harness = await _startTransfer(
      tester,
      ({required asset, expectedSha256, onProgress, onAbort}) async {
        onProgress!((received: 1 << 20, total: asset.size));
        await release.future;
        return package;
      },
    );

    await tester.pump(_slow);
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(harness.pushes, 1);

    release.complete();
    await tester.pumpAndSettle();

    // The point of the fix: a finished download must not sit on a frozen 100%
    // bar waiting for a Cancel that only it could justify.
    expect(find.byType(AlertDialog), findsNothing);
    expect(harness.pushes, 1);
    expect(harness.pops, 1);
    expect(harness.cancelled, isFalse);
    expect(harness.result, package);
  });

  testWidgets('a fast transfer never opens a window', (tester) async {
    final directory = Directory.systemTemp.createTempSync('iris-gated');
    addTearDown(() => directory.deleteSync(recursive: true));
    final package = _packageIn(directory);

    final harness = await _startTransfer(
      tester,
      ({required asset, expectedSha256, onProgress, onAbort}) async => package,
    );
    await tester.pumpAndSettle();

    expect(harness.pushes, 0);
    expect(find.byType(AlertDialog), findsNothing);
    expect(harness.result, package);
  });

  testWidgets('a failure takes over the same window instead of stacking one',
      (tester) async {
    final harness = await _startTransfer(
      tester,
      ({required asset, expectedSha256, onProgress, onAbort}) async {
        await Future<void>.delayed(_slow);
        throw const UpdateDownloadException(DownloadFailure.interrupted);
      },
    );

    await tester.pump(_slow);
    await tester.pump();
    expect(harness.pushes, 1);

    await tester.pumpAndSettle();

    // One window throughout: the progress content gave way to the report, and
    // the transfer reported at all instead of leaving the bar up forever.
    expect(harness.pushes, 1);
    expect(harness.pops, 0);
    expect(find.text(t.update_download_interrupted), findsOneWidget);

    await tester.tap(find.text(t.cancel));
    await tester.pumpAndSettle();
    expect(harness.pops, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(harness.result, isNull);
  });

  testWidgets('a refusal is reported as the refusal it was', (tester) async {
    final harness = await _startTransfer(
      tester,
      ({required asset, expectedSha256, onProgress, onAbort}) async {
        await Future<void>.delayed(_slow);
        throw const UpdateDownloadException(
          DownloadFailure.http,
          detail: '429',
        );
      },
    );

    await tester.pump(_slow);
    await tester.pump();
    await tester.pumpAndSettle();

    // The status decides the sentence: being throttled, turned away and GitHub
    // being broken are three different things, and retrying a 429 sooner only
    // lengthens the wait.
    expect(find.text(t.update_failed_rate_limited), findsOneWidget);
    expect(find.text(t.update_download_interrupted), findsNothing);
    expect(harness.pushes, 1);
  });

  testWidgets('a package the disk refused is not blamed on the network',
      (tester) async {
    final harness = await _startTransfer(
      tester,
      ({required asset, expectedSha256, onProgress, onAbort}) async {
        await Future<void>.delayed(_slow);
        throw const UpdateDownloadException(
          DownloadFailure.storage,
          detail: 'no space left on device',
        );
      },
    );

    await tester.pump(_slow);
    await tester.pump();
    await tester.pumpAndSettle();

    // "Check that you are online" is the one sentence that cannot help someone
    // whose disk is full.
    expect(find.text(t.update_download_not_writable), findsOneWidget);
    expect(find.text(t.update_failed_network), findsNothing);
    expect(harness.pushes, 1);
  });

  testWidgets('cancel aborts the transfer and drops the package it produced',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('iris-gated');
    addTearDown(() => directory.deleteSync(recursive: true));
    // The transfer finished writing its file anyway, on its way out.
    final package = _packageIn(directory);
    final aborted = Completer<void>();
    var aborts = 0;

    final harness = await _startTransfer(
      tester,
      ({required asset, expectedSha256, onProgress, onAbort}) async {
        onAbort!(() {
          aborts++;
          if (!aborted.isCompleted) aborted.complete();
        });
        onProgress!((received: 512, total: asset.size));
        await aborted.future;
        return package;
      },
    );

    await tester.pump(_slow);
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text(t.cancel));
    await tester.pumpAndSettle();

    // The stop reached the transfer, so nothing is still being pulled in behind
    // a window the user already closed.
    expect(aborts, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(harness.cancelled, isTrue);

    // Real file I/O: the abandoned package is deleted, so no installer can pick
    // it up, and a cancelled run hands back nothing to install.
    await _settleRealIo(tester);
    expect(package.existsSync(), isFalse);
    expect(harness.result, isNull);
  });

  testWidgets('a cancel that lands while the window closes drops the package',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('iris-gated');
    addTearDown(() => directory.deleteSync(recursive: true));
    final package = _packageIn(directory);
    final release = Completer<void>();
    var cancels = 0;

    // The user gives up in the gap the success path opens for them: the transfer
    // has already verified and returned its package, and the only thing left is
    // the window going away. On a device that gap is the close animation, and a
    // press that was already in flight when the transfer finished resolves
    // inside it — long after the cancel flag was read.
    final harness = await _startTransfer(
      tester,
      ({required asset, expectedSha256, onProgress, onAbort}) async {
        onProgress!((received: 1 << 20, total: asset.size));
        await release.future;
        return package;
      },
      onDialogPop: (started) {
        cancels++;
        started.download!.stop();
      },
    );

    await tester.pump(_slow);
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    release.complete();
    await tester.pumpAndSettle();

    // The cancel did arrive, and it arrived after the entry check had already
    // decided this was a success.
    expect(cancels, 1);
    expect(harness.cancelled, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(harness.pops, 1);

    // Cancel still means cancel: nothing is installed and nothing is left for an
    // installer to pick up, even though the package was complete and verified
    // by the time the user let go.
    expect(harness.result, isNull);
    await _settleRealIo(tester);
    expect(package.existsSync(), isFalse);
  });

  testWidgets('a caller that walked away drops the package it verified',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('iris-gated');
    addTearDown(() => directory.deleteSync(recursive: true));
    final package = _packageIn(directory);
    final release = Completer<void>();
    // The caller is gone for good before the transfer is even finished: its own
    // route is gone, so there is nothing left to install through.
    var wanted = false;

    final harness = await _startTransfer(
      tester,
      ({required asset, expectedSha256, onProgress, onAbort}) async {
        onProgress!((received: 1 << 20, total: asset.size));
        await release.future;
        return package;
      },
      stillWanted: () => wanted,
    );

    await tester.pump(_slow);
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    release.complete();
    await tester.pumpAndSettle();

    // Nobody is left to install it, so the run reports nothing at all and the
    // package goes the way every other unwanted one does.
    expect(harness.result, isNull);
    expect(find.byType(AlertDialog), findsNothing);
    await _settleRealIo(tester);
    expect(package.existsSync(), isFalse);
  });

  testWidgets('a caller that leaves while the window closes drops the package',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('iris-gated');
    addTearDown(() => directory.deleteSync(recursive: true));
    final package = _packageIn(directory);
    final release = Completer<void>();
    // The gap the success path opens for a dismissal, one level up: the caller
    // is still there for the transfer and gone by the time the window is down.
    // On a device that is the close animation — a back press, an Esc — landing
    // inside it, after the pop that already made this run a success, so the
    // cancel flag is never set and only the caller can say no.
    var wanted = true;

    final harness = await _startTransfer(
      tester,
      ({required asset, expectedSha256, onProgress, onAbort}) async {
        onProgress!((received: 1 << 20, total: asset.size));
        await release.future;
        return package;
      },
      onDialogPop: (_) => wanted = false,
      stillWanted: () => wanted,
    );

    await tester.pump(_slow);
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    release.complete();
    await tester.pumpAndSettle();

    // Not a cancel: the user never said no, so the run's own cancel flag stays
    // clear and the only thing that ended it is the caller.
    expect(harness.cancelled, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    expect(harness.pushes, 1);
    expect(harness.pops, 1);

    // Nothing is installed, and nothing is left on disk for an installer to pick
    // up: a package nobody can use is dropped exactly like a cancelled one.
    expect(harness.result, isNull);
    await _settleRealIo(tester);
    expect(package.existsSync(), isFalse);
  });

  testWidgets('a cancel that beats the transfer still aborts it',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('iris-gated');
    addTearDown(() => directory.deleteSync(recursive: true));
    final package = _packageIn(directory);
    var aborts = 0;

    final harness = await _startTransfer(
      tester,
      ({required asset, expectedSha256, onProgress, onAbort}) async {
        onProgress!((received: 1, total: asset.size));
        // Still dialling: the window is up and cancellable before the transfer
        // has handed over any way to stop it.
        await Future<void>.delayed(_dial);
        onAbort!(() => aborts++);
        return package;
      },
    );

    await tester.pump(_slow);
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text(t.cancel));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    // The handle arrives after the cancel and has to be used at once.
    await tester.pump(_dial);
    await _settleRealIo(tester);
    expect(aborts, 1);
    expect(harness.cancelled, isTrue);
    expect(harness.result, isNull);
  });
}
