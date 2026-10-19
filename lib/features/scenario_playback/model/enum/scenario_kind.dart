/// The kind of a Scenario row (C2/A1).
///
/// The SystemPlayingScenario is still a [Scenario] — only its [ScenarioKind]
/// differs. There is no parallel "SystemPlayingScenario" domain class.
enum ScenarioKind {
  /// The single current-playing workspace row. Never deleted, never shown as a
  /// normal saved scenario. `version` is always null (E4).
  systemPlaying,

  /// A custom desktop entry's OWN independently saved "system playing"
  /// workspace. One row per independent entry (id held by the entry), created
  /// lazily on first launch. Never shown as a normal saved scenario, never
  /// deleted through the scenario UI; removed only with its owning entry.
  entryWorkspace,

  /// A user-saved playback plan. Never connects to the Player directly; it is
  /// loaded into the systemPlaying row via Override/Append/Copy/Sync.
  userSaved,

  /// The single 副音 (background) workspace row. It carries the per-entry 副音
  /// playback STATE (position, repeat/shuffle); its CONTENT is not a scenario
  /// source but the reserved 「副音备选」tag's VIEW (`TagViewResolver`,
  /// `ignoreScenario: true`) — the same tag play view the foreground uses, so
  /// 副音's list is exactly "the videos tagged for 副音". Never shown in the
  /// saved-scenario list, never deleted through the scenario UI; never drives
  /// the foreground player.
  ///
  /// This is the DEFAULT context's background (paired with the SystemPlaying
  /// workspace). An independent app entry owns its own [entryBackground].
  background,

  /// The 副音 counterpart of an independent app entry's [entryWorkspace]: one
  /// row per independent entry, created lazily together with the fg workspace
  /// and deleted with the owning entry. Each entry therefore has its own
  /// fg/bg PAIR, so switching entries never mixes their background queues.
  /// Never shown in the saved-scenario list, never drives the foreground.
  entryBackground,
}
