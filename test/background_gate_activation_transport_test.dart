import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/actions/background_playback_actions.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/services/current_foreground_media_key.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/windows/desktop_keyboard/executor/potplayer_key_executor.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// The quick-bar activation GATE is a permission, not a play command: pressing
/// it while the foreground is paused opens the gate but must never force the
/// pair back to playing (the transport mirror owns the later resume).
MediaPlayer _player({required bool playing}) => MediaPlayer(
      isInitializing: false,
      isPlaying: playing,
      externalSubtitles: const [],
      position: Duration.zero,
      duration: const Duration(minutes: 1),
      buffer: Duration.zero,
      width: 0,
      height: 0,
      saveProgress: () async {},
      play: () async {},
      pause: () async {},
      backward: (_) async {},
      forward: (_) async {},
      stepBackward: () async {},
      stepForward: () async {},
      seek: (_) async {},
    );

FileItem _f(String key) =>
    FileItem(name: key, uri: 'file:///$key', path: [key]);

Widget _harness(MediaPlayer player) => InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Provider<MediaPlayer>.value(
          value: player,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    BackgroundPlaybackActions.toggleGateForCurrent(context),
                child: const Text('gate'),
              ),
            ),
          ),
        ),
      ),
    );

Widget _executorHarness(
  MediaPlayer player, {
  PotPlayerAction action = PotPlayerAction.toggleBackgroundGate,
}) =>
    InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Provider<MediaPlayer>.value(
          value: player,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await PotPlayerKeyExecutor(
                  context: context,
                  player: player,
                  showControl: () {},
                  showControlForHover: (future) => future,
                  showProgress: () {},
                ).perform(action, false);
              },
              child: const Text('gate key'),
            ),
          ),
        ),
      ),
    );

Widget _eventHarness(MediaPlayer player, KeyEvent event) =>
    InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Provider<MediaPlayer>.value(
          value: player,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await PotPlayerKeyExecutor(
                  context: context,
                  player: player,
                  showControl: () {},
                  showControlForHover: (future) => future,
                  showProgress: () {},
                ).handle(event);
              },
              child: const Text('send key'),
            ),
          ),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUp(() async {
    final app = useAppStore();
    app.set(app.state.copyWith(
      useMetadataSettings: true,
      useLegacyStoragePersistence: false,
    ));
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    await usePlayQueueStore().initialized;
    // The foreground media the double-play guard/scope key resolves against.
    await usePlayQueueStore().update(
      playQueue: [PlayQueueItem(file: _f('fg.mp4'), index: 0)],
      index: 0,
    );
    // A loaded, stopped run: the re-activation path skips candidate resolve.
    await bg.setAutoFocusControl(false);
    await bg.enableWithQueue([_f('b1')], focusControl: false, autoplay: false);
    bg.stopGate();
  });

  tearDown(() {
    StoreLocator().delete(BackgroundPlaybackStore);
    StoreLocator().delete(UnifiedPlayQueueStore);
  });

  testWidgets('activating while the video is paused opens the gate silently',
      (tester) async {
    await tester.pumpWidget(_harness(_player(playing: false)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('gate'));
    await tester.pumpAndSettle();

    final bg = useBackgroundPlaybackStore();
    expect(bg.state.gateOpen, isTrue, reason: 'the permission is granted');
    expect(bg.state.bgAutoPlay, isFalse,
        reason: 'a paused foreground must not be force-played on activation');
  });

  testWidgets('activating while the video plays starts 副音', (tester) async {
    await tester.pumpWidget(_harness(_player(playing: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('gate'));
    await tester.pumpAndSettle();

    final bg = useBackgroundPlaybackStore();
    expect(bg.state.gateOpen, isTrue);
    expect(bg.state.bgAutoPlay, isTrue,
        reason: 'activation follows a playing foreground');
  });

  testWidgets('仅当前: a press on a media outside the anchor ACTIVATES here '
      'instead of latching the run closed', (tester) async {
    final bg = useBackgroundPlaybackStore();
    // The gate is open but anchored to a DIFFERENT media (fg switched away):
    // 副音 is paused for this one, so the button is offering "play 副音 for the
    // current video". Turning it off here would kill the run over a media
    // switch the user never asked for.
    bg.set(bg.state.copyWith(
      gateOpen: true,
      bgAutoPlay: false,
      scopeAnchorKey: 'some-other-media',
    ));

    await tester.pumpWidget(_harness(_player(playing: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('gate'));
    await tester.pumpAndSettle();

    expect(bg.state.gateOpen, isTrue, reason: 'the press re-anchors, not stops');
    expect(
      bg.state.scopeAnchorKey,
      currentScopeKey(),
      reason: '仅当前 activation anchors the run to the media on screen',
    );
  });

  testWidgets('the keyboard gate action opens 副音 for the current video',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    expect(bg.state.gateOpen, isFalse, reason: 'setUp leaves the gate closed');

    await tester.pumpWidget(_executorHarness(_player(playing: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('gate key'));
    await tester.pumpAndSettle();

    expect(bg.state.gateOpen, isTrue);
    expect(bg.state.bgPairInEffect, isTrue);
    expect(bg.state.bgAutoPlay, isTrue,
        reason: 'activation follows a playing foreground');
  });

  testWidgets('a second keyboard gate press stops it and hands control back',
      (tester) async {
    final bg = useBackgroundPlaybackStore();

    await tester.pumpWidget(_executorHarness(_player(playing: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('gate key'));
    await tester.pumpAndSettle();
    expect(bg.state.gateOpen, isTrue);

    // Pretend the shared controls had been retargeted to 副音: the stop path
    // must return them to the foreground, exactly like the quick-bar button.
    bg.setControlTarget(ControlTarget.background);

    await tester.tap(find.text('gate key'));
    await tester.pumpAndSettle();

    expect(bg.state.gateOpen, isFalse);
    expect(bg.state.bgPairInEffect, isFalse);
    expect(bg.state.controlTarget, ControlTarget.foreground);
    expect(bg.state.displayTarget, ControlTarget.foreground);
  });

  testWidgets('Alt + the apostrophe key the Windows embedder reports reaches '
      'the gate action through the real lookup path', (tester) async {
    // Windows resolves VK_OEM_7 to `quote` (0x22), NOT `quoteSingle`; the
    // shipping bug was a default bound to `quoteSingle`, so the event fell
    // through to `key unbound: Alt+"` and nothing happened. Drive the executor
    // with that exact event so the fold cannot regress.
    final bg = useBackgroundPlaybackStore();
    expect(bg.state.gateOpen, isFalse);

    await tester.pumpWidget(
      _eventHarness(
        _player(playing: true),
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.quote,
          logicalKey: LogicalKeyboardKey.quote,
          timeStamp: Duration.zero,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.tap(find.text('send key'));
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

    expect(bg.state.gateOpen, isTrue);
    expect(bg.state.bgPairInEffect, isTrue);
  });

  group('Alt+; control target', () {
    testWidgets('flips the shared controls to 副音 and back while the pair is live',
        (tester) async {
      final bg = useBackgroundPlaybackStore();
      await bg.openGate(mediaKey: currentScopeKey(), autoplay: true);
      expect(bg.state.bgPairInEffect, isTrue, reason: 'the pair is live');
      expect(bg.state.bgOwnsControls, isFalse, reason: 'controls start on fg');

      await tester.pumpWidget(
        _executorHarness(
          _player(playing: true),
          action: PotPlayerAction.toggleControlTarget,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('gate key'));
      await tester.pumpAndSettle();

      expect(bg.state.controlTarget, ControlTarget.background);
      expect(bg.state.bgOwnsControls, isTrue);
      expect(bg.state.displayTarget, ControlTarget.foreground,
          reason: 'the shortcut moves the CONTROLS only');

      await tester.tap(find.text('gate key'));
      await tester.pumpAndSettle();

      expect(bg.state.controlTarget, ControlTarget.foreground);
      expect(bg.state.bgOwnsControls, isFalse);
    });

    testWidgets('is inert while 副音 is not in effect for this media',
        (tester) async {
      final bg = useBackgroundPlaybackStore();
      expect(bg.state.bgPairInEffect, isFalse,
          reason: 'setUp leaves the gate closed');

      await tester.pumpWidget(
        _executorHarness(
          _player(playing: true),
          action: PotPlayerAction.toggleControlTarget,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('gate key'));
      await tester.pumpAndSettle();

      expect(bg.state.gateOpen, isFalse, reason: 'never a side-effect open');
      expect(bg.state.controlTarget, ControlTarget.foreground);
    });

    testWidgets('the semicolon key the Windows embedder reports reaches the '
        'action through the real lookup path', (tester) async {
      final bg = useBackgroundPlaybackStore();
      await bg.openGate(mediaKey: currentScopeKey(), autoplay: true);

      await tester.pumpWidget(
        _eventHarness(
          _player(playing: true),
          KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.semicolon,
            logicalKey: LogicalKeyboardKey.semicolon,
            timeStamp: Duration.zero,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.tap(find.text('send key'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

      expect(bg.state.controlTarget, ControlTarget.background);
      expect(bg.state.bgOwnsControls, isTrue);
    });
  });
}
