import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/services/background_sync_logic.dart';
import 'package:iris/features/background_playback/model/enum/bg_align_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/model/enum/bg_seek_link.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/background_runtime_scope.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart' show PlayerBackend;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// The runtime observer's mirrors must respect the 作用范围 and must not let a
/// DEAD 副音 runtime dictate the foreground.
///
/// Three reported defects, one family:
/// - 仅当前 + fg A → B: the scope observer pauses 副音, then the transport
///   mirror (which only looked at `enabled && gateOpen`) read "fg playing /
///   bg paused" as a disagreement and resumed 副音 — the run stayed 激活.
/// - Switching 副音 on hands the master to the secondary runtime
///   (`autoFocusControl`), so while it had not started (no file / failed open)
///   the mirror paused the video: "点开副音导致播放暂停".
/// - The same master side maps its position onto the foreground and rolls the
///   queue when the target leaves the file: a transient drift must never
///   cross-file roll.
FileItem _f(String key) =>
    FileItem(name: key, uri: 'file:///$key', path: [key]);

class _FgProbe {
  final List<String> calls = <String>[];
  bool playing;
  _FgProbe({required this.playing, this.positionMs = 5000, this.isInitializing = false});

  /// Foreground position the probe reports. The mirror's drift correction is
  /// judged against it, so a test can place the video far from 00:00.
  final int positionMs;

  /// A media OPEN is in flight (the next file is loading).
  final bool isInitializing;

  MediaPlayer build() => MediaPlayer(
        isInitializing: isInitializing,
        isPlaying: playing,
        externalSubtitles: const [],
        position: Duration(milliseconds: positionMs),
        duration: const Duration(minutes: 10),
        buffer: Duration.zero,
        width: 0,
        height: 0,
        saveProgress: () async {},
        play: () async => calls.add('play'),
        pause: () async => calls.add('pause'),
        backward: (_) async => calls.add('backward'),
        forward: (_) async => calls.add('forward'),
        stepBackward: () async => calls.add('stepBackward'),
        stepForward: () async => calls.add('stepForward'),
        seek: (_) async => calls.add('seek'),
      );
}

Widget _harness({required MediaPlayer player, required engine}) =>
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
        home: ChangeNotifierProvider<BackgroundPlaybackEngine>.value(
          value: engine,
          child: Provider<MediaPlayer>.value(
            value: player,
            // NOT `const`: a const (canonicalized) widget is `identical` to the
            // previous one, so `pumpWidget` would skip the rebuild and a test
            // that re-mounts for a NEW foreground would keep reading the old
            // one.
            child: BackgroundRuntimeScope(child: const SizedBox.shrink()),
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

  late BackgroundPlaybackEngine engine;

  setUp(() async {
    final app = useAppStore();
    app.set(app.state.copyWith(
      useMetadataSettings: true,
      useLegacyStoragePersistence: false,
    ));
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    await usePlayQueueStore().initialized;
    engine = BackgroundPlaybackEngine(
      backend: PlayerBackend.mediaKit,
      attachNative: false,
    );
  });

  tearDown(() {
    engine.dispose();
    StoreLocator().delete(BackgroundPlaybackStore);
    StoreLocator().delete(UnifiedPlayQueueStore);
    StoreLocator().delete(AppStore);
  });

  Future<void> mount(
    WidgetTester tester, {
    required _FgProbe fg,
    required ControlTarget target,
    required String anchor,
    required String foreground,
    FileItem? loadedBg,
    int? alignOffsetMs,
    int bgPositionMs = 0,
    bool bgPlaying = false,
    Duration bgDuration = const Duration(minutes: 10),
    ControlTarget displayTarget = ControlTarget.foreground,
    /// Keeps the SESSION alignment / stop flags instead of re-seeding them: used
    /// by tests that switch the media mid-run and expect the observer's own
    /// teardown to do the clearing.
    bool keepSession = false,
    /// A MULTI-ITEM foreground queue (names), for the tests that drive a real
    /// `next()` / `previous()` instead of re-mounting on one fixed file.
    List<String>? foregroundQueue,
    int foregroundPosition = 0,
    BgApplyScope applyScope = BgApplyScope.currentOnly,
    /// A multi-item 副音 queue (names) + where it sits, so a step has somewhere
    /// to land and the direction is observable in `currentIndex`.
    List<String>? bgQueue,
    int bgIndex = 0,
  }) async {
    final List<String> fgNames = foregroundQueue ?? <String>[foreground];
    await usePlayQueueStore().update(
      playQueue: [
        for (var i = 0; i < fgNames.length; i++)
          PlayQueueItem(file: _f(fgNames[i]), index: i),
      ],
      index: foregroundPosition,
    );
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(
      enabled: true,
      gateOpen: true,
      controlTarget: target,
      displayTarget: displayTarget,
      applyScope: applyScope,
      scopeAnchorKey: anchor,
      bgAutoPlay: false,
      bgExhausted: false,
      // Session stop flags from a previous test must not leak: each mount is a
      // fresh pair in scope.
      bgOutOfScope: keepSession ? bg.state.bgOutOfScope : false,
      bgQueueEnded: keepSession ? bg.state.bgQueueEnded : false,
      seekLink: BgSeekLink.linked,
      lockLevel: BgLockLevel.high,
      autoFocusControl: true,
      alignOffsetMs: keepSession ? bg.state.alignOffsetMs : alignOffsetMs,
      // A live run needs an open target; an EMPTY queue models the "nothing to
      // play" state (the engine was stopped) without touching the DB.
      queue: bgQueue != null
          ? <FileItem>[for (final String n in bgQueue) _f(n)]
          : loadedBg == null
              ? const <FileItem>[]
              : <FileItem>[loadedBg],
      currentIndex: bgQueue != null ? bgIndex : (loadedBg == null ? -1 : 0),
    ));
    engine.file = bgQueue != null ? _f(bgQueue[bgIndex]) : loadedBg;
    engine.duration = bgDuration;
    engine.position = Duration(milliseconds: bgPositionMs);
    engine.isPlaying = bgPlaying;
    await tester.pumpWidget(_harness(player: fg.build(), engine: engine));
    // Deferred ARB loading rebuilds the subtree once, so settle before reading
    // the mirror's outcome.
    await tester.pumpAndSettle();
  }

  testWidgets('仅当前 + 高同步: a 副音 stuck at its head must NOT rewind the video',
      (tester) async {
    // Reported defect: switching 副音 on reset the video's progress to 00:00.
    // 副音 is the master while its alignment seek has not landed yet, so it
    // still reports 0; the continuous drift correction mapped that onto the
    // video and — with 仅当前 clamping a behind-target — issued `seek(0)`.
    final fg = _FgProbe(playing: true, positionMs: 300000);
    await mount(
      tester,
      fg: fg,
      target: ControlTarget.background,
      anchor: backgroundMediaKey(_f('B.mp4')),
      foreground: 'B.mp4',
      loadedBg: _f('b1'),
      alignOffsetMs: 0,
      bgPositionMs: 0,
      bgPlaying: true,
    );

    expect(
      fg.calls,
      isNot(contains('seek')),
      reason: 'a settled drift correction must never rewind the video',
    );
  });

  testWidgets('仅当前: leaving the anchor must NOT resume 副音 through the '
      'transport mirror', (tester) async {
    final fg = _FgProbe(playing: true);
    await mount(
      tester,
      fg: fg,
      target: ControlTarget.foreground,
      anchor: backgroundMediaKey(_f('A.mp4')),
      foreground: 'B.mp4',
      loadedBg: _f('b1'),
    );

    expect(
      useBackgroundPlaybackStore().state.bgAutoPlay,
      isFalse,
      reason: '副音 is out of scope for B — the mirror must not resurrect it',
    );
  });

  testWidgets('仅当前: on the anchor the transport mirror still links 副音',
      (tester) async {
    final fg = _FgProbe(playing: true);
    await mount(
      tester,
      fg: fg,
      target: ControlTarget.foreground,
      anchor: backgroundMediaKey(_f('B.mp4')),
      foreground: 'B.mp4',
      loadedBg: _f('b1'),
    );

    expect(
      useBackgroundPlaybackStore().state.bgAutoPlay,
      isTrue,
      reason: 'in scope + foreground master → 副音 follows the video',
    );
  });

  testWidgets('仅当前: leaving the anchor hands controls and picture back',
      (tester) async {
    final fg = _FgProbe(playing: true);
    await mount(
      tester,
      fg: fg,
      target: ControlTarget.background,
      displayTarget: ControlTarget.background,
      anchor: backgroundMediaKey(_f('A.mp4')),
      foreground: 'B.mp4',
      loadedBg: _f('b1'),
      bgPlaying: true,
    );

    final s = useBackgroundPlaybackStore().state;
    expect(s.bgOutOfScope, isTrue);
    expect(s.bgOwnsControls, isFalse,
        reason: 'the bar must not keep driving a paused 副音 (original report)');
    expect(s.bgOwnsDisplay, isFalse);
    // The routing PREFERENCE is untouched, so returning restores it.
    expect(s.controlTarget, ControlTarget.background);
    expect(s.displayTarget, ControlTarget.background);
  });

  testWidgets('仅当前: returning to the anchor restores the pair automatically',
      (tester) async {
    final fg = _FgProbe(playing: true);
    await mount(
      tester,
      fg: fg,
      target: ControlTarget.background,
      anchor: backgroundMediaKey(_f('A.mp4')),
      foreground: 'B.mp4',
      loadedBg: _f('b1'),
      bgPlaying: true,
    );
    expect(useBackgroundPlaybackStore().state.bgOwnsControls, isFalse);

    // The foreground plays the anchored media again (an episode switched back).
    // Re-mount the same observer against the new queue, as the player page does
    // when the media it shows changes.
    await mount(
      tester,
      fg: fg,
      target: ControlTarget.background,
      anchor: backgroundMediaKey(_f('A.mp4')),
      foreground: 'A.mp4',
      loadedBg: _f('b1'),
      bgPlaying: true,
    );

    final s = useBackgroundPlaybackStore().state;
    expect(s.bgOutOfScope, isFalse);
    expect(s.bgOwnsControls, isTrue);
  });

  testWidgets('a foreground switch while out of scope drops the stale alignment',
      (tester) async {
    // The offset is only meaningful for the media it was derived on. A switch
    // that happens while the pair is STOOD DOWN (仅当前 left its anchor) used to
    // skip the teardown, so widening the 作用范围 to 全部 re-activated the pair on
    // the NEW media with the OLD media's authoritative offset — the mirror then
    // keeps mapping through it (`anchor()` returns early while a pin is set) and
    // the 高同步 correction drags the video to the wrong position.
    final fg = _FgProbe(playing: true);
    await mount(
      tester,
      fg: fg,
      target: ControlTarget.background,
      anchor: backgroundMediaKey(_f('A.mp4')),
      foreground: 'A.mp4',
      loadedBg: _f('b1'),
      bgPlaying: true,
    );
    final bg = useBackgroundPlaybackStore();
    expect(bg.state.alignOffsetMs, isNotNull,
        reason: 'the first open publishes an alignment');

    // The video moves on to B: 仅当前 stands the pair down. Re-mounted the way
    // the player page re-mounts for a new media, but WITHOUT re-seeding the
    // session alignment, so only the observer can clear it.
    await mount(
      tester,
      fg: fg,
      target: ControlTarget.background,
      anchor: backgroundMediaKey(_f('A.mp4')),
      foreground: 'B.mp4',
      loadedBg: _f('b1'),
      bgPlaying: true,
      keepSession: true,
    );
    expect(bg.state.bgOutOfScope, isTrue, reason: 'B is outside 仅当前');
    expect(bg.state.alignOffsetMs, isNull,
        reason: 'the offset described A; it must not survive onto B');

    // Widening to 全部 brings the pair back on B (the app rebuilds through the
    // store notification; this harness has to be re-pumped).
    bg.set(bg.state.copyWith(applyScope: BgApplyScope.all));
    await tester.pumpWidget(_harness(player: fg.build(), engine: engine));
    await tester.pumpAndSettle();
    expect(bg.state.bgOutOfScope, isFalse);
    expect(bg.state.bgPairInEffect, isTrue);
    expect(bg.state.alignOffsetMs, isNull,
        reason: 'no stale pin may drive the video on the new media');
  });

  testWidgets('a dead 副音 runtime must never pause the foreground', (tester) async {
    final fg = _FgProbe(playing: true);
    // controlTarget = background (what `autoFocusControl` sets on activation),
    // but the secondary engine has NO file: it cannot be a master.
    await mount(
      tester,
      fg: fg,
      target: ControlTarget.background,
      anchor: backgroundMediaKey(_f('B.mp4')),
      foreground: 'B.mp4',
    );

    expect(
      fg.calls,
      isEmpty,
      reason: 'an unloaded 副音 engine must not dictate the video transport',
    );
  });

  testWidgets('a cut→cut switch never resumes 副音 while the next media opens',
      (tester) async {
    // Reported shape: 副音 is suspended for cut A, the queue advances to cut B.
    // `noteCutPlaying(null)` runs when B's open starts, so for the length of the
    // open `fakeCutActive` is false while `fgKey` already points at B. Resuming
    // there made 副音 blip for a moment on EVERY cut→cut switch.
    await usePlayQueueStore().update(
      playQueue: [PlayQueueItem(file: _f('B.mp4'), index: 0)],
      index: 0,
    );
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(
      enabled: true,
      gateOpen: true,
      applyScope: BgApplyScope.all,
      bgAutoPlay: false,
      bgExhausted: false,
      bgOutOfScope: false,
      bgQueueEnded: false,
      // What suspendForFakeCut remembers about a run that WAS sounding.
      bgSuspendedByFakeCut: true,
      fakeCutHeldRouting: true,
      // Sentinel: only `resumeAfterFakeCut` clears these two slots.
      controlTargetBeforeFakeCut: ControlTarget.background,
      displayTargetBeforeFakeCut: ControlTarget.background,
    ));
    engine.file = _f('b1');
    engine.isPlaying = false;

    // The new media is still opening: the resume must wait.
    await tester.pumpWidget(
        _harness(player: _FgProbe(playing: true, isInitializing: true).build(), engine: engine));
    await tester.pumpAndSettle();
    expect(bg.state.controlTargetBeforeFakeCut, ControlTarget.background,
        reason: 'the gap that sounded 副音 through a cut→cut switch must not '
            'restore the pair while the next media is still opening');

    // The open settled and the media is NOT a cut (the cut flag stays clear):
    // the pair comes back now.
    await tester.pumpWidget(
        _harness(player: _FgProbe(playing: true).build(), engine: engine));
    await tester.pumpAndSettle();
    expect(bg.state.controlTargetBeforeFakeCut, ControlTarget.foreground,
        reason: 'leaving the cut must still restore the pair once the open '
            'settles');
  });

  group('the automatic anchoring rule, applied by the runtime observer', () {
    testWidgets('副音 shorter than the video: 尾部锚定 (ends with the video)',
        (tester) async {
      // fg 10min at 5min → 5min left, 副音 6min: the 副音's END is put on the
      // video's END, so it starts at 1min and the offset is fgDur - bgDur.
      final fg = _FgProbe(playing: true, positionMs: 300000);
      await mount(
        tester,
        fg: fg,
        target: ControlTarget.background,
        anchor: backgroundMediaKey(_f('B.mp4')),
        foreground: 'B.mp4',
        loadedBg: _f('b1'),
        bgDuration: const Duration(minutes: 6),
        bgPlaying: true,
      );

      final bg = useBackgroundPlaybackStore();
      expect(bg.state.alignMode, BgAlignMode.tailAtFg);
      expect(bg.state.alignOffsetMs, 240000, reason: 'fgDur - bgDur');
      expect(
        fg.calls,
        isNot(contains('seek')),
        reason: 'the tail anchor must never rewind the video either',
      );
    });

    testWidgets('副音 shorter than the video REMAINDER: it starts from its head',
        (tester) async {
      // fg 10min at 5min → 5min left, 副音 2min cannot cover it, so a tail anchor
      // is impossible: the 副音 starts at its 00:00 at the current position.
      final fg = _FgProbe(playing: true, positionMs: 300000);
      await mount(
        tester,
        fg: fg,
        target: ControlTarget.background,
        anchor: backgroundMediaKey(_f('B.mp4')),
        foreground: 'B.mp4',
        loadedBg: _f('b1'),
        bgDuration: const Duration(minutes: 2),
        bgPlaying: true,
      );

      final bg = useBackgroundPlaybackStore();
      expect(bg.state.alignMode, BgAlignMode.bgHeadAtFg);
      expect(bg.state.alignOffsetMs, 300000, reason: 'the current fg moment');
    });

    testWidgets('副音 longer than the video: 同刻度 (offset 0)', (tester) async {
      final fg = _FgProbe(playing: true, positionMs: 300000);
      await mount(
        tester,
        fg: fg,
        target: ControlTarget.background,
        anchor: backgroundMediaKey(_f('B.mp4')),
        foreground: 'B.mp4',
        loadedBg: _f('b1'),
        bgDuration: const Duration(minutes: 12),
        bgPlaying: true,
      );

      final bg = useBackgroundPlaybackStore();
      expect(bg.state.alignMode, BgAlignMode.sameClock);
      expect(bg.state.alignOffsetMs, 0);
    });
  });

  group('副音 步进方向 (a foreground step carries its own direction)', () {
    testWidgets('「上一集」 at the head steps 副音 BACK, not forward',
        (tester) async {
      // Reported defect: pressing 「上一集」 while on the first episode wrapped
      // the video onto the LAST one, and 副音 stepped FORWARD. Both directions
      // of a wrap look identical from the item ids (`first → last` is also what
      // tapping the last row produces), so only the queue's own stamp can tell
      // them apart.
      final fg = _FgProbe(playing: true);
      await mount(
        tester,
        fg: fg,
        target: ControlTarget.background,
        anchor: backgroundMediaKey(_f('A.mp4')),
        foreground: 'A.mp4',
        foregroundQueue: const ['A.mp4', 'B.mp4', 'C.mp4'],
        // 全部: a new list item is not a 作用范围 change, so the cross step is
        // allowed (仅当前 would pause the pair instead).
        applyScope: BgApplyScope.all,
        bgQueue: const ['b1', 'b2', 'b3'],
        bgIndex: 1,
      );
      final bg = useBackgroundPlaybackStore();
      expect(bg.state.currentIndex, 1, reason: 'precondition: 副音 on b2');

      await usePlayQueueStore().previous();
      await tester.pumpWidget(_harness(player: fg.build(), engine: engine));
      await tester.pumpAndSettle();

      expect(bg.state.currentIndex, 0,
          reason: '副音 must follow the video BACK, not step past it');
    });
  });

  group('resolveBgMasterFgAction roll authority', () {
    test('a target past the file holds when a roll is not earned', () {
      expect(
        resolveBgMasterFgAction(fgTarget: 90000, fgDurMs: 60000),
        BgMasterFgAction.roll,
        reason: 'a real 副音 seek still rolls the foreground',
      );
      expect(
        resolveBgMasterFgAction(
          fgTarget: 90000,
          fgDurMs: 60000,
          allowRoll: false,
        ),
        BgMasterFgAction.hold,
        reason: 'a transient drift must never cross-file roll',
      );
    });

    test('a negative target holds when a roll is not earned', () {
      expect(
        resolveBgMasterFgAction(fgTarget: -500, fgDurMs: 60000, allowRoll: false),
        BgMasterFgAction.hold,
      );
    });

    test('an in-range target seeks even without roll authority', () {
      expect(
        resolveBgMasterFgAction(
          fgTarget: 10000,
          fgDurMs: 60000,
          allowRoll: false,
        ),
        BgMasterFgAction.seek,
      );
    });

    test('an unknown duration never rolls', () {
      expect(
        resolveBgMasterFgAction(
          fgTarget: 90000,
          fgDurMs: 0,
          allowRoll: false,
        ),
        BgMasterFgAction.seek,
      );
    });
  });
}
