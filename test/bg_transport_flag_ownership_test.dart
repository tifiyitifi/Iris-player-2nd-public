import 'dart:ui' show KeyEventDeviceType;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/player_control_target_scope.dart';
import 'package:iris/features/control_group/domain/center_zone_actions.dart';
import 'package:iris/hooks/use_keyboard.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/features/windows/desktop_keyboard/executor/potplayer_key_executor.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/play_pause_button.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

import 'helpers/sqlite3_loader.dart';

/// ONE owner for the transport flag a surface writes.
///
/// While 副音 owns the controls the shared surfaces drive the BACKGROUND
/// engine, so the pause/play must land in `bgAutoPlay` — never in the
/// foreground's `autoPlay` preference (ADR 0017). Writing the foreground flag
/// there both left `bgAutoPlay` stale (the next 下一首 re-opened the file with
/// `autoplay: true`, so 副音 resumed by itself after a pause) and cleared a
/// preference the command never touched.
///
/// The reference implementations are `PlayPauseButton`, the legacy bar and the
/// PotPlayer executor; these tests pin the two surfaces that used to diverge.
FileItem _f(String key) =>
    FileItem(name: key, uri: 'file:///$key', path: <String>[key]);

/// Records the transport the shared surface actually drives.
class _ProbeEngine extends BackgroundPlaybackEngine {
  _ProbeEngine() : super(backend: PlayerBackend.mediaKit, attachNative: false);

  int plays = 0;
  int pauses = 0;

  @override
  Future<void> play() async {
    plays++;
    isPlaying = true;
  }

  @override
  Future<void> pause() async {
    pauses++;
    isPlaying = false;
  }
}

MediaPlayer _fgPlayer() => MediaPlayer(
      isInitializing: false,
      isPlaying: true,
      externalSubtitles: const [],
      position: const Duration(minutes: 1),
      duration: const Duration(minutes: 10),
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

Widget _harness({
  required _ProbeEngine engine,
  required MediaPlayer player,
  required Widget Function(BuildContext) builder,
}) {
  return InheritedProvider<StoreLocator>.value(
    value: StoreLocator(),
    startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
      final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
      return sub.cancel;
    },
    lazy: false,
    child: ChangeNotifierProvider<BackgroundPlaybackEngine>.value(
      value: engine,
      child: Provider<MediaPlayer>.value(
        value: player,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: Builder(builder: builder)),
        ),
      ),
    ),
  );
}

void main() {
  ensureSqlite3Loaded();
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  // The 副音 store is a PersistentStore with session/AUX side effects.
  late AppDatabase db;
  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });
  tearDownAll(() => db.close());

  late _ProbeEngine engine;

  setUp(() async {
    final app = useAppStore();
    app.set(app.state.copyWith(
      useMetadataSettings: true,
      useLegacyStoragePersistence: false,
      autoPlay: true,
      // The LEGACY scheme is the one that used to write the foreground flag;
      // the PotPlayer executor already publishes `bgAutoPlay` (its own test).
      keyboardShortcutScheme: KeyboardShortcutScheme.legacy,
    ));
    await useBackgroundPlaybackStore().initialized;
    await usePlayQueueStore().initialized;
    engine = _ProbeEngine();
    // A pause is the interesting direction: the engine must be the one sounding.
    engine.isPlaying = true;
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(
      enabled: true,
      gateOpen: true,
      controlTarget: ControlTarget.background,
      displayTarget: ControlTarget.foreground,
      bgOutOfScope: false,
      bgExhausted: false,
      bgQueueEnded: false,
      bgAutoPlay: true,
      queue: <FileItem>[_f('a'), _f('b')],
      currentIndex: 0,
    ));
  });

  tearDown(() {
    StoreLocator().delete(BackgroundPlaybackStore);
    StoreLocator().delete(UnifiedPlayQueueStore);
    StoreLocator().delete(AppStore);
  });

  testWidgets('the default keyboard scheme pauses 副音 through its own flag',
      (tester) async {
    void Function(KeyEvent)? handler;
    late MediaPlayer bgPlayer;
    await tester.pumpWidget(_harness(
      engine: engine,
      player: _fgPlayer(),
      builder: (context) => HookBuilder(builder: (context) {
        bgPlayer = resolveActivePlayer(context);
        handler = useKeyboard(
          showControl: () {},
          showControlForHover: (future) => future,
          showProgress: () {},
        );
        return const SizedBox.shrink();
      }),
    ));
    await tester.pumpAndSettle();
    // The keyboard hook resolves the 副音 engine bridge while the background
    // owns the controls (it lives above the provider override).
    expect(bgPlayer.isPlaying, isTrue);

    handler!(KeyDownEvent(
      deviceType: KeyEventDeviceType.keyboard,
      logicalKey: LogicalKeyboardKey.space,
      physicalKey: PhysicalKeyboardKey.space,
      timeStamp: Duration.zero,
    ));
    await tester.pump();

    expect(engine.pauses, 1, reason: 'the 副音 engine is the player it drives');
    expect(useBackgroundPlaybackStore().state.bgAutoPlay, isFalse,
        reason: 'the pause belongs to 副音 and must be recorded on its flag');
    expect(useAppStore().state.autoPlay, isTrue,
        reason: 'a 副音 transport command must not rewrite the foreground pref');
  });

  testWidgets('the ring-dial centre tap pauses 副音 through its own flag',
      (tester) async {
    late BuildContext hostContext;
    await tester.pumpWidget(_harness(
      engine: engine,
      // Production mounts the controls under BackgroundTargetMediaScope, so the
      // resolved player IS the engine bridge.
      player: engine.asMediaPlayer(),
      builder: (context) => Builder(builder: (inner) {
        hostContext = inner;
        return ElevatedButton(
          onPressed: () => handleCenterZoneAction(
            context: inner,
            action: CircleSliderCenterAction.togglePlayPause,
            showControl: () {},
          ),
          child: const Text('center'),
        );
      }),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('center'));
    await tester.pump();

    expect(hostContext.mounted, isTrue);
    expect(engine.pauses, 1);
    expect(useBackgroundPlaybackStore().state.bgAutoPlay, isFalse);
    expect(useAppStore().state.autoPlay, isTrue);
  });

  testWidgets('the control-bar play/pause pauses 副音 through its own flag',
      (tester) async {
    await tester.pumpWidget(_harness(
      engine: engine,
      // Production mounts the control bar under BackgroundTargetMediaScope, so
      // the provider IS the engine bridge.
      player: engine.asMediaPlayer(),
      builder: (context) => PlayPauseButton(showControl: () {}),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump();

    expect(engine.pauses, 1, reason: 'the 副音 engine is the player it drives');
    expect(useBackgroundPlaybackStore().state.bgAutoPlay, isFalse,
        reason: 'the pause belongs to 副音 and must be recorded on its flag');
    expect(useAppStore().state.autoPlay, isTrue,
        reason: 'a 副音 transport command must not rewrite the foreground pref');
  });

  testWidgets('the PotPlayer executor pauses 副音 through its own flag',
      (tester) async {
    await tester.pumpWidget(_harness(
      engine: engine,
      player: engine.asMediaPlayer(),
      builder: (context) => ElevatedButton(
        onPressed: () async {
          await PotPlayerKeyExecutor(
            context: context,
            player: context.read<MediaPlayer>(),
            showControl: () {},
            showControlForHover: (future) => future,
            showProgress: () {},
          ).perform(PotPlayerAction.playPause, false);
        },
        child: const Text('playpause'),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('playpause'));
    await tester.pump();

    // The bg branch publishes the flag; the scope's autoplay-sync applies it to
    // the engine (there is no scope in this harness).
    expect(useBackgroundPlaybackStore().state.bgAutoPlay, isFalse);
    expect(useAppStore().state.autoPlay, isTrue,
        reason: 'a 副音 transport command must not rewrite the foreground pref');
    // Let the OSD auto-hide timer fire before teardown.
    await tester.pump(const Duration(seconds: 3));
  });
}
