# 0005 - Activation is explicit; no bound-plan fallback

- Date: 2026-11-23
- Status: accepted
- Private history: feature work (no single commit)
- Supersedes: none
- Superseded by: none

## Context

A video may own several projects. An earlier resolver played "the user's active
plan, otherwise the first bound one", so the merge could play a cut the user had
never opened, and closing a cut did nothing because the fallback was still
bound. The tab and playback disagreed.

## Decision

Only the ACTIVE plan participates. Activating or closing is an admission change:
the cut store re-resolves the live merge before its revision bump reopens the
media. The resolved `planPath` travels with the merged segment, so the opened
EDL and the displayed duration cannot describe two plans. No component may
silently activate a bound plan.

## Consequences

- Closing a cut returns the segment to its source; activating it switches the
  segment to the cut's timeline.
- A bound-but-inactive project never affects playback or the merge.
- The merge side owns its own rules (VM ADR 0037); this ADR owns the on/off
  state and the snapshot hand-off.
