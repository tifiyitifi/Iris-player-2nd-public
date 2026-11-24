import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';
import 'package:iris/features/fake_cut/services/fake_cut_discovery.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_queue_builder.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/resolver/vm_fake_cut_exclusions.dart';
import 'package:iris/features/virtual_media/resolver/vm_resume_target.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:path/path.dart' as p;

/// 虚拟剪播 ↔ Virtual Merge coexistence (ADR 0032): a merge follows the ACTIVE
/// cut. No active plan → the source segment; an active single-range plan → the
/// cut; an active multi-range/unusable plan → the file stays single; no-EDL
/// backends merge the source. All filesystem answers are injected.

EffectivePlaybackItem streamItem(
  String path, {
  String storage = 'st1',
  int? durationMs = 60000,
}) {
  final parts = path.split('/');
  final f = MediaNode.file(
    id: '$storage:$path',
    storageId: storage,
    path: parts,
    parentPath:
        parts.length <= 1 ? null : parts.sublist(0, parts.length - 1).join('/'),
    name: parts.last,
    mediaType: MediaType.video,
    durationMs: durationMs,
  );
  return EffectivePlaybackItem(
    media: f,
    scenarioId: 's1',
    virtualIndex: 0,
    occurrenceId: PlaybackOccurrenceId(storageId: storage, path: path),
  );
}

VirtualMediaRule dirRule() => VirtualMediaRule(
      id: 'r1',
      name: 'rule',
      matchMode: VmMatchMode.specifiedDir,
      paths: const <String>['Shorts'],
      patterns: const <VmPatternEntry>[],
      sortField: VmSortField.fileName,
      sortDir: SortDirection.asc,
      boundary: VmBoundaryMode.sameDirOnly,
      maxDurationMinutes: 90,
      maxItemCount: 32,
      titleTags: const <VmTitleTag>[VmTitleTag.seq],
      useExcludeOverlong: false,
      skipSingleSegment: false,
      enabled: true,
    );

FakeCutPlan cutPlan(String path, List<(int, int)> ranges) => FakeCutPlan(
      planPath: path,
      displayName: 'plan',
      version: 1,
      segments: <FakeCutSegment>[
        for (var i = 0; i < ranges.length; i++)
          FakeCutSegment(
            index: i,
            startMs: ranges[i].$1,
            endMs: ranges[i].$2,
          ),
      ],
    );

FakeCutPlanSource planSource(
  String path,
  List<(int, int)> ranges, {
  bool bound = true,
}) =>
    FakeCutPlanSource(
      path: path,
      size: 1000,
      modifiedMs: 1,
      plan: cutPlan(path, ranges),
      bound: bound,
    );

String cutKey(String path) => 'st1:$path';

VmCutRange range(String planPath, int start, int dur) => VmCutRange.single(
    planPath: planPath, sourceStartMs: start, durationMs: dur);

void main() {
  test('a cut range maps the two axes both ways', () {
    final VmCutRange r = range('a.llc', 10000, 30000);
    expect(r.toSourceMs(0), 10000);
    expect(r.toSourceMs(15000), 25000);
    expect(r.toCutMs(25000), 15000);
    expect(r.toCutMs(9000), isNull);
    expect(r.toCutMs(40000), isNull);
  });

  test('a multi-range cut maps the concatenated cut timeline', () {
    const VmCutRange r = VmCutRange(
      planPath: 'a.llc',
      keeps: <VmCutKeep>[
        VmCutKeep(sourceStartMs: 10000, durationMs: 5000),
        VmCutKeep(sourceStartMs: 30000, durationMs: 2000),
      ],
    );
    expect(r.durationMs, 7000);
    expect(r.toSourceMs(0), 10000);
    expect(r.toSourceMs(4999), 14999);
    // The second kept range starts at cut 5000, not source 15000.
    expect(r.toSourceMs(5000), 30000);
    expect(r.toSourceMs(6999), 31999);
    // Tail clamp, like the standalone timeline.
    expect(r.toSourceMs(7000), 32000);
    expect(r.toCutMs(14000), 4000);
    expect(r.toCutMs(30000), 5000);
    // A removed gap has no cut position.
    expect(r.toCutMs(20000), isNull);
  });

  test('a repeated range resumes from its FIRST hit', () {
    const VmCutRange r = VmCutRange(
      planPath: 'a.llc',
      keeps: <VmCutKeep>[
        VmCutKeep(sourceStartMs: 0, durationMs: 1000),
        VmCutKeep(sourceStartMs: 0, durationMs: 1000),
      ],
    );
    expect(r.durationMs, 2000);
    expect(r.toCutMs(500), 500, reason: 'the earliest hit wins');
    expect(r.toSourceMs(1500), 500);
  });

  group('resolveGroupsForStream with a cut range', () {
    test('a single-range cut joins the group and carries its own length', () {
      final List<EffectivePlaybackItem> stream = <EffectivePlaybackItem>[
        streamItem('Shorts/1.mp4'),
        streamItem('Shorts/2.mp4'),
        streamItem('Shorts/3.mp4'),
      ];
      final VmStreamGroups groups = resolveGroupsForStream(
        stream,
        <VirtualMediaRule>[dirRule()],
        cutRanges: <String, VmCutRange>{
          cutKey('Shorts/2.mp4'): range('2.llc', 10000, 30000),
        },
      );
      expect(groups.inOrder, hasLength(1));
      final VirtualMediaItem item = groups.inOrder.single;
      expect(item.segments, hasLength(3));
      final VirtualSegment cut = item.segments[1];
      expect(cut.durationMs, 30000);
      expect(cut.cutRange, isNotNull);
      expect(cut.cutRange!.planPath, '2.llc');
      expect(cut.cutRange!.sourceStartMs, 10000);
      // 60s + 30s cut + 60s, not the source's 60s for the cut member.
      expect(item.totalDurationMs, 150000);
    });

    test('a multi-range cut sets the group total to the cut timeline', () {
      const VmCutRange multi = VmCutRange(
        planPath: '2.llc',
        keeps: <VmCutKeep>[
          VmCutKeep(sourceStartMs: 10000, durationMs: 30000),
          VmCutKeep(sourceStartMs: 50000, durationMs: 20000),
        ],
      );
      final VmStreamGroups groups = resolveGroupsForStream(
        <EffectivePlaybackItem>[
          streamItem('Shorts/1.mp4'),
          streamItem('Shorts/2.mp4'),
          streamItem('Shorts/3.mp4'),
        ],
        <VirtualMediaRule>[dirRule()],
        cutRanges: <String, VmCutRange>{cutKey('Shorts/2.mp4'): multi},
      );
      final VirtualMediaItem item = groups.inOrder.single;
      expect(item.segments[1].durationMs, 50000);
      expect(item.totalDurationMs, 170000);
      // The merged local offset walks the concatenated cut timeline.
      expect(item.segments[1].cutRange!.toSourceMs(35000), 55000);
    });
  });

  test('the persisted queue row carries the cut-length total', () {
    final ScenarioQueuePlan plan = ScenarioQueueBuilder.build(
      stream: <EffectivePlaybackItem>[
        streamItem('Shorts/1.mp4'),
        streamItem('Shorts/2.mp4'),
      ],
      rules: <VirtualMediaRule>[dirRule()],
      mediaNodeIdOf: (rank, item) => rank,
      cutRanges: <String, VmCutRange>{
        cutKey('Shorts/2.mp4'): range('2.llc', 10000, 30000),
      },
    );
    expect(plan.groups, hasLength(1));
    // 60s source + 30s kept range, not 120s.
    expect(plan.groups.single.totalDurationMs, 90000);
  });

  group('vmCutRangeFromSources', () {
    test('the ACTIVE single-range plan yields its range', () {
      final VmCutRange? r = vmCutRangeFromSources(
        <FakeCutPlanSource>[planSource('a.llc', <(int, int)>[(100, 400)])],
        preferredPath: 'a.llc',
      );
      expect(r, range('a.llc', 100, 300));
    });

    test('no active plan yields no range (the source merges)', () {
      final VmCutRange? r = vmCutRangeFromSources(
        <FakeCutPlanSource>[planSource('a.llc', <(int, int)>[(100, 400)])],
      );
      expect(r, isNull);
    });

    test('an active multi-range plan yields all of its ranges', () {
      final VmCutRange? r = vmCutRangeFromSources(
        <FakeCutPlanSource>[
          planSource('a.llc', <(int, int)>[(0, 100), (200, 300)]),
        ],
        preferredPath: 'a.llc',
      );
      expect(r, isNotNull);
      expect(r!.keeps, hasLength(2));
      expect(r.durationMs, 200);
      expect(r.toSourceMs(150), 250);
    });

    test('the active plan wins over another bound plan', () {
      final VmCutRange? r = vmCutRangeFromSources(
        <FakeCutPlanSource>[
          planSource('a.llc', <(int, int)>[(0, 1000)]),
          planSource('b.llc', <(int, int)>[(5000, 6000)]),
        ],
        preferredPath: 'b.llc',
      );
      expect(r, range('b.llc', 5000, 1000));
    });

    test('an inactive bound plan is never used as a fallback', () {
      final VmCutRange? r = vmCutRangeFromSources(
        <FakeCutPlanSource>[
          planSource('a.llc', <(int, int)>[(0, 1000)]),
          planSource('b.llc', <(int, int)>[(5000, 6000)]),
        ],
        preferredPath: 'c.llc',
      );
      expect(r, isNull);
    });

    test('an unmatched project never joins', () {
      final VmCutRange? r = vmCutRangeFromSources(
        <FakeCutPlanSource>[
          planSource('a.llc', <(int, int)>[(0, 1000)], bound: false),
        ],
        preferredPath: 'a.llc',
      );
      expect(r, isNull);
    });

    test('an active plan matches across path spellings', () {
      // The active path arrives through the player (forward slashes, the media
      // row's case); the scanned path comes from the directory listing. Windows
      // treats separator and case as noise, so the merge must too — an exact
      // compare silently ignored the activated cut.
      final String planPath = p.join('plans', 'a.llc');
      final String preferred = Platform.isWindows
          ? planPath.replaceAll('\\', '/').toUpperCase()
          : planPath;
      final VmCutRange? r = vmCutRangeFromSources(
        <FakeCutPlanSource>[planSource(planPath, <(int, int)>[(100, 400)])],
        preferredPath: preferred,
      );
      expect(r, isNotNull);
      expect(r!.planPath, planPath);
    });
  });

  group('vmCutMergeInfoForStream', () {
    test('no active plan merges the source', () async {
      final VmCutMergeInfo info = await vmCutMergeInfoForStream(
        <EffectivePlaybackItem>[streamItem('Shorts/2.mp4')],
        projectKeys: (_) async => <String>{cutKey('Shorts/2.mp4')},
        scanner: (_, __) async => <FakeCutPlanSource>[
          planSource('a.llc', <(int, int)>[(0, 1000)]),
        ],
      );
      expect(info.rangesByKey, isEmpty);
    });

    test('an inactive bound plan does not participate', () async {
      final VmCutMergeInfo info = await vmCutMergeInfoForStream(
        <EffectivePlaybackItem>[streamItem('Shorts/2.mp4')],
        projectKeys: (_) async => <String>{cutKey('Shorts/2.mp4')},
        scanner: (_, __) async => <FakeCutPlanSource>[
          planSource('a.llc', <(int, int)>[(0, 1000)]),
        ],
      );
      expect(info.rangesByKey[cutKey('Shorts/2.mp4')], isNull);
    });

    test('an active multi-range plan joins with its total length', () async {
      final VmCutMergeInfo info = await vmCutMergeInfoForStream(
        <EffectivePlaybackItem>[streamItem('Shorts/2.mp4')],
        projectKeys: (_) async => <String>{cutKey('Shorts/2.mp4')},
        scanner: (_, __) async => <FakeCutPlanSource>[
          planSource('a.llc', <(int, int)>[(0, 100), (200, 300)]),
        ],
        preferredPlanPaths: <String, String>{
          cutKey('Shorts/2.mp4'): 'a.llc',
        },
      );
      final VmCutRange? r = info.rangesByKey[cutKey('Shorts/2.mp4')];
      expect(r, isNotNull, reason: 'ADR 0037 admits every range count');
      expect(r!.durationMs, 200);
      expect(r.keeps, hasLength(2));
      expect(r.keeps[1].sourceStartMs, 200);
    });

    test('an active unusable plan merges the source', () async {
      final VmCutMergeInfo info = await vmCutMergeInfoForStream(
        <EffectivePlaybackItem>[streamItem('Shorts/2.mp4')],
        projectKeys: (_) async => <String>{cutKey('Shorts/2.mp4')},
        scanner: (_, __) async => <FakeCutPlanSource>[
          FakeCutPlanSource(
            path: 'a.llc',
            size: 10,
            modifiedMs: 1,
            bound: true,
          ),
        ],
        preferredPlanPaths: <String, String>{
          cutKey('Shorts/2.mp4'): 'a.llc',
        },
      );
      expect(info.rangesByKey, isEmpty);
    });

    test('a backend without EDL merges the source', () async {
      final VmCutMergeInfo info = await vmCutMergeInfoForStream(
        <EffectivePlaybackItem>[streamItem('Shorts/2.mp4')],
        projectKeys: (_) async => <String>{cutKey('Shorts/2.mp4')},
        scanner: (_, __) async => <FakeCutPlanSource>[
          planSource('a.llc', <(int, int)>[(0, 1000)]),
        ],
        preferredPlanPaths: <String, String>{
          cutKey('Shorts/2.mp4'): 'a.llc',
        },
        enabled: false,
      );
      expect(info.rangesByKey, isEmpty);
    });

    test('an active single-range file is admitted with its cut length',
        () async {
      final VmCutMergeInfo info = await vmCutMergeInfoForStream(
        <EffectivePlaybackItem>[
          streamItem('Shorts/1.mp4'),
          streamItem('Shorts/2.mp4'),
        ],
        projectKeys: (_) async => <String>{cutKey('Shorts/2.mp4')},
        scanner: (_, __) async => <FakeCutPlanSource>[
          planSource('a.llc', <(int, int)>[(100, 400)]),
        ],
        preferredPlanPaths: <String, String>{
          cutKey('Shorts/2.mp4'): 'a.llc',
        },
      );
      expect(
        info.rangesByKey[cutKey('Shorts/2.mp4')],
        range('a.llc', 100, 300),
      );
      // The group carries the plan's CONTENT signature, so the open can notice
      // an edit on disk and re-derive the merge (ADR 0034).
      expect(
        info.rangesByKey[cutKey('Shorts/2.mp4')]!.planSignature,
        '100:400,',
      );
    });
  });

  group('resume on the cut timeline', () {
    VirtualMediaItem groupWithCut() {
      final VirtualSegment seg = VirtualSegment(
        mediaKey: cutKey('Shorts/1.mp4'),
        storageId: 'st1',
        path: const <String>['Shorts', '1.mp4'],
        name: '1.mp4',
        parentPath: 'Shorts',
        durationMs: 30000,
        cutRange: range('1.llc', 10000, 30000),
      );
      return VirtualMediaItem(
        ruleId: 'r1',
        scopeKey: 'r1|Shorts|#1',
        rootPath: 'Shorts',
        displayIndex: 1,
        displayName: 'rule:1',
        segments: <VirtualSegment>[seg],
      );
    }

    test('source progress maps onto the kept range', () {
      final (int index, int local) = resolveVmResumeByProgress(
        groupWithCut(),
        <String, SegmentProgress>{
          cutKey('Shorts/1.mp4'): (
            positionMs: 25000,
            completed: false,
            lastPlayedAt: DateTime(2026, 1, 1),
          ),
        },
      );
      expect(index, 0);
      expect(local, 15000);
    });

    test('a cut-away source point resumes from the segment head', () {
      final (int index, int local) = resolveVmResumeByProgress(
        groupWithCut(),
        <String, SegmentProgress>{
          cutKey('Shorts/1.mp4'): (
            positionMs: 5000,
            completed: false,
            lastPlayedAt: DateTime(2026, 1, 1),
          ),
        },
      );
      expect(index, 0);
      expect(local, 0);
    });

    test('source progress inside the second kept range maps onto it', () {
      const VmCutRange multi = VmCutRange(
        planPath: '1.llc',
        keeps: <VmCutKeep>[
          VmCutKeep(sourceStartMs: 10000, durationMs: 30000),
          VmCutKeep(sourceStartMs: 50000, durationMs: 20000),
        ],
      );
      final VirtualSegment seg = VirtualSegment(
        mediaKey: cutKey('Shorts/1.mp4'),
        storageId: 'st1',
        path: const <String>['Shorts', '1.mp4'],
        name: '1.mp4',
        parentPath: 'Shorts',
        durationMs: 50000,
        cutRange: multi,
      );
      final VirtualMediaItem item = VirtualMediaItem(
        ruleId: 'r1',
        scopeKey: 'r1|Shorts|#1',
        rootPath: 'Shorts',
        displayIndex: 1,
        displayName: 'rule:1',
        segments: <VirtualSegment>[seg],
      );
      final (int index, int local) = resolveVmResumeByProgress(
        item,
        <String, SegmentProgress>{
          cutKey('Shorts/1.mp4'): (
            positionMs: 55000,
            completed: false,
            lastPlayedAt: DateTime(2026, 1, 1),
          ),
        },
      );
      expect(index, 0);
      // 30s of the first keep + 5s into the second.
      expect(local, 35000);
    });
  });
}
