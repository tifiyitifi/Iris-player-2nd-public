import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/services/update_lease.dart';

/// Two windows must never download/apply the same update at once: they write
/// the same package file and can start the same installer.
void main() {
  tearDown(UpdateLease.debugReset);

  test('the disabled lease never blocks an update', () async {
    final lease = UpdateLease.disabled();
    expect(await lease.acquire(), isTrue);
    expect(await lease.acquire(), isTrue, reason: 're-entrant');
    await lease.release();
  });

  test('a held update lease refuses the second window until released', () async {
    final dir = await Directory.systemTemp.createTemp('iris_update_lease_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/update.lock';

    final first = UpdateLease(lockPath: path);
    final second = UpdateLease(lockPath: path);

    expect(await first.acquire(), isTrue);
    expect(await second.acquire(), isFalse,
        reason: 'another live window owns the update');

    await first.release();
    expect(await second.acquire(), isTrue);
    await second.release();
  }, skip: !Platform.isWindows);
}
