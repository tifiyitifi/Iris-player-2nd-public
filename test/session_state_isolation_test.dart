import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/play_queue/persistence/play_queue_persistence.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/play_queue_state.dart';
import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/utils/app_instance.dart';

class _MemoryKv implements KvStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }

  @override
  Future<bool> containsKey({required String key}) async =>
      values.containsKey(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
}

/// The playback SESSION (queue, history, active scenario) must belong to one
/// window. Slot 1 keeps the historical keys so existing single-window data is
/// untouched; a second window gets its own prefixed copy.
void main() {
  late _MemoryKv base;

  PlayQueueState queueWith(String name) => PlayQueueState(
        playQueue: [
          PlayQueueItem(
            file: FileItem(name: name, uri: '/media/$name', path: [name]),
            index: 0,
          ),
        ],
        currentIndex: 0,
      );

  setUp(() {
    base = _MemoryKv();
    setKvStoreForTest(base);
    AppInstance.debugSetSlot(1);
  });

  tearDown(() {
    resetKvStoreForTest();
    AppInstance.debugReset();
  });

  test('two windows keep independent play queues', () async {
    final persistence = LegacyPlayQueuePersistence();

    await persistence.save(queueWith('window1.mp4'));
    AppInstance.debugSetSlot(2);
    expect(await persistence.load(), isNull,
        reason: 'a new window must not inherit another window queue');
    await persistence.save(queueWith('window2.mp4'));

    AppInstance.debugSetSlot(1);
    expect((await persistence.load())?.playQueue.single.file.name,
        'window1.mp4');
    AppInstance.debugSetSlot(2);
    expect((await persistence.load())?.playQueue.single.file.name,
        'window2.mp4');
  });

  test('two windows keep independent history', () async {
    await getSessionKvStore().write(key: 'history_state', value: '{"a":1}');
    AppInstance.debugSetSlot(2);
    expect(await getSessionKvStore().read(key: 'history_state'), isNull);
    await getSessionKvStore().write(key: 'history_state', value: '{"b":2}');

    AppInstance.debugSetSlot(1);
    expect(
      await getSessionKvStore().read(key: 'history_state'),
      '{"a":1}',
    );
    AppInstance.debugSetSlot(2);
    expect(
      await getSessionKvStore().read(key: 'history_state'),
      '{"b":2}',
    );
  });

  test('slot 1 writes exactly the historical key names', () async {
    await LegacyPlayQueuePersistence().save(queueWith('legacy.mp4'));
    expect(base.values.containsKey('playQueue_state'), isTrue);
    expect(base.values.keys.any((k) => k.startsWith('s')), isFalse);
  });
}
