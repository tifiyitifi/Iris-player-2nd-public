import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/playback/vm_timeline_ownership.dart';

/// The 简播 (fake-cut) resolver replaces the opened source with an EDL, so it
/// must never run while Virtual Media owns the timeline — including the switch
/// window in which `isActive` is still false. The hook used to consult
/// `isActive` alone and stacked an EDL on the segment a VM feed was opening.
void main() {
  test('an inactive, idle VM does not own the timeline', () {
    expect(
      vmOwnsTimeline(
          isActive: false, feedInFlight: false, transitioning: false),
      isFalse,
    );
  });

  test('a landed VM session owns it', () {
    expect(
      vmOwnsTimeline(isActive: true, feedInFlight: false, transitioning: false),
      isTrue,
    );
  });

  test('a feed in flight owns it before isActive flips', () {
    expect(
      vmOwnsTimeline(isActive: false, feedInFlight: true, transitioning: false),
      isTrue,
    );
  });

  test('a pending transition owns it before the feed starts', () {
    expect(
      vmOwnsTimeline(isActive: false, feedInFlight: false, transitioning: true),
      isTrue,
    );
  });
}
