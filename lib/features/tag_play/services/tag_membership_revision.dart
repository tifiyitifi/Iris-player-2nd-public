import 'package:flutter/foundation.dart';

/// Session-scoped announcement that tag MEMBERSHIP changed.
///
/// A membership write is invisible to every derived consumer — a resolved 副音
/// candidate pool, an open queue view, a tag view index — unless somebody says
/// so, and the saying must be cheap enough to sit on the write path itself:
/// one `int` bump plus a set insert, no I/O.
///
/// Only MEMBERSHIP is announced. Creating a tag, renaming it or editing its
/// retention changes no member row, so those paths stay silent; a noise-free
/// signal is what lets a consumer coalesce instead of re-resolving per write.
///
/// The changed ids are deliberately NOT interpreted here. Whether a given tag
/// can affect a given consumer is that consumer's own rule knowledge (for 副音
/// that is the source rules — see `isTagRelevantToBgRules`), so subscribers
/// drain the batch and judge for themselves.
class TagMembershipRevision {
  TagMembershipRevision._();

  /// Process-wide instance. Deliberately NOT persisted: everything derived
  /// from it is itself a session cache keyed by DB content, so a fresh process
  /// has nothing stale to correct.
  static final TagMembershipRevision shared = TagMembershipRevision._();

  /// A private instance for a test that must not share the process-wide
  /// pending batch (single-drainer semantics make a shared one ambiguous).
  @visibleForTesting
  factory TagMembershipRevision.detached() => TagMembershipRevision._();

  final ValueNotifier<int> notifier = ValueNotifier<int>(0);
  final Set<int> _pending = <int>{};

  /// Monotonic counter of announced membership changes.
  int get revision => notifier.value;

  /// Announces that the members of [tagId] changed.
  void bump(int tagId) {
    if (tagId <= 0) return;
    _pending.add(tagId);
    notifier.value = notifier.value + 1;
  }

  /// Takes the tag ids announced since the last drain, leaving the set empty.
  ///
  /// Single-consumer by design: two drainers would race for one batch, so
  /// derived consumers read their own signal off ONE coordinator (see
  /// `BgSourceRevision`) instead of draining here directly.
  Set<int> drainPending() {
    if (_pending.isEmpty) return const <int>{};
    final drained = _pending.toSet();
    _pending.clear();
    return drained;
  }

  /// Drops queued ids without bumping the revision (test seam).
  @visibleForTesting
  void reset() {
    _pending.clear();
    notifier.value = 0;
  }

  void dispose() {
    notifier.dispose();
  }
}
