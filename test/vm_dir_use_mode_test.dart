import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/rule/vm_dir_use.dart';

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
  List<VmPatternEntry> patterns = const [],
  VmRuleUseMode useMode = VmRuleUseMode.use,
  bool enabled = true,
}) =>
    VirtualMediaRule(
      id: id,
      name: id,
      matchMode: mode,
      paths: paths,
      patterns: patterns,
      useMode: useMode,
      enabled: enabled,
      skipSingleSegment: false,
    );

void main() {
  group('vmEffectiveUseMask fast path', () {
    test('returns null when no enabled notUse rule exists', () {
      final rules = [
        rule(id: 'u', mode: VmMatchMode.specifiedDirRecursive, paths: ['S']),
      ];
      expect(vmEffectiveUseMask(rules, [seg('S/a.mp4')]), isNull);
    });

    test('a disabled notUse rule does not trigger the mask', () {
      final rules = [
        rule(
          id: 'n',
          mode: VmMatchMode.specifiedDir,
          paths: ['S'],
          useMode: VmRuleUseMode.notUse,
          enabled: false,
        ),
      ];
      expect(vmEffectiveUseMask(rules, [seg('S/a.mp4')]), isNull);
    });
  });

  group('tier priority', () {
    test('non-recursive exclusion carves only its direct folder', () {
      final rules = [
        rule(id: 'rec', mode: VmMatchMode.specifiedDirRecursive, paths: ['S']),
        rule(
          id: 'no',
          mode: VmMatchMode.specifiedDir,
          paths: ['S/1'],
          useMode: VmRuleUseMode.notUse,
        ),
      ];
      expect(vmFileUseState(rules, seg('S/1/a.mp4')), VmFileUseState.excluded);
      // Parent / siblings / children keep the recursive inclusion.
      expect(vmFileUseState(rules, seg('S/2/b.mp4')), VmFileUseState.merged);
      expect(
          vmFileUseState(rules, seg('S/1/sub/c.mp4')), VmFileUseState.merged);
    });

    test('specifiedDir (non-recursive) beats patternDir notUse', () {
      // `S/1` is explicitly used; a name-pattern rule would exclude it.
      final rules = [
        rule(id: 'use', mode: VmMatchMode.specifiedDir, paths: ['S/1']),
        rule(
          id: 'no',
          mode: VmMatchMode.patternDir,
          patterns: const [
            VmPatternEntry(kind: VmPatternKind.suffix, text: '1'),
          ],
          useMode: VmRuleUseMode.notUse,
        ),
      ];
      expect(vmFileUseState(rules, seg('S/1/a.mp4')), VmFileUseState.merged);
    });

    test('notUse wins inside the pattern tier', () {
      final rules = [
        rule(
          id: 'u',
          mode: VmMatchMode.patternDir,
          patterns: const [
            VmPatternEntry(kind: VmPatternKind.suffix, text: '1'),
          ],
        ),
        rule(
          id: 'n',
          mode: VmMatchMode.patternDir,
          patterns: const [
            VmPatternEntry(kind: VmPatternKind.contains, text: '1'),
          ],
          useMode: VmRuleUseMode.notUse,
        ),
      ];
      expect(vmFileUseState(rules, seg('S/1/a.mp4')), VmFileUseState.excluded);
    });

    test('uncovered file is not merged', () {
      final rules = [
        rule(id: 'u', mode: VmMatchMode.specifiedDir, paths: ['Other']),
      ];
      expect(vmFileUseState(rules, seg('S/a.mp4')), VmFileUseState.uncovered);
    });
  });

  group('folder rule helpers', () {
    test('conflict is a path intersection, not list equality', () {
      final candidate = rule(
        id: 'new',
        mode: VmMatchMode.specifiedDir,
        paths: const ['S/1', 'S/2'],
      );
      final rules = [
        candidate,
        rule(id: 'a', mode: VmMatchMode.specifiedDir, paths: const ['S/2']),
        rule(id: 'b', mode: VmMatchMode.specifiedDir, paths: const ['S/9']),
        rule(
          id: 'c',
          mode: VmMatchMode.specifiedDir,
          paths: const ['S/1'],
          enabled: false,
        ),
        rule(
            id: 'd',
            mode: VmMatchMode.specifiedDirRecursive,
            paths: const ['S']),
      ];
      final conflicts = vmDirRuleConflicts(candidate, rules);
      expect(conflicts.map((r) => r.id), ['a']);
    });

    test('find reuses a rule on the exact folder, enabled or not', () {
      final rules = [
        rule(
          id: 'off',
          mode: VmMatchMode.specifiedDir,
          paths: const ['S/1'],
          enabled: false,
        ),
      ];
      expect(vmFindDirRule(rules, 'S/1')?.id, 'off');
      expect(vmFindDirRule(rules, 'S/2'), isNull);
      // A recursive rule is not the folder rule.
      expect(
        vmFindDirRule(
          [
            rule(id: 'r', mode: VmMatchMode.specifiedDirRecursive, paths: ['S'])
          ],
          'S',
        ),
        isNull,
      );
    });

    test('vmMakeDirRule carries the requested polarity and matcher', () {
      final use = vmMakeDirRule(
        id: 'x',
        name: 'n',
        folderPath: 'S/1',
        use: true,
      );
      expect(use.matchMode, VmMatchMode.specifiedDir);
      expect(use.paths, ['S/1']);
      expect(use.useMode, VmRuleUseMode.use);
      expect(use.enabled, isTrue);

      final off = vmMakeDirRule(
        id: 'y',
        name: 'n',
        folderPath: 'S/1',
        use: false,
      );
      expect(off.useMode, VmRuleUseMode.notUse);
    });

    test('unique name appends a counter', () {
      final rules = [rule(id: 'a', mode: VmMatchMode.specifiedDir)];
      rules[0] = rules[0].copyWith(name: 'S - 1');
      expect(vmUniqueDirRuleName('S - 1', rules), 'S - 1 2');
      expect(vmUniqueDirRuleName('fresh', rules), 'fresh');
    });

    test(
        'case-insensitive identity reuses a rule on a differently-cased folder',
        () {
      final rules = [
        rule(
          id: 'win',
          mode: VmMatchMode.specifiedDir,
          paths: const ['Movies/Show'],
        ),
      ];
      // Default stays case-sensitive (POSIX / SAF are distinct folders).
      expect(vmFindDirRule(rules, 'movies/show'), isNull);
      // Windows/SMB: the same folder spelled with different case is ONE rule,
      // not a duplicate.
      expect(vmFindDirRule(rules, 'movies/show', caseInsensitive: true)?.id,
          'win');

      final candidate = rule(
        id: 'new',
        mode: VmMatchMode.specifiedDir,
        paths: const ['movies/show'],
      );
      expect(
        vmDirRuleConflicts(candidate, rules, caseInsensitive: true)
            .map((r) => r.id),
        ['win'],
      );
      expect(vmDirRuleConflicts(candidate, rules), isEmpty);
    });
  });
}
