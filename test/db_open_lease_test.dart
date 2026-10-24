import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/db/app_database_holder.dart';

/// Database migrations run as plain statements inside drift's `beforeOpen` — no
/// transaction, and no cross-process guard. Two windows starting together after
/// an upgrade would both replay the same migration steps, so the open path is
/// serialized with a file lease. These tests pin that serialization.
void main() {
  test('two windows serialize open + migrate', () async {
    final dir = await Directory.systemTemp.createTemp('iris_dblock_');
    addTearDown(() => dir.delete(recursive: true));

    final events = <String>[];

    Future<void> run(String name) async {
      await withDbOpenLease<void>(
        dirPath: dir.path,
        delay: const Duration(milliseconds: 20),
        body: () async {
          events.add('$name:start');
          await Future<void>.delayed(const Duration(milliseconds: 80));
          events.add('$name:end');
        },
      );
    }

    await Future.wait([run('a'), run('b')]);

    expect(events, hasLength(4));
    for (var i = 0; i < events.length; i += 2) {
      expect(
        events[i].replaceAll(':start', ''),
        events[i + 1].replaceAll(':end', ''),
        reason: 'the lease holder must finish before the other window opens',
      );
    }
  });

  test('the lease is released when the body throws', () async {
    final dir = await Directory.systemTemp.createTemp('iris_dblock_');
    addTearDown(() => dir.delete(recursive: true));

    await expectLater(
      withDbOpenLease<void>(
        dirPath: dir.path,
        body: () async => throw StateError('migration failed'),
      ),
      throwsStateError,
    );

    // A second caller is not blocked by the failed holder.
    var ran = false;
    await withDbOpenLease<void>(
      dirPath: dir.path,
      delay: const Duration(milliseconds: 20),
      body: () async {
        ran = true;
      },
    );
    expect(ran, isTrue);
  });
}
