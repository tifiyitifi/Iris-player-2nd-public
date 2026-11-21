# 0014 - The Sub Audio bridge stays on the VM side

- Date: 2026-11-21
- Status: accepted
- Private history: `4117eb37`, `6afffc08`
- Superseded by: none

## Context

Sub Audio resolves its candidate pool from a tag view. If that view were
VM-merged, the pool would contain virtual items instead of real files and the
alignment mapping would key on the wrong identity. Background playback should not
need to know that Virtual Media exists.

## Decision

The bridge lives in `interaction/controller/virtual_bg_link.dart`. The Sub Audio
pool resolves with the VM overlay off and is never VM-merged. The bridge returns
no switch action when the pair is not applied or when a seek-driven switch is
already owned by the full lock.

## Consequences

- Background playback stays VM-agnostic.
- The mapping key is a real file, not a virtual item.
- `wholeVirtual` pins the identity current at activation; a later item falls
  back; tiled overrides are session-only.

## Rejected alternatives

- Teaching background playback about VM rules.
- VM-merging the candidate pool.
- Letting both a seek and a switch own the same change.
