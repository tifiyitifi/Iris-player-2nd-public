import 'package:flutter_test/flutter_test.dart';
import 'package:iris/hooks/player/advance_play_queue_on_completed.dart';
import 'package:iris/features/media_library/play_queue/persistence/play_queue_persistence.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/models/store/play_queue_state.dart';
import 'package:iris/store/use_play_queue_store.dart';

/// Regression: FVP's end-of-file advance lacked the query-mode branch that
/// media_kit had. In query/paged mode the synthetic queue is always length 1,
/// so `currentPlayIndex == playQueue.length - 1` is permanently true and
/// playback never advanced (unless repeat-all wrapped it). The shared helper
/// must drive query mode by virtual position/total count.
class _NoopPersistence implements PlayQueuePersistence {
  @override
  Future<PlayQueueState?> load() async => null;

  @override
  Future<void> save(PlayQueueState state) async {}
}

/// Store double driving the two branches without a DB.
class _FakeStore extends UnifiedPlayQueueStore {
  _FakeStore({
    required this.queryMode,
    List<PlayQueueItem> single = const [],
    int currentIndex = 0,
    this.virtualPos = 0,
    this.count = 0,
  })  : _single = single,
        _index = currentIndex,
        super(
          legacyPersistence: _NoopPersistence(),
          queryPersistence: _NoopPersistence(),
        );

  final bool queryMode;
  final List<PlayQueueItem> _single;
  final int _index;
  int virtualPos;
  int count;

  final List<String> calls = [];

  @override
  bool get isQueryMode => queryMode;

  @override
  int get currentVirtualPos => virtualPos;

  @override
  int get totalCount => queryMode ? count : _single.length;

  @override
  PlayQueueState get state => PlayQueueState(
        playQueue: _single,
        currentIndex: _index,
      );

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> updateCurrentIndex(int index) async =>
      calls.add('update:$index');
}

List<PlayQueueItem> _items(int count) => [
      for (var i = 0; i < count; i++)
        PlayQueueItem(file: FileItem(name: 'f$i', uri: 'file:///f$i'), index: i),
    ];

void main() {
  group('advancePlayQueueOnCompleted query mode', () {
    test('not at the end advances regardless of repeat', () async {
      final store = _FakeStore(queryMode: true, virtualPos: 1, count: 3);
      expect(
        await advancePlayQueueOnCompleted(Repeat.none, store: store),
        isTrue,
        reason: 'the caller must know the queue really moved',
      );
      expect(store.calls, ['next']);
    });

    test('at the end with repeat-none does not wrap', () async {
      final store = _FakeStore(queryMode: true, virtualPos: 2, count: 3);
      expect(
        await advancePlayQueueOnCompleted(Repeat.none, store: store),
        isFalse,
        reason: 'nothing advanced — a tail latch must not stay armed',
      );
      expect(store.calls, isEmpty);
    });

    test('at the end with repeat-all wraps', () async {
      final store = _FakeStore(queryMode: true, virtualPos: 2, count: 3);
      expect(
        await advancePlayQueueOnCompleted(Repeat.all, store: store),
        isTrue,
      );
      expect(store.calls, ['next']);
    });
  });

  group('advancePlayQueueOnCompleted legacy mode', () {
    test('advances to the next explicit index', () async {
      final store = _FakeStore(queryMode: false, single: _items(3), currentIndex: 0);
      expect(
        await advancePlayQueueOnCompleted(Repeat.none, store: store),
        isTrue,
      );
      expect(store.calls, ['update:1']);
    });

    test('at the end with repeat-none stays put', () async {
      final store = _FakeStore(queryMode: false, single: _items(3), currentIndex: 2);
      expect(
        await advancePlayQueueOnCompleted(Repeat.none, store: store),
        isFalse,
      );
      expect(store.calls, isEmpty);
    });

    test('at the end with repeat-all wraps to the first index', () async {
      final store = _FakeStore(queryMode: false, single: _items(3), currentIndex: 2);
      expect(
        await advancePlayQueueOnCompleted(Repeat.all, store: store),
        isTrue,
      );
      expect(store.calls, ['update:0']);
    });
  });
}
