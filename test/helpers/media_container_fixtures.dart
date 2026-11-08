import 'dart:typed_data';

/// Builders for MINIMAL but structurally valid container headers.
///
/// WHY: the header probes are the difference between "a folder plays in a
/// second with a duration-ordered queue" and "it sits for tens of seconds in
/// the Shell property handler", so they are exercised against real byte layouts
/// (EBML / RIFF / ISO-BMFF) instead of binary fixtures in the repo.

/// A Matroska file with the shape every muxer produces: EBML header, `Segment`
/// (unknown size), `Info` (timecode scale + duration), `Tracks` (one video
/// track), then a small cluster.
Uint8List buildMkv({
  required int durationMs,
  required int width,
  required int height,
  int timecodeScaleNs = 1000000,
  bool includeDuration = true,
  bool segmentUnknownSize = true,
}) {
  final infoPayload = BytesBuilder()
    ..add(_ebmlElement(_idTimecodeScale, _ebmlUint(timecodeScaleNs)));
  if (includeDuration) {
    infoPayload.add(_ebmlElement(
      _idDuration,
      _ebmlFloat(durationMs * 1000000 / timecodeScaleNs),
    ));
  }

  final video = _ebmlElement(_idVideo, [
    ..._ebmlElement(_idPixelWidth, _ebmlUint(width)),
    ..._ebmlElement(_idPixelHeight, _ebmlUint(height)),
  ]);
  final trackEntry = _ebmlElement(_idTrackEntry, [
    ..._ebmlElement(_idTrackType, _ebmlUint(1)),
    ...video,
  ]);
  final tracks = _ebmlElement(_idTracks, trackEntry);

  final segmentBody = [
    ..._ebmlElement(_idInfo, infoPayload.takeBytes()),
    ...tracks,
    ..._ebmlElement(_idCluster, List<int>.filled(64, 0)),
  ];
  final segment = segmentUnknownSize
      ? [..._ebmlId(_idSegment), ..._ebmlUnknownSize(), ...segmentBody]
      : _ebmlElement(_idSegment, segmentBody);

  return Uint8List.fromList([
    ..._ebmlElement(_idEbmlHeader, List<int>.filled(8, 0)),
    ...segment,
  ]);
}

/// A RIFF/AVI file: `RIFF....AVI ` → `LIST hdrl` → `avih` → `LIST movi`.
Uint8List buildAvi({
  required int durationMs,
  required int width,
  required int height,
  int microsPerFrame = 40000,
}) {
  final totalFrames = (durationMs * 1000 / microsPerFrame).round();
  final avih = BytesBuilder()
    ..add(_u32le(microsPerFrame))
    ..add(_u32le(0)) // max bytes/sec
    ..add(_u32le(0)) // padding granularity
    ..add(_u32le(0x10)) // flags
    ..add(_u32le(totalFrames))
    ..add(_u32le(0)) // initial frames
    ..add(_u32le(1)) // streams
    ..add(_u32le(0)) // suggested buffer
    ..add(_u32le(width))
    ..add(_u32le(height));

  final hdrlChildren = [
    ..._riffChunk('avih', avih.takeBytes()),
  ];
  final hdrl = _riffChunk('LIST', [
    ...'hdrl'.codeUnits,
    ...hdrlChildren,
  ]);
  final movi = _riffChunk('LIST', [
    ...'movi'.codeUnits,
    ...List<int>.filled(64, 0),
  ]);
  final body = [...'AVI '.codeUnits, ...hdrl, ...movi];
  return Uint8List.fromList([
    ...'RIFF'.codeUnits,
    ..._u32le(body.length),
    ...body,
  ]);
}

// --- EBML ---------------------------------------------------------------

const int _idEbmlHeader = 0x1A45DFA3;
const int _idSegment = 0x18538067;
const int _idInfo = 0x1549A966;
const int _idTimecodeScale = 0x2AD7B1;
const int _idDuration = 0x4489;
const int _idTracks = 0x1654AE6B;
const int _idTrackEntry = 0xAE;
const int _idTrackType = 0x83;
const int _idVideo = 0xE0;
const int _idPixelWidth = 0xB0;
const int _idPixelHeight = 0xBA;
const int _idCluster = 0x1F43B675;

/// Writes an EBML id with its marker bits intact (ids store their own prefix).
List<int> _ebmlId(int id) {
  var length = 1;
  while (id >= (1 << (8 * length)) && length < 4) {
    length++;
  }
  final out = <int>[];
  for (var i = length - 1; i >= 0; i--) {
    out.add((id >> (8 * i)) & 0xFF);
  }
  return out;
}

/// Minimal 1-byte-prefixed size VINT for small payloads; throws on overflow so a
/// fixture bug reads as a test failure instead of a silently corrupt header.
List<int> _ebmlSize(int size) {
  for (var length = 1; length <= 8; length++) {
    final max = (1 << (7 * length)) - 2; // all-ones is "unknown size"
    if (size <= max) {
      final out = <int>[];
      var v = size;
      for (var i = length - 1; i >= 0; i--) {
        out.add((v >> (8 * i)) & 0xFF);
      }
      out[0] |= 0x80 >> (length - 1);
      return out;
    }
  }
  throw ArgumentError('payload too large: $size');
}

List<int> _ebmlUnknownSize() => [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];

List<int> _ebmlElement(int id, List<int> payload) => [
      ..._ebmlId(id),
      ..._ebmlSize(payload.length),
      ...payload,
    ];

List<int> _ebmlUint(int value) {
  if (value == 0) return [0];
  final bytes = <int>[];
  var v = value;
  while (v > 0) {
    bytes.insert(0, v & 0xFF);
    v >>= 8;
  }
  return bytes;
}

List<int> _ebmlFloat(double value) {
  final data = ByteData(8)..setFloat64(0, value, Endian.big);
  return data.buffer.asUint8List();
}

// --- RIFF ---------------------------------------------------------------

List<int> _riffChunk(String id, List<int> payload) {
  final pad = payload.length.isOdd ? [0] : const <int>[];
  return [...id.codeUnits, ..._u32le(payload.length), ...payload, ...pad];
}

List<int> _u32le(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
