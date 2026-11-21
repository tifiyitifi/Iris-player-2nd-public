import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/background_playback/engine/background_playback_scope.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

import 'helpers/sqlite3_loader.dart';

/// A transport command issued while a 副音 file is still OPENING must survive
/// the open.
///
/// The autoplay-sync effect bails on `isInitializing` (correct — the flag is not
/// meaningful yet), but nothing re-ran it when the open settled: the scope does
/// not listen to the engine, and `open()` captured `autoplay` at dial time. So
/// pressing 停止 mid-open still started the track, and pressing 播放 mid-open
/// left 副音 silent with its button showing "playing".
FileItem _f(String key) =>
    FileItem(name: key, uri: 'file:///$key', path: <String>[key]);

/// Emulates an open that takes a while: `settle()` is the moment the backend
/// finishes initializing (and, when the open was issued with autoplay, starts
/// sounding — the real media_kit behaviour the scope must react to).
class _OpenProbeEngine extends BackgroundPlaybackEngine {
  _OpenProbeEngine()
      : super(backend: PlayerBackend.mediaKit, attachNative: false);

  int opens = 0;
  int plays = 0;
  int pauses = 0;

  @override
  Future<void> open(FileItem next, {required bool autoplay}) async {
    opens++;
    file = next;
    isInitializing = true;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    plays++;
    isPlaying = true;
    completionPending = false;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    pauses++;
    isPlaying = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    file = null;
    isPlaying = false;
    isInitializing = false;
    notifyListeners();
  }

  /// The backend finished initializing; `startsPlaying` models the autoplay the
  /// open captured when it was issued.
  void settle({bool startsPlaying = false}) {
    isInitializing = false;
    isPlaying = startsPlaying;
    notifyListeners();
  }
}

Widget _harness(Widget child) => InheritedProvider<StoreLocator>.value(
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
        home: child,
      ),
    );

/// Writes to a store and WAITS for the zustand change stream to deliver.
///
/// Widget tests run in a fake-async zone where that stream does not deliver on
/// its own, so a bare `pump()` leaves every `select`-based effect looking at the
/// previous value (see `app_state_select_narrowing_test._mutate`).
Future<void> _write(WidgetTester tester, void Function() write) async {
  await tester.runAsync(() async {
    final Completer<void> delivered = Completer<void>();
    final StreamSubscription<dynamic> sub =
        StoreLocator().changes.listen((_) {
      if (!delivered.isCompleted) delivered.complete();
    });
    write();
    await delivered.future;
    await sub.cancel();
  });
  await tester.pump();
}

void main() {
  ensureSqlite3Loaded();
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });
  tearDownAll(() => db.close());

  late _OpenProbeEngine engine;

  setUp(() async {
    final app = useAppStore();
    app.set(app.state.copyWith(
      useMetadataSettings: true,
      useLegacyStoragePersistence: false,
    ));
    await useBackgroundPlaybackStore().initialized;
    await usePlayQueueStore().initialized;
    engine = _OpenProbeEngine();
  });

  tearDown(() {
    engine.dispose();
    StoreLocator().delete(BackgroundPlaybackStore);
    StoreLocator().delete(UnifiedPlayQueueStore);
    StoreLocator().delete(AppStore);
  });

  Future<void> mount(WidgetTester tester, {required bool autoPlay}) async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(
      enabled: true,
      gateOpen: true,
      bgAutoPlay: autoPlay,
      bgOutOfScope: false,
      bgExhausted: false,
      bgQueueEnded: false,
      queue: <FileItem>[_f('a')],
      currentIndex: 0,
    ));
    await tester.pumpWidget(_harness(
      BackgroundPlaybackScope(
        debugEngine: engine,
        child: Provider<MediaPlayer>.value(
          value: MediaPlayer(
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
          ),
          child: const SizedBox.shrink(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(engine.opens, 1, reason: 'the store armed one open');
    expect(engine.isInitializing, isTrue);
  }

  testWidgets('a stop issued while the file opens still stops it',
      (tester) async {
    await mount(tester, autoPlay: true);
    // The user presses 停止 while the backend is still initializing. The open
    // was issued with autoplay=true, so it will start sounding when it lands.
    await _write(tester, () => useBackgroundPlaybackStore().setPlaying(false));
    expect(engine.isInitializing, isTrue, reason: 'the open is still in flight');

    engine.settle(startsPlaying: true);
    await tester.pump();

    expect(engine.pauses, 1,
        reason: 'the settled open must honour the stop issued during it');
    expect(engine.isPlaying, isFalse);
  });

  testWidgets('a play issued while the file opens actually starts it',
      (tester) async {
    await mount(tester, autoPlay: false);
    await _write(tester, () => useBackgroundPlaybackStore().setPlaying(true));
    expect(engine.isInitializing, isTrue);

    engine.settle();
    await tester.pump();

    expect(engine.plays, 1,
        reason: 'the settled open must honour the play issued during it');
    expect(engine.isPlaying, isTrue);
  });
}
