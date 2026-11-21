# 0005 - Chunk caps have hard ceilings

- Date: 2026-11-21
- Status: accepted
- Private history: `53e9a4a1`, `61d02592`
- Superseded by: none

## Context

A rule with both cap switches off produced one item over an unbounded directory.
Opening it built a queue of thousands of files, and the session took minutes to
plan.

## Decision

At least one cap is required at save time. Independently of the switches, a
chunk is hard-capped at 32 items and 300 minutes.

## Consequences

- A rule cannot produce an unbounded item.
- A single file longer than the ceiling is not split; the cap chooses items, not
  file content.
- The editor rejects a save with both switches off.

## Rejected alternatives

- Allowing both caps off with a warning.
- Splitting a file to honour the duration cap.
