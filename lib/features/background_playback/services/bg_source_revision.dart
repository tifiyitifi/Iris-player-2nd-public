import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:iris/features/background_playback/services/bg_source_relevance.dart';
import 'package:iris/features/tag_play/services/tag_membership_revision.dart';

/// 副音-side view of "the candidate pool's inputs changed".
///
/// The candidate pool is a session cache keyed by the source rules, so a
/// membership write used to stay invisible to it until a rule was edited or the
/// user pressed refresh. This coordinator closes that hole in three steps:
/// drain the announced tag ids, keep only the ones a 副音 source actually
/// reads, and bump [revision] — which both re-keys the candidate cache and
/// tells a live run to reconcile its queue.
///
/// Coalescing is mandatory here, not an optimisation: a settings import or a
/// `+N` tag command writes members one row at a time, and resolving per row
/// would re-scan the library N times. The window is long enough to swallow a
/// burst and short enough that a single tap still feels immediate.
class BgSourceRevision {
  BgSourceRevision({
    TagMembershipRevision? source,
    Future<bool> Function(int tagId)? relevanceOf,
    Duration coalesce = defaultCoalesceWindow,
  })  : _source = source ?? TagMembershipRevision.shared,
        _relevanceOf = relevanceOf ?? isTagRelevantToBg,
        _coalesce = coalesce;

  /// Process-wide instance, started once by the 副音 bootstrap.
  static final BgSourceRevision shared = BgSourceRevision();

  /// Silence window that merges a burst of membership writes into one resolve.
  static const Duration defaultCoalesceWindow = Duration(milliseconds: 300);

  final TagMembershipRevision _source;
  final Future<bool> Function(int tagId) _relevanceOf;
  final Duration _coalesce;

  final ValueNotifier<int> notifier = ValueNotifier<int>(0);

  /// Bumped once per relevant batch. Folds into the candidate cache key.
  int get revision => notifier.value;

  bool _started = false;
  bool _flushing = false;
  bool _flushAgain = false;
  Timer? _timer;

  /// Idempotent subscription. Safe to call from every consumer that needs the
  /// signal to be live; only the first call attaches the listener.
  void start() {
    if (_started) return;
    _started = true;
    _source.notifier.addListener(_schedule);
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(_coalesce, _flush);
  }

  Future<void> _flush() async {
    if (_flushing) {
      // A batch arrived mid-probe; loop again instead of dropping it.
      _flushAgain = true;
      return;
    }
    _flushing = true;
    try {
      do {
        _flushAgain = false;
        final ids = _source.drainPending();
        if (ids.isEmpty) break;
        if (await _anyRelevant(ids)) notifier.value = notifier.value + 1;
      } while (_flushAgain);
    } finally {
      _flushing = false;
    }
  }

  Future<bool> _anyRelevant(Set<int> ids) async {
    for (final id in ids) {
      try {
        if (await _relevanceOf(id)) return true;
      } catch (_) {
        // A failed relevance probe must not wedge the signal: the pool simply
        // keeps its current generation until the next write.
      }
    }
    return false;
  }

  /// Test seam: stop listening and forget every recorded revision.
  @visibleForTesting
  void reset() {
    _timer?.cancel();
    _timer = null;
    _started = false;
    _flushing = false;
    _flushAgain = false;
    notifier.value = 0;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    // Detaching matters beyond tidiness: a disposed coordinator that stayed
    // subscribed would keep scheduling probes for batches it can no longer
    // report, and would re-arm its timer from a disposed notifier.
    if (_started) {
      _source.notifier.removeListener(_schedule);
      _started = false;
    }
    notifier.dispose();
  }
}
