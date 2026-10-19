import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/services/update_handoff.dart';
import 'package:path/path.dart' as p;

/// The pending-update record is a plain JSON file in the download directory, so
/// its `package` field is untrusted input. Only a package that actually lives
/// in the run's work directory may be deleted once the update lands.
void main() {
  late Directory root;
  late Directory work;
  late Directory outside;

  setUp(() {
    root = Directory.systemTemp.createTempSync('iris-handoff-delete');
    work = Directory(p.join(root.path, 'updates'))..createSync(recursive: true);
    outside = Directory(p.join(root.path, 'elsewhere'))..createSync();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<File> seedPackage(Directory dir, String name) async {
    final file = File(p.join(dir.path, name))..writeAsStringSync('PK');
    await recordPendingUpdate(
      workDir: work.path,
      fromVersion: '1.0.0',
      toVersion: '1.1.0',
      packagePath: file.path,
    );
    return file;
  }

  test('deletes the applied package when it lives in the work directory',
      () async {
    final package = await seedPackage(work, 'IRIS-1.1.0.zip');

    final report = await takePreviousUpdateReport(
      workDir: work.path,
      runningVersion: '1.1.0',
    );

    expect(report, isNotNull);
    expect(report!.applied, isTrue);
    expect(package.existsSync(), isFalse);
    expect(
        File(p.join(work.path, pendingUpdateFileName)).existsSync(), isFalse);
  });

  test('refuses to delete a package outside the work directory', () async {
    final package = await seedPackage(outside, 'victim.zip');

    final report = await takePreviousUpdateReport(
      workDir: work.path,
      runningVersion: '1.1.0',
    );

    expect(report, isNotNull);
    expect(report!.applied, isTrue);
    expect(package.existsSync(), isTrue,
        reason: 'the record must not be able to delete arbitrary files');
    expect(File(p.join(work.path, pendingUpdateFileName)).existsSync(), isFalse,
        reason: 'the one-shot record is still consumed');
  });
}
