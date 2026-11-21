/// How the 作用范围「仅当前」rule treats a Virtual Merge foreground.
///
/// A VM item presents a chain of physical segments as ONE video, so "the media
/// playing now" is ambiguous: the whole virtual video, or the physical block
/// currently on screen. This setting resolves that for the CURRENT-ONLY scope.
///
/// Volume ratio is deliberately NOT covered — each physical block keeps its own
/// saved pair.
enum BgVmScopeMode {
  /// 独立块匹配 (default): only the physical block on screen counts as the
  /// current media, so every VM block switch is a media switch.
  perBlock,

  /// The whole virtual video counts as ONE media: 副音 keeps applying across
  /// internal block switches and only stops when the user leaves for another
  /// video (virtual or not).
  wholeVirtual,
}
