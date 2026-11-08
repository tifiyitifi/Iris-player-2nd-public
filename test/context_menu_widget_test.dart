import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/player.dart';
import 'package:iris/pages/player/overlays/gesture_overlay.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

Widget _providerScope(Widget child) {
  return InheritedProvider<StoreLocator>.value(
    value: StoreLocator(),
    startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
      final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
      return sub.cancel;
    },
    lazy: false,
    child: child,
  );
}

MediaPlayer _fakePlayer() => MediaPlayer(
      isInitializing: false,
      isPlaying: true,
      externalSubtitles: const [],
      position: Duration.zero,
      duration: const Duration(minutes: 10),
      buffer: Duration.zero,
      width: 1280,
      height: 720,
      saveProgress: () async {},
      play: () async {},
      pause: () async {},
      backward: (_) async {},
      forward: (_) async {},
      stepBackward: () async {},
      stepForward: () async {},
      seek: (_) async {},
    );

Widget _harness({required MediaPlayer player}) {
  return _providerScope(
    Provider<MediaPlayer>.value(
      value: player,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox.expand(
            child: GestureOverlay(
              showControl: () {},
              hideControl: () {},
              showProgress: () {},
              showControlForHover: (cb) async => cb,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Right-clicks at [position] and settles the menu-open animation.
Future<void> _rightClick(WidgetTester tester, Offset position) async {
  final gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.down(position);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('GestureOverlay builds without error (desktop)', (tester) async {
    final player = _fakePlayer();
    await tester.pumpWidget(_harness(player: player));
    await tester.pumpAndSettle();
    expect(find.byType(GestureOverlay), findsOneWidget);
  });

  testWidgets('right-click opens PotPlayer-style menu', (tester) async {
    final player = _fakePlayer();
    await tester.pumpWidget(_harness(player: player));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(GestureOverlay));

    // Send secondary (right) click at center.
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.down(center);
    await gesture.up();
    await tester.pumpAndSettle();

    // Top-level entries should now be in the overlay.
    // MenuAnchor renders menuChildren in an OverlayPortal.
    expect(find.text('Open'), findsWidgets);
    expect(find.text('Playback'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('Subtitle'), findsOneWidget);
    expect(find.text('Window'), findsOneWidget);
  });

  testWidgets('menu contains nested Speed and A-B loop under Playback', (tester) async {
    final player = _fakePlayer();
    await tester.pumpWidget(_harness(player: player));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(GestureOverlay));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.down(center);
    await gesture.up();
    await tester.pumpAndSettle();

    // Playback submenu should be visible; opening it reveals Speed/A-B.
    // Tap Playback to expand its submenu.
    await tester.tap(find.text('Playback'));
    await tester.pumpAndSettle();

    expect(find.text('Speed'), findsOneWidget);
    expect(find.text('A-B loop'), findsOneWidget);
  });

  testWidgets('left-click on the video dismisses the context menu', (tester) async {
    final player = _fakePlayer();
    await tester.pumpWidget(_harness(player: player));
    await tester.pumpAndSettle();

    final canvas = tester.getRect(find.byType(GestureOverlay));
    // Open near the bottom-right: the panel grows right/down from the pointer
    // (and is clamped inside the view), so the top-left corner stays outside
    // the menu itself.
    await _rightClick(tester, canvas.bottomRight - const Offset(120, 120));
    expect(find.text('Playback'), findsOneWidget);

    await tester.tapAt(canvas.topLeft + const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('Playback'), findsNothing);
  });

  testWidgets('right-click elsewhere reopens the closed menu', (tester) async {
    final player = _fakePlayer();
    await tester.pumpWidget(_harness(player: player));
    await tester.pumpAndSettle();

    final canvas = tester.getRect(find.byType(GestureOverlay));
    await _rightClick(tester, canvas.center);
    expect(find.text('Playback'), findsOneWidget);

    // Dismiss, then right-click a different spot: the menu must come back.
    await tester.tapAt(canvas.topLeft + const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Playback'), findsNothing);

    await _rightClick(tester, canvas.topLeft + const Offset(200, 200));
    expect(find.text('Playback'), findsOneWidget);
  });
}
