import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/resolver/vm_fake_cut_exclusions.dart';
import 'package:iris/features/virtual_media/resolver/vm_resolver.dart';

/// Rule-level exclusions (`notUse` folders) still remove a member from another
/// rule's group; every remaining member keeps merging exactly as before.
///
/// 虚拟剪播 no longer excludes a file: an ACTIVE plan joins the merge as its cut
/// timeline (ADR 0037, `vm_cut_merge_test.dart`).
///
/// The exclusion set is injected (pure), so these tests never touch the
/// filesystem — `fake_cut_project_index_test.dart` covers the pairing itself.
VirtualSegment seg(String path, {int durationMs = 1000}) {
  final List<String> parts = path.split('/');
  return VirtualSegment(
    mediaKey: 'st1:$path',
    storageId: 'st1',
    path: parts,
    name: parts.last,
    parentPath:
        parts.length <= 1 ? '' : parts.sublist(0, parts.length - 1).join('/'),
    durationMs: durationMs,
  );
}

VirtualMediaRule dirRule({bool skipSingleSegment = false}) => VirtualMediaRule(
      id: 'r1',
      name: 'rule',
      matchMode: VmMatchMode.specifiedDir,
      paths: const <String>['/tv/show'],
      patterns: const <VmPatternEntry>[],
      sortField: VmSortField.fileName,
      sortDir: SortDirection.asc,
      boundary: VmBoundaryMode.sameDirOnly,
      maxDurationMinutes: 90,
      titleTags: const <VmTitleTag>[VmTitleTag.seq],
      enabled: true,
      pinned: false,
      useExcludeOverlong: false,
      skipSingleSegment: skipSingleSegment,
    );

void main() {
  final List<VirtualSegment> library = <VirtualSegment>[
    seg('/tv/show/ep01.mp4'),
    seg('/tv/show/ep02.mp4'),
    seg('/tv/show/ep03.mp4'),
  ];

  group('resolveRuleGroups', () {
    test('an excluded member is skipped, the rest still merge', () {
      final List<VirtualMediaItem> items = resolveRuleGroups(
        rules: <VirtualMediaRule>[dirRule()],
        library: library,
        excludedMediaKeys: <String>{'st1:/tv/show/ep02.mp4'},
      );
      expect(items, hasLength(1));
      expect(
        items.single.segments.map((VirtualSegment s) => s.name),
        <String>['ep01.mp4', 'ep03.mp4'],
      );
    });

    test('no exclusion keys keeps the whole group', () {
      final List<VirtualMediaItem> items = resolveRuleGroups(
        rules: <VirtualMediaRule>[dirRule()],
        library: library,
      );
      expect(items.single.segments, hasLength(3));
    });

    test('excluding every member drops the group entirely', () {
      final List<VirtualMediaItem> items = resolveRuleGroups(
        rules: <VirtualMediaRule>[dirRule()],
        library: library,
        excludedMediaKeys: <String>{
          'st1:/tv/show/ep01.mp4',
          'st1:/tv/show/ep02.mp4',
          'st1:/tv/show/ep03.mp4',
        },
      );
      expect(items, isEmpty);
    });

    test('a group left with one member follows skipSingleSegment', () {
      final Set<String> excluded = <String>{
        'st1:/tv/show/ep02.mp4',
        'st1:/tv/show/ep03.mp4',
      };
      expect(
        resolveRuleGroups(
          rules: <VirtualMediaRule>[dirRule()],
          library: library,
          excludedMediaKeys: excluded,
        ),
        hasLength(1),
      );
      expect(
        resolveRuleGroups(
          rules: <VirtualMediaRule>[dirRule(skipSingleSegment: true)],
          library: library,
          excludedMediaKeys: excluded,
        ),
        isEmpty,
      );
    });
  });

  test('a non-local row never resolves a cut range (no filesystem hit)',
      () async {
    // SAF/remote rows cannot pair a sibling `.llc`; the helper must skip them
    // rather than hand a content:// uri to the directory index.
    final VmCutMergeInfo info = await vmCutMergeInfo(
      <VirtualSegment>[
        VirtualSegment(
          mediaKey: 'st1:content://tree/x.mp4',
          storageId: 'st1',
          path: const <String>['content://tree/x.mp4'],
          name: 'x.mp4',
          parentPath: '',
          uri: 'content://tree/x.mp4',
          durationMs: 1000,
        ),
      ],
      preferredPlanPaths: const <String, String>{
        'st1:content://tree/x.mp4': 'content://tree/x.llc',
      },
    );
    expect(info.rangesByKey, isEmpty);
  });
}
