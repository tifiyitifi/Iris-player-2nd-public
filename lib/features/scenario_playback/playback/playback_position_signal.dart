import 'package:flutter/foundation.dart' show ValueNotifier;

/// Process-wide signal for the reactive position of the current item inside the
/// ACTIVE scenario's effective stream (0-based index + total count). Backs the
/// bar title's `[cur/total]` prefix in scenario mode.
///
/// The notifier deliberately does NOT live on `ScenarioPlaybackProvider`: the
/// provider is intentionally multi-instance — list taps build a short-lived one
/// (see `ScenarioResolvedActions._applyScenarioAndPlay`) so they cannot poison
/// the registry singleton's locate cache, while next/previous, resume and the
/// queue's auto-locate go through that singleton. With the notifier on the
/// instance, a tap published its position into an object that was discarded one
/// line later, so the title kept the pre-tap index (or fell through to the
/// paged queue's meaningless `[1/1]`) until the next PageDown/PageUp happened
/// to re-locate through the singleton. One shared sink makes every producer
/// visible to the single subscriber.
///
/// A dedicated holder (not a `static` field on the provider) keeps it resettable
/// for test isolation.
class PlaybackPositionSignal {
  PlaybackPositionSignal._();

  static final PlaybackPositionSignal instance = PlaybackPositionSignal._();

  /// Null while no position is established (nothing plays, or a brand-new
  /// playback context is still being located).
  final ValueNotifier<({int index, int count})?> position = ValueNotifier(null);

  /// True while the scenario provider owns the CURRENT playback context, i.e.
  /// the numbers the bar title shows were produced by the scenario stream and
  /// not handed over to an outside feed.
  ///
  /// Deliberately NOT `PlaybackProviderRegistry.scenarioModeActive`: that is a
  /// global app flag, true for EVERY playback in the default drift
  /// configuration — including a history-popup / file-browser list the scenario
  /// knows nothing about. Gating the prefix on it suppressed the queue index
  /// those feeds legitimately own. The bar title needs the per-context fact:
  /// "did the scenario produce these numbers, or did something else take the
  /// player?"
  final ValueNotifier<bool> scenarioOwnsContext = ValueNotifier(false);

  int _generation = 0;

  /// Monotonic context counter, bumped by every "I am (re)taking the player"
  /// declaration: [clear] (stop / teardown / external feed / test isolation) and
  /// [claimNewContext] (a scenario `play`).
  ///
  /// Locating is asynchronous — the signature probe, the ordering-hint item seek
  /// and (on a queue the index cannot serve) a `resolvePage` of up to 10k rows
  /// all sit between "start locating" and "publish". Without a counter, a
  /// hand-off that lands in that window is silently overwritten by the locate
  /// that preceded it: the previous stream's index re-claims ownership and the
  /// bar title shows it over whatever is actually playing. Producers capture
  /// this value before their first await and hand it to [publish] / [blank],
  /// which drop the write once a newer context exists.
  int get generation => _generation;

  /// Drops the published position AND the context ownership (stop / context
  /// teardown / external feed / test isolation).
  ///
  /// One fact, not two: a located position only describes the screen while the
  /// scenario owns the context, and handing the player to an outside feed
  /// invalidates both together. Resetting them as a pair is also what keeps
  /// test isolation honest — a leaked `true` here would silently suppress the
  /// queue prefix for the next case.
  void clear() {
    _generation++;
    position.value = null;
    scenarioOwnsContext.value = false;
  }

  /// Declares a NEW playback context owned by the scenario stream, WITHOUT
  /// publishing a position yet.
  ///
  /// [ScenarioPlaybackProvider.play] calls this at its "new playback context"
  /// point, i.e. before the locate: in the window between taking the player and
  /// locating the item the title must already treat the scenario as the owner,
  /// otherwise a bare `position = null` lets it fall through to the paged queue
  /// — which the scenario itself feeds one item per hop, i.e. a meaningless
  /// `[1/1]`.
  ///
  /// Bumps [generation] so a locate still in flight from the PREVIOUS context
  /// can no longer publish over this one.
  void claimNewContext() {
    _generation++;
    scenarioOwnsContext.value = true;
  }

  /// Publishes [pos] as the current position AND claims the context for it.
  ///
  /// Dropped when [generation] is no longer current — i.e. a hand-off happened
  /// while the locate was in flight. Returns whether the write landed.
  bool publish(int generation, ({int index, int count}) pos) {
    if (generation != _generation) return false;
    // A located position IS the proof that the scenario owns the context, so
    // publishing one claims ownership. Deriving it here rather than at each
    // call site keeps every re-establishing path correct after a teardown
    // (resumeActive, the paged view's auto-locate, the VM group sync) without
    // each of them having to remember to declare it. Ordered BEFORE the
    // position write: that write is what schedules the title's rebuild, and the
    // rebuild must not read a stale `false`.
    scenarioOwnsContext.value = true;
    position.value = pos;
    return true;
  }

  /// Drops the position while KEEPING the current ownership — the "new context
  /// taken, item not located yet" blank. Same generation guard as [publish].
  bool blank(int generation) {
    if (generation != _generation) return false;
    position.value = null;
    return true;
  }
}
