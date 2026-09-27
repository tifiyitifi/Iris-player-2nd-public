import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/service/scan_preflight.dart';
import 'package:iris/features/webdav_discovery/model/discovery_models.dart';
import 'package:iris/features/webdav_discovery/services/webdav_connect_coordinator.dart';
import 'package:iris/models/enums/storage_list_error.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';

// Entry-side remote-connect handling for the storagedb Storage-tab scan:
// an unreachable/unauthorized host is classified up front, never mistaken for
// an empty directory (which would purge the DB snapshot).
void main() {
  Storage local() => Storage.local(
        id: 'l1',
        type: StorageType.internal,
        name: 'Local',
        basePath: const ['/tmp'],
      );

  FTPStorage ftp() => Storage.ftp(
        id: 'ftp1',
        name: 'FTP',
        host: '10.0.0.2',
        basePath: const [''],
        port: '21',
        username: 'u',
        password: 'p',
      ) as FTPStorage;

  WebDAVStorage wildcard({List<String> resolvedHosts = const []}) =>
      Storage.webdav(
        id: 'w1',
        name: 'WebDAV',
        host: '192.168.1.*',
        basePath: const [''],
        port: '80',
        username: 'u',
        password: 'p',
        https: false,
        resolvedHosts: resolvedHosts,
      ) as WebDAVStorage;

  FileItem item(String name) => FileItem(
        storageId: 'w1',
        storageType: StorageType.webdav,
        name: name,
        uri: name,
        path: [name],
      );

  test('local storage is returned as-is without any listing', () async {
    final storage = local();
    var listed = false;
    final result = await prepareStorageForScan(
      storage,
      list: (s, p) async {
        listed = true;
        return FileListResult.empty;
      },
    );
    expect(result.ok, isTrue);
    expect(identical(result.storage, storage), isTrue);
    expect(listed, isFalse);
  });

  test('remote listing failure is classified, scan is not started', () async {
    final result = await prepareStorageForScan(
      ftp(),
      list: (s, p) async => const FileListResult(
        <FileItem>[],
        errorKind: StorageListErrorKind.unreachable,
        errorDetail: 'connection refused',
      ),
    );
    expect(result.ok, isFalse);
    expect(result.errorKind, StorageListErrorKind.unreachable);
    expect(result.errorDetail, 'connection refused');
  });

  test('remote listing success starts the scan', () async {
    final result = await prepareStorageForScan(
      ftp(),
      list: (s, p) async => FileListResult([item('a.mp4')]),
    );
    expect(result.ok, isTrue);
    expect(result.storage, isA<FTPStorage>());
  });

  test('wildcard resolve failure is classified', () async {
    final result = await prepareStorageForScan(
      wildcard(),
      resolve: (s, excluded, {onProgress, stillWanted}) async =>
          const WebDavResolveOutcome(
        errorKind: StorageListErrorKind.unreachable,
        errorDetail: 'no candidate host answered',
      ),
      readback: (_) => null,
      list: (s, p) async => FileListResult([item('a.mp4')]),
    );
    expect(result.ok, isFalse);
    expect(result.errorKind, StorageListErrorKind.unreachable);
  });

  test('wildcard resolve success scans the resolved entry', () async {
    final stored = wildcard(resolvedHosts: const ['192.168.1.5']);
    final result = await prepareStorageForScan(
      wildcard(),
      resolve: (s, excluded, {onProgress, stillWanted}) async =>
          const WebDavResolveOutcome(host: '192.168.1.5'),
      readback: (_) => stored,
      list: (s, p) async => FileListResult([item('a.mp4')]),
    );
    expect(result.ok, isTrue);
    final target = result.storage! as WebDAVStorage;
    expect(target.resolvedHost, '192.168.1.5');
  });

  test('wildcard empty root re-resolves and treats still-empty as unreachable',
      () async {
    var resolveCalls = 0;
    final result = await prepareStorageForScan(
      wildcard(resolvedHosts: const ['192.168.1.5']),
      resolve: (s, excluded, {onProgress, stillWanted}) async {
        resolveCalls++;
        // First resolve (no exclusions) picks a host; the retry excludes the
        // cached host and finds nothing new.
        if (excluded.isEmpty) {
          return const WebDavResolveOutcome(host: '192.168.1.5');
        }
        return const WebDavResolveOutcome(
          errorKind: StorageListErrorKind.unreachable,
          errorDetail: 'none',
        );
      },
      readback: (_) => wildcard(resolvedHosts: const ['192.168.1.5']),
      list: (s, p) async => FileListResult.empty,
    );
    expect(result.ok, isFalse);
    expect(result.errorKind, StorageListErrorKind.unreachable);
    expect(resolveCalls, 2);
  });

  // The empty-root retry re-runs discovery, and each of its two steps already
  // knows why it failed. Collapsing both into one hardcoded "unreachable" made
  // the dialog send the user to the wrong remedy — retry a connection whose
  // real problem is a rejected password.
  group('empty-root retry keeps the real reason', () {
    test('an unauthorized re-resolve is not reported as an unreachable host',
        () async {
      final result = await prepareStorageForScan(
        wildcard(resolvedHosts: const ['192.168.1.5']),
        resolve: (s, excluded, {onProgress, stillWanted}) async {
          if (excluded.isEmpty) {
            return const WebDavResolveOutcome(host: '192.168.1.5');
          }
          return const WebDavResolveOutcome(
            errorKind: StorageListErrorKind.unauthorized,
            errorDetail: 'credentials rejected by 192.168.1.9',
          );
        },
        readback: (_) => wildcard(resolvedHosts: const ['192.168.1.5']),
        list: (s, p) async => FileListResult.empty,
      );

      expect(result.ok, isFalse);
      expect(result.errorKind, StorageListErrorKind.unauthorized);
      expect(result.errorDetail, 'credentials rejected by 192.168.1.9');
    });

    test('a re-resolved host whose root fails to list keeps that failure',
        () async {
      var listCalls = 0;
      final result = await prepareStorageForScan(
        wildcard(resolvedHosts: const ['192.168.1.5']),
        resolve: (s, excluded, {onProgress, stillWanted}) async =>
            WebDavResolveOutcome(
          host: excluded.isEmpty ? '192.168.1.5' : '192.168.1.20',
        ),
        readback: (_) => null,
        list: (s, p) async {
          listCalls++;
          // The cached host answers with an empty root; the host discovery
          // then finds one that authenticates, but its listing times out.
          final hosts = (s as WebDAVStorage).resolvedHosts;
          if (hosts.contains('192.168.1.20')) {
            return const FileListResult(
              <FileItem>[],
              errorKind: StorageListErrorKind.timeout,
              errorDetail: 'read timed out',
            );
          }
          return FileListResult.empty;
        },
      );

      expect(listCalls, 2, reason: 'the empty root must be retried elsewhere');
      expect(result.ok, isFalse);
      expect(result.errorKind, StorageListErrorKind.timeout,
          reason: 'a verified host that cannot be listed is not an '
              'unreachable host');
      expect(result.errorDetail, 'read timed out');
    });
  });

  // The empty-root guard only means something while the resolved host can still
  // be recognized as a resolved wildcard, so the fallback path (a store that
  // has not caught up) is held to the same contract as the readback one:
  // [libraryHost] is the host that actually serves the library, every other
  // host answers with an empty root.
  ScanPreflightList emptyRootUnless(String libraryHost) =>
      (Storage s, List<String> p) async {
        final w = s as WebDAVStorage;
        for (final host in [...w.resolvedHosts, w.host]) {
          if (host == libraryHost) return FileListResult([item('a.mp4')]);
        }
        return FileListResult.empty;
      };

  test('a store that has not caught up still re-resolves an empty root',
      () async {
    final excludedPerCall = <Set<String>>[];
    final result = await prepareStorageForScan(
      wildcard(resolvedHosts: const ['192.168.1.5']),
      resolve: (s, excluded, {onProgress, stillWanted}) async {
        excludedPerCall.add(excluded);
        // The first pass commits to a machine that answers with an empty root;
        // the retry must look past every host already tried and find the one
        // holding the library.
        if (excluded.isEmpty) return const WebDavResolveOutcome(host: '192.168.1.9');
        return const WebDavResolveOutcome(host: '192.168.1.20');
      },
      readback: (_) => null,
      list: emptyRootUnless('192.168.1.20'),
    );

    expect(excludedPerCall.length, 2,
        reason: 'an empty root must re-resolve, not be taken as proof-empty');
    expect(excludedPerCall.last, containsAll(<String>['192.168.1.9', '192.168.1.5']),
        reason: 'the retry must ignore every host already tried');
    expect(result.ok, isTrue);
    final target = result.storage! as WebDAVStorage;
    expect(target.host, '192.168.1.*');
    expect(target.resolvedHost, '192.168.1.20');
  });

  test('a store that has not caught up never accepts an empty root as proof',
      () async {
    // No host ever serves the library: reporting this as ready would let the
    // scan reconcile the root to empty and purge the DB snapshot.
    final result = await prepareStorageForScan(
      wildcard(resolvedHosts: const ['192.168.1.5']),
      resolve: (s, excluded, {onProgress, stillWanted}) async =>
          const WebDavResolveOutcome(host: '192.168.1.9'),
      readback: (_) => null,
      list: emptyRootUnless('192.168.1.20'),
    );

    expect(result.ok, isFalse);
    expect(result.errorKind, StorageListErrorKind.unreachable);
  });

  test('a store that has not caught up still scans the verified host',
      () async {
    final result = await prepareStorageForScan(
      wildcard(),
      resolve: (s, excluded, {onProgress, stillWanted}) async =>
          const WebDavResolveOutcome(host: '192.168.1.9'),
      readback: (_) => null,
      list: emptyRootUnless('192.168.1.9'),
    );

    expect(result.ok, isTrue);
    final target = result.storage! as WebDAVStorage;
    // The pattern stays the configured host; the verified host heads the
    // history, exactly as the persisted entry would look.
    expect(target.host, '192.168.1.*');
    expect(target.resolvedHosts, const ['192.168.1.9']);
  });

  group('preflight progress', () {
    DiscoveryCandidate candidate(String host) => DiscoveryCandidate(
          host: host,
          index: 1,
          total: 4,
          stage: DiscoveryStage.scan,
        );

    test('candidates are forwarded, then null once listing starts', () async {
      final seen = <DiscoveryCandidate?>[];
      await prepareStorageForScan(
        wildcard(),
        resolve: (s, excluded, {onProgress, stillWanted}) async {
          onProgress?.call(candidate('192.168.1.5'));
          return const WebDavResolveOutcome(host: '192.168.1.5');
        },
        readback: (_) => null,
        list: (s, p) async => FileListResult([item('a.mp4')]),
        onProgress: seen.add,
      );

      expect(seen.length, 2);
      expect(seen.first?.host, '192.168.1.5');
      expect(seen.last, isNull,
          reason: 'naming a candidate while listing the root would be a lie');
    });

    test('an abandoned resolve is not reported as a failure', () async {
      final result = await prepareStorageForScan(
        wildcard(),
        resolve: (s, excluded, {onProgress, stillWanted}) async {
          onProgress?.call(candidate('192.168.1.5'));
          return const WebDavResolveOutcome(cancelled: true);
        },
        readback: (_) => null,
        list: (s, p) async {
          fail('the scan must not start after the user gave up');
        },
        onProgress: (_) {},
      );

      expect(result.ok, isFalse);
      expect(result.cancelled, isTrue);
      expect(result.errorKind, isNull);
    });

    test('an abandoned re-resolve is not reported as a failure', () async {
      final result = await prepareStorageForScan(
        wildcard(resolvedHosts: const ['192.168.1.5']),
        resolve: (s, excluded, {onProgress, stillWanted}) async {
          if (excluded.isEmpty) {
            return const WebDavResolveOutcome(host: '192.168.1.5');
          }
          return const WebDavResolveOutcome(cancelled: true);
        },
        readback: (_) => wildcard(resolvedHosts: const ['192.168.1.5']),
        list: (s, p) async => FileListResult.empty,
      );

      expect(result.ok, isFalse);
      expect(result.cancelled, isTrue);
      expect(result.errorKind, isNull);
    });
  });

  group('preflight cancellation', () {
    // The root listing is a network round trip the caller cannot interrupt (the
    // client gives it 8 s), so the only thing left to honour a give-up is to
    // stop starting one and stop believing one.
    test('a give-up before the listing starts it never', () async {
      var listed = false;
      final result = await prepareStorageForScan(
        ftp(),
        list: (s, p) async {
          listed = true;
          return FileListResult([item('a.mp4')]);
        },
        stillWanted: () => false,
      );

      expect(listed, isFalse, reason: 'nobody is waiting for the answer');
      expect(result.ok, isFalse);
      expect(result.cancelled, isTrue);
    });

    test('a give-up during the listing is not acted on', () async {
      var wants = true;
      final result = await prepareStorageForScan(
        ftp(),
        list: (s, p) async {
          // The user dismisses the progress window while the root is being
          // listed; the listing still finishes, and its answer is now moot.
          wants = false;
          return FileListResult([item('a.mp4')]);
        },
        stillWanted: () => wants,
      );

      expect(result.ok, isFalse);
      expect(result.cancelled, isTrue);
      expect(result.errorKind, isNull);
    });
  });
}
