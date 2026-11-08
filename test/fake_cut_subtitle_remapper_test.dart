import 'dart:convert';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';
import 'package:iris/features/fake_cut/services/fake_cut_subtitle_remapper.dart';

FakeCutPlan plan(List<List<int>> ranges) => FakeCutPlan(
      planPath: '/videos/proj.llc',
      displayName: 'proj',
      version: 2,
      segments: <FakeCutSegment>[
        for (int i = 0; i < ranges.length; i++)
          FakeCutSegment(index: i, startMs: ranges[i][0], endMs: ranges[i][1]),
      ],
    );

FakeCutSubtitleRemap remap(FakeCutPlan p, String path, String text) =>
    FakeCutSubtitleRemapper.remapText(plan: p, path: path, text: text)!;

void main() {
  final cut = plan(<List<int>>[
    <int>[10000, 20000],
    <int>[50000, 60000],
  ]);

  group('SRT', () {
    const srt = '''
1
00:00:12,000 --> 00:00:15,000
inside the first range

2
00:00:18,000 --> 00:00:22,000
the first range's tail

3
00:00:25,000 --> 00:00:30,000
inside a removed gap

4
00:00:52,000 --> 00:00:54,000
inside the second range
''';

    test('cuts, clips, drops and renumbers', () {
      final result = remap(cut, 'a.srt', srt);
      expect(result.emittedCues, 3);
      expect(result.droppedCues, 1);
      expect(result.text, contains('00:00:02,000 --> 00:00:05,000'));
      expect(result.text, contains('00:00:08,000 --> 00:00:10,000'));
      expect(result.text, contains('00:00:12,000 --> 00:00:14,000'));
      expect(result.text, isNot(contains('removed gap')));
      // Renumbered 1..3 in plan order.
      expect(result.text, contains('1\n00:00:02,000'));
      expect(result.text, contains('2\n00:00:08,000'));
      expect(result.text, contains('3\n00:00:12,000'));
    });

    test('repeated ranges duplicate the cue', () {
      final repeated = plan(<List<int>>[
        <int>[10000, 20000],
        <int>[10000, 20000],
      ]);
      final result = remap(repeated, 'a.srt', srt);
      expect(result.text, contains('00:00:02,000 --> 00:00:05,000'));
      expect(result.text, contains('00:00:12,000 --> 00:00:15,000'));
      // 1 (first range) + 1 (clipped tail) + 0 (gap) + 0 (second starts at 50s)
      expect(result.emittedCues, 4);
    });

    test('a document with no cue is reported as such', () {
      final result = remap(cut, 'a.srt', 'just text\n');
      expect(result.emittedCues, 0);
    });

    test('a cue whose timing cannot be parsed is dropped, never source-timed',
        () {
      // 4-digit milliseconds do not match the reader's `\d{1,3}` fraction. The
      // block used to be copied VERBATIM, i.e. shown at its SOURCE seconds — the
      // exact wrong-time subtitle `resolveSubtitleUriForCut` refuses to load.
      const mixed = '''
1
00:00:12,0000 --> 00:00:15,0000
unparsable timing

2
00:00:52,000 --> 00:00:54,000
inside the second range
''';
      final result = remap(cut, 'bad.srt', mixed);
      expect(result.text, isNot(contains('unparsable timing')));
      expect(result.text, isNot(contains('00:00:12,0000')));
      expect(result.text, contains('00:00:12,000 --> 00:00:14,000'));
      expect(result.emittedCues, 1);
      expect(result.droppedCues, 1);
    });
  });

  group('WebVTT', () {
    const vtt = '''WEBVTT

NOTE this note must survive

STYLE
::cue { color: red }

1
00:00:12.000 --> 00:00:15.000 align:start
inside the first range
''';

    test('keeps header/NOTE/STYLE and re-times cues', () {
      final result = remap(cut, 'a.vtt', vtt);
      expect(result.text, startsWith('WEBVTT'));
      expect(result.text, contains('NOTE this note must survive'));
      expect(result.text, contains('STYLE'));
      expect(result.text, contains('::cue { color: red }'));
      expect(result.text,
          contains('00:00:02.000 --> 00:00:05.000 align:start'));
    });

    test('MM:SS timestamps are understood', () {
      const short = '''WEBVTT

00:12.000 --> 00:14.000
short form
''';
      final result = remap(cut, 'b.vtt', short);
      expect(result.text, contains('00:00:02.000 --> 00:00:04.000'));
    });

    test('a cue whose timing cannot be parsed is dropped, not re-emitted', () {
      const mixed = '''WEBVTT

00:00:12.0000 --> 00:00:15.0000
unparsable timing

00:00:52.000 --> 00:00:54.000
inside the second range
''';
      final result = remap(cut, 'bad.vtt', mixed);
      expect(result.text, isNot(contains('unparsable timing')));
      expect(result.text, isNot(contains('00:00:12.0000')));
      expect(result.text, contains('00:00:12.000 --> 00:00:14.000'));
      expect(result.emittedCues, 1);
      expect(result.droppedCues, 1);
      // The metadata blocks are not cues and must still be byte-identical.
      expect(result.text, startsWith('WEBVTT'));
    });

    test('a cue identifier survives the re-time', () {
      const vtt = '''WEBVTT

intro-cue
00:00:52.000 --> 00:00:54.000
inside the second range
''';
      final result = remap(cut, 'id.vtt', vtt);
      expect(result.text, contains('intro-cue\n00:00:12.000 --> 00:00:14.000'));
    });

    test('a NOTE that mentions a timecode is still metadata, never dropped', () {
      // The loose "this is a timing line that failed to parse" probe must not
      // run over the BODY of a metadata block: a NOTE quoting a timecode used to
      // be counted as a dropped cue (and, on a subtitle with no other cue, made
      // the whole file report `emptyAfterRemap`).
      const vtt = '''WEBVTT

NOTE
12:00 --> 13:00 the deleted scene

00:00:52.000 --> 00:00:54.000
inside the second range
''';
      final result = remap(cut, 'note.vtt', vtt);
      expect(result.text, contains('12:00 --> 13:00 the deleted scene'));
      expect(result.emittedCues, 1);
      expect(result.droppedCues, 0);
    });

    test('an ambiguous multi-line identifier is dropped, not emitted', () {
      // WebVTT allows exactly ONE identifier line above the timing. Emitting two
      // produced a file whose first line is neither an id nor a timing, so the
      // cue was swallowed as part of the preceding block.
      const vtt = '''WEBVTT

intro-cue
second-line
00:00:52.000 --> 00:00:54.000
inside the second range
''';
      final result = remap(cut, 'multi.vtt', vtt);
      expect(result.text, isNot(contains('second-line')));
      expect(result.text, contains('00:00:12.000 --> 00:00:14.000'));
    });
  });

  group('ASS', () {
    const ass = '''[Script Info]
Title: test
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize
Style: Default,Arial,20

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:12.00,0:00:15.00,Default,,0,0,0,,inside, with a comma
Comment: 0,0:00:12.00,0:00:15.00,Default,,0,0,0,,a comment
Dialogue: 0,0:00:52.00,0:00:54.00,Default,Speaker,0,0,0,,second range
''';

    test('only Dialogue start/end change, everything else survives', () {
      final result = remap(cut, 'a.ass', ass);
      expect(result.emittedCues, 2);
      expect(result.text, contains('[Script Info]'));
      expect(result.text, contains('Style: Default,Arial,20'));
      expect(result.text,
          contains('Dialogue: 0,0:00:02.00,0:00:05.00,Default,,0,0,0,,'
              'inside, with a comma'));
      expect(result.text,
          contains('Dialogue: 0,0:00:12.00,0:00:14.00,Default,Speaker,'
              '0,0,0,,second range'));
      // Non-dialogue lines stay verbatim.
      expect(result.text,
          contains('Comment: 0,0:00:12.00,0:00:15.00,Default,,0,0,0,,a comment'));
      expect(result.text, contains('Format: Layer, Start, End, Style, Name,'
          ' MarginL, MarginR, MarginV, Effect, Text'));
    });

    test('SSA extension uses the same pipeline', () {
      final result = remap(cut, 'a.ssa', ass);
      expect(result.emittedCues, 2);
    });

    test('a Dialogue whose time cannot be parsed is dropped, not source-timed',
        () {
      const mixed = '''[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:xx.00,0:00:15.00,Default,,0,0,0,,unparsable time
Dialogue: 0,0:00:52.00,0:00:54.00,Default,,0,0,0,,second range
''';
      final result = remap(cut, 'bad.ass', mixed);
      expect(result.text, isNot(contains('unparsable time')));
      expect(result.text,
          contains('Dialogue: 0,0:00:12.00,0:00:14.00,Default,,0,0,0,,'
              'second range'));
      expect(result.emittedCues, 1);
      expect(result.droppedCues, 1);
    });

    test('an out-of-range ASS hour field is dropped, never thrown', () {
      final String huge = '9' * 20;
      final result = remap(cut, 'huge.ass', '[Events]\n'
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, '
          'MarginV, Effect, Text\n'
          'Dialogue: 0,$huge:00:52.00,0:00:54.00,Default,,0,0,0,,huge hour\n'
          'Dialogue: 0,0:00:52.00,0:00:54.00,Default,,0,0,0,,second range\n');
      expect(result.text, isNot(contains('huge hour')));
      expect(result.emittedCues, 1);
      expect(result.droppedCues, 1);
    });
  });

  group('decodeSubtitleBytes', () {
    test('UTF-8 with and without BOM', () {
      expect(FakeCutSubtitleRemapper.decodeSubtitleBytes(utf8.encode('中文')),
          '中文');
      expect(
          FakeCutSubtitleRemapper.decodeSubtitleBytes(
              <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('中文')]),
          '中文');
    });

    test('UTF-16 LE BOM', () {
      final bytes = utf16.encode('中文');
      expect(FakeCutSubtitleRemapper.decodeSubtitleBytes(bytes), '中文');
    });

    test('GBK', () {
      final bytes = gbk.encode('简体中文字幕');
      expect(FakeCutSubtitleRemapper.decodeSubtitleBytes(bytes), '简体中文字幕');
    });

    test('a BOM payload that does not decode never throws', () {
      // The BOM branches used to sit OUTSIDE the try: a file whose BOM declared
      // UTF-8 but held other bytes threw FormatException straight through
      // `remap()` instead of reporting `decodeFailed`.
      expect(
        FakeCutSubtitleRemapper.decodeSubtitleBytes(
            <int>[0xEF, 0xBB, 0xBF, 0xFF, 0xFE, 0xFD]),
        isNull,
      );
      // Every other byte soup must stay TOTAL: the caller only understands
      // "text or null", so a malformed BOM payload may not escape as a throw.
      for (final List<int> bytes in <List<int>>[
        <int>[0xFF, 0xFE, 0x41],
        <int>[0xFE, 0xFF, 0x00],
        <int>[0xFF, 0xFE, 0x00, 0xD8],
        <int>[0xEF, 0xBB, 0xBF],
      ]) {
        expect(
          () => FakeCutSubtitleRemapper.decodeSubtitleBytes(bytes),
          returnsNormally,
          reason: 'bytes=$bytes',
        );
      }
    });
  });

  group('supportsPath', () {
    test('lists exactly the re-timed formats', () {
      expect(FakeCutSubtitleRemapper.supportsPath('/a/b.SRT'), isTrue);
      expect(FakeCutSubtitleRemapper.supportsPath('/a/b.vtt'), isTrue);
      expect(FakeCutSubtitleRemapper.supportsPath('/a/b.ass'), isTrue);
      expect(FakeCutSubtitleRemapper.supportsPath('/a/b.ssa'), isTrue);
      expect(FakeCutSubtitleRemapper.supportsPath('/a/b.sub'), isFalse);
      expect(FakeCutSubtitleRemapper.supportsPath('/a/b.idx'), isFalse);
    });

    test('an unsupported format has no text remap', () {
      expect(FakeCutSubtitleRemapper.remapText(
          plan: cut, path: 'a.sub', text: 'x'), isNull);
    });
  });
}
