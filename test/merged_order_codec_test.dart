import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/resolver/bit_vector.dart';
import 'package:iris/features/scenario_playback/resolver/merged_order_codec.dart';
import 'package:iris/features/scenario_playback/resolver/shared_index_codec.dart';

/// The global base order is stored as the interleaving of the streams' shared
/// orders. The format is the one thing a bad build can silently corrupt, so it
/// is validated on encode AND on decode.
void main() {
  List<({int stream, int rank})> interleaved(int streamCount, int length) => [
        for (var i = 0; i < length; i++)
          (stream: i % streamCount, rank: i ~/ streamCount),
      ];

  List<int> countsOf(List<({int stream, int rank})> entries, int streams) {
    final counts = List<int>.filled(streams, 0);
    for (final e in entries) {
      counts[e.stream]++;
    }
    return counts;
  }

  List<MergedOrderStream> streamsFor(
    List<({int stream, int rank})> entries,
    int streamCount, {
    /// Length of every stream's order. Defaults to the contribution count, i.e.
    /// a DENSE order; a sparse (sub-range) contribution passes a larger value.
    int? orderLength,
  }) {
    final counts = countsOf(entries, streamCount);
    return [
      for (var i = 0; i < streamCount; i++)
        MergedOrderStream(
          orderKey: 'k$i',
          mediaRev: i,
          count: counts[i],
          orderLength: orderLength ?? counts[i],
        ),
    ];
  }

  test('round-trips an interleaved order (at + forEach)', () {
    final entries = interleaved(2, 200);
    final bytes = MergedOrder.encodeEntries(
      streams: streamsFor(entries, 2),
      entries: entries,
    );
    final order = MergedOrder.decode(bytes)!;
    expect(order.length, entries.length);
    for (var i = 0; i < entries.length; i++) {
      expect(order.at(i), entries[i], reason: 'entry $i');
    }
    final visited = <({int stream, int rank})>[];
    order.forEach((i, stream, rank) {
      expect(i, visited.length);
      visited.add((stream: stream, rank: rank));
    });
    expect(visited, entries);
  });

  for (final length in [1, 63, 64, 65, 127, 128, 129]) {
    test('checkpoint boundaries: length $length', () {
      final entries = interleaved(3, length);
      final order = MergedOrder.decode(MergedOrder.encodeEntries(
        streams: streamsFor(entries, 3),
        entries: entries,
      ))!;
      for (var i = 0; i < length; i++) {
        expect(order.at(i), entries[i], reason: 'entry $i');
      }
      expect(order.decodeBudgetAt(0), 64);
      if (length > 1) expect(order.decodeBudgetAt(1), 63);
    });
  }

  test('31 streams pack the stream index into 5 bits', () {
    const streamCount = 31;
    final entries = interleaved(streamCount, streamCount * 5);
    final order = MergedOrder.decode(MergedOrder.encodeEntries(
      streams: streamsFor(entries, streamCount),
      entries: entries,
    ))!;
    for (var i = 0; i < entries.length; i++) {
      expect(order.at(i), entries[i]);
    }
  });

  test('an extreme interleave (A0 B0 A1 B1 …) stays 1-2 bytes per entry', () {
    final entries = interleaved(2, 5000);
    final bytes = MergedOrder.encodeEntries(
      streams: streamsFor(entries, 2),
      entries: entries,
    );
    expect(bytes.length / entries.length, lessThan(2.0),
        reason: 'the merged encoding must not approach the 4 B id list');
  });

  test('a repeated rank is legal (duplicate occurrence) and round-trips', () {
    final streams2 = [
      const MergedOrderStream(
          orderKey: 'a', mediaRev: 0, count: 3, orderLength: 3),
      const MergedOrderStream(
          orderKey: 'b', mediaRev: 0, count: 1, orderLength: 1),
    ];
    final entries = <({int stream, int rank})>[
      (stream: 0, rank: 1),
      (stream: 0, rank: 1),
      (stream: 0, rank: 2),
      (stream: 1, rank: 0),
    ];
    final order =
        MergedOrder.decode(MergedOrder.encodeEntries(streams: streams2, entries: entries))!;
    expect(order.length, entries.length);
    for (var i = 0; i < entries.length; i++) {
      expect(order.at(i), entries[i], reason: 'entry $i');
    }
  });

  test('a DECREASING rank within its stream is refused', () {
    final streams2 = [
      const MergedOrderStream(
          orderKey: 'a', mediaRev: 0, count: 2, orderLength: 2),
      const MergedOrderStream(
          orderKey: 'b', mediaRev: 0, count: 1, orderLength: 1),
    ];
    expect(
      () => MergedOrder.encodeEntries(streams: streams2, entries: const [
        (stream: 0, rank: 1),
        (stream: 0, rank: 0),
        (stream: 1, rank: 0),
      ]),
      throwsArgumentError,
    );
  });

  test('a SPARSE (sub-range) contribution round-trips: ranks are positions in '
      'the order, not ordinals of the contribution', () {
    // The scenario covers two folders of a storage whose order also holds an
    // unrelated folder in between, so the contributed ranks are 0 and 2 while
    // the stream only contributes 2 entries. Bounding a rank by the COUNT would
    // refuse this — and every multi-folder scenario in a real library.
    final streams2 = [
      const MergedOrderStream(
          orderKey: 'k0', mediaRev: 0, count: 2, orderLength: 3),
      const MergedOrderStream(
          orderKey: 'k1', mediaRev: 0, count: 1, orderLength: 5),
    ];
    final entries = <({int stream, int rank})>[
      (stream: 0, rank: 0),
      (stream: 1, rank: 4),
      (stream: 0, rank: 2),
    ];
    final order =
        MergedOrder.decode(MergedOrder.encodeEntries(streams: streams2, entries: entries));
    expect(order, isNotNull, reason: 'a gap between ranks is legal');
    for (var i = 0; i < entries.length; i++) {
      expect(order!.at(i), entries[i], reason: 'entry $i');
    }
    expect(order!.streams[0].orderLength, 3);
  });

  test('a rank outside its ORDER is refused', () {
    expect(
      () => MergedOrder.encodeEntries(
        streams: const [
          MergedOrderStream(
              orderKey: 'a', mediaRev: 0, count: 1, orderLength: 2),
        ],
        entries: const [(stream: 0, rank: 2)],
      ),
      throwsArgumentError,
      reason: 'the order only holds 2 positions',
    );
  });

  test('a declared count that disagrees with the entries is refused', () {
    expect(
      () => MergedOrder.encodeEntries(
        streams: const [
          MergedOrderStream(
              orderKey: 'a', mediaRev: 0, count: 5, orderLength: 5),
          MergedOrderStream(
              orderKey: 'b', mediaRev: 0, count: 1, orderLength: 1),
        ],
        entries: const [(stream: 0, rank: 0), (stream: 1, rank: 0)],
      ),
      throwsArgumentError,
    );
  });

  test('corrupt payloads decode to null, never to a wrong order', () {
    final entries = interleaved(2, 130);
    final bytes = MergedOrder.encodeEntries(
      streams: streamsFor(entries, 2),
      entries: entries,
    );

    expect(MergedOrder.decode(Uint8List(0)), isNull);
    expect(MergedOrder.decode(Uint8List.fromList([99, 1, 2, 3])), isNull);
    expect(MergedOrder.decode(bytes.sublist(0, bytes.length - 3)), isNull,
        reason: 'a truncated checkpoint/payload must be refused');
    // A flipped payload byte breaks rank monotonicity or the checkpoint table.
    final flipped = Uint8List.fromList(bytes);
    flipped[flipped.length - 1] |= 0x40;
    expect(MergedOrder.decode(flipped), isNull);
  });

  group('SharedIndexCodec v4', () {
    test('a merged base order round-trips through the slices blob', () {
      final entries = interleaved(3, 70);
      final merged = MergedOrder.decode(MergedOrder.encodeEntries(
        streams: streamsFor(entries, 3),
        entries: entries,
      ))!;

      final decoded = SharedIndexCodec.decodeSlices(
          SharedIndexCodec.encodeSlices(MultiBaseOrder(merged)));

      expect(decoded, isA<MultiBaseOrder>());
      final order = (decoded as MultiBaseOrder).order;
      expect(order.length, entries.length);
      for (var i = 0; i < entries.length; i++) {
        expect(order.at(i), entries[i]);
      }
    });

    test('the single (bitmap) form still round-trips beside it', () {
      final bits = BitVectorBuilder(64)..set(3)..set(60);
      final decoded = SharedIndexCodec.decodeSlices(SharedIndexCodec.encodeSlices(
        SingleBaseOrder([(orderKey: 'k', mediaRev: 7, bits: bits.build())]),
      ));
      expect(decoded, isA<SingleBaseOrder>());
      expect(decoded.singleSlices.single.orderKey, 'k');
      expect(decoded.singleSlices.single.mediaRev, 7);
      expect(decoded.singleSlices.single.bits.count, 2);
    });

    test('a pre-v4 blob is rejected instead of mis-parsed', () {
      final legacy = Uint8List.fromList([3, 1, 0, 0]);
      expect(() => SharedIndexCodec.decodeSlices(legacy),
          throwsA(isA<FormatException>()));
    });
  });
}
