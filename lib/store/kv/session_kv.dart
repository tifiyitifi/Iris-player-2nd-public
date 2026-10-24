import 'package:iris/store/kv/kv_store.dart';

/// [KvStore] decorator that prefixes every key with one instance's session
/// prefix (`s2.`, `s3.`, …).
///
/// WHY: several IRIS windows share one settings backend. Config (storages,
/// theme, metadata settings) must stay shared, but the playback SESSION (queue,
/// history, active scenario) belongs to one window. Wrapping just those stores'
/// reads/writes gives each window its own session without a second backend and
/// without touching the persisted data of single-window users (slot 1 is
/// wrapped by nothing — see `getSessionKvStore`).
class SessionKv implements KvStore {
  SessionKv({required this.inner, required this.prefix});

  final KvStore inner;
  final String prefix;

  String _scoped(String key) => '$prefix$key';

  @override
  Future<String?> read({required String key}) => inner.read(key: _scoped(key));

  @override
  Future<void> write({required String key, required String value}) =>
      inner.write(key: _scoped(key), value: value);

  @override
  Future<void> delete({required String key}) => inner.delete(key: _scoped(key));

  @override
  Future<bool> containsKey({required String key}) =>
      inner.containsKey(key: _scoped(key));

  /// Only this session's entries, with the prefix stripped — a caller never
  /// sees another window's session keys.
  @override
  Future<Map<String, String>> readAll() async {
    final all = await inner.readAll();
    return {
      for (final entry in all.entries)
        if (entry.key.startsWith(prefix))
          entry.key.substring(prefix.length): entry.value,
    };
  }
}
