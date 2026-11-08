import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_timeline.dart';

FakeCutTimeline timeline(List<List<int>> ranges) => FakeCutTimeline(<FakeCutSegment>[
      for (int i = 0; i < ranges.length; i++)
        FakeCutSegment(index: i, startMs: ranges[i][0], endMs: ranges[i][1]),
    ]);

void main() {
  group('FakeCutTimeline', () {
    test('prefix sums in plan order (out of source order)', () {
      final t = timeline(<List<int>>[
        <int>[60000, 70000],
        <int>[10000, 20000],
        <int>[60000, 65000],
      ]);
      expect(t.totalMs, 10000 + 10000 + 5000);
      expect(t.fakeStartOf(0), 0);
      expect(t.fakeStartOf(1), 10000);
      expect(t.fakeStartOf(2), 20000);
      expect(t.sourceSpanEndMs, 70000);
    });

    test('locate clamps both ends', () {
      final t = timeline(<List<int>>[
        <int>[10000, 20000],
        <int>[50000, 60000],
      ]);
      expect(t.locate(-500), (0, 0));
      expect(t.locate(0), (0, 0));
      expect(t.locate(9999), (0, 9999));
      expect(t.locate(10000), (1, 0));
      expect(t.locate(10001), (1, 1));
      expect(t.locate(20000), (1, 10000));
      expect(t.locate(999999), (1, 10000));
    });

    test('virtual → source follows the segment', () {
      final t = timeline(<List<int>>[
        <int>[60000, 70000],
        <int>[10000, 20000],
      ]);
      expect(t.toSourceMs(0), 60000);
      expect(t.toSourceMs(5000), 65000);
      expect(t.toSourceMs(10000), 10000);
      expect(t.toSourceMs(12000), 12000);
    });

    test('empty timeline is inert', () {
      final t = FakeCutTimeline(const <FakeCutSegment>[]);
      expect(t.isEmpty, isTrue);
      expect(t.totalMs, 0);
      expect(t.toSourceMs(1000), 0);
      expect(t.locate(1000), (0, 0));
    });
  });

  group('sourceHits', () {
    test('a source point inside one range yields one hit', () {
      final t = timeline(<List<int>>[
        <int>[10000, 20000],
        <int>[50000, 60000],
      ]);
      final hits = t.sourceHits(15000);
      expect(hits, hasLength(1));
      expect(hits.single.segmentIndex, 0);
      expect(hits.single.fakeMs, 5000);
    });

    test('overlapping / repeated ranges yield several hits in plan order', () {
      final t = timeline(<List<int>>[
        <int>[10000, 20000],
        <int>[60000, 70000],
        <int>[15000, 25000],
        <int>[10000, 20000],
      ]);
      final hits = t.sourceHits(16000);
      expect(hits.map((h) => h.segmentIndex), <int>[0, 2, 3]);
      expect(hits.map((h) => h.fakeMs), <int>[6000, 21000, 36000]);
    });

    test('a contiguous boundary belongs to the later range only', () {
      final t = timeline(<List<int>>[
        <int>[10000, 20000],
        <int>[20000, 30000],
      ]);
      final hits = t.sourceHits(20000);
      expect(hits, hasLength(1));
      expect(hits.single.segmentIndex, 1);
      expect(hits.single.fakeMs, 10000);
    });

    test('a removed gap has no hit', () {
      final t = timeline(<List<int>>[
        <int>[10000, 20000],
        <int>[50000, 60000],
      ]);
      expect(t.sourceHits(30000), isEmpty);
    });

    test('next range start after a gap follows playback order', () {
      final outOfOrder = timeline(<List<int>>[
        <int>[60000, 70000],
        <int>[10000, 20000],
      ]);
      // Playback starts with 60s, so that is the "next" range.
      expect(outOfOrder.nextFakeStartAfterSource(30000), 0);
      expect(outOfOrder.nextFakeStartAfterSource(80000), isNull);
      expect(outOfOrder.nextFakeStartAfterSource(0), 0);

      final ascending = timeline(<List<int>>[
        <int>[10000, 20000],
        <int>[50000, 60000],
      ]);
      expect(ascending.nextFakeStartAfterSource(30000), 10000);
    });
  });
}
