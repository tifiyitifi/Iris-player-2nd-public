import 'package:flutter_test/flutter_test.dart';
import 'package:iris/utils/cooperative_yield.dart';

/// The scan's deliberate yields are budgeted by wall-clock time, not by step
/// count: one per directory (plus one per child) used to be ~100k timer events
/// on a 34k-directory volume, measured at 25.8 s of a 125 s scan.
void main() {
  test('a fresh gate works for a full frame before yielding', () {
    var now = 0;
    final gate = CooperativeYield(
      elapsedMs: () => now,
      budget: const Duration(milliseconds: 16),
    );

    // Constructing the gate counts as "just yielded", so a caller that has only
    // done a few microseconds of work does not pay a timer.
    expect(gate.takeYieldSlot(), isFalse);

    for (var i = 0; i < 15; i++) {
      now += 1;
      expect(gate.takeYieldSlot(), isFalse, reason: 'still inside the frame');
    }
  });

  test('yields once the budget elapsed, then starts a new frame', () {
    var now = 0;
    final gate = CooperativeYield(
      elapsedMs: () => now,
      budget: const Duration(milliseconds: 16),
    );

    now = 16;
    expect(gate.takeYieldSlot(), isTrue, reason: 'one frame has passed');
    now = 20;
    expect(gate.takeYieldSlot(), isFalse,
        reason: 'the clock restarted at the yield');
    now = 33;
    expect(gate.takeYieldSlot(), isTrue);
  });

  test('a long step yields immediately afterwards', () {
    var now = 0;
    final gate = CooperativeYield(
      elapsedMs: () => now,
      budget: const Duration(milliseconds: 16),
    );

    now = 500; // e.g. a slow directory listing
    expect(gate.takeYieldSlot(), isTrue);
  });

  test('reset suppresses the next yield', () {
    var now = 0;
    final gate = CooperativeYield(
      elapsedMs: () => now,
      budget: const Duration(milliseconds: 16),
    );

    now = 100;
    gate.reset();
    expect(gate.takeYieldSlot(), isFalse);
  });

  test('maybeYield completes even when the budget is unspent', () async {
    var now = 0;
    final gate = CooperativeYield(
      elapsedMs: () => now,
      budget: const Duration(milliseconds: 16),
    );
    now = 1;
    await gate.maybeYield();
    now = 100;
    await gate.maybeYield();
  });
}
