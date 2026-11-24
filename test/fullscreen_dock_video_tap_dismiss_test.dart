import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/player_ui_state.dart';
import 'package:iris/pages/player/overlays/gesture_overlay.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// Picture-fullscreen queue overlay: the panel is NOT a route, so it has no
/// barrier that could catch a "click elsewhere". The video tap is the only one
/// the user has, and it must close the panel instead of toggling the control
/// bar (this is the Windows report: "点画面其它处不会关闭").
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

Widget _harness({
  required void Function() onShow,
  required void Function() onHide,
}) {
  return _providerScope(
    Provider<MediaPlayer>.value(
      value: _fakePlayer(),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox.expand(
            child: GestureOverlay(
              showControl: onShow,
              hideControl: onHide,
              showProgress: () {},
              showControlForHover: (cb) async => cb,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    // Picture fullscreen is the only state where the overlay exists; the
    // desktop/meta-era/docked-right defaults are already what the resolver
    // needs (see `AppState`).
    usePlayerUiStore().set(
      const PlayerUiState(isFullScreen: true, isShowControl: false),
    );
  });

  testWidgets('a shown queue overlay spends the video tap on closing itself',
      (tester) async {
    var shows = 0;
    var hides = 0;
    usePlayerUiStore().showFullscreenDock();

    await tester.pumpWidget(_harness(
      onShow: () => shows++,
      onHide: () => hides++,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(GestureOverlay));
    // The video layer also owns a double-tap recognizer, so a single tap is
    // only resolved once the double-tap window elapses.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(usePlayerUiStore().isFullscreenDockShown, isFalse,
        reason: 'the picture click must conceal the queue panel');
    expect(shows, 0, reason: 'the click is consumed by the dismissal');
    expect(hides, 0, reason: 'the click must not also hide the chrome');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a hidden queue overlay leaves the tap to the control bar',
      (tester) async {
    var shows = 0;
    var hides = 0;
    usePlayerUiStore().hideFullscreenDock();

    await tester.pumpWidget(_harness(
      onShow: () => shows++,
      onHide: () => hides++,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(GestureOverlay));
    // The video layer also owns a double-tap recognizer, so a single tap is
    // only resolved once the double-tap window elapses.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(shows, 1, reason: 'no queue panel — the normal chrome toggle runs');
    expect(hides, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('outside picture fullscreen the tap never closes a panel',
      (tester) async {
    var shows = 0;
    var hides = 0;
    usePlayerUiStore().set(
      const PlayerUiState(isFullScreen: false, isShowControl: false),
    );
    usePlayerUiStore().showFullscreenDock();

    await tester.pumpWidget(_harness(
      onShow: () => shows++,
      onHide: () => hides++,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(GestureOverlay));
    // The video layer also owns a double-tap recognizer, so a single tap is
    // only resolved once the double-tap window elapses.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // The overlay is unreachable outside picture fullscreen, so stale flags must
    // not swallow the click either.
    expect(shows, 1);
    expect(usePlayerUiStore().isFullscreenDockShown, isTrue,
        reason: 'a stale flag is not a visible panel to dismiss');
    expect(tester.takeException(), isNull);
  });
}
