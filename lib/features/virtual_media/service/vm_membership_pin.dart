import 'package:iris/features/virtual_media/model/domain/vm_item.dart';

/// One frozen rule chunk captured immediately BEFORE a physical delete.
///
/// Holds the rule's own resolved chunk (identity fields + the full ordered
/// segment list as derived while the soon-to-be-deleted member was still in the
/// library). Re-emitting the chunk from this frozen member list — rather than
/// re-running the rule's sort → boundary → caps pipeline — is what keeps the
/// chunk BOUNDARIES stable after a member vanishes: a fresh `_chunkByLimits`
/// pass would re-accumulate the survivors and can merge a later chunk into an
/// earlier one (e.g. `{1,2,3,4}/{5}` minus `2,3,4` re-chunks into `{1,5}`).
class PinnedVmChunk {
  final String ruleId;
  final String scopeKey;
  final String rootPath;
  final int displayIndex;
  final List<VirtualSegment> originalSegments;

  const PinnedVmChunk({
    required this.ruleId,
    required this.scopeKey,
    required this.rootPath,
    required this.displayIndex,
    required this.originalSegments,
  });
}

/// Session-scoped Virtual Media boundary freeze (desktop physical delete).
///
/// WHY: VM grouping is a pure function of a rule + the current file set
/// (`resolveVirtualMedia`), so removing a `media_nodes` row normally makes the
/// rule re-chunk its WHOLE candidate list. Deleting one member could therefore
/// pull a NEIGHBOURING chunk's files into the deleted member's chunk (the
/// documented "重新分布整体vm" hazard).
///
/// This pin freezes the affected rule's chunk boundaries for the rest of the
/// session: only the chunk that contained the deleted file shrinks, every other
/// chunk (and every other rule — rules are independent anyway) keeps its exact
/// membership. The freeze is dropped by the four legitimate re-group triggers
/// (see [clear]); the next resolve then re-derives normally.
///
/// Deliberately holds NO media data beyond the frozen chunks: it is a small
/// session overlay consulted by the resolver, not a snapshot owner.
class VmMembershipPin {
  VmMembershipPin._();

  static final VmMembershipPin instance = VmMembershipPin._();

  /// ruleId → frozen chunks (only rules a delete has touched).
  final Map<String, List<PinnedVmChunk>> _byRule = {};

  /// mediaKeys physically deleted this session. Filtered out of pinned chunks
  /// even when a stale (pre-delete) library still carries them.
  final Set<String> _removedKeys = {};

  bool get isActive => _byRule.isNotEmpty;

  /// Frozen chunks for [ruleId], or null when the rule is not pinned (the
  /// resolver then runs its normal pipeline).
  List<PinnedVmChunk>? chunksFor(String ruleId) => _byRule[ruleId];

  Set<String> get removedKeys => Set<String>.unmodifiable(_removedKeys);

  /// Freezes [ruleId]'s current chunks. No-op when the rule is already pinned
  /// (the deletion that pinned it may have happened before an unrelated
  /// re-resolve). Only non-empty chunk lists are stored.
  ///
  /// The list holds the rule's raw chunks — feasible AND infeasible
  /// (unknown-duration) groups alike (see `collectPinnedVmChunks`). The
  /// infeasible ones never merge downstream, but retaining them keeps their
  /// yellow degraded attribution alive while the rule is pinned.
  void seedRule(String ruleId, Iterable<PinnedVmChunk> chunks) {
    if (_byRule.containsKey(ruleId)) return;
    final list = chunks.toList(growable: false);
    if (list.isEmpty) return;
    _byRule[ruleId] = list;
  }

  /// Records [mediaKey] as removed for the pinned rule. The member is filtered
  /// out of every chunk that carries it; other chunks are untouched.
  void removeMember(String ruleId, String mediaKey) {
    if (!_byRule.containsKey(ruleId)) return;
    _removedKeys.add(mediaKey);
  }

  /// Drops the freeze entirely, restoring normal re-derivation. Called by the
  /// four legitimate re-group triggers: app restart (implicit), source
  /// scan/dir-sync/duration change, rule change, and explicit source refresh.
  void clear() {
    _byRule.clear();
    _removedKeys.clear();
  }
}
