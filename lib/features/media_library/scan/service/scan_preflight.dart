import 'package:iris/features/webdav_discovery/model/discovery_models.dart';
import 'package:iris/features/webdav_discovery/services/webdav_connect_coordinator.dart';
import 'package:iris/models/enums/storage_list_error.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/storages/webdav.dart';
import 'package:iris/store/use_storage_store.dart';

/// Outcome of preparing a storage for a recursive scan.
///
/// [ok] carries the storage the scan must dial — the resolved entry for a
/// wildcard WebDAV host, otherwise the original storage. A failure carries the
/// classified reason so the caller can explain it (never a silent no-op) and
/// must NOT start the scan.
class ScanPreflightResult {
  const ScanPreflightResult._({
    required this.storage,
    this.errorKind,
    this.errorDetail,
    this.cancelled = false,
  });

  const ScanPreflightResult.ready(Storage storage) : this._(storage: storage);

  const ScanPreflightResult.failed({
    required StorageListErrorKind errorKind,
    required String? errorDetail,
  }) : this._(storage: null, errorKind: errorKind, errorDetail: errorDetail);

  /// The caller stopped waiting (see [WebDavResolveOutcome.cancelled]). Not a
  /// failure: nothing is known about the far end, so the caller must not
  /// explain one and must not start the scan.
  const ScanPreflightResult.abandoned()
      : this._(storage: null, cancelled: true);

  final Storage? storage;
  final StorageListErrorKind? errorKind;
  final String? errorDetail;
  final bool cancelled;

  bool get ok => storage != null;
}

/// Lists a storage directory, reporting failures through [FileListResult].
typedef ScanPreflightList = Future<FileListResult> Function(
    Storage storage, List<String> path);

/// Resolves a wildcard WebDAV entry, excluding [excludeHosts] from discovery.
///
/// [onProgress] receives the host currently being probed, or null when the
/// preflight moved past resolution (listing the live root), so a caller's
/// progress surface can stop naming a candidate that is no longer being tried.
/// [stillWanted] lets the caller abandon the run; see
/// [WebDavResolveOutcome.cancelled].
typedef ScanPreflightResolve = Future<WebDavResolveOutcome> Function(
  WebDAVStorage storage,
  Set<String> excludeHosts, {
  void Function(DiscoveryCandidate? candidate)? onProgress,
  bool Function()? stillWanted,
});

/// Reads the freshest persisted entry for [storageId] (the resolver records the
/// resolved host on it). Null when absent.
typedef ScanPreflightReadback = Storage? Function(String storageId);

Future<FileListResult> _defaultList(Storage storage, List<String> path) =>
    storage.getFilesDetailed(path);

Future<WebDavResolveOutcome> _defaultResolve(
  WebDAVStorage storage,
  Set<String> excludeHosts, {
  void Function(DiscoveryCandidate? candidate)? onProgress,
  bool Function()? stillWanted,
}) =>
    webdavConnectCoordinator().resolveDetailed(
      storage,
      excludeHosts: excludeHosts,
      // A null candidate is the preflight's own "past resolution" signal; the
      // coordinator only ever has real candidates to report.
      onCandidate: onProgress == null ? null : (c) => onProgress(c),
      stillWanted: stillWanted,
    );

Storage? _defaultReadback(String storageId) =>
    useStorageStore().findById(storageId);

/// Pings a storage's live root before a recursive scan so an unreachable or
/// unauthorized host fails up front (with a classified reason) instead of
/// producing an empty scan.
///
/// This is the entry-side half of the "offline never deletes" contract: the
/// scanner also refuses to treat a failed listing as an empty directory, but a
/// preflight lets the UI explain the cause before any work starts.
///
/// Local storages are returned as-is (no network to validate). Wildcard WebDAV
/// entries are resolved to a concrete host first; a resolved-but-empty root
/// listing is treated as unreachable (the cache may point at the wrong
/// machine), so the DB snapshot is never purged.
Future<ScanPreflightResult> prepareStorageForScan(
  Storage storage, {
  ScanPreflightList? list,
  ScanPreflightResolve? resolve,
  ScanPreflightReadback? readback,
  void Function(DiscoveryCandidate? candidate)? onProgress,
  bool Function()? stillWanted,
}) async {
  final listDir = list ?? _defaultList;

  // Only WebDAV/FTP classify listing failures. SAF `network` storages share
  // the local listing path, so they are returned as-is.
  final needsPreflight = storage.type == StorageType.webdav ||
      storage.type == StorageType.ftp;
  if (!needsPreflight) return ScanPreflightResult.ready(storage);

  var target = storage;

  if (target is WebDAVStorage && isIPv4WildcardHost(target.host)) {
    final resolveFn = resolve ?? _defaultResolve;
    final readbackFn = readback ?? _defaultReadback;

    final outcome = await resolveFn(
      target,
      const <String>{},
      onProgress: onProgress,
      stillWanted: stillWanted,
    );
    if (outcome.cancelled) return const ScanPreflightResult.abandoned();
    if (!outcome.ok) {
      return ScanPreflightResult.failed(
        errorKind: outcome.errorKind ?? StorageListErrorKind.unreachable,
        errorDetail: outcome.errorDetail,
      );
    }
    target = _resolvedEntry(target, outcome.host!, readbackFn);
  }

  // Past resolution: no candidate is being tried any more, so a progress
  // surface must stop naming one.
  onProgress?.call(null);
  // The listing cannot be interrupted (the client gives it 8 s), so a give-up
  // can only be honoured by not starting one and not believing one.
  if (stillWanted?.call() == false) return const ScanPreflightResult.abandoned();
  final result = await listDir(target, target.basePath);
  if (stillWanted?.call() == false) return const ScanPreflightResult.abandoned();
  if (!result.hasError) {
    // A wildcard whose cached host answers but serves an EMPTY root is
    // suspicious: the cache may point at a different machine (shared/anonymous
    // credentials + a wide pattern). Re-resolve while ignoring the cache and
    // retry once; if still empty, treat as unreachable (never as proven-empty),
    // because the scan would otherwise purge this storage's snapshot rows.
    if (result.items.isEmpty &&
        target is WebDAVStorage &&
        isIPv4WildcardHost(target.host) &&
        target.resolvedHosts.isNotEmpty) {
      final resolveFn = resolve ?? _defaultResolve;
      final readbackFn = readback ?? _defaultReadback;

      final retryOutcome = await resolveFn(
        target,
        {...target.resolvedHosts},
        onProgress: onProgress,
        stillWanted: stillWanted,
      );
      if (retryOutcome.cancelled) return const ScanPreflightResult.abandoned();
      if (retryOutcome.ok) {
        final retryTarget =
            _resolvedEntry(target, retryOutcome.host!, readbackFn);
        final retry = await listDir(retryTarget, retryTarget.basePath);
        if (stillWanted?.call() == false) {
          return const ScanPreflightResult.abandoned();
        }
        // The re-resolved host authenticated, so a failure here is that host's
        // own — the same listing classification the first pass keeps. Reporting
        // it as an unreachable host would send the user to retry a connection
        // whose real problem is a rejected password or a timeout.
        if (retry.hasError) {
          return ScanPreflightResult.failed(
            errorKind: retry.errorKind ?? StorageListErrorKind.unreachable,
            errorDetail: retry.errorDetail,
          );
        }
        if (retry.items.isNotEmpty) {
          return ScanPreflightResult.ready(retryTarget);
        }
      } else {
        // Nothing else answered, and the re-resolve says why: an unauthorized
        // one is a credentials problem, not a host that is not there.
        return ScanPreflightResult.failed(
          errorKind: retryOutcome.errorKind ?? StorageListErrorKind.unreachable,
          errorDetail: retryOutcome.errorDetail,
        );
      }
      // Only now is the evidence what it looks like: a host answered, and every
      // candidate the retry could reach listed an empty root. That is still not
      // proof this storage is empty (the cache may point at another machine), so
      // the snapshot stays.
      return const ScanPreflightResult.failed(
        errorKind: StorageListErrorKind.unreachable,
        errorDetail:
            'wildcard root listed empty; no other candidate host answered',
      );
    }
    return ScanPreflightResult.ready(target);
  }

  return ScanPreflightResult.failed(
    errorKind: result.errorKind ?? StorageListErrorKind.unknown,
    errorDetail: result.errorDetail,
  );
}

/// Prefers the persisted entry (the resolver records the resolved host there)
/// and, when the store has not caught up, mirrors what the resolver WOULD have
/// recorded: the pattern stays in `host` and the verified host heads
/// `resolvedHosts`.
///
/// Mirroring instead of pinning the host is what keeps the two paths
/// indistinguishable downstream. A pinned `host` would (a) make
/// [isIPv4WildcardHost] false, so an empty root would be accepted as proof the
/// storage is empty and the scan would purge its snapshot rows, and (b) be
/// ignored anyway, because a listing walks `resolvedHosts` first and would keep
/// dialling the stale cached machine discovery just replaced.
WebDAVStorage _resolvedEntry(
  WebDAVStorage original,
  String host,
  ScanPreflightReadback readback,
) {
  final stored = readback(original.id);
  if (stored is WebDAVStorage) return stored;
  return original.copyWith(
    resolvedHosts: _mergedResolvedHosts(host, original.resolvedHosts),
  );
}

/// Most-recent-first union, capped like the store's own history, so a mirrored
/// entry carries the same shape the persisted one would.
List<String> _mergedResolvedHosts(String host, List<String> current) {
  final merged = <String>[];
  for (final h in [host, ...current]) {
    if (h.isEmpty || merged.contains(h)) continue;
    merged.add(h);
    if (merged.length >= 5) break;
  }
  return merged;
}
