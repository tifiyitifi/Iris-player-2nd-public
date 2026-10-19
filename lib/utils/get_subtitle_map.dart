import 'package:iris/models/file.dart';
import 'package:iris/utils/check_content_type.dart';
import 'package:path/path.dart' as path;

/// The map key a listing uses to look up a video's subtitles: the video's own
/// `basenameWithoutExtension`.
///
/// The previous key was the file name up to the FIRST dot, which collapsed
/// `Show.S01E01.*` and `Show.S02E01.*` onto one `Show` bucket and cross-attached
/// every episode's subtitles to every episode. A subtitle is instead bound to
/// the sibling video it extends by the LONGEST dot-separated name prefix — see
/// [getSubtitleMap].
String subtitleMapKey(String fileName) => path.basenameWithoutExtension(fileName);

/// Dot-separated name tokens of a file, lowercased for a case-insensitive
/// comparison (Windows/NTFS and SMB are case-insensitive).
List<String> _nameTokens(String fileName) =>
    path.basenameWithoutExtension(fileName).toLowerCase().split('.');

/// Number of leading tokens [a] and [b] share.
int _leadingTokenMatch(List<String> a, List<String> b) {
  final max = a.length < b.length ? a.length : b.length;
  var n = 0;
  while (n < max && a[n] == b[n]) {
    n++;
  }
  return n;
}

/// Pairs every subtitle file in a listing with the video it belongs to.
///
/// A subtitle binds to the video it shares the LONGEST leading run of
/// dot-separated name tokens with, requiring at least one shared token:
///
/// - `Show.S01E01.zh-ru.ass` → `Show.S01E01.mp4` (shares `Show`, `S01E01`), and
///   NEVER `Show.S02E01.mp4` (shares only `Show`);
/// - `Movie.ass` → `Movie.mkv` (shares `Movie`);
/// - a tie (`Show.S01E01.1080p.mp4` and `Show.S01E01.720p.mp4` beside
///   `Show.S01E01.zh.ass`) attaches to EVERY tied video, matching the old
///   first-dot behaviour so nothing regresses;
/// - a subtitle sharing no token with any video is an orphan — it gets no entry,
///   exactly as the first-dot rule left it unattached.
///
/// Only video files ([isVideo], defaults to [isVideoFile]) are match candidates:
/// binding a subtitle to a non-video sibling that happens to share its name
/// (`Show.S01E01.txt`) would leave the real video with no track.
///
/// The map key is [subtitleMapKey] of the MATCHED VIDEO, so a consumer looks a
/// video up by its own name. [Subtitle.name] is the subtitle file's OWN name
/// (the full file name), which keeps an `.ass`/`.srt` pair distinguishable in
/// the track panel.
Map<String, List<Subtitle>> getSubtitleMap<T>({
  required List<T> files,
  required String Function(T) getName,
  required String Function(T) getUri,
  bool Function(String fileName)? isVideo,
}) {
  final subtitleExtensions = {'ass', 'srt', 'vtt', 'sub'};
  final isVideoFile_ = isVideo ?? isVideoFile;

  // Video candidates, tokenized once. Only these can receive a subtitle.
  final videos = <({String key, List<String> tokens})>[];
  for (final file in files) {
    final name = getName(file);
    if (isVideoFile_(name)) {
      videos.add((key: subtitleMapKey(name), tokens: _nameTokens(name)));
    }
  }

  final subtitleMap = <String, List<Subtitle>>{};
  for (final file in files) {
    final fileName = getName(file);
    final fileExt =
        path.extension(fileName).replaceFirst('.', '').toLowerCase();
    if (!subtitleExtensions.contains(fileExt)) continue;

    final subtitleTokens = _nameTokens(fileName);
    var best = 0;
    for (final video in videos) {
      final score = _leadingTokenMatch(subtitleTokens, video.tokens);
      if (score > best) best = score;
    }
    if (best == 0) continue; // Orphan: no video shares even one token.

    final subtitle = Subtitle(name: fileName, uri: getUri(file));
    for (final video in videos) {
      if (_leadingTokenMatch(subtitleTokens, video.tokens) == best) {
        subtitleMap.putIfAbsent(video.key, () => []).add(subtitle);
      }
    }
  }
  return subtitleMap;
}
