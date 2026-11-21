# 0016 - The derived revision follows a duration heal

- Date: 2026-11-21
- Status: accepted
- Private history: `40096a6b`, `7ac1653e`, `e531112d`
- Superseded by: none

## Context

A derived group index was persisted for scalable queues. A duration heal changed
which groups were feasible, but only the playback version was bumped, so the
index kept serving the old signature.

## Decision

A heal bumps the playback version and the source-scan revision. The derived
signature changes with it. The persisted group tables (`vm_groups`,
`vm_group_members`) were later removed in v45; the same rule now governs the
in-memory signature and search.

## Consequences

- A healed duration reaches every consumer.
- Reintroducing a derived table requires a new decision record.
- Scan bookkeeping is not cleared by a heal.

## Rejected alternatives

- Bumping only the playback version.
- Re-scanning the whole source after a heal.
