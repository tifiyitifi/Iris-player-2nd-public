import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/screen_lock/store/use_screen_lock_store.dart';
import 'package:iris/features/screen_lock/view/screen_lock_overlay.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

// Test-only StoreLocator host (see pubspec dev_dependencies comment).
Widget _providerScope(Widget child) => InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: child,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    StoreLocator().delete(ScreenLockStore);
  });

  /// A full-screen Stack shaped like the player's: the lock overlay is the
  /// TOPMOST child, with a tappable "gesture layer" behind it. A tap that
  /// reaches the background proves the lock did NOT swallow it.
  Future<void> pumpPlayer(WidgetTester tester,
      {required VoidCallback onBackgroundTap,
      String title = '',
      EdgeInsets testPadding = EdgeInsets.zero}) async {
    await tester.pumpWidget(_providerScope(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(padding: testPadding),
        child: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onBackgroundTap,
                  child: const SizedBox.expand(),
                ),
              ),
              ScreenLockOverlay(title: title),
            ],
          ),
        ),
      ),
    )));
    await tester.pumpAndSettle();
  }

  double chromeOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byKey(ScreenLockOverlay.chromeKey)).opacity;

  /// Arms the guard and settles the overlay on it. Two frames: the store
  /// broadcasts through the locator asynchronously, so the first frame
  /// flushes the notification and the second rebuilds on the new state.
  Future<void> armLock(WidgetTester tester) async {
    useScreenLockStore().lock();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('unlocked: nothing renders and taps reach the player',
      (tester) async {
    var backgroundTaps = 0;
    await pumpPlayer(tester, onBackgroundTap: () => backgroundTaps++);

    expect(find.byKey(ScreenLockOverlay.leftUnlockKey), findsNothing);
    expect(find.byKey(ScreenLockOverlay.rightUnlockKey), findsNothing);

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(backgroundTaps, 1,
        reason: 'an unlocked overlay must not intercept player taps');
  });

  testWidgets('locked: edge buttons and title show immediately after locking',
      (tester) async {
    await pumpPlayer(tester, onBackgroundTap: () {}, title: 'My Movie');

    await armLock(tester);

    expect(find.byKey(ScreenLockOverlay.leftUnlockKey), findsOneWidget);
    expect(find.byKey(ScreenLockOverlay.rightUnlockKey), findsOneWidget);
    expect(find.text('My Movie'), findsOneWidget);
    expect(chromeOpacity(tester), 1);
  });

  testWidgets('locked: chrome auto-hides after 3s', (tester) async {
    await pumpPlayer(tester, onBackgroundTap: () {});
    await armLock(tester);
    expect(chromeOpacity(tester), 1);

    await tester.pump(const Duration(seconds: 3));
    expect(chromeOpacity(tester), 0);
    // The guard is still armed: hiding the chrome never unlocks.
    expect(useScreenLockStore().state.locked, isTrue);
  });

  testWidgets('locked: tapping empty area toggles chrome, never the player',
      (tester) async {
    var backgroundTaps = 0;
    await pumpPlayer(tester, onBackgroundTap: () => backgroundTaps++);
    await armLock(tester);

    // Centre (away from both edge buttons) must not reach the gesture layer.
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    await tester.pump();
    expect(backgroundTaps, 0,
        reason: 'the full-screen barrier must swallow every pointer');
    expect(chromeOpacity(tester), 0,
        reason: 'first tap hides the lock chrome (showControl-like toggle)');

    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    await tester.pump();
    expect(backgroundTaps, 0);
    expect(chromeOpacity(tester), 1,
        reason: 'second tap brings the lock chrome back');

    // ...and the lock must still be armed: a stray tap never unlocks.
    expect(useScreenLockStore().state.locked, isTrue);
  });

  testWidgets('locked: hidden buttons cannot be tapped through', (tester) async {
    var backgroundTaps = 0;
    await pumpPlayer(tester, onBackgroundTap: () => backgroundTaps++);
    await armLock(tester);

    // Hide the chrome first.
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    await tester.pump();
    expect(chromeOpacity(tester), 0);

    // Tapping where the hidden button sits re-shows the chrome instead of
    // unlocking (the button is IgnorePointer'd while hidden). The miss
    // warning is the point: the tap must fall through to the barrier.
    await tester.tap(find.byKey(ScreenLockOverlay.leftUnlockKey),
        warnIfMissed: false);
    await tester.pump();
    await tester.pump();
    expect(useScreenLockStore().state.locked, isTrue,
        reason: 'hidden unlock button must not fire');
    expect(chromeOpacity(tester), 1);
    expect(backgroundTaps, 0);
  });

  testWidgets('locked: left button clears a landscape camera cutout',
      (tester) async {
    const cutout = EdgeInsets.only(left: 47);
    await pumpPlayer(tester,
        onBackgroundTap: () {}, testPadding: cutout);
    await armLock(tester);

    final Rect buttonRect =
        tester.getRect(find.byKey(ScreenLockOverlay.leftUnlockKey));
    expect(buttonRect.left, greaterThanOrEqualTo(cutout.left),
        reason: 'the unlock button must sit clear of the camera cutout');
  });

  testWidgets('locked: tapping the LEFT edge unlocks', (tester) async {
    await pumpPlayer(tester, onBackgroundTap: () {});
    await armLock(tester);

    await tester.tap(find.byKey(ScreenLockOverlay.leftUnlockKey));
    await tester.pumpAndSettle();

    expect(useScreenLockStore().state.locked, isFalse);
    expect(find.byKey(ScreenLockOverlay.leftUnlockKey), findsNothing);
  });

  testWidgets('locked: tapping the RIGHT edge unlocks', (tester) async {
    await pumpPlayer(tester, onBackgroundTap: () {});
    await armLock(tester);

    await tester.tap(find.byKey(ScreenLockOverlay.rightUnlockKey));
    await tester.pumpAndSettle();

    expect(useScreenLockStore().state.locked, isFalse);
  });

  testWidgets('unlocking never forwards the unlocking tap to the player',
      (tester) async {
    var backgroundTaps = 0;
    await pumpPlayer(tester, onBackgroundTap: () => backgroundTaps++);
    await armLock(tester);

    await tester.tap(find.byKey(ScreenLockOverlay.leftUnlockKey));
    await tester.pumpAndSettle();

    expect(backgroundTaps, 0,
        reason: 'the unlock press is consumed by the button, not passed down');
  });
}
