import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/window/playlist_dock/fullscreen_playlist_dock_overlay.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_dock.dart';

/// The fullscreen queue panel is transient: pointer movement outside it arms a
/// debounced conceal. Re-showing the panel (queue key/button) within that window
/// must cancel the armed conceal — otherwise it silently closes the panel the
/// user just opened.
Widget _host({
  required bool shown,
  required VoidCallback onConceal,
  required VoidCallback onReveal,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: FullscreenPlaylistDockOverlay(
          shown: shown,
          width: 200,
          edgeWidth: 40,
          onReveal: onReveal,
          onConceal: onConceal,
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('re-showing the panel cancels a pending conceal',
      (tester) async {
    var conceals = 0;
    var reveals = 0;

    await tester.pumpWidget(_host(
      shown: true,
      onConceal: () => conceals++,
      onReveal: () => reveals++,
    ));
    await tester.pump();

    // Pointer movement over the full-screen "away" watcher, outside the panel,
    // arms the debounced conceal.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(60, 60));
    await tester.pump();
    await gesture.moveTo(const Offset(90, 90));
    await tester.pump();

    // Dismiss and re-open before the delay elapses (a quick queue-key toggle).
    await tester.pumpWidget(_host(
      shown: false,
      onConceal: () => conceals++,
      onReveal: () => reveals++,
    ));
    await tester.pump();
    await tester.pumpWidget(_host(
      shown: true,
      onConceal: () => conceals++,
      onReveal: () => reveals++,
    ));
    await tester.pump(kFullscreenDockConcealDelay + const Duration(milliseconds: 50));

    expect(conceals, 0,
        reason: 'the conceal armed before the re-show must not fire');
    expect(reveals, 0, reason: 'visibility is caller-owned');
    expect(tester.takeException(), isNull);

    await gesture.removePointer();
  });

  testWidgets('pointer movement away still conceals a shown panel',
      (tester) async {
    var conceals = 0;

    await tester.pumpWidget(_host(
      shown: true,
      onConceal: () => conceals++,
      onReveal: () {},
    ));
    await tester.pump();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(60, 60));
    await tester.pump();
    await gesture.moveTo(const Offset(90, 90));
    await tester.pump();
    await tester
        .pump(kFullscreenDockConcealDelay + const Duration(milliseconds: 50));

    expect(conceals, 1, reason: 'the away watcher must arm the conceal');
    expect(tester.takeException(), isNull);

    await gesture.removePointer();
  });
}
