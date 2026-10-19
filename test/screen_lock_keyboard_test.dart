import 'dart:ui' show KeyEventDeviceType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/screen_lock/store/use_screen_lock_store.dart';
import 'package:iris/hooks/use_keyboard.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/player.dart';
import 'package:provider/provider.dart';
// Test-only StoreLocator host (see pubspec dev_dependencies comment).
import 'package:zustand/zustand.dart';

/// The screen lock is a hard gate for EVERY shortcut: while the touch guard is
/// armed the keyboard must not act on the player either. `player_back_disposition`
/// puts the lock above the gesture guide ("a stray press cannot dismiss
/// playback"), so space / arrows / step keys must be dropped too — not only
/// pointer input.
///
/// StoreScope-equivalent that does NOT dispose the global StoreLocator on
/// unmount (mirrors legacy_frame_step_repeat_test.providerScope).
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

void main() {
  final events = <String>[];
  late MediaPlayer player;
  void Function(KeyEvent)? capturedHandler;

  setUp(() {
    events.clear();
    capturedHandler = null;
    player = MediaPlayer(
      isInitializing: false,
      isPlaying: false,
      externalSubtitles: const [],
      position: Duration.zero,
      duration: const Duration(minutes: 1),
      buffer: Duration.zero,
      width: 0,
      height: 0,
      saveProgress: () async {},
      play: () async => events.add('play'),
      pause: () async => events.add('pause'),
      backward: (_) async => events.add('backward'),
      forward: (_) async => events.add('forward'),
      stepBackward: () async => events.add('stepBackward'),
      stepForward: () async => events.add('stepForward'),
      seek: (_) async => events.add('seek'),
    );
  });

  tearDown(() {
    StoreLocator().delete(ScreenLockStore);
  });

  Future<void> pumpHarness(WidgetTester tester) async {
    await tester.pumpWidget(providerScope(
      Provider<MediaPlayer>.value(
        value: player,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HookBuilder(builder: (context) {
            final handler = useKeyboard(
              showControl: () {},
              showControlForHover: (future) => future,
              showProgress: () {},
            );
            capturedHandler = handler;
            return const SizedBox.shrink();
          }),
        ),
      ),
    ));
    // Deferred l10n delegates load async — settle so the hook captures a
    // resolved handler.
    await tester.pumpAndSettle();
  }

  KeyEvent down(LogicalKeyboardKey key) => KeyDownEvent(
        deviceType: KeyEventDeviceType.keyboard,
        logicalKey: key,
        physicalKey: PhysicalKeyboardKey.arrowLeft,
        timeStamp: Duration.zero,
      );

  testWidgets('unlocked: an arrow key drives the player', (tester) async {
    await pumpHarness(tester);
    capturedHandler!(down(LogicalKeyboardKey.arrowLeft));
    await tester.pump();
    expect(events, ['backward'],
        reason: 'sanity: the shortcut is live while unlocked');
  });

  testWidgets('locked: arrow / space / step keys are all dropped',
      (tester) async {
    await pumpHarness(tester);
    useScreenLockStore().lock();
    await tester.pump();

    for (final key in [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.equal,
      LogicalKeyboardKey.minus,
    ]) {
      capturedHandler!(down(key));
      await tester.pump();
    }

    expect(events, isEmpty,
        reason: 'the lock must silence the keyboard, not only touch');
  });

  testWidgets('unlocking restores the shortcuts', (tester) async {
    await pumpHarness(tester);
    useScreenLockStore().lock();
    await tester.pump();
    capturedHandler!(down(LogicalKeyboardKey.arrowLeft));
    await tester.pump();
    expect(events, isEmpty);

    useScreenLockStore().unlock();
    await tester.pump();
    capturedHandler!(down(LogicalKeyboardKey.arrowLeft));
    await tester.pump();
    expect(events, ['backward']);
  });
}
