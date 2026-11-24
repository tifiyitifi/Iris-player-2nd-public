# 0002 - The timeline is the plan order, never sorted or de-duplicated

- Date: 2026-11-23
- Status: accepted
- Private history: feature work (no single commit)
- Supersedes: none
- Superseded by: none

## Context

LosslessCut projects legitimately keep ranges out of source order, repeat a
range, or overlap two ranges. Sorting them would change what the user exported;
de-duplicating would drop a repeat that was meant to play twice.

## Decision

`FakeCutSegment` keeps its project `index`, and `FakeCutTimeline` computes cut
positions from prefix sums in that order. `sourceHits(sourceMs)` returns every
containing range in project order; an exact boundary belongs to the later range
only (half-open `[start, end)`). Resume with several hits prompts for a sync
point standalone; in a merge the VM side takes the first hit without a dialog.

## Consequences

- EDL parts, subtitle re-timing, progress mapping and the merged segment's
  mapping all follow one ordered list.
- A removed gap has no hit; resume moves to the next kept range in playback
  order, not source order.
