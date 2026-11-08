import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/resolver/bit_vector.dart';
import 'package:iris/features/scenario_playback/resolver/shared_index_codec.dart';
import 'package:iris/features/scenario_playback/resolver/shared_row_overlay.dart';

/// The codec is the on-disk format of the shared-order index, so every part must
/// round-trip exactly and reject an unknown version rather than mis-parse.
void main() {
  test('bitmaps round-trip across word boundaries', () {
    for (final length in const [0, 1, 63, 64, 65, 512, 513, 5000]) {
      final builder = BitVectorBuilder(length);
      for (var i = 0; i < length; i += 3) {
        builder.set(i);
      }
      final bitmap = builder.build();
      final restored =
          SharedIndexCodec.decodeBitmap(SharedIndexCodec.encodeBitmap(bitmap));
      expect(restored.length, bitmap.length);
      expect(restored.count, bitmap.count);
      for (var i = 0; i < length; i++) {
        expect(restored[i], bitmap[i], reason: 'bit $i of $length');
      }
    }
  });

  test('slices round-trip (order key + media revision + bitmap)', () {
    final a = BitVectorBuilder(100)..set(0)..set(99);
    final b = BitVectorBuilder(7)..set(6);
    final slices = [
      (
        orderKey: 'v1|st1|name|asc|g|video,audio',
        mediaRev: 42,
        bits: a.build()
      ),
      (orderKey: '', mediaRev: 0, bits: b.build()),
    ];
    final decoded = SharedIndexCodec.decodeSlices(
        SharedIndexCodec.encodeSlices(SingleBaseOrder(slices)));
    expect(decoded, isA<SingleBaseOrder>());
    final roundTripped = decoded.singleSlices;
    expect(roundTripped.length, 2);
    for (var i = 0; i < 2; i++) {
      expect(roundTripped[i].orderKey, slices[i].orderKey);
      expect(roundTripped[i].mediaRev, slices[i].mediaRev);
      expect(roundTripped[i].bits.toBytes(), slices[i].bits.toBytes());
    }
  });

  test('group rows round-trip (members, absent member, occurrence, duration)',
      () {
    final groups = [
      SharedGroupRow(
        anchorRank: 3,
        ruleId: 'r1',
        rootPath: '/m',
        chunkNo: 1,
        members: Int32List.fromList([10, 11, -1]),
        memberOccurrence: const {1: 2},
        totalDurationMs: 1234567,
      ),
      SharedGroupRow(
        anchorRank: 40,
        ruleId: 'r2',
        rootPath: '/n',
        chunkNo: 2,
        members: Int32List.fromList([20]),
      ),
    ];
    final decoded =
        SharedIndexCodec.decodeGroups(SharedIndexCodec.encodeGroups(groups));
    expect(decoded.length, 2);
    for (var i = 0; i < 2; i++) {
      expect(decoded[i].anchorRank, groups[i].anchorRank);
      expect(decoded[i].groupId, groups[i].groupId);
      expect(decoded[i].members, groups[i].members);
      expect(decoded[i].memberOccurrence, groups[i].memberOccurrence);
      // Stored verbatim, never re-derived from the members: a member the
      // scenario's stream does not contain keeps its duration in the VM item but
      // has no node id here.
      expect(decoded[i].totalDurationMs, groups[i].totalDurationMs);
    }
    // A group with no members still round-trips.
    final empty = SharedGroupRow(
        anchorRank: 0, ruleId: 'r', rootPath: '', chunkNo: 0, members: Int32List(0));
    final decodedEmpty = SharedIndexCodec.decodeGroups(
        SharedIndexCodec.encodeGroups([empty]));
    expect(decodedEmpty.single.members, isEmpty);
    expect(decodedEmpty.single.memberOccurrence, isEmpty);
  });

  test('group rows intern the rule/path prefix', () {
    // 200 groups of one rule/path: the 36-char rule id must be stored ONCE, not
    // 200 times (that is the whole point of the interning).
    const ruleId = '00000000-0000-4000-8000-000000000000';
    final groups = [
      for (var g = 0; g < 200; g++)
        SharedGroupRow(
          anchorRank: g * 3,
          ruleId: ruleId,
          rootPath: '/some/path',
          chunkNo: g + 1,
          members: Int32List.fromList([g * 3 + 1, g * 3 + 2, g * 3 + 3]),
        ),
    ];
    final blob = SharedIndexCodec.encodeGroups(groups);
    // ~19 B/group (anchor + dict index + chunk + 3 members) vs 36+ B for the
    // bare rule id alone.
    expect(blob.length, lessThan(groups.length * ruleId.length));
    expect(SharedIndexCodec.decodeGroups(blob).length, groups.length);
  });

  test('sparse int maps round-trip (empty and large values)', () {
    expect(SharedIndexCodec.decodeIntMap(
        SharedIndexCodec.encodeIntMap(const {})), isEmpty);
    final values = {0: 1, 5: 300, 1000000: 2147483647};
    expect(SharedIndexCodec.decodeIntMap(
        SharedIndexCodec.encodeIntMap(values)), values);
  });

  test('placeholders round-trip', () {
    final values = {
      7: (storageId: 'st1', path: 'A/gone.mp4'),
      9: (storageId: '', path: ''),
    };
    expect(
        SharedIndexCodec.decodePlaceholders(
            SharedIndexCodec.encodePlaceholders(values)),
        values);
  });

  test('an unknown version is rejected, not mis-parsed', () {
    final good = SharedIndexCodec.encodeIntMap(const {1: 1});
    final bad = Uint8List.fromList(good)..[0] = 99;
    expect(() => SharedIndexCodec.decodeIntMap(bad),
        throwsA(isA<FormatException>()));
    expect(() => SharedIndexCodec.decodeBitmap(bad),
        throwsA(isA<FormatException>()));
  });
}
