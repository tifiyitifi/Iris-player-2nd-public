import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/playback/vm_session_launcher.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';

VirtualSegment seg(String name, {int? durationMs}) => VirtualSegment(
      mediaKey: 's:d/$name',
      storageId: 's',
      path: ['d', name],
      name: name,
      parentPath: 'd',
      durationMs: durationMs,
    );

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
  group('Phase B perf (same function)', () {
    test('VirtualSegment/Item value equality dedups identical snapshots', () {
      final a = seg('a.mp4', durationMs: 1000);
      final b = seg('a.mp4', durationMs: 1000);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      VirtualMediaItem item(List<VirtualSegment> segs) => VirtualMediaItem(
            ruleId: 'r',
            scopeKey: 's',
            rootPath: 'd',
            displayIndex: 1,
            displayName: 's',
            segments: segs,
          );
      expect(item([a]), item([b]));
      expect(item([a]).hashCode, item([b]).hashCode);
      expect(item([a]) == item([seg('c.mp4', durationMs: 5)]), isFalse);
    });

    test('planFromGroups equals planFromStream (no double resolve)', () {
      final stream = [
        streamItem('Shorts/1.mp4'),
        streamItem('Shorts/2.mp4'),
        streamItem('Shorts/3.mp4'),
      ];
      final rule = VirtualMediaRule(
        id: 'r1',
        name: 'R',
        matchMode: VmMatchMode.specifiedDirRecursive,
        paths: const ['Shorts'],
        boundary: VmBoundaryMode.ignoreDirs,
        useDurationCap: false,
        useCountCap: true,
        maxItemCount: 10,
      );
      final groups = resolveGroupsForStream(stream, [rule]);
      final a = planVmSessionStart(
        storageId: 'st1',
        path: 'Shorts/2.mp4',
        rules: [rule],
        stream: stream,
      );
      final b = planVmSessionStartFromGroups(
        storageId: 'st1',
        path: 'Shorts/2.mp4',
        groups: groups,
      );
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(b!.queueIndex, a!.queueIndex);
      expect(b.segmentIndex, a.segmentIndex);
      expect(b.initialLocalMs, a.initialLocalMs);
      expect(
        [for (final q in b.queue) q.scopeKey],
        [for (final q in a.queue) q.scopeKey],
      );
    });

    test('namingSnapshot degrades to defaults when meta stack not ready', () async {
      final snap = await VmPrefs.namingSnapshot();
      expect(snap.prefix, 'rule');
      expect(snap.numberFormat, 'raw');
      expect(snap.counter, 0);
    });
  });
}
