import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/play_queue/persistence/play_queue_persistence.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/play_queue_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

class _NoopPersistence implements PlayQueuePersistence {
  @override
  Future<PlayQueueState?> load() async => null;
  @override
  Future<void> save(PlayQueueState state) async {}
}

/// Hands back a pre-populated queue on `load()` — the startup path
/// (`PersistentStore._init` -> `load()` -> `set(...)`), which bypasses
/// `_syncSyntheticState` and therefore publishes no total of its own.
class _SeededPersistence implements PlayQueuePersistence {
  _SeededPersistence(this.seeded);
  final PlayQueueState seeded;

  @override
  Future<PlayQueueState?> load() async => seeded;
  @override
  Future<void> save(PlayQueueState state) async {}
}

/// Regression: the control bars decided prev/next visibility from
/// `(store.isQueryMode ? store.totalCount : playQueue.length)` where
/// `totalCount` was read BARE — a getter, not a subscription. In query mode the
/// synthetic state is pinned to ONE item, so `playQueue.length` is always 1 and
/// carries no size information; a search/filter that moved the total 1↔N left
/// the bar un-rebuilt and the transport buttons frozen.
///
/// The fix publishes the real total on `totalCountNotifier`. This test pins the
/// contract that makes the fix meaningful: the notifier tracks the queue's true
/// size and MOVES when the length-based subscription cannot.
PlayQueueItem _item(String n) => PlayQueueItem(
      file: FileItem(name: n, uri: '/$n'),
      index: n.codeUnitAt(0),
    );

void main() {
  late AppDatabase moduleDb;

  setUpAll(() {
    moduleDb = AppDatabase(NativeDatabase.memory());
    DbModule.init(moduleDb);
  });

  tearDownAll(() async {
    await moduleDb.close();
  });

  test('the notifier tracks the queue size in legacy mode', () async {
    // Pin the backend: `initialized` completes BEFORE `onReady()` picks it, so
    // without this the mode is whatever the ambient app store happens to say.
    useAppStore().set(
        useAppStore().state.copyWith(useLegacyStoragePersistence: true));
    final store = UnifiedPlayQueueStore(
      legacyPersistence: _NoopPersistence(),
      queryPersistence: _NoopPersistence(),
    );
    await store.initialized;
    await Future<void>.delayed(Duration.zero); // let onReady() settle
    expect(store.isQueryMode, isFalse, reason: 'precondition: legacy backend');

    int observed = store.totalCountNotifier.value;
    store.totalCountNotifier.addListener(
      () => observed = store.totalCountNotifier.value,
    );

    expect(store.totalCountNotifier.value, 0,
        reason: 'an empty queue publishes 0 regardless of backend');

    // Three items -> the notifier must follow, not stay at 0.
    await store.update(playQueue: [_item('a'), _item('b'), _item('c')]);
    expect(store.state.playQueue.length, 3);
    expect(store.totalCount, 3);
    expect(observed, 3,
        reason: 'the published total must track the live queue size');

    // Back down to one -> still mirrored.
    await store.update(playQueue: [_item('a')]);
    expect(observed, 1);
  });

  test('the backend-switch path publishes the loaded size', () async {
    // The real startup path: `AppStore.onReady` -> `switchBackend`, which loads
    // a populated queue and — being the legacy branch — never runs
    // `_syncSyntheticState`. A subscriber that arrives before the first
    // mutation must still see the real size, exactly as the previous bare
    // `store.totalCount` read gave it.
    final store = UnifiedPlayQueueStore(
      legacyPersistence: _SeededPersistence(
          PlayQueueState(playQueue: [_item('a'), _item('b')])),
      queryPersistence: _NoopPersistence(),
    );
    await store.initialized;

    await store.switchBackend(true);
    expect(store.totalCount, 2, reason: 'precondition: the queue is loaded');
    expect(store.totalCountNotifier.value, 2,
        reason: 'a backend switch must republish, or subscribers keep the '
            'previous backend’s total');
  });

  test('every backend switch republishes, whichever branch it takes',
      () async {
    // The shipped `QueryPlayQueuePersistence` is a null-returning stub, so the
    // `loaded != null` arm of `switchBackend` is dead in production — which is
    // exactly why it could lose its publish without anything going red. Seed
    // BOTH sides to make the query arm reachable and pin the invariant that
    // matters: after a switch the notifier mirrors the backend that is now
    // active, never the one that was.
    useAppStore().set(
        useAppStore().state.copyWith(useLegacyStoragePersistence: true));
    final store = UnifiedPlayQueueStore(
      legacyPersistence: _SeededPersistence(
          PlayQueueState(playQueue: [_item('a'), _item('b')])),
      queryPersistence: _SeededPersistence(
          PlayQueueState(playQueue: [_item('a'), _item('b')])),
    );
    await store.initialized;

    await store.switchBackend(true);
    expect(store.totalCountNotifier.value, 2,
        reason: 'precondition: the legacy backend published its 2');

    // Switching to the query backend: its own state is empty (nothing loaded
    // into it), so the live total is 0 — and that is what the notifier has to
    // say. Left at 2, every prev/next control keeps a queue that is gone.
    await store.switchBackend(false);
    expect(store.isQueryMode, isTrue, reason: 'precondition: query backend');
    expect(store.totalCount, 0);
    expect(store.totalCountNotifier.value, store.totalCount,
        reason: 'a backend switch must republish on BOTH arms, or subscribers '
            'keep the previous backend’s total');
  });

  test('the notifier is a SEPARATE signal from playQueue.length', () async {
    // This is the whole point of the fix. Reproduce the query-mode shape
    // directly on the facade: a synthetic single-item state whose real total
    // is much larger. A subscriber to `playQueue.length` sees no change here;
    // a subscriber to the notifier does.
    final store = UnifiedPlayQueueStore(
      legacyPersistence: _NoopPersistence(),
      queryPersistence: _NoopPersistence(),
    );
    await store.initialized;

    final seen = <int>[];
    store.totalCountNotifier.addListener(
      () => seen.add(store.totalCountNotifier.value),
    );

    // Shrink to a single item: this is exactly the query-mode synthetic shape
    // (`playQueue` = [current file], real total = 1).
    await store.update(playQueue: [_item('a')]);
    expect(store.state.playQueue.length, 1);
    final int lengthSnapshot = store.state.playQueue.length;

    expect(seen, contains(1),
        reason: 'the notifier reported the shrink to the single-item shape');
    expect(store.state.playQueue.length, lengthSnapshot,
        reason: 'precondition: the length-based signal is pinned at 1');
  });
}
