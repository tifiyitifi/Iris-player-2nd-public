import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:charset/charset.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';
import 'package:iris/features/fake_cut/services/fake_cut_edl_builder.dart';
import 'package:iris/utils/logger.dart';
import 'package:path/path.dart' as p;

final _log = AreaKeyLog(LogKeys.legacyPlayer);

/// Why a subtitle could not be remapped. Each maps to one localized dialog.
enum FakeCutSubtitleFailure {
  /// `.sub` (MicroDVD/VobSub) and anything else IRIS cannot re-time.
  unsupportedFormat,

  /// The file disappeared or cannot be read.
  unreadable,

  /// Unknown text encoding (UTF-8 / UTF-16 BOM / GBK are handled).
  decodeFailed,

  /// Every cue fell in a removed gap, or no cue could be re-timed, so an empty
  /// or mis-timed subtitle would be loaded.
  emptyAfterRemap,

  /// The document parsed but had no cue at all.
  noCues,
}

/// Outcome of [FakeCutSubtitleRemapper.remap]: either a playable [uri] or a
/// [failure]. Never both.
class FakeCutSubtitleResult {
  const FakeCutSubtitleResult.success({
    required this.uri,
    required this.emittedCues,
    required this.droppedCues,
  })  : failure = null,
        detail = null;

  const FakeCutSubtitleResult.failure(
    this.failure, {
    this.detail,
  })  : uri = null,
        emittedCues = 0,
        droppedCues = 0;

  final String? uri;
  final FakeCutSubtitleFailure? failure;
  final String? detail;
  final int emittedCues;
  final int droppedCues;

  bool get ok => uri != null;
}

/// Text-level remap result (no IO), exposed for tests.
class FakeCutSubtitleRemap {
  const FakeCutSubtitleRemap({
    required this.text,
    required this.emittedCues,
    required this.droppedCues,
  });

  final String text;
  final int emittedCues;

  /// Cues that produced no piece: the whole cue sat in a removed gap, OR its
  /// timing could not be parsed (those are DROPPED, never copied at source
  /// seconds — see `_looksLikeCueTiming`).
  final int droppedCues;
}

/// Re-times a SOURCE-timed external subtitle onto the virtual (cut) timeline.
///
/// WHY this exists: mpv shifts the streams of the MAIN demuxer when an EDL is
/// open (embedded subtitles are correct automatically), but an external subtitle
/// loaded with `sub-add` is an INDEPENDENT demuxer and is never shifted. Without
/// this remap every external subtitle in 简播 would be offset by the removed
/// material.
///
/// PRODUCT TRADEOFF: the input is assumed to be timed against the SOURCE file.
/// A subtitle authored for the already-cut output would be shifted twice.
///
/// CONTRACT with `resolveSubtitleUriForCut`: a cue that cannot be re-timed (an
/// unparsable timing line, an unreadable ASS event) is REMOVED, never copied
/// verbatim — a verbatim cue keeps its source seconds and plays offset by all
/// the removed material, which is exactly what "load nothing rather than a
/// mis-timed subtitle" forbids. Metadata that is not a cue (WebVTT NOTE / STYLE
/// / REGION) is still passed through byte-identical.
abstract final class FakeCutSubtitleRemapper {
  static const Set<String> supportedExtensions = <String>{'srt', 'vtt', 'ass', 'ssa'};

  static bool supportsPath(String path) =>
      supportedExtensions.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

  /// Reads [subtitlePath], remaps it and writes the result into the fake-cut
  /// temp cache. Reuses an existing artefact when the inputs did not change.
  ///
  /// [signature] identifies the plan revision (path + mtime + size).
  static Future<FakeCutSubtitleResult> remap({
    required FakeCutPlan plan,
    required String subtitlePath,
    required String signature,
    required Directory tempRoot,
  }) async {
    final String extension =
        p.extension(subtitlePath).replaceFirst('.', '').toLowerCase();
    if (!supportedExtensions.contains(extension)) {
      return const FakeCutSubtitleResult.failure(
          FakeCutSubtitleFailure.unsupportedFormat);
    }

    final File file = File(subtitlePath);
    final List<int> bytes;
    try {
      if (!await file.exists()) {
        return const FakeCutSubtitleResult.failure(
            FakeCutSubtitleFailure.unreadable);
      }
      bytes = await file.readAsBytes();
    } catch (e) {
      _log.w('fake cut subtitle read failed: $subtitlePath: $e');
      return const FakeCutSubtitleResult.failure(
          FakeCutSubtitleFailure.unreadable);
    }

    final String? text = decodeSubtitleBytes(bytes);
    if (text == null) {
      return const FakeCutSubtitleResult.failure(
          FakeCutSubtitleFailure.decodeFailed);
    }

    final FakeCutSubtitleRemap? remap =
        remapText(plan: plan, path: subtitlePath, text: text);
    if (remap == null) {
      return const FakeCutSubtitleResult.failure(
          FakeCutSubtitleFailure.unsupportedFormat);
    }
    if (remap.emittedCues == 0) {
      return FakeCutSubtitleResult.failure(
        remap.droppedCues > 0
            ? FakeCutSubtitleFailure.emptyAfterRemap
            : FakeCutSubtitleFailure.noCues,
      );
    }

    final Directory cacheDir = fakeCutCacheDirectory(tempRoot);
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    final String key = fakeCutCacheKey(
        '${plan.planPath}\u0000$signature\u0000$subtitlePath\u0000'
        '${fakeCutCacheKeyOfBytes(bytes)}\u0000${remap.emittedCues}');
    final String stem = _safeStem(p.basenameWithoutExtension(subtitlePath));
    final File out =
        File(p.join(cacheDir.path, '$stem.$key.remapped.$extension'));
    if (!await out.exists()) {
      await out.writeAsString(remap.text, encoding: utf8, flush: true);
    }
    _log.i('fake cut subtitle remapped: ${p.basename(out.path)} '
        '(${remap.emittedCues} cues, ${remap.droppedCues} dropped)');
    return FakeCutSubtitleResult.success(
      uri: out.path,
      emittedCues: remap.emittedCues,
      droppedCues: remap.droppedCues,
    );
  }

  /// Pure text remap. Returns null for an unsupported extension.
  static FakeCutSubtitleRemap? remapText({
    required FakeCutPlan plan,
    required String path,
    required String text,
  }) {
    final String extension =
        p.extension(path).replaceFirst('.', '').toLowerCase();
    final _Counter counter = _Counter();
    switch (extension) {
      case 'srt':
        return FakeCutSubtitleRemap(
          text: _remapSrt(plan, text, counter),
          emittedCues: counter.emitted,
          droppedCues: counter.dropped,
        );
      case 'vtt':
        return FakeCutSubtitleRemap(
          text: _remapVtt(plan, text, counter),
          emittedCues: counter.emitted,
          droppedCues: counter.dropped,
        );
      case 'ass':
      case 'ssa':
        return FakeCutSubtitleRemap(
          text: _remapAss(plan, text, counter),
          emittedCues: counter.emitted,
          droppedCues: counter.dropped,
        );
    }
    return null;
  }

  /// Decodes subtitle bytes: UTF-8 / UTF-16 (BOM) / GBK, else null.
  ///
  /// A silent guess is worse than a dialog here: loading mojibake subtitles is
  /// indistinguishable from a timing bug, so an undecodable file is reported.
  ///
  /// TOTAL by contract: it never throws. The BOM branches declare the encoding,
  /// so their failure is `decodeFailed` — falling back to GBK would only turn a
  /// broken UTF-16 file into mojibake. (They used to sit outside the try: a
  /// BOM-prefixed file that did not decode threw `FormatException` straight
  /// through `remap()` and the caller never showed anything.)
  static String? decodeSubtitleBytes(List<int> bytes) {
    if (bytes.isEmpty) return '';
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      try {
        return utf8.decode(bytes.sublist(3));
      } on FormatException {
        return null;
      }
    }
    if (bytes.length >= 2) {
      final bool le = bytes[0] == 0xFF && bytes[1] == 0xFE;
      final bool be = bytes[0] == 0xFE && bytes[1] == 0xFF;
      if (le || be) {
        // Odd payload / lone surrogate: utf16.decode rejects it.
        try {
          return utf16.decode(bytes);
        } catch (_) {
          return null;
        }
      }
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // Fall through: the classic Chinese subtitle encoding.
    }
    try {
      return gbk.decode(bytes);
    } catch (_) {
      return null;
    }
  }
}

class _Counter {
  int emitted = 0;
  int dropped = 0;
}

class _Piece {
  const _Piece(this.startMs, this.endMs);

  final int startMs;
  final int endMs;
}

/// Cuts one source-timed cue into virtual pieces, in plan order.
///
/// A cue spanning several ranges becomes several cues; a cue inside a repeat /
/// overlap range is duplicated (once per range); a cue wholly inside a removed
/// gap disappears (counted, never silently).
List<_Piece> _cutCue(FakeCutPlan plan, int startMs, int endMs, _Counter counter) {
  if (endMs <= startMs) {
    counter.dropped++;
    return const <_Piece>[];
  }
  final List<_Piece> pieces = <_Piece>[];
  for (int i = 0; i < plan.segments.length; i++) {
    final FakeCutSegment segment = plan.segments[i];
    final int from = math.max(startMs, segment.startMs);
    final int to = math.min(endMs, segment.endMs);
    if (to <= from) continue;
    final int fakeStart =
        plan.timeline.fakeStartOf(i) + (from - segment.startMs);
    pieces.add(_Piece(fakeStart, fakeStart + (to - from)));
  }
  if (pieces.isEmpty) {
    counter.dropped++;
  } else {
    counter.emitted += pieces.length;
  }
  return pieces;
}

String _normalizeNewlines(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

// ── SRT ────────────────────────────────────────────────────────────────────

final RegExp _srtTiming = RegExp(
    r'(\d{1,3}):(\d{2}):(\d{2})[.,](\d{1,3})\s*-->\s*(\d{1,3}):(\d{2}):(\d{2})[.,](\d{1,3})');

/// A line that IS a cue timing line, whatever its fraction length.
///
/// [`_srtTiming`] / [`_vttTiming`] are deliberately strict (3-digit fractions,
/// fixed field widths). This loose prefix is what tells "a cue we failed to
/// parse" apart from "a block that is not a cue at all" (NOTE / STYLE / junk
/// text). A cue we cannot re-time must be DROPPED: copying it verbatim leaves it
/// at its SOURCE seconds, which is the mis-timed subtitle
/// `resolveSubtitleUriForCut` refuses to load.
final RegExp _cueTimingLine =
    RegExp(r'^\s*(?:\d{1,3}:)?\d{1,3}:\d{2}(?:[.,]\d+)?\s*-->');

bool _looksLikeCueTiming(String line) => _cueTimingLine.hasMatch(line);

/// Whether [block] is WebVTT metadata rather than a cue.
///
/// NOTE / STYLE / REGION never render and must survive BYTE-IDENTICAL (the
/// documented contract). Their bodies may legitimately quote a timecode (`NOTE
/// 12:00 --> 13:00 deleted scene`), so the "did this cue fail to parse?" probe
/// must never look inside them.
bool _isVttMetadataBlock(List<String> blockLines) {
  if (blockLines.isEmpty) return false;
  final String head = blockLines.first.trimLeft().toUpperCase();
  return head.startsWith('NOTE') ||
      head.startsWith('STYLE') ||
      head.startsWith('REGION');
}

/// The WebVTT cue identifier, or '' when the block does not carry exactly one.
///
/// A cue identifier is ONE line immediately above the timing line. Keeping
/// anything else (a second line, a `NOTE` line of a file that forgot its blank
/// separator) writes an invalid cue whose text the parser then swallows into
/// the preceding block, so the ambiguous case is dropped instead.
String _vttCueIdentifier(List<String> blockLines, int timingIndex) {
  if (timingIndex != 1) return '';
  final String id = blockLines.first.trim();
  if (id.isEmpty) return '';
  final String upper = id.toUpperCase();
  if (upper.startsWith('NOTE') ||
      upper.startsWith('STYLE') ||
      upper.startsWith('REGION') ||
      _looksLikeCueTiming(id)) {
    return '';
  }
  return id;
}

String _remapSrt(FakeCutPlan plan, String text, _Counter counter) {
  final List<String> lines = _normalizeNewlines(text).split('\n');
  final List<String> blocks = <String>[];
  final StringBuffer current = StringBuffer();
  void flush() {
    if (current.isNotEmpty) {
      blocks.add(current.toString());
      current.clear();
    }
  }

  for (final String line in lines) {
    if (line.trim().isEmpty) {
      flush();
    } else {
      if (current.isNotEmpty) current.write('\n');
      current.write(line);
    }
  }
  flush();

  final List<String> outBlocks = <String>[];
  int number = 1;
  for (final String block in blocks) {
    final List<String> blockLines = block.split('\n');
    final int timingIndex =
        blockLines.indexWhere((String l) => _srtTiming.hasMatch(l));
    if (timingIndex < 0) {
      // Only the two lines that could CARRY a timing (`[number]` + timing) are
      // probed: a body line may quote a timecode and must not cost the block.
      if (blockLines.take(2).any(_looksLikeCueTiming)) {
        // A cue whose timing line did not parse. Keeping it would emit it at
        // SOURCE seconds (a mis-timed subtitle is worse than none).
        counter.dropped++;
        continue;
      }
      // A stray text block (no timing line): keep it verbatim.
      outBlocks.add(block);
      continue;
    }
    final RegExpMatch match = _srtTiming.firstMatch(blockLines[timingIndex])!;
    final int startMs = _ms(match.group(1), match.group(2), match.group(3),
        match.group(4));
    final int endMs = _ms(match.group(5), match.group(6), match.group(7),
        match.group(8));
    final List<String> body = blockLines.sublist(timingIndex + 1);
    if (body.isEmpty) continue;
    for (final _Piece piece in _cutCue(plan, startMs, endMs, counter)) {
      outBlocks.add('$number\n'
          '${_srtTime(piece.startMs)} --> ${_srtTime(piece.endMs)}\n'
          '${body.join('\n')}');
      number++;
    }
  }
  return '${outBlocks.join('\n\n')}\n';
}

int _ms(String? h, String? m, String? s, String? frac) {
  final int hours = int.parse(h!);
  final int minutes = int.parse(m!);
  final int seconds = int.parse(s!);
  final int milliseconds =
      frac == null ? 0 : int.parse(frac.padRight(3, '0').substring(0, 3));
  return ((hours * 60 + minutes) * 60 + seconds) * 1000 + milliseconds;
}

String _srtTime(int ms) {
  final int clamped = ms < 0 ? 0 : ms;
  final int h = clamped ~/ 3600000;
  final int m = (clamped ~/ 60000) % 60;
  final int s = (clamped ~/ 1000) % 60;
  final int milli = clamped % 1000;
  return '${_p2(h)}:${_p2(m)}:${_p2(s)},${milli.toString().padLeft(3, '0')}';
}

String _vttTime(int ms) {
  final int clamped = ms < 0 ? 0 : ms;
  final int h = clamped ~/ 3600000;
  final int m = (clamped ~/ 60000) % 60;
  final int s = (clamped ~/ 1000) % 60;
  final int milli = clamped % 1000;
  return '${_p2(h)}:${_p2(m)}:${_p2(s)}.${milli.toString().padLeft(3, '0')}';
}

String _p2(int value) => value.toString().padLeft(2, '0');

// ── WebVTT ─────────────────────────────────────────────────────────────────

final RegExp _vttTiming = RegExp(
    r'((?:\d{1,3}:)?\d{1,3}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d{1,3}:)?\d{1,3}:\d{2}[.,]\d{1,3})(.*)$');

String _remapVtt(FakeCutPlan plan, String text, _Counter counter) {
  final String normalized = _normalizeNewlines(text);
  final List<String> blocks = normalized
      .split(RegExp(r'\n[ \t]*\n'))
      .map((String b) => b.trim())
      .where((String b) => b.isNotEmpty)
      .toList();
  final List<String> outBlocks = <String>[];
  for (final String block in blocks) {
    if (block.startsWith('WEBVTT')) {
      outBlocks.add(block);
      continue;
    }
    final List<String> blockLines = block.split('\n');
    final int timingIndex =
        blockLines.indexWhere((String l) => _vttTiming.hasMatch(l));
    if (timingIndex < 0) {
      // Metadata blocks survive byte-identical, timecode in the body included;
      // only a cue-shaped block whose timing failed to parse is dropped.
      if (!_isVttMetadataBlock(blockLines) &&
          blockLines.take(2).any(_looksLikeCueTiming)) {
        // A cue this reader cannot re-time (a 4-digit fraction is the common
        // real-world case): drop it + count it, never copy it at source seconds.
        counter.dropped++;
        continue;
      }
      // NOTE / STYLE / REGION blocks stay byte-identical.
      outBlocks.add(block);
      continue;
    }
    final RegExpMatch match = _vttTiming.firstMatch(blockLines[timingIndex])!;
    final int? startMs = _parseVttTime(match.group(1)!);
    final int? endMs = _parseVttTime(match.group(2)!);
    final String settings = (match.group(3) ?? '').trim();
    if (startMs == null || endMs == null) {
      counter.dropped++;
      continue;
    }
    // Optional cue identifier: exactly one line above the timing, and never a
    // metadata keyword. A cue split across ranges cannot reuse one identifier
    // (ids must be unique), so later pieces go without.
    final String identifier = _vttCueIdentifier(blockLines, timingIndex);
    final List<String> body = blockLines.sublist(timingIndex + 1);
    bool firstPiece = true;
    for (final _Piece piece in _cutCue(plan, startMs, endMs, counter)) {
      final String timing =
          '${_vttTime(piece.startMs)} --> ${_vttTime(piece.endMs)}'
          '${settings.isEmpty ? '' : ' $settings'}';
      final String head = firstPiece && identifier.isNotEmpty
          ? '$identifier\n$timing'
          : timing;
      firstPiece = false;
      outBlocks.add(body.isEmpty ? head : '$head\n${body.join('\n')}');
    }
  }
  if (outBlocks.isEmpty || !outBlocks.first.startsWith('WEBVTT')) {
    outBlocks.insert(0, 'WEBVTT');
  }
  return '${outBlocks.join('\n\n')}\n';
}

int? _parseVttTime(String raw) {
  final String text = raw.trim();
  final List<String> parts = text.split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  final String secondsPart = parts.last.replaceAll(',', '.');
  final double? seconds = double.tryParse(secondsPart);
  if (seconds == null) return null;
  final int minutes = int.tryParse(parts[parts.length - 2]) ?? -1;
  if (minutes < 0) return null;
  final int hours =
      parts.length == 3 ? (int.tryParse(parts.first) ?? -1) : 0;
  if (hours < 0) return null;
  final int wholeSeconds = seconds.floor();
  final int millis = ((seconds - wholeSeconds) * 1000).round();
  return ((hours * 60 + minutes) * 60 + wholeSeconds) * 1000 + millis;
}

// ── ASS / SSA ──────────────────────────────────────────────────────────────

final RegExp _assTimePattern =
    RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})[.](\d{1,3})$');

/// Default SSA/ASS event field order (used when the section has no `Format:`).
const List<String> _defaultEventFormat = <String>[
  'layer',
  'start',
  'end',
  'style',
  'name',
  'marginl',
  'marginr',
  'marginv',
  'effect',
  'text',
];

String _remapAss(FakeCutPlan plan, String text, _Counter counter) {
  final List<String> lines = _normalizeNewlines(text).split('\n');
  final List<String> out = <String>[];
  bool inEvents = false;
  List<String> format = _defaultEventFormat;

  for (final String line in lines) {
    final String trimmed = line.trim();
    final RegExpMatch? section = RegExp(r'^\[(.+)\]$').firstMatch(trimmed);
    if (section != null) {
      inEvents = section.group(1)!.trim().toLowerCase() == 'events';
      if (inEvents) format = _defaultEventFormat;
      out.add(line);
      continue;
    }
    if (!inEvents) {
      out.add(line);
      continue;
    }
    if (trimmed.toLowerCase().startsWith('format:')) {
      final List<String> fields = line
          .substring(line.indexOf(':') + 1)
          .split(',')
          .map((String f) => f.trim().toLowerCase())
          .toList();
      if (fields.length >= 2) format = fields;
      out.add(line);
      continue;
    }
    if (trimmed.toLowerCase().startsWith('dialogue:')) {
      final List<String>? remapped =
          _remapAssDialogue(plan, line, format, counter);
      if (remapped == null) {
        // A Dialogue the reader cannot re-time (wrong field count, unreadable
        // start/end, an Event format without Start/End). Emitting it verbatim
        // would show it at SOURCE seconds — drop it and let the caller report an
        // unusable subtitle when nothing is left.
        counter.dropped++;
        continue;
      }
      out.addAll(remapped);
      continue;
    }
    // Comment: / Picture: / Sound: / anything else stays verbatim: it does not
    // render, and rewriting non-Dialogue lines would risk breaking the styles.
    out.add(line);
  }
  return out.join('\n');
}

List<String>? _remapAssDialogue(
  FakeCutPlan plan,
  String line,
  List<String> format,
  _Counter counter,
) {
  final int colon = line.indexOf(':');
  if (colon < 0) return null;
  final String prefix = line.substring(0, colon + 1);
  final List<String> rawFields = line.substring(colon + 1).split(',');
  // The last field (Text) may contain commas: fold the extras back in.
  final List<String> fields;
  if (rawFields.length > format.length) {
    fields = <String>[
      ...rawFields.take(format.length - 1),
      rawFields.skip(format.length - 1).join(','),
    ];
  } else {
    fields = rawFields;
  }
  if (fields.length < format.length) return null;

  final int startIndex = format.indexOf('start');
  final int endIndex = format.indexOf('end');
  if (startIndex < 0 || endIndex < 0) return null;

  final int? startMs = _parseAssTime(fields[startIndex].trim());
  final int? endMs = _parseAssTime(fields[endIndex].trim());
  if (startMs == null || endMs == null) return null;

  final List<_Piece> pieces = _cutCue(plan, startMs, endMs, counter);
  if (pieces.isEmpty) return <String>[];

  final List<String> out = <String>[];
  for (final _Piece piece in pieces) {
    final List<String> copy = List<String>.of(fields);
    copy[startIndex] = _formatAssTime(piece.startMs);
    copy[endIndex] = _formatAssTime(piece.endMs);
    out.add('$prefix${copy.join(',')}');
  }
  return out;
}

/// Parses one ASS `H:MM:SS.cc` field, or null when it is not a real time.
///
/// TOTAL by contract (like `LlcParser.parseSeconds`): the hour field has no
/// upper bound in the pattern, and `int.parse`/`double.parse` would throw a
/// FormatException/UnsupportedError straight out of `remap()` — the caller only
/// understands "re-timed text or a failure", so a hand-edited subtitle may not
/// escape as a throw.
int? _parseAssTime(String raw) {
  final RegExpMatch? match = _assTimePattern.firstMatch(raw);
  if (match == null) return null;
  final int? hours = int.tryParse(match.group(1)!);
  final int minutes = int.parse(match.group(2)!);
  final int seconds = int.parse(match.group(3)!);
  final String fraction = match.group(4)!;
  final double? fractionSeconds = double.tryParse('0.$fraction');
  if (hours == null || fractionSeconds == null || !fractionSeconds.isFinite) {
    return null;
  }
  if (minutes > 59 || seconds > 59) return null;
  final int millis = (fractionSeconds * 1000).round();
  return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis;
}

String _formatAssTime(int ms) {
  final int clamped = ms < 0 ? 0 : ms;
  final int totalCentis = (clamped / 10).round();
  final int h = totalCentis ~/ 360000;
  final int m = (totalCentis ~/ 6000) % 60;
  final int s = (totalCentis ~/ 100) % 60;
  final int cs = totalCentis % 100;
  return '$h:${_p2(m)}:${_p2(s)}.${_p2(cs)}';
}

String _safeStem(String raw) {
  final String cleaned =
      raw.replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001F]'), '_').trim();
  if (cleaned.isEmpty) return 'subtitle';
  // Same 32-character cap as the EDL name (Windows path budget).
  return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
}
