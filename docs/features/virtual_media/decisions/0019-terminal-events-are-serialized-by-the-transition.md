# 0019 - Terminal events are serialized by the transition

- Date: 2026-11-21
- Status: accepted
- Private history: audit of the current tree (no single commit)
- Superseded by: none

## Context

The dedupe guard compared a key built from the CURRENT `segmentIndex`. But
`advance()` moves `segmentIndex` synchronously before the new feed lands. An
error→advance followed by the same physical file's `completed` therefore
computed a key for the NEW segment, looked different, and was not dropped. The
second event advanced again and skipped a healthy segment.

## Decision

While a terminal event is already driving a transition or feed, ANY further
terminal event is a duplicate. The guard does not compare event identity,
because the identity is state-derived and the state has already moved. A
legitimate completion of the newly fed segment cannot occur inside that window:
the window ends when the feed lands.

## Consequences

- One terminal event drives one transition.
- Feed-internal failures are the exception and report through
  `handleSegmentError(fromFeed: true)` (0018).

## Rejected alternatives

- Comparing `mediaKey` only; a duplicated occurrence would over-drop.
- Freezing `segmentIndex` during the feed; it would break the post-feed plan.
