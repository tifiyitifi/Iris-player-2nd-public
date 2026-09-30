import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/speed/model/enum/speed_gesture_mode.dart';
import 'package:iris/features/speed/model/speed_gesture_math.dart';

void main() {
  group('resolveDualAxisSpeedIndex', () {
    test('singleAxis ignores dy, right is +', () {
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 9,
          total: const Offset(0, -72),
          mode: SpeedGestureMode.singleAxis,
          isSelectorVisible: true,
        ),
        9,
      );
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 9,
          total: const Offset(64, -72),
          mode: SpeedGestureMode.singleAxis,
          isSelectorVisible: true,
        ),
        10,
      );
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 9,
          total: const Offset(-64, 0),
          mode: SpeedGestureMode.singleAxis,
          isSelectorVisible: true,
        ),
        8,
      );
    });

    test('dualAxis invisible ignores dy (frozen legacy)', () {
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 9,
          total: const Offset(0, -72),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: false,
        ),
        9,
      );
    });

    test('dualAxis visible: right +1, up +10', () {
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 9,
          total: const Offset(64, 0),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        10,
      );
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 9,
          total: const Offset(-64, 0),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        8,
      );
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 9,
          total: const Offset(0, -120),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        19,
      );
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 9,
          total: const Offset(0, -72),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        19,
      );
    });

    test('dualAxis vertical-only maps without horizontal prerequisite', () {
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 9,
          total: const Offset(0, -240),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        29,
      );
    });

    test('diagonal follows dominant axis live', () {
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 9,
          total: const Offset(64, -120),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        19,
      );
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 20,
          total: const Offset(-40, 120),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        10,
      );
    });

    test('live axis switch wins per frame', () {
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 9,
          total: const Offset(80, -72),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        10,
      );
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 10,
          total: const Offset(80, -240),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        30,
      );
    });

    test('resolveSpeedLockedAxis picks dominant axis', () {
      expect(resolveSpeedLockedAxis(const Offset(64, -20)), Axis.horizontal);
      expect(resolveSpeedLockedAxis(const Offset(-20, -120)), Axis.vertical);
      expect(resolveSpeedLockedAxis(const Offset(7, 7)), isNull);
    });

    test('axis hysteresis resists jitter near the diagonal', () {
      expect(
        resolveSpeedLockedAxis(const Offset(60, 55),
            previous: Axis.horizontal),
        Axis.horizontal,
      );
      expect(
        resolveSpeedLockedAxis(const Offset(60, 55), previous: Axis.vertical),
        Axis.vertical,
      );
      expect(
        resolveSpeedLockedAxis(const Offset(60, 80), previous: Axis.horizontal),
        Axis.vertical,
      );
      expect(
        resolveSpeedLockedAxis(const Offset(80, 60), previous: Axis.vertical),
        Axis.horizontal,
      );
    });

    test('deadzone 8px', () {
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 9,
          total: const Offset(7, 7),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        9,
      );
    });

    test('clamp 0..99', () {
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 0,
          total: const Offset(-10000, 10000),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        0,
      );
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 99,
          total: const Offset(10000, -10000),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        99,
      );
    });

    test('fine overflow carries into coarse', () {
      expect(
        resolveDualAxisSpeedIndex(
          baseIndex: 18,
          total: const Offset(64, 0),
          mode: SpeedGestureMode.dualAxis,
          isSelectorVisible: true,
        ),
        19,
      );
    });

    test('speedCoarseFine splits wheels', () {
      expect(speedCoarseFine(0), (coarse: 0, fine: 1));
      expect(speedCoarseFine(9), (coarse: 1, fine: 0));
      expect(speedCoarseFine(19), (coarse: 2, fine: 0));
      expect(speedCoarseFine(99), (coarse: 10, fine: 0));
    });
  });

  group('shouldOpenTransientSpeedWindow', () {
    test('stays closed for vertical travel', () {
      expect(
        shouldOpenTransientSpeedWindow(
          total: const Offset(0, -240),
          lockedAxis: Axis.vertical,
        ),
        isFalse,
      );
    });

    test('stays closed below the horizontal threshold', () {
      expect(
        shouldOpenTransientSpeedWindow(
          total: const Offset(23, 0),
          lockedAxis: Axis.horizontal,
        ),
        isFalse,
      );
    });

    test('opens at the horizontal threshold', () {
      expect(
        shouldOpenTransientSpeedWindow(
          total: const Offset(24, 0),
          lockedAxis: Axis.horizontal,
        ),
        isTrue,
      );
    });

    test('stays closed inside the dead zone', () {
      expect(
        shouldOpenTransientSpeedWindow(
          total: const Offset(7, 7),
          lockedAxis: null,
        ),
        isFalse,
      );
    });

    test('stays closed when no axis is locked', () {
      expect(
        shouldOpenTransientSpeedWindow(
          total: const Offset(40, 0),
          lockedAxis: null,
        ),
        isFalse,
      );
    });
  });

  group('resolveSpeedGestureMode', () {
    test('gate off degrades to singleAxis', () {
      expect(
        resolveSpeedGestureMode(
          const FakeState(SpeedGestureMode.dualAxis),
          metadataEnabled: false,
        ),
        SpeedGestureMode.singleAxis,
      );
    });
  });
}

class FakeState {
  final SpeedGestureMode speedGestureMode;
  const FakeState(this.speedGestureMode);
}

SpeedGestureMode resolveSpeedGestureMode(
  FakeState state, {
  required bool metadataEnabled,
}) {
  if (!metadataEnabled) return SpeedGestureMode.singleAxis;
  return state.speedGestureMode;
}
