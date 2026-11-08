/// App-level audio mixing policy for the dual-engine (foreground + 副音) era.
///
/// One true master volume stays in [AppState] (`volume`, 0–100, `isMuted`).
/// While 副音 is INACTIVE (feature off, or the user gate closed) the foreground
/// engine gets the master verbatim — the pure legacy single-track path, with
/// NEITHER the fg ratio NOR the track mute applied. While it is ACTIVE each
/// engine is scaled by its own ratio, and each track carries an INDEPENDENT
/// mute:
///
///   fg engine = master × fgVolumePercent/100   (default 30 — 前台压低)
///   bg engine = master × bgVolumePercent/100   (default 100)
///
/// Master mute mutes both sides; [fgMuted] only the foreground track; [bgMuted]
/// only the 副音 track. Engine domains differ: media_kit uses 0–100,
/// fvp/video_player uses 0–1 — [toFvpScale] is the fvp conversion.
abstract final class BackgroundVolumePolicy {
  static const int defaultFgPercent = 30;
  static const int defaultBgPercent = 100;

  /// Whether 副音 is actively mixing right now — the ONE duck gate shared by
  /// both engines. [enabled] is the subsystem flag, [gateOpen] the user gate
  /// (quick-bar play/stop), [exhausted] the stopRestoreFg terminal state,
  /// [queueEnded] the "walked off the end of the queue" state and [outOfScope]
  /// the current media being outside the run's 作用范围 (or a 简播 cut).
  ///
  /// A closed gate or an inactive pair must read exactly like "no 副音 at all":
  /// the foreground then plays like any normal single-track player. Omitting
  /// [outOfScope] was the 「换到下一首后视频只剩 30% 音量、副音却静音」 report:
  /// the pair had stopped for the new media but the duck kept multiplying the
  /// foreground by [defaultFgPercent].
  static bool active({
    required bool enabled,
    required bool gateOpen,
    bool exhausted = false,
    bool queueEnded = false,
    bool outOfScope = false,
  }) =>
      enabled && gateOpen && !exhausted && !queueEnded && !outOfScope;

  /// Effective 0–100 engine volume for the FOREGROUND engine.
  static int foregroundEngineVolume({
    required int master,
    required bool muted,
    required bool bgActive,
    int fgPercent = defaultFgPercent,
    bool fgMuted = false,
  }) {
    if (muted) return 0;
    final clamped = master.clamp(0, 100);
    // No 副音: master verbatim — the fg ratio AND the per-track mute are
    // mixing-domain concepts that do not exist on the legacy path.
    if (!bgActive) return clamped;
    if (fgMuted) return 0;
    return (clamped * fgPercent ~/ 100).clamp(0, 100);
  }

  /// Effective 0–100 engine volume for the BACKGROUND engine.
  static int backgroundEngineVolume({
    required int master,
    required bool muted,
    required bool bgActive,
    int bgPercent = defaultBgPercent,
    bool bgMuted = false,
  }) {
    if (!bgActive || muted || bgMuted) return 0;
    final clamped = master.clamp(0, 100);
    return (clamped * bgPercent ~/ 100).clamp(0, 100);
  }

  /// fvp/video_player expects 0–1.
  static double toFvpScale(int volume0to100) => volume0to100 / 100;
}
