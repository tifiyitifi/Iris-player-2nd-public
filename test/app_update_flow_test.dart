import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/view/gated_update_check.dart';
import 'package:iris/features/app_update/view/show_update_result_dialog.dart';
import 'package:iris/features/app_update/view/update_flow.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Counts dialog routes, so "the checking window closed before the answer" is
/// assertable as two events rather than as whichever dialog happens to be up.
class _RouteCounter extends NavigatorObserver {
  int pushes = 0;
  int pops = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute) pushes++;
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute) pops++;
    super.didPop(route, previousRoute);
  }
}

/// Longer than the gate's delay, so the checking window is definitely up.
const _slow = Duration(milliseconds: 600);

/// Mounts the app with one "check update" row, the same entry point the About
/// page uses.
Widget _app(_RouteCounter counter, UpdateChecker check) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: [counter],
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => runUpdateCheckFlow(context, check: check),
              child: const Text('check'),
            ),
          ),
        ),
      ),
    );

/// The flow as a whole, not just the window: a check whose window nothing can
/// pop stranded the entire flow — "already up to date" included — on a spinner
/// forever, so reaching the answer has to be assertable without a human popping
/// anything.
void main() {
  late AppLocalizations t;

  setUpAll(() async {
    t = await AppLocalizations.delegate.load(const Locale('en'));
    // The flow reads the running version before it can check anything, and
    // `PackageInfo.fromPlatform` has no plugin behind it under `flutter_test`,
    // so the read never resolves. Mocked rather than awaited: this flow was
    // untestable end to end until now, which is how a window nothing could pop
    // shipped in the first place.
    PackageInfo.setMockInitialValues(
      appName: 'IRIS',
      packageName: 'com.iris',
      version: '2.0.6',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('a finished check hands its answer to the result dialog',
      (tester) async {
    final answering = Completer<UpdateCheckResult>();
    final counter = _RouteCounter();
    await tester.pumpWidget(
      _app(counter, ({required currentVersion}) => answering.future),
    );
    // Deferred l10n delegates load asynchronously — settle before tapping.
    await tester.pumpAndSettle();

    await tester.tap(find.text('check'));
    await tester.pump();
    await tester.pump(_slow);
    await tester.pump();
    expect(find.text(t.update_checking), findsOneWidget);
    expect(counter.pushes, 1);

    answering.complete(const UpToDate(version: '2.0.6'));
    // Nothing here dismisses the window: the gate owns it, and the answer is
    // reported only after that window is gone.
    await tester.pumpAndSettle();

    expect(find.text(t.update_checking), findsNothing);
    expect(find.text(t.update_result_up_to_date_title), findsOneWidget);
    // Checking window up, checking window down, answer up.
    expect(counter.pushes, 2);
    expect(counter.pops, 1);
  });

  testWidgets('a fast check goes straight to the answer, with no window flash',
      (tester) async {
    final counter = _RouteCounter();
    await tester.pumpWidget(
      _app(
        counter,
        ({required currentVersion}) async => const UpToDate(version: '2.0.6'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();

    expect(find.text(t.update_checking), findsNothing);
    expect(find.text(t.update_result_up_to_date_title), findsOneWidget);
    // Only the result dialog: the checking window never opened.
    expect(counter.pushes, 1);
    expect(counter.pops, 0);
  });

  testWidgets('a dismissed check window reports nothing at all', (tester) async {
    final answering = Completer<UpdateCheckResult>();
    final counter = _RouteCounter();
    await tester.pumpWidget(
      _app(counter, ({required currentVersion}) => answering.future),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('check'));
    await tester.pump();
    await tester.pump(_slow);
    await tester.pump();
    expect(find.text(t.update_checking), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(counter.pops, 1);

    // The check lands after the user walked away. Reporting it now would answer
    // a question nobody is holding, and re-open a window the user just closed.
    answering.complete(const UpToDate(version: '2.0.6'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(counter.pushes, 1);
  });

  testWidgets('a failed check ends in the failure dialog', (tester) async {
    final counter = _RouteCounter();
    await tester.pumpWidget(
      _app(
        counter,
        ({required currentVersion}) async =>
            const CheckFailed(UpdateFailure.network),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();

    expect(find.text(t.update_result_failed_title), findsOneWidget);
    expect(find.text(t.update_failed_network), findsOneWidget);
  });

  testWidgets('a retry re-runs the check instead of stacking a second window',
      (tester) async {
    var attempts = 0;
    final counter = _RouteCounter();
    await tester.pumpWidget(
      _app(counter, ({required currentVersion}) async {
        attempts++;
        return attempts == 1
            ? const CheckFailed(UpdateFailure.network)
            : const UpToDate(version: '2.0.7');
      }),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();
    expect(find.text(t.update_result_failed_title), findsOneWidget);

    await tester.tap(find.text(t.update_retry));
    await tester.pumpAndSettle();

    // The retry answered on its own seam, not the real GitHub, and the report
    // it opened replaced the one it was tapped in — never stacked on it.
    expect(attempts, 2);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(t.update_result_failed_title), findsNothing);
    expect(find.text(t.update_result_up_to_date_title), findsOneWidget);
    expect(counter.pushes, 2);
    expect(counter.pops, 1);
  });

  group('failure wording', () {
    Future<void> showFailure(WidgetTester tester, CheckFailed failure) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: buildUpdateResultDialog(context, failure),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // A status code carries no meaning to the reader, so 403 / 429 / 5xx each
    // get the sentence their own remedy calls for, and anything unrecognized
    // falls back rather than printing a number at someone.
    testWidgets('each kind of refusal gets its own advice', (tester) async {
      final cases = <int, String>{
        403: t.update_failed_forbidden,
        429: t.update_failed_rate_limited,
        500: t.update_failed_server_error,
        502: t.update_failed_server_error,
        599: t.update_failed_server_error,
        418: t.update_failed_http,
      };
      for (final entry in cases.entries) {
        await showFailure(
          tester,
          CheckFailed(UpdateFailure.http, detail: '${entry.key}'),
        );
        expect(find.text(entry.value), findsOneWidget,
            reason: 'status ${entry.key}');
      }
    });

    testWidgets('a page with no version explains itself without leaking the URL',
        (tester) async {
      await showFailure(
        tester,
        const CheckFailed(
          UpdateFailure.unreadableReleasePage,
          detail: 'https://github.com/login?return_to=%2Ftifiyiti',
        ),
      );

      expect(find.text(t.update_failed_unreadable_page), findsOneWidget);
      // The address is a log record, not something a reader can act on.
      expect(find.textContaining('github.com'), findsNothing);
      expect(find.textContaining('return_to'), findsNothing);
    });

    testWidgets('a page with no version is a failure, so the exits are open',
        (tester) async {
      await showFailure(
        tester,
        const CheckFailed(UpdateFailure.unreadableReleasePage),
      );

      // Without these, the user is told nothing worked and given no way to act.
      expect(find.text(t.update_result_failed_title), findsOneWidget);
      expect(find.text(t.releasePage), findsOneWidget);
      expect(find.text(t.update_copy_link), findsOneWidget);
    });
  });
}
