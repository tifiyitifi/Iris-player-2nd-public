# 0008 - Overlapping segments resolve by activation order

- Date: 2026-09-16
- Status: accepted
- Private history: `d0c91e6c`, `f2dd0787`
- Superseded by: none

## Context

The editor allowed a new segment to overlap an old one. The original runtime
policy (`keepFront`, `keepBack`, `overwrite`) decided at edit time what to do
with the old span, but the runtime still had to pick one segment at a position.

## Decision

v34 adds `isActive` and `activeSeq`. At any foreground position, the active
segment with the highest `activeSeq` wins; ties break on foreground start, then
id. A disabled segment is invisible. `visibleBlocks` slices at every active
edge. The edit-time clip modes remain, but they are about the draft, not the
runtime pick.

## Consequences

- Last activated wins, the same way the user just acted.
- Deactivating the later segment re-exposes the earlier one.
- The overview axis shows the same blocks the runtime plays.

## Rejected alternatives

- Keep the edit-time overlap policy as the runtime rule. It could not express
  "the one I just activated", and it was retired in `f2dd0787`.
