import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/resolver/vm_preflight.dart';
import 'package:iris/features/virtual_media/resolver/vm_resolver.dart';
import 'package:iris/features/virtual_media/vm_l10n.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/path_conv.dart';

/// Row flag bits persisted with a row (the shared index's `flags` int map).
class QueueRowFlags {
  /// The row is a scenario explicit item (not a source-derived file).
  static const int explicit = 1 << 0;
}

/// The materialized plan for one scenario view: the shared group set, the
/// ordered list rows (file rows + group rows) and the per-row base rank.
class ScenarioQueuePlan {
  /// Shared, rule-dimension groups. Keyed by `groupId` (resolver `scopeKey`).
  final List<GroupRow> groups;

  /// Ordered list rows keyed by `anchorRank` (group row = earliest member).
  final List<QueueEntryRow> entries;

  /// Highest base rank addressed by a row + 1 = the row space size.
  final int totalRanks;

  const ScenarioQueuePlan({
    required this.groups,
    required this.entries,
    required this.totalRanks,
  });

  bool get isEmpty => entries.isEmpty;
}

/// Pure planner: turns an ACCEPTED effective stream into persisted derived
/// index rows. No DB, no IO — unit-testable and reusable by the tag builder.
///
/// Semantics (final):
/// - Groups come from the rule's OWN sort → boundary → caps pipeline
///   ([resolveRuleGroups]); a group is a rule-dimension entity, never a
///   stream-run artifact.
/// - Feasible groups (all members have known positive duration) become ONE
///   group row anchored at `min(baseRank of members)`; their member files do
///   NOT get their own list rows (their ranks are skipped, not padded).
/// - Degraded groups (any member unknown duration) contribute NO group row:
///   their members stay ordinary file rows, matching the overlay's yellow-mark
///   behavior.
/// - Every non-grouped available file row gets a file row at its base rank.
/// - Unavailable placeholders (missing explicit / empty source) always get a
///   file row so the surface still shows the broken scope.
class ScenarioQueueBuilder {
  /// [stream] must already be exclusion/dedup filtered and in resolve order.
  /// [mediaNodeIdOf] maps a stream item to its `media_nodes.id` (nullable when
  /// the file has no stable DB row, e.g. explicit placeholders).
  static ScenarioQueuePlan build({
    required List<EffectivePlaybackItem> stream,
    required List<VirtualMediaRule> rules,
    required int Function(int baseRank, EffectivePlaybackItem item) mediaNodeIdOf,
    AppLocalizations? l10n,
    Set<String> excludedMediaKeys = const <String>{},
  }) {
    if (stream.isEmpty) {
      return const ScenarioQueuePlan(groups: [], entries: [], totalRanks: 0);
    }

    // 1. Stream → VirtualSegments with base rank, keeping only real file rows.
    final rankOf = <String, int>{}; // mediaKey → base rank
    final segs = <VirtualSegment>[];
    for (var rank = 0; rank < stream.length; rank++) {
      final item = stream[rank];
      if (!item.available) continue;
      final f = item.media.maybeMap(file: (f) => f, orElse: () => null);
      if (f == null) continue;
      final key = canonicalMediaKey(f.storageId, f.path, uri: f.uri);
      // First occurrence wins the rank (dedup already removed repeats).
      rankOf.putIfAbsent(key, () => rank);
      segs.add(VirtualSegment(
        mediaKey: key,
        storageId: f.storageId,
        path: f.path,
        name: f.name,
        parentPath: canonicalPath(f.parentPath ?? ''),
        uri: f.uri,
        durationMs: f.durationMs,
        width: f.width,
        height: f.height,
        sizeInBytes: f.sizeInBytes,
        occurrenceIndex: item.occurrenceId.occurrenceIndex,
      ));
    }

    // 2. Rule-authoritative groups + preflight.
    final rawGroups = resolveRuleGroups(
      rules: rules,
      library: segs,
      excludedMediaKeys: excludedMediaKeys,
      l10n: l10n ?? vmLocalizations(),
    );
    final partitioned = partitionVmItems(rawGroups);
    final valid = partitioned.valid;

    // 3. Map canonical mediaKey → (groupId, group) for valid groups only.
    final validGroupByKey = <String, VirtualMediaItem>{};
    for (final g in valid) {
      for (final s in g.segments) {
        validGroupByKey[s.mediaKey] = g;
      }
    }

    // 4. Group rows: anchor at earliest member rank; members in rule order.
    final groups = <GroupRow>[];
    final memberRanks = <int>{};
    final groupAnchorRank = <String, int>{};
    for (final g in valid) {
      var anchor = 1 << 62;
      for (final s in g.segments) {
        final r = rankOf[s.mediaKey];
        if (r != null && r < anchor) anchor = r;
      }
      if (anchor == 1 << 62) continue; // no member present in stream
      groupAnchorRank[g.scopeKey] = anchor;
      groups.add(GroupRow(
        groupId: g.scopeKey,
        ruleId: g.ruleId,
        anchorRoot: g.rootPath,
        displaySeq: g.displayIndex,
        segmentCount: g.segments.length,
        totalDurationMs: g.totalDurationMs,
        totalSizeBytes: g.totalSizeBytes,
        members: [
          for (var i = 0; i < g.segments.length; i++)
            GroupMemberRow(
              inGroupRank: i,
              mediaNodeId: _nodeIdOf(
                rankOf[g.segments[i].mediaKey],
                stream,
                mediaNodeIdOf,
              ),
              occurrenceIndex: g.segments[i].occurrenceIndex,
            ),
        ],
      ));
      for (final s in g.segments) {
        final r = rankOf[s.mediaKey];
        if (r != null) memberRanks.add(r);
      }
    }

    // 5. List rows: group rows at their anchor + file rows for the rest.
    final entries = <QueueEntryRow>[];
    final emittedGroups = <String>{};

    QueueEntryRow fileRow(int rank, EffectivePlaybackItem item) {
      final nodeId = mediaNodeIdOf(rank, item);
      final f = item.media.maybeMap(file: (f) => f, orElse: () => null);
      return QueueEntryRow(
        anchorRank: rank,
        isGroup: false,
        mediaNodeId: nodeId,
        occurrenceIndex: item.occurrenceId.occurrenceIndex,
        flags: item.explicit ? QueueRowFlags.explicit : 0,
        // An unavailable row has no node to reference, so the identity needed
        // to rebuild the greyed placeholder travels with the row itself.
        placeholderStorageId: nodeId < 0 ? f?.storageId : null,
        placeholderPath: nodeId < 0 ? f?.path.join('/') : null,
      );
    }

    for (var rank = 0; rank < stream.length; rank++) {
      final item = stream[rank];
      if (!item.available) {
        entries.add(fileRow(rank, item));
        continue;
      }
      final f = item.media.maybeMap(file: (f) => f, orElse: () => null);
      if (f == null) {
        entries.add(fileRow(rank, item));
        continue;
      }
      final key = canonicalMediaKey(f.storageId, f.path, uri: f.uri);
      final group = validGroupByKey[key];
      if (group != null) {
        // Skip every member rank; emit the group row once at its anchor.
        if (memberRanks.contains(rank)) {
          if (groupAnchorRank[group.scopeKey] == rank &&
              emittedGroups.add(group.scopeKey)) {
            entries.add(QueueEntryRow(
              anchorRank: rank,
              isGroup: true,
              groupId: group.scopeKey,
            ));
          }
          continue;
        }
      }
      entries.add(fileRow(rank, item));
    }

    return ScenarioQueuePlan(
      groups: groups,
      entries: entries,
      totalRanks: stream.length,
    );
  }

  static int _nodeIdOf(
    int? baseRank,
    List<EffectivePlaybackItem> stream,
    int Function(int, EffectivePlaybackItem) mediaNodeIdOf,
  ) {
    if (baseRank == null) return -1;
    return mediaNodeIdOf(baseRank, stream[baseRank]);
  }
}
