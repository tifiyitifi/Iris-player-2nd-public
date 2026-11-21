# 0018 - The pair's transport has one owner, and a real command always lands

- Date: 2026-11-21
- Status: accepted
- Private history: `add91d48`
- Superseded by: none

## Context

Three defects shared one question: *which runtime owns the transport right
now, and when does a command take effect?*

1. **The flag each surface writes was hard-coded to the foreground.** While 副音
   owns the controls, the shared surfaces read `MediaPlayer` from the provider,
   which `BackgroundTargetMediaScope` retargets to the secondary engine — but
   the default keyboard scheme, the double-tap / region gestures and the ring
   dial's centre still called `AppStore.updateAutoPlay`. The engine paused, yet
   `bgAutoPlay` stayed `true`: the next 下一首 re-opened the file with
   `autoplay: true` (副音 resumed by itself after a pause), `suspendForFakeCut`
   remembered a run that was not sounding, and the foreground preference was
   rewritten by a command that never touched the foreground. ADR 0017 already
   stated the rule; only the control bars and the PotPlayer executor followed
   it.

2. **A command issued while a file was opening was dropped.** The scope's
   autoplay-sync effect bails on `isInitializing` (the flag is not meaningful
   yet) and nothing re-ran it when the open settled: the scope never listened to
   the engine, and `open()` had captured `autoplay` at dial time. 停止 during a
   slow (WebDAV/FTP) open still started the track; 播放 during it left 副音
   silent with its button showing "playing".

3. **The completion hold (ADR 0017) had no exit for a real pause.** It cleared
   on play / open / stop only, so a pause that interleaved with a completion —
   the user, the 仅当前 boundary, a scrub policy — left the transport mirror
   stood down for the rest of the session. `seek()` even documented that it
   dropped the hold while only clearing the ended latch.

## Decision

- ONE function publishes a user transport command:
  `setActiveTransportFlag` (`player_control_target_scope.dart`). It writes
  `bgAutoPlay` when the pair owns the controls and the foreground preference
  otherwise. Every surface that can run inside the provider override calls it:
  the default keyboard scheme, both gesture layers, the ring dial's centre, the
  two control bars, the PotPlayer executor.
- An open is not a transport decision: on the `isInitializing → settled` EDGE
  the scope re-applies the store's current transport, so a command issued during
  the open still lands. A per-tick apply is deliberately avoided — it would
  fight the completion continuation's own seek/play.
- The completion hold ends on ANY definite transport state: `play`, `pause`,
  `seek`, `stop`, a new `open`. It is not a silence latch.

## Consequences

- 暂停/播放 behaves identically from every surface while 副音 owns the controls,
  and never rewrites the foreground preference.
- A stop is a stop even on a slow source.
- `rules.md` gains GATE-9 / GATE-10 and LOCK-7 is widened to "any definite
  transport state"; `scripts/check-bg-rules.ps1` resolves all three.

## Rejected alternatives

- Let each surface branch on `isBackgroundControlTarget` inline: that is exactly
  how the four call sites drifted apart. One function, one rule.
- Re-apply the transport on every engine notification while settled: it would
  re-issue `play()` on every tick that disagrees, replaying a file the
  continuation had just parked.
- Make the engine keep a `wantPlaying` latch instead of the scope edge: the
  engine has no access to the gate/scope state that decides permission, so the
  decision belongs to the host, not the engine.
