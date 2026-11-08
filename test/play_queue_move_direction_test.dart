import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/play_queue/persistence/play_queue_persistence.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/play_queue_state.dart';
import 'package:iris/store/use_play_queue_store.dart';

/// The play queue is the only thing that knows whether a move was 「下一集」 or
/// 「上一集」: `previous()` at the head wraps onto the TAIL and `next()` at the
/// tail wraps onto the HEAD, so `(from, to)` alone cannot separate a wrap from
/// an ordinary step in the opposite direction. 副音 mirrors the foreground's
/// direction, and it used to step FORWARD on 「上一集」 for want of a better
/// signal.
class _NoopPersistence implements PlayQueuePersistence {
  @override
  Future<PlayQueueState?> load() async => null;

  @override
  Future<void> save(PlayQueueState state) async {}
}

FileItem _f(String name) =>
    FileItem(name: name, uri: 'file:///$name', path: [name]);

void main() {
  late UnifiedPlayQueueStore store;

  setUp(() async {
    store = UnifiedPlayQueueStore(
      legacyPersistence: _NoopPersistence(),
      queryPersistence: _NoopPersistence(),
    );
    await store.initialized;
    // Pin the in-memory backend: the default AppState routes onReady to the
    // query backend, whose synthetic single-item state hides the wrap.
    await store.switchBackend(true);
    await store.update(
      playQueue: [
        PlayQueueItem(file: _f('a.mp4'), index: 0),
        PlayQueueItem(file: _f('b.mp4'), index: 1),
        PlayQueueItem(file: _f('c.mp4'), index: 2),
      ],
      index: 0,
    );
  });

  tearDown(() async {
    await store.dispose();
  });

  test('「上一集」 at the head stamps the wrap as BACKWARD', () async {
    expect(store.state.currentIndex, 0);
    await store.previous();
    expect(store.state.currentIndex, 2, reason: 'wrapped onto the tail');
    expect(store.lastMove, (forward: false, index: 2));
  });

  test('「下一集」 at the tail stamps the wrap as FORWARD', () async {
    await store.updateCurrentIndex(2);
    await store.next();
    expect(store.state.currentIndex, 0, reason: 'wrapped onto the head');
    expect(store.lastMove, (forward: true, index: 0));
  });

  test('a normal step carries its own direction', () async {
    await store.updateCurrentIndex(1);
    await store.next();
    expect(store.lastMove, (forward: true, index: 2));
    await store.previous();
    expect(store.lastMove, (forward: false, index: 1));
  });

  test('a bare jump carries NO direction (it is not a step)', () async {
    await store.previous();
    expect(store.lastMove, isNotNull);
    // A row tap or a restored position is neither 「下一集」 nor 「上一集」: the
    // consumers must fall back to the ids, so the previous press must not
    // linger and be read as this move's direction.
    await store.updateCurrentIndex(1);
    expect(store.lastMove, isNull);
  });

  test('the stamp names the entry the move LANDED on', () async {
    // Consumers compare it with the id they observed, so a later jump that
    // happens to be the only queue change must not be attributed to the press.
    await store.previous();
    expect(store.lastMove?.index, store.state.currentIndex);
  });
}
