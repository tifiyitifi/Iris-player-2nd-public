import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_scope_logic.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/model/enum/bg_quick_panel.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_play_queue_store.dart';

FileItem _f(String key) =>
    FileItem(name: key, uri: 'file:///$key', path: [key]);

/// 第 4 轮问题 2: the "对当前" toggle must survive a foreground media switch
/// (re-anchor) and must be able to turn back on after a close.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  bool applied(BackgroundPlaybackStore store, String fgKey) =>
      resolveApplyToCurrent(
        enabled: store.state.enabled,
        applyScope: store.state.applyScope,
        anchorKey: store.state.scopeAnchorKey,
        offMediaKeys: store.state.bgOffMediaKeys,
        fgKey: fgKey,
      );

  late BackgroundPlaybackStore store;

  setUp(() async {
    store = BackgroundPlaybackStore();
    await store.initialized;
  });

  tearDown(() => store.dispose());

  test('media switch away then apply re-anchors and resumes', () async {
    await store.enableWithQueue(
      [_f('a')],
      applyScope: BgApplyScope.currentOnly,
      anchorKey: 'a',
    );
    expect(applied(store, 'a'), isTrue);

    // Foreground moved to b: the run is paused and reads "not applied".
    expect(applied(store, 'b'), isFalse);

    store.applyToCurrent('b');

    expect(store.state.scopeAnchorKey, 'b',
        reason: 'the anchor must follow the media the user applied it to');
    expect(store.state.bgOffMediaKeys, isNot(contains('b')));
    expect(store.state.bgAutoPlay, isTrue);
    expect(applied(store, 'b'), isTrue,
        reason: 'the toggle must be able to turn back on after a switch');
  });

  test('close then apply toggles back on for the same media', () async {
    await store.enableWithQueue(
      [_f('a')],
      applyScope: BgApplyScope.currentOnly,
      anchorKey: 'a',
    );

    store.closeScopeForMedia('a');
    expect(applied(store, 'a'), isFalse);
    expect(store.state.bgAutoPlay, isFalse);

    store.applyToCurrent('a');
    expect(applied(store, 'a'), isTrue);
    expect(store.state.bgAutoPlay, isTrue);
  });

  test('all scope: apply clears the off set without touching the anchor',
      () async {
    await store.enableWithQueue([_f('a')], applyScope: BgApplyScope.all);
    expect(store.state.scopeAnchorKey, isNull);

    store.applyToCurrent('b');
    expect(store.state.scopeAnchorKey, isNull);
    expect(applied(store, 'b'), isTrue);
  });

  test('applyToCurrent is a no-op while 副音 is off', () async {
    // A cold load now arms the run (startArmed default on) — force it off.
    await store.disable();
    expect(store.state.enabled, isFalse);
    store.applyToCurrent('a');
    expect(store.state.bgAutoPlay, isFalse);
    expect(store.state.scopeAnchorKey, isNull);
  });

  test('disable clears the anchor and closes any open quick panel', () async {
    await store.enableWithQueue(
      [_f('a')],
      applyScope: BgApplyScope.currentOnly,
      anchorKey: 'a',
    );
    store.showQuickPanel(BgQuickPanel.scope);
    expect(store.state.openQuickPanel, BgQuickPanel.scope);

    await store.disable();

    expect(store.state.scopeAnchorKey, isNull);
    expect(store.state.openQuickPanel, BgQuickPanel.none);
  });

  test('applyToCurrent(autoplay: false) re-anchors without starting playback',
      () async {
    await store.enableWithQueue(
      [_f('a')],
      applyScope: BgApplyScope.currentOnly,
      anchorKey: 'a',
    );

    store.applyToCurrent('b', autoplay: false);

    expect(store.state.scopeAnchorKey, 'b');
    expect(applied(store, 'b'), isTrue);
    expect(store.state.bgAutoPlay, isFalse,
        reason: 'a paused foreground is not force-played when re-anchoring');
  });

  group('the AUTOMATIC saved-pairing start keeps the 副音 queue progress', () {
    /// The 智能 scope (and any scope auto-start) is a re-PAIRING, not a new run:
    /// the two runtimes stay two independent normal players that only share an
    /// anchor, a mix and "which fg gets 副音". Re-pointing at a NEW foreground
    /// media therefore must not rewind what 副音 had already reached.
    Future<void> armMidQueue() async {
      await store.enableWithQueue(
        [_f('b1'), _f('b2'), _f('b3')],
        applyScope: BgApplyScope.smart,
        anchorKey: 'fg1',
      );
      store.set(store.state.copyWith(
        currentIndex: 2,
        bgOutOfScope: true,
        bgQueueEnded: true,
        alignOffsetMs: 4200,
      ));
    }

    test('applyToCurrent(keepQueueProgress: true) lands on the SAME track',
        () async {
      await armMidQueue();
      final int runSeq = store.state.bgRunSeq;

      store.applyToCurrent('fg2', keepQueueProgress: true);

      expect(store.state.currentIndex, 2,
          reason: 'the queue position belongs to the user, not to the switch');
      expect(store.state.bgRunSeq, greaterThan(runSeq),
          reason: 'the ALIGNMENT still has to be re-derived for the new fg');
      expect(store.state.bgAutoPlay, isTrue);
      expect(store.state.bgOutOfScope, isFalse);
      expect(store.state.bgQueueEnded, isFalse);
      expect(store.state.alignOffsetMs, isNull,
          reason: 'the previous fg\'s offset describes media that is gone');
    });

    test('the explicit apply still restarts from the pool head', () async {
      await armMidQueue();

      store.applyToCurrent('fg2');

      expect(store.state.currentIndex, 0,
          reason: '「对当前视频使用副音」 is a new start, not a continuation');
    });

    /// Puts [key]'s file on the FOREGROUND queue, so the same-file guard
    /// (`excludedForegroundKey`) sees it — every other landing path in the store
    /// consults that guard, and the automatic re-pairing must not be the one
    /// exception.
    Future<void> withForeground(
      String key,
      Future<void> Function() body,
    ) async {
      final pq = usePlayQueueStore();
      await pq.update(
        playQueue: [PlayQueueItem(file: _f(key), index: 0)],
        index: 0,
      );
      try {
        await body();
      } finally {
        await pq.clear();
      }
    }

    test('keepQueueProgress never lands on the foreground file', () async {
      // 智能 auto-starts on a media that has a saved 副音 pairing. The pair is
      // already mid-queue, and the media being opened IS the 副音 track on the
      // air: keeping that index plays one file on two engines — exactly the
      // double-play `allowSameFgBgFile` (default off) exists to prevent, and
      // every other landing path refuses it.
      await armMidQueue();
      await withForeground('b1', () async {
        store.set(store.state.copyWith(currentIndex: 0));

        store.applyToCurrent('fg2', keepQueueProgress: true);

        expect(store.state.currentIndex, 1,
            reason: 'the queue keeps going: skip the entry the video took over');
      });
    });

    test('the skip wraps when the collision is the last entry', () async {
      await armMidQueue();
      await withForeground('b3', () async {
        store.applyToCurrent('fg2', keepQueueProgress: true);

        expect(store.state.currentIndex, 0,
            reason: 'nothing ahead of the tail, and 副音 has to sound '
                'somewhere other than the video\'s own file');
      });
    });

    test('an invalid progress index still lands on a playable entry', () async {
      // A run whose queue was replaced/emptied without a recording index has
      // nothing to keep: it must land through the same start-index math as every
      // other entry point instead of leaving `currentIndex: -1` (which the
      // runtime reads as "no target" and stops the engine on).
      await armMidQueue();
      await withForeground('b1', () async {
        store.set(store.state.copyWith(currentIndex: -1));

        store.applyToCurrent('fg2', keepQueueProgress: true);

        expect(store.state.currentIndex, 1,
            reason: 'pickStartIndex skips the foreground file');
      });
    });
  });

  test('enableWithQueue(autoplay: false) arms the run paused', () async {
    await store.enableWithQueue([_f('a')], autoplay: false);

    expect(store.state.enabled, isTrue);
    expect(store.state.gateOpen, isTrue);
    expect(store.state.bgAutoPlay, isFalse);
  });

  test('resumeForScope(play: false) stays paused after returning to the anchor',
      () async {
    await store.enableWithQueue(
      [_f('a')],
      applyScope: BgApplyScope.currentOnly,
      anchorKey: 'a',
    );
    store.pauseForScope();

    store.resumeForScope(play: false);

    expect(store.state.bgAutoPlay, isFalse);
  });
}
