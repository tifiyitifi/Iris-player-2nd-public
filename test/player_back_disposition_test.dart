import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/pages/player/player_back_disposition.dart';
import 'package:iris/store/use_player_ui_store.dart';
// Test-only StoreLocator host (see pubspec dev_dependencies comment).
import 'package:zustand/zustand.dart';
import 'package:provider/provider.dart';

void main() {
  Widget providerScope(Widget child) {
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

  group('resolvePlayerBackDisposition', () {
    test('guide open → close the guide overlay', () {
      expect(
        resolvePlayerBackDisposition(isShowGestureTips: true),
        PlayerBackDisposition.closeGestureGuide,
      );
    });

    test('guide hidden → original exit semantics', () {
      expect(
        resolvePlayerBackDisposition(isShowGestureTips: false),
        PlayerBackDisposition.leavePlayer,
      );
    });

    test('screen locked → release the lock, never leave', () {
      expect(
        resolvePlayerBackDisposition(
          isShowGestureTips: false,
          isScreenLocked: true,
        ),
        PlayerBackDisposition.unlockScreen,
      );
    });

    test('lock outranks the guide', () {
      expect(
        resolvePlayerBackDisposition(
          isShowGestureTips: true,
          isScreenLocked: true,
        ),
        PlayerBackDisposition.unlockScreen,
      );
    });
  });

  testWidgets('back arrow closes the guide instead of leaving the player',
      (tester) async {
    usePlayerUiStore().updateIsShowGestureTips(true);
    addTearDown(() => usePlayerUiStore().updateIsShowGestureTips(false));

    var exitAttempted = false;
    bool? seenGuideAtPop;
    await tester.pumpWidget(providerScope(MaterialApp(
      home: PopScope(
        // PopScope must live INSIDE the route (under the Navigator) to
        // register — mirroring player.dart's wrapping of the player body.
        canPop: false,
        onPopInvokedWithResult: (bool didPop, Object? result) async {
          if (!didPop) {
            seenGuideAtPop = usePlayerUiStore().state.isShowGestureTips;
            switch (resolvePlayerBackDisposition(
                isShowGestureTips: seenGuideAtPop!)) {
              case PlayerBackDisposition.unlockScreen:
                return;
              case PlayerBackDisposition.closeGestureGuide:
                usePlayerUiStore().updateIsShowGestureTips(false);
                return;
              case PlayerBackDisposition.leavePlayer:
                exitAttempted = true;
                return;
            }
          }
        },
        child: const Scaffold(body: SizedBox.shrink()),
      ),
    )));

    expect(usePlayerUiStore().state.isShowGestureTips, isTrue,
        reason: 'precondition: guide on stage before the back arrow');

    // Simulate the Android back arrow on the (non-poppable) route.
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(exitAttempted, isFalse,
        reason: 'back must NOT fall through to app exit while the guide is up');
    expect(seenGuideAtPop, isTrue,
        reason: 'callback must observe the live guide flag');
    expect(usePlayerUiStore().state.isShowGestureTips, isFalse);
  });
}
