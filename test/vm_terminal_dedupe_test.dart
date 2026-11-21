import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';

/// A terminal event (error/completed) arriving while a previous terminal event
/// is still driving a transition/feed must be dropped — otherwise one broken
/// file advances two segments.
///
/// The guard deliberately ignores event identity: `advance()` moves
/// `segmentIndex` BEFORE the new feed lands, so a duplicate for the old file
/// would be re-keyed to the new segment and look different.
void main() {
  group('shouldDropVmTerminalEvent', () {
    test('drops any terminal event while transitioning', () {
      expect(
        shouldDropVmTerminalEvent(
          handledKey: 'scope:1:key-b',
          transitioning: true,
          feedInFlight: false,
        ),
        isTrue,
      );
    });

    test('drops any terminal event while a feed is in flight', () {
      expect(
        shouldDropVmTerminalEvent(
          handledKey: 'scope:1:key-b',
          transitioning: false,
          feedInFlight: true,
        ),
        isTrue,
      );
    });

    test('drops a re-keyed duplicate after the index advanced', () {
      // The previous event moved segmentIndex 1 -> 2; the incoming event is
      // still the same physical file but now reads as a different key.
      expect(
        shouldDropVmTerminalEvent(
          handledKey: 'scope:1:key-b',
          transitioning: true,
          feedInFlight: true,
        ),
        isTrue,
      );
    });

    test('handles a terminal event when no event is in flight', () {
      expect(
        shouldDropVmTerminalEvent(
          handledKey: null,
          transitioning: false,
          feedInFlight: false,
        ),
        isFalse,
      );
    });

    test('a settled guard with no transition does not drop', () {
      expect(
        shouldDropVmTerminalEvent(
          handledKey: 'scope:1:key-b',
          transitioning: false,
          feedInFlight: false,
        ),
        isFalse,
      );
    });
  });
}
