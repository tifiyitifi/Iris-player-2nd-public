import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/services/fake_cut_plan_builder.dart';
import 'package:iris/features/fake_cut/services/llc_parser.dart';

LlcSegment seg(int startMs, int? endMs, {bool selected = true}) => LlcSegment(
      startMs: startMs,
      endMs: endMs,
      selected: selected,
      name: '',
    );

FakeCutPlan build(
  List<LlcSegment> segments, {
  int? sourceDurationMs,
  String? mediaFileName,
  String? sourceFileName,
}) =>
    buildFakeCutPlan(
      planPath: '/videos/movie-proj.llc',
      project: LlcProject(
        version: 2,
        mediaFileName: mediaFileName,
        segments: segments,
      ),
      sourceDurationMs: sourceDurationMs,
      sourceFileName: sourceFileName,
    );

void main() {
  test('markers are excluded, order is preserved', () {
    final plan = build(<LlcSegment>[
      seg(5000, 6000),
      seg(9000, null),
      seg(1000, 2000),
    ]);
    expect(plan.segments.map((s) => s.startMs), <int>[5000, 1000]);
    expect(plan.markerCount, 1);
    expect(plan.displayName, 'movie-proj');
    expect(plan.notices.map((n) => n.kind),
        contains(FakeCutNoticeKind.markersIgnored));
  });

  test('deselected ranges are excluded', () {
    final plan = build(<LlcSegment>[
      seg(0, 1000),
      seg(2000, 3000, selected: false),
    ]);
    expect(plan.segments, hasLength(1));
    expect(plan.deselectedCount, 1);
  });

  test('all deselected falls back to every non-marker range', () {
    final plan = build(<LlcSegment>[
      seg(0, 1000, selected: false),
      seg(2000, 3000, selected: false),
    ]);
    expect(plan.segments, hasLength(2));
    expect(plan.usedSelectedFallback, isTrue);
    expect(plan.notices.map((n) => n.kind),
        contains(FakeCutNoticeKind.selectedFallback));
  });

  test('overlap / repeat / out-of-order are kept verbatim', () {
    final plan = build(<LlcSegment>[
      seg(60000, 70000),
      seg(10000, 20000),
      seg(60000, 70000),
      seg(15000, 65000),
    ]);
    expect(plan.segments.map((s) => s.startMs),
        <int>[60000, 10000, 60000, 15000]);
    expect(plan.totalMs, 10000 + 10000 + 10000 + 50000);
  });

  test('end past the source duration is clamped and flagged', () {
    final plan = build(
      <LlcSegment>[seg(1000, 9000)],
      sourceDurationMs: 5000,
    );
    expect(plan.segments.single.endMs, 5000);
    expect(plan.clampedCount, 1);
  });

  test('range starting past the source is dropped', () {
    final plan = build(
      <LlcSegment>[seg(8000, 9000), seg(0, 1000)],
      sourceDurationMs: 5000,
    );
    expect(plan.segments, hasLength(1));
    expect(plan.invalidCount, 1);
  });

  test('end <= start is dropped', () {
    final plan = build(<LlcSegment>[seg(5000, 5000), seg(0, 4000)]);
    expect(plan.segments, hasLength(1));
    expect(plan.invalidCount, 1);
  });

  test('a sub-200ms range is kept but flagged', () {
    final plan = build(<LlcSegment>[seg(1000, 1100)]);
    expect(plan.segments, hasLength(1));
    expect(plan.tooShortCount, 1);
  });

  test('mediaFileName mismatch is a notice', () {
    final plan = build(
      <LlcSegment>[seg(0, 1000)],
      mediaFileName: 'other.mp4',
      sourceFileName: 'movie.mp4',
    );
    final notice = plan.notices
        .firstWhere((n) => n.kind == FakeCutNoticeKind.fileMismatch);
    expect(notice.detail, 'other.mp4');
  });

  test('matching mediaFileName produces no mismatch notice', () {
    final plan = build(
      <LlcSegment>[seg(0, 1000)],
      mediaFileName: 'movie.mp4',
      sourceFileName: 'movie.mp4',
    );
    expect(plan.notices.map((n) => n.kind),
        isNot(contains(FakeCutNoticeKind.fileMismatch)));
  });

  test('no playable range yields an empty plan', () {
    final plan = build(<LlcSegment>[seg(9000, null)]);
    expect(plan.isEmpty, isTrue);
    expect(plan.totalMs, 0);
  });
}
