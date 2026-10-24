import 'package:flutter_test/flutter_test.dart';
import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/session_kv.dart';
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

void main() {
  late _MemoryKv base;

  setUp(() {
    base = _MemoryKv();
    setKvStoreForTest(base);
  });

  tearDown(() {
    resetKvStoreForTest();
    AppInstance.debugReset();
  });

  test('a session write never touches the base key', () async {
    final session = SessionKv(inner: base, prefix: 's2.');
    await session.write(key: 'queue', value: 'B');

    expect(base.values['queue'], isNull);
    expect(base.values['s2.queue'], 'B');
    expect(await session.read(key: 'queue'), 'B');
  });

  test('two sessions are isolated from each other', () async {
    final second = SessionKv(inner: base, prefix: 's2.');
    final third = SessionKv(inner: base, prefix: 's3.');
    await second.write(key: 'queue', value: 'B');
    await third.write(key: 'queue', value: 'C');

    expect(await second.read(key: 'queue'), 'B');
    expect(await third.read(key: 'queue'), 'C');
    expect(
      await SessionKv(inner: base, prefix: 's4.').read(key: 'queue'),
      isNull,
    );
  });

  test('delete / containsKey / readAll stay inside the session', () async {
    await base.write(key: 'queue', value: 'primary');
    final session = SessionKv(inner: base, prefix: 's2.');
    await session.write(key: 'queue', value: 'B');
    await session.write(key: 'history', value: 'H');

    expect(await session.containsKey(key: 'queue'), isTrue);
    expect(await session.readAll(), {'queue': 'B', 'history': 'H'});

    await session.delete(key: 'queue');
    expect(await session.containsKey(key: 'queue'), isFalse);
    expect(await base.read(key: 'queue'), 'primary');
  });

  test('getSessionKvStore: slot 1 uses the raw backend, slot 2+ scopes',
      () async {
    AppInstance.debugSetSlot(1);
    await getSessionKvStore().write(key: 'queue', value: 'A');
    expect(base.values['queue'], 'A');

    AppInstance.debugSetSlot(2);
    await getSessionKvStore().write(key: 'queue', value: 'B');
    expect(base.values['s2.queue'], 'B');
    expect(base.values['queue'], 'A');
  });
}
