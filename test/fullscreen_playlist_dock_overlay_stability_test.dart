import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/window/playlist_dock/fullscreen_playlist_dock_overlay.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_dock.dart';

// Regression coverage for the picture-fullscreen dock hover loop.
//
// Symptom (real device): with the cursor parked on the right edge / over the
// panel, the panel hid and re-showed continuously. Cause: the activation strip
// was only mounted while hidden, so as soon as a transient exit concealed the
// panel, a fresh edge strip appeared UNDER the stationary pointer and its
// `onEnter` re-revealed — forever. The hover zone must therefore be a single
// persistent region, and a transient leave must be debounced.

const double _harnessW = 400;
const double _harnessH = 300;
const double _panelW = 240;
const double _edgeW = 10;

class _StabilityHarness extends StatefulWidget {
  const _StabilityHarness({super.key, required this.onEvent});

  final void Function(String event) onEvent;

  @override
  State<_StabilityHarness> createState() => _StabilityHarnessState();
}

class _StabilityHarnessState extends State<_StabilityHarness> {
  bool shown = false;

  /// Simulates a conceal that did NOT originate from the pointer leaving the
  /// hover region (e.g. a layout/geometry transient inside the fullscreen
  /// player while the cursor is parked on the edge).
  void forceConceal() => setState(() => shown = false);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: _harnessW,
          height: _harnessH,
          child: FullscreenPlaylistDockOverlay(
            shown: shown,
            width: _panelW,
            edgeWidth: _edgeW,
            // Record state TRANSITIONS, not raw callback invocations: reveal
            // fires on both enter and hover in the same event, and the real
            // caller's store writes are equality-guarded anyway.
            onReveal: () {
              if (shown) return;
              widget.onEvent('reveal');
              setState(() => shown = true);
            },
            onConceal: () {
              if (!shown) return;
              widget.onEvent('conceal');
              setState(() => shown = false);
            },
            child: const ColoredBox(
              key: Key('dock_body'),
              color: Color(0xFF1E1E1E),
            ),
          ),
        ),
      ),
    );
  }
}

int _count(List<String> events, String needle) =>
    events.where((e) => e == needle).length;

Future<TestGesture> _parkAtRightEdge(WidgetTester tester, List<String> events) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: const Offset(0, 0));
  await tester.pump();
  await gesture.moveTo(const Offset(_harnessW - 1, _harnessH / 2));
  await tester.pumpAndSettle();
  expect(events, contains('reveal'));
  return gesture;
}

void main() {
  testWidgets(
      'a conceal while the cursor stays on the edge does not re-reveal (no hover loop)',
      (tester) async {
    final events = <String>[];
    final harnessKey = GlobalKey<_StabilityHarnessState>();
    await tester.pumpWidget(
      _StabilityHarness(key: harnessKey, onEvent: events.add),
    );
    await tester.pumpAndSettle();

    await _parkAtRightEdge(tester, events);
    expect(_count(events, 'reveal'), 1);

    // The cursor does not move; only the panel is forced hidden. A persistent
    // hover region still contains the pointer, so nothing may re-reveal.
    harnessKey.currentState!.forceConceal();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(_count(events, 'reveal'), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a brief leave past the margin is debounced, not concealed',
      (tester) async {
    final events = <String>[];
    final harnessKey = GlobalKey<_StabilityHarnessState>();
    await tester.pumpWidget(
      _StabilityHarness(key: harnessKey, onEvent: events.add),
    );
    await tester.pumpAndSettle();

    final gesture = await _parkAtRightEdge(tester, events);

    // Step just outside the panel + hide margin...
    const double panelLeft = _harnessW - _panelW;
    await gesture.moveTo(
      Offset(panelLeft - kFullscreenDockHideMargin - 1, _harnessH / 2),
    );
    // ...but return before the conceal debounce elapses.
    await tester.pump(const Duration(milliseconds: 80));
    expect(events, isNot(contains('conceal')));

    await gesture.moveTo(Offset(_harnessW - _panelW / 2, _harnessH / 2));
    await tester.pumpAndSettle();
    expect(events, isNot(contains('conceal')));

    harnessKey.currentState!.forceConceal();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'moving within the still-active edge region re-reveals after a stuck conceal',
      (tester) async {
    // When a conceal happens while the pointer never left the edge region, the
    // region keeps containing the pointer so MouseTracker never re-fires
    // onEnter. Movement within the region must wake the panel (onHover),
    // otherwise the user has to leave the region and come back.
    final events = <String>[];
    final harnessKey = GlobalKey<_StabilityHarnessState>();
    await tester.pumpWidget(
      _StabilityHarness(key: harnessKey, onEvent: events.add),
    );
    await tester.pumpAndSettle();

    final gesture = await _parkAtRightEdge(tester, events);
    expect(_count(events, 'reveal'), 1);

    // Conceal while the cursor stays parked on the edge: the shrunk region
    // still contains the pointer, so no exit/enter pair follows.
    harnessKey.currentState!.forceConceal();
    await tester.pumpAndSettle();
    expect(_count(events, 'reveal'), 1);

    // A few pixels of movement *within* the edge region must wake it again.
    await gesture.moveTo(const Offset(_harnessW - 3, _harnessH / 2));
    await tester.pumpAndSettle();
    expect(_count(events, 'reveal'), greaterThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a dialog barrier over the panel does not conceal it (pointer still inside)',
      (tester) async {
    // A video switch can raise a confirm/progress dialog whose ModalBarrier
    // sits above the dock. That steals the hover region and emits onExit even
    // though the pointer never left the panel. The panel must stay open; the
    // user tapped a row, they did not dismiss the queue.
    final events = <String>[];
    await tester.pumpWidget(_StabilityHarness(onEvent: events.add));
    await tester.pumpAndSettle();

    final gesture = await _parkAtRightEdge(tester, events);

    final ctx = tester.element(find.byType(FullscreenPlaylistDockOverlay));
    unawaited(showDialog<void>(
      context: ctx,
      builder: (_) => const AlertDialog(content: Text('switching...')),
    ));
    await tester.pump();
    await tester.pump(kFullscreenDockConcealDelay);
    await tester.pumpAndSettle();

    expect(events, isNot(contains('conceal')));

    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    await gesture.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('re-entering the hidden edge re-reveals after a conceal',
      (tester) async {
    final events = <String>[];
    await tester.pumpWidget(_StabilityHarness(onEvent: events.add));
    await tester.pumpAndSettle();

    final gesture = await _parkAtRightEdge(tester, events);

    // Conceal.
    const double panelLeft = _harnessW - _panelW;
    await gesture.moveTo(
      Offset(panelLeft - kFullscreenDockHideMargin - 1, _harnessH / 2),
    );
    await tester.pump();
    await tester.pump(kFullscreenDockConcealDelay);
    await tester.pumpAndSettle();
    expect(events, contains('conceal'));
    final int revealsBefore = _count(events, 'reveal');

    // Move back onto the hidden activation edge: must reveal again.
    await gesture.moveTo(const Offset(_harnessW - 1, _harnessH / 2));
    await tester.pumpAndSettle();
    expect(_count(events, 'reveal'), revealsBefore + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving past the margin conceals after the debounce',
      (tester) async {
    final events = <String>[];
    await tester.pumpWidget(_StabilityHarness(onEvent: events.add));
    await tester.pumpAndSettle();

    final gesture = await _parkAtRightEdge(tester, events);

    const double panelLeft = _harnessW - _panelW;
    await gesture.moveTo(
      Offset(panelLeft - kFullscreenDockHideMargin - 1, _harnessH / 2),
    );
    await tester.pump();
    await tester.pump(kFullscreenDockConcealDelay);
    await tester.pumpAndSettle();

    expect(events, contains('conceal'));
    expect(tester.takeException(), isNull);
  });
}
