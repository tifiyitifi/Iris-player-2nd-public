# 0021 - A switch keeps its direction, a refresh keeps its track

- Date: 2026-11-21
- Status: accepted
- Private history: `e24d1fd7`
- Superseded by: none

## Context

Three ways a user action landed somewhere other than the place the user pointed
at.

1. **A Virtual Media item switch always stepped 副音 FORWARD.** The VM link
   called `step(forward: true)` for every item change, so 「上一集」 pushed the
   pair onto the next 副音 track — the very defect the foreground queue had
   cured with `isForwardQueueMove` (sparse item ids plus the queue's own move
   stamp). Under `vmSessionActive` the scope observer's own direction logic is
   deliberately off, so nothing else corrected it.

2. **「立即更新」 re-resolved the candidate page around the remembered
   occurrence.** `refresh` → `resolveCandidates()` passed no anchor at all,
   although its own doc says "keeping the current file by key". On a pool larger
   than one page the new window then did not contain the playing file, so
   `replaceQueue` read `currentLeftPool` and did exactly what that latch is for:
   paused the pair and jumped to the remembered entry.

3. **A queue-row tap on a stopRestoreFg run sounded muted.** `markBgExhausted`
   parks the run as terminal; `jumpTo`/`jumpToOccurrence` cleared only the
   queue-end latch, so until the alignment effect happened to land (it needs both
   durations) the duck gate kept the pair inactive — the engine played at volume
   0 with every mirror stood down.

## Decision

- `vmBgStepForward` decides the direction of an item switch: the play queue's
  move stamp wins whenever it describes the current move, else the VM queue
  index decides, else forward (the historical default).
- A refresh anchors on the PLAYING file's index and key, exactly like
  `BgQueueSyncObserver._reconcile` already did for membership writes.
- An explicit row pick clears `bgExhausted` as well as `bgQueueEnded`: it IS the
  re-activation. A system step deliberately does not (ADR 0014 keeps system
  moves and user commands apart).

## Consequences

- 「上一集」/「下一集」 walk the pair in the direction the user moved, in VM
  sessions too.
- A refresh of a large pool keeps 副音 sounding on the current track.
- A row tap after 副音 stopped for good is immediately audible again.
- `rules.md` gains VM-7 / POOL-8 / GATE-11; `scripts/check-bg-rules.ps1`
  resolves all three.

## Known limitation

POOL-8 has no automated test: reproducing it needs a pool larger than one page
(>400 members) resolved through the tag view, which the store tests cannot stage
without a full scenario fixture. The behaviour is pinned by the shared anchor
helper the reconcile path already uses, and the coverage column says so.
