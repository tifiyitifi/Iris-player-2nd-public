import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

/// The play gate waits on `playableSettled`, not on the whole scan:
/// - small local scopes wait for the metadata pass (fully ordered list);
/// - large/network scopes are released as soon as the tree is enumerated.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  Future<RecursiveScanStore> started({required bool waitForMetadata}) async {
    final store = RecursiveScanStore();
    await store.initialized;
    await store.startScan(
      storageId: 's1',
      depthPaths: {
        0: ['a']
      },
      waitForMetadata: waitForMetadata,
    );
    return store;
  }

  test('metadata tier keeps the gate closed until the pass is done', () async {
    final store = await started(waitForMetadata: true);
    var released = false;
    store.playableSettled.then((_) => released = true);
    await Future<void>.delayed(Duration.zero);

    store.addFilesSeen(1200);
    store.markEnumerationComplete();
    await Future<void>.delayed(Duration.zero);
    expect(released, isFalse,
        reason: 'a small local scope waits for duration/resolution');

    store.markPlayableReady();
    await Future<void>.delayed(Duration.zero);
    expect(released, isTrue);
    expect(store.filesSeen, 1200);
  });

  test('background tier releases the gate right after enumeration', () async {
    final store = await started(waitForMetadata: false);
    var released = false;
    store.playableSettled.then((_) => released = true);
    await Future<void>.delayed(Duration.zero);
    expect(released, isFalse);

    store.markEnumerationComplete();
    await Future<void>.delayed(Duration.zero);
    expect(released, isTrue);
  });

  test('a scope that grows past the limit downgrades to play-now', () async {
    final store = await started(waitForMetadata: true);
    var released = false;
    store.playableSettled.then((_) => released = true);

    store.addFilesSeen(40000);
    store.disableMetadataWait();
    store.markEnumerationComplete();
    await Future<void>.delayed(Duration.zero);
    expect(released, isTrue);
  });

  test('a new run releases the previous run\'s waiters', () async {
    final store = await started(waitForMetadata: true);
    var released = false;
    store.playableSettled.then((_) => released = true);
    await Future<void>.delayed(Duration.zero);

    // A superseding run must never leave the first action's gate hanging.
    await store.startScan(
      storageId: 's1',
      depthPaths: {
        0: ['b']
      },
      waitForMetadata: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(released, isTrue);
  });
}
