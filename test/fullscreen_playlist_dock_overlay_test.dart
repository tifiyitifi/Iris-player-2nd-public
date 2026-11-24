import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/window/playlist_dock/fullscreen_playlist_dock_overlay.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_dock.dart';

const double _harnessW = 400;
const double _harnessH = 300;
const double _panelW = 240;
const double _edgeW = 10;

class _OverlayHarness extends StatefulWidget {
  const _OverlayHarness({
    required this.shownInitially,
    required this.onEvent,
    this.child,
  });

  /// Seeds the caller-owned visibility, like `keepPanel` entering fullscreen.
  final bool shownInitially;
  final void Function(String event) onEvent;

  /// Panel body override; defaults to the plain dark box.
  final Widget? child;

  @override
  State<_OverlayHarness> createState() => _OverlayHarnessState();
}

class _OverlayHarnessState extends State<_OverlayHarness> {
  bool shown = false;

  @override
  void initState() {
    super.initState();
    shown = widget.shownInitially;
  }

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
            onReveal: () {
              widget.onEvent('reveal');
              setState(() => shown = true);
            },
            onConceal: () {
              widget.onEvent('conceal');
              setState(() => shown = false);
            },
            child: widget.child ??
                const ColoredBox(
                  key: Key('dock_body'),
                  color: Color(0xFF1E1E1E),
                ),
          ),
        ),
      ),
    );
  }
}

double _panelRight(WidgetTester tester) =>
    tester.getTopRight(find.byType(Material).last).dx;

void main() {
  group('fullscreen dock overlay hover peek', () {
    testWidgets('hidden -> edge hover reveals -> leave+margin hides',
        (tester) async {
      final events = <String>[];
      await tester.pumpWidget(
        _OverlayHarness(shownInitially: false, onEvent: events.add),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Hidden: the panel sits fully right of the viewport.
      expect(_panelRight(tester), greaterThan(_harnessW));
      expect(events, isEmpty);

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: const Offset(0, 0));
      await tester.pump();
      // Hover the 10px activation strip at the extreme right edge.
      await gesture.moveTo(const Offset(_harnessW - 1, 150));
      await tester.pumpAndSettle();
      expect(events, contains('reveal'));

      // Shown: panel right edge flush with the viewport.
      expect(_panelRight(tester), _harnessW);

      // Operate inside the panel — must stay shown, no conceal.
      await gesture.moveTo(const Offset(_harnessW - _panelW / 2, 150));
      await tester.pumpAndSettle();
      expect(events, isNot(contains('conceal')));
      expect(_panelRight(tester), _harnessW);

      // Leave past the panel + hide margin -> conceals once the debounce
      // elapses (the transient-exit guard; see kFullscreenDockConcealDelay).
      const double panelLeft = _harnessW - _panelW;
      await gesture.moveTo(
        Offset(panelLeft - kFullscreenDockHideMargin - 1, 150),
      );
      await tester.pump();
      await tester.pump(kFullscreenDockConcealDelay);
      await tester.pumpAndSettle();
      expect(events, contains('conceal'));
      expect(_panelRight(tester), greaterThan(_harnessW));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a panel seeded open (keepPanel) still conceals on hover-out',
        (tester) async {
      final events = <String>[];
      await tester.pumpWidget(
        _OverlayHarness(shownInitially: true, onEvent: events.add),
      );
      await tester.pumpAndSettle();
      expect(_panelRight(tester), _harnessW);

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: const Offset(300, 150));
      await tester.pump();
      // Move far left, out of the panel + margin.
      await gesture.moveTo(const Offset(0, 150));
      await tester.pump();
      await tester.pump(kFullscreenDockConcealDelay);
      await tester.pumpAndSettle();

      expect(events, contains('conceal'));
      expect(_panelRight(tester), greaterThan(_harnessW));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a panel revealed while the pointer is away conceals on the next move',
        (tester) async {
      // The queue key/button (or `keepPanel` on entry) can reveal the panel with
      // the pointer far from the right edge, so the activation strip never sees
      // it. The full-screen "away" watcher must still conceal it — otherwise the
      // panel could only be dismissed by Esc or a picture click.
      final events = <String>[];
      await tester.pumpWidget(
        _OverlayHarness(shownInitially: true, onEvent: events.add),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      // Pointer far left, never inside the strip or the panel.
      await gesture.addPointer(location: const Offset(20, 150));
      await tester.pump();
      await gesture.moveTo(const Offset(60, 160));
      await tester.pump();
      await tester.pump(kFullscreenDockConcealDelay);
      await tester.pumpAndSettle();

      expect(events, contains('conceal'));
      expect(_panelRight(tester), greaterThan(_harnessW));
      expect(tester.takeException(), isNull);
    });

    testWidgets('concealing the panel releases its keyboard focus',
        (tester) async {
      final panelNode = FocusNode(debugLabel: 'panel');
      addTearDown(panelNode.dispose);
      final events = <String>[];
      await tester.pumpWidget(
        _OverlayHarness(
          shownInitially: false,
          onEvent: events.add,
          child: Focus(
            focusNode: panelNode,
            child: const ColoredBox(
              key: Key('dock_body'),
              color: Color(0xFF1E1E1E),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Reveal the panel via the activation strip — only a shown panel may
      // take focus at all.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(0, 0));
      await tester.pump();
      await gesture.moveTo(const Offset(_harnessW - 1, 150));
      await tester.pumpAndSettle();
      expect(events, contains('reveal'));

      panelNode.requestFocus();
      await tester.pump();
      expect(panelNode.hasFocus, isTrue,
          reason: 'baseline — the revealed panel can hold focus');

      // Leave past the panel + hide margin → the panel slides off-screen.
      // It ignores pointers there (IgnorePointer) and must also let go of the
      // keyboard, otherwise ↑/↓ keep driving an invisible list.
      const double panelLeft = _harnessW - _panelW;
      await gesture.moveTo(
        Offset(panelLeft - kFullscreenDockHideMargin - 1, 150),
      );
      await tester.pump();
      await tester.pump(kFullscreenDockConcealDelay);
      await tester.pumpAndSettle();
      expect(events, contains('conceal'));

      expect(panelNode.hasFocus, isFalse,
          reason: 'a concealed panel must not keep keyboard ownership');
      expect(
        FocusManager.instance.primaryFocus?.ancestors.contains(panelNode),
        isNot(isTrue),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 360x640 phone width', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 640,
              child: FullscreenPlaylistDockOverlay(
                shown: true,
                width: 240,
                edgeWidth: 10,
                onReveal: _noop,
                onConceal: _noop,
                child: ColoredBox(
                  key: Key('dock_body'),
                  color: Color(0xFF1E1E1E),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dock_body')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

void _noop() {}
