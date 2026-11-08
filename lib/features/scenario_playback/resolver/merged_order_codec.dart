import 'dart:convert';
import 'dart:typed_data';

/// One stream of a merged base order: a storage's shared order (or the
/// scenario's explicit-item list) and how many of its entries the base order
/// contains.
class MergedOrderStream {
  const MergedOrderStream({
    required this.orderKey,
    required this.mediaRev,
    required this.count,
    required this.orderLength,
  });

  /// Identifies the shared order (`SharedMediaOrder.orderKey`), or the reserved
  /// key `explicit` for the scenario's explicit items.
  final String orderKey;

  /// Media revision the order was built against (0 for the explicit stream).
  final int mediaRev;

  /// Number of base entries contributed by this stream.
  final int count;

  /// Length of the stream's shared order.
  ///
  /// A rank is a POSITION in that order, and the order enumerates the whole
  /// scope (a storage for a folder source) — not just the files this scenario
  /// contributes. A scenario covering two of a storage's folders therefore
  /// contributes ranks with HOLES in between, so the only valid upper bound for
  /// a rank is the order's length. Using [count] here refuses every such merge
  /// (the bug this field exists to prevent) and would also let a corrupt rank
  /// index past the end of the order at read time.
  final int orderLength;
}

/// A base order expressed as the INTERLEAVING of several ordered streams.
///
/// The persisted representation of a globally sorted queue: every base entry is
/// `(stream, rank)` where `rank` is its position inside that stream's shared
/// order. Because the queue is ordered by the same comparator the shared orders
/// were built with, each stream's ranks are NON-DECREASING (a repeated position
/// is a duplicate occurrence), so the entries are stored as varint
/// `(delta << streamBits) | stream` — about 1–2 bytes per base entry instead of
/// the 4 B a full id sequence (or a per-scenario permutation) would cost.
///
/// Random access is bounded: the blob carries one checkpoint per
/// [checkInterval] entries (each stream's last rank before the block, plus the
/// byte offset of the block), so [at] decodes at most [checkInterval] varints.
class MergedOrder {
  MergedOrder._({
    required this.streams,
    required this.length,
    required this.checkInterval,
    required Uint8List packed,
    required Int32List blockRanks,
    required Int32List blockOffsets,
    required int streamBits,
  })  : _packed = packed,
        _blockRanks = blockRanks,
        _blockOffsets = blockOffsets,
        _streamBits = streamBits;

  static const int version = 2;

  /// Checkpoint distance. 64 keeps `at` cheap while the checkpoint table stays
  /// ~6% of the payload at 31 streams.
  static const int defaultCheckInterval = 64;

  final List<MergedOrderStream> streams;
  final int length;
  final int checkInterval;
  final Uint8List _packed;
  final Int32List _blockRanks;
  final Int32List _blockOffsets;
  final int _streamBits;

  int get streamCount => streams.length;

  /// Encodes [length] entries produced by [entryAt].
  ///
  /// Throws [ArgumentError] when the input is not a valid merge (a rank that
  /// DECREASES within its stream, or a total that disagrees with the declared
  /// per-stream counts): an invalid index must never be persisted.
  static Uint8List encode({
    required List<MergedOrderStream> streams,
    required int length,
    required ({int stream, int rank}) Function(int index) entryAt,
    int checkInterval = defaultCheckInterval,
  }) {
    // One stream is legal: a scenario whose items all live in ONE storage still
    // needs the merged form when it has several sources or explicit items (the
    // bitmap form is reserved for the exact single-source shape, so the two do
    // not race over the same bytes).
    if (streams.isEmpty) {
      throw ArgumentError('a merged order needs at least 1 stream');
    }
    if (checkInterval < 1) {
      throw ArgumentError('checkInterval must be >= 1');
    }
    final bits = _bitsFor(streams.length);
    final last = List<int>.filled(streams.length, -1);
    final blockRanks = <int>[];
    final blockOffsets = <int>[];
    final totals = List<int>.filled(streams.length, 0);
    final packed = BytesBuilder(copy: false);
    var packedLength = 0;

    for (var i = 0; i < length; i++) {
      if (i % checkInterval == 0) {
        blockOffsets.add(packedLength);
        for (final rank in last) {
          // `_blockRanks` holds the ACTUAL last rank (-1 = none); `toBytes`
          // shifts it by +1 so the sentinel fits a varint.
          blockRanks.add(rank);
        }
      }
      final entry = entryAt(i);
      if (entry.stream < 0 || entry.stream >= streams.length) {
        throw ArgumentError('stream ${entry.stream} out of range at $i');
      }
      if (entry.rank < 0 || entry.rank >= streams[entry.stream].orderLength) {
        throw ArgumentError(
            'stream ${entry.stream} rank ${entry.rank} is outside its order '
            '(${streams[entry.stream].orderLength}) at $i');
      }
      final delta = entry.rank - last[entry.stream];
      // NON-DECREASING, not strictly increasing: overlapping sources in one
      // storage (and `allowDuplicate`) can contribute the same shared-order
      // position twice, and a repeat is a legal base order — the same node then
      // simply appears at two ranks.
      if (delta < 0) {
        throw ArgumentError(
            'stream ${entry.stream} rank ${entry.rank} decreases at $i');
      }
      last[entry.stream] = entry.rank;
      totals[entry.stream]++;
      packedLength += _writeVarint(packed, (delta << bits) | entry.stream);
    }
    for (var s = 0; s < streams.length; s++) {
      if (totals[s] != streams[s].count) {
        throw ArgumentError(
            'stream $s contributed ${totals[s]} entries, declared ${streams[s].count}');
      }
    }

    return MergedOrder._(
      streams: streams,
      length: length,
      checkInterval: checkInterval,
      packed: packed.toBytes(),
      blockRanks: Int32List.fromList(blockRanks),
      blockOffsets: Int32List.fromList(blockOffsets),
      streamBits: bits,
    ).toBytes();
  }

  /// Re-serializes this order. The representative already holds every field, so
  /// a `(Slices)` blob can embed it without keeping the build-time entries
  /// around.
  Uint8List toBytes() {
    final w = _Writer()
      ..varint(version)
      ..varint(streamCount);
    for (final s in streams) {
      w
        ..string(s.orderKey)
        ..varint(s.mediaRev)
        ..varint(s.count)
        ..varint(s.orderLength);
    }
    w
      ..varint(length)
      ..varint(checkInterval)
      ..varint(_blockOffsets.length);
    for (final rank in _blockRanks) {
      w.varint(rank + 1);
    }
    for (final offset in _blockOffsets) {
      w.varint(offset);
    }
    w.bytes(_packed);
    return w.done();
  }

  /// Convenience wrapper for tests and small inputs.
  static Uint8List encodeEntries({
    required List<MergedOrderStream> streams,
    required List<({int stream, int rank})> entries,
    int checkInterval = defaultCheckInterval,
  }) =>
      encode(
        streams: streams,
        length: entries.length,
        entryAt: (i) => entries[i],
        checkInterval: checkInterval,
      );

  /// Decodes [data], or null when it is corrupt / internally inconsistent.
  ///
  /// Validation is a full pass (stream indices, non-decreasing ranks, the
  /// declared per-stream totals and the checkpoint table). A malformed blob must
  /// be REFUSED here — serving it would silently reorder the queue.
  static MergedOrder? decode(Uint8List data) {
    try {
      final r = _Reader(data);
      if (r.varint() != version) return null;
      final streamCount = r.varint();
      if (streamCount < 1 || streamCount > 256) return null;
      final streams = <MergedOrderStream>[
        for (var i = 0; i < streamCount; i++)
          MergedOrderStream(
            orderKey: r.string(),
            mediaRev: r.varint(),
            count: r.varint(),
            orderLength: r.varint(),
          ),
      ];
      // NOTE: no `count <= orderLength` check — overlapping sources legitimately
      // contribute the SAME position twice, so a stream can carry more entries
      // than its order has nodes.
      final length = r.varint();
      final checkInterval = r.varint();
      if (checkInterval < 1) return null;
      final blockCount = r.varint();
      final expectedBlocks =
          length == 0 ? 0 : (length + checkInterval - 1) ~/ checkInterval;
      if (blockCount != expectedBlocks) return null;

      final blockRanks = Int32List(blockCount * streamCount);
      for (var i = 0; i < blockRanks.length; i++) {
        blockRanks[i] = r.varint() - 1;
      }
      final blockOffsets = Int32List(blockCount);
      for (var i = 0; i < blockCount; i++) {
        blockOffsets[i] = r.varint();
      }
      final packed = r.bytes();

      var declaredTotal = 0;
      for (final s in streams) {
        declaredTotal += s.count;
      }
      if (declaredTotal != length) return null;

      final order = MergedOrder._(
        streams: streams,
        length: length,
        checkInterval: checkInterval,
        packed: packed,
        blockRanks: blockRanks,
        blockOffsets: blockOffsets,
        streamBits: _bitsFor(streamCount),
      );
      if (!order._validate()) return null;
      return order;
    } catch (_) {
      // Truncated / garbage bytes are an expected corruption mode.
      return null;
    }
  }

  /// The `(stream, rank)` entry at base position [index].
  ({int stream, int rank}) at(int index) {
    if (index < 0 || index >= length) {
      throw RangeError.index(index, this, 'index', null, length);
    }
    final bits = _streamBits;
    final mask = (1 << bits) - 1;
    final block = index ~/ checkInterval;
    final local = index % checkInterval;
    final ranks = Int32List(streamCount);
    for (var s = 0; s < streamCount; s++) {
      ranks[s] = _blockRanks[block * streamCount + s];
    }
    var pos = _blockOffsets[block];
    var stream = 0;
    for (var i = 0; i <= local; i++) {
      final decoded = _readVarintAt(_packed, pos);
      pos = decoded.next;
      final value = decoded.value;
      stream = value & mask;
      ranks[stream] += value >> bits;
    }
    return (stream: stream, rank: ranks[stream]);
  }

  /// Visits every entry in base order (sequential decode — cheaper than [at]
  /// for a full scan).
  void forEach(void Function(int index, int stream, int rank) visit) {
    final bits = _streamBits;
    final mask = (1 << bits) - 1;
    final ranks = Int32List(streamCount);
    var pos = 0;
    var block = 0;
    var index = 0;
    while (index < length) {
      if (index % checkInterval == 0) {
        for (var s = 0; s < streamCount; s++) {
          ranks[s] = _blockRanks[block * streamCount + s];
        }
        pos = _blockOffsets[block];
        block++;
      }
      final decoded = _readVarintAt(_packed, pos);
      pos = decoded.next;
      final value = decoded.value;
      final stream = value & mask;
      ranks[stream] += value >> bits;
      visit(index, stream, ranks[stream]);
      index++;
    }
  }

  /// Distance (in base entries) from [index] to the end of its checkpoint
  /// block — the most entries [at] can be asked to decode. Exposed for tests.
  int decodeBudgetAt(int index) =>
      checkInterval - (index % checkInterval);

  bool _validate() {
    final bits = _streamBits;
    final mask = (1 << bits) - 1;
    final ranks = Int32List(streamCount);
    final seen = List<int>.filled(streamCount, 0);
    var pos = 0;
    var block = 0;
    var index = 0;
    while (index < length) {
      if (index % checkInterval == 0) {
        if (block >= _blockOffsets.length) return false;
        // The checkpoint must point at exactly where the previous block ended.
        if (_blockOffsets[block] != pos) return false;
        for (var s = 0; s < streamCount; s++) {
          final stored = _blockRanks[block * streamCount + s];
          // A later block's checkpoint must repeat the state the previous block
          // ended in; otherwise a flipped checkpoint would silently reorder the
          // stream while every count still matched.
          if (block > 0 && stored != ranks[s]) return false;
          ranks[s] = stored;
        }
        block++;
      }
      if (pos >= _packed.length) return false;
      final decoded = _readVarintAt(_packed, pos);
      pos = decoded.next;
      final value = decoded.value;
      final stream = value & mask;
      if (stream >= streamCount) return false;
      final delta = value >> bits;
      // NON-DECREASING: a repeated position (delta 0) is a legal duplicate
      // occurrence; going backwards is not.
      if (delta < 0) return false;
      ranks[stream] += delta;
      if (ranks[stream] < 0) return false;
      // Bound by the ORDER's length, not by this stream's contribution count:
      // the order enumerates the whole scope, so a scenario that covers a
      // subrange of it legitimately stores ranks with holes (and gaps are the
      // norm, not the exception).
      if (ranks[stream] >= streams[stream].orderLength) return false;
      seen[stream]++;
      index++;
    }
    if (block != _blockOffsets.length) return false;
    for (var s = 0; s < streamCount; s++) {
      if (seen[s] != streams[s].count) return false;
    }
    return true;
  }

  static int _bitsFor(int streamCount) {
    final needed = (streamCount - 1).bitLength;
    return needed < 1 ? 1 : needed;
  }
}

// ── varint helpers ──

int _writeVarint(BytesBuilder out, int value) {
  assert(value >= 0);
  var written = 0;
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7f) | 0x80);
    v >>= 7;
    written++;
  }
  out.addByte(v);
  return written + 1;
}

({int value, int next}) _readVarintAt(Uint8List data, int pos) {
  var result = 0;
  var shift = 0;
  var at = pos;
  while (true) {
    final byte = data[at++];
    result |= (byte & 0x7f) << shift;
    if (byte & 0x80 == 0) return (value: result, next: at);
    shift += 7;
  }
}

class _Writer {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void varint(int value) => _writeVarint(_bytes, value);

  void bytes(Uint8List value) {
    varint(value.length);
    _bytes.add(value);
  }

  void string(String value) => bytes(utf8.encode(value));

  Uint8List done() => _bytes.toBytes();
}

class _Reader {
  _Reader(this._data);

  final Uint8List _data;
  int _pos = 0;

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

  Uint8List bytes() {
    final length = varint();
    final out = Uint8List.sublistView(_data, _pos, _pos + length);
    _pos += length;
    return out;
  }

  String string() => String.fromCharCodes(bytes());
}
