import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_scope_logic.dart';

/// A Virtual Merge ITEM switch steps the 副音 queue. It used to always step
/// FORWARD, so 「上一集」 pushed 副音 onto the next track — the same defect the
/// foreground queue cured with `isForwardQueueMove`. The queue's own move stamp
/// is the only signal that can tell 「上一集」 at the head from a tap on the last
/// row, so it wins whenever it describes the current move.
void main() {
  test('the queue move stamp wins over the VM queue indices', () {
    expect(
      vmBgStepForward(
        moveWasForward: false,
        previousQueueIndex: 0,
        queueIndex: 5,
      ),
      isFalse,
      reason: 'a stamped backward move cannot be re-derived from indices',
    );
    expect(
      vmBgStepForward(
        moveWasForward: true,
        previousQueueIndex: 9,
        queueIndex: 0,
      ),
      isTrue,
      reason: 'next() wrapped off the end: the stamp is authoritative',
    );
  });

  test('without a stamp a lower VM queue index steps backward', () {
    expect(
      vmBgStepForward(previousQueueIndex: 4, queueIndex: 3),
      isFalse,
    );
    expect(
      vmBgStepForward(previousQueueIndex: 3, queueIndex: 4),
      isTrue,
    );
  });

  test('an unresolvable switch keeps the forward default', () {
    expect(vmBgStepForward(previousQueueIndex: null, queueIndex: 2), isTrue);
    expect(vmBgStepForward(previousQueueIndex: 2, queueIndex: 2), isTrue);
  });
}
