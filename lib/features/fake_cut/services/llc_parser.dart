import 'package:iris/features/fake_cut/services/json5_light.dart';

/// Why a `.llc` project could not be read. The UI maps each kind to one
/// localized line, so the raw parser wording never reaches the user.
enum LlcParseFailure {
  /// Not JSON5 at all, or the root is not an object.
  invalidJson,

  /// A `version` outside 1..3 (LosslessCut has never written anything else).
  unsupportedVersion,

  /// `cutSegments` missing / not a list, or a segment not an object.
  invalidStructure,

  /// A `start` / `end` value that is neither seconds nor a timecode.
  invalidTime,
}

class LlcParseException implements Exception {
  const LlcParseException(this.failure, this.detail);

  final LlcParseFailure failure;

  /// Diagnostic only (segment index, offending token, ...); never shown raw.
  final String detail;

  @override
  String toString() => 'LlcParseException(${failure.name}): $detail';
}

/// One cut segment exactly as stored in the project file.
///
/// [endMs] is null for a **marker**: LosslessCut's own `filterNonMarkers` treats
/// a segment without `end` as a bookmark, not a playable range, so the plan
/// builder drops it (see `fake_cut_plan_builder.dart`).
class LlcSegment {
  const LlcSegment({
    required this.startMs,
    required this.endMs,
    required this.selected,
    required this.name,
  });

  /// Source start in milliseconds.
  final int startMs;

  /// Source end in milliseconds; null = marker.
  final int? endMs;

  /// Absent in the file means SELECTED ([LlcParser] applies the same default as
  /// LosslessCut's `createSegment`: `props?.selected ?? true`).
  final bool selected;

  final String name;

  bool get isMarker => endMs == null;
}

/// A parsed LosslessCut project file.
class LlcProject {
  const LlcProject({
    required this.version,
    required this.mediaFileName,
    required this.segments,
  });

  /// 1, 2 or 3. v1 stored bare numbers with an optional `start`; v2 numbers;
  /// v3 readable `HH:MM:SS.nnnnnnnnn` strings (this repo's LosslessCut fork).
  final int version;

  /// The source file name the project was cut from, when recorded.
  final String? mediaFileName;

  final List<LlcSegment> segments;
}

/// Reads a LosslessCut `.llc` project.
///
/// All versions collapse onto the same millisecond model: [LlcSegment] only
/// knows integer source milliseconds, which is the resolution the EDL and the
/// progress columns use. A project stored with nanosecond timecodes therefore
/// rounds to the nearest millisecond (≤0.5 ms, far below one video frame).
abstract final class LlcParser {
  static const Set<int> supportedVersions = <int>{1, 2, 3};

  static LlcProject parse(String raw) {
    final String text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
    final Object? decoded;
    try {
      decoded = parseJson5(text);
    } on Json5FormatException catch (e) {
      throw LlcParseException(LlcParseFailure.invalidJson, e.toString());
    }
    if (decoded is! Map) {
      throw const LlcParseException(
          LlcParseFailure.invalidJson, 'root is not an object');
    }

    final Object? rawVersion = decoded['version'];
    if (rawVersion is! num || !rawVersion.isFinite) {
      throw LlcParseException(
          LlcParseFailure.invalidStructure, 'version=${rawVersion.runtimeType}');
    }
    // `toInt()` alone silently truncates: a future `version: 2.9` would have
    // been parsed with v2 rules. Only a WHOLE number selects a version; `3.0`
    // is still a valid encoding of 3.
    final int version = rawVersion.toInt();
    if (rawVersion != version || !supportedVersions.contains(version)) {
      throw LlcParseException(
          LlcParseFailure.unsupportedVersion, 'version=$rawVersion');
    }

    final Object? rawMediaFileName = decoded['mediaFileName'];
    final String? mediaFileName =
        rawMediaFileName is String && rawMediaFileName.isNotEmpty
            ? rawMediaFileName
            : null;

    final Object? rawSegments = decoded['cutSegments'];
    if (rawSegments is! List) {
      throw LlcParseException(
          LlcParseFailure.invalidStructure,
          'cutSegments=${rawSegments.runtimeType}');
    }

    final List<LlcSegment> segments = <LlcSegment>[];
    for (int i = 0; i < rawSegments.length; i++) {
      final Object? rawSegment = rawSegments[i];
      if (rawSegment is! Map) {
        throw LlcParseException(
            LlcParseFailure.invalidStructure, 'segment[$i] is not an object');
      }
      // v1 allowed `start` to be missing ("from the beginning"); v2/v3 require
      // it. Defaulting to 0 keeps a hand-edited v2 file usable instead of
      // rejecting the whole plan.
      final int startMs;
      if (rawSegment.containsKey('start')) {
        final int? parsed = parseTimeValueMs(rawSegment['start']);
        if (parsed == null) {
          throw LlcParseException(
              LlcParseFailure.invalidTime, 'segment[$i].start');
        }
        startMs = parsed;
      } else {
        startMs = 0;
      }

      int? endMs;
      final Object? rawEnd = rawSegment['end'];
      if (rawEnd != null) {
        endMs = parseTimeValueMs(rawEnd);
        if (endMs == null) {
          throw LlcParseException(LlcParseFailure.invalidTime, 'segment[$i].end');
        }
      }

      final Object? rawSelected = rawSegment['selected'];
      final Object? rawName = rawSegment['name'];

      segments.add(LlcSegment(
        startMs: startMs,
        endMs: endMs,
        // LosslessCut's createSegment defaults an absent flag to true.
        selected: rawSelected is bool ? rawSelected : true,
        name: rawName is String ? rawName : '',
      ));
    }

    return LlcProject(
      version: version,
      mediaFileName: mediaFileName,
      segments: segments,
    );
  }

  /// Converts one stored time value to milliseconds.
  ///
  /// Mirrors `parseLlcTime` in the LosslessCut fork: a finite number is
  /// seconds; a string is either a plain number of seconds or
  /// `[-]H:MM:SS[.fraction]`. Values are rounded (not truncated) so a
  /// nanosecond timecode does not systematically lose its last millisecond.
  static int? parseTimeValueMs(Object? value) {
    if (value is num) {
      if (!value.isFinite) return null;
      return _roundSecondsToMs(value.toDouble());
    }
    if (value is String) {
      final double? seconds = parseSeconds(value);
      if (seconds == null) return null;
      return _roundSecondsToMs(seconds);
    }
    return null;
  }

  /// Milliseconds for [seconds], or null when it is not a real position.
  ///
  /// `double.round()` throws `UnsupportedError` on a non-finite value, and that
  /// is an Error — the discovery layer's `on LlcParseException` could not stop
  /// it. A plain-number timecode of a few hundred digits is enough to reach it
  /// (`double.parse` answers Infinity), so the guard lives at this one funnel.
  static int? _roundSecondsToMs(double seconds) {
    if (!seconds.isFinite) return null;
    final double ms = seconds * 1000;
    if (!ms.isFinite) return null;
    return ms.round();
  }

  /// Parses a timecode / plain-seconds string into seconds, or null.
  ///
  /// TOTAL by contract: a hand-edited project returns null (the caller reports
  /// [LlcParseFailure.invalidTime]) instead of throwing, so one bad project can
  /// never abort the whole folder's scan or the open that reads it.
  static double? parseSeconds(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return null;

    // Canonical HH:MM:SS[.fraction], short fields allowed (H:M:S).
    final RegExpMatch? withHours = _hhmmss.firstMatch(text);
    if (withHours != null) {
      // `hours` is unbounded in the pattern: `int.parse` threw a FormatException
      // for an out-of-range field, and the field is user-editable.
      final int? hours = int.tryParse(withHours.group(2)!);
      final int minutes = int.parse(withHours.group(3)!);
      final int seconds = int.parse(withHours.group(4)!);
      if (hours == null || minutes > 59 || seconds > 59) return null;
      final String? fraction = withHours.group(5);
      final double? fractionSeconds =
          fraction == null ? 0 : double.tryParse('0.$fraction');
      if (fractionSeconds == null) return null;
      final double total =
          hours * 3600 + minutes * 60 + seconds + fractionSeconds;
      return withHours.group(1) == '-' ? -total : total;
    }

    // Tolerated extras: `MM:SS[.fraction]` (VTT-style) and a bare number.
    final RegExpMatch? shortForm = _mmss.firstMatch(text);
    if (shortForm != null) {
      final int minutes = int.parse(shortForm.group(2)!);
      final int seconds = int.parse(shortForm.group(3)!);
      if (seconds > 59) return null;
      final String? fraction = shortForm.group(4);
      final double? fractionSeconds =
          fraction == null ? 0 : double.tryParse('0.$fraction');
      if (fractionSeconds == null) return null;
      final double total = minutes * 60 + seconds + fractionSeconds;
      return shortForm.group(1) == '-' ? -total : total;
    }

    if (_plainNumber.hasMatch(text)) {
      final double? plain = double.tryParse(text);
      if (plain == null || !plain.isFinite) return null;
      return plain;
    }
    return null;
  }

  static final RegExp _hhmmss =
      RegExp(r'^(-)?(\d+):(\d{1,2}):(\d{1,2})(?:[.,](\d+))?$');
  static final RegExp _mmss =
      RegExp(r'^(-)?(\d{1,3}):(\d{1,2})(?:[.,](\d+))?$');
  static final RegExp _plainNumber = RegExp(r'^-?\d+(?:\.\d+)?$');
}
