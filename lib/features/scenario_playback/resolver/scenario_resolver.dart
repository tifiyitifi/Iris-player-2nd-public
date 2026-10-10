import 'dart:convert';
import 'dart:typed_data';

import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/meta_settings/engine/browse_scope_snapshot.dart'
    show currentBrowseScopeMediaTypes;
import 'package:iris/features/media_library/play_queue/engine/shuffle_engine.dart';
import 'package:iris/features/scenario_playback/model/db/dao/media_order_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_shared_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/origin_reference.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_explicit_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/domain/virtual_child_entry.dart';
import 'package:iris/features/scenario_playback/model/enum/duplicate_policy.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_scope.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_queue_builder.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_source_provider.dart';
import 'package:iris/features/scenario_playback/resolver/bit_vector.dart';
import 'package:iris/features/scenario_playback/resolver/shared_base_order.dart';
import 'package:iris/features/scenario_playback/resolver/shared_index_codec.dart';
import 'package:iris/features/scenario_playback/resolver/shared_media_order.dart';
import 'package:iris/features/scenario_playback/resolver/shared_row_overlay.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/resolver/vm_overlay.dart';
import 'package:iris/features/virtual_media/resolver/vm_resolver.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:iris/features/virtual_media/rule/vm_title_composer.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/vm_l10n.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

/// Whether the index-backed read paths serve from the SHARED-ORDER index (v44).
///
/// ON: EVERY index-backed read path — page window, single-item seek, occurrence
/// recovery, total count, tag view, tag counts, VM search — is served from the
/// shared index. The semantics were pinned item-for-item against the v43 rows by
/// the three-way parity harness (`test/scenario_shared_index_read_test.dart`,
/// plain / VM-group / exclude+dedup / overlapping-source / shuffled / file-source
/// scenarios, gate-is-an-ORDER-invariant, stale order refused) while those rows
/// still existed, and are frozen as goldens
/// (`test/scenario_shared_index_golden_test.dart`) — the regression net now that
/// v45 dropped the tables.
///
/// The shared index is the ONLY persisted representation, so a build it cannot
/// express (placeholder segment, explicit item, provider/media-type mismatch —
/// see `_SharedIndexDraft`) has nothing to serve and degrades to the LEGACY walk,
/// never to a stale or empty read. Turning this off is the rollback: every read
/// path then takes the legacy walk, and no migration is needed.
const bool kUseSharedIndexRead = true;

final _log = AreaKeyLog(LogKeys.mediaProbe);

/// Upper bound on a cached materialized VM stream, sized for a low-end
/// (~1000 CNY) phone.
///
/// Memory math: one merged `EffectivePlaybackItem` holds a `MediaFile`
/// (~0.8-1.2 KB: id + storageId + path list + name + uri + numeric fields)
/// plus occurrence/origins (~0.3-0.5 KB); a `VirtualSegment` in the groups map
/// adds ~0.4-0.6 KB per covered item. Budget ~3-4 KB per item, so 5000 items
/// caps the retained cache at roughly:
///   resident  merged + groups + representative  ~= 5000 x 3 KB  ~= 15 MB
///   transient full-walk segment nodes (freed after the walk) ~= a few MB more
/// i.e. a ~15-20 MB peak inside the resolver.
///
/// Why that is safe on a 1000 CNY Android phone: such devices ship 3-4 GB RAM
/// (2 GB floor), but a 32-bit Flutter process is limited to a ~1.5-2 GB
/// address space and Android kills backgrounded apps well before that. This
/// cache is NOT a new permanent allocation — it only retimes an item graph the
/// resolve path already built per call; the win is keeping ONE copy instead of
/// rebuilding it per page. 15 MB is ~1% of the 1.5 GB budget and ~5% of a
/// conservative 300 MB app ceiling, so it never becomes the OOM trigger.
///
/// Above this bound the resolver degrades to the lazy, memory-safe (slower)
/// walk: no stream is retained, and (O3b) source segments fall back to the
/// rolling-window LRU instead of a full materialization. That path is the
/// pre-existing behavior, so a huge library is never made worse than today.
const int kResolveCacheMaxItems = 5000;

/// A paginated resolution result for a Scenario (C9: real-time pagination).
class ScenarioResolvePage {
  final List<EffectivePlaybackItem> items;
  final int totalItems;
  final int currentPage;
  final int pageSize;
  final int totalPages;

  ScenarioResolvePage({
    required this.items,
    required this.totalItems,
    required this.currentPage,
    required this.pageSize,
  }) : totalPages = ((totalItems / pageSize).ceil()).clamp(1, 99999).toInt();

  bool get isEmpty => items.isEmpty;
}

/// One index-backed Virtual Media search hit: a group row of a scenario's
/// current generation, with its display title rebuilt from the owning rule and
/// the identity of its representative (first visible) member, so a search
/// result can be opened exactly like the queue's merged row.
class VmSearchGroupHit {
  /// Group identity (`ruleId|root|#seq`) — the persisted `group_id`.
  final String scopeKey;

  /// Composed title WITHOUT the `[vm] ` prefix (the search segment adds it).
  final String title;
  final int segmentCount;
  final int totalDurationMs;
  final String storageId;
  final String path;
  final String? uri;
  final int occurrenceIndex;

  const VmSearchGroupHit({
    required this.scopeKey,
    required this.title,
    required this.segmentCount,
    required this.totalDurationMs,
    required this.storageId,
    required this.path,
    required this.uri,
    required this.occurrenceIndex,
  });
}

/// Resolves a Scenario into paginated [EffectivePlaybackItem]s (A2).
///
/// Execution order (v6):
///
/// 1. Load scenario Definition (sources by sortOrder, explicit items by
///    batchId/addOrder, excludes) + state (shuffle seed).
/// 2. Build segments (folder/file source segments + explicit segment).
/// 3. Merge into one virtual index space; each item gets a PlaybackOccurrenceId.
/// 4. Conditional dedup by mediaRef (NEVER mediaId):
///    deduplicate → keep first; allowDuplicate → keep all, mark duplicated.
/// 5. Apply exclusions: scenario-scope + source-scope.
/// 6. Attach metadata → EffectivePlaybackItem.
/// 7. Sort (folder segments by Scenario.sortField) / shuffle (Feistel).
/// 8. Return paginated result.
///
/// The resolved queue is runtime data only and never fully materialized.
class ScenarioResolver {
  final ScenarioRepository repo;
  final MediaNodeRepository nodeRepo;
  final Map<ScenarioSourceKind, ScenarioSourceProvider> providers;

  /// [scopedMediaTypes] feeds the default folder provider's browse-scope
  /// snapshot (defaults to the global funnel). Store-free environments pin
  /// the legacy semantics by passing `() => null`.
  ScenarioResolver({
    required this.repo,
    required this.nodeRepo,
    List<MediaType>? Function()? scopedMediaTypes,
    Map<ScenarioSourceKind, ScenarioSourceProvider>? providers,
    Future<List<VirtualMediaRule>> Function()? vmRulesProvider,
    int maxCachedItems = kResolveCacheMaxItems,
    ScenarioQueueIndexDao? queueIndexDao,
    MediaOrderDao? mediaOrderDao,
    ScenarioSharedIndexDao? sharedIndexDao,
    Future<int> Function(String storageId)? mediaRevisionProvider,
    Future<List<int>> Function(int tagId, DateTime? addedAfter)?
        tagMemberNodeIds,
    Future<List<({int tagId, int nodeId})>> Function(DateTime? addedAfter)?
        tagMembersByTag,
    bool useSharedIndexRead = kUseSharedIndexRead,
  })  : providers = providers ?? {
          ScenarioSourceKind.folder: FolderSourceProvider(
            scopedMediaTypes: scopedMediaTypes ?? currentBrowseScopeMediaTypes,
          ),
          ScenarioSourceKind.file: const FileSourceProvider(),
        },
        _vmRulesProvider =
            vmRulesProvider ?? VirtualMediaService.instance.enabledRules,
        _maxCachedItems = maxCachedItems,
        _queueIndexDao = queueIndexDao,
        _mediaOrderDao = mediaOrderDao,
        _sharedIndexDao = sharedIndexDao,
        _mediaRevisionProvider = mediaRevisionProvider,
        _tagMemberNodeIds = tagMemberNodeIds,
        _tagMembersByTag = tagMembersByTag,
        _useSharedIndexRead = useSharedIndexRead,
        // Same filter the folder provider uses, so the shared order's positions
        // and the provider's listing cannot disagree on media types.
        _scopedMediaTypes = scopedMediaTypes ?? currentBrowseScopeMediaTypes;

  /// Enabled VM rules, injectable for store-free tests. Production reads the
  /// cached [VirtualMediaService] snapshot.
  final Future<List<VirtualMediaRule>> Function() _vmRulesProvider;

  /// Item cap governing both the full-walk materialization and the retained
  /// merged-stream cache (see [kResolveCacheMaxItems]).
  final int _maxCachedItems;

  /// Persisted derived queue index meta: the current build id per scenario and
  /// its accepted count. Its ROW tables (v43 entries/groups) are retired — the
  /// shared index below is the only representation — but the meta row stays: the
  /// shared index's GC and the read paths' `currentBuildId` need it.
  ///
  /// Null disables index building so store-free tests keep the pure in-memory
  /// resolver behavior.
  final ScenarioQueueIndexDao? _queueIndexDao;

  /// Shared-order index (v44): the shared media orders and the per-scenario
  /// bitmaps. Either null disables it, in which case no index is written and the
  /// read paths take the legacy walk.
  final MediaOrderDao? _mediaOrderDao;
  final ScenarioSharedIndexDao? _sharedIndexDao;

  /// Scoped media revision per storage (the store's `media_rev:scope:<id>`),
  /// used to stamp/validate the shared orders. A shared order built against a
  /// stale revision would map ranks to the wrong nodes, so both sides must key
  /// on ONE revision source; the store is that source.
  final Future<int> Function(String storageId)? _mediaRevisionProvider;

  /// The browse-scope media-type filter the providers use; the shared order must
  /// be built with the SAME set or its positions would not match the providers.
  final List<MediaType>? Function() _scopedMediaTypes;

  /// Tag membership as MEDIA NODE IDS (`video_tag_members` joined to
  /// `media_nodes`), with the optional added-at cutoff. Injected because the
  /// resolver has no tag repository.
  ///
  /// Only the SHARED tag read needs it, and only the caller can resolve it; when
  /// it is absent a tag read DECLINES (null) instead of guessing — the other
  /// reads are unaffected.
  final Future<List<int>> Function(int tagId, DateTime? addedAfter)?
      _tagMemberNodeIds;

  /// Every tag's member node ids as `(tagId, nodeId)` pairs, for the shared
  /// intersection count. Injected alongside [_tagMemberNodeIds] (same tag DAO).
  final Future<List<({int tagId, int nodeId})>> Function(DateTime? addedAfter)?
      _tagMembersByTag;

  /// Whether the read path serves from the shared-order index. OFF is the
  /// rollback: every read then takes the legacy walk, which needs no migration.
  final bool _useSharedIndexRead;

  /// Decoded shared indexes, most-recently-used last (a small LRU). One entry is
  /// the base order (4 B per node) plus bitmaps, so at 500k a handful is tens of
  /// MB; cap it rather than following the 8 materialized scenarios.
  static const int _sharedIndexCacheMax = 2;
  final Map<int, _SharedIndex> _sharedIndexCache = {};

  /// Format version of the derived queue index, mixed into
  /// [definitionSignatureWithStorages] so a code-level change that alters the
  /// persisted generation (row encoding, group numbering, overlay semantics)
  /// rebuilds it even when no definition/media row changed.
  /// v2 = chunk numbers scoped per directory / per rule.
  /// v3 = ORDER BY semantics (deterministic name/path tail, NULLs last on both
  /// query paths, millisecond `modified_at`).
  static const int indexFormatVersion = 3;

  /// The decoded shared index for [buildId], or null when it is absent,
  /// unreadable, or was built against a revision whose order is gone.
  ///
  /// Never throws into the read path: a corrupt or mismatched blob must fall
  /// back to the legacy walk, never fail the page.
  Future<_SharedIndex?> _loadSharedIndex(int buildId) async {
    final cached = _sharedIndexCache.remove(buildId);
    if (cached != null) {
      _sharedIndexCache[buildId] = cached; // refresh LRU position
      return cached;
    }
    final sharedDao = _sharedIndexDao;
    final orderDao = _mediaOrderDao;
    if (sharedDao == null || orderDao == null) return null;
    try {
      final blobs = await sharedDao.read(buildId);
      if (blobs == null) {
        _log.w('shared index absent for build=$buildId: no persisted blob '
            '(the build refused it, or the generation was evicted)');
        return null;
      }
      final slices = <SharedOrderSlice>[];
      for (final s in SharedIndexCodec.decodeSlices(blobs.slices)) {
        final order = await orderDao.read(s.orderKey, mediaRev: s.mediaRev);
        // Without its order the bitmaps are meaningless: treat the whole index
        // as absent rather than serve positions against a wrong sequence.
        if (order == null) {
          _log.w('shared index unusable for build=$buildId: order '
              '"${s.orderKey}" missing at mediaRev=${s.mediaRev} '
              '(a revision mismatch orphans every scenario on that order)');
          return null;
        }
        slices.add(
            SharedOrderSlice(orderKey: s.orderKey, order: order, bits: s.bits));
      }
      final index = _SharedIndex(
        base: SharedBaseOrder(
          slices: slices,
          accepted: SharedIndexCodec.decodeBitmap(blobs.accepted),
        ),
        overlay: SharedRowOverlay(
          baseCount: blobs.baseCount,
          absorbed: SharedIndexCodec.decodeBitmap(blobs.absorbed),
          groupRows: SharedIndexCodec.decodeGroups(blobs.groupRows),
          placeholders: SharedIndexCodec.decodePlaceholders(blobs.placeholders),
          occurrence: SharedIndexCodec.decodeIntMap(blobs.occurrence),
          flags: SharedIndexCodec.decodeIntMap(blobs.flags),
        ),
      );
      // The decoded shape must agree with the stored base count, or the row
      // space and the rank space would disagree.
      if (index.base.count != blobs.baseCount) {
        _log.w('shared index unusable for build=$buildId: decoded base count '
            '${index.base.count} != stored ${blobs.baseCount}');
        return null;
      }
      _sharedIndexCache[buildId] = index;
      while (_sharedIndexCache.length > _sharedIndexCacheMax) {
        _sharedIndexCache.remove(_sharedIndexCache.keys.first);
      }
      return index;
    } catch (e) {
      _log.w('shared index unreadable (build=$buildId): $e');
      return null;
    }
  }

  /// The row source for [buildId]: the shared-order index when the switch is on
  /// and it is readable, otherwise NULL — the caller then falls back to the
  /// legacy walk.
  ///
  /// Picking it in ONE place keeps every index-backed read — page window,
  /// single-item seek, occurrence recovery, total count, tag view, tag counts,
  /// VM search — consistent about which representation serves it, and keeps the
  /// fallback in a single spot.
  ///
  /// Null is the ONLY fallback: with the v43 rows retired (not written any more)
  /// a scenario the representation cannot express has no persisted rows at all,
  /// so serving them would be a silent wrong page. Null therefore means
  /// "degrade to the walk".
  ///
  /// The tag read ABILITIES are declared separately on purpose: the tag view only
  /// needs [tagViewReads], the intersection count only [tagCountReads]. Coupling
  /// them (one "tagReads" flag requiring both callbacks) would push the VIEW back
  /// to the walk merely because the COUNT was left unwired — an unrelated
  /// regression.
  Future<_IndexRowSource?> _rowSource({
    required int buildId,
    bool tagViewReads = false,
    bool tagCountReads = false,
  }) async {
    if (!_useSharedIndexRead) {
      _log.w('shared index read is DISABLED (kUseSharedIndexRead=false): '
          'every scenario serves the legacy walk');
      return null;
    }
    final index = await _loadSharedIndex(buildId);
    final hasTagAbility =
        (!tagViewReads || _tagMemberNodeIds != null) &&
            (!tagCountReads || _tagMembersByTag != null);
    if (index == null || !hasTagAbility) return null;
    return _SharedRowSource(index, nodeRepo);
  }

  /// The direction that shapes the PERSISTED BASE order.
  ///
  /// Shuffling is a READ-TIME view: the base order is fixed at ASC so the
  /// permutation is stable and `desc` is its exact reverse (see
  /// [_resolvePageIndexed]). Only a real, non-shuffled sort direction changes
  /// the base order — so only that may invalidate the persisted index, and a
  /// shuffle refresh (new seed) or a direction flip must cost zero writes.
  static SortDirection baseDirectionOf(Scenario? scenario) =>
      scenario?.order == PlaybackOrder.shuffled
          ? SortDirection.asc
          : (scenario?.sortDirection ?? SortDirection.asc);

  /// Content signature of the DEFINITION [scenarioId]'s index is derived from:
  /// its base-order knobs (see [baseDirectionOf]) plus its sources, explicit
  /// items and exclude rules. Shuffle state is deliberately NOT part of it.
  ///
  /// The store compares this before serving a page, so an edit made anywhere
  /// (queue page, sources page, browse page, import) invalidates the persisted
  /// generation without every call site having to announce it. Rows are ordered
  /// semantically first, so a different DB row order is not a content change.
  ///
  /// Also returns the storages the definition references, so a caller that keys
  /// on per-storage media revisions can reuse the source/item rows this already
  /// read instead of querying them again on the read hot path.
  Future<({String signature, Set<String> storages})>
      definitionSignatureWithStorages(String scenarioId) async {
    final scenario = await repo.getScenario(scenarioId);
    final sources = [...await repo.getSources(scenarioId)]
      ..sort((a, b) => a.sortOrder != b.sortOrder
          ? a.sortOrder.compareTo(b.sortOrder)
          : a.id.compareTo(b.id));
    final items = [...await repo.getExplicitItems(scenarioId)]
      ..sort((a, b) => a.addOrder != b.addOrder
          ? a.addOrder.compareTo(b.addOrder)
          : a.id.compareTo(b.id));
    final excludes = [...await repo.getExcludeRules(scenarioId)]
      ..sort((a, b) => a.id.compareTo(b.id));

    var hash = 17;
    void mix(Object? value) {
      hash = 0x7fffffff & (hash * 31 + (value?.hashCode ?? 0));
    }

    // Bump this whenever the DERIVED index FORMAT changes (row encoding, group
    // numbering, overlay semantics): the persisted generation has to rebuild
    // even though no definition row and no media revision moved. v2 = chunk
    // numbers scoped to the directory (sameDirOnly) / to the rule (cross-dir),
    // replacing the single counter that ran across rules.
    mix('indexfmt:$indexFormatVersion');

    mix(scenario?.sortField.name);
    // Only the direction that shapes the PERSISTED BASE order belongs here.
    // Shuffling forces the base order to ASC and its direction is a read-time
    // view, so neither `order` nor the shuffle direction may invalidate the
    // index — a shuffle refresh has to reuse the stored generation.
    mix(baseDirectionOf(scenario).name);
    mix(scenario?.duplicatePolicy.name);
    mix(scenario?.sourceInternalFirst);
    mix('sources');
    for (final s in sources) {
      mix(s.id);
      mix(s.storageId);
      mix(s.path);
      mix(s.recursive);
      mix(s.sourceKind.name);
      mix(s.sortOrder);
    }
    mix('items');
    for (final i in items) {
      mix(i.id);
      mix(i.storageId);
      mix(i.path);
      mix(i.addOrder);
    }
    mix('excludes');
    for (final e in excludes) {
      mix(e.id);
      mix(e.kind.name);
      mix(e.scope.name);
      mix(e.storageId);
      mix(e.path);
      mix(e.recursive);
      mix(e.lifetime.name);
    }
    // VM rules are persisted rows: hashing their JSON keeps the signature
    // comparable across restarts, unlike the in-memory VM revision counter.
    mix('vmrules');
    final vmRules = [...await _vmRulesProvider()]
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final r in vmRules) {
      mix(jsonEncode(r.toJson()));
    }
    final storages = <String>{
      for (final s in sources) s.storageId,
      for (final i in items) i.storageId,
    }..removeWhere((e) => e.isEmpty);
    return (signature: hash.toRadixString(16), storages: storages);
  }

  /// [definitionSignatureWithStorages] digest only — for callers that do not
  /// also key on media revisions.
  Future<String> definitionSignature(String scenarioId) async =>
      (await definitionSignatureWithStorages(scenarioId)).signature;

  /// Builds (or refreshes) the persisted derived queue index for [scenarioId].
  ///
  /// Lazy trigger point (a): the playback store calls this before serving the
  /// first page of a scenario view. The build materializes the scenario's
  /// ACCEPTED effective stream once, derives rule-dimension groups, and writes
  /// a staged generation that is flipped atomically. Returns the build id, or
  /// 0 when the index is disabled / the stream is empty.
  ///
  /// Heavy work is data-dependent and must run off the hot path; callers gate
  /// it behind a progress mask.
  /// The shared index's GC replaces the v43 group sweeps: the meta row is the
  /// only thing a generation owes the index now, so dropping a stale meta row
  /// (see [evictOtherBuilds]) is what lets its blob go.
  Future<int> buildQueueIndex(String scenarioId) async {
    final dao = _queueIndexDao;
    if (dao == null) return 0;

    final scenario = await repo.getScenario(scenarioId);
    final sources = await repo.getSources(scenarioId);
    final items = await repo.getExplicitItems(scenarioId);
    final exclusions = await repo.getExcludeRules(scenarioId);

    final sortField = scenario?.sortField ?? ScenarioSortField.name;
    final sourceInternalFirst = scenario?.sourceInternalFirst ?? false;
    final dedup =
        (scenario?.duplicatePolicy ?? DuplicatePolicy.deduplicate) ==
            DuplicatePolicy.deduplicate;
    // The persisted index is SEED-INDEPENDENT: it stores the BASE order, and the
    // read side applies the Feistel permutation lazily. So only the base
    // direction shapes it — a shuffle refresh or a direction flip costs zero
    // writes (see [baseDirectionOf]).
    final segmentDirection = baseDirectionOf(scenario);

    final segments = await _buildSegments(
      scenarioId: scenarioId,
      sources: sources,
      items: items,
      sortField: sortField,
      segmentDirection: segmentDirection,
      sourceInternalFirst: sourceInternalFirst,
    );
    final space = _VirtualSpace(segments);
    final exclusionSet = await _buildExclusionSet(exclusions);
    final total = _estimateTotal(segments);

    // Prepare the shared-order index (v44) BEFORE the walk. Its per-source
    // slices are filled from the walk itself, because a slice IS the set of
    // shared-order positions the resolver's own virtual space assigned to that
    // source; re-deriving it from a path predicate would add a second source of
    // truth. Null when the scenario is not representable or the tables are not
    // wired, in which case the build has no persisted representation at all and
    // the reads fall back to the legacy walk.
    final shared = _sharedIndexDao != null && _mediaOrderDao != null
        ? await _prepareSharedIndex(
            scenarioId: scenarioId,
            segments: segments,
            sortField: sortField,
            sortDirection: segmentDirection,
            sourceInternalFirst: sourceInternalFirst,
            total: total,
          )
        : null;

    // Materialize the ACCEPTED BASE stream in ascending base-slot order. The
    // shuffle is deliberately NOT applied here: the persisted rows are the base
    // order (seed-independent) and the read side permutes them lazily, which is
    // what makes a shuffle refresh free instead of a full rebuild.
    final occurrenceCounts = <String, int>{};
    final stream = <EffectivePlaybackItem>[];
    var segmentIndex = 0;
    var segmentEnd = segments.isEmpty ? 0 : segments.first.count;
    for (var probe = 0; probe < total; probe++) {
      // The virtual space is the segments concatenated, so the probe's segment
      // is a pointer walk (probes ascend).
      while (probe >= segmentEnd && segmentIndex + 1 < segments.length) {
        segmentIndex++;
        segmentEnd += segments[segmentIndex].count;
      }
      final raw = await space.resolve(probe);
      if (raw == null) continue;
      shared?.record(segmentIndex, _nodeIdOf(raw));
      if (exclusionSet.isExcluded(raw)) continue;
      final key = raw.occurrenceId.mediaKey;
      if (dedup && occurrenceCounts.containsKey(key)) continue;
      final occurrence = occurrenceCounts.update(key, (v) => v + 1,
          ifAbsent: () => 0);
      shared?.markAccepted(probe);
      stream.add(raw.copyWith(
        occurrenceId: raw.occurrenceId.copyWith(occurrenceIndex: occurrence),
        duplicated: occurrence > 0,
      ));
    }

    final vmRules = await _vmRulesProvider();
    final plan = ScenarioQueueBuilder.build(
      stream: stream,
      rules: vmRules,
      mediaNodeIdOf: (rank, item) => _nodeIdOf(item),
    );

    // The gate: null unless the virtual space is EXACTLY the slices'
    // concatenation and the accepted set exactly the walk's.
    final blobs = shared?.finish(
      acceptedCount: plan.totalRanks,
      entries: plan.entries,
      groups: plan.groups,
    );

    // Allocate the build id INSIDE the transaction: it is globally unique and is
    // the key the reads resolve, so two scenarios building at once must not read
    // the same MAX(build_id).
    //
    // The v43 row tables are no longer written: the shared index below is the
    // ONLY persisted representation, and a scenario it cannot express falls back
    // to the legacy walk. The meta row stays (the shared index's GC and every
    // read path's `currentBuildId` need it).
    late int buildId;
    await dao.transaction(() async {
      buildId = await dao.nextBuildId();
      await dao.writeBuildMeta(
        scenarioId: scenarioId,
        buildId: buildId,
        baseCount: plan.totalRanks,
        entryCount: plan.entries.length,
      );
    });
    await dao.evictOtherBuilds(scenarioId, buildId);
    if (blobs != null) {
      await _writeSharedIndex(buildId, blobs);
    } else {
      _logUnrepresentable(scenarioId, plan,
          refused: shared != null, reason: shared?.rejectReason);
    }
    // Drop every shared generation no live build owns — the meta eviction above
    // is exactly what makes the previous generation stale. This must run even
    // when THIS build persisted nothing (a scenario that stopped being
    // representable): leaving the old blob behind would be dead weight until
    // some unrelated build happened to GC.
    await _sharedIndexDao?.gcStaleGenerations();
    return buildId;
  }

  /// Prepares the shared-order index for one build, or null when the scenario
  /// cannot be expressed over shared orders (the build then persists no
  /// representation and the reads use the legacy walk).
  ///
  /// Never throws into the build: a shared-order failure only costs the
  /// optimization, never the generation itself.
  Future<_SharedIndexDraft?> _prepareSharedIndex({
    required String scenarioId,
    required List<_Segment> segments,
    required ScenarioSortField sortField,
    required SortDirection sortDirection,
    required bool sourceInternalFirst,
    required int total,
  }) async {
    final orderDao = _mediaOrderDao;
    if (orderDao == null) return null;
    try {
      return await _SharedIndexDraft.prepare(
        segments: segments,
        nodeRepo: nodeRepo,
        sortField: sortField,
        sortDirection: sortDirection,
        sourceInternalFirst: sourceInternalFirst,
        mediaTypes:
            _scopedMediaTypes() ?? const [MediaType.video, MediaType.audio],
        total: total,
        orderDao: orderDao,
        revisionOf: _mediaRevisionOf,
      );
    } catch (e) {
      // ALWAYS logged, carrying the scenario id: this failure class is usually
      // per-STORAGE (an id that does not fit int32, a shared order that cannot be
      // written, a decode bug), so it can take out EVERY scenario on that storage
      // at once. Gating it on the scenario's size the way the shape signal does
      // would silence exactly that outage — and on a 100+ scenario library an
      // anonymous line is not actionable.
      _log.w('shared index unavailable for scenario $scenarioId: $e');
      return null;
    }
  }

  /// Logs the TRIGGER for the one known representability gap: the shared index
  /// cannot express a placeholder segment (empty source) or an explicit item, so
  /// the gate refuses such a build and the scenario falls back to the legacy
  /// walk — whose page window is the raw slot space and whose occurrence
  /// numbering is page-local.
  ///
  /// ONLY the non-trivial shape warns. The app auto-creates a 0-source,
  /// 1-explicit-item `entryWorkspace` every time a file is opened from the browse
  /// page; it is always trivial (one row, no groups, no duplicates) and warning
  /// on it would drown the signal that matters. A warn line therefore means "a
  /// large / grouped / duplicated scenario lost its indexed semantics in this
  /// library", i.e. the explicit-item-in-a-real-scenario combination appeared and
  /// the representation must be extended to it.
  void _logUnrepresentable(
    String scenarioId,
    ScenarioQueuePlan plan, {
    required bool refused,
    String? reason,
  }) {
    // `refused` = the gate turned this build down (a scenario-shape problem).
    // Otherwise the shared tables were unavailable (a wiring problem), which says
    // nothing about representability.
    if (!refused) return;
    final duplicates = plan.entries.where((e) => e.occurrenceIndex > 0).length;
    // A gate REFUSAL that carries a reason means an internal invariant broke
    // (order mismatch, count mismatch) — never a benign "shape not expressible".
    // That is always worth a line regardless of size: it is a bug, not a limit.
    if (reason == null &&
        plan.totalRanks <= 50 &&
        plan.groups.isEmpty &&
        duplicates == 0) {
      return;
    }
    _log.w(
      'scenario unrepresentable by the shared index, falling back to the '
      'legacy walk: scenario=$scenarioId base=${plan.totalRanks} '
      'rows=${plan.entries.length} groups=${plan.groups.length} '
      'duplicates=$duplicates${reason == null ? '' : ' reason=$reason'}',
    );
  }

  /// Persists the shared index for [buildId].
  ///
  /// Best-effort and deliberately OUTSIDE the meta transaction: a failure here
  /// leaves a generation whose reads fall back to the legacy walk, whereas a
  /// failure inside the transaction would roll the whole build back.
  Future<void> _writeSharedIndex(int buildId, _SharedIndexBlobs blobs) async {
    final shared = _sharedIndexDao;
    if (shared == null) return;
    try {
      await shared.write(
        buildId,
        baseCount: blobs.baseCount,
        slices: blobs.slices,
        accepted: blobs.accepted,
        absorbed: blobs.absorbed,
        groupRows: blobs.groupRows,
        placeholders: blobs.placeholders,
        occurrence: blobs.occurrence,
        flags: blobs.flags,
      );
    } catch (e) {
      _log.w('shared index write failed (build=$buildId): $e');
    }
  }

  /// The scoped media revision the shared orders are stamped with. One source
  /// only (the store's `media_rev:scope:<id>`): a reader that keyed on a
  /// different revision would serve a stale order against fresh bitmaps.
  Future<int> _mediaRevisionOf(String storageId) async {
    final provider = _mediaRevisionProvider;
    if (provider == null) return 0;
    try {
      return await provider(storageId);
    } catch (_) {
      return 0;
    }
  }

  static int _nodeIdOf(EffectivePlaybackItem item) {
    final id = item.media.maybeMap(file: (f) => f.id, orElse: () => '');
    return int.tryParse(id) ?? -1;
  }

  /// Re-derives the contributing source for an index-backed row.
  ///
  /// The derived index stores only the media node id, so a read-back row would
  /// carry no [OriginReference] and the queue's "Skip from source" action would
  /// silently disappear. The sources are re-read once per page and matched with
  /// the same containment rule the legacy segments used; the first containing
  /// source in source order mirrors the legacy segment order.
  static List<OriginReference> _originsForRow(
    List<ScenarioSource> sources,
    String storageId,
    List<String> segments,
  ) {
    for (final s in sources) {
      if (s.storageId != storageId) continue;
      if (_ExclusionSet._isUnder(segments, pathConv(s.path), s.recursive)) {
        return [OriginReference(sourceId: s.id, sourceKind: s.sourceKind)];
      }
    }
    return const [];
  }

  /// Resolves a paginated effective queue for [scenarioId].
  ///
  /// All sort/order/dedup knobs are read from the persisted scenario
  /// definition + state by default. The optional overrides let callers apply a
  /// TEMPORARY, non-persisted view (e.g. the read-only Preview page): when a
  /// non-null value is passed it wins over the persisted one, and nothing is
  /// written back. Local shuffle requires BOTH [order] == shuffled AND a
  /// [shuffleSeed]; otherwise the persisted order/seed is used.
  Future<ScenarioResolvePage> resolvePage({
    required String scenarioId,
    required int page,
    required int pageSize,
    ScenarioSortField? sortField,
    SortDirection? sortDirection,
    bool? sourceInternalFirst,
    PlaybackOrder? order,
    int? shuffleSeed,
    DuplicatePolicy? duplicatePolicy,
    int playbackVersion = 0,
  }) async {
    assert(page >= 0 && pageSize > 0, 'page must be >= 0 and pageSize > 0');

    final scenario = await repo.getScenario(scenarioId);
    final sources = await repo.getSources(scenarioId);
    final items = await repo.getExplicitItems(scenarioId);
    final exclusions = await repo.getExcludeRules(scenarioId);
    final state = await repo.getState(scenarioId);

    final effectiveSortField =
        sortField ?? scenario?.sortField ?? ScenarioSortField.name;
    final effectiveSortDirection =
        sortDirection ?? scenario?.sortDirection ?? SortDirection.asc;
    final effectiveSourceInternalFirst =
        sourceInternalFirst ?? scenario?.sourceInternalFirst ?? false;
    final effectiveOrder = order ?? scenario?.order ?? PlaybackOrder.sequential;
    final effectiveDedup =
        (duplicatePolicy ?? scenario?.duplicatePolicy) ==
            DuplicatePolicy.deduplicate;

    // When shuffled, the underlying segment base order is FIXED (asc) and the
    // chosen direction only reverses the shuffled walk (desc = exact reverse of
    // asc). Otherwise the direction applies to the segments as usual.
    final seed = shuffleSeed ?? state?.shuffleSeed;
    final shuffled = effectiveOrder == PlaybackOrder.shuffled && seed != null;
    final segmentDirection =
        shuffled ? SortDirection.asc : effectiveSortDirection;

    final startIndex = page * pageSize;

    // Virtual Media merge layer (orthogonal, scenario-first). The scenario's
    // OWN effective stream is materialized once and the enabled rules' merge
    // groups are derived FROM that stream ("根据源实时计算") — no library-wide
    // snapshot exists anywhere. Rules activate/change → notifyRulesChanged →
    // playbackVersion bump re-resolves the open lists immediately.
    final vmRules = await _vmRulesProvider();

    // A temporary override view is never cached (it must not evict the
    // persisted view's entry); the persisted-config key carries every
    // order-affecting knob plus playbackVersion / shuffleVersion / VM
    // revision, so any of them changing naturally misses.
    //
    // Only a MERGED view is cached: its signature already governs everything
    // that can change the list, while an unmerged view's sources/excludes are
    // invalidated elsewhere — caching it here would freeze edits behind a key
    // that never moves.
    final String? cacheKey =
        vmRules.isNotEmpty && !_hasOverrides(
      sortField: sortField,
      sortDirection: sortDirection,
      sourceInternalFirst: sourceInternalFirst,
      order: order,
      shuffleSeed: shuffleSeed,
      duplicatePolicy: duplicatePolicy,
    )
            ? _cacheKey(
                scenarioId,
                sortField: effectiveSortField,
                sortDirection: effectiveSortDirection,
                sourceInternalFirst: effectiveSourceInternalFirst,
                order: effectiveOrder,
                shuffleSeed: seed,
                dedup: effectiveDedup,
                playbackVersion: playbackVersion,
                shuffleVersion: state?.shuffleVersion ?? 0,
              )
            : null;

    final cached = _streamCache;
    if (cacheKey != null &&
        cached != null &&
        cached.scenarioId == scenarioId &&
        cached.signature == cacheKey) {
      _vmRepresentativeOccurrence = cached.representative;
      return _pageOf(cached.merged, startIndex, pageSize, page);
    }

    final segments = await _buildSegments(
      scenarioId: scenarioId,
      sources: sources,
      items: items,
      sortField: effectiveSortField,
      segmentDirection: segmentDirection,
      sourceInternalFirst: effectiveSourceInternalFirst,
    );
    final total = _estimateTotal(segments);
    await _prepareSegments(segments, total);

    // ONE element list per view — merged or not. It is built from the accepted
    // stream in BASE order (groups folded to one element each) and only then
    // put through the view's permutation, so the walk, the indexed read and the
    // tap path all page/number on the same element axis. This is also why the
    // walk is unbounded: a shuffled view needs the element count to define its
    // permutation, and a merged view needs the whole stream to derive its
    // groups. The index-backed read is the O(pageSize) path.
    final mat = await _materializeVm(
      segments: segments,
      exclusionSet: await _buildExclusionSet(exclusions),
      total: total,
      dedup: effectiveDedup,
      shuffled: shuffled,
      seed: seed,
      sortDirection: effectiveSortDirection,
      vmRules: vmRules,
    );
    if (vmRules.isNotEmpty) {
      // Publish preflight failures so list tiles can yellow-mark degraded
      // members (they stay ordinary single items via the overlay).
      VirtualMediaService.instance.setLastFail(
        mat.groups.failByKey,
        failedGroups: mat.groups.failedGroups,
      );
      _logVmMerge(scenarioId, mat, vmRules.length);
    }
    _vmRepresentativeOccurrence = mat.representative;
    if (cacheKey != null && total <= _maxCachedItems) {
      _streamCache = _ResolvedStreamCache(
        scenarioId: scenarioId,
        signature: cacheKey,
        merged: mat.merged,
        groups: mat.groups,
        representative: mat.representative,
      );
    }
    return _pageOf(mat.merged, startIndex, pageSize, page);
  }

  // ── Indexed (v39 derived index) page read ──

  /// Index-backed page read: O(pageSize) seek over the persisted rows, plus
  /// one bulk `media_nodes` fetch (and group-member reads) to rebuild items.
  ///
  /// The stored rows are the scenario's BASE order (exclusion/dedup applied);
  /// shuffle is applied lazily here, so a seed change costs zero writes.
  ///
  /// Paging runs on the ELEMENT axis: one ordinary file is one element, one
  /// merged group is one element (its members' ranks are absorbed and never
  /// get a row). Page p therefore covers display positions
  /// `[p*pageSize, (p+1)*pageSize)` of a dense, fully visible list, and each
  /// returned item carries that position as its `virtualIndex`.
  Future<ScenarioResolvePage> resolvePageIndexed({
    required String scenarioId,
    required int page,
    required int pageSize,
    PlaybackOrder? order,
    int? shuffleSeed,
    SortDirection? sortDirection,
  }) async {
    final dao = _queueIndexDao;
    // The fallbacks pass the requested VIEW through: the caller asked for this
    // order/seed/direction, so answering with the scenario's own defaults would
    // be a different queue (the legacy walk is the fallback, not a different
    // request).
    if (dao == null) {
      return resolvePage(
        scenarioId: scenarioId,
        page: page,
        pageSize: pageSize,
        order: order,
        shuffleSeed: shuffleSeed,
        sortDirection: sortDirection,
      );
    }
    final buildId = await dao.currentBuildId(scenarioId);
    // No generation yet, or one the shared representation cannot express: fall
    // back to the legacy walk (the v43 rows are no longer written).
    final source =
        buildId == 0 ? null : await _rowSource(buildId: buildId);
    if (source == null) {
      return resolvePage(
        scenarioId: scenarioId,
        page: page,
        pageSize: pageSize,
        order: order,
        shuffleSeed: shuffleSeed,
        sortDirection: sortDirection,
      );
    }

    final scenario = await repo.getScenario(scenarioId);
    final state = await repo.getState(scenarioId);
    final effectiveOrder = order ?? scenario?.order ?? PlaybackOrder.sequential;
    final seed = shuffleSeed ?? state?.shuffleSeed;
    final effectiveSortDirection =
        sortDirection ?? scenario?.sortDirection ?? SortDirection.asc;

    return _resolvePageIndexed(
      source: source,
      scenarioId: scenarioId,
      page: page,
      pageSize: pageSize,
      order: effectiveOrder,
      seed: seed,
      sortDirection: effectiveSortDirection,
    );
  }

  /// Index-backed page read: O(pageSize) rank seeks over the persisted rows,
  /// plus one bulk `media_nodes` fetch (and group-member reads) to rebuild
  /// items. See [resolvePageIndexed] for the element-axis paging contract.
  Future<ScenarioResolvePage> _resolvePageIndexed({
    required _IndexRowSource source,
    required String scenarioId,
    required int page,
    required int pageSize,
    required PlaybackOrder order,
    required int? seed,
    required SortDirection sortDirection,
  }) async {
    final baseTotal = await source.totalCount();
    if (baseTotal <= 0) {
      return ScenarioResolvePage(
        items: const [],
        totalItems: 0,
        currentPage: page,
        pageSize: pageSize,
      );
    }

    // Page/number space: elements, not ranks. A group is one element, so a
    // page is dense (no absorbed slots punching holes in it) and `totalItems`
    // counts rows the user can actually see.
    final count = await source.elementCount();
    if (count <= 0) {
      return ScenarioResolvePage(
        items: const [],
        totalItems: 0,
        currentPage: page,
        pageSize: pageSize,
      );
    }

    final shuffled = order == PlaybackOrder.shuffled && seed != null;
    final axis = _ElementAxis(
      count: count,
      shuffled: shuffled,
      reverse: shuffled && sortDirection == SortDirection.desc,
      seed: seed,
    );

    final start = page * pageSize;
    // Map each DISPLAY position to its rank, keeping display order: a shuffled
    // page must list its items in the order the user reads them.
    final ranks = <int>[];
    final displayOfRank = <int, int>{};
    final seenRanks = <int>{};
    for (var i = 0; i < pageSize; i++) {
      final display = start + i;
      if (display >= count) break;
      final rank = await source.rankAtOrdinal(axis.elementAt(display));
      if (rank == null || !seenRanks.add(rank)) continue;
      ranks.add(rank);
      displayOfRank[rank] = display;
    }

    final rowByRank = await source.rowsAtRanks(ranks);
    final orderedRows = <QueueEntryRow>[
      for (final r in ranks) if (rowByRank.containsKey(r)) rowByRank[r]!,
    ];

    // Bulk fetch the nodes needed by this page's file rows + group members.
    final nodeIds = <int>{};
    final groupIds = <String>{};
    for (final row in orderedRows) {
      if (row.isGroup) {
        if (row.groupId != null) groupIds.add(row.groupId!);
      } else if (row.mediaNodeId != null && row.mediaNodeId! >= 0) {
        nodeIds.add(row.mediaNodeId!);
      }
    }
    final groupMemberCache = <String, List<GroupMemberRow>>{};
    for (final gid in groupIds) {
      final members = await source.membersOf(gid);
      groupMemberCache[gid] = members;
      for (final m in members) {
        if (m.mediaNodeId >= 0) nodeIds.add(m.mediaNodeId);
      }
    }
    final rulesById = await _rulesById(needed: groupIds.isNotEmpty);
    final nodes = await nodeRepo.nodesByIds(nodeIds);

    // Reconstruct display-merged items in page order. `virtualIndex` is the
    // row's DISPLAY position (the element axis the paging windows and the
    // leading column use), which the window above resolved per rank.
    final sources = await repo.getSources(scenarioId);
    final items = <EffectivePlaybackItem>[];
    for (final row in orderedRows) {
      final display = displayOfRank[row.anchorRank] ?? row.anchorRank;
      if (row.isGroup) {
        final identity = await source.identityOf(row.groupId!);
        final item = _groupRowToItem(
          scenarioId: scenarioId,
          row: row,
          members: groupMemberCache[row.groupId] ?? const [],
          nodes: nodes,
          rulesById: rulesById,
          sources: sources,
          virtualIndex: display,
          ruleId: identity.ruleId,
          anchorRoot: identity.anchorRoot,
          displaySeq: identity.displaySeq,
        );
        if (item != null) items.add(item);
      } else {
        final node = row.mediaNodeId == null ? null : nodes[row.mediaNodeId!];
        if (node == null) {
          final placeholder = _placeholderRowToItem(scenarioId, row,
              virtualIndex: display);
          if (placeholder != null) items.add(placeholder);
          continue;
        }
        items.add(EffectivePlaybackItem(
          media: node,
          scenarioId: scenarioId,
          origins: _originsForRow(sources, node.storageId, node.path),
          explicit: (row.flags & QueueRowFlags.explicit) != 0,
          duplicated: row.occurrenceIndex > 0,
          available: true,
          virtualIndex: display,
          occurrenceId: PlaybackOccurrenceId(
            storageId: node.storageId,
            path: node.path.join('/'),
            occurrenceIndex: row.occurrenceIndex,
          ),
        ));
      }
    }

    return ScenarioResolvePage(
      items: items,
      totalItems: count,
      currentPage: page,
      pageSize: pageSize,
    );
  }

  /// Index-backed `totalItems` (the ELEMENT count: file rows + group rows) for
  /// [buildId], or null when the shared index is unavailable, so the caller
  /// falls back to the walk.
  Future<int?> indexedTotalCount(int buildId) async {
    if (!_useSharedIndexRead) return null;
    final shared = await _loadSharedIndex(buildId);
    final overlay = shared?.overlay;
    if (overlay == null) return null;
    return overlay.baseCount - overlay.absorbed.count;
  }

  /// Index-backed mode-1 tag view stream: the scenario index rows whose file is
  /// a member of [tagId], rebuilt as [EffectivePlaybackItem]s in anchor order.
  /// Replaces the O(N) `collectEffectiveItems(mediaKeyFilter)` walk. Returns
  /// null when the index is unavailable, so the caller falls back.
  Future<List<EffectivePlaybackItem>?> resolveTagViewIndexed({
    required String scenarioId,
    required int tagId,
    DateTime? addedAfter,
  }) async {
    final dao = _queueIndexDao;
    if (dao == null) return null;
    final buildId = await dao.currentBuildId(scenarioId);
    if (buildId == 0) return null;
    final source = await _rowSource(buildId: buildId, tagViewReads: true);
    if (source == null) return null;
    final rows = await source.tagMemberRows(
      tagId: tagId,
      addedAfter: addedAfter,
      memberNodeIds: () async {
        final provider = _tagMemberNodeIds;
        if (provider == null) return const <int>[];
        return provider(tagId, addedAfter);
      },
    );
    return _rowsToItems(scenarioId, source, rows);
  }

  /// Index-backed per-tag intersection counts for [scenarioId]'s current
  /// generation — how many of each tag's members are NON-GROUP rows of the queue
  /// — or null when the index or the tag data is unavailable, so the caller keeps
  /// its own fallback.
  ///
  /// The counts are OCCURRENCES, not distinct nodes: the v43 query is a
  /// `COUNT(*)` over the member × entry join.
  Future<Map<int, int>?> tagIntersectionCountsFor(String scenarioId) async {
    final dao = _queueIndexDao;
    if (dao == null) return null;
    final buildId = await dao.currentBuildId(scenarioId);
    if (buildId == 0) return null;
    final source =
        await _rowSource(buildId: buildId, tagCountReads: true);
    if (source == null) return null;
    return source.tagIntersectionCounts(
      membersByTag: () async {
        final provider = _tagMembersByTag;
        if (provider == null) return const <({int tagId, int nodeId})>[];
        return provider(null);
      },
    );
  }

  /// Rebuilds display items from persisted rows (file rows + group rows) in
  /// row order. Unlike the queue read, each item keeps its row's BASE slot
  /// (`anchor_rank`) as `virtualIndex`: the tag view is its own dense list and
  /// numbers rows by their ordinal IN IT, so a scenario-wide display position
  /// would be meaningless there.
  Future<List<EffectivePlaybackItem>> _rowsToItems(
    String scenarioId,
    _IndexRowSource source,
    List<QueueEntryRow> rows,
  ) async {
    final nodeIds = <int>{};
    final groupIds = <String>{};
    for (final row in rows) {
      if (row.isGroup) {
        if (row.groupId != null) groupIds.add(row.groupId!);
      } else if (row.mediaNodeId != null && row.mediaNodeId! >= 0) {
        nodeIds.add(row.mediaNodeId!);
      }
    }
    final memberCache = <String, List<GroupMemberRow>>{};
    for (final gid in groupIds) {
      final members = await source.membersOf(gid);
      memberCache[gid] = members;
      for (final m in members) {
        if (m.mediaNodeId >= 0) nodeIds.add(m.mediaNodeId);
      }
    }
    final nodes = await nodeRepo.nodesByIds(nodeIds);
    final rulesById = await _rulesById(needed: groupIds.isNotEmpty);
    final sources = await repo.getSources(scenarioId);
    final items = <EffectivePlaybackItem>[];
    for (final row in rows) {
      if (row.isGroup) {
        final identity = await source.identityOf(row.groupId!);
        final item = _groupRowToItem(
          scenarioId: scenarioId,
          row: row,
          members: memberCache[row.groupId] ?? const [],
          nodes: nodes,
          rulesById: rulesById,
          sources: sources,
          virtualIndex: row.anchorRank,
          ruleId: identity.ruleId,
          anchorRoot: identity.anchorRoot,
          displaySeq: identity.displaySeq,
        );
        if (item != null) items.add(item);
      } else {
        final node = row.mediaNodeId == null ? null : nodes[row.mediaNodeId!];
        if (node == null) {
          final placeholder = _placeholderRowToItem(scenarioId, row,
              virtualIndex: row.anchorRank);
          if (placeholder != null) items.add(placeholder);
          continue;
        }
        items.add(EffectivePlaybackItem(
          media: node,
          scenarioId: scenarioId,
          origins: _originsForRow(sources, node.storageId, node.path),
          explicit: (row.flags & QueueRowFlags.explicit) != 0,
          duplicated: row.occurrenceIndex > 0,
          available: true,
          virtualIndex: row.anchorRank,
          occurrenceId: PlaybackOccurrenceId(
            storageId: node.storageId,
            path: node.path.join('/'),
            occurrenceIndex: row.occurrenceIndex,
          ),
        ));
      }
    }
    return items;
  }

  /// In-memory cache of [searchVmGroupsIndexed]'s result, keyed by
  /// (scenario, build) so a per-keystroke search only re-runs its token filter.
  ({String scenarioId, int buildId, List<VmSearchGroupHit> hits})?
      _vmSearchCache;

  /// Index-backed VM search hits for [scenarioId]'s current generation.
  ///
  /// Replaces the O(N) `resolveVmGroupsFor` walk: the groups, their titles and
  /// their representative members all come from the persisted index. Returns
  /// null when the index is unavailable, so the caller keeps its full-walk
  /// fallback. Cached per generation (rebuilt when the index is rebuilt).
  Future<List<VmSearchGroupHit>?> searchVmGroupsIndexed(
      String scenarioId) async {
    final dao = _queueIndexDao;
    if (dao == null) return null;
    final buildId = await dao.currentBuildId(scenarioId);
    if (buildId == 0) return null;
    final cached = _vmSearchCache;
    if (cached != null &&
        cached.scenarioId == scenarioId &&
        cached.buildId == buildId) {
      return cached.hits;
    }

    final source = await _rowSource(buildId: buildId);
    if (source == null) return null;
    final headers = await source.groupHeaders();
    final rulesById = await _rulesById(needed: headers.isNotEmpty);
    final l10n = vmLocalizations();
    final hits = <VmSearchGroupHit>[];
    for (final g in headers) {
      final rule = rulesById[g.ruleId];
      // The rule is gone (deleted since the build): degrade to the default
      // tags rather than dropping the group from search.
      final title = rule != null
          ? composeRuleGroupTitle(
              rule: rule,
              anchorRoot: g.anchorRoot,
              firstFile: g.firstName ?? '',
              lastFile: g.lastName ?? '',
              seq: g.displaySeq,
              totalDurationMs: g.totalDurationMs,
              width: g.firstWidth,
              height: g.firstHeight,
              l10n: l10n,
            )
          : composeVmTitle(
              tags: const [VmTitleTag.dirName, VmTitleTag.seq],
              ruleName: '',
              dirName: vmDirTitleLabel(g.anchorRoot, l10n),
              firstFile: g.firstName ?? '',
              lastFile: g.lastName ?? '',
              seq: g.displaySeq,
              totalDurationMs: g.totalDurationMs,
              width: g.firstWidth,
              height: g.firstHeight,
            );
      hits.add(VmSearchGroupHit(
        scopeKey: g.groupId,
        title: title,
        segmentCount: g.segmentCount,
        totalDurationMs: g.totalDurationMs,
        storageId: g.firstStorageId,
        path: g.firstPath,
        uri: g.firstUri,
        occurrenceIndex: g.firstOccurrenceIndex,
      ));
    }
    _vmSearchCache = (scenarioId: scenarioId, buildId: buildId, hits: hits);
    return hits;
  }

  /// Index-backed single-item read by VISIBLE row ordinal (0-based). Backs
  /// `itemAt`/locate without materializing the prefix. Returns null when the
  /// index is unavailable or the ordinal is out of range.
  Future<EffectivePlaybackItem?> resolveItemAtIndex(
    String scenarioId,
    int ordinal, {
    PlaybackOrder? order,
    int? shuffleSeed,
    SortDirection? sortDirection,
  }) async {
    final dao = _queueIndexDao;
    if (dao == null || ordinal < 0) return null;
    final buildId = await dao.currentBuildId(scenarioId);
    if (buildId == 0) return null;
    final source = await _rowSource(buildId: buildId);
    if (source == null) return null;

    final scenario = await repo.getScenario(scenarioId);
    final state = await repo.getState(scenarioId);
    final effectiveOrder = order ?? scenario?.order ?? PlaybackOrder.sequential;
    final seed = shuffleSeed ?? state?.shuffleSeed;
    final shuffled = effectiveOrder == PlaybackOrder.shuffled && seed != null;

    final count = await source.elementCount();
    if (ordinal < 0 || ordinal >= count) return null;
    final reverse =
        (sortDirection ?? scenario?.sortDirection) == SortDirection.desc;
    final axis = _ElementAxis(
      count: count,
      shuffled: shuffled,
      reverse: shuffled && reverse,
      seed: seed,
    );
    // `ordinal` IS the display position the caller asked about (it came from
    // `establishCurrentPosition`, a dense prefix index). Map it to the element
    // it reads under this view, then to that element's rank — and answer with
    // the position itself, so the result can never disagree with the page read.
    final rank = await source.rankAtOrdinal(axis.elementAt(ordinal));
    if (rank == null) return null;

    final rows = await source.rowsAtRanks([rank]);
    final row = rows[rank];
    if (row == null) return null;

    if (row.isGroup) {
      final members = await source.membersOf(row.groupId!);
      final ids = <int>{
        for (final m in members)
          if (m.mediaNodeId >= 0) m.mediaNodeId,
      };
      final nodes = await nodeRepo.nodesByIds(ids);
      final identity = await source.identityOf(row.groupId!);
      return _groupRowToItem(
        scenarioId: scenarioId,
        row: row,
        members: members,
        nodes: nodes,
        rulesById: await _rulesById(needed: true),
        virtualIndex: ordinal,
        ruleId: identity.ruleId,
        anchorRoot: identity.anchorRoot,
        displaySeq: identity.displaySeq,
      );
    }
    if (row.mediaNodeId == null || row.mediaNodeId! < 0) {
      return _placeholderRowToItem(scenarioId, row, virtualIndex: ordinal);
    }
    final nodes = await nodeRepo.nodesByIds([row.mediaNodeId!]);
    final node = nodes[row.mediaNodeId!];
    if (node == null) {
      return _placeholderRowToItem(scenarioId, row, virtualIndex: ordinal);
    }
    return EffectivePlaybackItem(
      media: node,
      scenarioId: scenarioId,
      origins: const [],
      explicit: (row.flags & QueueRowFlags.explicit) != 0,
      duplicated: row.occurrenceIndex > 0,
      available: true,
      virtualIndex: ordinal,
      occurrenceId: PlaybackOccurrenceId(
        storageId: node.storageId,
        path: node.path.join('/'),
        occurrenceIndex: row.occurrenceIndex,
      ),
    );
  }

  /// Enabled VM rules keyed by id, or an empty map when [needed] is false.
  ///
  /// A group's title tags live on its RULE, not in the persisted index, so a
  /// read that reconstructs a group row looks its rule up again. Callers skip
  /// the lookup entirely when the read has no group row.
  Future<Map<String, VirtualMediaRule>> _rulesById({
    required bool needed,
  }) async {
    if (!needed) return const {};
    return {
      for (final r in await _vmRulesProvider()) r.id: r,
    };
  }

  /// Rebuilds an UNAVAILABLE placeholder row (empty folder source, missing
  /// file-kind source, missing explicit item) from the identity the builder
  /// persisted with it — the indexed equivalent of `_SourcePlaceholderSegment`
  /// and `_ExplicitSlot`'s no-node fallbacks. Returns null for a file row that
  /// carries no such identity (its node vanished for another reason).
  ///
  /// [virtualIndex] is supplied by the caller because a placeholder is just
  /// another element: it carries the position the view shows it at, not the
  /// rank it happens to be stored under.
  EffectivePlaybackItem? _placeholderRowToItem(
    String scenarioId,
    QueueEntryRow row, {
    List<ScenarioSource> sources = const [],
    required int virtualIndex,
  }) {
    final storageId = row.placeholderStorageId;
    final path = row.placeholderPath;
    if (storageId == null || path == null) return null;
    final explicit = (row.flags & QueueRowFlags.explicit) != 0;
    final segments = pathConv(path);
    return EffectivePlaybackItem(
      media: MediaNode.file(
        id: '-1',
        storageId: storageId,
        path: segments,
        name: segments.isNotEmpty
            ? segments.last
            : (explicit ? path : vmLocalizations().vm_title_root_dir),
        mediaType: MediaType.unknown,
        isPresent: false,
      ),
      scenarioId: scenarioId,
      origins: _originsForRow(sources, storageId, segments),
      explicit: explicit,
      duplicated: row.occurrenceIndex > 0,
      available: false,
      virtualIndex: virtualIndex,
      occurrenceId: PlaybackOccurrenceId(
        storageId: storageId,
        path: path,
      ),
    );
  }

  /// Rebuilds one merged group row from its identity + members. The first
  /// member's identity is the representative (occurrence id), the display name
  /// is the rule-composed title reconstructed from the persisted group shape.
  ///
  /// The identity comes from the ROW SOURCE (the shared overlay's decomposed
  /// `SharedGroupRow`), so this reconstruction is written once against the
  /// persisted group shape.
  EffectivePlaybackItem? _groupRowToItem({
    required String scenarioId,
    required QueueEntryRow row,
    required List<GroupMemberRow> members,
    required Map<int, MediaNode> nodes,
    required Map<String, VirtualMediaRule> rulesById,
    List<ScenarioSource> sources = const [],
    required int virtualIndex,
    String? ruleId,
    String anchorRoot = '',
    int displaySeq = 0,
  }) {
    final visible = [
      for (final m in members)
        if (nodes[m.mediaNodeId] != null) m,
    ];
    if (visible.isEmpty) return null;
    final first = nodes[visible.first.mediaNodeId]!;
    final children = <VirtualChildEntry>[];
    var totalMs = 0;
    var totalBytes = 0;
    for (final m in visible) {
      final node = nodes[m.mediaNodeId]!;
      final f = node.maybeMap(file: (f) => f, orElse: () => null);
      final dur = f?.durationMs;
      totalMs += dur ?? 0;
      totalBytes += f?.sizeInBytes ?? 0;
      children.add(VirtualChildEntry(
        mediaKey: canonicalKey(node.storageId, node.path.join('/')),
        name: node.name,
        occurrenceIndex: m.occurrenceIndex,
        durationMs: dur,
        sizeInBytes: f?.sizeInBytes,
        positionMs: f?.playbackPositionMs,
        completed: f?.playbackCompleted ?? false,
      ));
    }
    final firstFile = first.maybeMap(file: (f) => f, orElse: () => null);
    final lastName = nodes[visible.last.mediaNodeId]!.name;
    final rule = rulesById[ruleId];
    final composed = rule != null
        ? composeRuleGroupTitle(
            rule: rule,
            anchorRoot: anchorRoot,
            firstFile: first.name,
            lastFile: lastName,
            seq: displaySeq,
            totalDurationMs: totalMs,
            width: firstFile?.width,
            height: firstFile?.height,
            l10n: vmLocalizations(),
          )
        // The rule is gone (deleted since the build): degrade to the default
        // tags rather than dropping the row.
        : composeVmTitle(
            tags: const [VmTitleTag.dirName, VmTitleTag.seq],
            ruleName: '',
            dirName: vmDirTitleLabel(anchorRoot, vmLocalizations()),
            firstFile: first.name,
            lastFile: lastName,
            seq: displaySeq,
            totalDurationMs: totalMs,
            width: firstFile?.width,
            height: firstFile?.height,
          );
    return EffectivePlaybackItem(
      media: first.copyWith(name: composed),
      scenarioId: scenarioId,
      origins: _originsForRow(sources, first.storageId, first.path),
      explicit: false,
      duplicated: false,
      virtualMerged: true,
      vmTotalSizeBytes: totalBytes,
      vmTotalDurationMs: totalMs,
      vmSegmentCount: visible.length,
      vmChildren: children,
      available: true,
      virtualIndex: virtualIndex,
      occurrenceId: PlaybackOccurrenceId(
        storageId: first.storageId,
        path: first.path.join('/'),
        occurrenceIndex: visible.first.occurrenceIndex,
      ),
    );
  }

  // ── resolvePage internals ──
  bool _hasOverrides({
    ScenarioSortField? sortField,
    SortDirection? sortDirection,
    bool? sourceInternalFirst,
    PlaybackOrder? order,
    int? shuffleSeed,
    DuplicatePolicy? duplicatePolicy,
  }) =>
      sortField != null ||
      sortDirection != null ||
      sourceInternalFirst != null ||
      order != null ||
      shuffleSeed != null ||
      duplicatePolicy != null;

  /// Cache identity of a persisted-config view: every knob that can change the
  /// effective stream order, plus the volatile revisions ([playbackVersion],
  /// VM rule revision) that live only in memory.
  String _cacheKey(
    String scenarioId, {
    required ScenarioSortField sortField,
    required SortDirection sortDirection,
    required bool sourceInternalFirst,
    required PlaybackOrder order,
    required int? shuffleSeed,
    required bool dedup,
    required int playbackVersion,
    required int shuffleVersion,
  }) =>
      [
        scenarioId,
        sortField.name,
        sortDirection.name,
        sourceInternalFirst,
        order.name,
        '${shuffleSeed ?? ''}',
        dedup,
        '$playbackVersion',
        '$shuffleVersion',
        '${VirtualMediaService.instance.revision}',
      ].join('|');

  Future<List<_Segment>> _buildSegments({
    required String scenarioId,
    required List<ScenarioSource> sources,
    required List<ScenarioExplicitItem> items,
    required ScenarioSortField sortField,
    required SortDirection segmentDirection,
    required bool sourceInternalFirst,
  }) async {
    final segments = <_Segment>[];
    for (final source in sources) {
      final provider = providers[source.sourceKind];
      if (provider == null) continue;
      final count = await provider.count(source, nodeRepo);
      if (count <= 0) {
        // D28: an empty/missing source still produces a greyed, un-tappable
        // `available: false` placeholder that counts into totalItems (aligned
        // with the `_ExplicitSlot` placeholder) so the queue/preview surface
        // the broken scope instead of silently hiding it.
        segments.add(_SourcePlaceholderSegment(source));
        continue;
      }
      segments.add(_SourceSegment(
        source: source,
        provider: provider,
        count: count,
        nodeRepo: nodeRepo,
        sortField: sortField,
        sortDirection: segmentDirection,
        sourceInternalFirst: sourceInternalFirst,
      ));
    }
    if (items.isNotEmpty) {
      // Explicit items take part in the scenario's sort like a folder source
      // does; otherwise an explicit-item queue ignores the sort menu entirely
      // (the bug this fixes).
      segments.add(await _ExplicitSegment.build(
        items,
        nodeRepo,
        scenarioId,
        sortField: sortField,
        sortDirection: segmentDirection,
      ));
    }
    return segments;
  }

  /// Pre-fetches every source segment into memory when the whole stream will
  /// be walked AND fits the cache budget. Turns the shuffled random-access walk
  /// from one DB window fetch per item into one sequential fetch per window.
  /// Above the budget (total > [kResolveCacheMaxItems], e.g. a very large
  /// library on a low-end phone) the segments keep their rolling window/LRU so
  /// peak memory stays bounded — memory-safe, at the cost of speed.
  Future<void> _prepareSegments(List<_Segment> segments, int total) async {
    if (total > _maxCachedItems) return;
    for (final segment in segments) {
      if (segment is _SourceSegment) {
        await segment.materialize();
      }
    }
  }

  ScenarioResolvePage _pageOf(
    List<EffectivePlaybackItem> list,
    int startIndex,
    int pageSize,
    int page,
  ) {
    return ScenarioResolvePage(
      items: list.skip(startIndex).take(pageSize).toList(growable: false),
      totalItems: list.length,
      currentPage: page,
      pageSize: pageSize,
    );
  }

  void _logVmMerge(String scenarioId, _VmMaterialization mat, int ruleCount) {
    if (mat.groups.isNotEmpty) {
      _log.i('vm merge: scenario=$scenarioId stream=${mat.stream.length} '
          'rules=$ruleCount groups=${mat.groups.inOrder.length}');
      return;
    }
    // Include first item hint so path-shape mismatches are visible.
    final stream = mat.stream;
    final hint = stream.isEmpty
        ? 'empty stream'
        : 'firstParent=${stream.first.media.maybeMap(file: (f) => f.parentPath ?? "", orElse: () => "")} firstPath=${stream.first.media.maybeMap(file: (f) => f.path.join("/"), orElse: () => "")}';
    _log.w('vm merge no-op: scenario=$scenarioId stream=${stream.length} '
        'rules=$ruleCount groups=0 '
        '(matched=${mat.groups.resolvedGroupCount} valid=0; $hint)');
  }

  /// Walks [total] (in resolve order), applies exclusions + dedup + occurrence
  /// counting, then derives the merge groups and the display-merged list from
  /// the SAME accepted stream. Shared by [resolvePage] and [_computeVmGroups]
  /// so a queue row and a search hit can never disagree.
  /// Materializes a view's ELEMENT list: the accepted stream in BASE order
  /// (exclusions + dedup), each merge group folded into ONE element, and only
  /// then put through the view's permutation.
  ///
  /// Splitting it that way is the whole point: grouping sees the BASE stream,
  /// so a group's members and their own order never depend on the shuffle —
  /// only WHERE the merged row sits does. Permuting first (the old shape)
  /// scattered a group's members, so the run grouping disagreed with the
  /// persisted index about which files a row merges.
  ///
  /// The walk is unbounded by design: a shuffled view needs the element count
  /// to define its permutation, and a merged view needs the whole stream to
  /// derive its groups. The index-backed read is the O(pageSize) path.
  Future<_VmMaterialization> _materializeVm({
    required List<_Segment> segments,
    required _ExclusionSet exclusionSet,
    required int total,
    required bool dedup,
    required bool shuffled,
    required int? seed,
    required SortDirection sortDirection,
    required List<VirtualMediaRule> vmRules,
  }) async {
    final space = _VirtualSpace(segments);

    final occurrenceCounts = <String, int>{};
    EffectivePlaybackItem? accept(EffectivePlaybackItem? item) {
      if (item == null) return null;
      if (exclusionSet.isExcluded(item)) return null;
      if (dedup && occurrenceCounts.containsKey(item.occurrenceId.mediaKey)) {
        return null;
      }
      final occurrence = occurrenceCounts.update(
        item.occurrenceId.mediaKey,
        (v) => v + 1,
        ifAbsent: () => 0,
      );
      return item.copyWith(
        occurrenceId: item.occurrenceId.copyWith(occurrenceIndex: occurrence),
        duplicated: occurrence > 0,
      );
    }

    final stream = <EffectivePlaybackItem>[];
    final representative = <String, PlaybackOccurrenceId>{};
    // Only a MERGED view tracks representatives (they anchor a VM session); an
    // unmerged one would carry one map entry per file for nothing.
    final trackRepresentative = vmRules.isNotEmpty;
    for (var probe = 0; probe < total; probe++) {
      final accepted = accept(await space.resolve(probe));
      if (accepted == null) continue;
      stream.add(accepted);
      if (trackRepresentative) {
        representative.putIfAbsent(
          canonicalKey(
            accepted.occurrenceId.storageId,
            accepted.occurrenceId.path,
          ),
          () => accepted.occurrenceId,
        );
      }
    }

    final groups = resolveGroupsForStream(stream, vmRules);
    final elements =
        groups.isEmpty ? stream : applyVmOverlay(stream, groups.byKey);
    return _VmMaterialization(
      stream: stream,
      merged: _displayOrder(
        elements,
        shuffled: shuffled,
        reverse: shuffled && sortDirection == SortDirection.desc,
        seed: seed,
      ),
      groups: groups,
      representative: representative,
    );
  }

  /// Orders [elements] into the view's DISPLAY order and stamps each one with
  /// that position — what `virtualIndex` means on every read path: the leading
  /// column renders `virtualIndex + 1`, and page p holds positions
  /// `[p*pageSize, (p+1)*pageSize)`.
  List<EffectivePlaybackItem> _displayOrder(
    List<EffectivePlaybackItem> elements, {
    required bool shuffled,
    required bool reverse,
    required int? seed,
  }) {
    final axis = _ElementAxis(
      count: elements.length,
      shuffled: shuffled,
      reverse: reverse,
      seed: seed,
    );
    return [
      for (var display = 0; display < elements.length; display++)
        elements[axis.elementAt(display)].copyWith(virtualIndex: display),
    ];
  }

  // ── Virtual Media derivation (shared by search) ──

  /// Last fully materialized persisted-config view. Also serves
  /// [resolveVmGroupsFor], so a search pass and a queue page share ONE walk
  /// instead of each paying its own full resolve.
  _ResolvedStreamCache? _streamCache;

  /// Representative occurrence per merged group, keyed canonical mediaKey —
  /// the first segment's REAL [PlaybackOccurrenceId] from the stream, keeping
  /// its occurrenceIndex so a search hit can be played exactly like a queue tap.
  Map<String, PlaybackOccurrenceId> _vmRepresentativeOccurrence = const {};

  Map<String, PlaybackOccurrenceId> get vmRepresentativeOccurrence =>
      _vmRepresentativeOccurrence;

  /// Derives (and caches) [scenarioId]'s Virtual Media merge groups from its
  /// OWN effective stream, honoring the persisted definition (sort / order /
  /// shuffle / dedup) and exclusions — the SAME derivation the queue overlay
  /// uses, so a search hit and the queue row can never disagree.
  ///
  /// Scenario-first: no library-wide snapshot exists. The cache is keyed by
  /// scenario id + a signature (definition config, shuffle, [playbackVersion],
  /// [VirtualMediaService.revision]); a rule edit bumps the VM revision and is
  /// captured automatically. [playbackVersion] is passed in because the
  /// resolver has no store access. [forceRefresh] skips a matching entry.
  Future<VmStreamGroups> resolveVmGroupsFor(
    String scenarioId, {
    int playbackVersion = 0,
    bool forceRefresh = false,
  }) async {
    final groups = await _materializePersisted(scenarioId,
        playbackVersion: playbackVersion, forceRefresh: forceRefresh);
    return groups;
  }

  /// Materializes [scenarioId]'s persisted-config view, reusing [_streamCache]
  /// when the signature matches and [forceRefresh] is false.
  Future<VmStreamGroups> _materializePersisted(
    String scenarioId, {
    required int playbackVersion,
    required bool forceRefresh,
  }) async {
    final scenario = await repo.getScenario(scenarioId);
    final state = await repo.getState(scenarioId);
    final sources = await repo.getSources(scenarioId);
    final items = await repo.getExplicitItems(scenarioId);
    final exclusions = await repo.getExcludeRules(scenarioId);

    final sortField = scenario?.sortField ?? ScenarioSortField.name;
    final sortDirection = scenario?.sortDirection ?? SortDirection.asc;
    final sourceInternalFirst = scenario?.sourceInternalFirst ?? false;
    final order = scenario?.order ?? PlaybackOrder.sequential;
    final dedup =
        (scenario?.duplicatePolicy ?? DuplicatePolicy.deduplicate) ==
            DuplicatePolicy.deduplicate;
    final seed = state?.shuffleSeed;
    final shuffled = order == PlaybackOrder.shuffled && seed != null;
    final segmentDirection = shuffled ? SortDirection.asc : sortDirection;

    final signature = _cacheKey(
      scenarioId,
      sortField: sortField,
      sortDirection: sortDirection,
      sourceInternalFirst: sourceInternalFirst,
      order: order,
      shuffleSeed: seed,
      dedup: dedup,
      playbackVersion: playbackVersion,
      shuffleVersion: state?.shuffleVersion ?? 0,
    );

    final cached = _streamCache;
    if (!forceRefresh &&
        cached != null &&
        cached.scenarioId == scenarioId &&
        cached.signature == signature) {
      _vmRepresentativeOccurrence = cached.representative;
      return cached.groups;
    }

    final segments = await _buildSegments(
      scenarioId: scenarioId,
      sources: sources,
      items: items,
      sortField: sortField,
      segmentDirection: segmentDirection,
      sourceInternalFirst: sourceInternalFirst,
    );
    final total = _estimateTotal(segments);

    final vmRules = await _vmRulesProvider();
    if (vmRules.isEmpty) {
      _vmRepresentativeOccurrence = const {};
      _streamCache = null;
      return const VmStreamGroups(byKey: {}, inOrder: []);
    }

    await _prepareSegments(segments, total);
    final mat = await _materializeVm(
      segments: segments,
      exclusionSet: await _buildExclusionSet(exclusions),
      total: total,
      dedup: dedup,
      shuffled: shuffled,
      seed: seed,
      sortDirection: sortDirection,
      vmRules: vmRules,
    );
    _vmRepresentativeOccurrence = mat.representative;
    if (total <= _maxCachedItems) {
      _streamCache = _ResolvedStreamCache(
        scenarioId: scenarioId,
        signature: signature,
        merged: mat.merged,
        groups: mat.groups,
        representative: mat.representative,
      );
    }
    return mat.groups;
  }

  /// Resolves the occurrenceIndex-th effective item matching (storageId, path).
  ///
  /// Recovers the effective item for [occurrence] (C7/A3/D4).
  ///
  /// Served from the persisted derived index when the scenario has a live
  /// generation (O(log n): node → anchor rank → row → item), so the queue,
  /// search and browse entry points no longer pay a full O(N) walk per
  /// recovery. Falls back to the legacy walk when the index is unavailable or
  /// the occurrence is absent from it.
  ///
  /// [order] / [shuffleSeed] / [sortDirection] describe the VIEW being read —
  /// pass the same values the page read got, or the recovered `virtualIndex`
  /// would be a position in a different ordering than the one that asked.
  Future<EffectivePlaybackItem?> resolveItemByOccurrenceFor({
    required String scenarioId,
    required PlaybackOccurrenceId occurrence,
    PlaybackOrder? order,
    int? shuffleSeed,
    SortDirection? sortDirection,
  }) async {
    final dao = _queueIndexDao;
    if (dao != null) {
      final buildId = await dao.currentBuildId(scenarioId);
      if (buildId > 0) {
        final indexed = await _resolveItemByOccurrenceIndexed(
          scenarioId: scenarioId,
          buildId: buildId,
          occurrence: occurrence,
          order: order,
          shuffleSeed: shuffleSeed,
          sortDirection: sortDirection,
        );
        if (indexed != null) return indexed;
      }
    }
    return _resolveItemByOccurrenceLegacy(
      scenarioId: scenarioId,
      occurrence: occurrence,
      order: order,
      shuffleSeed: shuffleSeed,
      sortDirection: sortDirection,
    );
  }

  /// Index-backed occurrence recovery: the media node's anchor row (its own
  /// file row, or the group row covering it) is resolved to its element, then
  /// to the DISPLAY position that element reads at in the current view. A
  /// group member's recovered identity stays the requested FILE's; the merged
  /// row only supplies the composed title / totals / children.
  Future<EffectivePlaybackItem?> _resolveItemByOccurrenceIndexed({
    required String scenarioId,
    required int buildId,
    required PlaybackOccurrenceId occurrence,
    PlaybackOrder? order,
    int? shuffleSeed,
    SortDirection? sortDirection,
  }) async {
    final source = await _rowSource(buildId: buildId);
    if (source == null) return null;
    final node = await _mediaNodeFor(occurrence.storageId, occurrence.path);
    if (node == null) return null;
    final nodeId = int.tryParse(node.id);
    if (nodeId == null) return null;

    final rank = await source.anchorRankOfOccurrence(
      mediaNodeId: nodeId,
      occurrenceIndex: occurrence.occurrenceIndex,
    );
    if (rank == null) return null;
    final element = await source.elementIndexOfRank(rank);
    if (element == null) return null;
    final rows = await source.rowsAtRanks([rank]);
    final row = rows[rank];
    if (row == null) return null;
    // The recovered row must report the position the queue SHOWS it at, which
    // is the element's display position under this view's order (the same
    // mapping the page read and the single-item seek use).
    final display = await _displayIndexOf(
      source: source,
      scenarioId: scenarioId,
      element: element,
      order: order,
      shuffleSeed: shuffleSeed,
      sortDirection: sortDirection,
    );
    final sources = await repo.getSources(scenarioId);

    if (row.isGroup) {
      final members = await source.membersOf(row.groupId!);
      final ids = <int>{
        for (final m in members)
          if (m.mediaNodeId >= 0) m.mediaNodeId,
      };
      final nodes = await nodeRepo.nodesByIds(ids);
      final identity = await source.identityOf(row.groupId!);
      final item = _groupRowToItem(
        scenarioId: scenarioId,
        row: row,
        members: members,
        nodes: nodes,
        rulesById: await _rulesById(needed: true),
        sources: sources,
        virtualIndex: display,
        ruleId: identity.ruleId,
        anchorRoot: identity.anchorRoot,
        displaySeq: identity.displaySeq,
      );
      if (item == null) return null;
      // Keep the merged display (title / totals / children) but the requested
      // file's own identity, matching the merge-layer contract.
      return item.copyWith(
        media: node.copyWith(name: item.media.name),
        occurrenceId: PlaybackOccurrenceId(
          storageId: node.storageId,
          path: node.path.join('/'),
          occurrenceIndex: occurrence.occurrenceIndex,
        ),
        duplicated: occurrence.occurrenceIndex > 0,
      );
    }

    if (row.mediaNodeId == null || row.mediaNodeId! < 0) {
      return _placeholderRowToItem(scenarioId, row,
          sources: sources, virtualIndex: display);
    }
    final nodes = await nodeRepo.nodesByIds([row.mediaNodeId!]);
    final resolved = nodes[row.mediaNodeId!];
    if (resolved == null) {
      return _placeholderRowToItem(scenarioId, row,
          sources: sources, virtualIndex: display);
    }
    return EffectivePlaybackItem(
      media: resolved,
      scenarioId: scenarioId,
      origins: _originsForRow(sources, resolved.storageId, resolved.path),
      explicit: (row.flags & QueueRowFlags.explicit) != 0,
      duplicated: row.occurrenceIndex > 0,
      available: true,
      virtualIndex: display,
      occurrenceId: PlaybackOccurrenceId(
        storageId: resolved.storageId,
        path: resolved.path.join('/'),
        occurrenceIndex: row.occurrenceIndex,
      ),
    );
  }

  /// The existing FILE node for `storageId:path`, or null when it vanished.
  Future<MediaNode?> _mediaNodeFor(String storageId, String path) async {
    final nodes =
        await nodeRepo.nodesByMediaKeys({canonicalKey(storageId, path)});
    return nodes.isEmpty ? null : nodes.first;
  }

  /// The DISPLAY position of [element] under [scenarioId]'s persisted view.
  ///
  /// Occurrence recovery is the only index read that starts from an element
  /// ordinal instead of a display position, so it has to run the same
  /// permutation the page read does — otherwise a recovered row would report
  /// the pre-shuffle slot and the locate/`rowInCurrentPage` would center on a
  /// page that does not hold it.
  Future<int> _displayIndexOf({
    required _IndexRowSource source,
    required String scenarioId,
    required int element,
    PlaybackOrder? order,
    int? shuffleSeed,
    SortDirection? sortDirection,
  }) async {
    final scenario = await repo.getScenario(scenarioId);
    final state = await repo.getState(scenarioId);
    final effectiveOrder = order ?? scenario?.order ?? PlaybackOrder.sequential;
    final seed = shuffleSeed ?? state?.shuffleSeed;
    final shuffled = effectiveOrder == PlaybackOrder.shuffled && seed != null;
    final direction = sortDirection ?? scenario?.sortDirection ?? SortDirection.asc;
    final axis = _ElementAxis(
      count: await source.elementCount(),
      shuffled: shuffled,
      reverse: shuffled && direction == SortDirection.desc,
      seed: seed,
    );
    return axis.displayOf(element);
  }

  /// Legacy occurrence recovery: materializes the view's element list and
  /// returns the row that carries [occurrence]. Returns null when excluded or
  /// absent.
  ///
  /// [order] / [shuffleSeed] / [sortDirection] describe the VIEW being read,
  /// exactly as in [resolveItemByOccurrenceFor].
  Future<EffectivePlaybackItem?> _resolveItemByOccurrenceLegacy({
    required String scenarioId,
    required PlaybackOccurrenceId occurrence,
    PlaybackOrder? order,
    int? shuffleSeed,
    SortDirection? sortDirection,
  }) async {
    final scenario = await repo.getScenario(scenarioId);
    final sources = await repo.getSources(scenarioId);
    final items = await repo.getExplicitItems(scenarioId);
    final exclusions = await repo.getExcludeRules(scenarioId);
    final state = await repo.getState(scenarioId);

    final sortField = scenario?.sortField ?? ScenarioSortField.name;
    final effectiveDirection =
        sortDirection ?? scenario?.sortDirection ?? SortDirection.asc;
    final sourceInternalFirst = scenario?.sourceInternalFirst ?? false;

    // Keep the base segment order identical to [resolvePage] (asc when
    // shuffled) so occurrence recovery walks the same space.
    final effectiveOrder = order ?? scenario?.order ?? PlaybackOrder.sequential;
    final seed = shuffleSeed ?? state?.shuffleSeed;
    final shuffled = effectiveOrder == PlaybackOrder.shuffled && seed != null;
    final segmentDirection =
        shuffled ? SortDirection.asc : effectiveDirection;

    final segments = <_Segment>[];
    for (final source in sources) {
      final provider = providers[source.sourceKind];
      if (provider == null) continue;
      final count = await provider.count(source, nodeRepo);
      if (count <= 0) {
        // D28: same placeholder policy as [resolvePage].
        segments.add(_SourcePlaceholderSegment(source));
        continue;
      }
      segments.add(_SourceSegment(
        source: source,
        provider: provider,
        count: count,
        nodeRepo: nodeRepo,
        sortField: sortField,
        sortDirection: segmentDirection,
        sourceInternalFirst: sourceInternalFirst,
      ));
    }
    if (items.isNotEmpty) {
      segments.add(await _ExplicitSegment.build(
        items,
        nodeRepo,
        scenarioId,
        sortField: sortField,
        sortDirection: segmentDirection,
      ));
    }

    final exclusionSet = await _buildExclusionSet(exclusions);
    final dedup = scenario?.duplicatePolicy == DuplicatePolicy.deduplicate;

    final total = _estimateTotal(segments);
    await _prepareSegments(segments, total);

    // The SAME element list the page read serves: base-order accepted stream,
    // merge groups folded into one element each, view permutation applied last.
    // Recovering from it means the reported `virtualIndex` is the position the
    // queue actually shows the row at — no separate (and easily divergent)
    // base→display mapping to keep in sync.
    final mat = await _materializeVm(
      segments: segments,
      exclusionSet: exclusionSet,
      total: total,
      dedup: dedup,
      shuffled: shuffled,
      seed: seed,
      sortDirection: effectiveDirection,
      vmRules: await _vmRulesProvider(),
    );

    // Canonical match: producers may persist `/a/b`, `//a/b` or `a/b` for the
    // same file (browser raw path vs resolver rendering); compare normalized.
    final wantedKey = canonicalKey(occurrence.storageId, occurrence.path);
    final wantedIndex = occurrence.occurrenceIndex;
    for (final element in mat.merged) {
      // A plain row answers with itself. A merged row answers when the wanted
      // occurrence is one of its members, and then keeps the FILE's identity
      // (mirroring the index-backed recovery) while carrying the GROUP's
      // display — composed title, totals and child list.
      final selfKey = canonicalKey(
          element.occurrenceId.storageId, element.occurrenceId.path);
      final isMember = element.virtualMerged &&
          element.vmChildren.any((c) =>
              c.mediaKey == wantedKey && c.occurrenceIndex == wantedIndex);
      final isSelf = selfKey == wantedKey &&
          element.occurrenceId.occurrenceIndex == wantedIndex;
      if (!isSelf && !isMember) continue;
      if (!element.virtualMerged) return element;

      final fileNodes = await nodeRepo.nodesByMediaKeys({wantedKey});
      final fileNode = fileNodes.isEmpty ? null : fileNodes.first;
      return element.copyWith(
        // The composed title rides on the FILE's own node, so `mediaKey`
        // identifies what was asked for while the row still reads as the
        // merged video.
        media: fileNode == null
            ? element.media
            : fileNode.copyWith(name: element.media.name),
        occurrenceId: PlaybackOccurrenceId(
          storageId: occurrence.storageId,
          path: occurrence.path,
          occurrenceIndex: wantedIndex,
        ),
        duplicated: wantedIndex > 0,
      );
    }
    return null;
  }

  /// Collects the ENTIRE effective stream (exclusions + dedup applied) in the
  /// scenario's BASE resolve order, bounded by [maxItems].
  ///
  /// Additive API for derived views (e.g. tag_play): callers get the same
  /// item sequence a full pagination walk would produce, optionally narrowed
  /// to [mediaKeyFilter] (canonical `storageId:path`). Occurrence indices are
  /// assigned over the UNFILTERED effective stream so identities stay
  /// consistent with [resolveItemByOccurrenceFor].
  Future<List<EffectivePlaybackItem>> collectEffectiveItems({
    required String scenarioId,
    int maxItems = 100000,
    Set<String>? mediaKeyFilter,
  }) async {
    final sources = await repo.getSources(scenarioId);
    final items = await repo.getExplicitItems(scenarioId);
    final exclusions = await repo.getExcludeRules(scenarioId);

    final sortField = ScenarioSortField.name; // base order only
    const segmentDirection = SortDirection.asc;
    const sourceInternalFirst = true;

    final segments = <_Segment>[];
    for (final source in sources) {
      final provider = providers[source.sourceKind];
      if (provider == null) continue;
      final count = await provider.count(source, nodeRepo);
      if (count <= 0) continue;
      segments.add(_SourceSegment(
        source: source,
        provider: provider,
        count: count,
        nodeRepo: nodeRepo,
        sortField: sortField,
        sortDirection: segmentDirection,
        sourceInternalFirst: sourceInternalFirst,
      ));
    }
    if (items.isNotEmpty) {
      segments.add(await _ExplicitSegment.build(
        items,
        nodeRepo,
        scenarioId,
        sortField: sortField,
        sortDirection: segmentDirection,
      ));
    }

    final space = _VirtualSpace(segments);
    final exclusionSet = await _buildExclusionSet(exclusions);
    final total = _estimateTotal(segments);
    final dedup = true;

    final out = <EffectivePlaybackItem>[];
    final seenKeys = <String>{};
    final occurrenceCounts = <String, int>{};
    for (var index = 0; index < total; index++) {
      if (out.length >= maxItems) break;
      final item = await space.resolve(index);
      if (item == null) continue;
      if (exclusionSet.isExcluded(item)) continue;
      final key =
          canonicalKey(item.occurrenceId.storageId, item.occurrenceId.path);
      if (dedup && !seenKeys.add(key)) continue;
      final occurrence = occurrenceCounts.update(
        key,
        (v) => v + 1,
        ifAbsent: () => 0,
      );
      if (mediaKeyFilter != null && !mediaKeyFilter.contains(key)) continue;
      out.add(item.copyWith(
        occurrenceId: item.occurrenceId.copyWith(occurrenceIndex: occurrence),
        duplicated: occurrence > 0,
        virtualIndex: index,
      ));
    }
    return out;
  }

  // ── Internals ──

  int _estimateTotal(List<_Segment> segments) {
    var total = 0;
    for (final segment in segments) {
      total += segment.count;
    }
    return total;
  }

  Future<_ExclusionSet> _buildExclusionSet(List<ScenarioExcludeRule> exclusions) async {
    final mediaKeys = <String, Set<String>>{};
    final dirRules = <String, List<_DirRule>>{};
    final sourceMediaKeys = <String, Set<String>>{};
    final sourceDirRules = <String, List<_DirRule>>{};
    for (final rule in exclusions) {
      if (rule.scope == ExcludeScope.source) {
        final sourceKey = '${rule.storageId}:${rule.sourceId}';
        if (rule.kind == ExcludeRuleKind.media) {
          sourceMediaKeys
              .putIfAbsent(sourceKey, () => <String>{})
              // .add(pathConv(rule.path).join('/'));  // legacy: slash-dependent
              .add(canonicalDbPath(rule.path)); // unified canonical form
        } else {
          sourceDirRules.putIfAbsent(sourceKey, () => <_DirRule>[]).add(_DirRule(
                // path: rule.path,  // legacy: slash-dependent
                path: canonicalDbPath(rule.path), // unified canonical form
                recursive: rule.recursive,
                sourceId: rule.sourceId,
              ));
        }
      } else {
        if (rule.kind == ExcludeRuleKind.media) {
          mediaKeys
              .putIfAbsent(rule.storageId, () => <String>{})
              // .add(pathConv(rule.path).join('/'));  // legacy: slash-dependent
              .add(canonicalDbPath(rule.path)); // unified canonical form
        } else {
          dirRules.putIfAbsent(rule.storageId, () => <_DirRule>[]).add(_DirRule(
                // path: rule.path,  // legacy: slash-dependent
                path: canonicalDbPath(rule.path), // unified canonical form
                recursive: rule.recursive,
                sourceId: rule.sourceId,
              ));
        }
      }
    }
    return _ExclusionSet(
      mediaKeys: mediaKeys,
      dirRules: dirRules,
      sourceMediaKeys: sourceMediaKeys,
      sourceDirRules: sourceDirRules,
    );
  }
}

// ── Cached resolutions ──

/// One scenario's fully materialized persisted-config view, reused across
/// pages / locate / group derivation until its signature changes.
class _ResolvedStreamCache {
  final String scenarioId;
  final String signature;

  /// Accept-filtered resolve-order stream (pre-overlay).
  final List<EffectivePlaybackItem> merged;

  /// Merge groups derived from [merged]'s pre-overlay stream.
  final VmStreamGroups groups;

  /// canonical mediaKey → the first segment's real occurrence.
  final Map<String, PlaybackOccurrenceId> representative;

  const _ResolvedStreamCache({
    required this.scenarioId,
    required this.signature,
    required this.merged,
    required this.groups,
    required this.representative,
  });
}

/// Output of [_ScenarioResolver._materializeVm]: the walked stream, the
/// display-merged list, its groups and the representative occurrence map.
class _VmMaterialization {
  final List<EffectivePlaybackItem> stream;
  final List<EffectivePlaybackItem> merged;
  final VmStreamGroups groups;
  final Map<String, PlaybackOccurrenceId> representative;

  const _VmMaterialization({
    required this.stream,
    required this.merged,
    required this.groups,
    required this.representative,
  });
}

// ── Virtual index space ──

/// The concatenated virtual index space of a scenario: [source segments...,
/// explicit segment].
class _VirtualSpace {
  final List<_Segment> segments;

  _VirtualSpace(this.segments);

  Future<EffectivePlaybackItem?> resolve(int index) async {
    if (index < 0) return null;
    int local = index;
    for (final segment in segments) {
      if (local < segment.count) {
        return segment.resolve(local);
      }
      local -= segment.count;
    }
    return null;
  }
}

sealed class _Segment {
  final int count;
  const _Segment(this.count);

  Future<EffectivePlaybackItem?> resolve(int localIndex);
}

class _SourceSegment extends _Segment {
  final ScenarioSource source;
  final ScenarioSourceProvider provider;
  final ScenarioSortField sortField;
  final SortDirection sortDirection;
  final bool sourceInternalFirst;
  final MediaNodeRepository nodeRepo;

  /// Window size and per-window LRU depth. A shuffled full walk jumps between
  /// pseudo-random offsets; retaining a few windows (instead of one) keeps
  /// those jumps from re-fetching the same 200 rows on every item when the
  /// stream is too large to materialize (total > [kResolveCacheMaxItems]).
  ///
  /// Cost on a low-end phone: each window holds up to 200 `MediaNode`s
  /// (~1-2 KB each) = ~200-400 KB, so 6 windows ~= 1.2-2.4 MB transient —
  /// trivial next to the 15 MB materialized-stream bound and released as soon
  /// as paging moves on.
  static const int _windowSize = 200;
  static const int _windowLruDepth = 6;

  /// Fully materialized rows when the whole stream fits the cache budget.
  /// Null means the segment stays lazy (rolling window / LRU).
  List<MediaNode>? _all;

  final Map<int, List<MediaNode>> _windows = <int, List<MediaNode>>{};

  _SourceSegment({
    required this.source,
    required this.provider,
    required this.sortField,
    required this.sortDirection,
    required this.sourceInternalFirst,
    required this.nodeRepo,
    required int count,
  }) : super(count);

  /// Pulls the entire segment into memory in one sequential sweep so a full
  /// walk costs one fetch per window instead of one per accessed item.
  Future<void> materialize() async {
    if (_all != null) return;
    final out = <MediaNode>[];
    var offset = 0;
    while (offset < count) {
      final window = await provider.fetch(
        source,
        nodeRepo,
        offset: offset,
        count: _windowSize,
        sortField: sortField,
        sortDirection: sortDirection,
        sourceInternalFirst: sourceInternalFirst,
      );
      if (window.isEmpty) break;
      out.addAll(window);
      offset += window.length;
    }
    _all = out;
    _windows.clear();
  }

  @override
  Future<EffectivePlaybackItem?> resolve(int localIndex) async {
    final nodes = await _fetch(localIndex, 1);
    if (nodes.isEmpty) return null;
    return EffectivePlaybackItem(
      media: nodes.first,
      scenarioId: source.scenarioId,
      origins: [OriginReference(sourceId: source.id, sourceKind: source.sourceKind)],
      explicit: false,
      duplicated: false,
      available: true,
      virtualIndex: 0,
      occurrenceId: PlaybackOccurrenceId(
        storageId: nodes.first.storageId,
        path: nodes.first.path.join('/'),
      ),
    );
  }

  Future<List<MediaNode>> _fetch(int offset, int count) async {
    final all = _all;
    if (all != null) {
      if (offset < 0 || offset >= all.length) return const [];
      return all.skip(offset).take(count).toList();
    }
    if (offset < 0 || count <= 0) return const [];
    final windowOffset = offset ~/ _windowSize * _windowSize;
    final window = _windows[windowOffset] ??
        await _loadWindow(windowOffset);
    return window.skip(offset - windowOffset).take(count).toList();
  }

  Future<List<MediaNode>> _loadWindow(int windowOffset) async {
    final nodes = await provider.fetch(
      source,
      nodeRepo,
      offset: windowOffset,
      count: _windowSize,
      sortField: sortField,
      sortDirection: sortDirection,
      sourceInternalFirst: sourceInternalFirst,
    );
    _windows[windowOffset] = nodes;
    while (_windows.length > _windowLruDepth) {
      _windows.remove(_windows.keys.first);
    }
    return nodes;
  }
}

/// D28: a single-slot segment for an empty/missing [ScenarioSource]. It always
/// resolves to an `available: false` placeholder (greyed + un-tappable in the
/// queue/preview) and counts 1 toward totalItems, aligned with the
/// `_ExplicitSlot` placeholder policy.
class _SourcePlaceholderSegment extends _Segment {
  final ScenarioSource source;

  _SourcePlaceholderSegment(this.source) : super(1);

  @override
  Future<EffectivePlaybackItem?> resolve(int localIndex) async {
    if (localIndex != 0) return null;
    final segments = pathConv(source.path);
    final placeholder = MediaNode.file(
      id: '-1',
      storageId: source.storageId,
      path: segments,
      name: segments.isNotEmpty
          ? segments.last
          : vmLocalizations().vm_title_root_dir,
      mediaType: MediaType.unknown,
      isPresent: false,
    );
    return EffectivePlaybackItem(
      media: placeholder,
      scenarioId: source.scenarioId,
      origins: [
        OriginReference(sourceId: source.id, sourceKind: source.sourceKind),
      ],
      explicit: false,
      duplicated: false,
      available: false,
      virtualIndex: 0,
      occurrenceId: PlaybackOccurrenceId(
        storageId: source.storageId,
        path: source.path,
      ),
    );
  }
}

class _ExplicitSegment extends _Segment {
  final List<_ExplicitSlot> slots;

  _ExplicitSegment({required this.slots}) : super(slots.length);

  static Future<_ExplicitSegment> build(
    List<ScenarioExplicitItem> items,
    MediaNodeRepository nodeRepo,
    String scenarioId, {
    required ScenarioSortField sortField,
    required SortDirection sortDirection,
  }) async {
    final slots = <_ExplicitSlot>[];
    for (final item in items) {
      final node = await _resolve(item, nodeRepo);
      slots.add(_ExplicitSlot(item: item, node: node));
    }
    // Explicit items are a plain list in the DB, so the sort must be applied
    // here — mirroring the DAO's ORDER BY exactly (nulls-last for the numeric
    // axes, direction on the primary only, ascending name→path tail) so an
    // explicit queue pages in the same order a folder source would.
    slots.sort((a, b) => _compareSlots(a, b, sortField, sortDirection));
    return _ExplicitSegment(slots: slots);
  }

  /// DAO-parity comparator (see `MediaNodesDao._nullsLastTerms` /
  /// `_orderTailTerms`).
  static int _compareSlots(
    _ExplicitSlot a,
    _ExplicitSlot b,
    ScenarioSortField field,
    SortDirection direction,
  ) {
    final ascending = direction == SortDirection.asc;
    if (field == ScenarioSortField.name) {
      final byName = _slotName(a).compareTo(_slotName(b));
      if (byName != 0) return ascending ? byName : -byName;
      return a.item.path.compareTo(b.item.path);
    }
    final va = _slotNumeric(a, field);
    final vb = _slotNumeric(b, field);
    if (va == null || vb == null) {
      // NULLs last whichever direction — never flipped.
      if (va == null && vb == null) return _slotTail(a, b, field);
      return va == null ? 1 : -1;
    }
    final byValue = va.compareTo(vb);
    if (byValue != 0) return ascending ? byValue : -byValue;
    return _slotTail(a, b, field);
  }

  /// Ascending total-order tail, kept ascending in both directions.
  static int _slotTail(
    _ExplicitSlot a,
    _ExplicitSlot b,
    ScenarioSortField field,
  ) {
    if (field != ScenarioSortField.name) {
      final byName = _slotName(a).compareTo(_slotName(b));
      if (byName != 0) return byName;
    }
    return a.item.path.compareTo(b.item.path);
  }

  static String _slotName(_ExplicitSlot slot) {
    final node = slot.node;
    if (node != null) {
      return (node.normalizedName ?? node.name).toLowerCase();
    }
    // Missing node: fall back to the stored path's last segment.
    final segments = pathConv(slot.item.path);
    return (segments.isEmpty ? slot.item.path : segments.last).toLowerCase();
  }

  static int? _slotNumeric(_ExplicitSlot slot, ScenarioSortField field) {
    final node = slot.node;
    if (node == null) return null;
    return switch (field) {
      ScenarioSortField.modifiedAt => node.modifiedAt?.millisecondsSinceEpoch,
      ScenarioSortField.durationMs =>
        node.maybeMap(file: (f) => f.durationMs, orElse: () => null),
      ScenarioSortField.sizeInBytes =>
        node.maybeMap(file: (f) => f.sizeInBytes, orElse: () => null),
      ScenarioSortField.name => null,
    };
  }

  static Future<MediaNode?> _resolve(
    ScenarioExplicitItem item,
    MediaNodeRepository nodeRepo,
  ) async {
    // A8: mediaId first, (storageId, path) fallback.
    final segments = pathConv(item.path);
    return nodeRepo.getNodeByPath(storageId: item.storageId, path: segments);
  }

  @override
  Future<EffectivePlaybackItem?> resolve(int localIndex) {
    if (localIndex < 0 || localIndex >= slots.length) {
      return Future.value(null);
    }
    return Future.value(slots[localIndex].toEffective());
  }
}

class _ExplicitSlot {
  final ScenarioExplicitItem item;
  final MediaNode? node;

  const _ExplicitSlot({required this.item, this.node});

  EffectivePlaybackItem toEffective() {
    if (node != null) {
      return EffectivePlaybackItem(
        media: node!,
        scenarioId: item.scenarioId,
        origins: const [],
        explicit: true,
        duplicated: false,
        available: true,
        virtualIndex: 0,
        occurrenceId: PlaybackOccurrenceId(
          storageId: item.storageId,
          path: item.path,
        ),
      );
    }
    final segments = pathConv(item.path);
    final placeholder = MediaNode.file(
      id: '-1',
      storageId: item.storageId,
      path: segments,
      name: segments.isNotEmpty ? segments.last : item.path,
      mediaType: MediaType.unknown,
      isPresent: false,
    );
    return EffectivePlaybackItem(
      media: placeholder,
      scenarioId: item.scenarioId,
      origins: const [],
      explicit: true,
      duplicated: false,
      available: false,
      virtualIndex: 0,
      occurrenceId: PlaybackOccurrenceId(
        storageId: item.storageId,
        path: item.path,
      ),
    );
  }
}

class _DirRule {
  final String path;
  final bool recursive;
  final int? sourceId;

  const _DirRule({required this.path, required this.recursive, this.sourceId});
}

class _ExclusionSet {
  final Map<String, Set<String>> mediaKeys;
  final Map<String, List<_DirRule>> dirRules;
  final Map<String, Set<String>> sourceMediaKeys;
  final Map<String, List<_DirRule>> sourceDirRules;

  const _ExclusionSet({
    required this.mediaKeys,
    required this.dirRules,
    required this.sourceMediaKeys,
    required this.sourceDirRules,
  });

  bool isExcluded(EffectivePlaybackItem item) {
    final storageId = item.media.storageId;
    final itemSegs = item.media.path;
    // final fullPath = itemSegs.join('/');  // legacy: slash-dependent
    final fullPath = canonicalDbPath(itemSegs.join('/')); // unified canonical form

    if (_matchMedia(mediaKeys[storageId], fullPath)) return true;
    if (_matchDir(dirRules[storageId], itemSegs)) return true;

    // Source-scope rules only prune items whose origin includes that source.
    for (final origin in item.origins) {
      if (_matchMedia(sourceMediaKeys['$storageId:${origin.sourceId}'], fullPath)) {
        return true;
      }
      if (_matchDir(sourceDirRules['$storageId:${origin.sourceId}'], itemSegs)) {
        return true;
      }
    }
    return false;
  }

  static bool _matchMedia(Set<String>? keys, String fullPath) {
    return keys != null && keys.contains(fullPath);
  }

  static bool _matchDir(List<_DirRule>? rules, List<String> itemSegs) {
    if (rules == null) return false;
    for (final rule in rules) {
      if (_isUnder(itemSegs, pathConv(rule.path), rule.recursive)) return true;
    }
    return false;
  }

  static bool _isUnder(List<String> itemSegs, List<String> dirSegs, bool recursive) {
    if (dirSegs.isEmpty) return true;
    if (itemSegs.length < dirSegs.length) return false;
    for (var i = 0; i < dirSegs.length; i++) {
      if (itemSegs[i] != dirSegs[i]) return false;
    }
    if (itemSegs.length == dirSegs.length) return true;
    if (recursive) return true;
    return itemSegs.length == dirSegs.length + 1;
  }
}

/// The encoded blobs of one shared-order index, ready to persist.
class _SharedIndexBlobs {
  const _SharedIndexBlobs({
    required this.baseCount,
    required this.slices,
    required this.accepted,
    required this.absorbed,
    required this.groupRows,
    required this.placeholders,
    required this.occurrence,
    required this.flags,
  });

  final int baseCount;
  final Uint8List slices;
  final Uint8List accepted;
  final Uint8List absorbed;
  final Uint8List groupRows;
  final Uint8List placeholders;
  final Uint8List occurrence;
  final Uint8List flags;
}

/// In-progress shared-order index for one build.
///
/// The per-source slices are filled from the accepted-stream walk itself,
/// because a slice IS the set of shared-order positions the resolver's own
/// virtual space assigned to that source. Re-deriving it from a path predicate
/// would add a second source of truth that could silently drift; instead
/// [finish] refuses to produce an index unless the virtual space is EXACTLY the
/// slices' concatenation, each slice's element ORDER matches its segment, and
/// the accepted set is exactly the walk's. A refused build persists NOTHING, so a
/// non-representable scenario (placeholder segment, explicit item,
/// media-type/storage mismatch, reordered provider) degrades to the legacy walk
/// and is never mis-served.
class _SharedIndexDraft {
  _SharedIndexDraft._({
    required this.sources,
    required this.orderKeyOf,
    required this.orderOf,
    required this.positionOf,
    required this.mediaRevOf,
    required int total,
  })  : total = total,
        _bits = [
          for (final s in sources)
            BitVectorBuilder(orderOf[s.storageId]!.length),
        ],
        // -1 = "nothing recorded yet"; real positions are >= 0, so the first
        // element of every segment passes the strict monotonicity check.
        _lastPos = [for (final _ in sources) -1],
        _accepted = BitVectorBuilder(total);

  final List<ScenarioSource> sources;
  final Map<String, String> orderKeyOf;
  final Map<String, Int32List> orderOf;
  final Map<String, Map<int, int>> positionOf;
  final Map<String, int> mediaRevOf;
  final int total;
  final List<BitVectorBuilder> _bits;

  /// Last recorded shared-order position per segment (see [record]).
  ///
  /// The slice enumerates its positions ASCENDING, so a provider whose element
  /// order differs from the shared order restricted would pass a pure
  /// set/count check and silently REORDER the base order — the "wrong page /
  /// mis-anchored group" class of bug. Requiring a strictly increasing position
  /// per segment makes the gate an ORDER invariant too.
  final List<int> _lastPos;

  final BitVectorBuilder _accepted;

  /// Flips false the moment the scenario turns out not to be representable.
  bool viable = true;

  /// WHY [viable] flipped (null while still viable). The gate's rejections used
  /// to be silent, which is exactly the failure class that is hardest to
  /// diagnose in the field: a large scenario would quietly lose its indexed
  /// semantics with no line anywhere explaining which invariant failed.
  String? _rejectReason;

  /// Builds the draft, or null when the virtual space is not the sources
  /// concatenated (any non-source segment disqualifies the scenario).
  static Future<_SharedIndexDraft?> prepare({
    required List<_Segment> segments,
    required MediaNodeRepository nodeRepo,
    required ScenarioSortField sortField,
    required SortDirection sortDirection,
    required bool sourceInternalFirst,
    required List<MediaType> mediaTypes,
    required int total,
    required MediaOrderDao orderDao,
    required Future<int> Function(String storageId) revisionOf,
  }) async {
    if (segments.isEmpty) return null;
    if (segments.any((s) => s is! _SourceSegment)) return null;
    final sources = [for (final s in segments) (s as _SourceSegment).source];

    final orderKeyOf = <String, String>{};
    final orderOf = <String, Int32List>{};
    final positionOf = <String, Map<int, int>>{};
    final mediaRevOf = <String, int>{};
    for (final source in sources) {
      if (orderOf.containsKey(source.storageId)) continue;
      final key = SharedMediaOrder.orderKey(
        storageId: source.storageId,
        sortField: sortField,
        sortDirection: sortDirection,
        pathGroupFirst: sourceInternalFirst,
        mediaTypes: mediaTypes,
      );
      orderKeyOf[source.storageId] = key;
      final rev = await revisionOf(source.storageId);
      mediaRevOf[source.storageId] = rev;
      // Reuse the shared order only when it was built against the SAME media
      // revision: a stale order would map ranks to the wrong nodes.
      var order = await orderDao.read(key, mediaRev: rev);
      if (order == null) {
        order = await SharedMediaOrder.build(
          nodeRepo,
          storageId: source.storageId,
          sortField: sortField,
          sortDirection: sortDirection,
          pathGroupFirst: sourceInternalFirst,
          mediaTypes: mediaTypes,
        );
        try {
          await orderDao.write(key, mediaRev: rev, ids: order);
        } catch (e) {
          // Caching the order is an optimization; a write failure must not cost
          // the shared index itself.
          _log.w('shared order cache write failed ($key): $e');
        }
      }
      orderOf[source.storageId] = order;
      positionOf[source.storageId] = {
        for (var i = 0; i < order.length; i++) order[i]: i,
      };
    }
    return _SharedIndexDraft._(
      sources: sources,
      orderKeyOf: orderKeyOf,
      orderOf: orderOf,
      positionOf: positionOf,
      mediaRevOf: mediaRevOf,
      total: total,
    );
  }

  /// Marks the shared-order position of the node the walk found at
  /// [segmentIndex]. Called for EVERY resolved element, accepted or not: the
  /// slice describes the virtual space (excluded items are holes in the
  /// accepted bitmap, not absent from the space).
  void record(int segmentIndex, int nodeId) {
    if (!viable) return;
    final source = sources[segmentIndex];
    final position = positionOf[source.storageId]?[nodeId];
    if (position == null) {
      // The provider produced a node the shared order does not contain (media
      // type or storage mismatch): give up rather than write a wrong index.
      viable = false;
      _rejectReason =
          'node $nodeId from storage ${source.storageId} is absent from the '
          'shared order (source=${source.id} segment=$segmentIndex)';
      return;
    }
    // ORDER invariant: the slice enumerates positions ASCENDING
    // (`SharedOrderSlice.nodeIdAt`), so within a segment the provider's element
    // order must be the shared order restricted. A repeat is fatal too — a
    // bitmap cannot express a duplicated element, which would desync the
    // virtual space from the base order. Today only folder segments (proven
    // ordered by construction) and single-element file segments can pass; this
    // is the guard for any future multi-element provider.
    if (position <= _lastPos[segmentIndex]) {
      viable = false;
      _rejectReason =
          'provider order != shared order at segment $segmentIndex '
          '(node $nodeId position $position <= last ${_lastPos[segmentIndex]})';
      return;
    }
    _lastPos[segmentIndex] = position;
    _bits[segmentIndex].set(position);
  }

  void markAccepted(int probe) {
    if (viable) _accepted.set(probe);
  }

  /// Encodes the index, or null when the invariants that make the reader exact
  /// do not hold.
  _SharedIndexBlobs? finish({
    required int acceptedCount,
    required List<QueueEntryRow> entries,
    required List<GroupRow> groups,
  }) {
    if (!viable) return null;
    final built = [for (final bits in _bits) bits.build()];
    var sliceCount = 0;
    for (final b in built) {
      sliceCount += b.count;
    }
    // The virtual space must be EXACTLY the slices concatenated. Combined with
    // [record]'s strict monotonicity, a slice can hold at most its segment's
    // count of positions, so equality here also forces PER-SEGMENT count
    // equality — i.e. provider order == the shared order restricted.
    if (sliceCount != total) {
      _rejectReason = 'slice count $sliceCount != virtual space $total';
      return null;
    }

    final slices = <SharedOrderSlice>[
      for (var i = 0; i < sources.length; i++)
        SharedOrderSlice(
          orderKey: orderKeyOf[sources[i].storageId]!,
          order: orderOf[sources[i].storageId]!,
          bits: built[i],
        ),
    ];
    final accepted = _accepted.build();
    final base = SharedBaseOrder(slices: slices, accepted: accepted);
    // …and the accepted set must be exactly the walk's, or the reader would
    // serve a different queue than the one the build walked.
    if (base.virtualSize != total || base.count != acceptedCount) {
      _rejectReason =
          'accepted set mismatch (virtualSize ${base.virtualSize} vs $total, '
          'count ${base.count} vs $acceptedCount)';
      return null;
    }

    final overlay = SharedRowOverlay.fromPlan(
      baseCount: acceptedCount,
      entries: entries,
      groupsById: {for (final g in groups) g.groupId: g},
    );
    return _SharedIndexBlobs(
      baseCount: acceptedCount,
      slices: SharedIndexCodec.encodeSlices([
        for (var i = 0; i < slices.length; i++)
          (
            orderKey: slices[i].orderKey,
            mediaRev: mediaRevOf[sources[i].storageId]!,
            bits: slices[i].bits,
          ),
      ]),
      accepted: SharedIndexCodec.encodeBitmap(accepted),
      absorbed: SharedIndexCodec.encodeBitmap(overlay.absorbed),
      groupRows: SharedIndexCodec.encodeGroups(overlay.groupRows),
      placeholders: SharedIndexCodec.encodePlaceholders(overlay.placeholders),
      occurrence: SharedIndexCodec.encodeIntMap(overlay.occurrence),
      flags: SharedIndexCodec.encodeIntMap(overlay.flags),
    );
  }

  /// Why the gate refused this build, or null when it succeeded. Only meaningful
  /// after [finish] returned null.
  String? get rejectReason => _rejectReason;
}

/// A decoded shared-order index: the base order plus the visible-row overlay.
class _SharedIndex {
  _SharedIndex({required this.base, required this.overlay});

  final SharedBaseOrder base;
  final SharedRowOverlay overlay;
}

/// The queue's ONE index space: display position ⇄ element ordinal.
///
/// An ELEMENT is one visible row — an ordinary file, or a whole VM group (its
/// members never take part on their own). Elements sit in the scenario's BASE
/// order, and [elementAt] permutes that element sequence for the view being
/// read, so a shuffled view shuffles elements — not base ranks.
///
/// That distinction is the shuffle fix: permuting ranks scattered a group's
/// absorbed slots across page windows and labelled every row with the rank it
/// happened to land on (6,1,4,2,7,…), so the leading number, the locate and
/// the tapped page all disagreed. On the element axis
/// `virtualIndex == display position == row number - 1` in EVERY view.
class _ElementAxis {
  _ElementAxis({
    required this.count,
    required bool shuffled,
    required bool reverse,
    required int? seed,
  })  : engine = shuffled && seed != null ? FeistelShuffle(seed, count) : null,
        _reverse = shuffled && seed != null && reverse;

  /// Element count of the view — also the page total (`totalItems`).
  final int count;

  /// Permutation over [count] elements, or null when the view is not shuffled.
  final FeistelShuffle? engine;

  final bool _reverse;

  /// Display position → element ordinal (0-based, both in `[0, [count])`).
  int elementAt(int display) {
    final e = engine;
    if (e == null || count <= 1) return display;
    // desc walks the same permutation backwards, so it is the exact reversal.
    return _reverse ? e.forward(count - 1 - display) : e.forward(display);
  }

  /// Element ordinal → display position: the inverse of [elementAt].
  int displayOf(int element) {
    final e = engine;
    if (e == null || count <= 1) return element;
    return _reverse ? count - 1 - e.inverse(element) : e.inverse(element);
  }
}

/// The row/member source of an index-backed read.
///
/// Everything an index-backed read serves comes from the decoded shared index,
/// so the item reconstruction is written once and can only be fed one shape.
abstract class _IndexRowSource {
  /// Accepted base count (the queue's rank space).
  Future<int> totalCount();

  /// Number of VISIBLE rows — the ELEMENT axis the queue pages and numbers on.
  ///
  /// A VM group absorbs its members' ranks, so this is [totalCount] minus the
  /// absorbed slots: one ordinary file is one element, one group is one
  /// element. Paging, `totalItems` and `virtualIndex` are all expressed in
  /// this space; the rank space stays the persisted representation.
  Future<int> elementCount();

  /// The element ordinal (0-based) of the visible row at [rank], or null when
  /// [rank] is absorbed into a group anchored elsewhere.
  Future<int?> elementIndexOfRank(int rank);

  /// The anchor rank of the visible row at element ordinal [element] (the
  /// inverse of [elementIndexOfRank]), or null when it is out of range.
  Future<int?> rankAtOrdinal(int ordinal);

  /// The visible rows at [ranks], keyed by rank (absent = absorbed slot).
  Future<Map<int, QueueEntryRow>> rowsAtRanks(List<int> ranks);

  /// The rule-ordered members of [groupId].
  Future<List<GroupMemberRow>> membersOf(String groupId);

  /// The anchor rank of the row covering ([mediaNodeId], [occurrenceIndex]) —
  /// either a plain file row or the group row whose members include it. Null
  /// when the occurrence is absent from the generation.
  Future<int?> anchorRankOfOccurrence({
    required int mediaNodeId,
    required int occurrenceIndex,
  });

  /// The group headers for the VM search list, ordered by anchor rank: group
  /// identity, chunk shape + totals, and the first/last VISIBLE member's file
  /// fields.
  Future<List<GroupHeaderRow>> groupHeaders();

  /// The scenario rows whose file is a member of [tagId]: file rows whose node
  /// is a member, plus group rows ANY of whose members is a member (the "宽松"
  /// policy — the tag only decides visibility, the whole group surfaces),
  /// DISTINCT and ordered by anchor rank.
  ///
  /// [memberNodeIds] resolves the tag's membership (node ids, optional added-at
  /// cutoff).
  Future<List<QueueEntryRow>> tagMemberRows({
    required int tagId,
    required Future<List<int>> Function() memberNodeIds,
    DateTime? addedAfter,
  });

  /// Per-tag count of the scenario's NON-GROUP rows whose file is a tag member
  /// (OCCURRENCES, not distinct nodes).
  ///
  /// [membersByTag] supplies `(tagId, nodeId)` pairs.
  Future<Map<int, int>> tagIntersectionCounts({
    required Future<List<({int tagId, int nodeId})>> Function() membersByTag,
    DateTime? addedAfter,
  });

  /// The group's identity: rule id (null when the rule is gone), anchor root and
  /// chunk number; the defaults are the "rule deleted" degrade values.
  Future<({String? ruleId, String anchorRoot, int displaySeq})> identityOf(
      String groupId);
}

/// [_IndexRowSource] over the shared-order overlay (v44). Rows, members and the
/// group identity all live in the decoded index, so a page read costs no table
/// round trips at all.
class _SharedRowSource implements _IndexRowSource {
  _SharedRowSource(this._index, this._nodeRepo);

  final _SharedIndex _index;
  final MediaNodeRepository _nodeRepo;

  /// Groups resolved per batch when synthesizing headers.
  ///
  /// Bounds peak memory: a 500k scenario chunked 3-to-a-group has ~170k groups,
  /// so resolving every representative node up front would materialize the
  /// library several times over. Only the batch's first/last member ids are
  /// fetched, and the nodes are dropped before the next batch.
  static const int _headerBatch = 2000;

  @override
  Future<int> totalCount() async => _index.overlay.baseCount;

  @override
  Future<int> elementCount() async {
    final overlay = _index.overlay;
    return overlay.baseCount - overlay.absorbed.count;
  }

  @override
  Future<int?> elementIndexOfRank(int rank) async {
    final overlay = _index.overlay;
    if (rank < 0 || rank >= overlay.baseCount) return null;
    if (overlay.absorbed[rank]) return null;
    // `rank - absorbed.rank(rank)` counts the visible rows before this rank,
    // which is exactly its element ordinal (O(1) table lookup).
    return rank - overlay.absorbed.rank(rank);
  }

  @override
  Future<Map<int, QueueEntryRow>> rowsAtRanks(List<int> ranks) async {
    final out = <int, QueueEntryRow>{};
    for (final rank in ranks) {
      final row = _index.overlay.rowAt(_index.base, rank);
      if (row != null) out[rank] = row;
    }
    return out;
  }

  @override
  Future<List<GroupMemberRow>> membersOf(String groupId) async =>
      _index.overlay.groupById(groupId)?.toMemberRows() ?? const [];

  @override
  Future<int?> rankAtOrdinal(int ordinal) async {
    final overlay = _index.overlay;
    if (ordinal < 0) return null;
    final visible = overlay.baseCount - overlay.absorbed.count;
    if (ordinal >= visible) return null;
    // `r - absorbed.rank(r)` is the number of visible rows BEFORE r. It grows by
    // 0 or 1 per rank, so the ordinal-th visible row is the smallest r where it
    // equals `ordinal` — an O(log n) search instead of the DAO's OFFSET scan.
    var lo = 0;
    var hi = overlay.baseCount - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (mid - overlay.absorbed.rank(mid) < ordinal) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    // A group row never sits on an absorbed rank, but stay defensive: walk to
    // the next visible rank (at most one group's worth) rather than return one.
    while (lo < overlay.baseCount && overlay.absorbed[lo]) {
      lo++;
    }
    return lo < overlay.baseCount ? lo : null;
  }

  @override
  Future<int?> anchorRankOfOccurrence({
    required int mediaNodeId,
    required int occurrenceIndex,
  }) async {
    final overlay = _index.overlay;
    // A plain file row wins, mirroring the v43 query's two steps. The node is
    // located by scanning a slice's order for its id, then asking the base order
    // for that position's accepted rank — no materialization of the whole
    // accepted order (which at 500k would be a 2 MB allocation per call).
    for (final slice in _index.base.slices) {
      final order = slice.order;
      for (var p = 0; p < order.length; p++) {
        if (order[p] != mediaNodeId) continue;
        final rank = _index.base.acceptedRankAtPosition(slice, p);
        if (rank == null) continue;
        if (overlay.absorbed[rank]) continue; // folded into a group row
        if ((overlay.occurrence[rank] ?? 0) != occurrenceIndex) continue;
        return rank;
      }
    }
    // …otherwise the group row whose members cover it.
    for (final group in overlay.groupRows) {
      for (var i = 0; i < group.members.length; i++) {
        if (group.members[i] == mediaNodeId &&
            (group.memberOccurrence[i] ?? 0) == occurrenceIndex) {
          return group.anchorRank;
        }
      }
    }
    return null;
  }

  @override
  Future<({String? ruleId, String anchorRoot, int displaySeq})> identityOf(
      String groupId) async {
    final group = _index.overlay.groupById(groupId);
    if (group == null) return (ruleId: null, anchorRoot: '', displaySeq: 0);
    return (
      ruleId: group.ruleId,
      anchorRoot: group.rootPath,
      displaySeq: group.chunkNo,
    );
  }

  @override
  Future<List<GroupHeaderRow>> groupHeaders() async {
    final groups = _index.overlay.groupRows;
    if (groups.isEmpty) return const [];
    final out = <GroupHeaderRow>[];
    for (var start = 0; start < groups.length; start += _headerBatch) {
      final end = start + _headerBatch > groups.length
          ? groups.length
          : start + _headerBatch;
      final batch = groups.sublist(start, end);

      // The v43 header's MIN/MAX subqueries pick the first/last member that HAS
      // a node. A member id of -1 was never in this scenario's stream (the
      // padding preserves the rule's chunk shape), so it marks exactly the
      // members to skip — no existence query needed for the rest.
      final firstIdx = List<int>.filled(batch.length, -1);
      final lastIdx = List<int>.filled(batch.length, -1);
      final visibleIds = <int>{};
      for (var g = 0; g < batch.length; g++) {
        final members = batch[g].members;
        for (var i = 0; i < members.length; i++) {
          if (members[i] < 0) continue;
          if (firstIdx[g] < 0) firstIdx[g] = i;
          lastIdx[g] = i;
        }
        if (firstIdx[g] >= 0) {
          visibleIds.add(members[firstIdx[g]]);
          visibleIds.add(members[lastIdx[g]]);
        }
      }
      // BATCH-level skip: not one group in these 2000 has a visible member, so
      // there is nothing to query for and nothing to emit.
      if (visibleIds.isEmpty) continue;
      final nodes = await _nodeRepo.nodesByIds(visibleIds);

      for (var g = 0; g < batch.length; g++) {
        // GROUP-level skip: this one group has no visible member (the v43 header's
        // media_nodes join drops it the same way).
        if (firstIdx[g] < 0) continue;
        final group = batch[g];
        final firstNode = nodes[group.members[firstIdx[g]]];
        // A node that vanished after the build: the v43 join drops the group
        // too, and the media revision will invalidate this generation anyway.
        if (firstNode == null) continue;
        final lastNode = nodes[group.members[lastIdx[g]]] ?? firstNode;
        // `uri` / `width` / `height` live on the FILE variant, like the v43
        // query's `media_nodes` columns.
        final firstFile =
            firstNode.maybeMap(file: (f) => f, orElse: () => null);
        out.add(GroupHeaderRow(
          groupId: group.groupId,
          ruleId: group.ruleId,
          anchorRoot: group.rootPath,
          displaySeq: group.chunkNo,
          // The VM item's own segment count, which the -1 padding preserves.
          segmentCount: group.members.length,
          totalDurationMs: group.totalDurationMs,
          firstNodeId: group.members[firstIdx[g]],
          firstStorageId: firstNode.storageId,
          firstPath: firstNode.path.join('/'),
          firstUri: firstFile?.uri,
          firstName: firstNode.name,
          firstWidth: firstFile?.width,
          firstHeight: firstFile?.height,
          firstOccurrenceIndex: group.memberOccurrence[firstIdx[g]] ?? 0,
          lastName: lastNode.name,
        ));
      }
    }
    return out;
  }

  @override
  Future<List<QueueEntryRow>> tagMemberRows({
    required int tagId,
    required Future<List<int>> Function() memberNodeIds,
    DateTime? addedAfter,
  }) async {
    // The tag's membership decides VISIBILITY only ("宽松"): a file row surfaces
    // when its node is a member, and a group row surfaces WHOLE when ANY of its
    // members is — the two halves of the v43 query's UNION, in anchor order.
    final members = (await memberNodeIds()).toSet();
    if (members.isEmpty) return const [];
    final overlay = _index.overlay;
    final out = <QueueEntryRow>[];
    for (var rank = 0; rank < overlay.baseCount; rank++) {
      final row = overlay.rowAt(_index.base, rank);
      if (row == null) continue;
      if (row.isGroup) {
        final group = overlay.groupAt(rank);
        if (group == null) continue;
        for (final id in group.members) {
          if (id >= 0 && members.contains(id)) {
            out.add(row);
            break;
          }
        }
        continue;
      }
      final id = row.mediaNodeId;
      if (id != null && id >= 0 && members.contains(id)) out.add(row);
    }
    return out;
  }

  @override
  Future<Map<int, int>> tagIntersectionCounts({
    required Future<List<({int tagId, int nodeId})>> Function() membersByTag,
    DateTime? addedAfter,
  }) async {
    final pairs = await membersByTag();
    if (pairs.isEmpty) return const {};
    // node id → the tags it belongs to (one file can carry several tags).
    final tagsOf = <int, List<int>>{};
    for (final pair in pairs) {
      (tagsOf[pair.nodeId] ??= <int>[]).add(pair.tagId);
    }
    final overlay = _index.overlay;
    final counts = <int, int>{};
    for (var rank = 0; rank < overlay.baseCount; rank++) {
      final row = overlay.rowAt(_index.base, rank);
      // NON-GROUP rows only: the v43 query joins with `is_group = 0`, so a group
      // row's tagged members do NOT count here — unlike the tag VIEW, which
      // surfaces the whole group.
      if (row == null || row.isGroup) continue;
      final id = row.mediaNodeId;
      if (id == null || id < 0) continue;
      final tags = tagsOf[id];
      if (tags == null) continue;
      // One increment per ROW, matching `COUNT(*)`: a duplicated file counts once
      // per occurrence, not once per node.
      for (final tagId in tags) {
        counts[tagId] = (counts[tagId] ?? 0) + 1;
      }
    }
    return counts;
  }
}
