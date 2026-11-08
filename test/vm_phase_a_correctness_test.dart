import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/resolver/vm_overlay.dart';
import 'package:iris/features/virtual_media/resolver/vm_preflight.dart';
import 'package:iris/features/virtual_media/resolver/vm_resolver.dart';
import 'package:iris/features/virtual_media/resolver/vm_resume_target.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:iris/utils/natural_sort_key.dart';
import 'package:iris/features/virtual_media/scan/vm_scan_facade.dart';

VirtualSegment seg(String name, {int? durationMs, String parent = 'd'}) {
  return VirtualSegment(
    mediaKey: 's:$parent/$name',
    storageId: 's',
    path: [parent, name],
    name: name,
    parentPath: parent,
    durationMs: durationMs,
  );
}

VirtualMediaItem itemOf(String scope, List<VirtualSegment> segs) {
  return VirtualMediaItem(
    ruleId: 'r',
    scopeKey: scope,
    rootPath: 'd',
    displayIndex: 1,
    displayName: scope,
    segments: segs,
  );
}

EffectivePlaybackItem streamItem(String path, {int? durationMs = 60000}) {
  final parts = path.split('/');
  final f = MediaNode.file(
    id: 'st1:$path',
    storageId: 'st1',
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
    available: true,
    virtualIndex: 0,
    occurrenceId: PlaybackOccurrenceId(storageId: 'st1', path: path),
  );
}

void main() {
  group('Phase A correctness', () {
    test('offsetOf out-of-range index returns 0 (no total leak)', () {
      final item = itemOf('s', [seg('a.mp4', durationMs: 1000)]);
      // segments.length == 1, prefixMs.length == 2; index == 1 is out of range.
      expect(item.offsetOf(1), 0);
      expect(item.offsetOf(-1), 0);
    });

    test('stream path applies hard ceilings when caps unchecked', () {
      final stream = [
        for (var i = 0; i < 105; i++)
          streamItem('Shorts/${i.toString().padLeft(3, '0')}.mp4'),
      ];
      final r = VirtualMediaRule(
        id: 'r1',
        name: 'R',
        matchMode: VmMatchMode.specifiedDirRecursive,
        paths: const ['Shorts'],
        boundary: VmBoundaryMode.ignoreDirs,
        useDurationCap: false,
        useCountCap: false,
      );
      final groups = resolveGroupsForStream(stream, [r]);
      // Hard ceiling 100/group: 105 segments must split, never one mega-chunk.
      expect(groups.inOrder.length, greaterThan(1));
      for (final g in groups.inOrder) {
        expect(g.segments.length, lessThanOrEqualTo(kVmHardMaxItemCount));
      }
    });

    test('crossDirMerge keeps global sort order (not dir-bucketed)', () {
      VirtualSegment dseg(String parent, String name, int dur) =>
          VirtualSegment(
            mediaKey: 's:$parent/$name',
            storageId: 's',
            path: [parent, name],
            name: name,
            parentPath: parent,
            durationMs: dur,
          );
      final lib = [
        dseg('b', 'a.mp4', 3000),
        dseg('a', 'b.mp4', 1000),
        dseg('b', 'c.mp4', 2000),
      ];
      final r = VirtualMediaRule(
        id: 'r1',
        name: 'R',
        matchMode: VmMatchMode.specifiedDirRecursive,
        paths: const ['a', 'b'],
        sortField: VmSortField.duration,
        sortDir: SortDirection.asc,
        boundary: VmBoundaryMode.crossDirMerge,
        useDurationCap: false,
        useCountCap: false,
      );
      final items = resolveVirtualMedia(rules: [r], library: lib);
      expect(items, hasLength(1));
      expect(
        [for (final s in items.first.segments) s.durationMs],
        [1000, 2000, 3000],
      );
    });

    test('preflight names bad members on bad rows (not on good rows)', () {
      final bad = seg('bad.mp4');
      final good = seg('good.mp4', durationMs: 1000);
      final p = partitionVmItems([itemOf('s', [good, bad])]);
      expect(p.valid, isEmpty);
      final goodInfo = p.failByKey[good.mediaKey]!;
      final badInfo = p.failByKey[bad.mediaKey]!;
      expect(goodInfo.badNames, contains('bad.mp4'));
      expect(badInfo.badNames, contains('bad.mp4'));
    });

    test('empty group is tracked as failed (count parity)', () {
      final p = partitionVmItems([itemOf('empty', const [])]);
      expect(p.valid, isEmpty);
      expect(p.failed, hasLength(1));
    });

    test('short file resume does not jump to head', () {
      final item = VirtualMediaItem(
        ruleId: 'r',
        scopeKey: 's',
        rootPath: 'd',
        displayIndex: 1,
        displayName: 's',
        segments: [
          VirtualSegment(
            mediaKey: 's:u.mp4',
            storageId: 's',
            path: const ['u.mp4'],
            name: 'u.mp4',
            parentPath: '',
            durationMs: 3000,
          ),
        ],
      );
      final t = DateTime(2026, 1, 1);
      final (idx, local) = resolveVmResumeByProgress(item, {
        's:u.mp4': (positionMs: 2000, completed: false, lastPlayedAt: t),
      });
      // duration 3000, position 2000: old code clamped 3000-5000 to 0.
      expect((idx, local), (0, 2000));
    });

    test('overlay tolerates stale byKey entries', () {
      final stream = [
        EffectivePlaybackItem(
          media: MediaNode.file(
            id: 'st1:a/1.mp4',
            storageId: 'st1',
            path: const ['a', '1.mp4'],
            parentPath: 'a',
            name: '1.mp4',
            mediaType: MediaType.video,
            durationMs: 1000,
          ),
          scenarioId: 's1',
          available: true,
          virtualIndex: 0,
          occurrenceId:
              const PlaybackOccurrenceId(storageId: 'st1', path: 'a/1.mp4'),
        ),
      ];
      // Stale key not present in stream: must not throw, stream passes through.
      final merged = applyVmOverlay(stream, const {});
      expect(merged, hasLength(1));
    });

    test('applyDbDurations keeps stream duration when DB row missing', () {
      final segs = [seg('a.mp4', durationMs: 1234)];
      final out = applyDbDurationsToSegments(segs, {'s:d/a.mp4': null});
      expect(out.first.durationMs, 1234);
    });

    test('natural compare orders 2 before 10 without per-char lowercasing crash',
        () {
      expect(naturalCompare('ep2.mp4', 'ep10.mp4'), lessThan(0));
      expect(naturalCompare('EP2.mp4', 'ep10.mp4'), lessThan(0));
    });
  });
}
