import 'dart:convert';
import 'dart:math';

import 'package:iris/store/kv/use_kv_store.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart'
    show clampPageSize;
import 'package:iris/features/scenario_playback/commands/scenario_commands.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_explicit_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_sort_spec.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_state.dart';
import 'package:iris/features/scenario_playback/model/enum/duplicate_policy.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_list_sort_by.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_manage_sort_by.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/store/playback_scenario_store_state.dart';
import 'package:iris/features/scenario_playback/logging/scenario_log_keys.dart';
import 'package:iris/features/virtual_media/service/vm_membership_pin.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/store/persistent_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final areaKeyLog = AreaKeyLog(ScenarioLogKeys.store);

/// Manages Scenarios and the active scenario selection.
///
/// The store is a thin coordinator over [ScenarioRepository] and
/// [ScenarioResolver]. Per-scenario playback state (current item, shuffle,
/// repeat, sort) lives in the media database, not in this in-memory state.
class PlaybackScenarioStore
    extends PersistentStore<PlaybackScenarioStoreState> {
  static const _activeScenarioKey = 'playback_scenario_active_id';

  PlaybackScenarioStore() : super(PlaybackScenarioStoreState());

  ScenarioRepository get _repo => DbModule.scenarioRepo;

  late final ScenarioResolver _resolver = ScenarioResolver(
    repo: _repo,
    nodeRepo: DbModule.mediaNodeRepo,
    queueIndexDao: DbModule.scenarioQueueIndexDao,
    mediaOrderDao: DbModule.mediaOrderDao,
    sharedIndexDao: DbModule.scenarioSharedIndexDao,
    // ONE revision source for the shared orders: the same scoped revision the
    // index signature keys on, so an order and its bitmaps can never disagree.
    mediaRevisionProvider: _mediaScopeRevision,
    // Tag membership as node ids, for the shared tag read (the resolver has no
    // tag repository). Without it a tag read declines and its callers keep their
    // own walk.
    tagMemberNodeIds: (tagId, addedAfter) =>
        DbModule.videoTagMembersDao.memberNodeIds(tagId,
            addedAfter: addedAfter),
    tagMembersByTag: (addedAfter) =>
        DbModule.videoTagMembersDao.memberNodeIdsByTag(addedAfter: addedAfter),
  );

  ScenarioResolver get resolver => _resolver;

  /// Scenarios whose derived queue index has been built this process lifetime,
  /// mapped to the content [signature] the build reflects. Any content change
  /// (definition rows, a media rescan, a VM rule edit) changes the signature, so
  /// the next read rebuilds automatically — switching scenarios does not.
  final Map<String, ({int buildId, String signature})> _queueIndexBuilds = {};

  /// Builds in flight, so concurrent readers of the same scenario share ONE
  /// rebuild instead of each walking the library. Every read path (page fetch,
  /// locate, single-item seek) funnels through [ensureQueueIndex].
  final Map<String, ({String signature, Future<int> build})>
      _queueIndexBuildsInFlight = {};

  /// Meta keys for cross-restart index bookkeeping (see [AppMetaDao]).
  static const _kMediaContentRevision = 'media_content_revision';

  /// Per-storage media revision. A rescan bumps only the storages it actually
  /// touched, so a scenario whose sources live elsewhere is not invalidated.
  static const _kMediaScopeRevisionPrefix = 'media_rev:scope:';

  static String _indexSigKey(String scenarioId) =>
      ScenarioQueueIndexDao.signatureKey(scenarioId);

  static String _indexUsedKey(String scenarioId) =>
      ScenarioQueueIndexDao.usedKey(scenarioId);

  /// In-memory cache of the media revisions the index signature keys on, so a
  /// page fetch does not read `app_meta` once per storage. Kept in sync by
  /// [bumpSourceScanRevision]; a fresh process fills it lazily.
  final Map<String, int> _mediaScopeRev = {};
  int _mediaGlobalRev = 0;
  bool _mediaRevLoaded = false;

  Future<int> _mediaGlobalRevision() async {
    if (!_mediaRevLoaded) {
      _mediaGlobalRev = int.tryParse(
              await DbModule.appMetaDao.read(_kMediaContentRevision) ?? '') ??
          0;
      _mediaRevLoaded = true;
    }
    return _mediaGlobalRev;
  }

  Future<int> _mediaScopeRevision(String storageId) async {
    final cached = _mediaScopeRev[storageId];
    if (cached != null) return cached;
    final rev = int.tryParse(
            await DbModule.appMetaDao
                    .read('$_kMediaScopeRevisionPrefix$storageId') ??
                '') ??
        0;
    _mediaScopeRev[storageId] = rev;
    return rev;
  }

  /// How many materialized generations are kept on disk at once.
  ///
  /// Derived storage is `#materialized × per-scenario`, so with whole-library
  /// sources a user with hundreds of scenarios would otherwise accumulate one
  /// full copy each. Keeping only the most-recently-used few bounds the total;
  /// an evicted scenario rebuilds lazily the next time it is opened.
  static const int kQueueIndexRetention = 8;

  /// In-memory most-recently-resolved scenario ids (most recent first), capped
  /// at [kQueueIndexRetention]. Protects what the UI is actually viewing — the
  /// queue can page a NON-active scenario (`resolvePageFor`), so protecting
  /// only [state.activeScenarioId] would evict the visible one and force a
  /// whole-library rebuild on the UI isolate.
  final List<String> _recentIndexUse = [];

  void _touchRecentIndexUse(String scenarioId) {
    _recentIndexUse
      ..remove(scenarioId)
      ..insert(0, scenarioId);
    if (_recentIndexUse.length > kQueueIndexRetention) {
      _recentIndexUse.removeRange(kQueueIndexRetention, _recentIndexUse.length);
    }
  }

  /// Stamps [scenarioId] as recently used (best-effort, best-value LRU key).
  Future<void> _recordIndexUse(String scenarioId) async {
    _touchRecentIndexUse(scenarioId);
    try {
      await DbModule.appMetaDao.write(
        _indexUsedKey(scenarioId),
        '${DateTime.now().millisecondsSinceEpoch}',
      );
    } catch (_) {
      // Best-effort: a missing stamp only makes the scenario look older.
    }
  }

  /// Evicts the least-recently-used materialized generations beyond
  /// [kQueueIndexRetention]. Runs after a build/reuse, never on the read hot
  /// path. Recency is the in-memory view order first (covers this session's
  /// reads), then the persisted stamp (covers earlier sessions).
  Future<void> _enforceIndexRetention() async {
    try {
      final ids = await DbModule.scenarioQueueIndexDao.materializedScenarioIds();
      if (ids.length <= kQueueIndexRetention) return;
      final used = <String, int>{};
      for (final id in ids) {
        used[id] = int.tryParse(
                await DbModule.appMetaDao.read(_indexUsedKey(id)) ?? '') ??
            0;
      }
      int memRank(String id) {
        final r = _recentIndexUse.indexOf(id);
        return r < 0 ? 1 << 30 : r;
      }

      ids.sort((a, b) {
        final ra = memRank(a), rb = memRank(b);
        if (ra != rb) return ra.compareTo(rb);
        return (used[b] ?? 0).compareTo(used[a] ?? 0);
      });
      final keep = <String>{
        ...ids.take(kQueueIndexRetention),
        if (state.activeScenarioId != null) state.activeScenarioId!,
      };
      for (final id in ids) {
        if (keep.contains(id)) continue;
        // clearScenario also drops the app_meta bookkeeping keys.
        await DbModule.scenarioQueueIndexDao.clearScenario(id);
        _queueIndexBuilds.remove(id);
        _queueIndexBuildsInFlight.remove(id);
        _recentIndexUse.remove(id);
      }
      await DbModule.scenarioSharedIndexDao.gcStaleGenerations();
    } catch (_) {
      // Best-effort: failing to evict only costs disk, never correctness.
    }
  }

  /// Signature of the content a build reflects, used for IN-SESSION comparison.
  /// The persistent parts (scenario definition rows, enabled VM rules, the
  /// media revisions) let a fresh process match the stored generation; the
  /// session-relative VM revision is stripped before persisting (see
  /// [_persistableSignature]) so a restart does not force a rebuild.
  Future<String> _indexSignature(String scenarioId) async {
    // The digest already reads the source/item rows, so it hands back the
    // storages they reference — the read hot path must not query them again.
    final definition =
        await _resolver.definitionSignatureWithStorages(scenarioId);
    var mediaRev = 0;
    final parts = <String>[];
    try {
      mediaRev = await _mediaGlobalRevision();
      final ids = definition.storages.toList()..sort();
      for (final id in ids) {
        parts.add('$id=${await _mediaScopeRevision(id)}');
      }
    } catch (_) {
      // Meta unavailable (test env without DbModule): the definition digest
      // alone still detects the common edits.
    }
    return '${definition.signature}|media:$mediaRev|scopes:${parts.join(',')}'
        '|vmrev:${VirtualMediaService.instance.revision}';
  }

  /// Drops the session-relative tail of [_indexSignature] before it is stored,
  /// so the persisted value is comparable after a restart (where the in-memory
  /// VM revision is 0 again).
  String _persistableSignature(String signature) {
    final i = signature.indexOf('|vmrev:');
    return i < 0 ? signature : signature.substring(0, i);
  }

  /// Reuses the persisted generation when its stored signature matches the
  /// persistable part of [signature] (cold-start fast path). Returns 0 when
  /// there is nothing to reuse, so the caller builds.
  Future<int> _reusePersistedIndex(String scenarioId, String signature) async {
    try {
      final persisted =
          await DbModule.appMetaDao.read(_indexSigKey(scenarioId));
      if (persisted != _persistableSignature(signature)) return 0;
      final buildId =
          await DbModule.scenarioQueueIndexDao.currentBuildId(scenarioId);
      if (buildId <= 0) return 0;
      _queueIndexBuilds[scenarioId] = (buildId: buildId, signature: signature);
      await _recordIndexUse(scenarioId);
      // Cold-start reuse is a good moment to converge on the retention cap.
      await _enforceIndexRetention();
      return buildId;
    } catch (_) {
      return 0;
    }
  }

  /// Trigger point (a): ensures [scenarioId]'s persisted derived index is
  /// current before the first page fetch, rebuilding it only when its content
  /// signature changed. Returns the build id in effect, or 0 when indexing is
  /// unavailable.
  Future<int> ensureQueueIndex(String scenarioId) async {
    // Mark what the UI is viewing even on the in-memory fast path, so the
    // retention pass never evicts the scenario being paged (it need not be the
    // active one). In-memory only — no DB write on the read path.
    _touchRecentIndexUse(scenarioId);
    final signature = await _indexSignature(scenarioId);
    final existing = _queueIndexBuilds[scenarioId];
    if (existing != null &&
        existing.buildId > 0 &&
        existing.signature == signature) {
      return existing.buildId;
    }
    // Cold start: the in-memory map is empty, but the persisted generation may
    // still be current — reuse it instead of re-walking the library.
    if (existing == null) {
      final reused = await _reusePersistedIndex(scenarioId, signature);
      if (reused > 0) return reused;
    }
    final inFlight = _queueIndexBuildsInFlight[scenarioId];
    if (inFlight != null && inFlight.signature == signature) {
      return inFlight.build;
    }
    final Future<int> build;
    build = _resolver.buildQueueIndex(scenarioId).then((id) async {
      _queueIndexBuilds[scenarioId] = (buildId: id, signature: signature);
      if (id > 0) {
        try {
          await DbModule.appMetaDao.write(
              _indexSigKey(scenarioId), _persistableSignature(signature));
          await _recordIndexUse(scenarioId);
        } catch (_) {
          // Persisting the signature is best-effort: a failure only costs one
          // rebuild on the next cold start.
        }
        await _enforceIndexRetention();
      }
      return id;
    });
    _queueIndexBuildsInFlight[scenarioId] =
        (signature: signature, build: build);
    build.whenComplete(() {
      if (identical(_queueIndexBuildsInFlight[scenarioId]?.build, build)) {
        _queueIndexBuildsInFlight.remove(scenarioId);
      }
    });
    return build;
  }

  /// Index-backed single-item read for the active scenario (O(1)-ish seek).
  /// Returns null when the index is unavailable, so the caller falls back.
  Future<EffectivePlaybackItem?> resolveItemAtIndex(int ordinal) async {
    final id = state.activeScenarioId;
    if (id == null) return null;
    // Keep the persisted index current with the definition (rebuilds on a
    // version bump), so a locate/hint never reads a stale generation.
    final buildId = await ensureQueueIndex(id);
    if (buildId <= 0) return null;
    return _resolver.resolveItemAtIndex(id, ordinal);
  }

  /// Index-backed total (`totalItems` = base file count) for the active
  /// scenario, or null when the index is unavailable.
  ///
  /// Ensures the derived index is current FIRST (same as [_resolveTotal]): the
  /// in-memory `_queueIndexBuilds` entry is only refreshed by [ensureQueueIndex],
  /// so reading it directly would serve the PRE-edit count whenever a caller
  /// resolves right after a definition change and before any other read
  /// refreshed the index — the player chrome then lagged one change behind.
  Future<int?> indexedTotalCount() async {
    final id = state.activeScenarioId;
    if (id == null) return null;
    final buildId = await ensureQueueIndex(id);
    if (buildId <= 0) return null;
    return _resolver.indexedTotalCount(buildId);
  }

  /// In-memory monotonic revision of the SystemPlaying workspace's DEFINITION
  /// (v6-D1): bumped only when the workspace scope is replaced (an override) —
  /// never by append / active-scenario switch / save commands. A parked search
  /// session records this value at creation and is considered stale on resume
  /// when it no longer matches (see `MediaSearchDataSource.isStaleByWorkspaceOverride`).
  int _workspaceOverrideRevision = 0;

  int get workspaceOverrideRevision => _workspaceOverrideRevision;

  void bumpWorkspaceOverrideRevision() {
    _workspaceOverrideRevision++;
  }

  /// v6-D34: stay-mode flag for the storagedb popup. In-memory only (default
  /// false = close on play) so no schema/freezed/build_runner change is needed
  /// (NFR-003). Independent from the preview's persisted
  /// `scenarioPreviewStayOnTap`.
  bool _storagesDbStayOnPlay = false;

  bool get storagesDbStayOnPlay => _storagesDbStayOnPlay;

  void setStoragesDbStayOnPlay(bool value) {
    _storagesDbStayOnPlay = value;
  }

  Scenario? get activeScenario {
    final id = state.activeScenarioId;
    if (id == null) return null;
    for (final c in state.scenarios) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The single SystemPlaying workspace row, if loaded.
  Scenario? get systemPlayingScenario {
    for (final c in state.scenarios) {
      if (c.type == ScenarioKind.systemPlaying) return c;
    }
    return null;
  }

  // ── Lifecycle ──

  /// Completion of the initial [refreshScenarios] started by [onReady].
  /// Null only in the window before `_init` reaches [onReady].
  Future<void>? _scenariosReady;

  @override
  void onReady() {
    _scenariosReady = refreshScenarios();
  }

  /// Completes when the scenario list AND the active selection are resolved.
  ///
  /// [initialized] does NOT cover [onReady]'s refresh: the base class
  /// completes the completer BEFORE calling onReady, so awaiting only
  /// `initialized` races the activeScenarioId restore and cold-start resume
  /// dies with "No active PlaybackScenario selected" on slow IO. Every
  /// startup consumer of the active selection must await this instead.
  Future<void> ensureReady() async {
    await initialized;
    await _scenariosReady;
  }

  /// Loads all scenarios and restores the active selection.
  Future<void> refreshScenarios() async {
    final raw = await _repo.getAllScenarios();
    final scenarios = _sortScenarios(raw);

    String? active = state.activeScenarioId;
    if (active == null || !scenarios.any((c) => c.id == active)) {
      active = await _pickInitialActiveScenario();
    }

    set(state.copyWith(
        scenarios: scenarios, activeScenarioId: active, isLoading: false));
    await _syncActiveScenarioShuffled();
  }

  /// Sorts the scenario list for the Playback Scenario tab.
  List<Scenario> _sortScenarios(List<Scenario> scenarios) {
    final sorted = [...scenarios];

    int cmpDate(DateTime? a, DateTime? b) {
      final av = a ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bv = b ?? DateTime.fromMillisecondsSinceEpoch(0);
      return av.compareTo(bv);
    }

    int compare(Scenario a, Scenario b) {
      switch (state.scenarioSortBy) {
        case ScenarioListSortBy.name:
          return a.name.compareTo(b.name);
        case ScenarioListSortBy.createdAt:
          return cmpDate(a.createdAt, b.createdAt);
        case ScenarioListSortBy.updatedAt:
          return cmpDate(a.updatedAt, b.updatedAt);
      }
    }

    sorted.sort((a, b) {
      final result = compare(a, b);
      return state.scenarioSortDirection == SortDirection.asc
          ? result
          : -result;
    });

    // The SystemPlaying scenario always stays on top.
    sorted.sort((a, b) =>
        (b.type == ScenarioKind.systemPlaying ? 1 : 0) -
        (a.type == ScenarioKind.systemPlaying ? 1 : 0));
    return sorted;
  }

  Future<void> updateScenarioSort(
    ScenarioListSortBy sortBy,
    SortDirection sortDirection,
  ) async {
    set(state.copyWith(
        scenarioSortBy: sortBy, scenarioSortDirection: sortDirection));
    await refreshScenarios();
  }

  /// Sets the global manage-list container-first preference (D7): when true
  /// the Sources (Manage) list groups entries by their container (directory /
  /// storage) before sorting by name. Persisted via the store's secure-storage
  /// load/save; does NOT touch the database (no refreshScenarios).
  Future<void> setManageContainerFirst(bool value) async {
    set(state.copyWith(manageContainerFirst: value));
    await save(state);
  }

  /// Sets the global manage-list sort field and direction (D3/D5). Persisted
  /// via secure storage; does NOT touch the database.
  Future<void> setManageSort(
    ScenarioManageSortBy field,
    SortDirection direction,
  ) async {
    set(state.copyWith(manageSortBy: field, manageSortDirection: direction));
    await save(state);
  }

  /// Sets the global manage-list 组内排序 preference (D7): when true the list
  /// sorts within the Filter group order (group order is primary); when false
  /// the selected field sorts the whole list globally. Persisted via secure
  /// storage; does NOT touch the database.
  Future<void> setManageSortWithinGroup(bool value) async {
    set(state.copyWith(manageSortWithinGroup: value));
    await save(state);
  }

  /// Sets the playing-scenario queue pagination page size. Persisted via
  /// secure storage; does NOT touch the database.
  Future<void> updatePlayingScenarioQueuePageSize(int value) async {
    set(state.copyWith(playingScenarioQueuePageSize: value));
    await save(state);
  }

  /// Sets the Scenario preview pagination page size. Persisted via secure
  /// storage; does NOT touch the database.
  Future<void> updateScenarioPreviewQueuePageSize(int value) async {
    set(state.copyWith(scenarioPreviewQueuePageSize: value));
    await save(state);
  }

  /// Sets the Scenario preview stay-on-tap flag. Persisted via secure
  /// storage; does NOT touch the database.
  Future<void> updateScenarioPreviewStayOnTap(bool value) async {
    set(state.copyWith(scenarioPreviewStayOnTap: value));
    await save(state);
  }

  /// Sets the Sources (Manage) / browse pagination page size. Persisted via
  /// secure storage; does NOT touch the database.
  Future<void> updateScenarioManagePageSize(int value) async {
    set(state.copyWith(scenarioManagePageSize: value));
    await save(state);
  }

  Future<String?> _pickInitialActiveScenario() async {
    final scenarios = await _repo.getAllScenarios();
    if (scenarios.isEmpty) return null;

    // Prefer the SystemPlaying scenario.
    final system = scenarios.where((c) => c.type == ScenarioKind.systemPlaying);
    if (system.isNotEmpty) return system.first.id;

    // Otherwise fall back to the most recently active SAVED scenario — the
    // unified workspace is an internal context and is never auto-selected.
    final withTimes = <(String, DateTime?)>[];
    for (final c in scenarios) {
      if (c.type != ScenarioKind.userSaved) continue;
      final s = await _repo.getState(c.id);
      withTimes.add((c.id, s?.lastActiveAt));
    }
    withTimes.sort((a, b) {
      final at = a.$2 ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.$2 ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    });
    return withTimes.first.$1;
  }

  // ── Scenario CRUD ──

  Future<Scenario> createScenario(String name) async {
    final scenario = await _repo.createScenario(name: name);
    set(state.copyWith(
      scenarios: [...state.scenarios, scenario],
      activeScenarioId: scenario.id,
    ));
    await _repo.touchState(scenario.id);
    await refreshScenarios();
    return scenario;
  }

  /// Auto-generates a batch of scenarios from a name pattern.
  Future<List<Scenario>> createScenarioBatch({
    required String pattern,
    required int count,
    required int startIndex,
    int maxCount = 1000,
  }) async {
    final safeCount = count.clamp(1, maxCount);
    final maxIndex = startIndex + safeCount - 1;
    final padWidth = maxIndex.toString().length;

    final created = <Scenario>[];
    for (int offset = 0; offset < safeCount; offset++) {
      final index = startIndex + offset;
      final paddedIndex = index.toString().padLeft(padWidth, '0');
      final name = pattern.contains('{index}')
          ? pattern.replaceAll('{index}', paddedIndex)
          : '$pattern $paddedIndex';
      created.add(await _repo.createScenario(name: name));
    }

    await refreshScenarios();
    return created;
  }

  Future<void> renameScenario(String id, String name) async {
    await _repo.renameScenario(id, name);
    await refreshScenarios();
  }

  Future<void> deleteScenario(String id) async {
    final deleted = await _repo.deleteScenario(id);
    if (!deleted) return;
    // _repo.deleteScenario -> indexDao.clearScenario also drops the app_meta
    // bookkeeping keys; here we only drop this store's in-memory state.
    _queueIndexBuilds.remove(id);
    _queueIndexBuildsInFlight.remove(id);
    _recentIndexUse.remove(id);
    if (state.activeScenarioId == id) {
      final system = await _repo.getSystemPlayingScenario();
      set(state.copyWith(activeScenarioId: system?.id));
    }
    await refreshScenarios();
  }

  Future<void> setActiveScenario(String id) async {
    // Switching scenarios changes which member set each VM rule sees, so a
    // delete-time boundary freeze seeded from the PREVIOUS scenario's stream is
    // stale: applying it would strip/misgroup the new scenario's VM rows. A
    // scenario switch is therefore a legitimate re-group trigger.
    VmMembershipPin.instance.clear();
    // Switching scenarios changes no scenario's CONTENT, so the derived index
    // stays valid: an A→B→A switch must not rebuild A.
    set(state.copyWith(activeScenarioId: id));
    await _repo.touchState(id);
    await _syncActiveScenarioShuffled();
    await _recordIndexUse(id);
  }

  /// Bumps the playback revision so listeners re-resolve the effective queue
  /// (e.g. after source/exclude mutations made outside this store).
  Future<void> bumpPlaybackVersion() async {
    set(state.copyWith(playbackVersion: state.playbackVersion + 1));
  }

  /// Bumps the media-snapshot revision after a [ScenarioSourceRefreshService]
  /// scan run. Unlike [bumpPlaybackVersion] this is NOT paired with an explicit
  /// `fetchPage` by the mutating call site, so an open queue's listener owns
  /// the single in-place re-fetch.
  ///
  /// [storages] scopes the persisted invalidation to the storages the scan
  /// actually touched. Omit it when the change cannot be attributed to specific
  /// storages — that conservatively invalidates every scenario (the old
  /// behaviour).
  ///
  /// CONTRACT (implicit, load-bearing): the derived index is only correct if
  /// EVERY path that mutates `media_nodes` (scan, rename, delete, duration
  /// heal, import…) calls this with the scope it changed. Passing `null` is
  /// always safe (it invalidates everything); passing a wrong/short scope
  /// leaves stale scenarios. Today only [ScenarioSourceRefreshService] knows
  /// the storages, so it is the only caller that passes them; new media-mutating
  /// paths must either pass their scope or accept the global bump.
  Future<void> bumpSourceScanRevision({Iterable<String>? storages}) async {
    set(state.copyWith(sourceScanRevision: state.sourceScanRevision + 1));
    // Persist a monotonic content revision so the derived-index signature stays
    // comparable across restarts (the in-memory counter resets to 0), and keep
    // the read-path cache in sync in the same step.
    try {
      final ids = storages?.where((e) => e.isNotEmpty).toSet();
      if (ids == null || ids.isEmpty) {
        _mediaGlobalRev =
            await DbModule.appMetaDao.increment(_kMediaContentRevision);
        _mediaRevLoaded = true;
      } else {
        for (final id in ids) {
          _mediaScopeRev[id] = await DbModule.appMetaDao
              .increment('$_kMediaScopeRevisionPrefix$id');
        }
      }
    } catch (_) {
      // Best-effort: a failure only costs one rebuild on the next cold start.
      // Drop the cache so the next read re-loads from disk.
      _mediaRevLoaded = false;
      _mediaScopeRev.clear();
    }
  }

  /// Signals an OPEN queue view to re-fetch in place WITHOUT invalidating any
  /// persisted generation. Definition edits (append / override) already change
  /// the edited scenario's own definition digest, so routing them through the
  /// media revision would needlessly rebuild every OTHER scenario too.
  Future<void> notifyQueueRefetch() async {
    set(state.copyWith(sourceScanRevision: state.sourceScanRevision + 1));
  }

  /// Signals that the ACTIVE scenario's definition changed so EVERY playback
  /// surface re-resolves: the player chrome (prev/next visibility, bar title)
  /// off [bumpPlaybackVersion], and open queue lists off [notifyQueueRefetch].
  ///
  /// Definition edits made from surfaces OTHER than the queue (the Sources /
  /// Manage "Remove", the Browse add/exclude actions) used to bump neither
  /// signal, so the player chrome kept a stale prev/next visibility while an
  /// open/re-opened queue list moved on — until a full rebuild (rotation).
  ///
  /// Batch callers must invoke this ONCE after their loop, never per item.
  /// Callers that may have removed the current item additionally re-validate it
  /// (the store cannot: `ScenarioPlaybackProvider` depends on this store).
  Future<void> notifyDefinitionChanged() async {
    await bumpPlaybackVersion();
    await notifyQueueRefetch();
  }

  /// Mirrors the active scenario's shuffle/repeat flags into the in-memory
  /// state so the player buttons can render synchronously.
  Future<void> _syncActiveScenarioShuffled() async {
    final id = state.activeScenarioId;
    if (id == null) return;
    final scenario = await _repo.getScenario(id);
    set(state.copyWith(
      activeScenarioShuffled: scenario?.order == PlaybackOrder.shuffled,
      activeScenarioRepeat: scenario?.repeatMode ?? Repeat.none,
    ));
  }

  // ── Active scenario playback state (DB-backed) ──

  Future<ScenarioState?> activeState() async {
    final id = _requireActiveId();
    return _repo.getState(id);
  }

  /// Recovers the current playing item by its [PlaybackOccurrenceId] (C7/D4).
  Future<EffectivePlaybackItem?> getCurrentItem() =>
      currentItemFor(_requireActiveId());

  /// Recovers [scenarioId]'s OWN current playing item by its persisted
  /// occurrence. Unlike [getCurrentItem] this is not tied to the active
  /// workspace, so a view of another scenario resolves that scenario's own
  /// position instead of reporting the active one's (the "open another queue
  /// and it scrolls to the wrong row" bug).
  Future<EffectivePlaybackItem?> currentItemFor(String scenarioId) async {
    // Keep the derived index current so the recovery below is index-backed.
    await ensureQueueIndex(scenarioId);
    final s = await _repo.getState(scenarioId);
    final occurrence = s?.currentPlaybackOccurrence;
    if (occurrence == null) return null;
    // CLOSE_DEBUG_LOG
    areaKeyLog.d(
        'currentItemFor scenario=$scenarioId persisted=${occurrence.occurrenceKey}');
    final resolved = await _resolver.resolveItemByOccurrenceFor(
      scenarioId: scenarioId,
      occurrence: occurrence,
    );
    // CLOSE_DEBUG_LOG
    areaKeyLog.d(
        'currentItemFor resolved=${resolved?.occurrenceId.occurrenceKey}');
    return resolved;
  }

  /// Recovers [occurrence] within [scenarioId] for any entry point (queue,
  /// search, browse, sources). Keeps the persisted index current first, so the
  /// recovery is index-backed instead of an O(N) walk; the resolver falls back
  /// internally when the index is unavailable.
  Future<EffectivePlaybackItem?> resolveItemByOccurrence({
    required String scenarioId,
    required PlaybackOccurrenceId occurrence,
  }) async {
    await ensureQueueIndex(scenarioId);
    return _resolver.resolveItemByOccurrenceFor(
      scenarioId: scenarioId,
      occurrence: occurrence,
    );
  }

  Future<void> setCurrentItem({
    required PlaybackOccurrenceId occurrence,
    int? virtualPos,
  }) async {
    final id = _requireActiveId();
    // CLOSE_DEBUG_LOG
    areaKeyLog.d(
        'setCurrentItem active=$id key=${occurrence.occurrenceKey} virtualPos=$virtualPos prevMirror=${state.currentOccurrenceKey}');
    final s = await _repo.getState(id);
    await _repo.updateState(
      (s ?? ScenarioState(scenarioId: id)).copyWith(
        currentPlaybackOccurrence: occurrence,
        currentVirtualPos: virtualPos,
        lastActiveAt: DateTime.now(),
      ),
    );
    // Mirror into the in-memory state so queue views can reactively highlight
    // the playing occurrence on play/next/previous. The key is canonicalized
    // so the highlight matches regardless of the producer's slash convention.
    set(state.copyWith(
      currentOccurrenceKey: canonicalOccurrenceKey(
        occurrence.storageId,
        occurrence.path,
        occurrence.occurrenceIndex,
      ),
    ));
    // CLOSE_DEBUG_LOG
    areaKeyLog.d('setCurrentItem mirror=${state.currentOccurrenceKey}');
  }

  Future<void> toggleShuffle() async {
    final id = _requireActiveId();
    final scenario = await _repo.getScenario(id);
    final s = await _repo.getState(id);

    if (scenario?.order == PlaybackOrder.shuffled) {
      await _repo
          .updateScenario(scenario!.copyWith(order: PlaybackOrder.sequential));
      await _repo.updateState(
        (s ?? ScenarioState(scenarioId: id)).copyWith(shuffleSeed: null),
      );
      await refreshScenarios();
      return;
    }

    final total = await _resolveTotal(id);
    final seed = Random().nextInt(1 << 30);
    await _repo.updateScenario(
      (scenario ?? Scenario(id: id, name: ''))
          .copyWith(order: PlaybackOrder.shuffled, sortDirection: SortDirection.asc),
    );
    await _repo.updateState(
      (s ?? ScenarioState(scenarioId: id)).copyWith(
        shuffleSeed: seed,
        shuffleVersion: (s?.shuffleVersion ?? 0) + 1,
        shuffleItemCount: total,
      ),
    );
    await refreshScenarios();
  }

  /// Flips the shuffle direction while shuffled (asc = forward permutation,
  /// desc = reversed permutation). No-op when shuffle is off.
  Future<void> toggleShuffleDirection() async {
    final id = _requireActiveId();
    final scenario = await _repo.getScenario(id);
    if (scenario?.order != PlaybackOrder.shuffled) return;
    await _repo.updateScenario(
      scenario!.copyWith(
        sortDirection: scenario.sortDirection == SortDirection.asc
            ? SortDirection.desc
            : SortDirection.asc,
      ),
    );
    await refreshScenarios();
  }

  /// Refreshes the shuffled order: if shuffle is off, enables it first; then
  /// regenerates with a fresh seed. Used by the queue's "shuffle refresh".
  Future<void> shuffleRefresh() async {
    final id = _requireActiveId();
    final scenario = await _repo.getScenario(id);
    final s = await _repo.getState(id);
    final total = await _resolveTotal(id);
    await _repo.updateScenario(
      (scenario ?? Scenario(id: id, name: ''))
          .copyWith(order: PlaybackOrder.shuffled),
    );
    await _repo.updateState(
      (s ?? ScenarioState(scenarioId: id)).copyWith(
        shuffleSeed: Random().nextInt(1 << 30),
        shuffleVersion: (s?.shuffleVersion ?? 0) + 1,
        shuffleItemCount: total,
      ),
    );
    await refreshScenarios();
  }

  Future<void> setRepeat(Repeat repeat) async {
    final id = _requireActiveId();
    final scenario = await _repo.getScenario(id);
    await _repo.updateScenario(
      (scenario ?? Scenario(id: id, name: '')).copyWith(repeatMode: repeat),
    );
    await refreshScenarios();
  }

  Future<void> setSort(
    ScenarioSortField field,
    SortDirection direction,
  ) async {
    final id = _requireActiveId();
    final scenario = await _repo.getScenario(id);
    await _repo.updateScenario(
      (scenario ?? Scenario(id: id, name: ''))
          .copyWith(sortField: field, sortDirection: direction),
    );
    await refreshScenarios();
    // Order-affecting definition change: signal re-resolution (and derived
    // index rebuild) like the other definition mutations.
    await bumpPlaybackVersion();
  }

  /// Applies a queue-generation rule captured from a source view (files-paged
  /// / lib content): sets the live sort, switches to sequential and records the
  /// rule as [Scenario.originalSortField] so the order menu's "Original" can
  /// restore it. Called on override-style population (folder/lib/multi-select
  /// replace), never on append.
  Future<void> applyQueueGenerationRule({
    required ScenarioSortField sortField,
    required SortDirection sortDirection,
  }) async {
    final id = _requireActiveId();
    final scenario = await _repo.getScenario(id);
    final s = await _repo.getState(id);
    await _repo.updateScenario(
      (scenario ?? Scenario(id: id, name: '')).copyWith(
        sortField: sortField,
        sortDirection: sortDirection,
        order: PlaybackOrder.sequential,
        originalSortField: sortField,
      ),
    );
    await _repo.updateState(
      (s ?? ScenarioState(scenarioId: id)).copyWith(shuffleSeed: null),
    );
    await refreshScenarios();
  }

  /// Applies the preview's sort view [spec] to the [scenarioId] workspace ONLY
  /// when it differs from the workspace's current Definition + state
  /// (dirty-check). Returns true when a write happened; false when the spec
  /// equals the current sort view (zero write — `originalSortField`, the
  /// shuffle seed and version stay untouched).
  Future<bool> applyPreviewSortConfig(
    String scenarioId,
    ScenarioSortSpec spec,
  ) async {
    final scenario = await _repo.getScenario(scenarioId);
    if (scenario == null) return false;
    final state = await _repo.getState(scenarioId);
    final current = ScenarioSortSpec.fromScenario(scenario, state?.shuffleSeed);
    if (spec == current) return false;
    await ScenarioCommands.applySortConfig(
      workspace: scenario,
      spec: spec,
      repo: _repo,
    );
    await refreshScenarios();
    return true;
  }

  /// Toggles the active scenario's duplicate policy (E3: only DuplicatePolicy).
  Future<void> toggleDuplicatePolicy() async {
    final id = _requireActiveId();
    final scenario = await _repo.getScenario(id);
    final next = scenario?.duplicatePolicy == DuplicatePolicy.deduplicate
        ? DuplicatePolicy.allowDuplicate
        : DuplicatePolicy.deduplicate;
    await _repo.updateScenario(
      (scenario ?? Scenario(id: id, name: '')).copyWith(duplicatePolicy: next),
    );
    await refreshScenarios();
    // Dedup changes the accepted stream → signal re-resolution + index rebuild.
    await bumpPlaybackVersion();
  }

  /// Sets the active scenario's 同目录连续 flag (D5/D6): when true each source
  /// is ordered by (parentPath, sortField, name) so same-directory files stay
  /// contiguous; when false each source is sorted by sortField only.
  Future<void> setSourceInternalFirst(bool value) async {
    final id = _requireActiveId();
    final scenario = await _repo.getScenario(id);
    await _repo.updateScenario(
      (scenario ?? Scenario(id: id, name: ''))
          .copyWith(sourceInternalFirst: value),
    );
    await refreshScenarios();
    // Order-affecting definition change: signal re-resolution so playback
    // version subscribers (prev/next visibility, lists) refresh, matching the
    // other definition mutations.
    await bumpPlaybackVersion();
  }

  // ── Resolution ──

  Future<ScenarioResolvePage> resolvePage({
    required int page,
    required int pageSize,
  }) {
    return resolvePageIndexed(_requireActiveId(), page: page, pageSize: pageSize);
  }

  /// Index-preferred page read for [scenarioId], which need not be the active
  /// scenario (the queue page may show another one).
  ///
  /// Trigger point (a): ensures the persisted derived index is current before
  /// serving the page, then seeks it in O(pageSize) instead of walking the
  /// library. Falls back to the legacy walk when indexing is unavailable.
  Future<ScenarioResolvePage> resolvePageIndexed(
    String scenarioId, {
    required int page,
    required int pageSize,
  }) async {
    final buildId = await ensureQueueIndex(scenarioId);
    if (buildId > 0) {
      return _resolver.resolvePageIndexed(
        scenarioId: scenarioId,
        page: page,
        pageSize: pageSize,
      );
    }
    areaKeyLog.w('scenario $scenarioId has no usable index (buildId=$buildId): '
        'serving the legacy walk');
    return _resolver.resolvePage(
      scenarioId: scenarioId,
      page: page,
      pageSize: pageSize,
      // The persisted-config stream cache keys on playbackVersion, which lives
      // only in this store's memory (definition edits / overrides / append).
      playbackVersion: state.playbackVersion,
    );
  }

  Future<ScenarioResolvePage> resolvePageFor(
    String scenarioId, {
    required int page,
    required int pageSize,
    ScenarioSortField? sortField,
    SortDirection? sortDirection,
    bool? sourceInternalFirst,
    PlaybackOrder? order,
    int? shuffleSeed,
    DuplicatePolicy? duplicatePolicy,
  }) {
    // With no overrides the persisted definition IS what the index stores, so
    // serve the page from it. A caller-supplied knob is a temporary,
    // non-persisted view (preview sort / order) the index cannot represent.
    if (sortField == null &&
        sortDirection == null &&
        sourceInternalFirst == null &&
        order == null &&
        shuffleSeed == null &&
        duplicatePolicy == null) {
      return resolvePageIndexed(scenarioId, page: page, pageSize: pageSize);
    }
    return _resolver.resolvePage(
      scenarioId: scenarioId,
      page: page,
      pageSize: pageSize,
      sortField: sortField,
      sortDirection: sortDirection,
      sourceInternalFirst: sourceInternalFirst,
      order: order,
      shuffleSeed: shuffleSeed,
      duplicatePolicy: duplicatePolicy,
      playbackVersion: state.playbackVersion,
    );
  }

  Future<int> _resolveTotal(String scenarioId) async {
    // The index's accepted-stream count IS the shuffle space the indexed page
    // read permutes, unlike the legacy estimate, which spans filtered-out files.
    final buildId = await ensureQueueIndex(scenarioId);
    if (buildId > 0) {
      final indexed = await _resolver.indexedTotalCount(buildId);
      if (indexed != null) return indexed;
    }
    final result = await _resolver.resolvePage(
        scenarioId: scenarioId,
        page: 0,
        pageSize: 1,
        playbackVersion: state.playbackVersion);
    return result.totalItems;
  }

  // ── Scenario content management (delegated to repo) ──

  Future<void> addSource({
    required String storageId,
    required String path,
    bool recursive = false,
    ScenarioSourceKind kind = ScenarioSourceKind.folder,
  }) {
    return _repo.addSource(
      scenarioId: _requireActiveId(),
      storageId: storageId,
      path: path,
      recursive: recursive,
      kind: kind,
    );
  }

  /// [addSource] targeting an explicit [scenarioId] instead of the active one.
  ///
  /// The open queue can page a NON-active scenario, and a row action must edit
  /// the scenario it belongs to — never whichever workspace happens to be
  /// active.
  Future<void> addSourceFor(
    String scenarioId, {
    required String storageId,
    required String path,
    bool recursive = false,
    ScenarioSourceKind kind = ScenarioSourceKind.folder,
  }) {
    return _repo.addSource(
      scenarioId: scenarioId,
      storageId: storageId,
      path: path,
      recursive: recursive,
      kind: kind,
    );
  }

  Future<void> removeSource(int sourceId) => _repo.removeSource(sourceId);

  /// Batch form of [addSource] for the drag-drop append/override paths: one
  /// transaction for the whole list instead of one per folder.
  Future<void> addSources({
    required List<({String storageId, String path, bool recursive})> specs,
    ScenarioSourceKind kind = ScenarioSourceKind.folder,
  }) {
    return _repo.addSources(
      scenarioId: _requireActiveId(),
      specs: [
        for (final s in specs)
          (
            storageId: s.storageId,
            path: s.path,
            recursive: s.recursive,
            kind: kind,
          ),
      ],
    );
  }

  Future<void> addExplicitInclude({
    required String storageId,
    required String path,
  }) {
    return _repo.addExplicitItem(
      scenarioId: _requireActiveId(),
      storageId: storageId,
      path: path,
    );
  }

  Future<void> removeExplicitInclude(int includeId) =>
      _repo.removeExplicitItem(includeId);

  /// Batch form of [removeExplicitInclude] for the redundant-addition cleanup.
  Future<void> removeExplicitIncludes(Iterable<int> includeIds) =>
      _repo.removeExplicitItems(includeIds);

  /// Adds an explicit item to an arbitrary scenario (not necessarily active).
  Future<void> addExplicitItemFor({
    required String scenarioId,
    required String storageId,
    required String path,
  }) =>
      _repo.addExplicitItem(
        scenarioId: scenarioId,
        storageId: storageId,
        path: path,
      );

  /// Batch form of [addExplicitItemFor] for the drag-drop append/override
  /// paths: one transaction and one read for the whole list.
  Future<void> addExplicitItemsFor({
    required String scenarioId,
    required List<({String storageId, String path})> items,
  }) {
    return _repo.addExplicitItems(
      scenarioId: scenarioId,
      items: [
        for (final i in items)
          (
            storageId: i.storageId,
            path: i.path,
            batchId: null,
            mediaId: null,
            uiSortKey: null,
          ),
      ],
    );
  }

  Future<void> addExcludeRule(ScenarioExcludeRule rule) {
    return _repo.addExcludeRule(scenarioId: _requireActiveId(), rule: rule);
  }

  Future<void> removeExcludeRule(int ruleId) => _repo.removeExcludeRule(ruleId);

  // ── Source-of-truth facade (keep all DB access centralized here) ──

  Future<Scenario?> getScenario(String id) => _repo.getScenario(id);

  Future<List<ScenarioSource>> getSources(String id) => _repo.getSources(id);

  Future<List<ScenarioExplicitItem>> getExplicitItems(String id) =>
      _repo.getExplicitItems(id);

  Future<List<ScenarioExcludeRule>> getExcludeRules(String id) =>
      _repo.getExcludeRules(id);

  Future<ScenarioState?> getState(String id) => _repo.getState(id);

  Future<void> updateState(ScenarioState state) => _repo.updateState(state);

  Future<Scenario> ensureSystemPlayingScenario() =>
      _repo.ensureSystemPlayingScenario();

  /// Resolves the entry workspace for a custom desktop entry: reuses
  /// [existingId] when it still points at a live [ScenarioKind.entryWorkspace]
  /// row, otherwise lazily creates a fresh one (and refreshes the mirror).
  Future<Scenario> ensureEntryWorkspace(String? existingId) async {
    if (existingId != null) {
      final existing = await _repo.getScenario(existingId);
      if (existing != null &&
          existing.type == ScenarioKind.entryWorkspace) {
        return existing;
      }
    }
    final created = await _repo.createEntryWorkspace();
    await refreshScenarios();
    return created;
  }

  Future<void> deleteEntryWorkspace(String id) async {
    await _repo.deleteEntryWorkspace(id);
    await refreshScenarios();
  }

  Future<void> clearSources(String id) => _repo.clearSources(id);

  Future<void> clearExplicitItems(String id) => _repo.clearExplicitItems(id);

  Future<void> clearExcludes(String id) => _repo.clearExcludes(id);

  Future<void> clearTemporaryExcludes(String id) =>
      _repo.clearTemporaryExcludes(id);

  Future<void> updateScenario(Scenario scenario) =>
      _repo.updateScenario(scenario);

  /// Override the SystemPlaying workspace from [source]'s Definition + State,
  /// then refresh the in-memory scenario mirror (source of truth).
  Future<void> overrideWorkspace({
    required Scenario workspace,
    Scenario? source,
    bool importPersistentExcludes = true,
  }) async {
    await ScenarioCommands.override(
      workspace: workspace,
      source: source,
      importPersistentExcludes: importPersistentExcludes,
      repo: _repo,
    );
    // v6-D1: replacing the SystemPlaying scope invalidates any parked search
    // session bound to the pre-override workspace.
    bumpWorkspaceOverrideRevision();
    await refreshScenarios();
  }

  /// Append [source]'s Definition into the workspace, then refresh the mirror.
  Future<void> appendWorkspace({
    required Scenario workspace,
    required Scenario source,
    bool importPersistentExcludes = true,
  }) async {
    await ScenarioCommands.append(
      workspace: workspace,
      source: source,
      importPersistentExcludes: importPersistentExcludes,
      repo: _repo,
    );
    await refreshScenarios();
  }

  /// Override the [targetScenarioId] userSaved scenario from the workspace
  /// (save-dialog "Override it", D5), then refresh the mirror.
  Future<void> overrideOther({
    required Scenario workspace,
    required String targetScenarioId,
    String? description,
  }) async {
    await ScenarioCommands.overrideTarget(
      workspace: workspace,
      targetScenarioId: targetScenarioId,
      description: description,
      repo: _repo,
    );
    await refreshScenarios();
  }

  /// Append the workspace's content into the [targetScenarioId] userSaved
  /// scenario with source dedup (save-dialog "Append to it", D6/D7), then
  /// refresh the mirror.
  Future<void> appendOther({
    required Scenario workspace,
    required String targetScenarioId,
    String? description,
  }) async {
    await ScenarioCommands.appendTarget(
      workspace: workspace,
      targetScenarioId: targetScenarioId,
      description: description,
      repo: _repo,
    );
    await refreshScenarios();
  }

  /// Save the workspace as a new userSaved scenario, then refresh the mirror.
  ///
  /// Only this path increments [PlaybackScenarioStoreState.saveCounter] (D2)
  /// and persists it explicitly — the store otherwise only saves on dispose.
  Future<Scenario> saveWorkspaceAs(
    Scenario workspace, {
    String? name,
    String? description,
  }) async {
    final created = await ScenarioCommands.saveAs(
      workspace: workspace,
      name: name,
      description: description,
      repo: _repo,
    );
    set(state.copyWith(saveCounter: state.saveCounter + 1));
    await save(state);
    await refreshScenarios();
    return created;
  }

  /// Default name for the next save-as-new: `Scenario N` where N starts from
  /// counter+1 and skips any occupied name (D1).
  String nextDefaultScenarioName() {
    final taken = state.scenarios
        .where((s) => s.type == ScenarioKind.userSaved)
        .map((s) => s.name)
        .toSet();
    var n = state.saveCounter + 1;
    while (taken.contains('Scenario $n')) {
      n++;
    }
    return 'Scenario $n';
  }

  /// True when the workspace has no sources AND no explicit items (O1/D17:
  /// persistent-only excludes still count as empty).
  Future<bool> isWorkspaceEmpty(String scenarioId) async {
    final sources = await _repo.getSources(scenarioId);
    if (sources.isNotEmpty) return false;
    final items = await _repo.getExplicitItems(scenarioId);
    return items.isEmpty;
  }

  /// Sync the workspace back to its origin (E2), then refresh the mirror.
  Future<bool> syncWorkspaceBack(Scenario workspace) async {
    final ok = await ScenarioCommands.syncBack(
      workspace: workspace,
      repo: _repo,
    );
    await refreshScenarios();
    return ok;
  }

  /// Reloads the scenario list mirror from the DB after any write that changes
  /// scenario definition (sort/order/duplicate/repeat/original rule) so
  /// `state.scenarios` stays the source of truth for `select`-driven UI.
  Future<void> refreshScenarioMirror() => refreshScenarios();

  String _requireActiveId() {
    final id = state.activeScenarioId;
    if (id == null) {
      throw StateError('No active PlaybackScenario selected.');
    }
    return id;
  }

  // ── Persistence (active scenario selection only) ──

  @override
  Future<PlaybackScenarioStoreState?> load() async {
    try {
      final storage = getKvStore();
      final raw = await storage.read(key: _activeScenarioKey);
      if (raw == null) return null;
      // Clamp the per-surface page sizes ON READ: a size persisted by an older
      // build (the prompt used to allow 100000) would otherwise materialize a
      // huge page on upgrade.
      final loaded = PlaybackScenarioStoreState.fromJson(json.decode(raw));
      return loaded.copyWith(
        playingScenarioQueuePageSize:
            clampPageSize(loaded.playingScenarioQueuePageSize),
        scenarioPreviewQueuePageSize:
            clampPageSize(loaded.scenarioPreviewQueuePageSize),
        scenarioManagePageSize: clampPageSize(loaded.scenarioManagePageSize),
      );
    } catch (e) {
      areaKeyLog.e('Error loading PlaybackScenarioStore: $e');
    }
    return null;
  }

  @override
  Future<void> save(PlaybackScenarioStoreState s) async {
    try {
      final storage = getKvStore();
      await storage.write(
        key: _activeScenarioKey,
        value: json.encode(s.toJson()),
      );
    } catch (e) {
      areaKeyLog.e('Error saving PlaybackScenarioStore: $e');
    }
  }
}

PlaybackScenarioStore usePlaybackScenarioStore() =>
    create(() => PlaybackScenarioStore());
