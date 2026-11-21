# 0002 - The displayed group is the playback group

- Date: 2026-11-21
- Status: accepted
- Private history: `f3dda394`, `54847044`
- Superseded by: none

## Context

The list showed a merged row built from one resolution while playback built its
queue from another. Tapping the row could open a different file, and the queue
could skip rows the reader could see.

## Decision

The row's identity is the group it displayed. The session queue is the displayed
merged order across all rules, and the start plan targets the tapped group and
segment.

## Consequences

- The tap, the overlay and the session share one derivation.
- A duplicated file is opened by its occurrence, not by key alone.
- Filtering the queue by the current rule is forbidden.

## Rejected alternatives

- Building the queue per rule.
- Re-deriving groups from a library snapshot during playback.
- Keying the session by a list index.
