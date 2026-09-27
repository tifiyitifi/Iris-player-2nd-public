import 'package:iris/features/tag_play/playback/tag_play_controller.dart'
    show TagViewStatus;

/// Sentinel tag suffix for "no tag view drives playback". It travels
/// unlocalized through title widgets and is rendered via `tag_no_tag` at
/// each display site — never compared against real tag names.
const String kNoTagSuffix = 'no-tag';

/// Builds the `[cur/total]` prefix shown before the bar title.
///
/// Priority: the active tag view (its own 1-based position), then the scenario
/// effective stream, then the paged/query queue, then the in-memory queue.
/// Returns null when nothing meaningful plays.
///
/// [scenarioOwnsPlayback] must be true whenever the scenario-driven provider
/// owns the CURRENT playback context — read it from
/// [PlaybackPositionSignal.scenarioOwnsContext], never from the global
/// `PlaybackProviderRegistry.scenarioModeActive` flag. In scenario mode the
/// paged queue is fed a SINGLE item per [ScenarioPlaybackProvider.advanceEntry]
/// hop, so its `isQueryMode` numbers describe nothing that is on screen: with
/// no located scenario position the honest answer is "no prefix", not a
/// leftover `[1/1]` from the last feed.
///
/// It ALSO gates the scenario position itself: that position lives in a
/// process-wide signal which only the scenario provider resets, so a feed that
/// never went through it (history popup, file browser, open file / link, share
/// intent) leaves the previous stream's numbers behind. While something else
/// owns the context that leftover is meaningless and must not outrank a live
/// queue's own index — which is exactly why the gate must be per-context: an
/// external list feed's index is meaningful and has to win.
String? resolveQueuePrefix({
  required TagViewStatus? tagView,
  required ({int index, int count})? scenarioPos,
  required bool scenarioOwnsPlayback,
  required bool isQueryMode,
  required int queryVirtualPos,
  required int queryTotalCount,
  required int queueLength,
  required int currentQueueIndex,
}) {
  if (tagView != null) return '[${tagView.index}/${tagView.count}]';
  // `count > 0` is not decoration: the scenario's index and total are resolved
  // by two INDEPENDENT async reads (`_emitPosition` awaits the total after the
  // index is known), so an emptied / mid-rebuild effective stream can publish
  // `(3, 0)` — the locate cache hit re-publishes a still-valid index with a
  // freshly computed total. Same `[1/0]` the queue branches below refuse.
  if (scenarioOwnsPlayback && scenarioPos != null && scenarioPos.count > 0) {
    return '[${scenarioPos.index + 1}/${scenarioPos.count}]';
  }
  if (scenarioOwnsPlayback) return null;
  // A context the scenario gave up (teardown / external feed) hands the prefix
  // to the queue, but only while the queue still holds something: `clear()` /
  // a stop empties it and leaves the virtual position at 0, which would render
  // a bare `[1/0]` next to the placeholder title.
  if (isQueryMode && queryTotalCount > 0) {
    return '[${queryVirtualPos + 1}/$queryTotalCount]';
  }
  if (queueLength > 0) return '[${currentQueueIndex + 1}/$queueLength]';
  return null;
}
