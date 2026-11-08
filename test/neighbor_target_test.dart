import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_instance/controller/neighbor_target.dart';

/// Boundary rules for Shift+PageUp/PageDown neighbour playback. The step itself
/// lives in the receiving window; only "is there a neighbour, and which index"
/// is decided here, so it is pinned down without stores or a database.
void main() {
  group('resolveNeighborIndex', () {
    test('steps inside the queue', () {
      expect(
          resolveNeighborIndex(index: 1, count: 3, forward: true, wrap: false),
          2);
      expect(
          resolveNeighborIndex(index: 1, count: 3, forward: false, wrap: false),
          0);
    });

    test('stops at the tail/head without wrap', () {
      expect(
          resolveNeighborIndex(index: 2, count: 3, forward: true, wrap: false),
          isNull);
      expect(
          resolveNeighborIndex(index: 0, count: 3, forward: false, wrap: false),
          isNull);
    });

    test('wraps at the tail/head with wrap (Repeat.all)', () {
      expect(
          resolveNeighborIndex(index: 2, count: 3, forward: true, wrap: true),
          0);
      expect(
          resolveNeighborIndex(index: 0, count: 3, forward: false, wrap: true),
          2);
    });

    test('a single-item queue only wraps onto itself', () {
      expect(
          resolveNeighborIndex(index: 0, count: 1, forward: true, wrap: false),
          isNull);
      expect(
          resolveNeighborIndex(index: 0, count: 1, forward: true, wrap: true),
          0);
    });

    test('an empty or out-of-range queue has no neighbour', () {
      expect(
          resolveNeighborIndex(index: 0, count: 0, forward: true, wrap: true),
          isNull);
      expect(
          resolveNeighborIndex(index: -1, count: 3, forward: true, wrap: true),
          isNull);
      expect(
          resolveNeighborIndex(index: 3, count: 3, forward: false, wrap: true),
          isNull);
    });
  });
}
