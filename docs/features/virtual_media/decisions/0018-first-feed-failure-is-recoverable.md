# 0018 - A failed first feed is recoverable

- Date: 2026-11-21
- Status: accepted
- Private history: audit of the current tree (no single commit)
- Superseded by: none

## Context

`handleSegmentError` gated on `isActive`, and `isActive` requires the play
queue's current file to equal `_expectedSegmentKey`. That key is only assigned
after a successful feed. If the FIRST feed of a session failed (node row gone,
lookup threw, queue push failed), the handler returned false, no error was
shown, and `transitioning` stayed set for ever. VM kept owning the timeline, so
the player froze with no recovery short of leaving the screen.

## Decision

A feed failure raised by `_doFeedCurrent` itself is reported with
`handleSegmentError(fromFeed: true)`. It bypasses the `isActive` gate (the first
feed has no expected key yet) and the terminal dedupe (the guard may still
belong to the previous segment). Superseded feeds check `seq == _feedSeq` before
reporting.

## Consequences

- The first broken segment is skipped, or the session ends with a visible
  localized error.
- `transitioning` is released by the same recovery path.
- A stale feed cannot act on a newer session.

## Rejected alternatives

- Pre-seeding `_expectedSegmentKey` before the feed lands; it would claim
  liveness before the queue carries the file.
- Clearing `transitioning` in `reconcileStaleSession`; it would race a
  legitimate switch.
