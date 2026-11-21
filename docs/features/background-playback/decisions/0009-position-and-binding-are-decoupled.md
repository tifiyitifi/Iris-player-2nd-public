# 0009 - Position and binding are decoupled

- Date: 2026-09-14
- Status: accepted
- Private history: `a518fc43`
- Superseded by: none

## Context

Replacing the background file of a segment re-clamped A/B and moved the offset,
so the alignment the user had built was lost. The span and the file are two
different things.

## Decision

Swapping the background file keeps the A/B span and the alignment offset
byte-identical. An uncovered tail is drawn gray instead of being re-clamped.
`MappingBinding.offsetMsOf` and `replaceBgKeepingSpan` own the contract.

## Consequences

- A replacement is a binding change, not a position change.
- The editor can show a gray tail rather than silently shrinking the span.

## Rejected alternatives

- Re-clamp A/B on every replacement. It destroyed the user's alignment and was
  the source of several "the offset moved by itself" reports.
