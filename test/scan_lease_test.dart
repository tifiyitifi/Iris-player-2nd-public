import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
import 'package:iris/features/media_library/scan/service/scan_lease.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';

import 'helpers/sqlite3_loader.dart';

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

/// A lease held by "the other window".
class _BusyLease extends ScanLease {
  _BusyLease() : super(lockPath: 'unused');

  @override
  Future<bool> acquire() async => false;

  @override
  Future<void> release() async {}
}

/// Same, but records how often the lease was requested, so a test can prove the
/// lease is NOT taken while the user is still deciding.
class _SpyBusyLease extends _BusyLease {
  int acquires = 0;

  @override
  Future<bool> acquire() async {
    acquires++;
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  setUpAll(() async {
    DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  setUp(() {
    setKvStoreForTest(_MemoryKv());
    ScanLease.debugReset();
  });

  tearDown(() {
    resetKvStoreForTest();
    ScanLease.debugReset();
  });

  test('the disabled lease never blocks a scan', () async {
    final lease = ScanLease.disabled();
    expect(await lease.acquire(), isTrue);
    expect(await lease.acquire(), isTrue, reason: 're-entrant');
    await lease.release();
  });

  test('a held lease refuses the second window until it is released', () async {
    final dir = await Directory.systemTemp.createTemp('iris_scan_lease_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/scan.lock';

    final first = ScanLease(lockPath: path);
    final second = ScanLease(lockPath: path);

    expect(await first.acquire(), isTrue);
    expect(await second.acquire(), isFalse,
        reason: 'another live window owns the scan');

    await first.release();
    expect(await second.acquire(), isTrue);
    await second.release();
  }, skip: !Platform.isWindows);

  testWidgets('a scan request from a second window explains instead of scanning',
      (tester) async {
    ScanLease.debugSetInstance(_BusyLease());
    final scanStore = RecursiveScanStore();
    await scanStore.initialized;

    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    // The localization delegate loads asynchronously; the `home` subtree (and
    // therefore `ctx`) only exists after that settles.
    await tester.pumpAndSettle();

    final service = RecursiveScanService(
      storage: Storage.local(
        id: 'lease-local',
        type: StorageType.internal,
        name: 'Local',
        basePath: const [''],
      ),
      scanStore: scanStore,
      nodesDao: DbModule.mediaNodesDao,
      sourcesDao: DbModule.mediaLibSourcesDao,
    );

    final run = service.scanRecursively(rootPaths: const ['a'], context: ctx);
    await tester.pumpAndSettle();

    expect(find.text('Another IRIS window is scanning'), findsOneWidget);
    expect(scanStore.state.phase, ScanPhase.idle,
        reason: 'no scan may start while another window holds the lease');

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await run;
    expect(scanStore.state.phase, ScanPhase.idle);
  });

  testWidgets('the lease is taken only AFTER the user decides to scan',
      (tester) async {
    // A previous scan was interrupted: the service must ASK first. Holding the
    // cross-window lease while the user reads the prompt made every other
    // window's scan fail with "another window is scanning".
    final spy = _SpyBusyLease();
    ScanLease.debugSetInstance(spy);
    final scanStore = RecursiveScanStore();
    await scanStore.initialized;
    await scanStore.failScan('interrupted');

    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    await tester.pumpAndSettle();

    final service = RecursiveScanService(
      storage: Storage.local(
        id: 'lease-local',
        type: StorageType.internal,
        name: 'Local',
        basePath: const [''],
      ),
      scanStore: scanStore,
      nodesDao: DbModule.mediaNodesDao,
      sourcesDao: DbModule.mediaLibSourcesDao,
    );

    final run = service.scanRecursively(rootPaths: const ['a'], context: ctx);
    await tester.pumpAndSettle();

    expect(find.text('Previous scan was not completed'), findsOneWidget);
    expect(spy.acquires, 0,
        reason: 'user think-time must not hold the cross-window lease');
    expect(find.text('Another IRIS window is scanning'), findsNothing);

    // The user chooses to resume: NOW the service asks for the lease and is
    // refused (the other window is scanning).
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();

    expect(spy.acquires, 1);
    expect(find.text('Another IRIS window is scanning'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await run;
    expect(scanStore.state.phase, ScanPhase.error,
        reason: 'nothing ran, so the interrupted state must stay discoverable');
  });
}
