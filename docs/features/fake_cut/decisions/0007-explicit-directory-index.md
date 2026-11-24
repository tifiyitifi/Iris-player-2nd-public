# 0007 - The project index is directory-cached and explicitly invalidated

- Date: 2026-11-23
- Status: accepted
- Private history: feature work (no single commit)
- Supersedes: none
- Superseded by: none

## Context

Virtual Merge grouping walks a whole view on every list materialization, and a
folder can hold one `.llc` per episode. Listing each directory on every resolve
would be the only slow part of the pipeline, but a TTL would change the group
set under the user's feet.

## Decision

`FakeCutProjectIndex` caches one Future per directory (a Future so concurrent
resolves share a listing) and is dropped ONLY by an explicit `invalidate()`:
the 虚拟剪播 tab's refresh button or a completed media rescan. A failed listing
is removed from the cache so a transient IO error cannot disable the feature for
the rest of the session.

## Consequences

- A plan created on disk needs one refresh or a rescan to be discovered.
- `activate`/`deactivate` must NOT invalidate: the project set did not change,
  only the active choice did.
- Every new discovery entry point must either share the cached index or call
  `invalidate()`; a private lister would reintroduce the mismatch.
