import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/get_subtitle_map.dart';
import 'package:path/path.dart' as p;

/// The desktop local listing pairs a video with its subtitles using the SAME
/// rule as every remote/SAF listing ([getSubtitleMap]).
///
/// The bug history: the local path once grouped by the exact
/// `basenameWithoutExtension`, so a subtitle carrying a language segment
/// (`Show.S01E01.zh-ru.ass` beside `Show.S01E01.mp4`) formed a group with no
/// video and was dropped from the listing entirely. It then grouped by the
/// first dot, which cross-attached every episode of a series. It now binds to
/// the sibling video sharing the LONGEST dot-separated name prefix (see
/// [subtitleMapKey]). WebDAV/FTP/SAF all go through [getSubtitleMap] too.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('iris-local-listing');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void touch(String name) => File(p.join(dir.path, name)).writeAsStringSync('x');

  Future<List<FileItem>> list() async {
    final storage = LocalStorage(
      id: 'local',
      type: StorageType.internal,
      name: 'Local',
      basePath: [dir.path],
    );
    final result = await getLocalFilesResult(storage, [dir.path]);
    return result.items;
  }

  test('a language-segmented subtitle is attached to its video', () async {
    touch('Show.S01E01.mp4');
    touch('Show.S01E01.zh-ru.ass');
    touch('Show.S01E01.zh.srt');

    final items = await list();
    final video = items.firstWhere((f) => f.name == 'Show.S01E01.mp4');

    expect(
      video.subtitles.map((s) => s.name).toSet(),
      {'Show.S01E01.zh-ru.ass', 'Show.S01E01.zh.srt'},
    );
    // The subtitle's own name is the display label, and its uri is the file.
    expect(
      video.subtitles.map((s) => s.uri).toSet(),
      {
        p.join(dir.path, 'Show.S01E01.zh-ru.ass'),
        p.join(dir.path, 'Show.S01E01.zh.srt'),
      },
    );
  });

  test('a subtitle next to a plainly named video still pairs', () async {
    touch('Movie.mkv');
    touch('Movie.ass');

    final items = await list();
    final video = items.firstWhere((f) => f.name == 'Movie.mkv');
    expect(video.subtitles.map((s) => s.name), ['Movie.ass']);
  });

  test('subtitle files are never listed as rows of their own', () async {
    touch('Show.S01E01.mp4');
    touch('Show.S01E01.zh-ru.ass');
    // Orphan: no video of that name in this directory.
    touch('Orphan.zh.ass');

    final items = await list();
    expect(
      items.map((f) => f.name),
      isNot(contains('Show.S01E01.zh-ru.ass')),
      reason: 'a subtitle is an association, not a row',
    );
    expect(items.map((f) => f.name), isNot(contains('Orphan.zh.ass')));
    expect(items.map((f) => f.name), ['Show.S01E01.mp4']);
  });

  test('a whole series does not cross-attach subtitles', () async {
    touch('Show.S01E01.mp4');
    touch('Show.S02E01.mp4');
    touch('Show.S01E01.zh.ass');

    final items = await list();
    final ep1 = items.firstWhere((f) => f.name == 'Show.S01E01.mp4');
    final ep2 = items.firstWhere((f) => f.name == 'Show.S02E01.mp4');

    expect(ep1.subtitles.map((s) => s.name), ['Show.S01E01.zh.ass']);
    expect(ep2.subtitles, isEmpty,
        reason: 'S02E01 shares only the `Show` prefix and must get no track');
  });

  test('the pairing key is the video basename, not the first dot segment', () {
    expect(subtitleMapKey('Show.S01E01.zh-ru.ass'), 'Show.S01E01.zh-ru');
    expect(subtitleMapKey('Show.S01E01.mp4'), 'Show.S01E01');
    expect(subtitleMapKey('Movie.ass'), 'Movie');
  });
}
