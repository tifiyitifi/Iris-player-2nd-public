# 0017 - A completed background master releases the foreground; a user step has one entry

- Date: 2026-11-21
- Status: accepted
- Private history: `5ef14f87`
- Superseded by: none

## Context

Two reports shared one seam: who owns the pair's transport and control routing.

1. With the control target on the background, the background engine is the
   transport **master**. A natural completion sets `isPlaying=false` while the
   completion continuation is still resolving the next landing. The generic
   transport mirror read that ended pause as a master pause and issued
   `fgPlayer.pause()` (plus `updateAutoPlay(false)`). The continuation's landing
   does not always re-issue a foreground play, and until it lands the mirror
   keeps re-pausing a foreground the user tries to start. Result: the video
   froze on the completed background file.

2. The control bar's previous/next buttons called the background store's `step`
   directly while the background owned the controls. That bypassed the router,
   dropping `excludedKey: excludedForegroundKey()` (the double-play guard) and
   `userInitiated: true` (the manual-switch mark). A background step could land
   on the file the foreground was already playing, and the position mirror then
   dragged the video to the wrong place.

## Decision

- An ended background master is **not** a paused master. The engine publishes a
  completion hold (`completionPending`) from the natural-end signal until
  playback actually resumes (a real play, a new open, or a stop); the transport
  mirror stands down for its duration. The continuation (nextBg / repeat-one /
  queue end / exhausted) owns the pair in that window.
- User stepping has ONE entry: `PlaybackProviderRegistry.step` →
  `BackgroundPlaybackRouter.step`, which supplies the foreground double-play
  guard and the manual-switch mark. Control surfaces never call the background
  store's `step` directly.
- A background transport command never writes the foreground autoplay flag (the
  legacy bar's play/stop now follow the same rule).

## Consequences

- A completed background file no longer pauses the video.
- A control-bar step and a keyboard step behave identically (same guards).
- `rules.md` gains GATE-8 and LOCK-7; `scripts/check-bg-rules.ps1` resolves both.

## Rejected alternatives

- Force a foreground play on every continuation exit: a legitimate user pause
  must survive, and the clean fix is not to issue the wrong pause at all.
- Special-case only `bgQueueEnded`/`bgExhausted`: both latch a frame *after* the
  completion frame the mirror acts on, so they cannot cover it.
- Reset `controlTarget` on hand-back: the target is the user's routing
  preference and is deliberately preserved; `bgOwnsControls` is derived.
