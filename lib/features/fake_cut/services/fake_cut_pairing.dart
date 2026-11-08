import 'package:iris/utils/name_tokens.dart';
import 'package:path/path.dart' as p;

/// One LosslessCut `.llc` in a directory, reduced to what PAIRING needs.
///
/// Kept free of the parsed plan on purpose: the folder index reads a project
/// once per directory just to learn WHICH video it belongs to, and the plan
/// itself is only parsed for the videos the user actually opens.
class LlcSibling {
  const LlcSibling({required this.path, this.mediaFileName});

  /// Absolute path of the `.llc`.
  final String path;

  /// `mediaFileName` recorded inside the project (the authoritative pairing key
  /// — LosslessCut writes the SOURCE file name there), or null when the project
  /// is unreadable / predates the field.
  final String? mediaFileName;

  String get fileName => p.basename(path);

  /// Lowercase project stem (`movie-proj`), the fallback pairing key.
  String get stem => p.basenameWithoutExtension(path).toLowerCase().trim();

  @override
  String toString() => 'LlcSibling($fileName)';
}

/// How one directory's projects bind to the videos beside them.
class LlcBinding {
  const LlcBinding({required this.byVideo, required this.unmatched});

  /// Lowercase video file name → the projects it owns, in listing order.
  ///
  /// A video may own SEVERAL projects (`movie.cut1.llc`, `movie.zh.llc`) — the
  /// same way a video may own several external subtitles.
  final Map<String, List<LlcSibling>> byVideo;

  /// Projects that name no video in this directory (renamed/moved source).
  ///
  /// Never applied to any video: they are surfaced in the 简播 tab's collapsed
  /// 「无匹配计划」 section instead.
  final List<LlcSibling> unmatched;

  List<LlcSibling> forVideo(String videoFileName) =>
      byVideo[videoFileName.toLowerCase()] ?? const <LlcSibling>[];
}

/// Binds every `.llc` to the ONE video it was made for, the way a subtitle binds
/// to its sibling video (`get_subtitle_map.dart` uses the same tokens).
///
/// WHY per-video: 简播 used to list EVERY project of the directory for whichever
/// video was playing, so in a shared cut folder two projects both played the one
/// video on screen (the EDL is built over the PLAYING file). Pairing rules, in
/// order of authority — first hit wins:
///
///  1. the project's `mediaFileName` equals a video's file name (exact truth:
///     LosslessCut recorded the source it was cut from);
///  2. the project stem is the video stem (`movie.llc`);
///  3. the project stem with LosslessCut's default suffix removed is the video
///     stem (`movie-proj.llc`, `movieproj.llc`, `movie.proj.llc`) — only when
///     rule 2 matched nothing, so `movie-proj.llc` beside a real
///     `movie-proj.mp4` names THAT file;
///  4. the LONGEST leading run of dot-separated name tokens, at least one shared
///     (`Show.S01E01.zh.llc` → `Show.S01E01.mp4`, never `Show.S02E01.mp4`),
///     narrowed to the closest candidates (fewest extra tokens) so a featurette
///     sharing the prefix (`Show.S01E01.extra.mp4`) is not offered another
///     episode's cut points.
///
/// A genuine tie — two videos that are equally close (the same stem in two
/// containers) — attaches to every tied video, exactly like subtitles.
LlcBinding bindLlcProjects({
  required Iterable<String> videoNames,
  required Iterable<LlcSibling> projects,
}) {
  final Map<String, String> videoStems = <String, String>{};
  for (final String name in videoNames) {
    final String key = name.toLowerCase();
    if (key.isEmpty) continue;
    videoStems[key] = p.basenameWithoutExtension(key).trim();
  }

  final Map<String, List<LlcSibling>> byVideo = <String, List<LlcSibling>>{};
  final List<LlcSibling> unmatched = <LlcSibling>[];

  void attach(String videoKey, LlcSibling project) {
    final List<LlcSibling> list =
        byVideo.putIfAbsent(videoKey, () => <LlcSibling>[]);
    if (!list.contains(project)) list.add(project);
  }

  for (final LlcSibling project in projects) {
    final String? recorded = project.mediaFileName;
    if (recorded != null) {
      final String recordedName = p.basename(recorded.trim()).toLowerCase();
      if (recordedName.isNotEmpty && videoStems.containsKey(recordedName)) {
        attach(recordedName, project);
        continue;
      }
    }

    // Rules 2 and 3 are exact-stem matches, tried in order of authority: the
    // project stem AS IS outranks the LosslessCut suffix strip. Testing both at
    // once (`bases.contains`) attached `movie-proj.llc` to BOTH `movie-proj.mp4`
    // and `movie.mp4`, and the cut ranges of one file were then applied to the
    // other.
    final String exactStem = project.stem;
    final String strippedStem = llcVideoStem(exactStem);
    final List<String> exact = <String>[
      for (final MapEntry<String, String> video in videoStems.entries)
        if (video.value == exactStem) video.key,
    ];
    if (exact.isNotEmpty) {
      for (final String key in exact) {
        attach(key, project);
      }
      continue;
    }
    final List<String> stripped = <String>[
      for (final MapEntry<String, String> video in videoStems.entries)
        if (strippedStem != exactStem && video.value == strippedStem) video.key,
    ];
    if (stripped.isNotEmpty) {
      for (final String key in stripped) {
        attach(key, project);
      }
      continue;
    }

    final List<String> bases = <String>{
      exactStem,
      strippedStem,
    }.where((String base) => base.isNotEmpty).toList(growable: false);

    int best = 0;
    final Map<String, int> scores = <String, int>{};
    for (final MapEntry<String, String> video in videoStems.entries) {
      int score = 0;
      for (final String base in bases) {
        final int shared =
            leadingTokenMatch(base.split('.'), video.value.split('.'));
        if (shared > score) score = shared;
      }
      scores[video.key] = score;
      if (score > best) best = score;
    }
    if (best == 0) {
      unmatched.add(project);
      continue;
    }
    // Among equally long shared prefixes, only the CLOSEST videos (fewest extra
    // name tokens) are candidates: `Show.S01E01.zh.llc` names `Show.S01E01.mp4`,
    // not the `Show.S01E01.extra.mp4` featurette. A genuine tie (same stem,
    // different container) still shares the plan, exactly like a subtitle.
    int closest = 1 << 30;
    for (final MapEntry<String, int> entry in scores.entries) {
      if (entry.value != best) continue;
      final int extra =
          videoStems[entry.key]!.split('.').length - best;
      if (extra < closest) closest = extra;
    }
    for (final MapEntry<String, int> entry in scores.entries) {
      if (entry.value != best) continue;
      if (videoStems[entry.key]!.split('.').length - best != closest) continue;
      attach(entry.key, project);
    }
  }

  return LlcBinding(byVideo: byVideo, unmatched: unmatched);
}

/// `<stem>-proj` / `<stem>proj` / `<stem>.proj` → `<stem>`.
///
/// LosslessCut's own default project naming: the project is not named after the
/// video, it is named after the video plus a marker. Only the SUFFIX is removed;
/// a stem that merely ends in `proj` keeps working through rule 2 as well.
String llcVideoStem(String projectStem) {
  String stem = projectStem.toLowerCase().trim();
  if (stem.endsWith('-proj')) return stem.substring(0, stem.length - 5);
  if (stem.endsWith('.proj')) return stem.substring(0, stem.length - 5);
  if (stem.endsWith('proj') && stem.length > 4) {
    stem = stem.substring(0, stem.length - 4);
    if (stem.endsWith('-') || stem.endsWith('.')) {
      stem = stem.substring(0, stem.length - 1);
    }
    return stem;
  }
  return stem;
}
