import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/resolver/vm_overlay.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:iris/l10n/app_localizations_en.dart';
import 'package:iris/l10n/app_localizations_zh.dart';

EffectivePlaybackItem streamItem(
  String path, {
  String storage = 'st1',
  bool available = true,
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
    available: available,
    virtualIndex: 0,
    occurrenceId: PlaybackOccurrenceId(storageId: storage, path: path),
  );
}

VirtualMediaRule rule({
  String id = 'r1',
  VmMatchMode matchMode = VmMatchMode.specifiedDirRecursive,
  List<String> paths = const ['Shorts'],
  VmBoundaryMode boundary = VmBoundaryMode.ignoreDirs,
  VmSortField sortField = VmSortField.fileName,
  SortDirection sortDir = SortDirection.asc,
  bool useDurationCap = false,
  bool useCountCap = true,
  int maxItemCount = 2,
}) {
  return VirtualMediaRule(
    id: id,
    name: 'R',
    matchMode: matchMode,
    paths: paths,
    boundary: boundary,
    sortField: sortField,
    sortDir: sortDir,
    useDurationCap: useDurationCap,
    useCountCap: useCountCap,
    maxItemCount: maxItemCount,
    titleTags: const [VmTitleTag.seq],
    // Isolation from the per-file exclusion defaults; their own semantics
    // are covered by vm_exclusion_rules_test.
    useExcludeOverlong: false,
    skipSingleSegment: false,
  );
}

void main() {
  test('empty rules → no groups', () {
    final groups = resolveGroupsForStream(
      [streamItem('Shorts/1.mp4'), streamItem('Shorts/2.mp4')],
      const [],
    );
    expect(groups.isEmpty, isTrue);
    expect(groups.byKey, isEmpty);
    expect(groups.inOrder, isEmpty);
  });

  test('groups derive from the STREAM only, not a library snapshot', () {
    // The scenario's source covers only 3 of the directory's files; the
    // count cap is 2 → chunks are computed over the stream alone.
    final groups = resolveGroupsForStream([
      streamItem('Shorts/1.mp4'),
      streamItem('Shorts/2.mp4'),
      streamItem('Shorts/3.mp4'),
    ], [rule()]);
    expect(groups.byKey, hasLength(3));
    expect(groups.inOrder, hasLength(2));
    expect(groups.inOrder[0].segments.map((s) => s.name).toList(),
        ['1.mp4', '2.mp4']);
    expect(groups.inOrder[1].segments.single.name, '3.mp4');
    // Every stream member maps to its covering group.
    expect(groups.byKey['st1:Shorts/1.mp4'], same(groups.inOrder[0]));
    expect(groups.byKey['st1:Shorts/3.mp4'], same(groups.inOrder[1]));
  });

  test('chunks follow the RULE\'s sort: members are exempt from the external '
      'order', () {
    // The scenario streams by name while the rule sorts by duration, so chunk
    // membership comes from the RULE, not from where a file happens to sit in
    // the stream. Those members can therefore be interleaved (or moved by a
    // shuffle) without changing what a group merges or how its own segments
    // are sequenced.
    final stream = [
      streamItem('Shorts/aaa.mp4', durationMs: 1000),
      streamItem('Shorts/bbb.mp4', durationMs: 500),
      streamItem('Shorts/ccc.mp4', durationMs: 200),
    ];
    final groups = resolveGroupsForStream(stream, [
      rule(
        sortField: VmSortField.duration,
        sortDir: SortDirection.asc,
        maxItemCount: 2,
      ),
    ]);
    // Duration asc → ccc, bbb | aaa.
    expect(groups.inOrder, hasLength(2));
    expect(groups.inOrder[0].segments.map((s) => s.name).toList(),
        ['ccc.mp4', 'bbb.mp4']);
    expect(groups.inOrder[1].segments.single.name, 'aaa.mp4');

    // The merged ROW still takes part in the external order as a whole, at its
    // earliest member's position — and carries the RULE's segment order.
    final merged = applyVmOverlay(stream, groups.byKey);
    expect(merged, hasLength(2));
    expect(merged.map((e) => e.mediaKey).toList(),
        ['st1:Shorts/aaa.mp4', 'st1:Shorts/bbb.mp4'],
        reason: 'a group sits where its first member streams in');
    expect(merged[0].vmChildren.map((c) => c.name).toList(), ['aaa.mp4']);
    expect(merged[1].vmChildren.map((c) => c.name).toList(),
        ['ccc.mp4', 'bbb.mp4']);
  });

  test('cross-directory streams group per the rule\'s own chunking', () {
    // Two folder sources (A and B) in the stream, both covered by one rule
    // that ignores directory boundaries; the name sort decides the chunks.
    final groups = resolveGroupsForStream([
      streamItem('A/1.mp4'),
      streamItem('A/2.mp4'),
      streamItem('B/3.mp4'),
      streamItem('B/4.mp4'),
    ], [
      rule(paths: ['A', 'B'], maxItemCount: 2),
    ]);
    expect(groups.inOrder, hasLength(2));
    expect(groups.inOrder[0].segments.map((s) => s.name).toList(),
        ['1.mp4', '2.mp4']);
    expect(groups.inOrder[1].segments.map((s) => s.name).toList(),
        ['3.mp4', '4.mp4']);
  });

  test('non-consecutive members stay ONE group (membership is rule-defined)',
      () {
    final stream = [
      streamItem('Shorts/1.mp4'),
      streamItem('Movies/9.mp4'),
      streamItem('Shorts/2.mp4'),
    ];
    final groups = resolveGroupsForStream(stream, [rule()]);
    // The rule covers Shorts only, and its chunk spans BOTH Shorts files even
    // though a foreign file sits between them: a group is a rule entity, so an
    // interleaved — or shuffled — stream must not split it into two.
    expect(groups.inOrder, hasLength(1));
    expect(groups.byKey.keys,
        unorderedEquals(['st1:Shorts/1.mp4', 'st1:Shorts/2.mp4']));
    expect(groups.byKey['st1:Movies/9.mp4'], isNull);

    // The display folds them into ONE row, placed at the first member.
    final merged = applyVmOverlay(stream, groups.byKey);
    expect(merged, hasLength(2));
    expect(merged[0].mediaKey, 'st1:Shorts/1.mp4');
    expect(merged[0].virtualMerged, isTrue);
    expect(merged[1].mediaKey, 'st1:Movies/9.mp4');
    expect(merged.map((e) => e.virtualIndex).toList(), [0, 1]);
  });

  test('items outside rule scope are not grouped', () {
    final groups = resolveGroupsForStream([
      streamItem('Shorts/1.mp4'),
      streamItem('Movies/9.mp4'),
    ], [rule()]);
    expect(groups.byKey.keys, ['st1:Shorts/1.mp4']);
  });

  test('unavailable placeholders never merge', () {
    final groups = resolveGroupsForStream([
      streamItem('Shorts/1.mp4'),
      streamItem('Shorts/missing.mp4', available: false),
    ], [rule()]);
    expect(groups.byKey.keys, ['st1:Shorts/1.mp4']);
  });

  test('unknown-duration members degrade to failByKey, not byKey', () {
    final groups = resolveGroupsForStream([
      streamItem('Shorts/1.mp4', durationMs: 60000),
      streamItem('Shorts/2.mp4', durationMs: null),
    ], [rule(maxItemCount: 100)]);
    expect(groups.byKey, isEmpty);
    expect(groups.inOrder, isEmpty);
    expect(groups.failByKey.keys,
        containsAll(['st1:Shorts/1.mp4', 'st1:Shorts/2.mp4']));
  });

  test('overlay collapses stream into one merged entry (user-visible list)', () {
    // End-to-end: the scenario stream + a rule → the DISPLAYED list must show
    // ONE merged entry titled by the group, with totalItems shrinking.
    final stream = [
      streamItem('Shorts/1.mp4', durationMs: 60000),
      streamItem('Shorts/2.mp4', durationMs: 60000),
      streamItem('Shorts/3.mp4', durationMs: 60000),
      streamItem('Other/9.mp4'),
    ];
    final groups = resolveGroupsForStream(stream, [rule(maxItemCount: 100)]);
    final merged = applyVmOverlay(stream, groups.byKey);

    // 4 stream items → 2 displayed entries: one merged Shorts video + Other.
    expect(merged, hasLength(2));
    expect(merged[0].media.name, '1');
    expect(merged[0].media.path, ['Shorts', '1.mp4']); // identity stays first segment
    expect(merged[1].media.name, '9.mp4');
  });

  test('chunking follows the rule while the overlay still emits ONE row per '
      'group', () {
    // Durations interleave long/short across the stream (a1 LONG, a2 short,
    // b1 LONG, b2 short) and the rule sorts duration-DESC, so a chunk is
    // [a1,b1] | [a2,b2] — neither chunk is a contiguous span of the stream.
    // The overlay must still collapse each group to exactly one row, carrying
    // the group's OWN segment order rather than the stream's.
    final stream = [
      streamItem('Shorts/a1.mp4', durationMs: 10000),
      streamItem('Shorts/a2.mp4', durationMs: 100),
      streamItem('Shorts/b1.mp4', durationMs: 10000),
      streamItem('Shorts/b2.mp4', durationMs: 100),
    ];
    final groups = resolveGroupsForStream(stream, [
      rule(
        sortField: VmSortField.duration,
        sortDir: SortDirection.desc,
        maxItemCount: 2,
      ),
    ]);
    expect(groups.inOrder, hasLength(2));
    expect(groups.inOrder[0].segments.map((s) => s.name).toList(),
        ['a1.mp4', 'b1.mp4']);
    expect(groups.inOrder[1].segments.map((s) => s.name).toList(),
        ['a2.mp4', 'b2.mp4']);
    final merged = applyVmOverlay(stream, groups.byKey);
    expect(merged, hasLength(2),
        reason: 'one group must collapse to exactly one row');
    expect(merged.map((e) => e.mediaKey).toList(),
        ['st1:Shorts/a1.mp4', 'st1:Shorts/a2.mp4'],
        reason: 'each row is placed at its earliest member');
    expect(merged[0].vmChildren.map((c) => c.name).toList(),
        ['a1.mp4', 'b1.mp4']);
    expect(merged[1].vmChildren.map((c) => c.name).toList(),
        ['a2.mp4', 'b2.mp4']);
  });

  test('absolute DB paths match relative rule paths (Windows E:/ vs vault/)', () {
    // The DB stores ABSOLUTE parent paths (`E:/vault/003`) while the rule
    // path is storage-RELATIVE (`vault/003`). Both specifiedDir and
    // specifiedDirRecursive must still match — this was the root cause of
    // "rules enabled but groups=0".
    final groups = resolveGroupsForStream([
      streamItem('E:/vault/003/a.mp4'),
      streamItem('E:/vault/003/b.mp4'),
      streamItem('E:/vault/003/sub/c.mp4'),
    ], [rule(paths: ['vault/003'])]);
    expect(groups.byKey.keys, containsAll([
      'st1:E:/vault/003/a.mp4',
      'st1:E:/vault/003/b.mp4',
      'st1:E:/vault/003/sub/c.mp4',
    ]), reason: 'recursive must match absolute parentPath against relative rule');

    final direct = resolveGroupsForStream([
      streamItem('E:/vault/003/a.mp4'),
      streamItem('E:/vault/003/sub/c.mp4'),
    ], [rule(matchMode: VmMatchMode.specifiedDir, paths: ['vault/003'])]);
    expect(direct.byKey.keys, ['st1:E:/vault/003/a.mp4'],
        reason: 'non-recursive direct-children must match relative rule too');
  });

  test('root-directory title localizes via the passed l10n', () {
    final rootRule = rule(
      matchMode: VmMatchMode.specifiedDir,
      paths: const [''],
    ).copyWith(titleTags: const [VmTitleTag.dirName]);

    final zh = resolveGroupsForStream(
      [streamItem('1.mp4'), streamItem('2.mp4')],
      [rootRule],
      l10n: AppLocalizationsZh(),
    );
    expect(zh.inOrder, isNotEmpty);
    expect(zh.inOrder.first.displayName, contains('根目录'));

    final en = resolveGroupsForStream(
      [streamItem('1.mp4'), streamItem('2.mp4')],
      [rootRule],
      l10n: AppLocalizationsEn(),
    );
    expect(en.inOrder.first.displayName, contains('Root directory'));
  });
}
