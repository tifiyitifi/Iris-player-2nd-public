import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/playback/mirror_target_policy.dart';

/// The receiving window must play the entry the SOURCE window named, or nothing
/// at all. These cases pin the two allowed answers; "play a different entry" is
/// never one of them.
void main() {
  test('an absent key trusts the index (payloads from older builds)', () {
    expect(neighborTargetMatches(expectedKey: null, actualKey: 'a:1'), isTrue);
    expect(neighborTargetMatches(expectedKey: '', actualKey: 'a:1'), isTrue);
  });

  test('a shipped key must match the resolved entry exactly', () {
    expect(neighborTargetMatches(expectedKey: 'a:1', actualKey: 'a:1'), isTrue);
    expect(neighborTargetMatches(expectedKey: 'a:1', actualKey: 'a:2'), isFalse);
    expect(
      neighborTargetMatches(expectedKey: 'a:1', actualKey: 'b:1'),
      isFalse,
      reason: 'a shifted index that lands on a neighbour must not be played',
    );
  });
}
