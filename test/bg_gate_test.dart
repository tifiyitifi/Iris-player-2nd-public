import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_scope_logic.dart';
import 'package:iris/features/background_playback/model/background_playback_state.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/model/enum/bg_gate_stop_behavior.dart';
import 'package:iris/features/background_playback/model/enum/bg_reactivate_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_seek_link.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/store/use_play_queue_store.dart';
import 'package:zustand/zustand.dart';

FileItem _f(String key) =>
    FileItem(name: key, uri: 'file:///$key', path: [key]);

/// The quick-bar gate is a PURE play/stop permission (never a subsystem power
/// switch), and an explicit stop latches closed across every scope until the
/// user opens it again. `startArmed` arms the run on a cold launch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late BackgroundPlaybackStore store;

  setUp(() async {
    store = BackgroundPlaybackStore();
    await store.initialized;
    // The double-play guard reads the foreground identity from the play queue.
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
  });

  tearDown(() {
    StoreLocator().delete(BackgroundPlaybackStore);
    StoreLocator().delete(UnifiedPlayQueueStore);
    store.dispose();
  });

  test('stopGate is a pure stop: run, queue, index and opt-outs survive',
      () async {
    await store.enableWithQueue(
      [_f('b1'), _f('b2')],
      applyScope: BgApplyScope.currentOnly,
      anchorKey: 'fg',
    );
    final int idx = store.state.currentIndex;

    store.stopGate();

    expect(store.state.enabled, isTrue, reason: 'never disables the run');
    expect(store.state.gateOpen, isFalse);
    expect(store.state.bgAutoPlay, isFalse);
    expect(store.state.currentIndex, idx, reason: 'queue position retained');
    expect(store.state.queue, hasLength(2));
    expect(store.state.bgOffMediaKeys, isEmpty,
        reason: 'the gate never writes a per-media opt-out');
  });

  test('openGate keeps the loaded track unless stepForward is set', () async {
    await store.enableWithQueue([_f('b1'), _f('b2'), _f('b3')]);
    store.jumpTo(1);
    store.stopGate();

    store.openGate(mediaKey: 'fg');
    expect(store.state.currentIndex, 1, reason: 'sameBg keeps the file');
    expect(store.state.gateOpen, isTrue);
    expect(store.state.bgAutoPlay, isTrue);

    store.stopGate();
    store.openGate(mediaKey: 'fg', stepForward: true);
    expect(store.state.currentIndex, 2, reason: 'nextBg advances one step');
  });

  test('openGate wraps a single-item queue onto itself', () async {
    await store.enableWithQueue([_f('only')]);
    store.stopGate();

    store.openGate(mediaKey: 'fg', stepForward: true);
    expect(store.state.currentIndex, 0);
  });

  test('openGate stepForward at the pool end STOPS instead of replaying',
      () async {
    // Repeat.none, already on the last entry: 下一首 has nowhere to go. It must
    // keep the loaded track PAUSED and must not restart the run — bumping the run
    // with the stale index re-opened (replayed) the same last track.
    await store.enableWithQueue([_f('b1'), _f('b2')]);
    store.set(store.state.copyWith(bgRepeat: Repeat.none));
    await store.jumpTo(1);
    store.stopGate();
    final int runSeq = store.state.bgRunSeq;

    store.openGate(mediaKey: 'fg', stepForward: true);

    expect(store.state.currentIndex, 1, reason: 'nowhere to advance to');
    expect(store.state.bgAutoPlay, isFalse,
        reason: 'a blocked 下一首 must not replay the loaded track');
    expect(store.state.bgRunSeq, runSeq,
        reason: 'nothing moved, so the run must not restart');
  });

  test('openGate stepForward all-excluded stays paused and does not restart',
      () async {
    // Every candidate is the foreground file: the guard skips them all, so this
    // is the same "blocked" verdict as Repeat.none at the end.
    final fg = _f('fg.mp4');
    await usePlayQueueStore().update(
      playQueue: [PlayQueueItem(file: fg, index: 0)],
      index: 0,
    );
    store.set(store.state.copyWith(shuffle: false));
    await store.enableWithQueue(
      [fg, _f('fg.mp4')],
      applyScope: BgApplyScope.currentOnly,
      anchorKey: 'fg',
    );
    await store.jumpTo(0);
    store.stopGate();
    final int runSeq = store.state.bgRunSeq;

    store.openGate(mediaKey: 'fg', stepForward: true);

    expect(store.state.bgAutoPlay, isFalse);
    expect(store.state.bgRunSeq, runSeq);
  });

  test('openGate stepForward skips the foreground file (double-play guard)',
      () async {
    // The foreground file is ALSO a queue entry; 下一首 re-activation must not
    // land on it (that would double-play one file on both engines).
    final fg = _f('fg.mp4');
    await usePlayQueueStore().update(
      playQueue: [PlayQueueItem(file: fg, index: 0)],
      index: 0,
    );

    store.set(store.state.copyWith(shuffle: false));
    await store.enableWithQueue(
      [_f('b1'), fg, _f('b2')],
      applyScope: BgApplyScope.currentOnly,
      anchorKey: 'fg',
    );
    store.jumpTo(0);
    store.stopGate();

    store.openGate(mediaKey: 'fg', stepForward: true);

    expect(store.state.currentIndex, 2,
        reason: 'the excluded foreground file is skipped, not double-played');
    expect(store.state.queue[2].name, 'b2');
  });

  test('openGate clears the current media opt-out and re-anchors', () async {
    await store.enableWithQueue(
      [_f('b1')],
      applyScope: BgApplyScope.currentOnly,
      anchorKey: 'old',
    );
    store.closeScopeForMedia('fg');

    store.openGate(mediaKey: 'fg');
    expect(store.state.bgOffMediaKeys, isNot(contains('fg')));
    expect(store.state.scopeAnchorKey, 'fg');
  });

  test('armRunStopped arms the run without playing and leaves the gate shut',
      () async {
    await store.disable();

    store.armRunStopped();

    expect(store.state.enabled, isTrue);
    expect(store.state.gateOpen, isFalse,
        reason: 'feature on, stopped — only the quick bar opens the gate');
    expect(store.state.bgAutoPlay, isFalse, reason: 'armed, never auto-plays');
    expect(store.state.currentIndex, -1);
    expect(store.state.controlTarget.name, 'foreground');
  });

  test('cold load arms from startArmed (default on) but keeps the gate shut',
      () {
    final armed = BackgroundPlaybackStore.normalizeLoaded(
      const BackgroundPlaybackState(),
    );
    expect(armed.enabled, isTrue);
    expect(armed.gateOpen, isFalse,
        reason: 'a cold launch must never auto-start 副音');
    expect(armed.bgAutoPlay, isFalse);
    expect(armed.currentIndex, -1);

    final off = BackgroundPlaybackStore.normalizeLoaded(
      const BackgroundPlaybackState(startArmed: false),
    );
    expect(off.enabled, isFalse);
    expect(off.gateOpen, isFalse);
  });

  test('resumeForScope respects the closed gate', () async {
    await store.enableWithQueue([_f('b1')], anchorKey: 'fg');
    store.stopGate();

    store.resumeForScope();
    expect(store.state.bgAutoPlay, isFalse,
        reason: 'a latched stop must survive a scope resume');

    store.openGate(mediaKey: 'fg');
    store.resumeForScope();
    expect(store.state.bgAutoPlay, isTrue);
  });

  test('a closed gate suppresses resume and saved-mapping start', () {
    expect(
      resolveBgScopeOnFgChange(
        enabled: true,
        applyScope: BgApplyScope.currentOnly,
        anchorKey: 'fg',
        newFgKey: 'fg',
        gateOpen: false,
      ),
      BgScopeAction.none,
    );
    expect(
      resolveBgScopeOnFgChange(
        enabled: true,
        applyScope: BgApplyScope.smart,
        anchorKey: 'fg',
        newFgKey: 'other',
        newFgHasSavedMapping: true,
        gateOpen: false,
      ),
      BgScopeAction.none,
    );
    // Gate open: the existing scope behavior is unchanged.
    expect(
      resolveBgScopeOnFgChange(
        enabled: true,
        applyScope: BgApplyScope.currentOnly,
        anchorKey: 'fg',
        newFgKey: 'fg',
      ),
      BgScopeAction.resumeBg,
    );
  });

  test('reactivate mode defaults to next and round-trips', () async {
    expect(store.state.bgReactivateMode, BgReactivateMode.nextBg);

    await store.setBgReactivateMode(BgReactivateMode.sameBg);
    expect(store.state.bgReactivateMode, BgReactivateMode.sameBg);
  });

  test('startArmed defaults on and is settable', () async {
    expect(store.state.startArmed, isTrue);

    await store.setStartArmed(false);
    expect(store.state.startArmed, isFalse);
  });

  test('gate stop behavior defaults to pause and round-trips', () async {
    expect(store.state.gateStopBehavior, BgGateStopBehavior.pause);

    await store.setGateStopBehavior(BgGateStopBehavior.unload);
    expect(store.state.gateStopBehavior, BgGateStopBehavior.unload);
  });

  test('stopGate hands the controls and the picture back to the foreground',
      () async {
    await store.enableWithQueue([_f('b1'), _f('b2')], focusControl: true);
    await store.setDisplayTarget(ControlTarget.background);
    expect(store.state.controlTarget, ControlTarget.background);
    expect(store.state.displayTarget, ControlTarget.background);

    store.stopGate();

    expect(store.state.gateOpen, isFalse);
    expect(store.state.controlTarget, ControlTarget.foreground,
        reason: 'deactivation must leave the shared controls on the video');
    expect(store.state.displayTarget, ControlTarget.foreground,
        reason: 'deactivation must leave the fg picture on screen');
  });

  test('stopGate never rewrites the linkage settings', () async {
    await store.enableWithQueue([_f('b1')]);
    await store.setLockLevel(BgLockLevel.low);
    expect(store.state.seekLink, BgSeekLink.linked);

    store.stopGate();

    expect(store.state.seekLink, BgSeekLink.linked,
        reason: 'the saved preference survives the deactivation');
    expect(store.state.lockLevel, BgLockLevel.low,
        reason: 'the saved preference survives the deactivation');
  });

  test('a user pause keeps the activation (gate stays open)', () async {
    await store.enableWithQueue([_f('b1')], focusControl: true);

    // The transport pause owns bgAutoPlay only — never the activation.
    store.setPlaying(false);

    expect(store.state.gateOpen, isTrue,
        reason: 'pausing bg must not cancel the activation');
    expect(store.state.bgAutoPlay, isFalse);
    expect(store.state.controlTarget, ControlTarget.background,
        reason: 'the paused bg still owns the controls until deactivation');

    // A later gate press deactivates from the paused state, too.
    store.stopGate();
    expect(store.state.gateOpen, isFalse);
    expect(store.state.controlTarget, ControlTarget.foreground);
    expect(store.state.displayTarget, ControlTarget.foreground);
  });

  test('openGate honors the auto-focus preference (picture untouched)',
      () async {
    await store.enableWithQueue([_f('b1')], focusControl: false);
    expect(store.state.controlTarget, ControlTarget.foreground);
    store.stopGate();

    store.openGate(mediaKey: 'fg');

    expect(store.state.controlTarget, ControlTarget.background,
        reason: 'activation follows 开启副音时先切换控制权 (default on)');
    expect(store.state.displayTarget, ControlTarget.foreground,
        reason: 'activation never steals the picture');

    await store.setAutoFocusControl(false);
    store.stopGate();
    store.openGate(mediaKey: 'fg');
    expect(store.state.controlTarget, ControlTarget.foreground,
        reason: 'auto-focus off keeps the video controllable on activation');
  });

  test('stopGate drops any active mapped/silence session (统一退出)', () async {
    await store.enableWithQueue([_f('b1'), _f('b2')]);
    await store.enterMappedSegment(
      _f('mapped'),
      targetMs: 1000,
      rate: 1.0,
    );
    store.silenceHold();

    store.stopGate();

    expect(store.state.gateOpen, isFalse);
    expect(store.state.mappedFile, isNull);
    expect(store.state.mappedSilenceOn, isFalse,
        reason: 'a gate stop must leave 副音 unable to sound');
    expect(store.state.enabled, isTrue, reason: 'still never disables the run');
    expect(store.state.queue, hasLength(2));
  });

  test('openGate(autoplay: false) opens the gate without starting transport',
      () async {
    await store.enableWithQueue([_f('b1')], focusControl: false);
    store.stopGate();

    store.openGate(mediaKey: 'fg', autoplay: false);

    expect(store.state.gateOpen, isTrue, reason: 'the permission is granted');
    expect(store.state.bgAutoPlay, isFalse,
        reason: 'a paused foreground must not be force-played on activation');
  });

  test('resumeForScope(play: false) keeps 副音 paused on a paused foreground',
      () async {
    await store.enableWithQueue([_f('b1')], anchorKey: 'fg');
    store.pauseForScope();

    store.resumeForScope(play: false);

    expect(store.state.bgAutoPlay, isFalse,
        reason: 'returning to the anchor must respect the paused video');
  });

  test('setPlaying cannot reopen transport while the gate is closed', () async {
    await store.enableWithQueue([_f('b1')], anchorKey: 'fg');
    store.stopGate();
    expect(store.state.gateOpen, isFalse);
    expect(store.state.bgAutoPlay, isFalse);

    store.setPlaying(true);

    expect(store.state.bgAutoPlay, isFalse,
        reason: 'a closed gate owns the transport and cannot be revived');
  });
}
