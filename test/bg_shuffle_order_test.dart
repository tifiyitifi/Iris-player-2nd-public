import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/services/background_tag_pool.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';

/// 副音's shuffle is a background-local permutation of the resolved candidate
/// stream, NOT a write into the shared reserved-tag view state (that reordered
/// the foreground browser of the same tag). The permutation must be
/// deterministic: the queue window, a slide (`windowAt`) and the 副音 browser
/// all resolve the stream independently and must agree on the order.
void main() {
  test('seed 0 leaves the order untouched', () {
    final input = [for (var i = 0; i < 10; i++) i];
    expect(shuffleBySeed(input, 0), input);
    expect(shuffleBySeed([1], 12345), [1]);
  });

  test('the same seed always yields the same order', () {
    final input = [for (var i = 0; i < 30; i++) i];
    expect(shuffleBySeed(input, 987654), shuffleBySeed(input, 987654));
  });

  test('the result is a permutation of the input', () {
    final input = [for (var i = 0; i < 30; i++) i];
    final out = shuffleBySeed(input, 42);
    expect(out, hasLength(input.length));
    expect(out.toSet(), input.toSet());
    expect(input, [for (var i = 0; i < 30; i++) i],
        reason: 'the input must not be mutated in place');
  });

  test('different seeds generally produce different orders', () {
    final input = [for (var i = 0; i < 30; i++) i];
    expect(shuffleBySeed(input, 1), isNot(shuffleBySeed(input, 2)));
  });

  test('renumbering after the shuffle keeps virtualIndex == position', () {
    final items = [
      for (var i = 0; i < 12; i++)
        EffectivePlaybackItem(
          media: MediaNode.file(
            id: 's$i',
            storageId: 's',
            path: <String>['$i.mp4'],
            name: '$i.mp4',
            mediaType: MediaType.video,
          ),
          scenarioId: 'bg',
          // The resolver numbered them in ITS order; the shuffle then moved
          // them, so these no longer describe positions.
          virtualIndex: i,
          occurrenceId: PlaybackOccurrenceId(storageId: 's', path: '$i.mp4'),
        ),
    ];
    final shuffled = renumberVirtualIndexes(shuffleBySeed(items, 4242));
    expect(shuffled, hasLength(items.length));
    for (var i = 0; i < shuffled.length; i++) {
      expect(shuffled[i].virtualIndex, i,
          reason: 'jumpToOccurrence indexes the stream by this value');
    }
    // The identity carried by each row is preserved (only the index moved).
    expect(shuffled.map((e) => e.mediaKey).toSet(),
        items.map((e) => e.mediaKey).toSet());
  });
}
