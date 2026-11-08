import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/model/background_playback_state.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;

/// The ONE "is the pair in effect?" predicate every reader shares.
///
/// A run can be armed/enabled and still not be in effect: the current media may
/// be outside the run's 作用范围, the stopRestoreFg terminal may have latched, or
/// the queue may have run off its end under Repeat.none. All three are
/// session-only and must hand the controls/picture/ducking back to the video
/// WITHOUT rewriting the user's routing preference.
FileItem _f(String key) => FileItem(name: key, uri: 'file:///$key', path: [key]);

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
  });

  void armRun() {
    store.set(store.state.copyWith(
      enabled: true,
      gateOpen: true,
      controlTarget: ControlTarget.background,
      displayTarget: ControlTarget.background,
      bgAutoPlay: true,
      queue: [_f('a'), _f('b'), _f('c')],
      currentIndex: 0,
    ));
  }

  group('bgPairInEffect / bgOwnsControls / bgOwnsDisplay', () {
    test('an armed, in-gate, in-scope run owns both', () {
      armRun();
      final s = store.state;
      expect(s.bgPairInEffect, isTrue);
      expect(s.bgOwnsControls, isTrue);
      expect(s.bgOwnsDisplay, isTrue);
    });

    test('out of 作用范围 hands the controls AND the picture back', () {
      armRun();
      store.setOutOfScope(true);
      final s = store.state;
      expect(s.bgPairInEffect, isFalse);
      expect(s.bgOwnsControls, isFalse,
          reason: 'the bar must not drive a paused 副音 (original report)');
      expect(s.bgOwnsDisplay, isFalse);
      // The routing PREFERENCE survives: returning to the anchor restores it
      // without the user re-picking a target.
      expect(s.controlTarget, ControlTarget.background);
      expect(s.displayTarget, ControlTarget.background);
    });

    test('pause/resumeForScope are the scope transitions', () {
      armRun();
      store.pauseForScope();
      expect(store.state.bgOutOfScope, isTrue);
      expect(store.state.bgAutoPlay, isFalse);
      expect(store.state.bgOwnsControls, isFalse);

      store.resumeForScope();
      expect(store.state.bgOutOfScope, isFalse);
      expect(store.state.bgOwnsControls, isTrue);
    });

    test('an explicit activation clears every session stop', () async {
      armRun();
      store.setOutOfScope(true);
      store.markBgQueueEnded();
      store.markBgExhausted();
      expect(store.state.bgPairInEffect, isFalse);

      // Re-opening the gate is the user's "use 副音 here" command: it clears the
      // out-of-scope hand-back, the queue-end latch and the terminal stop.
      await store.openGate();
      final s = store.state;
      expect(s.bgOutOfScope, isFalse);
      expect(s.bgQueueEnded, isFalse);
      expect(s.bgExhausted, isFalse);
      expect(s.bgOwnsControls, isTrue);
    });

    test('the stopRestoreFg terminal is not in effect', () {
      armRun();
      store.markBgExhausted();
      final s = store.state;
      expect(s.bgOwnsControls, isFalse);
      expect(s.bgOwnsDisplay, isFalse);
      expect(s.bgPairInEffect, isFalse);
    });
  });

  group('bgQueueEnded (Repeat.none ran off the end)', () {
    test('a forward step at the end latches it and hands back the pair', () async {
      armRun();
      store.set(store.state.copyWith(
        currentIndex: 2,
        bgRepeat: Repeat.none,
      ));
      expect(store.state.bgOwnsControls, isTrue);

      // Synchronous up to the in-window fast path: no DB is needed here.
      final moved = await store.step(forward: true);
      expect(moved, isFalse);
      expect(store.state.bgQueueEnded, isTrue);
      expect(store.state.bgAutoPlay, isFalse);
      expect(store.state.bgOwnsControls, isFalse);
      expect(store.state.bgOwnsDisplay, isFalse);
      // The routing preference is intact for the next play.
      expect(store.state.controlTarget, ControlTarget.background);
    });

    test('a double-play collision is NOT the end of the queue', () async {
      armRun();
      store.set(store.state.copyWith(
        currentIndex: 0,
        bgRepeat: Repeat.none,
        queue: [_f('a'), _f('b')],
      ));
      final excluded = backgroundMediaKey(_f('b'));
      final moved = await store.step(forward: true, excludedKey: excluded);
      expect(moved, isFalse);
      // The list has one more entry — it is the FOREGROUND file, not the end of
      // the queue. Handing the pair back here would drop the picture/title/duck
      // for a run that still has somewhere to go (the untaken branch `b`).
      expect(store.state.bgQueueEnded, isFalse,
          reason: 'a collision is a guard hit, not an exhausted list');
      expect(store.state.bgOwnsControls, isTrue);
    });

    test('a collision under Repeat.all never latches it either', () async {
      armRun();
      store.set(store.state.copyWith(
        currentIndex: 0,
        bgRepeat: Repeat.all,
        queue: [_f('a')],
      ));
      final excluded = backgroundMediaKey(_f('a'));
      final moved = await store.step(forward: true, excludedKey: excluded);
      expect(moved, isFalse);
      expect(store.state.bgQueueEnded, isFalse);
      expect(store.state.bgOwnsControls, isTrue,
          reason: 'looping onto the only entry is not the end of the list');
    });

    test('a 下一首 re-activation at the end of a Repeat.none list hands the pair back',
        () async {
      armRun();
      store.set(store.state.copyWith(
        currentIndex: 0,
        bgRepeat: Repeat.none,
        queue: [_f('a')],
      ));
      // No candidate exists past the head: this is the LIST being over, so the
      // same hand-back as `step` applies.
      await store.openGate(stepForward: true, autoplay: false);
      expect(store.state.bgQueueEnded, isTrue);
      expect(store.state.bgOwnsControls, isFalse);
    });

    test('a real play clears the latch', () {
      armRun();
      store.markBgQueueEnded();
      expect(store.state.bgQueueEnded, isTrue);
      store.setPlaying(true);
      expect(store.state.bgQueueEnded, isFalse);
      expect(store.state.bgOwnsControls, isTrue);
    });

    test('Repeat.all never latches it', () async {
      armRun();
      store.set(store.state.copyWith(currentIndex: 2, bgRepeat: Repeat.all));
      // Wraps onto index 0 through the in-window fast path.
      final moved = await store.step(forward: true);
      expect(moved, isTrue);
      expect(store.state.bgQueueEnded, isFalse);
      expect(store.state.bgOwnsControls, isTrue);
    });
  });

  test('session states never serialize', () {
    armRun();
    store.setOutOfScope(true);
    store.markBgQueueEnded();
    final json = store.state.toJson();
    expect(json.containsKey('bgOutOfScope'), isFalse);
    expect(json.containsKey('bgQueueEnded'), isFalse);
    // The cold-load normalizer clears every session flag explicitly.
    final cleared = BackgroundPlaybackStore.normalizeLoaded(store.state);
    expect(cleared.bgOutOfScope, isFalse);
    expect(cleared.bgQueueEnded, isFalse);
    // …and the getters read a fresh session as "not stopped".
    expect(const BackgroundPlaybackState().bgQueueEnded, isFalse);
    expect(const BackgroundPlaybackState().bgOutOfScope, isFalse);
  });
}
