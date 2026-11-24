import 'package:iris/features/fake_cut/services/fake_cut_discovery.dart';
import 'package:iris/features/fake_cut/services/fake_cut_edl_builder.dart';
import 'package:iris/features/fake_cut/services/fake_cut_project_index.dart';
import 'package:iris/features/fake_cut/store/use_fake_cut_store.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/models/store/app_state.dart' show PlayerBackend;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:path/path.dart' as p;

/// Virtual-merge admission for a video that has a sibling LosslessCut `.llc`.
///
/// The ACTIVE plan joins a merged group whatever its range count (ADR 0037): the
/// segment plays that plan's EDL and its duration is the plan's total CUT
/// length. No active plan, an unusable project, a non-local row or a backend
/// without mpv EDL merges the file as its normal source.
///
/// The criterion is the ACTIVE plan, not merely "a project exists" (ADR 0037):
/// a merge follows the same cut on/off state the player shows, so closing the
/// cut makes the segment play its source again and activating it makes the
/// segment play that cut. A bound-but-inactive project never participates.
/// Freshness is explicit — a newly added/removed `.llc` only counts after
/// `FakeCutProjectIndex.invalidate()` (a completed media rescan, ADR 0033, or
/// the 虚拟剪播 tab's refresh button).
///
/// The grouping functions stay PURE: these helpers resolve the filesystem answer
/// once per pass and the callers inject it into `resolveGroupsForStream` /
/// `ScenarioQueueBuilder.build` as `cutRanges`.
///
/// What one stream pass found: the cut ranges that may MERGE.
class VmCutMergeInfo {
  const VmCutMergeInfo({required this.rangesByKey});

  static const VmCutMergeInfo empty = VmCutMergeInfo(
    rangesByKey: <String, VmCutRange>{},
  );

  /// `mediaKey → kept ranges` for segments that play their cut inside a merge.
  final Map<String, VmCutRange> rangesByKey;
}

/// Plan scanner seam: production reads the sibling `.llc` files; tests inject a
/// prepared source list so no filesystem is touched.
typedef VmCutPlanScanner = Future<List<FakeCutPlanSource>> Function(
  String videoPath,
  int? sourceDurationMs,
);

/// "Which media keys own a project" seam; tests replace the filesystem pass.
typedef VmCutProjectKeys = Future<Set<String>> Function(
  Iterable<FakeCutProjectQuery>,
);

/// The active 虚拟剪播 plan paths (`mediaKey → .llc`), so a merge plays the plan
/// the user explicitly chose when a video owns several. Empty outside a
/// running UI (unit tests, early startup).
Map<String, String> activeCutPlanPaths() {
  try {
    return useFakeCutStore().state.activePaths;
  } catch (_) {
    return const <String, String>{};
  }
}

/// Whether the current backend can open an mpv EDL. Defaults to supported when
/// no store exists yet (unit tests, early startup).
bool cutMergeSupportedNow() {
  try {
    return useAppStore().state.playerBackend == PlayerBackend.mediaKit;
  } catch (_) {
    return true;
  }
}

/// Resolves the USER'S ACTIVE plan to the kept ranges that may merge.
///
/// There is deliberately NO fallback to another bound plan (ADR 0032): the
/// merge follows the same "cut on/off" state the player shows, so a file whose
/// cut is closed participates as its SOURCE (`preferredPath == null`).
///
/// ANY number of kept ranges merges (ADR 0037): the segment's timeline is the
/// plan's concatenated cut timeline, so reordered/repeated/overlapping ranges
/// are representable. An unusable (unparseable/empty) project is "play the
/// source", exactly like standalone playback.
VmCutRange? vmCutRangeFromSources(
  List<FakeCutPlanSource> sources, {
  String? preferredPath,
}) {
  if (preferredPath == null) return null;
  for (final FakeCutPlanSource source in sources) {
    if (!samePlanPath(source.path, preferredPath)) continue;
    return _rangeOf(source);
  }
  return null;
}

/// Whether two spellings name the same `.llc`.
///
/// The active plan path reaches us through the PLAYER (`FileItem.uri`) while the
/// scanned source path comes from the project index (`Directory.list`); the two
/// may differ in separator or case on Windows. An exact string compare silently
/// ignored an activated cut in the merge, which is exactly the "tab says on,
/// playback says source" mismatch the register keeps fighting.
bool samePlanPath(String a, String b) => p.equals(a, b);

VmCutRange? _rangeOf(FakeCutPlanSource source) {
  if (!source.bound || !source.usable) return null;
  final plan = source.plan;
  if (plan == null || plan.isEmpty) return null;
  final List<VmCutKeep> keeps = <VmCutKeep>[
    for (final segment in plan.segments)
      if (segment.durationMs > 0)
        VmCutKeep(
          sourceStartMs: segment.startMs,
          durationMs: segment.durationMs,
        ),
  ];
  if (keeps.isEmpty) return null; // degenerate → source
  return VmCutRange(
    planPath: source.path,
    // The content signature the group is built with; the player compares it
    // with the plan it opens, so an edit on disk re-derives the merge (ADR 0034).
    planSignature: fakeCutPlanSignature(plan),
    keeps: keeps,
  );
}

/// One pass over a stream: which members may merge as a cut.
///
/// [enabled] is false on a backend without mpv EDL (fvp): the old exclusion is
/// returned so those files keep their single rows instead of merging into a
/// timeline the player cannot honour.
Future<VmCutMergeInfo> vmCutMergeInfoForStream(
  Iterable<EffectivePlaybackItem> stream, {
  FakeCutProjectIndex? index,
  VmCutPlanScanner? scanner,
  VmCutProjectKeys? projectKeys,
  Map<String, String> preferredPlanPaths = const <String, String>{},
  bool? enabled,
}) async {
  final List<_CutQuery> queries = <_CutQuery>[];
  for (final EffectivePlaybackItem item in stream) {
    if (!item.available) continue;
    final f = item.media.maybeMap(file: (f) => f, orElse: () => null);
    if (f == null) continue;
    queries.add((
      mediaKey: canonicalMediaKey(f.storageId, f.path, uri: f.uri),
      name: f.name,
      uri: nodePlayableUri(f.path, uri: f.uri),
      durationMs: f.durationMs,
    ));
  }
  return _cutInfoForQueries(
    queries,
    index: index,
    scanner: scanner,
    projectKeys: projectKeys,
    preferredPlanPaths: preferredPlanPaths,
    enabled: enabled,
  );
}

/// Segment form for the resolver's preview library (virtual_media manager).
Future<VmCutMergeInfo> vmCutMergeInfo(
  Iterable<VirtualSegment> segments, {
  FakeCutProjectIndex? index,
  VmCutPlanScanner? scanner,
  VmCutProjectKeys? projectKeys,
  Map<String, String> preferredPlanPaths = const <String, String>{},
  bool? enabled,
}) async {
  final List<_CutQuery> queries = <_CutQuery>[
    for (final VirtualSegment seg in segments)
      (
        mediaKey: seg.mediaKey,
        name: seg.name,
        // `uri` is only carried for SAF rows; ordinary filesystem rows resolve
        // through the canonical path (already absolute).
        uri: nodePlayableUri(seg.path, uri: seg.uri),
        durationMs: seg.durationMs,
      ),
  ];
  return _cutInfoForQueries(
    queries,
    index: index,
    scanner: scanner,
    projectKeys: projectKeys,
    preferredPlanPaths: preferredPlanPaths,
    enabled: enabled,
  );
}

typedef _CutQuery = ({
  String mediaKey,
  String name,
  String uri,
  int? durationMs,
});

Future<VmCutMergeInfo> _cutInfoForQueries(
  List<_CutQuery> queries, {
  FakeCutProjectIndex? index,
  VmCutPlanScanner? scanner,
  VmCutProjectKeys? projectKeys,
  Map<String, String> preferredPlanPaths = const <String, String>{},
  bool? enabled,
}) async {
  if (queries.isEmpty) return VmCutMergeInfo.empty;

  final List<FakeCutProjectQuery> projectQueries = <FakeCutProjectQuery>[
    for (final q in queries) (mediaKey: q.mediaKey, name: q.name, uri: q.uri),
  ];
  final Set<String> withProject = await (projectKeys ??
      (index ?? FakeCutProjectIndex.instance)
          .mediaKeysWithProject)(projectQueries);
  if (withProject.isEmpty) return VmCutMergeInfo.empty;

  // A backend without EDL cannot play the cut anywhere, so the file merges as
  // its source instead of disappearing from the group (ADR 0037).
  if (!(enabled ?? cutMergeSupportedNow())) return VmCutMergeInfo.empty;

  final VmCutPlanScanner scan = scanner ?? _defaultCutScan;
  final Map<String, VmCutRange> ranges = <String, VmCutRange>{};
  for (final q in queries) {
    if (!withProject.contains(q.mediaKey)) continue;
    final String? preferred = preferredPlanPaths[q.mediaKey];
    // Cut closed (or never activated): source segment, still mergeable.
    if (preferred == null) continue;
    List<FakeCutPlanSource> sources;
    try {
      sources = await scan(q.uri, q.durationMs);
    } catch (e) {
      // A failed scan cannot prove the plan is unusable. Treat it like "no
      // active plan" (source) rather than dropping the file from the merge.
      continue;
    }
    FakeCutPlanSource? chosen;
    for (final FakeCutPlanSource source in sources) {
      if (!samePlanPath(source.path, preferred)) continue;
      chosen = source;
      break;
    }
    // The remembered plan is no longer bound to this video (stale active path,
    // renamed source) or cannot be parsed at all: the player's
    // `ensureActivePlan` forgets it and plays the source, so the merge must do
    // the same instead of dropping the file.
    if (chosen == null || !chosen.usable) continue;
    final VmCutRange? range = _rangeOf(chosen);
    if (range != null) ranges[q.mediaKey] = range;
  }
  return VmCutMergeInfo(rangesByKey: ranges);
}

Future<List<FakeCutPlanSource>> _defaultCutScan(
  String videoPath,
  int? sourceDurationMs,
) =>
    FakeCutDiscovery.scan(
      videoPath: videoPath,
      sourceDurationMs: sourceDurationMs,
    );
