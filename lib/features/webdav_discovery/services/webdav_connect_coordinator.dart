import 'dart:async';

import 'package:iris/features/webdav_discovery/model/discovery_models.dart';
import 'package:iris/features/webdav_discovery/services/webdav_discovery.dart';
import 'package:iris/features/webdav_discovery/services/webdav_group.dart';
import 'package:iris/models/enums/storage_list_error.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.webdav);

/// How often a give-up is noticed while discovery has nothing to say.
///
/// Only a bound on the wait, never a cost: the poll does no work of its own,
/// and a stream that keeps talking is still cut off at the next event.
const _giveUpPollInterval = Duration(milliseconds: 200);

/// Result of resolving a wildcard WebDAV entry to a concrete host.
///
/// Carries the failure classification (and a raw technical detail) so a caller
/// can explain an unreachable storage instead of silently doing nothing.
class WebDavResolveOutcome {
  const WebDavResolveOutcome({
    this.host,
    this.errorKind,
    this.errorDetail,
    this.cancelled = false,
  });

  final String? host;
  final StorageListErrorKind? errorKind;
  final String? errorDetail;

  /// The caller stopped waiting (see [WebDavConnectCoordinator.resolveDetailed]'s
  /// `stillWanted`). Deliberately distinct from a failure: nothing is known
  /// about the far end, so the caller must neither report one nor navigate.
  final bool cancelled;

  bool get ok => host != null;
}

/// Connects a wildcard WebDAV entry: resolves a concrete host, records it on
/// the entry, and reports the host to open.
class WebDavConnectCoordinator {
  WebDavConnectCoordinator({WebDavDiscovery? discovery})
      : _discovery = discovery ?? WebDavDiscovery();

  final WebDavDiscovery _discovery;

  /// Resolves [storage] to a reachable host, persists it in the entry's
  /// resolution history, and returns it. Null when nothing reachable was found
  /// (e.g. every reachable host is claimed by a sibling entry).
  Future<String?> resolveAndRecord(WebDAVStorage storage) async {
    final store = useStorageStore();
    final outcome = await resolveDetailed(
      storage,
      excludeHosts: claimedBySiblings(storage, store.state.storages),
    );
    return outcome.host;
  }

  /// Re-resolves [storage] while ignoring [excludeHosts].
  ///
  /// Used when a cached host authenticates but serves an EMPTY listing: that
  /// usually means the cache points at a different machine than the intended
  /// one (shared/anonymous credentials + a wide wildcard pattern). Excluding the
  /// current cache forces SSDP and the subnet scan to look elsewhere.
  Future<String?> reResolveExcluding(
    WebDAVStorage storage, {
    required Set<String> excludeHosts,
  }) async {
    final outcome = await resolveDetailed(storage, excludeHosts: excludeHosts);
    return outcome.host;
  }

  /// [resolveAndRecord] with the failure classification kept.
  ///
  /// [onCandidate] receives every host about to be probed, so a caller can
  /// surface live progress instead of an opaque wait (a full subnet scan is
  /// unbounded). [stillWanted] is polled on a timer AND between events:
  /// returning false abandons the run — which cancels the discovery stream and
  /// stops the in-flight probes — and reports
  /// [WebDavResolveOutcome.cancelled] rather than a failure nobody is waiting
  /// for. The timer is what makes that true while discovery is silent, which
  /// it is for whole seconds at a time: the SSDP collection window, a probe
  /// waiting out its timeout, a subnet with nothing to say.
  Future<WebDavResolveOutcome> resolveDetailed(
    WebDAVStorage storage, {
    Set<String> excludeHosts = const <String>{},
    void Function(DiscoveryCandidate candidate)? onCandidate,
    bool Function()? stillWanted,
  }) async {
    final store = useStorageStore();
    final excluded = <String>{
      ...claimedBySiblings(storage, store.state.storages),
      ...excludeHosts,
    };

    StorageListErrorKind? errorKind;
    String? errorDetail;

    final events = StreamIterator<DiscoveryEvent>(
      _discovery.resolve(storage, excludedHosts: excluded),
    );
    var abandoned = false;
    final ticker = stillWanted == null
        ? null
        : Timer.periodic(_giveUpPollInterval, (_) {
            if (!abandoned && stillWanted() == false) {
              abandoned = true;
              // Cancelling is what tells the discovery to stop taking new work.
              unawaited(events.cancel());
            }
          });

    try {
      while (await events.moveNext()) {
        if (abandoned || stillWanted?.call() == false) {
          abandoned = true;
          await events.cancel();
          break;
        }
        final event = events.current;
        if (event is DiscoveryCandidate) {
          onCandidate?.call(event);
          continue;
        }
        if (event is DiscoveryAmbiguous) {
          _log.w(
            'resolve(${storage.id}): ${event.hosts.length} hosts authenticated '
            '${event.hosts}; using ${event.chosen}. Pin a concrete host on the '
            'entry if that is not the intended machine.',
          );
        }
        if (event is DiscoveryAuthRejected) {
          errorKind = StorageListErrorKind.unauthorized;
          errorDetail = 'credentials rejected by ${event.host}';
          continue;
        }
        if (event is DiscoveryExhausted) {
          errorKind ??= StorageListErrorKind.unreachable;
          errorDetail ??= excluded.isEmpty
              ? 'no candidate host answered (host pattern: ${storage.host})'
              : 'no candidate host answered; excluded: ${excluded.join(', ')}';
          continue;
        }
        if (event is DiscoveryVerified) {
          await store.updateWebdavResolvedHosts(storage.id, <String>[event.host]);
          return WebDavResolveOutcome(host: event.host);
        }
      }
    } catch (e) {
      _log.e('resolve(${storage.id}) failed: $e');
      return WebDavResolveOutcome(
        errorKind: StorageListErrorKind.unknown,
        errorDetail: e.toString(),
      );
    } finally {
      ticker?.cancel();
    }

    if (abandoned) return const WebDavResolveOutcome(cancelled: true);
    return WebDavResolveOutcome(errorKind: errorKind, errorDetail: errorDetail);
  }
}

WebDavConnectCoordinator? _instance;

/// Shared coordinator — holds no per-entry state, so a process-wide instance
/// is safe and avoids rebuilding the discovery graph on every tap.
WebDavConnectCoordinator webdavConnectCoordinator() =>
    _instance ??= WebDavConnectCoordinator();
