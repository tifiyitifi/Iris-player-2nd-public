import 'package:iris/features/fake_cut/services/fake_cut_project_index.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/utils/path_conv.dart';

/// Virtual-merge exclusion: a video that has a sibling LosslessCut `.llc`
/// project never joins a merged group.
///
/// WHY exclude the FILE and not the merge: 简播 turns that one video into a fake
/// cut. Merging it with its neighbours would either hide the cut (the merged
/// row is not the cut) or produce a merged timeline whose segments disagree with
/// what the user asked to watch. Skipping just that member keeps every other
/// file merging exactly as before — the rule keeps its shape, only the members
/// it may claim change (PRODUCT TRADEOFF: a `每 N 个文件` boundary rule can shift
/// its chunks once a member is skipped).
///
/// The criterion is the FILESYSTEM (a project exists for this video), not "the
/// user activated a plan": grouping must not depend on per-window runtime state,
/// and a video the user never opens in 简播 still has an authored cut that the
/// merged playback would ignore. Freshness is explicit — a `.llc` created after
/// a group was built only counts after `FakeCutProjectIndex.invalidate()`
/// (the 简播 tab's refresh button).
///
/// The grouping functions stay PURE: these helpers resolve the filesystem answer
/// once per pass and the callers inject it into `resolveRuleGroups` /
/// `resolveGroupsForStream`.
Future<Set<String>> vmFakeCutExclusionKeys(
  Iterable<VirtualSegment> segments, {
  FakeCutProjectIndex? index,
}) =>
    (index ?? FakeCutProjectIndex.instance).mediaKeysWithProject(
      <FakeCutProjectQuery>[
        for (final VirtualSegment segment in segments)
          (
            mediaKey: segment.mediaKey,
            name: segment.name,
            // `uri` is only carried for SAF rows; ordinary filesystem rows
            // resolve through the canonical path (already absolute).
            uri: nodePlayableUri(segment.path, uri: segment.uri),
          ),
      ],
    );

/// [vmFakeCutExclusionKeys] for a resolved playback stream — the form both the
/// runtime group derivation and the persisted queue build already hold.
Future<Set<String>> vmFakeCutExclusionKeysForStream(
  Iterable<EffectivePlaybackItem> stream, {
  FakeCutProjectIndex? index,
}) {
  final List<FakeCutProjectQuery> queries = <FakeCutProjectQuery>[];
  for (final EffectivePlaybackItem item in stream) {
    // Same filter the group derivation applies: unavailable placeholders
    // (missing explicit items / empty sources) and directory rows never merge.
    if (!item.available) continue;
    final f = item.media.maybeMap(file: (f) => f, orElse: () => null);
    if (f == null) continue;
    queries.add((
      mediaKey: canonicalMediaKey(f.storageId, f.path, uri: f.uri),
      name: f.name,
      uri: nodePlayableUri(f.path, uri: f.uri),
    ));
  }
  return (index ?? FakeCutProjectIndex.instance)
      .mediaKeysWithProject(queries);
}
