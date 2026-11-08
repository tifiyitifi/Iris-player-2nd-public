import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';
import 'package:iris/features/fake_cut/services/fake_cut_edl_builder.dart';

FakeCutPlan plan(List<List<int>> ranges) => FakeCutPlan(
      planPath: '/videos/proj.llc',
      displayName: 'proj',
      version: 2,
      segments: <FakeCutSegment>[
        for (int i = 0; i < ranges.length; i++)
          FakeCutSegment(index: i, startMs: ranges[i][0], endMs: ranges[i][1]),
      ],
    );

void main() {
  group('buildFakeCutEdlText', () {
    test('header, no_chapters, one part per segment', () {
      final text = buildFakeCutEdlText(
        plan: plan(<List<int>>[
          <int>[8033, 44979],
          <int>[60359, 83433],
        ]),
        sourcePath: r'E:\vault\br\cut and merge\movie.mp4',
      );
      final lines = text.split('\n');
      expect(lines[0], '# mpv EDL v0');
      expect(lines[1], '!no_chapters');
      expect(lines[2], '%35%E:/vault/br/cut and merge/movie.mp4,'
          'start=8.033,length=36.946');
      expect(lines[3], '%35%E:/vault/br/cut and merge/movie.mp4,'
          'start=60.359,length=23.074');
      expect(text.endsWith('\n'), isTrue);
    });

    test('an identical source reference is emitted for every part', () {
      final text = buildFakeCutEdlText(
        plan: plan(<List<int>>[
          <int>[0, 1000],
          <int>[5000, 6000],
          <int>[0, 1000],
        ]),
        sourcePath: '/media/a.mp4',
      );
      final refs = text
          .split('\n')
          .skip(2)
          .where((l) => l.isNotEmpty)
          .map((l) => l.split(',').first)
          .toSet();
      expect(refs, hasLength(1));
    });

    test('%N% counts UTF-8 BYTES, not characters', () {
      final text = buildFakeCutEdlText(
        plan: plan(<List<int>>[<int>[0, 1000]]),
        sourcePath: '/media/与室友.mp4',
      );
      final payload = '/media/与室友.mp4';
      final bytes = utf8.encode(payload).length;
      expect(text, contains('%$bytes%$payload,start=0.000,length=1.000'));
      expect(bytes, greaterThan(payload.length));
    });

    test('commas and percent signs in the path stay inside the payload', () {
      final text = buildFakeCutEdlText(
        plan: plan(<List<int>>[<int>[0, 1000]]),
        sourcePath: r'/media/a,b;c%d.mp4',
      );
      expect(text, contains('%18%/media/a,b;c%d.mp4,start='));
    });
  });

  group('fakeCutCacheKey', () {
    test('is stable and content-dependent', () {
      expect(fakeCutCacheKey('a'), fakeCutCacheKey('a'));
      expect(fakeCutCacheKey('a'), isNot(fakeCutCacheKey('b')));
      expect(fakeCutCacheKey('a'), hasLength(16));
    });
  });
}
