import 'dart:typed_data';

import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/resolver/base_order_view.dart';
import 'package:iris/features/scenario_playback/resolver/bit_vector.dart';

/// One merged group row: where it sits, which group it is, and its members in
/// RULE order.
///
/// The group id is stored DECOMPOSED into its parts (rule + root path + chunk
/// number) rather than as the resolver's `scopeKey` string. That lets the codec
/// intern the 36-char rule id (and the root path) once per (rule, path) instead
/// of on every group row, which is what the storage budget needs at 3-to-a-group
/// chunking. [groupId] rebuilds the exact resolver key.
///
/// The member list is NOT shareable across scenarios: the resolver derives
/// groups from the RULE over the scenario's OWN item set
/// (`resolveRuleGroups(library: segs)`), so two scenarios with different
/// sources/excludes chunk differently.
class SharedGroupRow {
  SharedGroupRow({
    required this.anchorRank,
    required this.ruleId,
    required this.rootPath,
    required this.chunkNo,
    required this.members,
    this.memberOccurrence = const {},
    this.totalDurationMs = 0,
  });

  /// Base rank the row is emitted at (the earliest member's).
  final int anchorRank;

  final String ruleId;

  /// The group's root path (`VirtualMediaItem.rootPath`).
  final String rootPath;

  /// 1-based chunk number within the rule (`VirtualMediaItem.displayIndex`).
  final int chunkNo;

  /// Member node ids in rule play order. `-1` marks a member that is NOT in this
  /// scenario's stream — the builder keeps it so the row preserves the rule's
  /// chunk shape, and the read side drops it (no node to show).
  final Int32List members;

  /// Non-zero member occurrence indices keyed by member POSITION (absent ⇒ 0).
  final Map<int, int> memberOccurrence;

  /// The group's total duration (`VirtualMediaItem.totalDurationMs`), stored
  /// VERBATIM rather than re-derived from the members' nodes.
  ///
  /// The VM item's own segments are the source of truth: a segment that is not
  /// in the scenario's stream still contributes its duration to the item but has
  /// NO node id here (`-1`), so summing the members' durations would silently
  /// disagree with the value the search list renders.
  final int totalDurationMs;

  /// The resolver's `scopeKey` (`ruleId|rootPath|#chunkNo`).
  String get groupId => '$ruleId|$rootPath|#$chunkNo';

  List<GroupMemberRow> toMemberRows() => [
        for (var i = 0; i < members.length; i++)
          GroupMemberRow(
            inGroupRank: i,
            mediaNodeId: members[i],
            occurrenceIndex: memberOccurrence[i] ?? 0,
          ),
      ];
}

/// The compact per-scenario OVERLAY of the visible-row layer.
///
/// The v43 index stored one row per visible element (plus a member row per group
/// member). Almost all of that is recoverable: a file row's node id is the base
/// order's node at that rank. What is genuinely per-scenario is:
///   - the SHAPE: which base ranks are absorbed into a group row, and where the
///     group rows sit;
///   - the MEMBER layer: each group's rule-ordered members (see [SharedGroupRow]
///     — these depend on the scenario's own item set, so they cannot be shared);
///   - the sparse extras: placeholder identity, occurrence > 0, raw row flags.
class SharedRowOverlay {
  SharedRowOverlay({
    required this.baseCount,
    required this.absorbed,
    required this.groupRows,
    this.placeholders = const {},
    this.occurrence = const {},
    this.flags = const {},
  });

  /// The scenario's accepted base element count (the queue's rank space).
  final int baseCount;

  /// Base ranks absorbed into a group row (they emit no row of their own).
  ///
  /// Stored explicitly rather than derived from the member lists: with
  /// `allowDuplicate` only the FIRST occurrence of a mediaKey is absorbed, so
  /// the set is not a pure function of the member node ids.
  final BitVector absorbed;

  /// Group rows, ascending by [SharedGroupRow.anchorRank].
  final List<SharedGroupRow> groupRows;

  /// Unavailable rows (no `media_nodes` row) keyed by rank: the identity needed
  /// to rebuild the greyed placeholder.
  final Map<int, ({String storageId, String path})> placeholders;

  /// Non-zero file-row occurrence indices keyed by rank (absent ⇒ 0).
  final Map<int, int> occurrence;

  /// Raw row flags keyed by rank (absent ⇒ 0). Kept as the raw value, not
  /// collapsed to the `explicit` bit, so future flag bits cannot be lost.
  final Map<int, int> flags;

  /// Lazy `groupId → group` index for [groupById]; the read path resolves a
  /// page's groups by id, which must not scan every group in the scenario.
  Map<String, SharedGroupRow>? _byId;

  /// Encodes the builder's plan into the compact shape.
  ///
  /// [entries] must be ordered by `anchorRank` and lie within `[0, baseCount)`
  /// (exactly what `ScenarioQueueBuilder.build` produces); [groupsById] supplies
  /// each group's rule/root/chunk and its rule-ordered members.
  factory SharedRowOverlay.fromPlan({
    required int baseCount,
    required List<QueueEntryRow> entries,
    required Map<String, GroupRow> groupsById,
  }) {
    final absorbed = BitVectorBuilder(baseCount);
    final groupRows = <SharedGroupRow>[];
    final placeholders = <int, ({String storageId, String path})>{};
    final occurrence = <int, int>{};
    final flags = <int, int>{};

    var rowIndex = 0;
    for (var rank = 0; rank < baseCount; rank++) {
      final row =
          rowIndex < entries.length && entries[rowIndex].anchorRank == rank
              ? entries[rowIndex]
              : null;
      if (row == null) {
        absorbed.set(rank);
        continue;
      }
      rowIndex++;
      if (row.isGroup) {
        final group = groupsById[row.groupId];
        if (group == null) {
          throw StateError('group ${row.groupId} has no GroupRow');
        }
        final members = group.members;
        final ids = Int32List(members.length);
        final memberOccurrence = <int, int>{};
        for (var i = 0; i < members.length; i++) {
          ids[i] = members[i].mediaNodeId;
          if (members[i].occurrenceIndex != 0) {
            memberOccurrence[i] = members[i].occurrenceIndex;
          }
        }
        groupRows.add(SharedGroupRow(
          anchorRank: rank,
          ruleId: group.ruleId,
          rootPath: group.anchorRoot,
          chunkNo: group.displaySeq,
          members: ids,
          memberOccurrence: memberOccurrence,
          totalDurationMs: group.totalDurationMs,
        ));
        continue;
      }
      if (row.isPlaceholder) {
        placeholders[rank] = (
          storageId: row.placeholderStorageId ?? '',
          path: row.placeholderPath ?? '',
        );
      }
      if (row.occurrenceIndex != 0) occurrence[rank] = row.occurrenceIndex;
      if (row.flags != 0) flags[rank] = row.flags;
    }

    return SharedRowOverlay(
      baseCount: baseCount,
      absorbed: absorbed.build(),
      groupRows: groupRows,
      placeholders: placeholders,
      occurrence: occurrence,
      flags: flags,
    );
  }

  /// Rebuilds the visible rows, taking file node ids from [base].
  List<QueueEntryRow> toEntries(BaseOrderView base) {
    final out = <QueueEntryRow>[];
    for (var rank = 0; rank < baseCount; rank++) {
      final row = rowAt(base, rank);
      if (row != null) out.add(row);
    }
    return out;
  }

  /// The visible row at [rank], or null when [rank] is absorbed into a group
  /// row anchored elsewhere (the read skips those slots).
  ///
  /// This is the read path's per-slot entry point: O(log groups) plus a
  /// [BaseOrderView.nodeIdAt], never a walk over the whole scenario.
  QueueEntryRow? rowAt(BaseOrderView base, int rank) {
    if (rank < 0 || rank >= baseCount) return null;
    if (absorbed[rank]) return null;
    final group = groupAt(rank);
    if (group != null) {
      return QueueEntryRow(
        anchorRank: rank,
        isGroup: true,
        groupId: group.groupId,
      );
    }
    final rowFlags = flags[rank] ?? 0;
    final placeholder = placeholders[rank];
    if (placeholder != null) {
      return QueueEntryRow(
        anchorRank: rank,
        isGroup: false,
        mediaNodeId: -1,
        occurrenceIndex: occurrence[rank] ?? 0,
        flags: rowFlags,
        placeholderStorageId: placeholder.storageId,
        placeholderPath: placeholder.path,
      );
    }
    return QueueEntryRow(
      anchorRank: rank,
      isGroup: false,
      mediaNodeId: base.nodeIdAt(rank),
      occurrenceIndex: occurrence[rank] ?? 0,
      flags: rowFlags,
    );
  }

  /// The visible rows for [ranks], in the same order, skipping absorbed slots.
  List<QueueEntryRow> rowsAt(BaseOrderView base, List<int> ranks) => [
        for (final rank in ranks)
          if (rowAt(base, rank) != null) rowAt(base, rank)!,
      ];

  /// The group row anchored exactly at [rank], or null. [groupRows] is sorted by
  /// anchor, so this is a binary search.
  SharedGroupRow? groupAt(int rank) {
    var lo = 0;
    var hi = groupRows.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final anchor = groupRows[mid].anchorRank;
      if (anchor == rank) return groupRows[mid];
      if (anchor < rank) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return null;
  }

  /// The group with [groupId], or null when this overlay has none.
  SharedGroupRow? groupById(String groupId) {
    final index = _byId ??= {for (final g in groupRows) g.groupId: g};
    return index[groupId];
  }

}
