import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/rule/vm_chunk_numbering.dart';
import 'package:iris/features/virtual_media/rule/vm_natural_compare.dart';
import 'package:iris/features/virtual_media/rule/vm_sorter.dart';
import 'package:iris/features/virtual_media/rule/vm_title_composer.dart';
import 'package:iris/features/virtual_media/service/vm_membership_pin.dart';
import 'package:iris/features/virtual_media/vm_l10n.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/dir_match.dart';

/// Pure resolver pipeline (v2):
///
///   enabled rules → (per rule, INDEPENDENTLY) match directories →
///   collect candidates → sort → group by boundary mode → chunks
///
/// Rules never claim files from each other — overlapping rules simply
/// produce overlapping virtual items and the user avoids duplicates by
/// shaping the rules ("有多条合并规则，就当成多条视频").
List<VirtualMediaItem> resolveVirtualMedia({
  required List<VirtualMediaRule> rules,
  required List<VirtualSegment> library,
  AppLocalizations? l10n,
  /// When false the delete-time boundary freeze ([VmMembershipPin]) is ignored
  /// and every rule re-derives normally. The full-library MANAGEMENT PREVIEW
  /// uses this: the pin is seeded from one scenario's stream, so applying it to
  /// a whole-`media_nodes` snapshot would drop members outside that scenario.
  bool applyPin = true,
}) {
  final items = <VirtualMediaItem>[];
  final t = l10n ?? vmLocalizations();
  final pin = VmMembershipPin.instance;
  for (final rule in rules) {
    if (!rule.enabled) continue;
    // A rule whose boundaries a physical delete froze this session emits its
    // pinned chunks instead of re-deriving them (see VmMembershipPin).
    final pinned = applyPin ? pin.chunksFor(rule.id) : null;
    if (pinned != null) {
      items.addAll(_resolveFromPinned(rule, pinned, library, t));
    } else {
      items.addAll(_resolveRule(rule, library, t));
    }
  }
  return items;
}

/// Rebuilds a pinned rule's frozen chunks against the CURRENT library.
///
/// Members that vanished (physically deleted) or are absent from the library
/// are dropped; survivors keep their original order, so chunk boundaries and
/// cross-chunk membership stay exactly as they were before the delete. A chunk
/// that was multi-member stays merged even when it shrinks to one member (the
/// "vm1 survives as {1}" contract), while a chunk that was ALWAYS single keeps
/// the normal [VirtualMediaRule.skipSingleSegment] handling.
List<VirtualMediaItem> _resolveFromPinned(
  VirtualMediaRule rule,
  List<PinnedVmChunk> pinned,
  List<VirtualSegment> library,
  AppLocalizations l10n,
) {
  // The pin freezes only the BOUNDARY shape. Members are looked up in the
  // CURRENT library by mediaKey so they carry up-to-date metadata (duration,
  // dimensions) instead of the pre-delete snapshot captured when the pin was
  // seeded.
  final freshByKey = <String, VirtualSegment>{
    for (final s in library) s.mediaKey: s,
  };
  final removed = VmMembershipPin.instance.removedKeys;
  final items = <VirtualMediaItem>[];
  for (final chunk in pinned) {
    final segments = <VirtualSegment>[
      for (final seg in chunk.originalSegments)
        if (!removed.contains(seg.mediaKey) &&
            freshByKey.containsKey(seg.mediaKey))
          freshByKey[seg.mediaKey]!,
    ];
    if (segments.isEmpty) continue;
    if (rule.skipSingleSegment && chunk.originalSegments.length == 1) {
      continue;
    }
    items.add(VirtualMediaItem(
      ruleId: rule.id,
      scopeKey: chunk.scopeKey,
      rootPath: chunk.rootPath,
      displayIndex: chunk.displayIndex,
      displayName: _displayName(rule, segments, chunk.displayIndex, l10n),
      segments: segments,
    ));
  }
  return items;
}

/// The authoritative, RULE-DIMENSION grouping over a view's member universe.
///
/// Unlike the scenario-stream run approximation (`resolveGroupsForStream`),
/// this groups by the rule's OWN sort → boundary → caps pipeline — the same
/// semantics as [resolveVirtualMedia]. A group is therefore a pure function of
/// its rule + the set of covered files, independent of any stream/scenario
/// order, which lets the group be materialized once and reused by every
/// scenario/tag view (with [membership] narrowing the covered set).
///
/// [membership] optionally restricts which library files a rule may claim
/// (canonical mediaKey set); null means "all". Files NOT in the set are never
/// part of a group, but they do not break a group either — the tag-view
/// "宽松" policy (a group keeps its rule shape, the view filters visible
/// members) is applied by the caller.
List<VirtualMediaItem> resolveRuleGroups({
  required List<VirtualMediaRule> rules,
  required List<VirtualSegment> library,
  Set<String>? membership,
  AppLocalizations? l10n,
  bool applyPin = true,
}) {
  if (rules.isEmpty || library.isEmpty) return const [];
  final scoped = membership == null
      ? library
      : [
          for (final seg in library)
            if (membership.contains(seg.mediaKey)) seg,
        ];
  if (scoped.isEmpty) return const [];
  return resolveVirtualMedia(
      rules: rules, library: scoped, l10n: l10n, applyPin: applyPin);
}

List<VirtualMediaItem> _resolveRule(
    VirtualMediaRule rule, List<VirtualSegment> library, AppLocalizations l10n) {
  final candidates = _collectCandidates(rule, library);
  if (candidates.isEmpty) return const [];

  final sorted = sortSegments(candidates, rule.sortField, rule.sortDir);
  final groups = _group(sorted, rule);
  if (groups.isEmpty) return const [];

  final numbering = VmChunkNumbering(rule.boundary);
  final items = <VirtualMediaItem>[];
  for (final group in groups) {
    // A chunk that collapsed to a single file is not a merge: keep the file
    // as an ordinary single item instead of a one-segment virtual item.
    if (rule.skipSingleSegment && group.length == 1) continue;
    final chunkNo = numbering.next(
      ruleId: rule.id,
      parentPath: group.first.parentPath,
    );
    items.add(VirtualMediaItem(
      ruleId: rule.id,
      scopeKey: '${rule.id}|${group.first.parentPath}|#$chunkNo',
      rootPath: group.first.parentPath,
      displayIndex: chunkNo,
      displayName: _displayName(rule, group, chunkNo, l10n),
      segments: group,
    ));
  }
  return items;
}

// ── Matching ──

/// Whether [seg] falls inside [rule]'s scope — the single source of truth
/// for "this rule covers this file", shared by the batch candidate
/// collection ([resolveVirtualMedia]) and the per-entry point checks
/// (scenario playback start, current-item recovery).
///
/// Delegates to the shared [dirRuleMatchesFile] engine (also used by 副音
/// source rules) so both features share one tested implementation.
///
/// Hot loops (files × rules) must compile once with [compileVmRule] and
/// match per file with [vmRuleCoversCompiled] instead — this entry compiles
/// on every call.
bool vmRuleCoversFile(VirtualMediaRule rule, VirtualSegment seg) {
  return dirRuleMatchesFile(
    mode: _toDirMode(rule.matchMode),
    paths: rule.paths,
    patterns: _toDirPatterns(rule.patterns),
    fullPath: seg.fullPath,
    parentPath: seg.parentPath,
  );
}

/// Precompiles [rule] for repeated matching (same result as
/// [vmRuleCoversFile], no per-file setup cost).
CompiledDirRule compileVmRule(VirtualMediaRule rule) => compileDirRule(
      mode: _toDirMode(rule.matchMode),
      paths: rule.paths,
      patterns: _toDirPatterns(rule.patterns),
    );

/// Matches one segment against a precompiled rule (see [compileVmRule]).
bool vmRuleCoversCompiled(CompiledDirRule compiled, VirtualSegment seg) =>
    compiledDirRuleMatchesFile(
      compiled,
      fullPath: seg.fullPath,
      parentPath: seg.parentPath,
    );

/// Exclusion threshold in milliseconds for the rule's "single video too long
/// to merge" switch, or null when the switch is off.
///
/// Dirty/zero values fall back to the domain default; the result is clamped
/// into the shared 1–300 min range so a hand-edited DB row can never produce
/// an out-of-range threshold. Shared by BOTH resolver paths (batch and
/// scenario-stream) so they cannot drift.
int? vmOverlongThresholdMs(VirtualMediaRule rule) {
  if (!rule.useExcludeOverlong) return null;
  final minutes = (rule.maxSingleDurationMinutes <= 0
          ? kVmDefaultMaxSingleDurationMinutes
          : rule.maxSingleDurationMinutes)
      .clamp(1, kVmHardMaxDurationMinutes);
  return minutes * 60 * 1000;
}

/// Whether [seg] is a single video long enough to be kept OUT of a merge.
///
/// Unknown/zero durations are NEVER excluded: they still join the merge and
/// degrade through preflight instead of silently disappearing.
bool vmSegmentOverlong(VirtualMediaRule rule, VirtualSegment seg) {
  final threshold = vmOverlongThresholdMs(rule);
  if (threshold == null) return false;
  final d = seg.durationMs;
  return d != null && d > 0 && d > threshold;
}

DirMatchMode _toDirMode(VmMatchMode mode) => switch (mode) {
      VmMatchMode.specifiedDir => DirMatchMode.specifiedDir,
      VmMatchMode.specifiedDirRecursive => DirMatchMode.specifiedDirRecursive,
      VmMatchMode.patternDir => DirMatchMode.patternDir,
      VmMatchMode.patternDirRecursive => DirMatchMode.patternDirRecursive,
    };

List<DirPatternEntry> _toDirPatterns(List<VmPatternEntry> patterns) => [
      for (final p in patterns)
        DirPatternEntry(
          kind: switch (p.kind) {
            VmPatternKind.prefix => DirPatternKind.prefix,
            VmPatternKind.suffix => DirPatternKind.suffix,
            VmPatternKind.contains => DirPatternKind.contains,
            VmPatternKind.regex => DirPatternKind.regex,
          },
          text: p.text,
          activated: p.activated,
          pinned: p.pinned,
        ),
    ];

List<VirtualSegment> _collectCandidates(
    VirtualMediaRule rule, List<VirtualSegment> library) {
  final compiled = compileVmRule(rule);
  return [
    for (final f in library)
      if (vmRuleCoversCompiled(compiled, f) && !vmSegmentOverlong(rule, f)) f,
  ];
}

// ── Grouping ──

/// Applies the boundary mode AFTER sorting:
/// - sameDirOnly: buckets by directory (natural dir order), chunked
///   inside each bucket;
/// - crossDirMerge: buckets concatenated (natural dir order), chunked
///   across boundaries;
/// - ignoreDirs: global order, straight chunking.
List<List<VirtualSegment>> _group(
    List<VirtualSegment> sorted, VirtualMediaRule rule) {
  switch (rule.boundary) {
    case VmBoundaryMode.sameDirOnly:
      final byRoot = <String, List<VirtualSegment>>{};
      for (final seg in sorted) {
        (byRoot[seg.parentPath] ??= []).add(seg);
      }
      final keys = byRoot.keys.toList()..sort(vmNaturalCompare);
      final groups = <List<VirtualSegment>>[];
      for (final k in keys) {
        groups.addAll(_chunkByLimits(byRoot[k]!, rule));
      }
      return groups;

    case VmBoundaryMode.crossDirMerge:
      // Global order is authoritative: the input is already sorted by the
      // rule's sort spec, so chunk it directly. Re-bucketing by directory
      // would scatter duration/resolution ordering.
      return _chunkByLimits(sorted, rule);

    case VmBoundaryMode.ignoreDirs:
      return _chunkByLimits(sorted, rule);
  }
}

List<List<VirtualSegment>> _chunkByLimits(
    List<VirtualSegment> sorted, VirtualMediaRule rule) {
  // Hard ceilings always apply, even when the user leaves both caps
  // unchecked — an unbounded chunk breaks seek UX and segment-switch cost.
  final durLimitMs = (rule.useDurationCap
          ? (rule.maxDurationMinutes <= 0
              ? kVmDefaultMaxDurationMinutes
              : rule.maxDurationMinutes)
          : kVmHardMaxDurationMinutes)
      .clamp(1, kVmHardMaxDurationMinutes) *
      60 *
      1000;
  final cntLimit = (rule.useCountCap
          ? (rule.maxItemCount <= 0
              ? kVmDefaultMaxItemCount
              : rule.maxItemCount)
          : kVmHardMaxItemCount)
      .clamp(1, kVmHardMaxItemCount);
  const useDur = true;
  const useCnt = true;
  final chunks = <List<VirtualSegment>>[];
  var current = <VirtualSegment>[];
  var accMs = 0;

  void close() {
    if (current.isNotEmpty) chunks.add(current);
    current = <VirtualSegment>[];
    accMs = 0;
  }

  for (final seg in sorted) {
    final d = seg.durationMs ?? 0;
    final wouldOverflowDur = useDur && current.isNotEmpty && accMs + d > durLimitMs;
    final wouldOverflowCnt = useCnt && current.isNotEmpty && current.length + 1 > cntLimit;
    final needsSplit = wouldOverflowDur || wouldOverflowCnt;
    if (needsSplit) close();
    current.add(seg);
    accMs += d;
  }
  close();
  return chunks;
}

// ── Presentation ──

String _baseNameOf(String dirPath) {
  final idx = dirPath.lastIndexOf('/');
  return idx < 0 ? dirPath : dirPath.substring(idx + 1);
}

/// The `dirName` piece of a group title: a group anchored at the storage root
/// shows the localized root label, every other group the last path segment.
/// Shared so both title producers below agree on the same rendering.
String vmDirTitleLabel(String anchorRoot, AppLocalizations l10n) =>
    anchorRoot.isEmpty ? l10n.vm_title_root_dir : _baseNameOf(anchorRoot);

/// Composes a group's display title from its RULE's own `titleTags` — the
/// single source of truth shared by the materializing resolver (which stores
/// the result on `VirtualMediaItem.displayName`) and the persistent-index read
/// path (which rebuilds the title from the persisted group header + members).
String composeRuleGroupTitle({
  required VirtualMediaRule rule,
  required String anchorRoot,
  required String firstFile,
  required String lastFile,
  required int seq,
  required int totalDurationMs,
  required int? width,
  required int? height,
  required AppLocalizations l10n,
}) =>
    composeVmTitle(
      tags: rule.titleTags,
      ruleName: rule.name,
      dirName: vmDirTitleLabel(anchorRoot, l10n),
      firstFile: firstFile,
      lastFile: lastFile,
      seq: seq,
      totalDurationMs: totalDurationMs,
      width: width,
      height: height,
    );

String _displayName(VirtualMediaRule rule, List<VirtualSegment> group, int seq,
    AppLocalizations l10n) {
  final total = group.fold<int>(
      0, (sum, s) => sum + (s.durationMs ?? 0));
  return composeRuleGroupTitle(
    rule: rule,
    anchorRoot: group.first.parentPath,
    firstFile: group.first.name,
    lastFile: group.last.name,
    seq: seq,
    totalDurationMs: total,
    width: group.first.width,
    height: group.first.height,
    l10n: l10n,
  );
}
