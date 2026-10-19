import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/services/background_scenario_pool.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/store/use_play_queue_store.dart';

FileItem _f(String key) => FileItem(name: key, uri: 'file:///$key', path: [key]);

/// A bg run must never START on the foreground's own file, on any of the four
/// paths that land on a queue (enable / gate re-open / refresh-replace).
///
/// This is the guard that had to move when the queue became the complete
/// candidate pool: the pool legitimately contains the foreground file (it is
/// the 音库 source for the NEXT foreground), so "where do we begin playing" can
/// no longer be answered by "index 0".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  final files = [_f('a'), _f('b'), _f('c')];

  Future<void> withForeground(
    String key,
    Future<void> Function() body,
  ) async {
    final pq = usePlayQueueStore();
    await pq.update(playQueue: [PlayQueueItem(file: _f(key), index: 0)], index: 0);
    try {
      await body();
    } finally {
      await pq.clear();
    }
  }

  group('bg run never starts on the foreground file', () {
    late BackgroundPlaybackStore store;

    setUp(() async {
      store = BackgroundPlaybackStore();
      await store.initialized;
    });

    tearDown(() => store.dispose());

    test('enableWithQueue skips a leading foreground entry', () async {
      await withForeground('a', () async {
        // Shuffle off so the queue order is the candidate order: 'a' is the
        // head AND the foreground, which used to be opened on both engines.
        store.set(store.state.copyWith(shuffle: false));
        await store.enableWithQueue(files);
        expect(store.state.currentIndex, 1);
        expect(
          backgroundMediaKey(store.state.queue[store.state.currentIndex]),
          isNot(backgroundMediaKey(_f('a'))),
        );
      });
    });

    test('enableWithQueue tolerates a queue that is only the foreground file',
        () async {
      await withForeground('a', () async {
        store.set(store.state.copyWith(shuffle: false));
        await store.enableWithQueue([_f('a')]);
        // Nothing else to play, but the run must still hold a valid index
        // rather than -1 (which the panel would render as "no current file").
        expect(store.state.currentIndex, 0);
      });
    });

    test('replaceQueue keeps the playing file, else a playable one', () async {
      await withForeground('b', () async {
        store.set(store.state.copyWith(shuffle: false));
        // Current file is 'a' (playable): it must survive a refresh.
        await store.enableWithQueue(files);
        expect(store.state.currentIndex, 0);

        await store.replaceQueue([_f('b'), _f('c')]);
        // 'a' is gone, so it must NOT fall onto the now-head 'b' (= foreground).
        expect(
          backgroundMediaKey(store.state.queue[store.state.currentIndex]),
          backgroundMediaKey(_f('c')),
        );
      });
    });

    test('openGate on a never-started queue lands on a playable file',
        () async {
      await withForeground('a', () async {
        store.set(store.state.copyWith(shuffle: false));
        await store.enableWithQueue(files);
        // Simulate the cold state the gate has to recover from: queue present,
        // nothing chosen yet.
        store.set(store.state.copyWith(currentIndex: -1));
        store.openGate(mediaKey: backgroundMediaKey(_f('a')));
        expect(store.state.currentIndex, 1);
      });
    });

    test('the guard lifts entirely with allowSameFgBgFile', () async {
      final live = useBackgroundPlaybackStore();
      await live.initialized;
      live.set(live.state.copyWith(allowSameFgBgFile: true));
      addTearDown(() => live.set(live.state.copyWith(allowSameFgBgFile: false)));

      await withForeground('a', () async {
        live.set(live.state.copyWith(shuffle: false));
        await live.enableWithQueue(files);
        expect(live.state.currentIndex, 0,
            reason: 'the user allowed the same file on both runtimes');
        await live.disable();
      });
    });

    test('a REMEMBERED item that is the foreground is not resumed', () async {
      await withForeground('a', () async {
        store.set(store.state.copyWith(shuffle: false));
        // The run was last left on 'a' — which is the foreground RIGHT NOW.
        // Applying the remembered position after the guard (the old order)
        // started the same media on two engines.
        final w = BgQueueWindow(
          files: files,
          start: 0,
          total: files.length,
          focusIndex: 0,
          focusKey: backgroundMediaKey(_f('a')),
        );
        await store.enableWithQueue(files, window: w);
        expect(
          backgroundMediaKey(store.state.queue[store.state.currentIndex]),
          backgroundMediaKey(_f('b')),
        );
      });
    });

    test('replaceQueue follows the window, not the stale remembered item',
        () async {
      await withForeground('fg', () async {
        store.set(store.state.copyWith(shuffle: false));
        await store.enableWithQueue(files);
        expect(backgroundMediaKey(store.state.queue[store.state.currentIndex]),
            backgroundMediaKey(_f('a')));

        // A system move (lock rollover / tiled entrance) left the run on 'c'
        // while the scenario still records 'a'. The reconcile window is
        // resolved around the LIVE item, so the selection must not jump back.
        store.set(store.state.copyWith(currentIndex: 2));
        final w = BgQueueWindow(
          files: files,
          start: 0,
          total: files.length,
          focusKey: backgroundMediaKey(_f('a')),
        );
        await store.replaceQueue(w.files, window: w);
        expect(
          backgroundMediaKey(store.state.queue[store.state.currentIndex]),
          backgroundMediaKey(_f('c')),
        );
      });
    });

    test('restartForCurrent does not land on the foreground file', () async {
      await withForeground('a', () async {
        store.set(store.state.copyWith(shuffle: false));
        await store.enableWithQueue(files);
        // Walk away from the head so the restart's reset is observable.
        store.set(store.state.copyWith(currentIndex: 2));

        store.restartForCurrent();

        // The queue head 'a' IS the foreground: 「对当前」 must skip it rather
        // than play the same file on two engines (the unconditional
        // `currentIndex: 0` this used to be).
        expect(store.state.currentIndex, 1);
        expect(
          backgroundMediaKey(store.state.queue[store.state.currentIndex]),
          isNot(backgroundMediaKey(_f('a'))),
        );
      });
    });

    test('restartForCurrent still returns to the head when it is playable',
        () async {
      await withForeground('fg', () async {
        store.set(store.state.copyWith(shuffle: false));
        await store.enableWithQueue(files);
        store.set(store.state.copyWith(currentIndex: 2));

        store.restartForCurrent();

        expect(store.state.currentIndex, 0,
            reason: '回到队首 semantics are kept for a playable head');
      });
    });

    test('restartForCurrent keeps a valid index for an all-foreground queue',
        () async {
      await withForeground('a', () async {
        store.set(store.state.copyWith(shuffle: false));
        await store.enableWithQueue([_f('a')]);
        store.restartForCurrent();
        expect(store.state.currentIndex, 0,
            reason: 'nothing else to play — still a valid index, not -1');
      });
    });

    test('a 下一首 re-activation honours Repeat.none and does not wrap',
        () async {
      await withForeground('fg', () async {
        store.set(store.state.copyWith(shuffle: false, bgRepeat: Repeat.none));
        await store.enableWithQueue(files);
        // The last track is loaded: a forward re-activation has nowhere to go.
        store.set(store.state.copyWith(currentIndex: 2));
        store.stopGate();

        await store.openGate(mediaKey: 'fg', stepForward: true);

        // It used to hardcode Repeat.all here, so 循环关 + 「下一首」 wrapped to
        // the head — the one case the repeat setting exists to prevent. The gate
        // is a PERMISSION (the caller owns autoplay), so the assertion is the
        // LANDING: the loaded track stays, nothing wraps.
        expect(store.state.currentIndex, 2,
            reason: 'kept the loaded track instead of wrapping');
        expect(store.currentFile, isNotNull);
        expect(store.currentFile!.name, 'c',
            reason: 'the run stays on the file that was loaded');
      });
    });

    test('a 下一首 re-activation still advances under Repeat.all', () async {
      await withForeground('fg', () async {
        store.set(store.state.copyWith(shuffle: false, bgRepeat: Repeat.all));
        await store.enableWithQueue(files);
        store.set(store.state.copyWith(currentIndex: 2));
        store.stopGate();

        await store.openGate(mediaKey: 'fg', stepForward: true);

        expect(store.state.currentIndex, 0, reason: 'wraps to the head');
      });
    });
  });
}
