import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/store/use_app_store.dart';

/// Performance contract for the seek-step adjuster: live updates (held keys /
/// strip drag) must NEVER persist, because each persist re-encodes the whole
/// AppState and rewrites every settings row. Persistence happens once, on
/// commit (key-up / drag-end / popover close).
void main() {
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  var appStateWrites = 0;
  String? lastAppStateWrite;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      if (call.method == 'write') {
        final Object? args = call.arguments;
        if (args is Map && args['key'] == 'app_state') {
          appStateWrites++;
          lastAppStateWrite = args['value'] as String?;
        }
      }
      return null;
    });
  });

  setUp(() {
    // Legacy mode forces the blob write path, making persistence observable
    // without a DB (metadata rows need a ready module, absent in unit tests).
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: false,
          seekStepSeconds: 5,
        ));
    appStateWrites = 0;
  });

  test('live updates change the value without persisting', () async {
    final store = useAppStore();
    store.updateSeekStepSecondsLive(6);
    store.updateSeekStepSecondsLive(7);
    store.updateSeekStepSecondsLive(8);
    await pumpEventQueue();

    expect(store.state.seekStepSeconds, 8);
    expect(appStateWrites, 0, reason: 'live must not touch storage');
  });

  test('commit persists the pending value exactly once', () async {
    final store = useAppStore();
    store.updateSeekStepSecondsLive(6);
    store.updateSeekStepSecondsLive(7);
    await store.commitSeekStepSeconds();
    expect(appStateWrites, 1, reason: 'commit persists once');

    // A second commit with no pending change is a no-op.
    await store.commitSeekStepSeconds();
    expect(appStateWrites, 1);
  });

  test('dispose flushes a pending live seek-step value', () async {
    // A held gesture / key can end without its release callback (dialog,
    // crash, force close). The store's own dispose must still land the value
    // instead of leaving the old one stored.
    final store = AppStore();
    await store.initialized;
    // Legacy mode forces the blob path so persistence is observable without a
    // ready metadata module (same trick as the other tests).
    store.set(store.state.copyWith(
      useMetadataSettings: false,
      seekStepSeconds: 5,
    ));
    appStateWrites = 0;

    store.updateSeekStepSecondsLive(9);
    await pumpEventQueue();
    expect(store.state.seekStepSeconds, 9);
    expect(appStateWrites, 0, reason: 'live must stay in memory');

    await store.dispose();
    expect(appStateWrites, isNonZero,
        reason: 'dispose must flush the pending value');
    // The teardown writes the whole snapshot (commit + PersistentStore's own
    // dispose save), so assert the value rather than the write count.
    expect(lastAppStateWrite, contains('"seekStepSeconds":9'));
  });

  test('a no-op live update does not mark the store dirty', () async {
    final store = useAppStore();
    store.updateSeekStepSecondsLive(5); // already 5
    await store.commitSeekStepSeconds();
    expect(appStateWrites, 0);
  });

  test('live updates clamp to [1, 120]', () {
    final store = useAppStore();
    store.updateSeekStepSecondsLive(9999);
    expect(store.state.seekStepSeconds, 120);
    store.updateSeekStepSecondsLive(-3);
    expect(store.state.seekStepSeconds, 1);
  });
}
