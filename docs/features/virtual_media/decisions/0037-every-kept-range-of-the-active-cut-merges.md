# 0037 - Every kept range of the active cut merges

- Date: 2026-11-23
- Status: accepted
- Private history: feature work (no single commit)
- Supersedes: 0032, 0036
- Superseded by: none

## Context

ADR 0032 admitted only a SINGLE-range active plan into a merge and excluded a
multi-range one, because `VmCutRange` mapped one contiguous source window to the
segment's cut timeline. The user asked for Phase 2: a LosslessCut project with
several (possibly reordered, repeated or overlapping) ranges must merge and play
its whole cut, and resuming must stay deterministic without a dialog during
auto-advance.

The standalone cut playback already solves this: `FakeCutTimeline` concatenates
the plan's ranges, maps cut → source by locating the range, and reports every
source hit for a repeated range.

## Decision

`VmCutRange` holds the ORDERED list of kept ranges (`VmCutKeep`) instead of one
window. The segment's `durationMs` is the plan's total cut length, and the
mapping is the concatenated cut timeline:

- **cut → source**: the range the cut position falls in; before the head → the
  first keep's start, at/after the tail → the last keep's end (the same clamps
  the standalone timeline uses).
- **source → cut**: the FIRST keep (plan order) whose half-open window contains
  the source point; null when the point was cut away (the caller resumes from
  the segment head).

First hit is the deliberate, documented policy for repeated/overlapping ranges:
the earliest hit is deterministic, and a merged session auto-advancing into the
segment must never block on a "which occurrence?" dialog (the standalone player
may ask, a merge may not).

Admission follows ADR 0032's active-only rule unchanged — no active plan or an
unusable project merges the source, a backend without EDL merges the source —
but the range COUNT no longer matters, so a usable active plan always merges.

`FakeCutStore.ensurePlanAt` materializes any non-empty plan (it only rejects an
empty/zero-length one), and the player opens exactly that plan.

Because no usable active cut is unrepresentable any more, the folder toggle's
"the cut cannot merge" state (ADR 0036) is deleted, together with its message
key and test.

## Consequences

- Reordered / repeated / overlapping ranges merge; the merged duration is the
  sum of the kept ranges and the scrubber/totals follow it.
- A cut→cut switch while re-grouping now converts through the SOURCE axis: two
  different plans have different cut timelines, so keeping the cut offset would
  land on a different physical point.
- Resuming a repeated range resumes from its first occurrence.
- `VmCutMergeInfo.excludedKeys` (and the cut half of the queue exclusion set) is
  gone: only VM rule exclusions remain.
- The 虚拟剪播 tab's merge notice now says the cut applies "when this file plays
  as a merged segment", not "only single-range plans merge".

## Rejected alternatives

- Keep single-range-only and approximate a multi-range plan by its span: it
  would play audio/video the user cut away.
- Ask the user which occurrence to resume: a merged session resumes during
  auto-advance, where a dialog has no place.
- A separate multi-range mapping type: the standalone timeline already defines
  the semantics the EDL follows, and two implementations would drift.
