# 0013 - Progress lock has two axes

- Date: 2026-09-11
- Status: accepted
- Private history: `a8dc6d30`, `783c388b`
- Superseded by: none

## Context

The progress lock started as one value that meant "follow the foreground".
Users wanted to follow the picture without following the seek, and to follow
transport without following the position. One value could not say both.

## Decision

Two axes:

- `BgSeekLink`: `linked` or `independent`.
- `BgLockLevel`: `high` (seek and transport) or `low` (play/pause only).

Discrete steps have their own mode: `swapOnly` (default) or `followLink`. A
legacy `progressLock` value migrates onto these axes.

## Consequences

- `independent` shares nothing; `low` keeps play/pause but frees seeks; `high`
  mirrors both.
- A scrub drag and a system seek each have their own policy.

## Rejected alternatives

- One boolean, or a three-value enum. Neither could express "transport but not
  position", and the migration would have lost the distinction.
