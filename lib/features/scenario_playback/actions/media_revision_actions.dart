import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/service/vm_membership_pin.dart';

/// Notifies the scenario playback layer that `media_nodes` content changed for
/// the given storages (a recursive scan, or a filesystem→DB directory sync).
///
/// This is the single funnel for the load-bearing contract documented on
/// [PlaybackScenarioStore.bumpSourceScanRevision]: EVERY path that mutates
/// `media_nodes` must announce the storage(s) it changed, otherwise the derived
/// queue index keeps serving a stale generation (missing new files, ghost rows
/// for deleted ones) and an open queue view never re-fetches.
///
/// Bumps BOTH signals the proven scenario-source-refresh path uses:
/// - [PlaybackScenarioStore.bumpPlaybackVersion] → player chrome (prev/next
///   visibility) and the provider's locate cache re-resolve;
/// - [PlaybackScenarioStore.bumpSourceScanRevision] → the derived index
///   signature changes AND [PlaybackScenarioStore.state.sourceScanRevision]
///   drives an in-place re-fetch of an open queue view.
abstract final class MediaRevisionActions {
  const MediaRevisionActions._();

  /// Announces that [storageIds]' media content may have changed. Empty ids are
  /// ignored; a fully empty set is a no-op (nothing to invalidate).
  ///
  /// [preserveVirtualMediaBoundaries] must be true when the caller is the
  /// targeted desktop physical-delete path: it removes one `media_nodes` row
  /// but deliberately keeps the session's VM boundary freeze so a neighbouring
  /// chunk is not re-derived into the deleted file's chunk. Every other
  /// (bulk/scan) caller leaves it false — a source update is one of the four
  /// legitimate re-group triggers and drops the freeze.
  static Future<void> mediaNodesChanged(
    Iterable<String> storageIds, {
    bool preserveVirtualMediaBoundaries = false,
  }) async {
    final ids = storageIds.where((e) => e.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    if (!preserveVirtualMediaBoundaries) VmMembershipPin.instance.clear();
    final store = usePlaybackScenarioStore();
    await store.bumpPlaybackVersion();
    await store.bumpSourceScanRevision(storages: ids);
  }
}
