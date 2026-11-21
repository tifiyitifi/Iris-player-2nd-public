/// Whether an ENABLED rule USES or does NOT USE virtual merging for the
/// directories it matches.
///
/// [use] is the historical behaviour: matching files merge into virtual items.
/// [notUse] is an exclusion: matching files stay out of every merge. Because a
/// rule is independent of [VirtualMediaRule.enabled], a rule can be saved but
/// disabled while keeping its polarity for the next enable.
enum VmRuleUseMode {
  use,
  notUse,
}

/// How a rule selects the directories whose media merge into virtual items.
enum VmMatchMode {
  /// 指定目录（非递归）: only files whose direct parent is one of the
  /// picked directories.
  specifiedDir,

  /// 指定目录（递归）: all media beneath the picked directories,
  /// including subdirectories.
  specifiedDirRecursive,

  /// 匹配目录（非递归）: directories whose name satisfies every activated
  /// pattern entry; only their direct media merge.
  patternDir,

  /// 匹配目录（递归）: matched directories plus their whole subtrees.
  patternDirRecursive,
}

/// One pattern condition of a 匹配目录 rule.
///
/// Users never write globs: the four kinds cover the everyday cases and
/// regex is the escape hatch. Several entries under one rule are AND-ed
/// (every ACTIVATED entry must hold).
enum VmPatternKind {
  /// 匹配目录名前缀.
  prefix,

  /// 匹配目录名后缀.
  suffix,

  /// 目录包含内容.
  contains,

  /// 按正则表达式.
  regex,
}

/// Directory-crossing policy applied after sorting.
enum VmBoundaryMode {
  /// 目录内排序且合并媒体仅在同一目录: chunks never span directories.
  sameDirOnly,

  /// 目录内排序但允许跨目录合并媒体: directories keep their natural order
  /// but one chunk may continue into the next directory.
  crossDirMerge,

  /// 无视目录: one global sort, then chunk; directories play no role.
  ignoreDirs,
}

/// Single-level segment sort field. Must include aspect ratio and
/// resolution per product decision; width/height are plain numeric sorts.
/// Unknown probe values always sort LAST regardless of direction.
enum VmSortField {
  fileName,
  duration,
  resolution,
  aspectRatio,
  width,
  height,
}

/// Toggleable label chips composing a virtual item's display title.
///
/// The lit order IS the concatenation order — there is no separate
/// reorder control ("关闭排序": 点亮顺序即标题顺序).
enum VmTitleTag {
  ruleName,
  dirName,
  firstFile,
  lastFile,

  /// 序号 (chunk number). Named `seq` because [Enum] forbids an `index`
  /// instance member collision.
  seq,
  duration,
  resolution,
}

/// Cross-segment drag strategy for virtual merge (spec §6).
///
/// [directSwitch] — every drag tick jumps live (default): cross-segment
/// ticks open WITH the intra-segment offset, throttled to one open per
/// 300ms, with the release commit covering the dropped tail.
/// [previewOnRelease] — during cross-segment drag no picture change,
/// floating preview “将跳转第X段 …” until release commits once.
/// [clampToCurrent] is hidden from settings (kept only so the name never
/// needs a migration); the drag gate degrades it to direct behavior.
enum VmCrossSegmentDragStrategy {
  previewOnRelease,
  directSwitch,
  clampToCurrent,
}

/// How the B-scheme dual time labels resolve the "same instant, two axes"
/// rounding mismatch (virtual merged playback only).
///
/// The total (merged) and sub (current-segment) labels are each floored to
/// whole seconds, but a segment's start offset is almost never a whole number
/// of seconds, so the two second-digits tick at different instants (up to
/// ~1s apart). This mode lets the user pick which row to quantize onto the
/// other's second grid.
///
/// [exact] — both rows stay numerically exact; their seconds may tick
/// alternately (no correction).
/// [subToTotal] — the total stays exact; the sub is counted on the total's
/// second grid (sub may read up to ~1s off). Default.
/// [totalToSub] — the sub stays exact; the total is counted on the sub's
/// second grid (total may read up to ~1s off).
enum VmDualTimeSyncMode {
  exact,
  subToTotal,
  totalToSub,
}
