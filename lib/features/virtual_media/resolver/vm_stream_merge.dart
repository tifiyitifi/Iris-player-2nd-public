import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/resolver/vm_preflight.dart';
import 'package:iris/features/virtual_media/resolver/vm_resolver.dart';
import 'package:iris/features/virtual_media/service/vm_membership_pin.dart';
import 'package:iris/features/virtual_media/vm_l10n.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.mediaProbe);

/// VM merge groups derived from ONE scenario's effective stream.
class VmStreamGroups {
  /// Canonical mediaKey (`storageId:path`) → the virtual item covering it.
  ///
  /// Contains ONLY feasible groups (every segment has a known positive
  /// duration, single-segment groups included). Infeasible members land in
  /// [failByKey] and stay ordinary single items downstream.
  final Map<String, VirtualMediaItem> byKey;

  /// Resolved groups in resolve order (rule order, then chunk order) — the
  /// sibling queue for a VM session started from this stream.
  final List<VirtualMediaItem> inOrder;

  /// Canonical mediaKey → failure attribution for would-be virtual members
  /// that failed preflight (unknown duration etc.). The overlay leaves these
  /// unmerged; the list UI renders them with a yellow warning mark and they
  /// play as ordinary single files.
  final Map<String, VmFailInfo> failByKey;

  /// The infeasible groups behind [failByKey] (for the scan flow; the overlay
  /// never sees these).
  final List<VirtualMediaItem> failedGroups;

  const VmStreamGroups({
    required this.byKey,
    required this.inOrder,
    this.failByKey = const {},
    this.failedGroups = const [],
  });

  bool get isEmpty => byKey.isEmpty;
  bool get isNotEmpty => byKey.isNotEmpty;

  /// Groups derived from the stream before preflight (valid + degraded).
  /// Lets callers distinguish "no rule matched" (0) from "matched but all
  /// degraded" (>0 with empty [byKey]) in diagnostics.
  int get resolvedGroupCount => inOrder.length + failedGroups.length;
}

/// Cache decision for per-tap merge groups (play/next/prev/completion).
enum VmGroupsCacheAction {
  /// Reuse the cached groups (no stream resolve, no regex matching).
  useCached,

  /// Re-collect the effective stream and re-resolve.
  resolveFresh,
}

/// Decides whether the cached [VmStreamGroups] serve the tapped entry.
///
/// Fresh resolve when the effective-stream signature moved (definition
/// config, shuffle, playback version, rule revision) or when a rule-covered
/// entry is in neither `byKey` nor `failByKey` (content scanned after
/// caching — one refresh, then the entry is covered). Pure: unit-testable.
VmGroupsCacheAction vmGroupsCacheAction({
  required String? cachedSignature,
  required String currentSignature,
  required bool entryCoveredInCache,
}) {
  if (cachedSignature != currentSignature) return VmGroupsCacheAction.resolveFresh;
  if (!entryCoveredInCache) return VmGroupsCacheAction.resolveFresh;
  return VmGroupsCacheAction.useCached;
}

/// Scenario-first VM merge (the ONLY grouping entry point in playback):
///
///   scenario sources (drift) → effective stream → THIS adapter → overlay
///
/// ORDER CONTRACT (rule-dimension grouping):
///
///   - A group is defined by the RULE over the covered file set
///     (`resolveRuleGroups`: the rule's own sort → boundary → caps), exactly
///     like the persisted index that serves the queue page. It is a pure
///     function of the rule + the files, so it does NOT depend on the order
///     the scenario happens to stream them in.
///   - A group's members and their order are therefore EXEMPT from the
///     external order: shuffling or re-sorting the scenario moves the merged
///     ROW, never which files it merges nor how its own segments sequence.
///   - The merged item then takes part in the external order as ONE element
///     (see `applyVmOverlay`, which places it at its earliest member).
///
/// Deriving the groups from the STREAM order instead (the old maximal-run
/// approximation) meant a shuffled stream scattered a group's members, so the
/// run pipeline split it into several rows while the persisted index stored
/// one: the row the list showed and the group the tap played were then two
/// different sets of files.
///
/// The run-based derivation is retired; `vmNoMatchReport` survives as the
/// diagnostic for "no rule matched anything", which the rule pipeline itself
/// reports only as an empty result.
VmStreamGroups resolveGroupsForStream(
  List<EffectivePlaybackItem> stream,
  List<VirtualMediaRule> rules, {
  AppLocalizations? l10n,
}) {
  if (rules.isEmpty || stream.isEmpty) {
    return const VmStreamGroups(byKey: {}, inOrder: []);
  }

  final segments = <VirtualSegment>[];
  for (final item in stream) {
    // Unavailable placeholders (missing explicit items / empty sources) and
    // directory rows never take part in a virtual merge.
    if (!item.available) continue;
    final f = item.media.maybeMap(file: (f) => f, orElse: () => null);
    if (f == null) continue;
    segments.add(VirtualSegment(
      mediaKey: canonicalKey(f.storageId, f.path.join('/')),
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
  if (segments.isEmpty) {
    return const VmStreamGroups(byKey: {}, inOrder: []);
  }

  final l = l10n ?? vmLocalizations();
  final rawItems =
      resolveRuleGroups(rules: rules, library: segments, l10n: l);
  if (rawItems.isEmpty) {
    // Pure log line: a path-shape mismatch must stay visible in release logs.
    _log.w(vmNoMatchReport(rules: rules, streamOrdered: segments));
  }
  // Preflight: only feasible groups (known positive duration per segment,
  // single-segment included) stay merged; the rest degrade to ordinary
  // single items with yellow-mark attribution in failByKey.
  final partitioned = partitionVmItems(rawItems);
  final items = partitioned.valid;
  final byKey = <String, VirtualMediaItem>{};
  for (final item in items) {
    for (final seg in item.segments) {
      byKey[seg.mediaKey] = item;
    }
  }
  return VmStreamGroups(byKey: byKey, inOrder: items, failByKey: partitioned.failByKey, failedGroups: partitioned.failed);
}

/// Delete-time boundary capture for [VmMembershipPin] (pure, unit-testable).
///
/// Collects the frozen raw chunks of every rule in [ruleIds] — BOTH the
/// feasible groups ([VmStreamGroups.inOrder]) AND the infeasible ones
/// ([VmStreamGroups.failedGroups], e.g. unknown duration). The latter never
/// merge, so freezing them changes no playlist row, but dropping them would
/// lose their yellow degraded mark once the rule is pinned: a pinned rule
/// re-emits only its frozen chunks instead of re-deriving, and the next
/// `resolveGroupsForStream` would then publish an empty `failByKey` for it.
///
/// Callers seed the result via `VmMembershipPin.seedRule` per rule; empty
/// results seed nothing (the pin's `seedRule` no-ops on empty lists).
Map<String, List<PinnedVmChunk>> collectPinnedVmChunks(
  VmStreamGroups groups,
  Set<String> ruleIds,
) {
  if (ruleIds.isEmpty) return const {};
  final byRule = <String, List<PinnedVmChunk>>{};
  final seenScopes = <String>{};
  void add(VirtualMediaItem g) {
    if (!ruleIds.contains(g.ruleId)) return;
    if (!seenScopes.add(g.scopeKey)) return;
    (byRule[g.ruleId] ??= []).add(PinnedVmChunk(
      ruleId: g.ruleId,
      scopeKey: g.scopeKey,
      rootPath: g.rootPath,
      displayIndex: g.displayIndex,
      originalSegments: g.segments,
    ));
  }
  for (final g in groups.inOrder) {
    add(g);
  }
  for (final g in groups.failedGroups) {
    add(g);
  }
  return byRule;
}

/// Human-readable attribution for a resolve where NO rule matched ANY
/// stream segment. Pure function so the 0-match case is unit-testable;
/// callers log the returned line instead of `print` (release logs keep it).
String vmNoMatchReport({
  required List<VirtualMediaRule> rules,
  required List<VirtualSegment> streamOrdered,
}) {
  if (streamOrdered.isEmpty) {
    return '[vm] no rule matched stream. rules=${rules.length} empty stream';
  }
  final first = streamOrdered.first;
  final perRule = <String, int>{};
  for (final rule in rules) {
    var count = 0;
    for (final seg in streamOrdered) {
      if (vmRuleCoversFile(rule, seg)) count++;
    }
    perRule[rule.id] = count;
  }
  return '[vm] no rule matched stream. rules=${rules.length} '
      'perRule=$perRule '
      'firstStorage=${first.storageId} firstParent=${first.parentPath} '
      'firstFull=${first.fullPath} firstKey=${first.mediaKey} '
      'firstMode=${rules.first.matchMode.name} '
      'firstPaths=${rules.first.paths} '
      'firstPatterns=${rules.first.patterns.map((p) => "${p.kind.name}:${p.text}").toList()}';
}

