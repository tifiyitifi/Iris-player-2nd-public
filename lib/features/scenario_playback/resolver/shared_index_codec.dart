import 'dart:convert';
import 'dart:typed_data';

import 'package:iris/features/scenario_playback/resolver/bit_vector.dart';
import 'package:iris/features/scenario_playback/resolver/merged_order_codec.dart';
import 'package:iris/features/scenario_playback/resolver/shared_row_overlay.dart';

/// One stored base order.
///
/// [SingleBaseOrder] is the v44 shape: one storage's shared order plus a
/// membership bitmap. [MultiBaseOrder] is the v52 shape: a globally sorted base
/// order over several streams, stored as a [MergedOrder] (and used only when the
/// queue is NOT a single storage's filtered subsequence — otherwise the bitmap is
/// both smaller and byte-identical to what older builds wrote).
sealed class StoredBaseOrder {
  const StoredBaseOrder();
}

class SingleBaseOrder extends StoredBaseOrder {
  const SingleBaseOrder(this.slices);

  /// One entry per source, in `sortOrder` (the virtual space is their
  /// concatenation). This is the shape every single-source build still writes.
  final List<({String orderKey, int mediaRev, BitVector bits})> slices;
}

class MultiBaseOrder extends StoredBaseOrder {
  const MultiBaseOrder(this.order);

  final MergedOrder order;
}

extension StoredBaseOrderSlices on StoredBaseOrder {
  /// The concatenation slices, or an empty list for a merged order.
  ///
  /// Convenience for tests and legacy call sites; production code branches on
  /// the kind explicitly so a merged order can never be mistaken for a bitmap.
  List<({String orderKey, int mediaRev, BitVector bits})> get singleSlices =>
      switch (this) {
        SingleBaseOrder(:final slices) => slices,
        MultiBaseOrder() => const [],
      };
}

/// Binary codec for the shared-order derived index blobs.
///
/// These blobs are the bulk of the derived storage, so the format is compact
/// and explicit (varint lengths, little-endian int32, UTF-8 strings) rather than
/// JSON. Every blob starts with a version tag so a future format change is
/// detectable instead of silently mis-parsed.
class SharedIndexCodec {
  const SharedIndexCodec._();

  static const int version = 4;

  /// Slice kinds in the `slices` blob.
  static const int kindSingle = 0;
  static const int kindMerged = 1;

  // ── Bitmaps ──

  /// `[version][length][packed words]` — the length is needed to rebuild the
  /// vector (the byte length alone cannot express a non-multiple of 64).
  static Uint8List encodeBitmap(BitVector bitmap) {
    final w = _Writer()
      ..varint(version)
      ..varint(bitmap.length)
      ..bytes(bitmap.toBytes());
    return w.done();
  }

  static BitVector decodeBitmap(Uint8List data) {
    final r = _Reader(data);
    _checkVersion(r.varint());
    final length = r.varint();
    return BitVector.fromBytes(length, r.bytes());
  }

  // ── Slices ──

  /// `[version][kind]` followed by the kind's payload.
  ///
  /// A [SingleBaseOrder] carries its `(orderKey, mediaRev)` IN the blob so the
  /// read side needs no revision plumbing: it reads the order at the revision
  /// the index was built with, and a newer revision makes the order look absent
  /// (the caller falls back).
  static Uint8List encodeSlices(StoredBaseOrder order) {
    final w = _Writer()..varint(version);
    switch (order) {
      case SingleBaseOrder():
        w
          ..varint(kindSingle)
          ..varint(order.slices.length);
        for (final s in order.slices) {
          w
            ..string(s.orderKey)
            ..varint(s.mediaRev)
            ..bytes(encodeBitmap(s.bits));
        }
      case MultiBaseOrder():
        w
          ..varint(kindMerged)
          ..bytes(order.order.toBytes());
    }
    return w.done();
  }

  static StoredBaseOrder decodeSlices(Uint8List data) {
    final r = _Reader(data);
    _checkVersion(r.varint());
    final kind = r.varint();
    switch (kind) {
      case kindSingle:
        final n = r.varint();
        return SingleBaseOrder([
          for (var i = 0; i < n; i++)
            (
              orderKey: r.string(),
              mediaRev: r.varint(),
              bits: decodeBitmap(r.bytes()),
            ),
        ]);
      case kindMerged:
        final merged = MergedOrder.decode(r.bytes());
        if (merged == null) {
          throw const FormatException('corrupt merged base order');
        }
        return MultiBaseOrder(merged);
      default:
        throw FormatException('unknown base-order kind $kind');
    }
  }

  // ── Element order (VM display order) ──

  /// Version tag of [encodeElementOrder].
  static const int elementOrderVersion = 1;

  /// Encodes the element-axis permutation: `rankByOrdinal[ordinal]` is the base
  /// anchor rank the queue displays at [ordinal].
  ///
  /// Zigzag deltas from the previous ordinal (starting at -1): a VM-sorted view
  /// is NOT monotonic in anchor rank, so a plain delta would go negative.
  static Uint8List encodeElementOrder(Int32List rankByOrdinal) {
    final w = _Writer()
      ..varint(elementOrderVersion)
      ..varint(rankByOrdinal.length);
    var previous = -1;
    for (final rank in rankByOrdinal) {
      w.varint(_zigzag(rank - previous));
      previous = rank;
    }
    return w.done();
  }

  /// Decodes [encodeElementOrder]'s output, or throws [FormatException] when it
  /// is malformed.
  ///
  /// Values are BASE anchor ranks, so their range is the caller's `baseCount`;
  /// here we can only guarantee non-negative, duplicate-free and no trailing
  /// bytes. The read side additionally checks the range against the absorbed
  /// bitmap before trusting the permutation.
  static Int32List decodeElementOrder(Uint8List data) {
    final r = _Reader(data);
    final version = r.varint();
    if (version != elementOrderVersion) {
      throw FormatException('unsupported element-order version $version');
    }
    final count = r.varint();
    if (count < 0) throw const FormatException('negative element count');
    final out = Int32List(count);
    final seen = <int>{};
    var previous = -1;
    for (var i = 0; i < count; i++) {
      final rank = previous + _unzigzag(r.varint());
      if (rank < 0) {
        throw FormatException('negative element rank $rank at $i');
      }
      if (!seen.add(rank)) {
        throw FormatException('duplicate element rank $rank at $i');
      }
      out[i] = rank;
      previous = rank;
    }
    // A trailing payload would mean the blob was written by a different
    // shape — refuse instead of silently ignoring it.
    if (r.pos != data.length) {
      throw const FormatException('trailing bytes in element order');
    }
    return out;
  }

  static int _zigzag(int v) => v >= 0 ? (v << 1) : ((-v) << 1) - 1;

  static int _unzigzag(int v) => (v >> 1) ^ -(v & 1);

  // ── Group rows ──

  /// Encodes group rows with the `(ruleId, rootPath)` prefix INTERNED once per
  /// blob. A group row then costs an anchor + a dictionary index + a chunk
  /// number + its members, instead of repeating the 36-char rule id per group.
  static Uint8List encodeGroups(List<SharedGroupRow> groups) {
    final keyIndex = <String, int>{};
    final keys = <({String ruleId, String rootPath})>[];
    for (final g in groups) {
      final key = '${g.ruleId}\u0000${g.rootPath}';
      if (!keyIndex.containsKey(key)) {
        keyIndex[key] = keys.length;
        keys.add((ruleId: g.ruleId, rootPath: g.rootPath));
      }
    }

    final w = _Writer()
      ..varint(version)
      ..varint(keys.length);
    for (final k in keys) {
      w.string(k.ruleId);
      w.string(k.rootPath);
    }
    w.varint(groups.length);
    for (final g in groups) {
      w.varint(g.anchorRank);
      w.varint(keyIndex['${g.ruleId}\u0000${g.rootPath}']!);
      w.varint(g.chunkNo);
      // The VM item's own total, not a sum of the members below (see
      // `SharedGroupRow.totalDurationMs`).
      w.varint(g.totalDurationMs);
      w.varint(g.members.length);
      for (final id in g.members) {
        w.int32(id);
      }
      w.varint(g.memberOccurrence.length);
      g.memberOccurrence.forEach((position, occurrence) {
        w.varint(position);
        w.varint(occurrence);
      });
    }
    return w.done();
  }

  static List<SharedGroupRow> decodeGroups(Uint8List data) {
    final r = _Reader(data);
    _checkVersion(r.varint());
    final keyCount = r.varint();
    final keys = [
      for (var i = 0; i < keyCount; i++)
        (ruleId: r.string(), rootPath: r.string()),
    ];
    final n = r.varint();
    final out = <SharedGroupRow>[];
    for (var i = 0; i < n; i++) {
      final anchor = r.varint();
      final key = keys[r.varint()];
      final chunkNo = r.varint();
      final totalDurationMs = r.varint();
      final memberCount = r.varint();
      final members = Int32List(memberCount);
      for (var m = 0; m < memberCount; m++) {
        members[m] = r.int32();
      }
      final occCount = r.varint();
      final occurrence = <int, int>{};
      for (var o = 0; o < occCount; o++) {
        occurrence[r.varint()] = r.varint();
      }
      out.add(SharedGroupRow(
        anchorRank: anchor,
        ruleId: key.ruleId,
        rootPath: key.rootPath,
        chunkNo: chunkNo,
        members: members,
        memberOccurrence: occurrence,
        totalDurationMs: totalDurationMs,
      ));
    }
    return out;
  }

  // ── Sparse int maps (file occurrence, raw flags) ──

  static Uint8List encodeIntMap(Map<int, int> values) {
    final w = _Writer()
      ..varint(version)
      ..varint(values.length);
    final keys = values.keys.toList()..sort();
    for (final k in keys) {
      w.varint(k);
      w.varint(values[k]!);
    }
    return w.done();
  }

  static Map<int, int> decodeIntMap(Uint8List data) {
    final r = _Reader(data);
    _checkVersion(r.varint());
    final n = r.varint();
    return {for (var i = 0; i < n; i++) r.varint(): r.varint()};
  }

  // ── Placeholders ──

  static Uint8List encodePlaceholders(
      Map<int, ({String storageId, String path})> values) {
    final w = _Writer()
      ..varint(version)
      ..varint(values.length);
    final keys = values.keys.toList()..sort();
    for (final k in keys) {
      w.varint(k);
      w.string(values[k]!.storageId);
      w.string(values[k]!.path);
    }
    return w.done();
  }

  static Map<int, ({String storageId, String path})> decodePlaceholders(
      Uint8List data) {
    final r = _Reader(data);
    _checkVersion(r.varint());
    final n = r.varint();
    return {
      for (var i = 0; i < n; i++)
        r.varint(): (storageId: r.string(), path: r.string()),
    };
  }

  static void _checkVersion(int found) {
    if (found != version) {
      throw FormatException(
          'unsupported shared-index blob version $found (expected $version)');
    }
  }
}

/// LEB128 + length-prefixed bytes writer.
class _Writer {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void varint(int value) {
    assert(value >= 0, 'varint requires a non-negative value (got $value)');
    var v = value;
    while (v >= 0x80) {
      _bytes.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    _bytes.addByte(v);
  }

  void int32(int value) {
    final b = ByteData(4)..setInt32(0, value, Endian.little);
    _bytes.add(b.buffer.asUint8List());
  }

  void bytes(Uint8List value) {
    varint(value.length);
    _bytes.add(value);
  }

  void string(String value) => bytes(utf8.encode(value));

  Uint8List done() => _bytes.toBytes();
}

/// Matching reader.
class _Reader {
  _Reader(this._data);

  final Uint8List _data;
  int _pos = 0;

  /// Bytes consumed so far (format validation: a well-formed blob has no tail).
  int get pos => _pos;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = _data[_pos++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }

  int int32() {
    final value = ByteData.sublistView(_data, _pos, _pos + 4)
        .getInt32(0, Endian.little);
    _pos += 4;
    return value;
  }

  Uint8List bytes() {
    final length = varint();
    final out = Uint8List.sublistView(_data, _pos, _pos + length);
    _pos += length;
    return out;
  }

  String string() => utf8.decode(bytes());
}
