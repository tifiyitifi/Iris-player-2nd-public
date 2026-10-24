import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/utils/app_instance.dart';

/// Slot allocation is what makes "two windows, two session states" possible:
/// the first process keeps the historical keys (slot 1), the next one gets a
/// free numbered slot and scopes its queue/history with `s<n>.`.
void main() {
  tearDown(() {
    AppInstance.debugReset();
    resetKvStoreForTest();
  });

  test('session prefix: slot 1 is unprefixed, others are scoped', () {
    AppInstance.debugSetSlot(1);
    expect(AppInstance.isPrimary, isTrue);
    expect(AppInstance.sessionPrefix, '');

    AppInstance.debugSetSlot(2);
    expect(AppInstance.isPrimary, isFalse);
    expect(AppInstance.sessionPrefix, 's2.');

    AppInstance.debugSetSlot(3);
    expect(AppInstance.sessionPrefix, 's3.');
  });

  test('lowest free slot is reused after a window closes', () async {
    final dir = await Directory.systemTemp.createTemp('iris_slots_');
    addTearDown(() => dir.delete(recursive: true));

    final first = await InstanceSlotLock.acquire(dirPath: dir.path);
    final second = await InstanceSlotLock.acquire(dirPath: dir.path);
    expect(first?.slot, 1);
    expect(second?.slot, 2);

    await first!.release();
    final third = await InstanceSlotLock.acquire(dirPath: dir.path);
    expect(third?.slot, 1, reason: 'the lowest free slot is reused');

    await second!.release();
    await third!.release();
  }, skip: !Platform.isWindows);

  test('a slot locked by another holder is skipped', () async {
    final dir = await Directory.systemTemp.createTemp('iris_slots_');
    addTearDown(() => dir.delete(recursive: true));

    // Simulate an already-running window holding slot 1.
    final foreign = await InstanceSlotLock.acquire(dirPath: dir.path);
    expect(foreign?.slot, 1);

    final mine = await InstanceSlotLock.acquire(dirPath: dir.path);
    expect(mine?.slot, 2);

    await foreign!.release();
    await mine!.release();
  }, skip: !Platform.isWindows);

  test('an exhausted slot table yields a throwaway session, never slot 1',
      () async {
    final dir = await Directory.systemTemp.createTemp('iris_slots_');
    addTearDown(() => dir.delete(recursive: true));

    // The last available slot is already held by another window.
    final foreign = await InstanceSlotLock.acquire(dirPath: dir.path);
    expect(foreign?.slot, 1);

    await AppInstance.init(dirOverride: dir.path, slots: 1);

    expect(AppInstance.isEphemeral, isTrue);
    expect(AppInstance.isPrimary, isFalse,
        reason: 'a ninth window must not adopt the primary identity');
    expect(AppInstance.sessionPrefix, 'ephemeral.');
    expect(AppInstance.slotLabel, 'tmp');

    await foreign!.release();
  }, skip: !Platform.isWindows);

  test('one unopenable slot file skips only that slot', () async {
    final dir = await Directory.systemTemp.createTemp('iris_slots_');
    addTearDown(() => dir.delete(recursive: true));
    // A DIRECTORY where slot 1's lock file should be: opening it for append
    // throws FileSystemException, exactly like an AV / permission block. The
    // allocation must try the next slot instead of aborting the loop and
    // dropping the window into the throwaway session while 2..8 are free.
    await Directory('${dir.path}/slot-1.lock').create();

    final lock = await InstanceSlotLock.acquire(dirPath: dir.path);

    expect(lock?.slot, 2, reason: 'only the unusable slot is skipped');
    await lock!.release();
  });

  test('a broken slot directory fails open to a throwaway session, not slot 1',
      () async {
    final dir = await Directory.systemTemp.createTemp('iris_slots_');
    addTearDown(() => dir.delete(recursive: true));
    // A FILE where the slots directory should be: Directory.create throws, so
    // init takes the failure path instead of allocating a slot.
    final blocker = File('${dir.path}/instances');
    await blocker.writeAsString('not a directory');

    await AppInstance.init(dirOverride: blocker.path);

    expect(AppInstance.isEphemeral, isTrue,
        reason: 'an unusable slot dir must never mint a second primary window');
    expect(AppInstance.isPrimary, isFalse);
    expect(AppInstance.sessionPrefix, 'ephemeral.');
    expect(AppInstance.slotLabel, 'tmp');
  });

  test('an ephemeral session never touches the shared KV backend', () async {
    final shared = MemoryKvStore();
    setKvStoreForTest(shared);
    AppInstance.debugSetEphemeral(true);

    final session = getSessionKvStore();
    await session.write(key: 'playQueue_state', value: 'mine');

    expect(shared.values, isEmpty,
        reason: 'a throwaway session must not write shared keys');
    expect(await session.read(key: 'playQueue_state'), 'mine');
    expect(await session.readAll(), {'playQueue_state': 'mine'});
  });
}
