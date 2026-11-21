import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/resolver/vm_resolver.dart';

VirtualSegment seg(String path, {String storage = 's'}) {
  final parts = path.split('/');
  return VirtualSegment(
    mediaKey: '$storage:$path',
    storageId: storage,
    path: parts,
    name: parts.last,
    parentPath:
        parts.length <= 1 ? '' : parts.sublist(0, parts.length - 1).join('/'),
  );
}

VirtualMediaRule rule({
  required String id,
  required VmMatchMode mode,
  List<String> paths = const [],
  VmRuleUseMode useMode = VmRuleUseMode.use,
}) =>
    VirtualMediaRule(
      id: id,
      name: id,
      matchMode: mode,
      paths: paths,
      useMode: useMode,
      skipSingleSegment: false,
    );

void main() {
  test('a non-recursive notUse rule removes only its folder from a merge', () {
    final rules = [
      rule(id: 'use', mode: VmMatchMode.specifiedDirRecursive, paths: ['Shorts']),
      rule(
        id: 'no',
        mode: VmMatchMode.specifiedDir,
        paths: ['Shorts/1'],
        useMode: VmRuleUseMode.notUse,
      ),
    ];
    final library = [
      seg('Shorts/1/a.mp4'),
      seg('Shorts/2/b1.mp4'),
      seg('Shorts/2/b2.mp4'),
    ];
    final items = resolveVirtualMedia(rules: rules, library: library);

    // Shorts/1 is excluded; Shorts/2 still merges its two files.
    expect(items, hasLength(1));
    expect(
      items.single.segments.map((s) => s.name).toList(),
      ['b1.mp4', 'b2.mp4'],
    );
  });

  test('without a notUse rule the same library is unchanged', () {
    final rules = [
      rule(id: 'use', mode: VmMatchMode.specifiedDirRecursive, paths: ['Shorts']),
    ];
    final library = [
      seg('Shorts/1/a.mp4'),
      seg('Shorts/2/b1.mp4'),
      seg('Shorts/2/b2.mp4'),
    ];
    final items = resolveVirtualMedia(rules: rules, library: library);
    final names = [
      for (final it in items)
        for (final s in it.segments) s.name,
    ];
    expect(names, containsAll(['a.mp4', 'b1.mp4', 'b2.mp4']));
  });

  test('a notUse rule never produces its own virtual item', () {
    final rules = [
      rule(
        id: 'no',
        mode: VmMatchMode.specifiedDir,
        paths: ['Shorts'],
        useMode: VmRuleUseMode.notUse,
      ),
    ];
    final items = resolveVirtualMedia(
      rules: rules,
      library: [seg('Shorts/a.mp4'), seg('Shorts/b.mp4')],
    );
    expect(items, isEmpty);
  });
}
