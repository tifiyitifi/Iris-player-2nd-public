import 'package:iris/features/virtual_media/model/domain/vm_item.dart';

/// Per-file playback progress of one physical segment, as stored on the
/// segment's own `media_nodes` row. Progress is keyed by FILE identity, so a
/// virtual group can be relocated across re-resolutions (rule edits, tag
/// switches, chunk reshapes) that change the positional `scopeKey`.
///
/// A structural record so the media-library repository can produce it without
/// importing this feature (feature layering stays one-way).
typedef SegmentProgress = ({
  int? positionMs,
  bool completed,
  DateTime? lastPlayedAt,
});

/// Jump-to-end guard: a position within this margin of the end resumes that
/// much before the end instead of at the very tail.
const int vmResumeEndSafetyMs = 5000;

/// Resolves the resume target of a virtual group by the segment that was
/// watched MOST RECENTLY.
///
/// WHY BY FILE RECENCY (design intent — do not "optimize" this into a
/// positional lookup):
/// A merged group is a SYNTHETIC video the app invents on every resolve. Its
/// effective stream is recomputed whenever anything upstream moves (rule
/// edits, source add/remove, scenario/tag switch, shuffle, membership
/// changes), so the group's positional `scopeKey` and even its member list are
/// ephemeral: a re-resolve can shift, renumber or split a group without any
/// file moving. Only the FILE identity survives that — its `media_nodes` row
/// is keyed by `storageId:path` and keeps the real "last played" time.
/// Resuming by the newest `lastPlayedAt` therefore returns the user to the
/// actual file they were watching, and that file's own saved position is the
/// only offset that stays meaningful when the group's timeline changes.
/// (The legacy positional anchor in `virtual_media_states` is written but is
/// NOT authoritative for exactly this reason — see `_saveAnchor`.)
///
/// Among the group's segments, the one with the newest [SegmentProgress.lastPlayedAt]
/// wins; its own saved position becomes the intra-segment offset. A segment
/// watched through (`completed`) resumes from its head. No usable progress
/// anywhere → segment 0 start.
///
/// Deliberately identity-based: the group's positional `scopeKey` changes when
/// the stream is recomposed, but each file's own progress does not.
/// A caller that already knows the exact file (a per-context bookmark) can
/// override this through `targetMediaKey`; see [planVmSessionStart].
(int, int) resolveVmResumeByProgress(
  VirtualMediaItem item,
  Map<String, SegmentProgress> progressByKey,
) {
  if (item.segments.isEmpty || progressByKey.isEmpty) return (0, 0);

  var bestIdx = -1;
  DateTime? bestAt;
  for (var i = 0; i < item.segments.length; i++) {
    final progress = progressByKey[item.segments[i].mediaKey];
    final at = progress?.lastPlayedAt;
    if (progress == null || at == null) continue;
    if (bestAt == null || at.isAfter(bestAt)) {
      bestAt = at;
      bestIdx = i;
    }
  }
  if (bestIdx < 0) return (0, 0);

  final segment = item.segments[bestIdx];
  final progress = progressByKey[segment.mediaKey]!;
  if (progress.completed) return (bestIdx, 0);

  var positionMs = progress.positionMs ?? 0;
  final durationMs = segment.durationMs ?? 0;
  if (positionMs <= 0 || durationMs <= 0) return (bestIdx, 0);
  // A mergeable cut stores SOURCE progress but its local axis is the kept
  // range. A source point the cut removed (or one past its end = watched
  // through) resumes from the segment head, exactly like a completed file.
  if (segment.cutRange != null) {
    final int? local = segment.cutRange!.toCutMs(positionMs);
    if (local == null) return (bestIdx, 0);
    positionMs = local;
  }

  final maxLocal = durationMs - 1;
  // Tail guard only applies to files comfortably longer than the safety
  // margin; short files resume at the exact saved position instead of
  // collapsing to 0 via a negative clamp.
  if (durationMs <= 2 * vmResumeEndSafetyMs) {
    return (bestIdx, positionMs.clamp(0, maxLocal));
  }
  final local = positionMs >= durationMs - vmResumeEndSafetyMs
      ? (durationMs - vmResumeEndSafetyMs).clamp(0, maxLocal)
      : positionMs.clamp(0, maxLocal);
  return (bestIdx, local);
}
