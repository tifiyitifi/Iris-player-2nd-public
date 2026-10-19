import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/play_queue/engine/shuffle_engine.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/model/domain/tag_media_counts.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_member.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_view_state.dart';
import 'package:iris/features/tag_play/model/enum/tag_play_sort_field.dart';
import 'package:iris/features/virtual_media/resolver/vm_overlay.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/utils/path_conv.dart';

/// Abstraction over "collect the scenario's effective stream" so the tag view
/// can be resolved against any scenario-like source in tests.
abstract class ScenarioEffectiveItemsSource {
  Future<List<EffectivePlaybackItem>> collect({
    required String scenarioId,
    Set<String>? mediaKeyFilter,
  });
}

/// Production adapter over [ScenarioResolver.collectEffectiveItems].
class ResolverEffectiveItemsSource implements ScenarioEffectiveItemsSource {
  final ScenarioResolver resolver;

  const ResolverEffectiveItemsSource(this.resolver);

  @override
  Future<List<EffectivePlaybackItem>> collect({
    required String scenarioId,
    Set<String>? mediaKeyFilter,
  }) {
    return resolver.collectEffectiveItems(
      scenarioId: scenarioId,
      mediaKeyFilter: mediaKeyFilter,
    );
  }
}

/// Optional index-backed replacement for [ScenarioEffectiveItemsSource].
///
/// When available, mode-1 tag views are built by an index join (members ×
/// scenario rows) instead of the O(N) effective-stream walk. Returns null when
/// the index is absent/stale so callers fall back to [source].
abstract class IndexedTagItemsSource {
  Future<List<EffectivePlaybackItem>?> collectIndexed({
    required String scenarioId,
    required int tagId,
    DateTime? addedAfter,
  });
}

/// Production adapter over [ScenarioResolver.resolveTagViewIndexed].
class ResolverIndexedTagItemsSource implements IndexedTagItemsSource {
  final ScenarioResolver resolver;

  const ResolverIndexedTagItemsSource(this.resolver);

  @override
  Future<List<EffectivePlaybackItem>?> collectIndexed({
    required String scenarioId,
    required int tagId,
    DateTime? addedAfter,
  }) {
    return resolver.resolveTagViewIndexed(
      scenarioId: scenarioId,
      tagId: tagId,
      addedAfter: addedAfter,
    );
  }
}

/// One resolved tag play view: the intersection of the current scenario's
/// effective stream with a tag's active membership, ordered by the TAG'S OWN
/// strategy (never the scenario's order) — plus the persisted view state used.
class TagViewSnapshot {
  final int tagId;
  final List<EffectivePlaybackItem> items;
  final TagPlayViewState state;

  /// The tag's own jump-back window. Null = always attempt to resume the
  /// bookmarked video; non-null bounds the resume attempt to this window.
  final Duration? resumeWindow;

  /// The view's stream BEFORE the display overlay merged virtual groups.
  ///
  /// Virtual Media sessions must derive their grouping from this raw stream
  /// (the same derivation the list display used), so a merged entry maps
  /// back to its full group. Optionally false-y when empty.
  final List<EffectivePlaybackItem> vmStream;

  /// The merge groups resolved for [vmStream] during this resolve, carried so
  /// the playback side reuses them instead of paying a second O(stream × rules)
  /// regex pass per feed (performance contract). Null when no rule applied.
  final VmStreamGroups? vmGroups;

  /// Physical file key (`storageId:path`) → the index of the display item that
  /// covers it. A merged display item maps ALL of its segments' keys to its
  /// own index, so a per-context bookmark (a real file) locates its item in
  /// O(1) even when the group was recomposed.
  final Map<String, int> itemIndexByFileKey;

  const TagViewSnapshot({
    required this.tagId,
    required this.items,
    required this.state,
    this.resumeWindow,
    this.vmStream = const [],
    this.vmGroups,
    this.itemIndexByFileKey = const {},
  });

  bool get isEmpty => items.isEmpty;
  int get length => items.length;

  /// Index of [canonicalMediaKey] (`storageId:canonicalPath`) in this view,
  /// or null when absent.
  int? indexOfKey(String canonicalMediaKey) {
    for (var i = 0; i < items.length; i++) {
      if (keyOf(items[i]) == canonicalMediaKey) return i;
    }
    return null;
  }

  /// Index of the display item covering the physical [fileMediaKey], or null.
  /// Unlike [indexOfKey] this resolves a real file that sits INSIDE a merged
  /// group (the bookmark identity), not just the group's representative.
  int? indexOfFileKey(String fileMediaKey) => itemIndexByFileKey[fileMediaKey];
}

/// Looks up media nodes by canonical media key (`storageId:path`); vanished
/// files are absent from the result.
typedef MediaNodesByKeys = Future<List<MediaNode>> Function(Set<String> keys);

/// Canonical view-side identity of a resolved item. Scenario producers may
/// surface rooted paths (`/a.mp4`, `//a/b`); membership rows are canonical —
/// every comparison goes through [canonicalKey].
String keyOf(EffectivePlaybackItem e) =>
    canonicalKey(e.occurrenceId.storageId, e.occurrenceId.path);

/// Resolves one tag's play view.
///
/// Pipeline: active members → canonical key set → scenario effective stream ∩
/// keys → sort by the tag's own spec (addedAt desc by default) → optional
/// Feistel shuffle over the filtered count. Memory is bounded by
/// min(membership, effective), not library size.
class TagViewResolver {
  final ScenarioEffectiveItemsSource source;
  final TagPlayRepository repo;

  /// Optional index-backed source for mode-1 (scenario ∩ tag) views.
  final IndexedTagItemsSource? indexedSource;

  /// Node lookup used by the "ignore scenario" branch; injectable so tests
  /// never need a live media-node table. Kept nullable (not defaulted at
  /// construction) so the DB handle is only touched on the ignore path.
  final MediaNodesByKeys? _nodesByKeys;

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  static TagPlayViewState defaultStateFor(int tagId) =>
      TagPlayViewState(tagId: tagId);

  TagViewResolver({
    required this.source,
    required this.repo,
    this.indexedSource,
    MediaNodesByKeys? nodesByKeys,
  }) : _nodesByKeys = nodesByKeys;

  Future<List<MediaNode>> _lookupNodes(Set<String> keys) =>
      (_nodesByKeys ?? DbModule.mediaNodeRepo.nodesByMediaKeys)(keys);

  Future<TagViewSnapshot> resolve({
    required int tagId,
    required String scenarioId,
    bool ignoreScenario = false,
    bool withVmOverlay = true,
  }) async {
    final tag = await repo.tagById(tagId);
    final members = await repo.activeMembersOf(tagId);
    final state = (await repo.stateOf(tagId)) ?? defaultStateFor(tagId);

    if (members.isEmpty || (!ignoreScenario && scenarioId.isEmpty)) {
      return TagViewSnapshot(
        tagId: tagId,
        items: const [],
        state: state,
        resumeWindow: tag?.resumeWindow,
      );
    }

    // Member lookup keyed exactly like view-side identities (canonical form).
    // [canonicalKey] — NOT a raw `'$storageId:$path'` interpolation: a
    // pre-normalization row (a leading slash, a `//` collapse) would otherwise
    // build a key that never matches [keyOf]'s canonical one, silently
    // dropping the member from the addedAt lookup (epoch fallback) and, on the
    // ignore-scenario path, from the stream itself.
    final addedAtByKey = <String, DateTime>{
      for (final m in members) canonicalKey(m.storageId, m.path): m.addedAt,
    };

    // "Ignore scenario": the tag's OWN membership is the stream — no scenario
    // sources, no scenario excludes. Members whose file vanished are skipped.
    final List<EffectivePlaybackItem> effective;
    if (ignoreScenario) {
      effective = await _collectMembersOnly(members, scenarioId);
    } else {
      // Index-backed path: an index join (members × scenario rows) avoids the
      // O(N) effective-stream walk. Falls back to the source on no index.
      List<EffectivePlaybackItem>? indexed;
      final idxSource = indexedSource;
      if (idxSource != null) {
        indexed = await idxSource.collectIndexed(
          scenarioId: scenarioId,
          tagId: tagId,
          addedAfter: null,
        );
      }
      if (indexed != null) {
        effective = indexed;
      } else {
        effective = await source.collect(
          scenarioId: scenarioId,
          mediaKeyFilter: addedAtByKey.keys.toSet(),
        );
      }
    }

    final list = [...effective];
    final factor = state.sortDirection == SortDirection.asc ? 1 : -1;
    int compare(EffectivePlaybackItem a, EffectivePlaybackItem b) {
      switch (state.sortField) {
        case TagPlaySortField.name:
          return factor *
              a.media.name.toLowerCase().compareTo(b.media.name.toLowerCase());
        case TagPlaySortField.tagAddedAt:
          final av = addedAtByKey[keyOf(a)] ?? _epoch;
          final bv = addedAtByKey[keyOf(b)] ?? _epoch;
          return factor * av.compareTo(bv);
      }
    }

    list.sort(compare);
    var resolved = List<EffectivePlaybackItem>.from(list);

    // Shuffle applies ON TOP of the base order (mirrors the scenario model:
    // fixed base order + deterministic permutation). desc walks it reversed.
    if (state.order == PlaybackOrder.shuffled &&
        state.shuffleSeed != null &&
        resolved.length > 1) {
      final engine = FeistelShuffle(state.shuffleSeed!, resolved.length);
      final reverse = state.sortDirection == SortDirection.desc;
      final shuffled = <EffectivePlaybackItem>[];
      for (var v = 0; v < resolved.length; v++) {
        final real = reverse
            ? engine.forward(resolved.length - 1 - v)
            : engine.forward(v);
        shuffled.add(resolved[real]);
      }
      resolved = shuffled;
    }

    // `virtualIndex` must be the item's position in THIS resolved stream: the
    // tag's own sort/shuffle just reordered the list, so the pre-sort index
    // (scenario order, or membership order on the ignore-scenario path) no
    // longer describes where the item sits. Every dense-list consumer relies on
    // the invariant `virtualIndex == position` — notably the 副音 runtime, which
    // indexes its window by it (a stale index made a tapped row play another
    // file).
    resolved = [
      for (var i = 0; i < resolved.length; i++)
        resolved[i].copyWith(virtualIndex: i),
    ];

    // Keep the pre-overlay stream: the playback side derives its VM session
    // grouping from it (a merged display entry must map back to its group).
    final vmStream = List<EffectivePlaybackItem>.from(resolved);

    // VM merge (orthogonal, scenario-first): groups derive from THIS tag
    // view's own filtered stream — tag selects, VM organizes ("职责独立").
    // Resolved ONCE and carried on the snapshot so the playback feed reuses
    // them (a second `resolveGroupsForStream` per feed was the dominant
    // per-tap regex cost). 副音 opts out (its list must stay real single files).
    VmStreamGroups? groups;
    if (withVmOverlay) {
      final vmRules = await VirtualMediaService.instance.enabledRules();
      if (vmRules.isNotEmpty) {
        groups = resolveGroupsForStream(resolved, vmRules);
        if (groups.isNotEmpty) {
          resolved = applyVmOverlay(resolved, groups.byKey);
        }
      }
    }

    // file→item index for the per-context bookmark: `indexOfKey` only knows
    // display representatives, but a bookmark stores a REAL file that may sit
    // inside a merged group. Mapping every segment key of each group to its
    // display index keeps relocation O(1) across recompositions.
    final fileIndex = <String, int>{};
    final byKey = groups?.byKey;
    for (var i = 0; i < resolved.length; i++) {
      final key = keyOf(resolved[i]);
      fileIndex[key] = i;
      final group = byKey?[key];
      if (group != null) {
        for (final seg in group.segments) {
          fileIndex[seg.mediaKey] = i;
        }
      }
    }

    return TagViewSnapshot(
      tagId: tagId,
      items: List.unmodifiable(resolved),
      state: state,
      resumeWindow: tag?.resumeWindow,
      vmStream: List.unmodifiable(vmStream),
      vmGroups: groups,
      itemIndexByFileKey: Map.unmodifiable(fileIndex),
    );
  }

  /// Builds the tag's stream directly from its membership (no scenario):
  /// a batch node lookup by canonical media key, in membership order.
  /// Vanished files are silently skipped.
  Future<List<EffectivePlaybackItem>> _collectMembersOnly(
    List<TagPlayMember> members,
    String scenarioId,
  ) async {
    // Query and lookup on the SAME canonical axis the node map is built on:
    // a raw `'$storageId:$path'` lookup misses a legacy non-canonical member
    // row even though the canonical-keyed node was found (see [canonicalKey]).
    final keys = <String>{
      for (final m in members) canonicalKey(m.storageId, m.path),
    };
    final nodes = await _lookupNodes(keys);
    final byKey = {
      for (final node in nodes)
        canonicalKey(node.storageId, node.path.join('/')): node,
    };
    final out = <EffectivePlaybackItem>[];
    for (final m in members) {
      final node = byKey[canonicalKey(m.storageId, m.path)];
      if (node == null) continue;
      out.add(EffectivePlaybackItem(
        media: node,
        scenarioId: scenarioId,
        explicit: true,
        virtualIndex: out.length,
        occurrenceId: PlaybackOccurrenceId(
          storageId: m.storageId,
          path: m.path,
        ),
      ));
    }
    return out;
  }
}

/// Computes, for EVERY tag, how many of its active members are present in the
/// active scenario (`scenarioCount`) versus its whole membership
/// (`totalCount`). One membership read backs the whole sheet, rather than a
/// resolve per tag.
class TagMediaCountResolver {
  final ScenarioEffectiveItemsSource source;
  final TagPlayRepository repo;

  /// Optional shared-index bridge: its counts answer every tag in one pass over
  /// the persisted index. When it declines (the scenario is not representable,
  /// the switch is off, or the environment is store-free) the Dart-side
  /// collect + set-intersection below serves instead — slower, never wrong.
  final ScenarioResolver? resolver;

  const TagMediaCountResolver({
    required this.source,
    required this.repo,
    this.resolver,
  });

  Future<Map<int, TagMediaCounts>> resolveAll({
    required String scenarioId,
  }) async {
    if (scenarioId.isNotEmpty) {
      final intersect = await resolver?.tagIntersectionCountsFor(scenarioId);
      if (intersect != null) {
        final totals = await repo.memberCountsByTag();
        return {
          for (final entry in totals.entries)
            entry.key: TagMediaCounts(
              scenarioCount: intersect[entry.key] ?? 0,
              totalCount: entry.value,
            ),
        };
      }
    }

    final membersByTag = await repo.activeMembersByTag();

    Set<String> scenarioKeys = const {};
    if (scenarioId.isNotEmpty) {
      final effective = await source.collect(scenarioId: scenarioId);
      scenarioKeys = {for (final item in effective) keyOf(item)};
    }

    final out = <int, TagMediaCounts>{};
    for (final entry in membersByTag.entries) {
      final members = entry.value;
      var inScenario = 0;
      if (scenarioKeys.isNotEmpty) {
        for (final m in members) {
          // Canonical, like [keyOf] on the scenario side — a raw interpolation
          // misses non-canonical member rows and undercounts.
          if (scenarioKeys.contains(canonicalKey(m.storageId, m.path))) {
            inScenario++;
          }
        }
      }
      out[entry.key] = TagMediaCounts(
        scenarioCount: inScenario,
        totalCount: members.length,
      );
    }
    return out;
  }
}
