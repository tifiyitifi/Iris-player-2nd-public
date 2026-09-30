import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/window/playlist_dock/fullscreen_playlist_dock_overlay.dart';

/// Fullscreen desktop bug: the one-handed side control panel is anchored to the
/// RIGHT edge — the very edge the playlist dock's summon strip covers — so
/// reaching for its slider revealed the queue on top of it ("想控制 side type
/// control bar 时会打开侧边 queue"). The strip must exclude the control bar's
/// live rect while the queue is hidden, and only while hidden: once the panel is
/// out it is drawn over the bar and shares its rect.

const double _w = 400;
const double _h = 300;
const double _panelW = 240;
const double _edgeW = 10;

/// The "control bar" stub: a block hugging the right edge, exactly like the
/// side panel in picture fullscreen.
const Rect _barRect = Rect.fromLTWH(_w - 120, _h - 140, 120, 140);

/// A point inside the summon strip AND inside the control bar.
const Offset _onBar = Offset(_w - 2, _h - 60);

/// A point inside the summon strip, clear of the control bar.
const Offset _clearOfBar = Offset(_w - 2, 40);

class _ControlBarHarness extends StatefulWidget {
  const _ControlBarHarness({
    required this.onEvent,
    this.barOffset = Offset.zero,
    this.isolationHeight = 0,
  });

  final void Function(String event) onEvent;

  /// Translates the bar away from the pointer, mimicking the control bar being
  /// hidden (the real one slides off-screen).
  final Offset barOffset;

  /// Control-bar isolation zone height, passed straight through.
  final double isolationHeight;

  @override
  State<_ControlBarHarness> createState() => _ControlBarHarnessState();
}

class _ControlBarHarnessState extends State<_ControlBarHarness> {
  final GlobalKey barKey = GlobalKey();
  final ValueNotifier<GlobalKey?> barKeyNotifier =
      ValueNotifier<GlobalKey?>(null);
  bool shown = false;

  @override
  void initState() {
    super.initState();
    barKeyNotifier.value = barKey;
  }

  @override
  void dispose() {
    barKeyNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: _w,
          height: _h,
          child: Stack(
            children: <Widget>[
              Positioned(
                left: _barRect.left,
                top: _barRect.top,
                width: _barRect.width,
                height: _barRect.height,
                child: Transform.translate(
                  offset: widget.barOffset,
                  child: ColoredBox(
                    key: barKey,
                    color: const Color(0xFF2A2A2A),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              FullscreenPlaylistDockOverlay(
                shown: shown,
                pinned: false,
                width: _panelW,
                edgeWidth: _edgeW,
                controlPanelKey: barKeyNotifier,
                controlBarIsolationHeight: widget.isolationHeight,
                onReveal: () {
                  widget.onEvent('reveal');
                  setState(() => shown = true);
                },
                onConceal: () {
                  widget.onEvent('conceal');
                  setState(() => shown = false);
                },
                child: const ColoredBox(
                  key: Key('dock_body'),
                  color: Color(0xFF1E1E1E),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

double _panelRight(WidgetTester tester) =>
    tester.getTopRight(find.byType(Material).last).dx;

void main() {
  group('fullscreen dock summon strip excludes the control bar', () {
    testWidgets('hovering the control bar does not summon the queue',
        (tester) async {
      final events = <String>[];
      await tester.pumpWidget(_ControlBarHarness(onEvent: events.add));
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(0, 0));
      await tester.pump();

      // Right-edge strip over the bar's slider area: the bar wins, no summon.
      await gesture.moveTo(_onBar);
      await tester.pumpAndSettle();
      expect(events, isEmpty);
      expect(_panelRight(tester), greaterThan(_w));

      // The same strip above the bar still summons.
      await gesture.moveTo(_clearOfBar);
      await tester.pumpAndSettle();
      expect(events, contains('reveal'));
      expect(_panelRight(tester), _w);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a revealed panel keeps working over the control bar',
        (tester) async {
      final events = <String>[];
      await tester.pumpWidget(_ControlBarHarness(onEvent: events.add));
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(0, 0));
      await tester.pump();

      await gesture.moveTo(_clearOfBar);
      await tester.pumpAndSettle();
      expect(events, contains('reveal'));

      // Down onto the bar's rect — still inside the shown region, so the panel
      // must stay (excluding it here would conceal it the moment it appeared).
      await gesture.moveTo(_onBar);
      await tester.pumpAndSettle();
      expect(events, isNot(contains('conceal')));
      expect(_panelRight(tester), _w);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a hidden (translated away) control bar frees the strip',
        (tester) async {
      final events = <String>[];
      await tester.pumpWidget(
        _ControlBarHarness(
          onEvent: events.add,
          // The bar slid off-screen: its rect can no longer contain the pointer.
          barOffset: const Offset(0, 400),
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(0, 0));
      await tester.pump();

      await gesture.moveTo(_onBar);
      await tester.pumpAndSettle();
      expect(events, contains('reveal'));
      expect(_panelRight(tester), _w);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no published control bar leaves the whole strip summonable',
        (tester) async {
      final events = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: _w,
              height: _h,
              child: FullscreenPlaylistDockOverlay(
                shown: false,
                pinned: false,
                width: _panelW,
                edgeWidth: _edgeW,
                onReveal: () => events.add('reveal'),
                onConceal: () => events.add('conceal'),
                child: const ColoredBox(
                  key: Key('dock_body'),
                  color: Color(0xFF1E1E1E),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(0, 0));
      await tester.pump();

      await gesture.moveTo(_onBar);
      await tester.pumpAndSettle();
      expect(events, contains('reveal'));
      expect(tester.takeException(), isNull);
    });
  });

  group('fullscreen dock summon strip honours the control-bar isolation zone',
      () {
    const double isolation = 30; // bottom 30 of the 300px area
    // Above the band (y < 270) and inside it (y >= 270) on the right edge.
    const Offset aboveBand = Offset(_w - 2, 250);
    const Offset inBand = Offset(_w - 2, 285);

    testWidgets('the band does not summon while hidden; above it does',
        (tester) async {
      final events = <String>[];
      await tester.pumpWidget(
        _ControlBarHarness(
          onEvent: events.add,
          // Bar off-screen so only the isolation zone can block.
          barOffset: const Offset(0, 400),
          isolationHeight: isolation,
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(0, 0));
      await tester.pump();

      await gesture.moveTo(inBand);
      await tester.pumpAndSettle();
      expect(events, isEmpty);
      expect(_panelRight(tester), greaterThan(_w));

      await gesture.moveTo(aboveBand);
      await tester.pumpAndSettle();
      expect(events, contains('reveal'));
      expect(_panelRight(tester), _w);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a shown panel over the band is not concealed', (tester) async {
      final events = <String>[];
      await tester.pumpWidget(
        _ControlBarHarness(
          onEvent: events.add,
          barOffset: const Offset(0, 400),
          isolationHeight: isolation,
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(0, 0));
      await tester.pump();

      await gesture.moveTo(aboveBand);
      await tester.pumpAndSettle();
      expect(events, contains('reveal'));

      // Into the band while shown: it shares the region, so it must stay.
      await gesture.moveTo(inBand);
      await tester.pumpAndSettle();
      expect(events, isNot(contains('conceal')));
      expect(_panelRight(tester), _w);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a zero isolation zone leaves the bottom band summonable',
        (tester) async {
      final events = <String>[];
      await tester.pumpWidget(
        _ControlBarHarness(
          onEvent: events.add,
          barOffset: const Offset(0, 400),
          isolationHeight: 0,
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(0, 0));
      await tester.pump();

      await gesture.moveTo(inBand);
      await tester.pumpAndSettle();
      expect(events, contains('reveal'));
      expect(_panelRight(tester), _w);
      expect(tester.takeException(), isNull);
    });
  });
}
