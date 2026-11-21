# 0019 - A probe write-back reaches the timeline; a refusal supersedes

- Date: 2026-11-21
- Status: accepted
- Private history: `f37fc28c`
- Superseded by: none

## Context

Three defects sat on the queue/timeline boundary rather than in the mirror.

1. **A duration the probe resolved never reached playback.** The probe observer
   writes the duration into `media_nodes`, but the runtime observer's queue read
   (`resolvedBgDurationsByKey`) was memoized on the QUEUE's identity only — and a
   write-back does not change the queue. So `BgQueueTimeline.fullyKnown` and
   `mappingUsableThrough` stayed false for the rest of the session even though
   the queue list (which reads the probe's own verdict sets) showed the rows as
   resolved: cross-file rolls were skipped and every continuation fell back to a
   plain `step`, restarting 副音 at the next file's head while the video kept its
   position.

2. **An empty-uri refusal did not supersede the open it interrupted.** The
   refusal unloaded the runtime but left the generation token alone, so a slower
   open still believed it was current. On media_kit (where a halt is `stop()`,
   not a dispose) that open could finish by dialling its own media — a ghost
   track sounding behind a `file`/`errorText` record that describes the refused
   entry.

3. **A non-looping step read only ONE candidate.** `Repeat.none` returned the
   immediate neighbour, so when that neighbour was the foreground file the
   double-play guard rejected the only candidate and 下一首 did nothing — a dead
   button — even though the entry after it was playable. The wrap modes already
   try two candidates because the guard rejects at most one, and a collision is
   not a queue end (GATE-5).

## Decision

- A finished probe pass bumps `bgDurationResolvedSeq`; the runtime observer keys
  its queue-duration read on it. The timeline therefore re-reads when durations
  can actually have changed, without a queue rebuild.
- A refusal invalidates in-flight opens (`_openGen++`) before unloading: a
  superseded open must never publish initialization, play its media, or rewrite
  the failure record.
- A `Repeat.none` step visits up to two candidates, bounded by the list's ends.
  Running off the end still stops (and still latches the hand-back); skipping a
  collision does not.

## Consequences

- A queue entry the probe resolves mid-session immediately participates in the
  virtual axis: rolls, ceilings and continuations use its real duration.
- The failure the user reads is the one that actually happened.
- 下一首 works at a colliding neighbour under every repeat mode.
- `rules.md` gains ENG-4, ENG-3 is widened, GATE-5's behaviour names the skip;
  `scripts/check-bg-rules.ps1` resolves all three.

## Rejected alternatives

- Bump `bgDurationProbeSeq` (the request seq) on write-back: it means "run a
  pass", and the observer would start another probe for a duration it already
  has.
- Key the read on the probe's verdict sets: it works only because a resolved key
  happens to leave both sets, and it re-reads on every in-flight flag flip.
- Dispose the media_kit player on a refusal (like fvp): it would drop the warm
  instance that `keepWarmPlayer` exists to preserve.
- Let `Repeat.none` wrap: that is the opposite answer (ADR 0014) — running off
  the end must stop, not loop.
