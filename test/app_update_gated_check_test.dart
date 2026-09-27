import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/view/gated_update_check.dart';
import 'package:iris/l10n/app_localizations.dart';

/// Counts dialog routes, so "the spinner was closed" is assertable at all.
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

/// One check under test, plus what the flow's caller would end up holding.
class _Harness {
  _Harness(this.counter);

  final _RouteCounter counter;

  UpdateCheckResult? result;
  Object? error;
  var answered = false;

  int get pushes => counter.pushes;
  int get pops => counter.pops;
}

/// Longer than the gate's delay, so the window is definitely up.
const _slow = Duration(milliseconds: 600);

/// Mounts the app, starts one check from a tap and settles the first frame.
Future<_Harness> _startCheck(
  WidgetTester tester,
  UpdateChecker checker,
) async {
  final counter = _RouteCounter();
  final harness = _Harness(counter);

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
                try {
                  harness.result = await GatedUpdateCheck(
                    currentVersion: '2.0.6',
                    check: checker,
                  ).run(navigator: Navigator.of(context, rootNavigator: true));
                } catch (error) {
                  harness.error = error;
                }
                harness.answered = true;
              },
              child: const Text('check'),
            ),
          ),
        ),
      ),
    ),
  );
  // Deferred l10n delegates load asynchronously — settle before tapping.
  await tester.pumpAndSettle();
  await tester.tap(find.text('check'));
  await tester.pump();
  return harness;
}

/// The checking window used to be awaited with nothing able to pop it, which
/// stranded the entire flow — "already up to date" included — on a spinner.
void main() {
  late AppLocalizations t;

  setUpAll(() async {
    t = await AppLocalizations.delegate.load(const Locale('en'));
  });

  testWidgets('a slow check closes its window and hands the answer back',
      (tester) async {
    final answering = Completer<UpdateCheckResult>();
    final harness = await _startCheck(
      tester,
      ({required currentVersion}) => answering.future,
    );

    await tester.pump(_slow);
    await tester.pump();
    expect(find.text(t.update_checking), findsOneWidget);
    expect(harness.pushes, 1);

    answering.complete(const UpToDate(version: '2.0.6'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(harness.pushes, 1);
    expect(harness.pops, 1);
    expect(harness.answered, isTrue);
    expect(harness.result, isA<UpToDate>());
  });

  testWidgets('a fast check never opens a window', (tester) async {
    final harness = await _startCheck(
      tester,
      ({required currentVersion}) async => const UpToDate(version: '2.0.6'),
    );
    await tester.pumpAndSettle();

    expect(harness.pushes, 0);
    expect(harness.result, isA<UpToDate>());
  });

  testWidgets('a dismissed check drops its answer instead of reporting it',
      (tester) async {
    final answering = Completer<UpdateCheckResult>();
    final harness = await _startCheck(
      tester,
      ({required currentVersion}) => answering.future,
    );

    await tester.pump(_slow);
    await tester.pump();
    expect(find.text(t.update_checking), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(harness.pops, 1);
    expect(find.byType(AlertDialog), findsNothing);

    // The check lands after the user walked away: reporting it now would be
    // answering a question nobody is holding any more, and re-opening a window
    // on top of a route the user has since left.
    answering.complete(const UpToDate(version: '2.0.6'));
    await tester.pumpAndSettle();

    expect(harness.answered, isTrue);
    expect(harness.result, isNull);
    expect(harness.pushes, 1, reason: 'the dismissal must not be undone');
  });

  testWidgets('a throwing check still closes its window', (tester) async {
    final failing = Completer<UpdateCheckResult>();
    final harness = await _startCheck(
      tester,
      ({required currentVersion}) => failing.future,
    );

    await tester.pump(_slow);
    await tester.pump();
    expect(find.text(t.update_checking), findsOneWidget);
    expect(harness.pushes, 1);

    failing.completeError(StateError('the release source exploded'));
    await tester.pumpAndSettle();

    // The window is the one thing that can strand this flow, so unwinding has
    // to close it — and the failure still reaches the caller rather than being
    // swallowed on the way out.
    expect(harness.pushes, 1);
    expect(harness.pops, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(harness.answered, isTrue);
    expect(harness.error, isA<StateError>());
    expect(harness.result, isNull);
  });
}
