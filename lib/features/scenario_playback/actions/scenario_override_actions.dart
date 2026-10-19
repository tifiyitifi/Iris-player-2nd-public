import 'package:flutter/widgets.dart' show BuildContext;
import 'package:iris/features/media_library/model/enum/basic_enum.dart'
    show SortDirection;
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart'
    show MediaSourceKind;
import 'package:iris/features/media_library/model/enum/media_node.dart'
    show MediaNodeKind;
import 'package:iris/features/meta_settings/engine/browse_scope_snapshot.dart'
    show currentBrowseScopeMediaTypes;
import 'package:iris/features/scenario_playback/actions/scan_play_gate.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_error.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider.dart'
    show PlaybackEntry;
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/utils/path_conv.dart';

/// OVERRIDE-style play actions: they clear the SystemPlaying workspace
/// (sources + explicit items + temporary excludes) and install a brand-new
/// scope, then start playback. Playing a folder/library/multi-selection always
/// OVERRIDES the workspace (E1/D2) — the workspace never accumulates.
class ScenarioOverrideActions {
  const ScenarioOverrideActions._();

  /// Page size used to walk the effective queue while locating the first
  /// available item (v6-D35).
  static const _scanPageSize = 100;

  /// Bounded scan cap when locating the first available item.
  static const _maxScanItems = 10000;

  /// Plays [tapped] with the effective queue being the given folder scope —
  /// the unified click entry for storagedb files-paged AND media-lib content
  /// taps.
  ///
  /// [folderPath] is the tapped item's parent directory (empty = storage
  /// root); [recursive] defaults to false so a click is NOT recursive.
  ///
  /// [sortField]/[sortDirection] are the sort the source view (files-paged /
  /// lib-content) was showing when the user tapped — the queue-generation
  /// rule. They are applied as the live sort AND recorded as
  /// [Scenario.originalSortField] so the queue matches the page order and
  /// "Original" restores it later.
  ///
  /// As a manual scope (E1/F2), the workspace's origin marker is cleared so
  /// Sync-back is disabled and `playResolvedItem` never treats a stale origin
  /// as a direct mirror.
  static Future<void> playFolderScopeInDefaultScenario({
    required String storageId,
    required String folderPath,
    required FileItem tapped,
    String? itemPath,
    bool recursive = false,
    required ScenarioSortField sortField,
    required SortDirection sortDirection,

    /// Skips the inline playability pre-check (v3-D6/D14). The caller has
    /// already shown a No Media confirm dialog. After a forced install, the
    /// tapped file must still exist in `media_nodes` to start playback —
    /// otherwise the scope is installed WITHOUT playing (v4-D11/v6-D37).
    bool force = false,

    /// When non-null, the recursive-scan gate runs for recursive scopes
    /// before the workspace is touched (files-page / storages-list /
    /// lib-tile / lib-content surfaces). Null (or non-recursive) → no gate.
    BuildContext? gateContext,
  }) async {
    final ws = await ensurePlaybackWorkspace();
    // Scan gate: a recursive folder scope whose directory was never fully
    // scanned (or is stale / mid-scan) asks the user first. When the user
    // picks 立即完整扫描, record the pending intent — this override will be
    // resumed (same parameters) once the scan completes, so the tap isn't lost.
    if (recursive && gateContext != null) {
      // gateContext is consumed only inside ensureDirsScannedWithPendingPlay,
      // which guards it with mounted checks before showing any dialog.
      final proceed = await ensureDirsScannedWithPendingPlay(
        // ignore: use_build_context_synchronously
        gateContext,
        [
          (
            storageId: storageId,
            path: folderPath,
            recursive: true,
            kind: ScenarioSourceKind.folder,
          ),
        ],
        playOnScanNow: () => playFolderScopeInDefaultScenario(
          storageId: storageId,
          folderPath: folderPath,
          tapped: tapped,
          itemPath: itemPath,
          recursive: recursive,
          sortField: sortField,
          sortDirection: sortDirection,
          force: false,
        ),
      );
      if (!proceed) return;
    }
    // v15-D6: validate BEFORE mutating — an empty folder scope must not wipe
    // the workspace nor disturb the player.
    if (!force) {
      final result = await DbModule.mediaNodeRepo.getPagedNodesForSources(
        sources: [
          (
            storageId: storageId,
            path: folderPath.isEmpty ? null : folderPath,
            kind: MediaSourceKind.directory,
            recursive: recursive,
            scenarioSourceId: null,
          ),
        ],
        nodeKind: MediaNodeKind.file,
        // Scope-narrowed playability: out-of-scope-only folders must fail
        // the pre-check instead of installing a doomed scope.
        mediaTypes: currentBrowseScopeMediaTypes(),
        page: 0,
        pageSize: 1,
      );
      if (result.totalItems == 0) {
        throw PlaybackUnavailableException.emptyFolder(
          folderPath.isEmpty ? '/' : folderPath,
        );
      }
    }
    await _replaceSources(ws.id, [
      (
        storageId: storageId,
        path: folderPath,
        recursive: recursive,
        kind: ScenarioSourceKind.folder,
      ),
    ]);
    await resetManualScopeOrigin(ws.id);
    await usePlaybackScenarioStore().applyQueueGenerationRule(
      sortField: sortField,
      sortDirection: sortDirection,
    );
    // v6-D1: the workspace scope was replaced — invalidate stale search sessions.
    usePlaybackScenarioStore().bumpWorkspaceOverrideRevision();
    await usePlaybackScenarioStore().bumpPlaybackVersion();
    // An override changes what the active scenario resolves to, so an OPEN
    // queue view must re-fetch its page in place (sourceScanRevision is the
    // designated in-place re-fetch signal; playbackVersion is deliberately
    // ignored by the queue data source to avoid a double-resolve). The edit
    // already changed THIS scenario's definition digest, so it must not
    // invalidate any other scenario's index.
    await usePlaybackScenarioStore().notifyQueueRefetch();
    // v6-D37: with the pre-check skipped, a tapped file that is not in the
    // media DB installs the scope but must not start playback.
    if (force) {
      final node = await DbModule.mediaNodeRepo.getNodeByPath(
        storageId: storageId,
        path: tapped.path,
      );
      if (node == null || !node.isFile) return;
    }
    await playInScenario(
      ws,
      tapped,
      storageId,
      itemPath ?? canonicalOccurrencePath(tapped.path.join('/')),
    );
  }

  /// Plays a multi-selection (files-paged / lib content / search) through the
  /// SystemPlaying workspace, honoring the user-perceived order (D2):
  ///
  /// - selected directories become recursive folder sources, in selection
  ///   order (their contents play first, sorted by the captured sort);
  /// - selected files become explicit items, in selection order;
  /// - the queue's first item plays (first directory's first file, else the
  ///   first selected file).
  ///
  /// [sortField]/[sortDirection] capture the source view's sort at play time.
  static Future<void> playSelectionInDefaultScenario({
    required List<FileItem> files,
    required List<ScenarioSourceSpec> directories,
    required ScenarioSortField sortField,
    required SortDirection sortDirection,

    /// Skips the playability pre-check (v3-D6/D14). The caller has already
    /// shown a No Media confirm dialog. The intended scope is still installed
    /// (v6-D36); an unplayable scope resolves to an empty queue and playback
    /// simply does not start.
    bool force = false,

    /// When non-null, the recursive-scan gate runs for recursive dirs before
    /// the workspace is touched (files-page / storages-list / lib-tile /
    /// lib-content surfaces). Null → no gate.
    BuildContext? gateContext,
  }) async {
    final store = usePlaybackScenarioStore();
    final ws = await ensurePlaybackWorkspace();
    // Scan gate (files-page / storages-list / lib-tile / lib-content only).
    // When the user picks 立即完整扫描, record the pending intent so this
    // override is resumed (same parameters) once the scan completes.
    if (gateContext != null && directories.isNotEmpty) {
      // gateContext is consumed only inside ensureDirsScannedWithPendingPlay,
      // which guards it with mounted checks before showing any dialog.
      final proceed = await ensureDirsScannedWithPendingPlay(
        // ignore: use_build_context_synchronously
        gateContext,
        directories,
        playOnScanNow: () => playSelectionInDefaultScenario(
          files: files,
          directories: directories,
          sortField: sortField,
          sortDirection: sortDirection,
          force: false,
        ),
      );
      if (!proceed) return;
    }
    // v15-D6: validate the prospective scope is playable BEFORE mutating — an
    // empty/unavailable selection must not wipe the workspace nor disturb the
    // player. Throws [PlaybackUnavailableException] when nothing can play.
    if (!force) {
      await _ensurePlayable(files: files, directories: directories);
    }
    await store.clearSources(ws.id);
    await store.clearExplicitItems(ws.id);
    // v5-D7/D30: mirror `_replaceSources` — an override also clears temporary
    // excludes so a forced install never leaks a stale workspace blacklist.
    await store.clearTemporaryExcludes(ws.id);
    await store.addSources(specs: directories);
    await store.addExplicitItemsFor(
      scenarioId: ws.id,
      items: [
        for (final f in files)
          // A SAF single-picked file has no segment path; its identity is its
          // document uri (the resolver resolves it through `nodesByUris`).
          // Filtering on `path.isNotEmpty` alone silently dropped every SAF
          // single pick from the workspace.
          if (f.path.isNotEmpty || f.uri.isNotEmpty)
            (
              storageId: f.storageId,
              path: f.path.isNotEmpty
                  ? canonicalOccurrencePath(f.path.join('/'))
                  : f.uri,
            ),
      ],
    );
    await store.applyQueueGenerationRule(
      sortField: sortField,
      sortDirection: sortDirection,
    );
    await resetManualScopeOrigin(ws.id);
    // v6-D1: the workspace scope was replaced — invalidate stale search sessions.
    store.bumpWorkspaceOverrideRevision();
    await store.bumpPlaybackVersion();
    // See playFolderScopeInDefaultScenario: an open queue view re-fetches in
    // place off sourceScanRevision (never playbackVersion), and the definition
    // edit must not invalidate other scenarios' indexes.
    await store.notifyQueueRefetch();

    // v6-D35: start from the FIRST AVAILABLE item — a missing file-kind
    // explicit or empty-source placeholder (available:false) that sorts first
    // must not abort a partially playable queue.
    final provider = ScenarioPlaybackProvider(store: store);
    var page = 0;
    var scanned = 0;
    while (scanned < _maxScanItems) {
      final result =
          await store.resolvePage(page: page, pageSize: _scanPageSize);
      final items = result.items;
      if (items.isEmpty) return;
      for (final item in items) {
        if (!item.available) continue;
        await provider.play(
          PlaybackEntry(
            file: provider.fileOf(item.media),
            storageId: item.media.storageId,
            path: item.pathValue,
            key: item.mediaKey,
            available: item.available,
            occurrenceIndex: item.occurrenceId.occurrenceIndex,
          ),
        );
        return;
      }
      scanned += items.length;
      page++;
    }
  }

  /// OVERRIDES the SystemPlaying workspace with [files] as explicit items only
  /// and starts playback from the first available one — the "play just these
  /// files" entry shared by the search page (single-item override) and any
  /// future file-list surface. Directories are intentionally not accepted.
  ///
  /// Same semantics as `playSelectionInDefaultScenario(files, directories: [])`.
  static Future<void> playFilesOverride({
    required List<FileItem> files,
    required ScenarioSortField sortField,
    required SortDirection sortDirection,
  }) async {
    if (files.isEmpty) return;
    await playSelectionInDefaultScenario(
      files: files,
      directories: const [],
      sortField: sortField,
      sortDirection: sortDirection,
    );
  }

  /// Installs [specs] as the workspace sources, replacing the previous scope
  /// (E1/D2): sources, explicit items AND temporary excludes are all cleared
  /// so a folder/library play does not leak stale explicit items into the new
  /// queue (mirrors [playSelectionInDefaultScenario]).
  static Future<void> _replaceSources(
    String scenarioId,
    List<ScenarioSourceSpec> specs,
  ) async {
    final store = usePlaybackScenarioStore();
    await store.clearSources(scenarioId);
    await store.clearExplicitItems(scenarioId);
    await store.clearTemporaryExcludes(scenarioId);
    await store.addSources(specs: specs);
  }

  /// v15-D6 playability pre-check: throws [PlaybackUnavailableException] when
  /// the prospective scope has nothing playable, so no override action mutates
  /// the workspace (nor the player) on a doomed request.
  static Future<void> _ensurePlayable({
    List<FileItem> files = const [],
    List<ScenarioSourceSpec> directories = const [],
  }) async {
    // Dirs honor the spec's recursion flag (v2-D1/D8): a non-recursive source
    // whose media only lives in subdirectories must fail the pre-check rather
    // than commit an empty queue.
    for (final dir in directories) {
      final result = await DbModule.mediaNodeRepo.getPagedNodesForSources(
        sources: [
          (
            storageId: dir.storageId,
            path: dir.path.isEmpty ? null : dir.path,
            kind: MediaSourceKind.directory,
            recursive: dir.recursive,
            scenarioSourceId: null,
          ),
        ],
        nodeKind: MediaNodeKind.file,
        // Scope-narrowed playability (see playFolderScopeInDefaultScenario).
        mediaTypes: currentBrowseScopeMediaTypes(),
        page: 0,
        pageSize: 1,
      );
      if (result.totalItems > 0) return;
    }
    // Explicit files: playable when at least one exists in the media DB.
    // A SAF single-picked file has no segment path; its identity is its
    // document uri, which `media_nodes` stores as the canonical path (v51).
    // Mirror the append path here, or a pure-SAF selection collects zero
    // paths and the pre-check throws `search_err_selection_not_in_db`.
    final byStorage = <String, List<String>>{};
    for (final f in files) {
      final p = f.path.isNotEmpty ? f.path.join('/') : f.uri;
      if (p.isEmpty) continue;
      byStorage.putIfAbsent(f.storageId, () => []).add(p);
    }
    for (final entry in byStorage.entries) {
      final existing = await DbModule.mediaNodeRepo.getExistingFilePaths(
        storageId: entry.key,
        paths: entry.value,
      );
      if (existing.isNotEmpty) return;
    }
    throw const PlaybackUnavailableException(
      'search_err_selection_not_in_db',
    );
  }
}
