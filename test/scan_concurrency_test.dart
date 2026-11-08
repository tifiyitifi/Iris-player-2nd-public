import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';

/// Bounded child concurrency: sibling listings overlap (hiding provider
/// round-trip latency) while every child is still visited exactly once.
///
/// The cap is the run-wide listing semaphore, so a NESTED tree must not
/// multiply it per level — the second test pins exactly that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  Storage ftp(String id) => Storage.ftp(
        id: id,
        name: 'FTP',
        host: '10.0.0.2',
        basePath: const [''],
        port: '21',
        username: 'u',
        password: 'p',
      );

  Future<BuildContext> contextOf(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    return ctx;
  }

  testWidgets('sibling directories overlap, each visited exactly once',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'conv-par';
      const kids = ['kidA', 'kidB', 'kidC', 'kidD'];
      var inFlight = 0;
      var maxInFlight = 0;
      final seen = <String>[];

      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: ftp(id),
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        listDir: (s, p) async {
          final key = p.join('/');
          if (key == 's') {
            return FileListResult([
              for (final k in kids)
                FileItem(name: k, uri: 's/$k', isDir: true),
            ]);
          }
          inFlight++;
          maxInFlight = max(maxInFlight, inFlight);
          await Future<void>.delayed(const Duration(milliseconds: 60));
          inFlight--;
          seen.add(key);
          return const FileListResult(<FileItem>[]);
        },
      );

      await service.scanRecursively(rootPaths: const ['s'], context: ctx);

      expect(scanStore.state.phase, ScanPhase.done);
      expect(seen.length, kids.length,
          reason: 'every child is visited exactly once');
      expect(seen.toSet(), {'s/kidA', 's/kidB', 's/kidC', 's/kidD'});
      expect(maxInFlight, greaterThan(1),
          reason: 'sibling listings overlap instead of running serially');
      expect(maxInFlight, lessThanOrEqualTo(kScanMaxConcurrency),
          reason: 'concurrency stays bounded');
    });
  });

  testWidgets('nesting does not multiply the listing cap', (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'conv-nest';
      // A 4-wide, 4-deep tree: 4 + 16 + 64 + 256 directories, far more than
      // the cap. Per-level workers (3 each) would open many more than
      // kScanMaxConcurrency listings at once.
      const depth = 4;
      const width = 4;
      var inFlight = 0;
      var maxInFlight = 0;

      List<FileItem> childrenOf(String path) {
        final level = path.isEmpty ? 0 : path.split('/').length;
        if (level >= depth) return const <FileItem>[];
        return [
          for (var i = 0; i < width; i++)
            FileItem(
              name: 'd$i',
              uri: '$path/d$i',
              isDir: true,
            ),
        ];
      }

      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: ftp(id),
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        listDir: (s, p) async {
          inFlight++;
          maxInFlight = max(maxInFlight, inFlight);
          await Future<void>.delayed(const Duration(milliseconds: 4));
          inFlight--;
          return FileListResult(childrenOf(p.join('/')));
        },
      );

      await service.scanRecursively(rootPaths: const ['root'], context: ctx);

      expect(scanStore.state.phase, ScanPhase.done);
      expect(maxInFlight, lessThanOrEqualTo(kScanMaxConcurrency),
          reason: 'the cap is run-wide, not per directory level');
      // Every directory is still counted once: 1 + 4 + 16 + 64 (a 4-component
      // path is the deepest one that still gets listed and counted).
      expect(scanStore.state.scannedDirs,
          1 + width + width * width + width * width * width);
    });
  });
}
