# 0020 - A valid group owns its file

- Date: 2026-11-21
- Status: accepted
- Private history: audit of the current tree (no single commit)
- Superseded by: none

## Context

`failByKey` was a flat `mediaKey → failure` map with no rule dimension.
`partitionVmItems` wrote every member of a failed group into it, including
members that were feasible. A file in one feasible group and one infeasible
group was therefore marked failed. The overlay still collapsed the feasible
group into a merged row, but the planner checked `failByKey` first and refused
to start, so the visible merged row played as a single file.

## Decision

After the valid groups are indexed, every key they own is removed from
`failByKey`. The valid group wins; the failure belongs to the other group's own
members.

## Consequences

- A merged row that is displayed is playable.
- The failed group's unique members keep their yellow mark.
- `failByKey` remains flat; a scope-keyed map is not needed.

## Rejected alternatives

- Adding a rule/scope dimension to `failByKey` (a wider API change for the same
  result).
- Hiding the valid group's row; it would remove a working merge.
