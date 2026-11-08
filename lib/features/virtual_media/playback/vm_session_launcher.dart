import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/resolver/vm_resume_target.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/utils/path_conv.dart';

/// A fully-resolved VM session start: the sibling queue (all in-order
/// virtual bodies of the entry's rule), the entry's position inside it, and
/// the resume target decoded from the watched files' own progress.
///
/// Produced by [planVmSessionStart]; consumed by
/// [VirtualMediaController.startSession] callers so every feed path that can
/// land on a virtual body shares ONE merge derivation.
class VmSessionStartPlan {
  final List<VirtualMediaItem> queue;
  final int queueIndex;
  final int segmentIndex;

  /// Intra-segment open offset. The session opens at the most-recently-watched
  /// segment's own saved position; with no usable progress it is 0 so legacy
  /// per-file DB resume never leaks into the virtual timeline.
  final int? initialLocalMs;

  const VmSessionStartPlan({
    required this.queue,
    required this.queueIndex,
    required this.segmentIndex,
    required this.initialLocalMs,
  });
}

/// Decides whether [storageId]/[path] — an entry of the scenario's effective
/// [stream] that is ABOUT to be fed to the player — starts (or re-enters) a
/// Virtual Media session instead of playing as an ordinary single file.
///
/// Pure derivation over already-fetched data (enabled rules + effective
/// stream + per-file progress), so it is unit-testable without DB wiring and
/// shared by every feed outlet:
/// - `ScenarioPlaybackProvider.play` (list tap / first open),
/// - `ScenarioPlaybackProvider.advanceEntry` (next/prev/wrap/completion),
/// - `ScenarioResolvedActions._restoreVirtualSession` (cold-start resume),
/// - `TagPlayController._startVmSession` (tag view feed).
///
/// [targetMediaKey] names the physical file the caller wants the session to
/// open on (a per-context bookmark). When it is one of the group's segments,
/// that segment and its OWN saved progress win over the recency fallback —
/// this is what keeps a stored "last real file" stable even after the group
/// is recomposed. When absent/not a member, the most-recently-watched segment
/// decides (see [resolveVmResumeByProgress]).
///
/// [preferRecency] flips that priority for the COLD-START restore, where the
/// bookmark is only the scenario's current ROW (see the groups variant below).
///
/// Returns null when the entry must fall through to single-file playback:
/// no covering rule, preflight-degraded member (`failByKey`), or an
/// infeasible group. Callers log the ordinary-play decision themselves when
/// they need attribution.
VmSessionStartPlan? planVmSessionStart({
  required String storageId,
  required String path,
  required List<VirtualMediaRule> rules,
  required List<EffectivePlaybackItem> stream,
  Map<String, SegmentProgress> progressByKey = const {},
  String? targetMediaKey,
  int? targetOccurrenceIndex,
  bool preferRecency = false,
  Set<String> excludedMediaKeys = const <String>{},
}) {
  if (rules.isEmpty || stream.isEmpty) return null;
  return planVmSessionStartFromGroups(
    storageId: storageId,
    path: path,
    groups: resolveGroupsForStream(stream, rules,
        excludedMediaKeys: excludedMediaKeys),
    progressByKey: progressByKey,
    targetMediaKey: targetMediaKey,
    targetOccurrenceIndex: targetOccurrenceIndex,
    preferRecency: preferRecency,
  );
}

/// Groups-reusing variant: callers that already resolved [groups] for
/// fail-attribution pass them in instead of paying a second
/// `resolveGroupsForStream` (O(stream × rules) with regex matching).
///
/// [preferRecency] is the COLD-START reading of the pair: the bookmark names the
/// scenario's current ROW (a group's anchor, not necessarily the file the user
/// last watched), so recency must decide the segment. The bookmark is still
/// honoured when it names the SAME file as the recency winner, which is what
/// keeps a duplicated file (scenario `allowDuplicate`) on the persisted COPY
/// instead of collapsing to the first one — the two signals only disagree about
/// the occurrence there. An explicit pick (child-list tap / tag bookmark) keeps
/// the default `false`: it knows the exact file the user asked for.
VmSessionStartPlan? planVmSessionStartFromGroups({
  required String storageId,
  required String path,
  required VmStreamGroups groups,
  Map<String, SegmentProgress> progressByKey = const {},
  String? targetMediaKey,
  int? targetOccurrenceIndex,
  bool preferRecency = false,
}) {
  final entryKey = canonicalKey(storageId, path);
  // Preflight-degraded members can never merge — ordinary single play.
  if (groups.failByKey.containsKey(entryKey)) return null;
  final group = groups.byKey[entryKey];
  if (group == null || group.segments.isEmpty || group.totalDurationMs <= 0) {
    return null;
  }
  // Sibling queue = the DISPLAYED merged order across ALL rules (inOrder is
  // the stream-ordered resolve; the overlay collapses exactly these runs).
  // Filtering by ruleId would drop other rules' rows that sit between this
  // rule's bodies, so natural auto-advance would skip a row the user sees.
  final queue = groups.inOrder;
  final idx = queue.indexWhere((i) => i.scopeKey == group.scopeKey);
  if (idx < 0) return null;

  int segIdx;
  int? localMs;
  final targetIdx = targetMediaKey == null
      ? null
      : group.indexOfSegment(targetMediaKey, targetOccurrenceIndex);
  if (targetIdx == null) {
    (segIdx, localMs) = resolveVmResumeByProgress(group, progressByKey);
  } else if (!preferRecency) {
    // Bookmark hit: open the stored file and let its own `media_nodes`
    // progress steer the intra-segment offset (initialLocalMs null → the
    // player's shared resume path reads the file's saved position). Skipping
    // the recency lookup here is both faster and more faithful than
    // reconstructing a group-timeline offset.
    segIdx = targetIdx;
    localMs = null;
  } else {
    final (recentIdx, recentLocal) =
        resolveVmResumeByProgress(group, progressByKey);
    if (group.segments[recentIdx].mediaKey ==
        group.segments[targetIdx].mediaKey) {
      // Same physical file: only the COPY differs, so the bookmark wins and the
      // file's own saved position still steers the offset.
      segIdx = targetIdx;
      localMs = null;
    } else {
      segIdx = recentIdx;
      localMs = recentLocal;
    }
  }
  return VmSessionStartPlan(
    queue: queue,
    queueIndex: idx,
    segmentIndex: segIdx,
    initialLocalMs: localMs,
  );
}

/// Shared empty progress map for callers that already resolved a bookmark
/// target and deliberately skip the per-file DB read (the planner never reads
/// progress for a located target).
const Map<String, SegmentProgress> noSegmentProgress = {};

/// Reads the per-file progress of every segment in [group] from the media
/// nodes table (identity-keyed, so it survives re-resolutions). Failures
/// degrade to "no progress" — the session then opens at segment 0.
Future<Map<String, SegmentProgress>> loadSegmentProgress(
  VirtualMediaItem group,
) async {
  final keys = {for (final seg in group.segments) seg.mediaKey};
  if (keys.isEmpty) return const {};
  try {
    return await DbModule.mediaNodeRepo.progressForMediaKeys(keys);
  } catch (_) {
    return const {};
  }
}
