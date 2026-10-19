import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:iris/features/background_playback/services/background_tag_pool.dart';
import 'package:iris/features/tag_play/services/tag_membership_revision.dart';

/// 副音-side view of "the candidate pool's inputs changed".
///
/// The pool IS the reserved 「副音备选」tag's view (see
/// `resolveBackgroundCandidates`), so its only input is that tag's MEMBERSHIP: a
/// membership write is drained from [TagMembershipRevision] and coalesced below
/// into one bump of [revision]. Writes to other tags are filtered out by the
/// relevance probe ([relevanceOfReservedBackgroundTag]).
///
/// Bumping [revision] both re-keys the pool and tells a live run to reconcile
/// its queue. A scenario SOURCE edit can no longer reach the pool: v49 retired
/// the tag source kind, so the background workspace carries no sources at all
/// (the old second input here).
///
/// Coalescing is mandatory here, not an optimisation: a settings import or a
/// `+N` tag command writes members one row at a time, and resolving per row
/// would re-scan the library N times. The window is long enough to swallow a
/// burst and short enough that a single tap still feels immediate.
class BgPoolRevision {
  BgPoolRevision({
    TagMembershipRevision? source,
    Future<bool> Function(int tagId)? relevanceOf,
    Duration coalesce = defaultCoalesceWindow,
  })  : _source = source ?? TagMembershipRevision.shared,
        _relevanceOf = relevanceOf ?? _alwaysRelevant,
        _coalesce = coalesce;

  /// Process-wide instance, started once by the 副音 bootstrap.
  static final BgPoolRevision shared = BgPoolRevision();

  /// Silence window that merges a burst of membership writes into one resolve.
  static const Duration defaultCoalesceWindow = Duration(milliseconds: 300);

  final TagMembershipRevision _source;

  /// Defaults to "every write matters" so a store-free test that never calls
  /// [start] with a probe behaves as before; production calls [start] with
  /// [relevanceOfReservedBackgroundTag].
  Future<bool> Function(int tagId) _relevanceOf;

  final Duration _coalesce;

  /// Every membership change is now relevant (the pool is tag-sourced; the
  /// retired rules no longer narrow which tags matter).
  static Future<bool> _alwaysRelevant(int _) async => true;

  /// The PRODUCTION relevance probe: only the reserved 「副音备选」tag's
  /// membership can change the candidate pool, because that tag's view IS the
  /// stream (see `resolveBackgroundCandidates`).
  ///
  /// Without it every tag write in the app — a 收藏 tag, an unrelated
  /// collection's `+N` command, a settings import — re-resolved the whole
  /// candidate stream and persisted the queue.
  static Future<bool> relevanceOfReservedBackgroundTag(int tagId) async {
    try {
      final reserved = await reservedBackgroundTagId();
      return reserved != null && reserved == tagId;
    } catch (_) {
      // No tag DB (store-free context): nothing can be relevant.
      return false;
    }
  }

  final ValueNotifier<int> notifier = ValueNotifier<int>(0);

  /// Bumped once per relevant batch. Folds into the candidate cache key.
  int get revision => notifier.value;

  bool _started = false;
  bool _flushing = false;
  bool _flushAgain = false;
  Timer? _timer;

  /// Idempotent subscription. Safe to call from every consumer that needs the
  /// signal to be live; only the first call attaches the listener.
  ///
  /// [relevanceOf] is how production supplies the real probe
  /// ([relevanceOfReservedBackgroundTag]): the process-wide [shared] instance is
  /// constructed before the DB exists, so the probe is injected here instead.
  /// A later call still REFRESHES the probe — silently ignoring it left a
  /// caller believing the real probe was installed while every write stayed
  /// "relevant" (re-resolving the whole pool on unrelated tag writes).
  void start({Future<bool> Function(int tagId)? relevanceOf}) {
    if (relevanceOf != null) _relevanceOf = relevanceOf;
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
    // Detach BEFORE clearing `_started`, so a follow-up [start] gets a clean
    // single subscription instead of stacking a second listener on the old one.
    if (_started) {
      _source.notifier.removeListener(_schedule);
      _started = false;
    }
    _timer?.cancel();
    _timer = null;
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
