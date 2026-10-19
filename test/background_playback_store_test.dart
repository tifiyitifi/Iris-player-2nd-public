import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/model/background_playback_state.dart';
import 'package:iris/features/background_playback/model/enum/bg_video_layout.dart';
import 'package:iris/features/background_playback/model/enum/bg_step_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_exhausted_action.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;

FileItem _f(String key) => FileItem(name: key, uri: 'file:///$key', path: [key]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  final files = [_f('a'), _f('b'), _f('c')];

  group('persisted JSON shape', () {
    test('session fields never serialize (reload re-arms, never plays)', () {
      final state = const BackgroundPlaybackState().copyWith(
        enabled: true,
        controlTarget: ControlTarget.background,
        currentIndex: 2,
        bgAutoPlay: true,
        showBgVideo: true,
        fgMuted: true,
        bgMuted: true,
        queue: files,
      );
      final encoded = json.encode(state.toJson());
      expect(encoded.contains('"enabled"'), isFalse);
      expect(encoded.contains('"currentIndex"'), isFalse);
      expect(encoded.contains('"controlTarget"'), isFalse);

      final decoded = BackgroundPlaybackStore.normalizeLoaded(
        BackgroundPlaybackState.fromJson(json.decode(encoded)),
      );
      // 开机状态: the cold-load normalizer re-arms per startArmed (default on)
      // but keeps the gate shut, clears every session field and never
      // auto-plays.
      expect(decoded.enabled, isTrue);
      expect(decoded.gateOpen, isFalse);
      expect(decoded.currentIndex, -1);
      expect(decoded.controlTarget, ControlTarget.foreground);
      expect(decoded.bgAutoPlay, isFalse);
      expect(decoded.showBgVideo, isTrue);
      expect(decoded.fgMuted, isTrue);
      expect(decoded.bgMuted, isTrue);
      expect(decoded.queue, hasLength(3));
      expect(decoded.bgRepeat, Repeat.all);
    });

    test('normalizeLoaded clamps corrupt persisted prefs', () {
      final state = const BackgroundPlaybackState().copyWith(
        fgVolumePercent: 999,
        bgVolumePercent: -4,
        rate: 0,
      );
      final out = BackgroundPlaybackStore.normalizeLoaded(state);
      expect(out.fgVolumePercent, 100);
      expect(out.bgVolumePercent, 0);
      expect(out.rate, 1.0);
    });

    test('video layout persists; session fields stay excluded', () {
      final state = const BackgroundPlaybackState().copyWith(
        bgVideoLayout: BgVideoLayout.split,
        bgPanelVisible: false,
      );
      final encoded = json.encode(state.toJson());
      expect(encoded.contains('"bgVideoLayout"'), isTrue);
      expect(encoded.contains('split'), isTrue);
      expect(encoded.contains('"bgPanelVisible"'), isFalse,
          reason: 'collapse state is session-only (hidden != closed)');

      final decoded = BackgroundPlaybackStore.normalizeLoaded(
        BackgroundPlaybackState.fromJson(json.decode(encoded)),
      );
      expect(decoded.bgVideoLayout, BgVideoLayout.split);
      // Collapse state is never restored from disk: next session opens full.
      expect(decoded.bgPanelVisible, isTrue);
    });
  });

  group('BackgroundPlaybackStore behaviors', () {
    late BackgroundPlaybackStore store;

    setUp(() async {
      store = BackgroundPlaybackStore();
      await store.initialized;
    });

    tearDown(() => store.dispose());

    test('a fresh enable re-arms the duration probe', () async {
      // A member that failed on the last run must be retried: the verdict sets
      // gate which entries the probe observer will try, so a stale failure kept
      // the run red until an app restart.
      store.set(store.state.copyWith(
        enabled: true,
        bgDurationFailedKeys: const {'s1:a'},
        bgDurationUnknownKeys: const {'s1:b'},
      ));
      final before = store.state.bgDurationProbeSeq;

      await store.enableWithQueue(files);

      expect(store.state.bgDurationFailedKeys, isEmpty);
      expect(store.state.bgDurationUnknownKeys, isEmpty);
      expect(store.state.bgDurationProbeSeq, before + 1,
          reason: 'the observer fingerprints on the seq, so it must change');
    });

    test('enableWithQueue starts at index 0 and refuses empty',
        () async {
      await store.enableWithQueue(files);
      expect(store.state.enabled, isTrue);
      expect(store.state.currentIndex, 0);
      expect(store.state.bgAutoPlay, isTrue);
      expect(store.state.queue.toSet(), files.toSet());

      final before = store.state.queue.length;
      await store.enableWithQueue(const []);
      expect(store.state.queue, hasLength(before));
    });

    test('disable clears the session and returns the target to foreground',
        () async {
      await store.enableWithQueue(files);
      // Starting 副音 focuses the controls (autoFocusControl defaults on) —
      // assert the target explicitly instead of leaning on cycleTarget.
      store.setControlTarget(ControlTarget.background);
      expect(store.state.controlTarget, ControlTarget.background);

      await store.disable();
      expect(store.state.enabled, isFalse);
      expect(store.state.controlTarget, ControlTarget.foreground);
      expect(store.state.currentIndex, -1);
      // Persisted queue survives for the next session.
      expect(store.state.queue, hasLength(3));
    });

    test('step wraps with repeat all and honors the excluded foreground key',
        () async {
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: files,
        currentIndex: 0,
        bgRepeat: Repeat.all,
      ));
      // Next from c (index 2) skips a (the foreground file) → b (index 1).
      store.set(store.state.copyWith(currentIndex: 2));
      final moved =
          await store.step(forward: true, excludedKey: backgroundMediaKey(_f('a')));
      expect(moved, isTrue);
      expect(store.state.currentIndex, 1);
      expect(backgroundMediaKey(store.currentFile!), backgroundMediaKey(_f('b')));
    });

    test('step returns false and pauses when every candidate is excluded',
        () async {
      final only = files.sublist(0, 1); // lone file == foreground file
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: only,
        currentIndex: 0,
        bgAutoPlay: true,
      ));
      final moved = await store.step(
          forward: true, excludedKey: backgroundMediaKey(only.first));
      expect(moved, isFalse);
      expect(store.state.bgAutoPlay, isFalse);
    });

    test('toggleShuffle flips the flag and keeps the current file', () async {
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: files,
        currentIndex: 2,
      ));
      await store.toggleShuffle();
      expect(store.state.shuffle, isTrue);
      // 副音's order is owned by the reserved tag view (a DB write); with no DB
      // the window is left as-is and the file that was playing stays current.
      expect(store.state.queue.toSet(), files.toSet());
      expect(
        backgroundMediaKey(store.currentFile!),
        backgroundMediaKey(_f('c')),
      );
    });

    test('replaceQueue keeps the current file by key, or pauses at the head',
        () async {
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: files,
        currentIndex: 2, // currently c
        bgAutoPlay: true,
      ));
      final refreshed = [_f('d'), _f('a'), _f('c')];
      await store.replaceQueue(refreshed);
      expect(
        backgroundMediaKey(store.currentFile!),
        backgroundMediaKey(_f('c')),
      );
      expect(store.state.bgAutoPlay, isTrue,
          reason: 'the playing file survived the refresh');

      await store.replaceQueue([_f('x')]);
      expect(backgroundMediaKey(store.currentFile!), backgroundMediaKey(_f('x')));
      expect(store.state.bgAutoPlay, isFalse,
          reason: 'a file that left the pool must stop, not switch silently');
    });

    test('toggleFgMute/bgMute flip their own track only', () async {
      expect(store.state.fgMuted, isFalse);
      expect(store.state.bgMuted, isFalse);
      await store.toggleFgMute();
      expect(store.state.fgMuted, isTrue);
      expect(store.state.bgMuted, isFalse);
      await store.toggleBgMute();
      expect(store.state.fgMuted, isTrue);
      expect(store.state.bgMuted, isTrue);
      await store.toggleFgMute();
      expect(store.state.fgMuted, isFalse);
      expect(store.state.bgMuted, isTrue);
    });

    test('advanceOnCompleted replays a single-track queue in place', () async {
      final solo = [_f('a')];
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        bgRepeat: Repeat.all,
        queue: solo,
        currentIndex: 0,
        bgAutoPlay: true,
      ));
      final replay = await store.advanceOnCompleted();
      expect(store.state.currentIndex, 0);
      expect(store.state.bgAutoPlay, isTrue);
      expect(replay, isTrue, reason: 'single-track repeat-all must loop in place');
    });

    test('advanceOnCompleted steps to a different file in a multi-track queue',
        () async {
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        bgRepeat: Repeat.all,
        queue: files,
        currentIndex: 0,
        bgAutoPlay: true,
      ));
      final replay = await store.advanceOnCompleted();
      expect(replay, isFalse, reason: 'multi-track advance opens a new file');
      expect(store.state.currentIndex, 1);
    });

    test('advanceOnCompleted stops (no replay) at repeat-none boundary', () async {
      final solo = [_f('a')];
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        bgRepeat: Repeat.none,
        queue: solo,
        currentIndex: 0,
        bgAutoPlay: true,
      ));
      final replay = await store.advanceOnCompleted();
      expect(replay, isFalse);
      expect(store.state.bgAutoPlay, isFalse);
    });

    test('cycleBgRepeat is its own track and leaves the rest of state intact',
        () async {
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: true,
        bgRepeat: Repeat.all,
      ));
      await store.cycleBgRepeat();
      expect(store.state.bgRepeat, Repeat.one);
      // Cycling bg repeat must not couple to the foreground: foreground state
      // is kept in the app store and is never touched by these methods.
      expect(store.state.enabled, isTrue);
      expect(store.state.shuffle, isTrue);
      await store.cycleBgRepeat();
      expect(store.state.bgRepeat, Repeat.none);
      await store.cycleBgRepeat();
      expect(store.state.bgRepeat, Repeat.all);
    });

    test('setBgVideoLayout persists the surface layout choice', () async {
      await store.setBgVideoLayout(BgVideoLayout.pip);
      expect(store.state.bgVideoLayout, BgVideoLayout.pip);
      await store.setBgVideoLayout(BgVideoLayout.fullscreen);
      expect(store.state.bgVideoLayout, BgVideoLayout.fullscreen);
    });

    test('setPanelVisible only moves the panel while 副音 is enabled',
        () async {
      // Disabled: collapse requests are ignored (no panel exists yet).
      await store.disable();
      expect(store.state.enabled, isFalse);
      await store.setPanelVisible(false);
      expect(store.state.bgPanelVisible, isTrue);

      await store.enableWithQueue(files);
      expect(store.state.bgPanelVisible, isTrue);
      await store.setPanelVisible(false);
      expect(store.state.bgPanelVisible, isFalse,
          reason: 'collapse hides the surface only — playback keeps running');
      // Collapse never flips the enable flag (X = disable is the real close).
      expect(store.state.enabled, isTrue);
      await store.setPanelVisible(true);
      expect(store.state.bgPanelVisible, isTrue);
    });

    test('linkage defaults: follow off, rate-lock on, same-file off', () {
      expect(store.state.bgFollowsFgSwitch, isFalse);
      expect(store.state.bgRateLock, isTrue);
      expect(store.state.allowSameFgBgFile, isFalse);
    });

    test('linkage setters persist through the JSON snapshot', () async {
      await store.setFollowFgSwitch(true);
      await store.setRateLock(false);
      await store.setAllowSameFgBgFile(true);
      expect(store.state.bgFollowsFgSwitch, isTrue);
      expect(store.state.bgRateLock, isFalse);
      expect(store.state.allowSameFgBgFile, isTrue);

      final encoded = json.encode(store.state.toJson());
      expect(encoded.contains('"bgFollowsFgSwitch":true'), isTrue);
      expect(encoded.contains('"bgRateLock":false'), isTrue);
      expect(encoded.contains('"allowSameFgBgFile":true'), isTrue);

      final restored = BackgroundPlaybackStore.normalizeLoaded(
        BackgroundPlaybackState.fromJson(json.decode(encoded)),
      );
      expect(restored.bgFollowsFgSwitch, isTrue);
      expect(restored.bgRateLock, isFalse);
      expect(restored.allowSameFgBgFile, isTrue);
    });

    // ── 换集行为 / step event seq ──

    test('stepMode defaults to swapOnly (only the 副音 track changes)', () {
      expect(store.state.stepMode, BgStepMode.swapOnly);
      expect(store.state.bgStepSeq, 0);
    });

    test('a user step bumps bgStepSeq even when the index wraps in place',
        () async {
      final solo = [_f('a')];
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        bgRepeat: Repeat.all,
        queue: solo,
        currentIndex: 0,
      ));
      final before = store.state.bgStepSeq;
      await store.step(forward: true);
      expect(store.state.bgStepSeq, before + 1,
          reason: 'the runtime observer keys step-vs-slider on this seq');

      // A no-eligible-candidate step must NOT bump it (nothing happened).
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        bgRepeat: Repeat.none,
        queue: solo,
        currentIndex: 0,
      ));
      final seq = store.state.bgStepSeq;
      await store.step(forward: true, excludedKey: backgroundMediaKey(_f('a')));
      expect(store.state.bgStepSeq, seq);
    });

    test('jumpTo (queue row tap) also bumps bgStepSeq', () async {
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: files,
        currentIndex: 0,
      ));
      final before = store.state.bgStepSeq;
      await store.jumpTo(2);
      expect(store.state.currentIndex, 2);
      expect(store.state.bgStepSeq, before + 1);
    });

    test('repeat-one completion bumps bgStepSeq (a replay is a step)', () async {
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        bgRepeat: Repeat.one,
        queue: files,
        currentIndex: 0,
      ));
      final before = store.state.bgStepSeq;
      await store.advanceOnCompleted();
      expect(store.state.bgStepSeq, before + 1);
    });

    test('setAlignAutoPauseRemainSec clamps into 1..120 (never off)', () async {
      await store.setAlignAutoPauseRemainSec(0);
      expect(store.state.alignAutoPauseRemainSec, 1);
      await store.setAlignAutoPauseRemainSec(5);
      expect(store.state.alignAutoPauseRemainSec, 5);
      await store.setAlignAutoPauseRemainSec(999);
      expect(store.state.alignAutoPauseRemainSec, 120);
    });

    test('bgUserAlignSeq bumps only on a userInitiated step/jump', () async {
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        bgRepeat: Repeat.all,
        queue: files,
        currentIndex: 0,
        bgAutoPlay: true,
      ));
      final before = store.state.bgUserAlignSeq;
      await store.step(forward: true);
      expect(store.state.bgUserAlignSeq, before,
          reason: 'a system step never raises the user-switch signal');
      await store.step(forward: true, userInitiated: true);
      expect(store.state.bgUserAlignSeq, before + 1);
      await store.jumpTo(2, userInitiated: true);
      expect(store.state.bgUserAlignSeq, before + 2);
    });

    test('bgExhaustedAction persists; mark/clear and switching back to nextBg',
        () async {
      expect(store.state.bgExhaustedAction, BgExhaustedAction.nextBg);
      await store.setBgExhaustedAction(BgExhaustedAction.stopRestoreFg);
      expect(store.state.bgExhaustedAction, BgExhaustedAction.stopRestoreFg);

      store.set(store.state.copyWith(enabled: true, bgAutoPlay: true));
      store.markBgExhausted();
      expect(store.state.bgExhausted, isTrue);
      expect(store.state.bgAutoPlay, isFalse);
      store.clearBgExhausted();
      expect(store.state.bgExhausted, isFalse);

      // Choosing "keep playing" clears a terminal restore immediately.
      store.markBgExhausted();
      expect(store.state.bgExhausted, isTrue);
      await store.setBgExhaustedAction(BgExhaustedAction.nextBg);
      expect(store.state.bgExhausted, isFalse);
    });

    test('enable/disable/restart clear the exhausted flag', () async {
      store.set(store.state.copyWith(enabled: true, bgExhausted: true));
      await store.enableWithQueue(files);
      expect(store.state.bgExhausted, isFalse);

      store.set(store.state.copyWith(enabled: true, bgExhausted: true));
      await store.disable();
      expect(store.state.bgExhausted, isFalse);

      store.set(store.state.copyWith(
        enabled: true,
        queue: files,
        currentIndex: 0,
        bgExhausted: true,
      ));
      store.restartForCurrent();
      expect(store.state.bgExhausted, isFalse);
    });

    // ── 自动使用已保存的映射 (mappingEnabled) ──

    test('mappingEnabled defaults on (auto-use saved mappings)', () {
      expect(store.state.mappingEnabled, isTrue);
    });

    test('setMappingEnabled works while 副音 is off (it is a preference)',
        () async {
      await store.disable();
      expect(store.state.enabled, isFalse);
      await store.setMappingEnabled(false);
      expect(store.state.mappingEnabled, isFalse);
      await store.setMappingEnabled(true);
      expect(store.state.mappingEnabled, isTrue);
    });

    // ── APB fg 显示窗口 (fgWindowZoom / fgWindowPushBg) ──

    test('fg window defaults: 2.0× zoom, push-at-boundary off', () {
      expect(store.state.fgWindowZoom, 2.0);
      expect(store.state.fgWindowPushBg, isFalse);
    });

    test('setFgWindowZoom clamps to the 1.0..10.0 range', () async {
      await store.setFgWindowZoom(99);
      expect(store.state.fgWindowZoom, 10.0);
      await store.setFgWindowZoom(0.25);
      expect(store.state.fgWindowZoom, 1.0);
      await store.setFgWindowZoom(1.5);
      expect(store.state.fgWindowZoom, 1.5);
    });

    test('setFgWindowPushBg flips the preference while 副音 is off', () async {
      await store.disable();
      expect(store.state.enabled, isFalse);
      await store.setFgWindowPushBg(true);
      expect(store.state.fgWindowPushBg, isTrue);
    });

    // Snap-to-saved-boundary preference + release memory bound.

    test('snap defaults: off, one recent release remembered', () {
      expect(store.state.snapEnabled, isFalse);
      expect(store.state.snapReleaseLimit, 1);
    });

    test('setSnapEnabled flips the preference', () async {
      await store.setSnapEnabled(true);
      expect(store.state.snapEnabled, isTrue);
      await store.setSnapEnabled(false);
      expect(store.state.snapEnabled, isFalse);
    });

    test('setSnapReleaseLimit clamps to the 1..10000 range', () async {
      await store.setSnapReleaseLimit(0);
      expect(store.state.snapReleaseLimit, 1);
      await store.setSnapReleaseLimit(99999);
      expect(store.state.snapReleaseLimit, 10000);
      await store.setSnapReleaseLimit(3);
      expect(store.state.snapReleaseLimit, 3);
    });
  });
}
