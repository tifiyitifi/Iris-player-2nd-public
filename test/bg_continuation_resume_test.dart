import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/model/enum/bg_seek_link.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/services/background_duration_probe.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/background_runtime_scope.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart' show PlayerBackend, Repeat;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

import 'helpers/sqlite3_loader.dart';

/// A 副音 file that ENDS under `BgExhaustedAction.nextBg` must leave 副音
/// PLAYING — the setting promises the next 副音 keeps it audible, and the queue
/// is walked as one looping timeline.
///
/// Two defects lived here:
/// - a landing INSIDE the file that is already open (a single-entry 副音 list —
///   exactly the mid-video activation case) moves no queue index, so nothing
///   re-opened the engine and no autoplay flag changed: the pair stayed paused
///   on a completed file;
/// - an unusable timeline (a duration the probe never resolved — routine on a
///   WebDAV/FTP source) used to PAUSE outright.
///
/// `seekLink: independent` (完全独立) is deliberate: it stands the transport
/// mirror down, so `engine.play()` / `engine.replay()` can only come from the
/// continuation itself.
FileItem _f(String key) =>
    FileItem(name: key, uri: 'file:///$key', path: [key]);

/// A local file whose canonical media key is `storageId:name`, so a matching
/// `media_nodes` row can supply its duration.
FileItem _fs(String storageId, String name) => FileItem(
      storageId: storageId,
      name: name,
      uri: 'file:///$name',
      path: <String>[name],
    );

class _ProbeEngine extends BackgroundPlaybackEngine {
  _ProbeEngine() : super(backend: PlayerBackend.mediaKit, attachNative: false);

  final List<Duration> seeks = <Duration>[];
  int plays = 0;
  int replays = 0;

  /// Rebuilds the observer's `useListenable(engine)` subscription. The widget
  /// harness does not deliver store-driven rebuilds reliably, so the tests poke
  /// this after a store write to force the effects to re-evaluate.
  void poke() => notifyListeners();

  @override
  Future<void> play() async {
    plays++;
    isPlaying = true;
  }

  @override
  Future<void> replay() async {
    replays++;
    isPlaying = true;
    position = Duration.zero;
  }

  @override
  Future<void> seek(Duration target) async {
    seeks.add(target);
    position = target;
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
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

MediaPlayer _fgPlayer() => MediaPlayer(
      isInitializing: false,
      isPlaying: true,
      externalSubtitles: const [],
      position: const Duration(minutes: 5),
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

/// Mounts the observer over a 副音 [queue] with [openFile] already loaded, whose
/// engine reports [bgDuration] (zero models a duration the probe never
/// resolved). [bgPosition] defaults to the file's end (a completed file).
Future<void> _mountBg(
  WidgetTester tester,
  _ProbeEngine engine, {
  required List<FileItem> queue,
  required FileItem openFile,
  required Duration bgDuration,
  Duration? bgPosition,
  Repeat bgRepeat = Repeat.all,
  int? alignOffsetMs,
}) async {
  await usePlayQueueStore().update(
    playQueue: [PlayQueueItem(file: _f('B.mp4'), index: 0)],
    index: 0,
  );
  final bg = useBackgroundPlaybackStore();
  final int idx = queue.indexWhere((f) => identical(f, openFile));
  bg.set(bg.state.copyWith(
    enabled: true,
    gateOpen: true,
    controlTarget: ControlTarget.foreground,
    displayTarget: ControlTarget.foreground,
    applyScope: BgApplyScope.all,
    scopeAnchorKey: '',
    bgAutoPlay: true,
    bgExhausted: false,
    // Fully unlinked: the transport mirror must not mask the continuation.
    seekLink: BgSeekLink.independent,
    bgRepeat: bgRepeat,
    alignOffsetMs: alignOffsetMs,
    queue: queue,
    currentIndex: idx < 0 ? 0 : idx,
  ));
  engine.file = openFile;
  engine.duration = bgDuration;
  engine.position = bgPosition ?? bgDuration;
  engine.isPlaying = false;

  await tester.pumpWidget(_harness(
    ChangeNotifierProvider<BackgroundPlaybackEngine>.value(
      value: engine,
      child: Provider<MediaPlayer>.value(
        value: _fgPlayer(),
        child: const BackgroundRuntimeScope(child: SizedBox.shrink()),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Mounts the observer over a single-entry 副音 queue whose engine reports
/// [bgDuration] (zero models a duration the probe never resolved).
Future<void> _mountSingleBg(
  WidgetTester tester,
  _ProbeEngine engine, {
  required Duration bgDuration,
}) =>
    _mountBg(
      tester,
      engine,
      queue: <FileItem>[_f('b1')],
      openFile: _f('b1'),
      bgDuration: bgDuration,
      alignOffsetMs: 0,
    );

/// Bumps the continuation request and rebuilds the observer.
Future<void> _requestContinuation(
  WidgetTester tester,
  _ProbeEngine engine,
) async {
  useBackgroundPlaybackStore().requestBgContinuation(fromAlign: false);
  engine.poke();
  await tester.pumpAndSettle();
}

void main() {
  ensureSqlite3Loaded();
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  // `step` records the new occurrence on the background scenario, which needs a
  // live (in-memory) DB.
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
    ));
    await useBackgroundPlaybackStore().initialized;
    await usePlayQueueStore().initialized;
    engine = _ProbeEngine();
  });

  tearDown(() {
    engine.dispose();
    StoreLocator().delete(BackgroundPlaybackStore);
    StoreLocator().delete(UnifiedPlayQueueStore);
    StoreLocator().delete(AppStore);
  });

  testWidgets('a completion landing in the OPEN file resumes 副音',
      (tester) async {
    // Single-entry list: the mapped position falls inside the very file the
    // engine already holds, so no queue index moves and no open follows.
    await _mountSingleBg(
      tester,
      engine,
      bgDuration: const Duration(minutes: 10),
    );
    expect(engine.plays, 0, reason: 'sanity: nothing resumes on its own');

    await _requestContinuation(tester, engine);

    expect(engine.isPlaying, isTrue,
        reason: 'the pair must be PLAYING after the continuation');
    expect(engine.plays, greaterThanOrEqualTo(1));
    expect(engine.seeks, contains(const Duration(minutes: 5)),
        reason: 'the mapped position (fg 5:00 − offset 0)');
  });

  testWidgets('an unusable timeline restarts 副音 instead of pausing it',
      (tester) async {
    // A duration the probe never resolved: nothing can be located in the looping
    // timeline, so the fallback must keep 副音 audible — here by looping the
    // single-entry list onto itself.
    await _mountSingleBg(tester, engine, bgDuration: Duration.zero);

    useBackgroundPlaybackStore().requestBgContinuation(fromAlign: false);
    engine.poke();
    await tester.pump();
    // The fallback walks the queue THROUGH the store, which records the new
    // occurrence on the background scenario — real (DB) async work — so let it
    // settle outside the fake-async zone of the pump.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(engine.isPlaying, isTrue);
    expect(engine.replays, greaterThanOrEqualTo(1));
  });

  testWidgets(
      'a natural cross-file continuation keeps the pinned virtual offset',
      (tester) async {
    // Two real files with DB durations, so file B starts a whole file (10min)
    // into the queue's VIRTUAL axis. The alignment on file A (index 0) pins a
    // file-local offset; the continuation onto B must NOT re-derive it against
    // B's (larger) prefix — that shifted the pair by a whole file duration and
    // made the 高同步 correction chase a phantom drift.
    await DbModule.mediaNodesDao.deleteByStorage('s1');
    for (final name in const ['a.mp4', 'b.mp4']) {
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 's1:$name',
        storageId: 's1',
        path: <String>[name],
        name: name,
        mediaType: MediaType.video,
        durationMs: 600000,
      ));
    }
    final FileItem a = _fs('s1', 'a.mp4');
    final FileItem b = _fs('s1', 'b.mp4');
    // Self-check: file B must really start a whole file into the virtual axis,
    // otherwise the freeze assertion below could pass trivially.
    final resolved = await resolvedBgDurationsByKey(<FileItem>[a, b]);
    expect(resolved[backgroundMediaKey(a)], 600000);
    expect(resolved[backgroundMediaKey(b)], 600000);

    await _mountBg(
      tester,
      engine,
      queue: <FileItem>[a, b],
      openFile: a,
      bgDuration: const Duration(minutes: 10),
      bgPosition: Duration.zero,
    );

    final bg = useBackgroundPlaybackStore();
    final int? pinned = bg.state.alignVirtualOffsetMs;
    expect(pinned, isNotNull,
        reason: 'the first open of the run aligns and pins the offset');
    expect(bg.state.alignOffsetAnchorIndex, 0);
    // File A starts the axis, so the pin IS the file-local offset.
    expect(pinned, bg.state.alignOffsetMs);

    // The natural continuation moves the queue onto B WITHOUT re-aligning (a
    // completion open leaves the alignment chain alone: `firstAlignDoneForRun`).
    engine.file = b;
    engine.duration = const Duration(minutes: 10);
    engine.position = Duration.zero;
    bg.set(bg.state.copyWith(currentIndex: 1));
    engine.poke();
    await tester.pumpAndSettle();

    expect(bg.state.alignVirtualOffsetMs, pinned,
        reason: "the pair's queue-VIRTUAL offset must survive the switch");
  });

  testWidgets(
      "a window rebuild re-derives the pin from the aligned file's NEW prefix",
      (tester) async {
    // A shuffle toggle / a candidate re-resolve / a tag sync rebuilds the
    // window UNDERNEATH the run: the same file keeps playing, but the aligned
    // file now sits at a NEW index, so its prefix — and therefore the pin
    // (`fileLocalOffset - prefix`) — changed. Keeping the old pin left the pair
    // off by the prefix difference, which the 高同步 correction then chased.
    await DbModule.mediaNodesDao.deleteByStorage('s1');
    for (final name in const ['a.mp4', 'b.mp4']) {
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 's1:$name',
        storageId: 's1',
        path: <String>[name],
        name: name,
        mediaType: MediaType.video,
        durationMs: 600000,
      ));
    }
    final FileItem a = _fs('s1', 'a.mp4');
    final FileItem b = _fs('s1', 'b.mp4');

    await _mountBg(
      tester,
      engine,
      queue: <FileItem>[a, b],
      openFile: a,
      bgDuration: const Duration(minutes: 10),
      bgPosition: const Duration(minutes: 1),
    );

    final bg = useBackgroundPlaybackStore();
    // Publish the alignment AFTER mounting so it outranks the automatic rule,
    // which would otherwise anchor the fg moment inside the file (sameClock).
    bg.setAlignOffset(3000);
    engine.poke();
    await tester.pumpAndSettle();

    expect(bg.state.alignVirtualOffsetMs, 3000,
        reason: 'A starts the first window, so its prefix is 0');
    expect(bg.state.alignOffsetAnchorKey, backgroundMediaKey(a),
        reason: 'the pin records WHICH file it belongs to');

    // Same open file, new order: A is now a whole file into the virtual axis.
    bg.set(bg.state.copyWith(
      queue: <FileItem>[b, a],
      currentIndex: 1,
      queueTotal: 2,
    ));
    await tester.pump();
    // Resolving the new window's durations is real (DB) work.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(bg.state.alignOffsetMs, 3000,
        reason: 'the file-local anchor itself is unchanged');
    expect(
      bg.state.alignVirtualOffsetMs,
      3000 - 600000,
      reason: "the pin must be re-derived from A's prefix in the NEW window "
          '(3000 − 600000), not kept from the old one',
    );
    expect(bg.state.alignOffsetAnchorIndex, 1);
  });

  testWidgets(
      'an alignment continuation past a non-looping list does not raise '
      'the explainer', (tester) async {
    // A 2min 副音 list, non-looping, with the video at 5:00: a user alignment
    // (offset 0) maps the current fg moment PAST the list end, so the
    // continuation can only clamp onto the last entry's tail — a landing that
    // instantly re-completes. The explainer would promise exactly that, so it
    // must be skipped and 副音 stopped instead.
    await _mountBg(
      tester,
      engine,
      queue: <FileItem>[_f('b1')],
      openFile: _f('b1'),
      bgDuration: const Duration(minutes: 2),
      bgRepeat: Repeat.none,
    );
    final bg = useBackgroundPlaybackStore();
    // Publish the user alignment AFTER mounting so it outranks the auto rule
    // (which would otherwise anchor the fg moment WITHIN the file).
    bg.setAlignOffset(0);
    engine.poke();
    await tester.pumpAndSettle();

    bg.requestBgContinuation(fromAlign: true);
    engine.poke();
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.queue_music_rounded), findsNothing,
        reason: 'a past-the-end alignment must not raise the explainer');
    expect(engine.isPlaying, isFalse);
  });

  testWidgets(
      'the pin is withheld while the prefix through the current file is '
      'still unresolved (no phantom drift)', (tester) async {
    // File A (index 0) has NO resolved duration while the pair is aligned on
    // file B (index 1). `offsetOf(B)` would then be derived from an understated
    // prefix; the probe landing later moves `offsetOf(B)` while
    // `offsetOf(anchor)` stays put, and the 高同步 correction chases the
    // difference — the phantom drift. The pin must stay unset (the mirror
    // stands down) until the prefix is known.
    await DbModule.mediaNodesDao.deleteByStorage('s1');
    // Only B carries a duration; A is the unresolved prefix entry.
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 's1:b.mp4',
      storageId: 's1',
      path: <String>['b.mp4'],
      name: 'b.mp4',
      mediaType: MediaType.video,
      durationMs: 600000,
    ));
    final FileItem a = _fs('s1', 'a.mp4');
    final FileItem b = _fs('s1', 'b.mp4');

    await _mountBg(
      tester,
      engine,
      queue: <FileItem>[a, b],
      openFile: b,
      bgDuration: const Duration(minutes: 10),
      alignOffsetMs: 0,
    );

    final bg = useBackgroundPlaybackStore();
    expect(bg.state.currentIndex, 1);
    expect(bg.state.alignVirtualOffsetMs, isNull,
        reason: 'an unresolved entry before the current file must withhold the '
            'pin, not derive one from an understated prefix');
  });

  testWidgets('the pin IS derived once the prefix through the anchor is known',
      (tester) async {
    // The control for the test above: the same shape with both durations
    // resolved must pin (otherwise the gate could pass trivially).
    await DbModule.mediaNodesDao.deleteByStorage('s1');
    for (final name in const ['a.mp4', 'b.mp4']) {
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 's1:$name',
        storageId: 's1',
        path: <String>[name],
        name: name,
        mediaType: MediaType.video,
        durationMs: 600000,
      ));
    }
    final FileItem a = _fs('s1', 'a.mp4');
    final FileItem b = _fs('s1', 'b.mp4');

    await _mountBg(
      tester,
      engine,
      queue: <FileItem>[a, b],
      openFile: b,
      bgDuration: const Duration(minutes: 10),
      alignOffsetMs: 0,
    );

    final bg = useBackgroundPlaybackStore();
    expect(bg.state.alignVirtualOffsetMs, -600000,
        reason: 'B starts a whole file (A) into the axis: 0 − 600000');
    expect(bg.state.alignOffsetAnchorIndex, 1);
  });
}
