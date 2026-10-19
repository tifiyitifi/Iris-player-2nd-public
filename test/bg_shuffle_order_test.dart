import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/services/background_tag_pool.dart';

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
}
