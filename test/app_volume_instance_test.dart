import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/store/use_app_store.dart';
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

/// Volume/mute are PER-WINDOW live values: each process feeds its own player, so
/// two windows never share a slider. Only the primary window writes the shared
/// stored value — an extra window would otherwise rewrite the whole `app_state`
/// blob (carrying its stale copy of every other setting) on every volume tick.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryKv kv;

  setUp(() {
    kv = _MemoryKv();
    setKvStoreForTest(kv);
    AppInstance.debugReset();
  });

  tearDown(() {
    resetKvStoreForTest();
    AppInstance.debugReset();
  });

  test('the primary window persists volume changes', () async {
    AppInstance.debugSetSlot(1);
    final store = AppStore();
    await store.initialized;
    expect(store.loadOk, isTrue, reason: 'the durable write gate must be open');

    await store.updateVolume(37);
    await store.updateMute(true);

    final blob = kv.values['app_state'];
    expect(blob, isNotNull);
    final json = jsonDecode(blob!) as Map<String, dynamic>;
    expect(json['volume'], 37);
    expect(json['isMuted'], isTrue);
  });

  test('an extra window keeps volume in memory only', () async {
    AppInstance.debugSetSlot(2);
    final store = AppStore();
    await store.initialized;

    await store.updateVolume(23);
    await store.updateMute(true);

    expect(store.state.volume, 23, reason: 'the window keeps its live value');
    expect(store.state.isMuted, isTrue);
    expect(kv.values['app_state'], isNull,
        reason: 'a second window must not overwrite the shared settings blob');
  });

  test('an extra window keeps unrelated settings out of the shared blob',
      () async {
    AppInstance.debugSetSlot(2);
    final store = AppStore();
    await store.initialized;

    await store.updateThemeMode(ThemeMode.dark);

    expect(store.state.themeMode, ThemeMode.dark);
    // The whole-snapshot blob stays with the authoritative window; an extra
    // window's change is persisted through the per-field metadata rows path
    // (see app_state_multi_instance_persist_test.dart), never by rewriting a
    // snapshot that may predate a sibling's edits.
    expect(kv.values['app_state'], isNull);
  });

  test('an extra window does not rewrite the shared blob on shutdown', () async {
    AppInstance.debugSetSlot(2);
    final store = AppStore();
    await store.initialized;
    await store.updateVolume(11);

    await store.dispose();

    expect(kv.values['app_state'], isNull,
        reason: 'its shutdown snapshot may be stale for other settings');
  });
}
