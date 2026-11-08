import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/resolver/base_order_view.dart';
import 'package:iris/features/scenario_playback/resolver/bit_vector.dart';
import 'package:iris/features/scenario_playback/resolver/merged_order_codec.dart';
import 'package:iris/features/scenario_playback/resolver/shared_base_order.dart';

/// Both base-order representations must answer the SAME questions the same way,
/// because the overlay and the row source never learn which one they got.
void main() {
  BitVector bits(int length, Iterable<int> set) =>
      BitVector.fromSetBits(length, set);

  group('SharedBaseOrder', () {
    test('nodeIdAt follows the slice order and the accepted bitmap', () {
      final slice = SharedOrderSlice(
        orderKey: 'k',
        order: Int32List.fromList([10, 20, 30, 40]),
        bits: bits(4, [0, 2, 3]),
      );
      final base = SharedBaseOrder(
        slices: [slice],
        accepted: bits(3, [0, 1, 2]),
      );

      expect(base.virtualSize, 3);
      expect(base.count, 3);
      expect([for (var i = 0; i < 3; i++) base.nodeIdAt(i)], [10, 30, 40]);
      expect(base.nodeIdAt(3), isNull);
    });

    test('acceptedRanksOfNode maps every hit (duplicates included)', () {
      // Two slices can describe the same file (overlapping sources). Dedup drops
      // the later one from `accepted`, exactly like the resolver does.
      final a = SharedOrderSlice(
        orderKey: 'a',
        order: Int32List.fromList([7, 8]),
        bits: bits(2, [0, 1]),
      );
      final b = SharedOrderSlice(
        orderKey: 'b',
        order: Int32List.fromList([8, 9]),
        bits: bits(2, [0, 1]),
      );
      final base = SharedBaseOrder(
        slices: [a, b],
        // virtual = [7, 8 | 8, 9]; the second 8 is deduped away.
        accepted: bits(4, [0, 1, 3]),
      );

      expect(base.acceptedRanksOfNode(8).toList(), [1]);
      expect(base.acceptedRanksOfNode(9).toList(), [2]);
      expect(base.acceptedRanksOfNode(1234), isEmpty);
    });

    test('a repeated node in the SAME order yields one rank per occurrence', () {
      final slice = SharedOrderSlice(
        orderKey: 'k',
        order: Int32List.fromList([5, 6, 5]),
        bits: bits(3, [0, 1, 2]),
      );
      final base = SharedBaseOrder(
        slices: [slice],
        accepted: bits(3, [0, 1, 2]),
      );

      expect(base.acceptedRanksOfNode(5).toList(), [0, 2]);
    });
  });

  group('MergedBaseOrder', () {
    MergedBaseOrder build({
      required List<Int32List> orders,
      required List<({int stream, int rank})> entries,
      required Iterable<int> accepted,
      int placeholders = 0,
    }) {
      // `count` is the number of ENTRIES a stream contributes, which can exceed
      // its order length when an overlapping source repeats a position.
      final counts = List<int>.filled(orders.length, 0);
      for (final e in entries) {
        counts[e.stream]++;
      }
      final streams = [
        for (var i = 0; i < orders.length; i++)
          MergedOrderStream(
            orderKey: 'k$i',
            mediaRev: 1,
            count: counts[i],
            orderLength: orders[i].length,
          ),
      ];
      final order = MergedOrder.decode(
        MergedOrder.encodeEntries(streams: streams, entries: entries),
      )!;
      final length = entries.length + placeholders;
      return MergedBaseOrder(
        order: order,
        orders: orders,
        accepted: bits(length, accepted),
        placeholderCount: placeholders,
      );
    }

    test('nodeIdAt interleaves the streams', () {
      final base = build(
        orders: [
          Int32List.fromList([10, 30]),
          Int32List.fromList([20, 40]),
        ],
        entries: const [
          (stream: 0, rank: 0),
          (stream: 1, rank: 0),
          (stream: 0, rank: 1),
          (stream: 1, rank: 1),
        ],
        accepted: [0, 1, 2, 3],
      );

      expect(base.virtualSize, 4);
      expect(base.count, 4);
      expect([for (var i = 0; i < 4; i++) base.nodeIdAt(i)], [10, 20, 30, 40]);
    });

    test('placeholder tail has no node id and still counts as virtual space',
        () {
      final base = build(
        orders: [
          Int32List.fromList([10]),
          Int32List.fromList([20]),
        ],
        entries: const [(stream: 0, rank: 0), (stream: 1, rank: 0)],
        accepted: [0, 1, 2, 3],
        placeholders: 2,
      );

      expect(base.virtualSize, 4);
      expect(base.count, 4);
      expect(base.nodeIdAt(0), 10);
      expect(base.nodeIdAt(1), 20);
      expect(base.nodeIdAt(2), isNull);
      expect(base.nodeIdAt(3), isNull);
    });

    test('acceptedRanksOfNode sees duplicate occurrences', () {
      // The same shared position appears twice (an overlapping source): two
      // accepted ranks map to the same node.
      final base = build(
        orders: [
          Int32List.fromList([10, 20]),
          Int32List.fromList([20]),
        ],
        entries: const [
          (stream: 1, rank: 0),
          (stream: 0, rank: 0),
          (stream: 0, rank: 1),
          (stream: 1, rank: 0),
        ],
        accepted: [0, 1, 2, 3],
      );

      expect(base.count, 4);
      expect(base.acceptedRanksOfNode(20).toList(), [0, 2, 3]);
      expect(base.acceptedRanksOfNode(999), isEmpty);
    });
  });
}
