/// The LEGACY persisted default alignment (the `bg.alignDefault` AUX row).
///
/// It no longer drives anything: every fresh anchor is decided AUTOMATICALLY by
/// `resolveAutoAlignAnchor` from the two real durations, and the alignment
/// popup's 「默认对齐」 tab is read-only (it explains that rule). Only the three
/// MANUAL anchors have a counterpart here — [BgAlignMode.tailAtFg] is the
/// automatic rule's own answer — so this never mirrored [BgAlignMode]
/// one-to-one. The values are kept as the frozen on-disk preference so an
/// upgraded install keeps its row (see [key]).
///
/// There is no "always ask" value either: a mandatory remaining-time
/// threshold (see `alignAutoPauseRemainSec`) raises the prompt instead.
///
/// Every value answers ONE question: which 副音 moment maps to the video's
/// current moment. The names say that directly — the old `fgHead`/`fgPosition`
/// names read as "start from the foreground's head" and were the opposite of
/// what the modes do (see `bg_align_mode.dart`).
enum BgAlignDefault {
  /// 副音与视频同一刻度: the 副音 position equals the video position
  /// (`bgPos = fgPos`).
  sameClock('fgHead'),

  /// 副音 00:00 sits at the video's current moment (`bgPos = 0` at anchor).
  bgHead('fgPosition'),

  /// 副音 starts at [percent]% of its duration, anchored to the video moment.
  bgPercent('bgPercent');

  const BgAlignDefault(this.key);

  /// The PERSISTED name (the `bg.alignDefault` AUX row + the settings enum
  /// value). Deliberately frozen at the pre-rename spelling so an upgraded
  /// install keeps its preference and the settings row keeps matching: the
  /// rename is code-only, never a data migration.
  final String key;
}
