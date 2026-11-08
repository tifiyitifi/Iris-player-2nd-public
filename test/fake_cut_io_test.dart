import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';
import 'package:iris/features/fake_cut/services/fake_cut_discovery.dart';
import 'package:iris/features/fake_cut/services/fake_cut_edl_builder.dart';
import 'package:iris/features/fake_cut/services/fake_cut_subtitle_remapper.dart';
import 'package:iris/features/fake_cut/services/llc_parser.dart';
import 'package:path/path.dart' as p;

FakeCutPlan planOf(List<List<int>> ranges) => FakeCutPlan(
      planPath: '/videos/proj.llc',
      displayName: 'proj',
      version: 2,
      segments: <FakeCutSegment>[
        for (int i = 0; i < ranges.length; i++)
          FakeCutSegment(index: i, startMs: ranges[i][0], endMs: ranges[i][1]),
      ],
    );

const String _v2Project = '''
{
  version: 2,
  mediaFileName: 'movie.mp4',
  cutSegments: [
    { start: 1.5, end: 3.0, name: '', selected: true },
    { start: 10.0, end: 12.0, name: 'two', selected: true },
  ],
}
''';

const String _v3Project = '''
{
  version: 3,
  mediaFileName: 'other.mp4',
  cutSegments: [
    { start: '00:00:02.000000000', end: '00:00:04.000000000', name: '', selected: true },
  ],
}
''';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('iris_fake_cut_io');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('FakeCutDiscovery.scan', () {
    test('lists ONLY this video\'s projects; the rest are unmatched', () async {
      // Two videos, one project each, in a shared cut folder — the reported
      // setup. The playing video must never see the other video's plan.
      final String movie = p.join(root.path, 'movie.mp4');
      final String other = p.join(root.path, 'other.mp4');
      await File(movie).writeAsBytes(const <int>[0]);
      await File(other).writeAsBytes(const <int>[0]);
      await File(p.join(root.path, 'movie-proj.llc')).writeAsString(_v2Project);
      await File(p.join(root.path, 'other-proj.llc')).writeAsString(_v3Project);
      await File(p.join(root.path, 'broken.llc')).writeAsString('nope{');
      // Not a project: must be ignored.
      await File(p.join(root.path, 'notes.txt')).writeAsString('hello');

      final sources = await FakeCutDiscovery.scan(
        videoPath: movie,
        sourceDurationMs: 600000,
      );

      expect(sources, hasLength(1));
      expect(sources.single.displayName, 'movie-proj');
      expect(sources.single.bound, isTrue);
      expect(sources.single.usable, isTrue);
      expect(sources.single.plan!.segments, hasLength(2));
      expect(sources.single.plan!.mediaFileName, 'movie.mp4');
      expect(sources.single.signature, isNotEmpty);
      expect(
        sources.single.plan!.notices.map((n) => n.kind),
        isNot(contains(FakeCutNoticeKind.fileMismatch)),
      );

      // Everything that belongs to NO video beside it is still surfaced — in
      // the collapsed 「无匹配计划」 section, never as this video's plan.
      final unmatched = await FakeCutDiscovery.scanUnmatched(
        videoPath: movie,
        sourceDurationMs: 600000,
      );
      expect(unmatched.map((FakeCutPlanSource s) => s.displayName),
          <String>['broken']);
      expect(unmatched.every((FakeCutPlanSource s) => !s.bound), isTrue);
      expect(
        unmatched.single.parseFailure,
        LlcParseFailure.invalidJson,
      );

      // The neighbours are not "unmatched" — they belong to their own video.
      final otherSources = await FakeCutDiscovery.scan(
        videoPath: other,
        sourceDurationMs: 600000,
      );
      expect(otherSources.map((FakeCutPlanSource s) => s.displayName),
          <String>['other-proj']);
      expect(otherSources.single.plan!.mediaFileName, 'other.mp4');
    });

    test('a broken project named after the video stays in ITS list', () async {
      final String video = p.join(root.path, 'movie.mp4');
      await File(video).writeAsBytes(const <int>[0]);
      await File(p.join(root.path, 'movie.cut.llc')).writeAsString('nope{');

      final sources = await FakeCutDiscovery.scan(videoPath: video);
      expect(sources, hasLength(1));
      expect(sources.single.bound, isTrue);
      expect(sources.single.usable, isFalse);
      expect(sources.single.parseFailure, LlcParseFailure.invalidJson);
      expect(await FakeCutDiscovery.scanUnmatched(videoPath: video), isEmpty);
    });

    test('a broken project does not hide its neighbours', () async {
      // One hand-edited timecode used to throw a FormatException out of the
      // parser (which only reports LlcParseException), aborting the scan loop:
      // `discover` turned that into an EMPTY list, so every good project in the
      // folder disappeared from the tab with it.
      final String video = p.join(root.path, 'movie.mp4');
      await File(video).writeAsBytes(const <int>[0]);
      await File(p.join(root.path, 'movie.llc')).writeAsString(_v2Project);
      final String huge = '9' * 20;
      await File(p.join(root.path, 'movie.cut2.llc')).writeAsString('''
{
  version: 3,
  mediaFileName: 'movie.mp4',
  cutSegments: [{ start: '$huge:00:00', end: '00:00:01.000000000', name: '' }],
}
''');

      final sources = await FakeCutDiscovery.scan(
        videoPath: video,
        sourceDurationMs: 600000,
      );
      expect(sources, hasLength(2), reason: 'the good project must survive');
      expect(sources.where((FakeCutPlanSource s) => s.usable), hasLength(1));
      final FakeCutPlanSource bad =
          sources.singleWhere((FakeCutPlanSource s) => !s.usable);
      expect(bad.parseFailure, LlcParseFailure.invalidTime);
    });

    test('an unreadable directory is an empty list, not a throw', () async {
      final sources = await FakeCutDiscovery.scan(
        videoPath: p.join(root.path, 'missing', 'movie.mp4'),
      );
      expect(sources, isEmpty);
      expect(
        await FakeCutDiscovery.scanUnmatched(
          videoPath: p.join(root.path, 'missing', 'movie.mp4'),
        ),
        isEmpty,
      );
    });
  });

  group('prepareFakeCutEdl', () {
    test('writes UTF-8, reuses the cache file, prunes nothing recent',
        () async {
      final plan = planOf(<List<int>>[
        <int>[1000, 3000],
        <int>[10000, 12000],
      ]);
      final first = await prepareFakeCutEdl(
        plan: plan,
        sourcePath: r'E:\media\与室友.mp4',
        signature: 'sig-1',
        tempRoot: root,
      );
      final File file = File(first.path);
      expect(await file.exists(), isTrue);
      final text = await file.readAsString();
      expect(text.split('\n').first, '# mpv EDL v0');
      expect(text, contains('!no_chapters'));
      expect(text, contains('start=1.000,length=2.000'));
      expect(text, contains('start=10.000,length=2.000'));
      expect(text, contains('E:/media/与室友.mp4'));

      final second = await prepareFakeCutEdl(
        plan: plan,
        sourcePath: r'E:\media\与室友.mp4',
        signature: 'sig-1',
        tempRoot: root,
      );
      expect(second.path, first.path, reason: 'cache hit has no new file');

      final changed = await prepareFakeCutEdl(
        plan: planOf(<List<int>>[<int>[1000, 4000]]),
        sourcePath: r'E:\media\与室友.mp4',
        signature: 'sig-1',
        tempRoot: root,
      );
      expect(changed.path, isNot(first.path),
          reason: 'changed ranges produce a new artefact');
    });
  });

  group('FakeCutSubtitleRemapper.remap (file IO)', () {
    test('writes a re-timed subtitle and reuses it', () async {
      final plan = planOf(<List<int>>[
        <int>[10000, 20000],
      ]);
      final File sub = File(p.join(root.path, 'movie.zh.srt'));
      await sub.writeAsString('1\n00:00:12,000 --> 00:00:13,000\n你好\n');

      final result = await FakeCutSubtitleRemapper.remap(
        plan: plan,
        subtitlePath: sub.path,
        signature: 'sig',
        tempRoot: root,
      );
      expect(result.ok, isTrue);
      expect(result.emittedCues, 1);
      final File out = File(result.uri!);
      expect(await out.exists(), isTrue);
      expect(await out.readAsString(), contains('00:00:02,000 --> 00:00:03,000'));
      expect(await out.readAsString(), contains('你好'));

      final again = await FakeCutSubtitleRemapper.remap(
        plan: plan,
        subtitlePath: sub.path,
        signature: 'sig',
        tempRoot: root,
      );
      expect(again.uri, result.uri);
    });

    test('subtitle entirely in a removed gap is reported, not written',
        () async {
      final plan = planOf(<List<int>>[
        <int>[10000, 20000],
      ]);
      final File sub = File(p.join(root.path, 'gap.srt'));
      await sub.writeAsString('1\n00:00:40,000 --> 00:00:42,000\ngone\n');

      final result = await FakeCutSubtitleRemapper.remap(
        plan: plan,
        subtitlePath: sub.path,
        signature: 'sig',
        tempRoot: root,
      );
      expect(result.ok, isFalse);
      expect(result.failure, FakeCutSubtitleFailure.emptyAfterRemap);
    });

    test('a subtitle whose cues cannot be re-timed is reported, not written',
        () async {
      // Same contract as the "removed gap" case: the caller must NOT load the
      // original file (its cues would sit at SOURCE seconds), so an unusable
      // remap has to be a failure rather than a half-copied artefact.
      final plan = planOf(<List<int>>[
        <int>[10000, 20000],
      ]);
      final File sub = File(p.join(root.path, 'noparse.vtt'));
      await sub.writeAsString('WEBVTT\n\n'
          '00:00:12.0000 --> 00:00:15.0000\nunparsable\n');

      final result = await FakeCutSubtitleRemapper.remap(
        plan: plan,
        subtitlePath: sub.path,
        signature: 'sig',
        tempRoot: root,
      );
      expect(result.ok, isFalse);
      expect(result.failure, FakeCutSubtitleFailure.emptyAfterRemap);
      final Directory cache =
          Directory(p.join(root.path, 'iris_fake_cut'));
      final Iterable<File> written = await cache.exists()
          ? (await cache.list().toList()).whereType<File>()
          : const <File>[];
      expect(
        written.where((File f) => f.path.endsWith('.vtt')),
        isEmpty,
        reason: 'a source-timed copy must never reach mpv',
      );
    });

    test('an edited subtitle of the SAME byte length is not served stale',
        () async {
      final plan = planOf(<List<int>>[
        <int>[10000, 20000],
      ]);
      final File sub = File(p.join(root.path, 'same.srt'));
      await sub.writeAsString('1\n00:00:12,000 --> 00:00:13,000\nAAAAA\n');
      final first = await FakeCutSubtitleRemapper.remap(
        plan: plan,
        subtitlePath: sub.path,
        signature: 'sig',
        tempRoot: root,
      );
      expect(first.ok, isTrue);

      // Same length, different text: the old cache key carried only
      // `bytes.length`, so the artefact was reused and the edit never showed.
      await sub.writeAsString('1\n00:00:12,000 --> 00:00:13,000\nBBBBB\n');
      final second = await FakeCutSubtitleRemapper.remap(
        plan: plan,
        subtitlePath: sub.path,
        signature: 'sig',
        tempRoot: root,
      );
      expect(second.ok, isTrue);
      expect(second.uri, isNot(first.uri));
      expect(await File(second.uri!).readAsString(), contains('BBBBB'));
    });

    test('unknown format and missing file are classified', () async {
      final plan = planOf(<List<int>>[
        <int>[0, 1000],
      ]);
      final File sub = File(p.join(root.path, 'movie.sub'));
      await sub.writeAsString('{0}{1}hi');

      final unsupported = await FakeCutSubtitleRemapper.remap(
        plan: plan,
        subtitlePath: sub.path,
        signature: 'sig',
        tempRoot: root,
      );
      expect(unsupported.failure, FakeCutSubtitleFailure.unsupportedFormat);

      final missing = await FakeCutSubtitleRemapper.remap(
        plan: plan,
        subtitlePath: p.join(root.path, 'missing.srt'),
        signature: 'sig',
        tempRoot: root,
      );
      expect(missing.failure, FakeCutSubtitleFailure.unreadable);
    });
  });
}
