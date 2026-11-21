import 'dart:typed_data';

import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/utils/dir_match.dart';

/// How a file participates in virtual merging after the use/exclude rules are
/// applied.
enum VmFileUseState {
  /// A covering rule wins and it is an inclusion rule.
  merged,

  /// A covering rule wins and it is an exclusion rule.
  excluded,

  /// No enabled rule covers the file; it stays an ordinary single.
  uncovered,
}

class _TieredRule {
  const _TieredRule(this.dir, this.isUse);
  final CompiledDirRule dir;
  final bool isUse;
}

/// Four priority tiers, highest first (product contract):
///
///   1. `specifiedDir` (explicit path, non-recursive) — a folder-targeted rule
///      wins outright: "说用就用，说不用就不用".
///   2. `patternDir` (name match, non-recursive).
///   3. `specifiedDirRecursive`.
///   4. `patternDirRecursive`.
///
/// Non-recursive always outranks recursive, so a non-recursive exclusion can
/// carve one folder out of a recursive inclusion while its children keep
/// merging. Inside one tier `notUse` wins (an explicit exclusion is the safer
/// reading); tier 1 is additionally protected by the same-path uniqueness rule.
List<List<_TieredRule>> _compileTiers(List<VirtualMediaRule> rules) {
  final t1 = <_TieredRule>[];
  final t2 = <_TieredRule>[];
  final t3 = <_TieredRule>[];
  final t4 = <_TieredRule>[];
  for (final r in rules) {
    if (!r.enabled) continue;
    final tier = switch (r.matchMode) {
      VmMatchMode.specifiedDir => t1,
      VmMatchMode.patternDir => t2,
      VmMatchMode.specifiedDirRecursive => t3,
      VmMatchMode.patternDirRecursive => t4,
    };
    tier.add(_TieredRule(_compile(r), r.useMode == VmRuleUseMode.use));
  }
  return [t1, t2, t3, t4];
}

CompiledDirRule _compile(VirtualMediaRule r) => compileDirRule(
      mode: _toDirMode(r.matchMode),
      paths: r.paths,
      patterns: [
        for (final p in r.patterns)
          DirPatternEntry(
            kind: _toPatternKind(p.kind),
            text: p.text,
            activated: p.activated,
            pinned: p.pinned,
          ),
      ],
    );

DirMatchMode _toDirMode(VmMatchMode mode) => switch (mode) {
      VmMatchMode.specifiedDir => DirMatchMode.specifiedDir,
      VmMatchMode.specifiedDirRecursive => DirMatchMode.specifiedDirRecursive,
      VmMatchMode.patternDir => DirMatchMode.patternDir,
      VmMatchMode.patternDirRecursive => DirMatchMode.patternDirRecursive,
    };

DirPatternKind _toPatternKind(VmPatternKind kind) => switch (kind) {
      VmPatternKind.prefix => DirPatternKind.prefix,
      VmPatternKind.suffix => DirPatternKind.suffix,
      VmPatternKind.contains => DirPatternKind.contains,
      VmPatternKind.regex => DirPatternKind.regex,
    };

VmFileUseState _stateFromTiers(
    List<List<_TieredRule>> tiers, VirtualSegment seg) {
  for (final tier in tiers) {
    if (tier.isEmpty) continue;
    var covered = false;
    var sawNotUse = false;
    for (final r in tier) {
      if (compiledDirRuleMatchesFile(r.dir,
          fullPath: seg.fullPath, parentPath: seg.parentPath)) {
        covered = true;
        if (!r.isUse) sawNotUse = true;
      }
    }
    if (covered) {
      return sawNotUse ? VmFileUseState.excluded : VmFileUseState.merged;
    }
  }
  return VmFileUseState.uncovered;
}

/// The use/exclude outcome for one file. Pure: unit-testable.
VmFileUseState vmFileUseState(
        List<VirtualMediaRule> rules, VirtualSegment seg) =>
    _stateFromTiers(_compileTiers(rules), seg);

/// Per-file "may this file still merge?" mask (1 = yes, 0 = excluded by a
/// `notUse` rule).
///
/// Returns null when no enabled rule is a `notUse` rule — the FAST PATH. The
/// 500k-media pipeline then pays only one boolean test and never allocates the
/// mask or walks the library an extra time.
///
/// [Uint8List] is one byte per file (0.5 MB at 500k), deliberately NOT a
/// `Set<String>` (tens of MB) — the phone is the target.
Uint8List? vmEffectiveUseMask(
  List<VirtualMediaRule> rules,
  List<VirtualSegment> library,
) {
  var hasNotUse = false;
  for (final r in rules) {
    if (r.enabled && r.useMode == VmRuleUseMode.notUse) {
      hasNotUse = true;
      break;
    }
  }
  if (!hasNotUse) return null;
  final tiers = _compileTiers(rules);
  final mask = Uint8List(library.length);
  for (var i = 0; i < library.length; i++) {
    mask[i] =
        _stateFromTiers(tiers, library[i]) == VmFileUseState.excluded ? 0 : 1;
  }
  return mask;
}

/// Materialized excluded keys for the bounded (<= 50k) management preview.
///
/// Playback must use [vmEffectiveUseMask]; this set is only for the settings
/// preview where the library is capped and a set is convenient.
Set<String> vmRuleExcludedKeys(
  List<VirtualMediaRule> rules,
  List<VirtualSegment> library,
) {
  final mask = vmEffectiveUseMask(rules, library);
  if (mask == null) return const {};
  final out = <String>{};
  for (var i = 0; i < library.length; i++) {
    if (mask[i] == 0) out.add(library[i].mediaKey);
  }
  return out;
}

/// The (enabled or disabled) `specifiedDir` rule whose picked path matches
/// [folderPath], or null. Used by the folder toggle to reuse one rule instead
/// of creating a duplicate.
///
/// [caseInsensitive] folds case when the backing storage rides a
/// case-insensitive filesystem (Windows drive/UNC, SMB). Matching a folder for
/// RULE IDENTITY must follow the filesystem, or the same directory spelled with
/// different case creates a duplicate rule. The resolver's own matching keeps
/// its existing semantics; this only affects de-duplication.
VirtualMediaRule? vmFindDirRule(
  List<VirtualMediaRule> rules,
  String folderPath, {
  bool caseInsensitive = false,
}) {
  for (final r in rules) {
    if (r.matchMode != VmMatchMode.specifiedDir) continue;
    if (_pathsOverlap(<String>[folderPath], r.paths,
        caseInsensitive: caseInsensitive)) {
      return r;
    }
  }
  return null;
}

/// Other ENABLED non-recursive `specifiedDir` rules that pick any of the same
/// directories as [candidate] (path-set INTERSECTION, not list equality — a
/// rule may union several paths).
///
/// [caseInsensitive] has the same meaning as in [vmFindDirRule].
List<VirtualMediaRule> vmDirRuleConflicts(
  VirtualMediaRule candidate,
  List<VirtualMediaRule> rules, {
  bool caseInsensitive = false,
}) {
  if (candidate.matchMode != VmMatchMode.specifiedDir) return const [];
  final out = <VirtualMediaRule>[];
  for (final r in rules) {
    if (r.id == candidate.id) continue;
    if (!r.enabled) continue;
    if (r.matchMode != VmMatchMode.specifiedDir) continue;
    if (_pathsOverlap(candidate.paths, r.paths,
        caseInsensitive: caseInsensitive)) {
      out.add(r);
    }
  }
  return out;
}

bool _pathsOverlap(
  List<String> a,
  List<String> b, {
  bool caseInsensitive = false,
}) {
  for (final x in a) {
    for (final y in b) {
      if (caseInsensitive
          ? dirsEqual(x.toLowerCase(), y.toLowerCase())
          : dirsEqual(x, y)) {
        return true;
      }
    }
  }
  return false;
}

/// Builds the rule the folder toggle creates when none exists: the default
/// chunk configuration scoped to ONE non-recursive directory.
VirtualMediaRule vmMakeDirRule({
  required String id,
  required String name,
  required String folderPath,
  required bool use,
}) =>
    VirtualMediaRule(
      id: id,
      name: name,
      description: '',
      matchMode: VmMatchMode.specifiedDir,
      paths: <String>[folderPath],
      patterns: const [],
      sortField: VmSortField.fileName,
      sortDir: SortDirection.asc,
      boundary: VmBoundaryMode.sameDirOnly,
      maxDurationMinutes: 90,
      maxItemCount: 32,
      useDurationCap: true,
      useCountCap: true,
      useExcludeOverlong: true,
      maxSingleDurationMinutes: 35,
      skipSingleSegment: true,
      titleTags: const [VmTitleTag.dirName, VmTitleTag.seq],
      useMode: use ? VmRuleUseMode.use : VmRuleUseMode.notUse,
      enabled: true,
    );

/// A rule name that does not collide with an existing one (`base`, `base 2`,
/// `base 3`, ...). Pure so the toggle command can be tested without a DB.
String vmUniqueDirRuleName(String base, List<VirtualMediaRule> rules) {
  final trimmed = base.trim().isEmpty ? 'VM' : base.trim();
  final names = {for (final r in rules) r.name};
  if (!names.contains(trimmed)) return trimmed;
  var n = 2;
  while (names.contains('$trimmed $n')) {
    n++;
  }
  return '$trimmed $n';
}
