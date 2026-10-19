import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/file.dart';
import 'package:iris/utils/get_subtitle_map.dart';

/// The track panel shows `Subtitle.name` verbatim, so it must be the subtitle
/// file's OWN name. The previous language-suffix label (`zh-ru`) made an
/// `.ass`/`.srt` pair render as two identical rows — and could be matched away
/// against an embedded track that happened to carry the same title.
///
/// Pairing is by the LONGEST dot-separated name prefix, so a subtitle reaches
/// the episode it extends and never a sibling episode that merely shares the
/// show name.
void main() {
  Map<String, List<Subtitle>> mapOf(List<String> files) => getSubtitleMap<String>(
        files: files,
        getName: (f) => f,
        getUri: (f) => 'http://h/$f',
      );

  test('names every subtitle after its own file name', () {
    final map = mapOf(const [
      'Show.S01E01.mp4',
      'Show.S01E01.zh-ru.ass',
      'Show.S01E01.zh-ru.srt',
      'other.ass',
    ]);

    // Keyed by the video's own basename; the two siblings stay distinguishable.
    expect(
      map['Show.S01E01'],
      const [
        Subtitle(name: 'Show.S01E01.zh-ru.ass', uri: 'http://h/Show.S01E01.zh-ru.ass'),
        Subtitle(name: 'Show.S01E01.zh-ru.srt', uri: 'http://h/Show.S01E01.zh-ru.srt'),
      ],
    );
    // `other.ass` has no sibling video: an orphan, no entry.
    expect(map.containsKey('other'), isFalse);
  });

  test('a subtitle binds only to the episode it extends, never a sibling', () {
    final map = mapOf(const [
      'Show.S01E01.mp4',
      'Show.S02E01.mp4',
      'Show.S01E01.zh.ass',
    ]);

    expect(map['Show.S01E01']!.map((s) => s.name), ['Show.S01E01.zh.ass']);
    expect(map.containsKey('Show.S02E01'), isFalse,
        reason: 'S02E01 only shares the `Show` prefix, so it must get no track');
  });

  test('a longer prefix beats a merely-shared first segment', () {
    final map = mapOf(const [
      'Show.S01E01.mp4',
      'Show.S01E02.720p.mp4',
      'Show.S01E02.zh.ass',
    ]);

    expect(map['Show.S01E02.720p']!.map((s) => s.name), ['Show.S01E02.zh.ass']);
    expect(map.containsKey('Show.S01E01'), isFalse);
  });

  test('a tied prefix attaches to every tied video (old behaviour preserved)', () {
    final map = mapOf(const [
      'Show.S01E01.1080p.mp4',
      'Show.S01E01.720p.mp4',
      'Show.S01E01.zh.ass',
    ]);

    expect(map['Show.S01E01.1080p']!.map((s) => s.name), ['Show.S01E01.zh.ass']);
    expect(map['Show.S01E01.720p']!.map((s) => s.name), ['Show.S01E01.zh.ass']);
  });

  test('ignores non-subtitle files and keeps every extension', () {
    final map = mapOf(const ['a.mp4', 'a.vtt', 'a.sub', 'a.txt', 'b.ass']);
    expect(map['a']!.map((s) => s.name), ['a.vtt', 'a.sub']);
    // No `b` video beside `b.ass`: an orphan, not an entry.
    expect(map.containsKey('b'), isFalse);
  });

  test('a non-video sibling never steals the track', () {
    // `Show.S01E01.txt` shares the video's exact basename but is not a video,
    // so it must not become the pairing target.
    final map = mapOf(const [
      'Show.S01E01.mp4',
      'Show.S01E01.txt',
      'Show.S01E01.zh.ass',
    ]);
    expect(map['Show.S01E01']!.map((s) => s.name), ['Show.S01E01.zh.ass']);
  });

  test('subtitleMapKey is the video basename, not the first dot segment', () {
    expect(subtitleMapKey('Show.S01E01.zh-ru.ass'), 'Show.S01E01.zh-ru');
    expect(subtitleMapKey('Show.S01E01.mp4'), 'Show.S01E01');
    expect(subtitleMapKey('Movie.ass'), 'Movie');
  });
}
