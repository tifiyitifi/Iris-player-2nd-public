# 0033 - A media rescan refreshes the cut-project index

- Date: 2026-11-23
- Status: accepted
- Private history: feature work (no single commit)
- Supersedes: none
- Superseded by: none

## Context

The 虚拟剪播 project index (`FakeCutProjectIndex`) is deliberately an explicit
cache: it lists each directory once and remembers which `.llc` belongs to which
video, because Virtual Merge grouping runs over a whole view on every list
materialization. ADR 0032 made a merge follow the ACTIVE cut, but the index was
only invalidated by the 虚拟剪播 tab's refresh button — so a plan authored (or
deleted) on disk after a group was built kept merging with the previous shape
until that button was pressed. The tab's own copy says "新建虚拟剪播后需刷新",
yet a media rescan already re-lists every directory: the user reasonably expects
a scan to be that refresh.

## Decision

A completed recursive scan announces itself through
`MediaRevisionActions.mediaRescanned(storageIds)`, which:

1. drops the cut-project index (`FakeCutProjectIndex.invalidate()`), then
2. runs the ordinary media-content announce
   (`bumpPlaybackVersion` + `bumpSourceScanRevision`), which also clears the
   `VmMembershipPin`.

The ORDER matters: the index is dropped before the announce, so the re-derive
that the announce triggers already sees the new/deleted project.

The announce is deliberately the MEDIA-CONTENT one, not
`VirtualMediaService.notifyRulesChanged()`: a rescan re-lists the same files, it
does not edit rules. The rule cache and the per-session scan bookkeeping
(`_shellUnsupported`, `_dismissedScanScopes`) must survive, or every scan
re-arms the Windows Shell probe and the scan prompt for files already known.

The index is NOT invalidated per VM resolve (that defeats the cache) and not on
`activate`/`deactivate` (the project SET did not change — ADR 0032 handles the
plan switch).

## Consequences

- Adding a `.llc` and rescanning the source makes the cut participate in merges
  without touching the 虚拟剪播 tab; deleting one makes the file merge as its
  source again.
- A scan now costs one extra directory listing per directory (the next resolve),
  and one extra open-queue re-fetch. Both are bounded by the scan itself.
- A plan EDIT (same path, new content) is still governed by the signature check
  in `FakeCutStore.ensurePlanAt`; the group's duration catches up on the next
  re-resolve. That remaining window is tracked separately.
- A rescan that fails or is stopped before completion does not announce: the
  directory listing that would prove the change may not have happened.

## Rejected alternatives

- Invalidate inside `MediaRevisionActions.mediaNodesChanged`: that funnel also
  runs on a duration write during playback, which would drop a whole library's
  directory cache per played file.
- A TTL on directory listings: the group set would change under the user's feet
  mid-session.
- Reuse `notifyRulesChanged`: it clears the Shell-empty marks and dismissed scan
  prompts for a change that touched no rules.
