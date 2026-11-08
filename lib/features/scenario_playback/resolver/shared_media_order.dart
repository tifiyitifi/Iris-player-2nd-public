import 'dart:typed_data';

import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_query.dart';
import 'package:iris/features/media_library/model/db/dao/keyset_parent_scope.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';

/// A shared, scenario-independent ORDER over one media scope.
///
/// The v43 derived index persists a per-scenario permutation of node ids —
/// twice (queue rows and VM group members). With many whole-library scenarios
/// that is largely the SAME permutation stored N times. A shared order is built
/// once per (scope, sort, direction, grouping, media-type set) and each scenario
/// then stores only a membership bitmap over it; a scenario's base order is the
/// concatenation of its sources, each a FILTERED SUBSEQUENCE of this order
/// (filtering an ordered set preserves order).
///
/// The order is produced through the SAME query the folder source provider uses
/// ([MediaNodeRepository.getPagedNodes] with `matchAllInStorage`), so it cannot
/// drift from the order the resolver sees (tie-breaks, NULL-last rules, index
/// plan all match by construction).
class SharedMediaOrder {
  const SharedMediaOrder._();

  /// Rows fetched per round trip while building; bounds peak memory on a 500k
  /// scope without materializing one giant result set.
  static const int buildChunk = 20000;

  /// Format version of [orderKey]. Bump it whenever the ORDER BY semantics
  /// change, so an order persisted under the old rules is rebuilt instead of
  /// reused.
  static const String formatVersion = 'v4';

  /// The part of every [orderKey] of [storageId] that the cache GC prunes
  /// within (see `MediaOrderDao.pruneStale` / `pruneToRecent`).
  static String scopePrefix(String storageId) => '$formatVersion|$storageId|';

  /// Stable key for one order. Every input that affects the row set or the
  /// ORDER BY is part of it, so two callers with the same key must get the same
  /// sequence. The `vN` prefix is the ORDER FORMAT version (see
  /// [formatVersion]).
  static String orderKey({
    required String storageId,
    required ScenarioSortField sortField,
    required SortDirection sortDirection,
    required bool pathGroupFirst,
    required List<MediaType> mediaTypes,
  }) {
    // v4: the ORDER BY gained the v53 natural-name collation key on BOTH name
    // paths (plain and 同目录连续 grouped), so a sequence built from the old
    // lexical name is a different order. Same bump as the v52 derived-index
    // reset, which also clears media_orders / scenario_shared_index.
    // v3: 0 now means "unknown" for size/duration, so those rows moved to the
    // NULL bucket at the END of the order instead of ranking as the smallest
    // value. A v2 sequence is a different order and must be rebuilt.
    // v2: the ORDER BY gained a deterministic name/path tail and NULLs-last on
    // both query paths, and modified_at became milliseconds — so a v1 sequence
    // is no longer the same order.
    final types = mediaTypes.map((e) => e.name).toList()..sort();
    return '$formatVersion|$storageId|${sortField.name}|${sortDirection.name}'
        '|${pathGroupFirst ? 'g' : 'f'}|${types.join(',')}';
  }

  /// The full ordered node-id sequence of [storageId] under [sortField].
  ///
  /// Throws [StateError] if a node id does not fit int32 — the packed order
  /// format is int32, and a silent wrap would corrupt every rank.
  static Future<Int32List> build(
    MediaNodeRepository nodeRepo, {
    required String storageId,
    required ScenarioSortField sortField,
    required SortDirection sortDirection,
    required bool pathGroupFirst,
    required List<MediaType> mediaTypes,
    int chunk = buildChunk,
  }) async {
    // Both name orders have a total-order keyset cursor now: plain
    // (`natural_name, path`) and grouped/同目录连续 (`parent_path, natural_name,
    // path`, served by idx_scope_parent_natural_path). Other sort fields still
    // need OFFSET paging — their tie-break is not a single indexed prefix.
    if (sortField == ScenarioSortField.name) {
      return _buildByNameKeyset(
        nodeRepo,
        storageId: storageId,
        sortDirection: sortDirection,
        grouped: pathGroupFirst,
        mediaTypes: mediaTypes,
        chunk: chunk,
      );
    }

    final ids = <int>[];
    var page = 1;
    while (true) {
      final result = await nodeRepo.getPagedNodes(MediaNodePageQuery(
        page: page,
        pageSize: chunk,
        storageId: storageId,
        nodeKind: MediaNodeKind.file,
        mediaTypes: mediaTypes,
        matchAllInStorage: true,
        sortField: sortField.toMediaSortField(),
        sortDirection: sortDirection,
        pathGroupFirst: pathGroupFirst,
        countTotal: false,
      ));
      if (result.items.isEmpty) break;
      for (final node in result.items) {
        final id = int.tryParse(node.id);
        if (id == null || id > 0x7fffffff) {
          throw StateError('media node id "${node.id}" does not fit int32');
        }
        ids.add(id);
      }
      if (result.items.length < chunk) break;
      page++;
    }
    return Int32List.fromList(ids);
  }

  /// Name order built with a keyset cursor instead of OFFSET paging.
  ///
  /// Same ORDER BY as the DAO path — `natural_name, path` plain, `parent_path,
  /// natural_name, path` grouped — but each row is read once: a 500k library
  /// builds in ~5 s instead of ~69 s (grouped) / ~94 s (plain, before the
  /// index), which matters because [formatVersion] bumps force every user to
  /// rebuild once. The grouped cursor also has to carry `parent_path`, and the
  /// root level (`parent_path IS NULL`) needs the NULL group spelled out —
  /// see [MediaNodeRepository.getFilePagesByNaturalKey].
  static Future<Int32List> _buildByNameKeyset(
    MediaNodeRepository nodeRepo, {
    required String storageId,
    required SortDirection sortDirection,
    required bool grouped,
    required List<MediaType> mediaTypes,
    required int chunk,
  }) async {
    final ids = <int>[];
    Future<void> walk(KeysetParentScope parentScope) async {
      var hasCursor = false;
      String? parent;
      String? key;
      String? path;
      while (true) {
        final rows = await nodeRepo.getFilePagesByNaturalKey(
          storageId: storageId,
          mediaTypes: mediaTypes,
          direction: sortDirection,
          grouped: grouped,
          parentScope: parentScope,
          hasCursor: hasCursor,
          afterParentPath: parent,
          afterKey: key,
          afterPath: path,
          limit: chunk,
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          if (row.id > 0x7fffffff) {
            throw StateError('media node id "${row.id}" does not fit int32');
          }
          ids.add(row.id);
        }
        final last = rows.last;
        hasCursor = true;
        parent = last.parentPath;
        key = last.key;
        path = last.path;
        if (rows.length < chunk) break;
      }
    }

    if (grouped && sortDirection == SortDirection.desc) {
      // DESC puts the NULL parent group LAST, and a single query that also
      // reaches it cannot use the `parent_path` range (OR hides it), so it
      // rescans the index for every page. Walk the seekable non-null range
      // first, then the trailing group — same sequence, one extra phase.
      await walk(KeysetParentScope.nonNull);
      await walk(KeysetParentScope.nullOnly);
    } else {
      await walk(KeysetParentScope.any);
    }
    return Int32List.fromList(ids);
  }
}
