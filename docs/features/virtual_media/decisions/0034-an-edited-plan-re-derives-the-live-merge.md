# 0034 - An edited cut plan re-derives the live merge

- Date: 2026-11-23
- Status: accepted
- Private history: feature work (no single commit)
- Supersedes: none
- Superseded by: none

## Context

ADR 0032 made activating or closing a cut re-segment the live merge before the
media reopens. Editing the ACTIVE plan is a different event: the `.llc` path does
not change (LosslessCut keeps writing the same project), no store mutation
happens, and the group's `VmCutRange` keeps the span and duration it was built
with. The player, however, always re-reads the project before opening a cut
segment (`FakeCutStore.ensurePlanAt`), so after an edit it plays the NEW EDL
while the merged duration, totals and scrubber still describe the OLD range. A
plan edited into several ranges (or into an unusable file) kept its cut segment
until some unrelated re-resolve happened to run.

## Decision

`VmCutRange` carries the plan's CONTENT signature (`fakeCutPlanSignature` — the
same signature the EDL and remapped-subtitle caches key on). When a merged cut
segment is opened, the opened session's signature is compared with the range's:

| Opened session | Meaning | Action |
| --- | --- | --- |
| signature equal | same plan the group was built with | nothing |
| signature different | plan edited on disk | open the fresh plan, then ask for ONE re-derive |
| null | plan deleted/unusable (or the EDL could not be prepared) | play the source, ask for ONE re-derive |

The request goes to `PlaybackProviderRegistry.refreshLiveVirtualGroups()`, the
same entry point ADR 0032 uses: it re-resolves the live scene/tag groups and
(`VirtualMediaController.resegmentLiveFromGroups`) reshapes the session in place.
It is idempotent — the next group carries the fresh signature, so the following
open asks for nothing.

Content signature, not `mtime:size`: a project that was touched but not changed
must not re-derive anything, and content is what the EDL is built from.

## Consequences

- Editing the active plan mid-session converges on the next open of that
  segment: the picture, the merged duration and the scrubber agree again.
- An edit that makes the plan multi-range/unusable removes the segment from the
  merge on that same re-derive (ADR 0032's admission rules then apply).
- A plan edited while that segment is NOT playing keeps its old displayed
  duration until the segment is opened, the 虚拟剪播 tab is refreshed, or a media
  rescan runs (ADR 0033). Watching the directory is deliberately out of scope.
- The comparison costs nothing per open (both signatures are already computed).

## Rejected alternatives

- Invalidate the group on every open: the derived index would rebuild while
  switching segments, which is exactly the cost the explicit cache exists to
  avoid.
- Compare `mtime:size`: a save with identical ranges would re-derive the live
  session for no visible change.
- A filesystem watcher on every rule directory: unbounded handles and a
  cross-platform notification story for one rare edit.
