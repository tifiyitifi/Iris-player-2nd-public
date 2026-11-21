import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';

part 'vm_rule.freezed.dart';
part 'vm_rule.g.dart';

/// Hard ceiling for chunking: at most 32 videos per virtual item, even when
/// the user leaves both caps unchecked (bounds standby/open cost and keeps
/// the virtual timeline seekable; 32 whole-file sectors is also the
/// readability floor of the dial chunk ring, ~10° per sector).
const int kVmHardMaxItemCount = 32;

/// Hard ceiling for chunking: at most 5 hours per virtual item, even when
/// the user leaves both caps unchecked.
const int kVmHardMaxDurationMinutes = 300;

/// Defaults for new rules (2h / 32 videos).
const int kVmDefaultMaxDurationMinutes = 120;
const int kVmDefaultMaxItemCount = 32;

/// Default per-file exclusion threshold in minutes (35 min). Files strictly
/// longer than this are left out of virtual merges when [VirtualMediaRule
/// .useExcludeOverlong] is on; same 1 min – 5 h range as the chunk cap.
const int kVmDefaultMaxSingleDurationMinutes = 35;

/// One pattern condition of a 匹配目录 rule.
///
/// Entries are AND-ed: only directories satisfying EVERY ACTIVATED entry
/// match. [pinned] is display-only (pinned entries list first); it carries
/// no resolution semantics.
@freezed
abstract class VmPatternEntry with _$VmPatternEntry {
  const factory VmPatternEntry({
    required VmPatternKind kind,
    @Default('') String text,
    @Default(true) bool activated,
    @Default(false) bool pinned,
  }) = _VmPatternEntry;

  factory VmPatternEntry.fromJson(Map<String, dynamic> json) =>
      _$VmPatternEntryFromJson(json);
}

/// Domain view of one [VmRulesTable] row — the simplified v2 rule.
///
/// Rules are DATA: the resolver interprets them, nothing about matching or
/// grouping is hard-coded into playback code. Identity is the text [id].
///
/// Deliberately ABSENT from the v1 model: priority, searchRoot,
/// excludePatterns, candidateScope, maxItemCount, keepDirectoryBoundary and
/// the nameTemplate — each either replaced by a simpler field or dropped
/// (rules are independent; duplicates are the user's to avoid).
@freezed
abstract class VirtualMediaRule with _$VirtualMediaRule {
  const factory VirtualMediaRule({
    required String id,

    /// Display name; also a title-composition tag.
    required String name,

    /// Optional description shown in the virtual item's subtitle.
    @Default('') String description,

    /// 指定/匹配 × 递归/非递归.
    @Default(VmMatchMode.patternDir) VmMatchMode matchMode,

    /// Picked directory paths (指定模式). Storage-relative canonical form,
    /// `/` separators. Multiple paths are a UNION.
    @Default(<String>[]) List<String> paths,

    /// AND-ed name conditions (匹配模式).
    @Default(<VmPatternEntry>[]) List<VmPatternEntry> patterns,

    /// Single-level sort; nulls last, mediaKey tie-break appended.
    @Default(VmSortField.fileName) VmSortField sortField,
    @Default(SortDirection.asc) SortDirection sortDir,

    /// Directory-crossing policy applied after sorting.
    @Default(VmBoundaryMode.sameDirOnly) VmBoundaryMode boundary,

    /// Chunk duration cap in minutes (default 120 = 2h, hard ceiling 300).
    @Default(kVmDefaultMaxDurationMinutes) int maxDurationMinutes,

    /// Chunk item-count cap (default 32, hard ceiling 32).
    /// Honored only when [useCountCap].
    @Default(kVmDefaultMaxItemCount) int maxItemCount,

    /// At least one of these must be true ("至少勾选一个").
    @Default(true) bool useDurationCap,
    @Default(true) bool useCountCap,

    /// Excludes single videos longer than [maxSingleDurationMinutes] from
    /// the merge (they are not "算入虚拟合播"). Unknown durations (null/0)
    /// are never excluded — they still take part and degrade via preflight.
    @Default(true) bool useExcludeOverlong,

    /// Per-file exclusion threshold in minutes (default 35, hard ceiling
    /// [kVmHardMaxDurationMinutes]). Honored only when [useExcludeOverlong].
    @Default(kVmDefaultMaxSingleDurationMinutes) int maxSingleDurationMinutes,

    /// When true, a chunk that ends up with exactly one segment is not
    /// presented as a virtual item (the file stays an ordinary single).
    @Default(true) bool skipSingleSegment,

    /// Lit title tags in lighting order (= concatenation order).
    @Default(<VmTitleTag>[VmTitleTag.dirName, VmTitleTag.seq])
    List<VmTitleTag> titleTags,

    /// Whether an ENABLED rule uses ([VmRuleUseMode.use], historical
    /// behaviour) or excludes ([VmRuleUseMode.notUse]) the directories it
    /// matches from virtual merging. Independent of [enabled].
    @Default(VmRuleUseMode.use) VmRuleUseMode useMode,

    /// Disabled rules are ignored by the resolver entirely.
    @Default(true) bool enabled,

    /// Pinned rules display first in the management list — presentation
    /// only, no resolution priority ("无视优先级").
    @Default(false) bool pinned,

    /// Player title separator (spec §9.2 configurable, default ':').
    /// Joins “目录:序号/总数:原名”.
    @Default(':') String playerTitleSeparator,
  }) = _VirtualMediaRule;

  factory VirtualMediaRule.fromJson(Map<String, dynamic> json) =>
      _$VirtualMediaRuleFromJson(json);
}
