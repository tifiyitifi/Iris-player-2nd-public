import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/tag_play/playback/tag_play_controller.dart';
import 'package:iris/pages/player/title_prefix.dart';

void main() {
  group('resolveQueuePrefix', () {
    test('tag view wins over every other source', () {
      final tag = const TagViewStatus(index: 3, count: 25, tagName: '喜欢');
      expect(
        resolveQueuePrefix(
          tagView: tag,
          scenarioPos: (index: 99, count: 999),
          scenarioOwnsPlayback: true,
          isQueryMode: true,
          queryVirtualPos: 0,
          queryTotalCount: 50,
          queueLength: 1,
          currentQueueIndex: 0,
        ),
        '[3/25]',
      );
    });

    test('scenario effective position when no tag view', () {
      expect(
        resolveQueuePrefix(
          tagView: null,
          scenarioPos: (index: 6, count: 42),
          scenarioOwnsPlayback: true,
          isQueryMode: false,
          queryVirtualPos: 0,
          queryTotalCount: 0,
          queueLength: 1,
          currentQueueIndex: 0,
        ),
        '[7/42]',
      );
    });

    test('query mode uses the virtual position', () {
      expect(
        resolveQueuePrefix(
          tagView: null,
          scenarioPos: null,
          scenarioOwnsPlayback: false,
          isQueryMode: true,
          queryVirtualPos: 9,
          queryTotalCount: 30,
          queueLength: 0,
          currentQueueIndex: -1,
        ),
        '[10/30]',
      );
    });

    test('in-memory queue when everything else is absent', () {
      expect(
        resolveQueuePrefix(
          tagView: null,
          scenarioPos: null,
          scenarioOwnsPlayback: false,
          isQueryMode: false,
          queryVirtualPos: 0,
          queryTotalCount: 0,
          queueLength: 5,
          currentQueueIndex: 2,
        ),
        '[3/5]',
      );
    });

    test('single item still gets [1/1]', () {
      expect(
        resolveQueuePrefix(
          tagView: null,
          scenarioPos: null,
          scenarioOwnsPlayback: false,
          isQueryMode: false,
          queryVirtualPos: 0,
          queryTotalCount: 0,
          queueLength: 1,
          currentQueueIndex: 0,
        ),
        '[1/1]',
      );
    });

    test('null when nothing meaningful plays', () {
      expect(
        resolveQueuePrefix(
          tagView: null,
          scenarioPos: null,
          scenarioOwnsPlayback: false,
          isQueryMode: false,
          queryVirtualPos: 0,
          queryTotalCount: 0,
          queueLength: 0,
          currentQueueIndex: -1,
        ),
        isNull,
      );
    });

    // Scenario-driven playback feeds the paged queue one item per hop, so its
    // query-mode numbers describe the LAST hop, not what is on screen. Falling
    // through to them pinned the bar title to a permanent [1/1] whenever the
    // scenario position had not been located yet.
    test('no prefix when the scenario owns playback but nothing is located', () {
      expect(
        resolveQueuePrefix(
          tagView: null,
          scenarioPos: null,
          scenarioOwnsPlayback: true,
          isQueryMode: true,
          queryVirtualPos: 0,
          queryTotalCount: 1,
          queueLength: 1,
          currentQueueIndex: 0,
        ),
        isNull,
      );
    });

    test('scenario position still wins over the paged queue in scenario mode',
        () {
      expect(
        resolveQueuePrefix(
          tagView: null,
          scenarioPos: (index: 0, count: 1),
          scenarioOwnsPlayback: true,
          isQueryMode: true,
          queryVirtualPos: 0,
          queryTotalCount: 1,
          queueLength: 1,
          currentQueueIndex: 0,
        ),
        '[1/1]',
      );
    });

    // The scenario position is a process-wide signal that ONLY the scenario
    // provider resets, so any feed that never touched it (history popup, file
    // browser, open file / link, share intent) left the old stream's numbers
    // behind. Trusting them whenever they are merely non-null made the bar title
    // keep claiming e.g. [37/120] while a 3-item history list was playing.
    test('stale scenario position is ignored when the scenario does not own playback',
        () {
      expect(
        resolveQueuePrefix(
          tagView: null,
          scenarioPos: (index: 36, count: 120),
          scenarioOwnsPlayback: false,
          isQueryMode: false,
          queryVirtualPos: 0,
          queryTotalCount: 0,
          queueLength: 3,
          currentQueueIndex: 0,
        ),
        '[1/3]',
      );
    });

    test('stale scenario position is ignored in query mode too', () {
      expect(
        resolveQueuePrefix(
          tagView: null,
          scenarioPos: (index: 36, count: 120),
          scenarioOwnsPlayback: false,
          isQueryMode: true,
          queryVirtualPos: 0,
          queryTotalCount: 8,
          queueLength: 1,
          currentQueueIndex: 0,
        ),
        '[1/8]',
      );
    });

    // An external feed takes the context away from the scenario, so the paged
    // queue becomes the authority again — but only while it actually holds
    // something. A teardown empties it (totalCount 0) and its virtual position
    // stays at 0, which used to render a bare `[1/0]` next to the placeholder
    // title.
    test('an emptied queue yields no prefix instead of [1/0]', () {
      expect(
        resolveQueuePrefix(
          tagView: null,
          scenarioPos: null,
          scenarioOwnsPlayback: false,
          isQueryMode: true,
          queryVirtualPos: 0,
          queryTotalCount: 0,
          queueLength: 0,
          currentQueueIndex: 0,
        ),
        isNull,
      );
    });

    // The scenario's own count is the one number here that no caller can
    // guarantee is non-zero: `_emitPosition` resolves the INDEX and the TOTAL
    // through two independent async reads, so an emptied / rebuilding effective
    // stream publishes `(3, 0)`. The queue branches all guard against a bare
    // `[1/0]`; the scenario branch has to hold the same line.
    test('a scenario position with an empty total yields no prefix', () {
      expect(
        resolveQueuePrefix(
          tagView: null,
          scenarioPos: (index: 3, count: 0),
          scenarioOwnsPlayback: true,
          isQueryMode: true,
          queryVirtualPos: 0,
          queryTotalCount: 12,
          queueLength: 1,
          currentQueueIndex: 0,
        ),
        isNull,
      );
    });
  });
}
