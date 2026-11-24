import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_resume.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';

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
  group('resolveFakeCutResume', () {
    test('no / non-positive progress starts at the beginning', () {
      final p = plan(<List<int>>[<int>[10000, 20000]]);
      expect(resolveFakeCutResume(p, null).kind, FakeCutResumeKind.none);
      expect(resolveFakeCutResume(p, 0).kind, FakeCutResumeKind.none);
      expect(resolveFakeCutResume(p, -5).kind, FakeCutResumeKind.none);
    });

    test('one containing range maps directly', () {
      final p = plan(<List<int>>[
        <int>[10000, 20000],
        <int>[50000, 60000],
      ]);
      final resume = resolveFakeCutResume(p, 12000);
      expect(resume.kind, FakeCutResumeKind.exact);
      expect(resume.fakeMs, 2000);
      expect(resume.needsChoice, isFalse);
    });

    test('several containing ranges ask for a sync point', () {
      final p = plan(<List<int>>[
        <int>[10000, 20000],
        <int>[60000, 70000],
        <int>[15000, 25000],
      ]);
      final resume = resolveFakeCutResume(p, 16000);
      expect(resume.kind, FakeCutResumeKind.ambiguous);
      expect(resume.needsChoice, isTrue);
      expect(resume.candidates.map((c) => c.fakeMs), <int>[6000, 21000]);
    });

    test('a removed gap resumes at the next kept range', () {
      final p = plan(<List<int>>[
        <int>[10000, 20000],
        <int>[50000, 60000],
      ]);
      final resume = resolveFakeCutResume(p, 30000);
      expect(resume.kind, FakeCutResumeKind.gapNext);
      expect(resume.fakeMs, 10000);
    });

    test('past every range is treated as watched', () {
      final p = plan(<List<int>>[<int>[10000, 20000]]);
      expect(resolveFakeCutResume(p, 25000).kind, FakeCutResumeKind.afterEnd);
    });

    test('an empty plan never resumes', () {
      final p = plan(<List<int>>[]);
      expect(resolveFakeCutResume(p, 5000).kind, FakeCutResumeKind.none);
    });
  });

  group('decideFakeCutResume', () {
    test('auto-resolve takes the FIRST hit of an ambiguous resume', () {
      // A merged segment auto-advance must never block on a dialog (ADR 0037):
      // the first hit in plan order is the deterministic landing.
      final p = plan(<List<int>>[
        <int>[10000, 20000],
        <int>[60000, 70000],
        <int>[15000, 25000],
      ]);
      final resume = resolveFakeCutResume(p, 16000);
      final decision = decideFakeCutResume(resume, autoResolve: true);
      expect(decision.needsChoice, isFalse);
      expect(decision.fakeMs, 6000);
    });

    test('without auto-resolve an ambiguous resume still asks', () {
      final p = plan(<List<int>>[
        <int>[10000, 20000],
        <int>[15000, 25000],
      ]);
      final resume = resolveFakeCutResume(p, 16000);
      final decision = decideFakeCutResume(resume);
      expect(decision.needsChoice, isTrue);
      expect(decision.fakeMs, isNull);
    });

    test('exact, gap and head decisions need no dialog either way', () {
      final p = plan(<List<int>>[
        <int>[10000, 20000],
        <int>[50000, 60000],
      ]);
      for (final bool auto in <bool>[false, true]) {
        final exact = decideFakeCutResume(
            resolveFakeCutResume(p, 12000), autoResolve: auto);
        expect(exact.fakeMs, 2000);
        expect(exact.needsChoice, isFalse);

        final gap = decideFakeCutResume(
            resolveFakeCutResume(p, 30000), autoResolve: auto);
        expect(gap.fakeMs, 10000);
        expect(gap.needsChoice, isFalse);

        final head = decideFakeCutResume(
            resolveFakeCutResume(p, null), autoResolve: auto);
        expect(head.fakeMs, isNull);
        expect(head.needsChoice, isFalse);

        final end = decideFakeCutResume(
            resolveFakeCutResume(p, 70000), autoResolve: auto);
        expect(end.fakeMs, isNull);
        expect(end.needsChoice, isFalse);
      }
    });
  });
}
