import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/widgets/dialogs/delayed_progress_gate.dart';

/// Counts dialog routes so "the failure reused the progress route" is
/// assertable — a pop + push would show up as pushes == 2.
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

const _delay = Duration(milliseconds: 400);

Widget _app(_RouteCounter counter, Widget child) => MaterialApp(
      navigatorObservers: [counter],
      home: Scaffold(body: child),
    );

/// The delay gate exists so a run that finishes inside [delay] costs the user
/// nothing: no route, no build, no flash. A run slower than [delay] must show
/// the surface, and a failure must reuse that same route.
void main() {
  testWidgets('a run faster than the delay never mounts a window',
      (tester) async {
    final counter = _RouteCounter();
    final gate = DelayedProgressGate(delay: _delay);
    var opened = false;

    await tester.pumpWidget(_app(
      counter,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            gate.arm(
              navigator: Navigator.of(context, rootNavigator: true),
              builder: (_) => const AlertDialog(content: Text('working')),
            );
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await gate.succeed();
            opened = true;
          },
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();
    // Well past the 50 ms the work needs, but still inside the delay window:
    // succeed() must cancel the timer before it can ever fire.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(opened, isTrue);
    expect(counter.pushes, 0);
    expect(gate.isVisible, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    gate.dispose();
  });

  testWidgets('a slow run shows the surface and dismisses it on success',
      (tester) async {
    final counter = _RouteCounter();
    final gate = DelayedProgressGate(delay: _delay);
    var opened = false;

    await tester.pumpWidget(_app(
      counter,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            gate.arm(
              navigator: Navigator.of(context, rootNavigator: true),
              builder: (_) => const AlertDialog(content: Text('working')),
            );
            await Future<void>.delayed(const Duration(milliseconds: 600));
            await gate.succeed();
            opened = true;
          },
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(_delay + const Duration(milliseconds: 1));
    await tester.pump();

    expect(find.text('working'), findsOneWidget);
    expect(gate.isVisible, isTrue);
    expect(gate.cancelled, isFalse);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(opened, isTrue);
    expect(gate.isVisible, isFalse);
    // A success is never a cancellation: the caller may navigate on.
    expect(gate.cancelled, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    expect(counter.pushes, 1);
    expect(counter.pops, 1);
    gate.dispose();
  });

  testWidgets('a slow failure morphs on the progress route, never a new one',
      (tester) async {
    final counter = _RouteCounter();
    final gate = DelayedProgressGate(delay: _delay);
    String? chosen;

    await tester.pumpWidget(_app(
      counter,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            gate.arm(
              navigator: Navigator.of(context, rootNavigator: true),
              builder: (_) => const AlertDialog(content: Text('working')),
            );
            await Future<void>.delayed(const Duration(milliseconds: 600));
            chosen = await gate.fail<String>(
              failureBuilder: (ctx) => AlertDialog(
                content: const Text('failed'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, 'retry'),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          },
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(_delay + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('working'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(find.text('working'), findsNothing);
    expect(find.text('failed'), findsOneWidget);
    expect(counter.pushes, 1,
        reason: 'the failure must take over the progress route');
    expect(counter.pops, 0);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(chosen, 'retry');
    expect(counter.pushes, 1);
    expect(counter.pops, 1);
    expect(gate.cancelled, isFalse);
    gate.dispose();
  });

  testWidgets('a fast failure opens the failure surface with no progress flash',
      (tester) async {
    final counter = _RouteCounter();
    final gate = DelayedProgressGate(delay: _delay);
    String? chosen;

    await tester.pumpWidget(_app(
      counter,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            gate.arm(
              navigator: Navigator.of(context, rootNavigator: true),
              builder: (_) => const AlertDialog(content: Text('working')),
            );
            await Future<void>.delayed(const Duration(milliseconds: 50));
            chosen = await gate.fail<String>(
              failureBuilder: (ctx) => AlertDialog(
                content: const Text('failed'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, 'edit'),
                    child: const Text('Edit'),
                  ),
                ],
              ),
            );
          },
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.text('working'), findsNothing);
    expect(find.text('failed'), findsOneWidget);
    expect(counter.pushes, 1);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(chosen, 'edit');
    gate.dispose();
  });

  testWidgets('dismissing the surface cancels: no re-push, no phantom success',
      (tester) async {
    final counter = _RouteCounter();
    final gate = DelayedProgressGate(delay: _delay);

    await tester.pumpWidget(_app(
      counter,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            gate.arm(
              navigator: Navigator.of(context, rootNavigator: true),
              builder: (ctx) => AlertDialog(
                content: const Text('working'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 600));
            // The work lands after the user gave up: a terminal call on an
            // already-dismissed gate must be inert, never a second window.
            await gate.succeed();
          },
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(_delay + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('working'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(gate.cancelled, isTrue);
    expect(gate.isVisible, isFalse);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(gate.cancelled, isTrue);
    expect(counter.pushes, 1);
    expect(counter.pops, 1);
    expect(find.byType(AlertDialog), findsNothing);
    gate.dispose();
  });

  testWidgets('dispose without a terminal call asserts — that is the tripwire',
      (tester) async {
    // The assert is the only thing standing between a forgotten terminal call
    // and a spinner nobody can get rid of, so it is pinned rather than trusted.
    // What it does NOT do is close anything: the body only releases, which is
    // why an abandoning caller has to say so through cancel() first.
    final counter = _RouteCounter();
    final gate = DelayedProgressGate(delay: _delay);

    await tester.pumpWidget(_app(
      counter,
      Builder(
        builder: (context) => TextButton(
          onPressed: () {
            gate.arm(
              navigator: Navigator.of(context, rootNavigator: true),
              builder: (_) => const AlertDialog(content: Text('working')),
            );
          },
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(_delay + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('working'), findsOneWidget);

    expect(() => gate.dispose(), throwsA(isA<AssertionError>()));
    expect(find.text('working'), findsOneWidget,
        reason: 'dispose() releases, it never pops a live surface');

    await gate.succeed();
    gate.dispose();
  });

  testWidgets('an abandoned surface is taken down, not left standing',
      (tester) async {
    // The caller walked away mid-connect: the popup hosting it is gone, but the
    // surface was pushed on the ROOT navigator, so nothing about that dismissal
    // closes it. cancel() is the terminal that does.
    final counter = _RouteCounter();
    final gate = DelayedProgressGate(delay: _delay);

    await tester.pumpWidget(_app(
      counter,
      Builder(
        builder: (context) => TextButton(
          onPressed: () {
            gate.arm(
              navigator: Navigator.of(context, rootNavigator: true),
              builder: (_) => const AlertDialog(content: Text('working')),
            );
          },
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(_delay + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('working'), findsOneWidget);

    await gate.cancel();
    await tester.pumpAndSettle();
    gate.dispose();

    expect(counter.pushes, 1);
    expect(counter.pops, 1);
    expect(find.byType(AlertDialog), findsNothing);
    // The caller's own route is still standing.
    expect(find.text('go'), findsOneWidget);
    // An abandon is the caller's decision, not the user's: reporting it as
    // cancelled would poison the stillWanted checks that read the same flag.
    expect(gate.cancelled, isFalse);
  });

  testWidgets('a cancelled surface that never materialised is silent',
      (tester) async {
    // The fast abandon: nothing was ever pushed, so the terminal has to stay
    // just as invisible.
    final counter = _RouteCounter();
    final gate = DelayedProgressGate(delay: _delay);

    await tester.pumpWidget(_app(
      counter,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            gate.arm(
              navigator: Navigator.of(context, rootNavigator: true),
              builder: (_) => const AlertDialog(content: Text('working')),
            );
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await gate.cancel();
            gate.dispose();
          },
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(counter.pushes, 0);
    expect(counter.pops, 0);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('cancel after the user dismissed pops once, and the caller lives',
      (tester) async {
    // The two exits meet: the user already closed the surface, so the abandon
    // that lands right after must be inert. A second pop here would take the
    // caller's own route with it.
    final counter = _RouteCounter();
    final gate = DelayedProgressGate(delay: _delay);

    await tester.pumpWidget(_app(
      counter,
      Builder(
        builder: (context) => TextButton(
          onPressed: () {
            gate.arm(
              navigator: Navigator.of(context, rootNavigator: true),
              builder: (ctx) => AlertDialog(
                content: const Text('working'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            );
          },
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(_delay + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('working'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(gate.cancelled, isTrue);

    await gate.cancel();
    await tester.pumpAndSettle();
    gate.dispose();

    expect(counter.pushes, 1);
    expect(counter.pops, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('go'), findsOneWidget);
  });

  testWidgets('a terminal call in the same turn as a dismissal pops once',
      (tester) async {
    // The exact hazard: the work settles in the same turn as the dismissal,
    // before the dismissed route's future has reported back. A gate that reads
    // "still visible" there pops a second time — and the second pop takes the
    // caller's own route with it.
    final counter = _RouteCounter();
    final gate = DelayedProgressGate(delay: _delay);

    await tester.pumpWidget(_app(
      counter,
      Builder(
        builder: (context) => TextButton(
          onPressed: () {
            gate.arm(
              navigator: Navigator.of(context, rootNavigator: true),
              builder: (ctx) => AlertDialog(
                content: const Text('working'),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      gate.succeed();
                    },
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            );
          },
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(_delay + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('working'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(counter.pushes, 1);
    expect(counter.pops, 1);
    expect(gate.cancelled, isTrue);
    // The caller's own route is still standing.
    expect(find.text('go'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    gate.dispose();
  });
}
