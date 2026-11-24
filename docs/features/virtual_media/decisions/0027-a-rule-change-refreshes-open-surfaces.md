# 0027 - A rule change refreshes the surfaces that are already open

- Date: 2026-11-22
- Status: accepted
- Private history: feature work (no single commit)
- Superseded by: none

## Context

The desktop playlist dock is mounted for the whole session. Its data source
re-fetches in place on the content revision (`sourceScanRevision`) only: a plain
`playbackVersion` bump is deliberately ignored there, because every mutating
path that bumps it already fetches explicitly (see
`scenario_queue_scan_refresh_test`).

Virtual-merge mutations only bumped `playbackVersion`. The folder toggle made
the playing video merge immediately (DIR-11) and the player chrome updated — but
the dock kept rendering the pre-change rows: separate files instead of the
merged one, or the reverse, until the user reopened it. On a phone the queue is
built fresh on open, which is why the report was desktop-only. The global
master switch was the only VM path that paired both signals, and its own comment
said so.

A second, smaller gap: after the list re-groups, the follow token (the playing
item's occurrence key) does not change — the physical file did not move — so
"follow the playing item" never scrolled to the row's new element.

## Decision

`VirtualMediaService.notifyRulesChanged` is the single choke point every VM
mutation already goes through (folder toggle, manager rule CRUD, editor save,
quick add, settings import, fake-cut re-derive). It now emits BOTH signals:

1. `bumpPlaybackVersion()` — player chrome, locate caches, merge-group caches;
2. `notifyQueueRefetch()` — the content revision open queue surfaces re-fetch on.

It first calls a late-bound `tagViewRuleChangeRefresher` (installed by
`PlaybackProviderRegistry.init`) so an active tag view re-resolves its snapshot
BEFORE the refetch reads it. The hook avoids a service → playback-layer import
cycle; it is a no-op in tests and early startup.

The queue data source folds a **row identity** into the follow token:

- it resolves which loaded row currently owns the playing occurrence (the same
  matcher the row highlight uses);
- the token is `(occurrence, rowGeneration)`, and the generation moves ONLY when
  an in-place refresh changes that row's identity while it is on the loaded page;
- the first landed fetch only seeds the row key, and a user page change never
  re-derives it.

So a re-group scrolls an open, follow-enabled queue to the playing row's new
element, while a duration backfill, a background scan or manual paging still
never moves the viewport.

## Consequences

- "Use/not use this folder" is visible in the side playlist within one refresh,
  on desktop and phone alike.
- Every VM rule edit costs one page re-fetch of the open queue(s). The refetch is
  in place (same page), and the derived index is already keyed on the VM
  revision, so the re-grouped generation is what gets served.
- The master switch no longer sends the second signal itself; it relies on the
  same choke point.

## Rejected alternatives

- Making the queue data source listen to `playbackVersion` too. That signal's
  other call sites fetch explicitly, so an open queue would resolve twice per
  edit — the reason it was excluded in the first place.
- Re-deriving the follow row on every fetch. Paging away would then read as "the
  row moved" and the auto-locate would drag the reader back to the playing item.
- Scrolling unconditionally from the toggle command. The dock's viewport is
  owned by the generic browser; the token is the contract that already means
  "follow the playing item".
- Calling `TagPlayController.revalidate` from the VM service directly; the tag
  resolver reads the VM service, so that import would close a cycle.
