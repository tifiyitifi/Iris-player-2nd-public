# 0004 - The runtime queue is a bounded, key-anchored window

- Date: 2026-09-15
- Status: accepted
- Private history: `397820e1`, `7fbb0904`, `c8ee84fa`
- Superseded by: none

## Context

A library can hold hundreds of thousands of files. Resolving the whole
candidate stream into memory is not viable, and a queue row index is not a
global position.

## Decision

The runtime queue is one page of the candidate stream: `files`, a global
`start`, and `total`, capped at 400 entries. Navigation works on global indices;
`step` slides the window and re-resolves the page. The window is anchored by
media key, not by a stale index. Conversion happens after the page is sliced.

## Consequences

- A jump far outside the page slides onto the page that contains it.
- A row tap plays the file the view shows at that global position.
- A lock rollover records the position for the next launch.

## Rejected alternatives

- Resolve the whole list. It does not scale and it made the launch slow.
- Index-only anchoring. It broke after a shuffle or a membership change.
