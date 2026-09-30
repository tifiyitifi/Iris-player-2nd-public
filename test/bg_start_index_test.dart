import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/models/file.dart';
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
  });
}
