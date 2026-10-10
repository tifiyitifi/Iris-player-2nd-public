import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:iris/features/virtual_media/service/vm_membership_pin.dart';

VirtualMediaRule _rule() => VirtualMediaRule(
      id: 'r1',
      name: 'R',
      matchMode: VmMatchMode.specifiedDirRecursive,
      paths: const ['d'],
      boundary: VmBoundaryMode.ignoreDirs,
      sortField: VmSortField.fileName,
      sortDir: SortDirection.asc,
      useDurationCap: false,
      useCountCap: true,
      maxItemCount: 2,
      useExcludeOverlong: false,
      skipSingleSegment: false,
    );

EffectivePlaybackItem _streamItem(String name, {int? durationMs}) {
  final path = 'd/$name';
  final parts = path.split('/');
  final f = MediaNode.file(
    id: 's:$path',
    storageId: 's',
    path: parts,
    parentPath: 'd',
    name: name,
    mediaType: MediaType.video,
    durationMs: durationMs,
  );
  return EffectivePlaybackItem(
    media: f,
    scenarioId: 's1',
    available: true,
    virtualIndex: 0,
    occurrenceId: PlaybackOccurrenceId(storageId: 's', path: path),
  );
}

void main() {
  final pin = VmMembershipPin.instance;
  setUp(pin.clear);
  tearDown(pin.clear);

  test('capture keeps infeasible groups so the yellow mark survives a pin',
      () {
    final rule = _rule();
    final stream = [
      _streamItem('f1.mp4', durationMs: 60000),
      _streamItem('f2.mp4', durationMs: 60000),
      _streamItem('f3.mp4', durationMs: 60000),
      _streamItem('f4.mp4', durationMs: null),
    ];
    final groups = resolveGroupsForStream(stream, [rule]);

    // Precondition: one feasible chunk {f1,f2} + one degraded chunk {f3,f4}.
    expect(groups.inOrder, hasLength(1));
    expect(groups.failedGroups, hasLength(1));
    expect(groups.failByKey.keys,
        containsAll(['s:d/f3.mp4', 's:d/f4.mp4']));

    // The delete-time capture must retain BOTH, keyed by rule.
    final captured = collectPinnedVmChunks(groups, {'r1'});
    final chunks = captured['r1']!;
    expect(chunks.map((c) => c.scopeKey),
        containsAll([groups.inOrder.single.scopeKey, groups.failedGroups.single.scopeKey]));
    expect(chunks, hasLength(2));

    // Seed the pin the way the delete path does, excise f1, and re-resolve
    // the shrunken stream: the degraded chunk must still degrade.
    pin.seedRule('r1', chunks);
    pin.removeMember('r1', 's:d/f1.mp4');
    final after = resolveGroupsForStream(
      [
        _streamItem('f2.mp4', durationMs: 60000),
        _streamItem('f3.mp4', durationMs: 60000),
        _streamItem('f4.mp4', durationMs: null),
      ],
      [rule],
    );
    expect(after.failByKey.keys,
        containsAll(['s:d/f3.mp4', 's:d/f4.mp4']));
    expect(after.failedGroups, hasLength(1));
  });
}
