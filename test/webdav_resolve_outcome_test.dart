import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/features/webdav_discovery/model/discovery_models.dart';
import 'package:iris/features/webdav_discovery/services/webdav_connect_coordinator.dart';
import 'package:iris/features/webdav_discovery/services/webdav_discovery.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/enums/storage_list_error.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';

import 'helpers/sqlite3_loader.dart';

/// Scripted resolver: emits exactly the given events, no network involved.
class _ScriptedDiscovery extends WebDavDiscovery {
  _ScriptedDiscovery(this.events);

  final List<DiscoveryEvent> events;

  @override
  Stream<DiscoveryEvent> resolve(
    WebDAVStorage storage, {
    Set<String> excludedHosts = const <String>{},
  }) =>
      Stream<DiscoveryEvent>.fromIterable(events);
}

/// Emits whatever it is handed, whenever — including nothing at all, which is
/// what an SSDP window or a slow probe looks like from the caller's side.
class _ManualDiscovery extends WebDavDiscovery {
  _ManualDiscovery(this.controller);

  final StreamController<DiscoveryEvent> controller;

  @override
  Stream<DiscoveryEvent> resolve(
    WebDAVStorage storage, {
    Set<String> excludedHosts = const <String>{},
  }) =>
      controller.stream;
}

WebDAVStorage _storage({String host = '192.168.*.*', List<String> resolved = const <String>[]}) =>
    WebDAVStorage(
      id: 's1',
      name: 'nas',
      host: host,
      resolvedHosts: resolved,
      basePath: const <String>['/'],
      port: '8090',
      username: 'u',
      password: 'p',
      https: false,
    );

void main() {
  ensureSqlite3Loaded();

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    useStorageStore();
    await useStorageStore().initialized;
  });

  group('webdavNeedsResolution', () {
    test('true only for an unresolved wildcard', () {
      expect(webdavNeedsResolution(_storage()), isTrue);
      expect(
        webdavNeedsResolution(_storage(resolved: const <String>['192.168.1.4'])),
        isFalse,
      );
      expect(webdavNeedsResolution(_storage(host: '192.168.1.4')), isFalse);
    });
  });

  group('resolveDetailed outcomes', () {
    test('verified reports the host and no failure', () async {
      final coordinator = WebDavConnectCoordinator(
        discovery: _ScriptedDiscovery(const [DiscoveryVerified('192.168.1.4')]),
      );
      final outcome = await coordinator.resolveDetailed(_storage());

      expect(outcome.ok, isTrue);
      expect(outcome.host, '192.168.1.4');
      expect(outcome.errorKind, isNull);
    });

    test('exhausted reports an unreachable failure with detail', () async {
      final coordinator = WebDavConnectCoordinator(
        discovery: _ScriptedDiscovery(const [DiscoveryExhausted()]),
      );
      final outcome = await coordinator.resolveDetailed(_storage());

      expect(outcome.ok, isFalse);
      expect(outcome.host, isNull);
      expect(outcome.errorKind, StorageListErrorKind.unreachable);
      expect(outcome.errorDetail, isNotNull);
    });

    test('rejected credentials report unauthorized', () async {
      final coordinator = WebDavConnectCoordinator(
        discovery:
            _ScriptedDiscovery(const [DiscoveryAuthRejected('192.168.1.9')]),
      );
      final outcome = await coordinator.resolveDetailed(_storage());

      expect(outcome.errorKind, StorageListErrorKind.unauthorized);
      expect(outcome.errorDetail, contains('192.168.1.9'));
    });
  });

  group('resolveDetailed progress', () {
    test('every candidate is forwarded so the UI can show live progress',
        () async {
      final seen = <DiscoveryCandidate>[];
      final coordinator = WebDavConnectCoordinator(
        discovery: _ScriptedDiscovery(const [
          DiscoveryCandidate(
            host: '192.168.1.7',
            index: 1,
            total: 3,
            stage: DiscoveryStage.cached,
          ),
          DiscoveryCandidate(
            host: '192.168.1.8',
            index: 2,
            total: 3,
            stage: DiscoveryStage.scan,
          ),
          DiscoveryVerified('192.168.1.8'),
        ]),
      );
      final outcome = await coordinator.resolveDetailed(
        _storage(),
        onCandidate: seen.add,
      );

      expect(seen.map((c) => c.host), ['192.168.1.7', '192.168.1.8']);
      expect(seen.last.total, 3);
      expect(outcome.ok, isTrue);
    });

    test('a caller that gives up reports cancelled, not a failure', () async {
      final seen = <DiscoveryCandidate>[];
      var wants = true;
      final coordinator = WebDavConnectCoordinator(
        discovery: _ScriptedDiscovery(const [
          DiscoveryCandidate(
            host: '192.168.1.7',
            index: 1,
            total: 9,
            stage: DiscoveryStage.scan,
          ),
          DiscoveryCandidate(
            host: '192.168.1.8',
            index: 2,
            total: 9,
            stage: DiscoveryStage.scan,
          ),
          DiscoveryExhausted(),
        ]),
      );
      // The user dismisses the progress surface on the first candidate: the
      // rest of the (potentially huge) scan must not be reported as a failure.
      final outcome = await coordinator.resolveDetailed(
        _storage(),
        onCandidate: (c) {
          seen.add(c);
          wants = false;
        },
        stillWanted: () => wants,
      );

      expect(outcome.cancelled, isTrue);
      expect(outcome.ok, isFalse);
      expect(outcome.errorKind, isNull);
      expect(outcome.errorDetail, isNull);
      expect(seen.length, 1, reason: 'the loop must stop at the cancellation');
    });

    test('a give-up during a silent stretch lands without waiting for an event',
        () async {
      // The progress surface is cancellable, so a cancel has to be noticed even
      // while discovery says nothing: the SSDP collection window and a probe
      // waiting out its timeout are exactly this shape, and a polling that only
      // runs between events leaves the user looking at a window that stopped
      // responding for seconds after they dismissed it.
      final controller = StreamController<DiscoveryEvent>();
      var subscriptionCancelled = false;
      controller.onCancel = () => subscriptionCancelled = true;
      addTearDown(controller.close);

      var wants = true;
      final coordinator = WebDavConnectCoordinator(
        discovery: _ManualDiscovery(controller),
      );

      final pending = coordinator.resolveDetailed(
        _storage(),
        stillWanted: () => wants,
      );
      Timer(const Duration(milliseconds: 50), () => wants = false);
      final outcome = await pending.timeout(const Duration(seconds: 3));

      expect(outcome.cancelled, isTrue,
          reason: 'no event will ever arrive to notice the cancel');
      expect(outcome.errorKind, isNull,
          reason: 'nothing is known about the far end, so nothing is reported');
      expect(subscriptionCancelled, isTrue,
          reason: 'abandoning the run has to stop the discovery stream');
    });

    test('events still stop the run at the next one', () async {
      // The timer is a safety net, not the mechanism: a stream that keeps
      // talking must still be cut off by the event that follows the cancel.
      final controller = StreamController<DiscoveryEvent>();
      addTearDown(controller.close);

      var wants = true;
      final seen = <DiscoveryCandidate>[];
      final coordinator = WebDavConnectCoordinator(
        discovery: _ManualDiscovery(controller),
      );

      final pending = coordinator.resolveDetailed(
        _storage(),
        onCandidate: seen.add,
        stillWanted: () => wants,
      );
      controller.add(DiscoveryCandidate(
        host: '192.168.1.7',
        index: 1,
        total: 9,
        stage: DiscoveryStage.scan,
      ));
      await Future<void>.delayed(Duration.zero);
      wants = false;
      controller.add(DiscoveryCandidate(
        host: '192.168.1.8',
        index: 2,
        total: 9,
        stage: DiscoveryStage.scan,
      ));
      controller.add(const DiscoveryExhausted());

      final outcome = await pending.timeout(const Duration(seconds: 3));
      expect(outcome.cancelled, isTrue);
      expect(seen.length, 1);
    });
  });
}
