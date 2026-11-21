# Virtual Media - design

## 1. Terms

- **Rule**: a saved selector (`specifiedDir*` or `patternDir*`), an ordering, a
  boundary mode, caps and title tags. Rules are data; the resolver interprets
  them. There is no priority field.
- **Group**: the pure result of one rule over the files it covers. A group is a
  function of the rule plus the covered files, never of the current list order.
- **Virtual item**: a group after chunking, carrying `segments`, `prefixMs`, a
  composed title and a `scopeKey`.
- **Segment**: one real file, identified by `mediaKey = storageId:path` plus an
  `occurrenceIndex` for a duplicated file.
- **Overlay**: the list transform that replaces a group's consecutive rows with
  one row at the earliest member, and reassigns `virtualIndex`.
- **Pin**: a session-scoped freeze of chunk boundaries after a physical delete.
- **Seed**: the position a session starts at inside one segment.

## 2. Slice shape

```
lib/features/virtual_media/
  model/domain/        freezed rule and item models
  model/enum/          match/pattern/boundary/sort/title/drag/dual-time enums
  model/db/            tables, DAOs, repository
  rule/                pure numbering, naming, sorter, title, tick helpers
  resolver/            pure grouping, overlay, stream merge, preflight, resume
  playback/            session plan, controller, backfill, ownership
  scan/                DB duration reader
  service/             scan facade, preflight coordinator, pin, overlay service
  store/               playback store, prefs, bootstrap
  interaction/         facade, controllers, input adapters, drag gate, Sub Audio link
  view/                editor, manager, scrubber marks, merged row pieces, dialogs
  commands/            entry points and master-switch actions
  contributions/       metadata-settings rows under `virtualmedia.*`
```

The resolver is pure and has no player or DB dependency beyond the input it is
handed. The controller owns the session and the feed. The store holds the
current item, segment index and queue; it never holds the anchor.

## 3. Data model

| Table | Key | Holds |
| --- | --- | --- |
| `vm_rules` | `id` | selector JSON, ordering, boundary, caps, exclusion switches, title tags, enabled/pinned |
| `virtual_media_states` | `scopeKey` | last-played segment and local position (legacy/diagnostic) |
| `vm_progress` | `(scenarioId, tagId, scopeKey)` | per-context resume point |

- There are no Drift foreign keys. Cascade cleanup is explicit:
  `deleteRuleCascade` atomically removes the rule, its `vm_progress` rows and its
  anchors (prefix match on `scopeKey`).
- JSON columns (`paths`, `patterns`, `titleTags`) decode defensively; malformed
  input becomes the default. Caps are clamped on read into the hard range.
- Schema history: v16 `virtual_media_states`, v18 `vm_rules` (v2), v19 caps,
  v21 `vm_progress`, v33 indexes, v36 exclusion columns. The derived
  `vm_groups`/`vm_group_members` index lived v39-v44 and was dropped in v45.

## 4. Resolution pipeline

```
rule + covered files
  -> collect (apply overlong exclusion and available filter)
  -> sort (single level, unknown last, natural name)
  -> boundary (sameDirOnly / crossDirMerge / ignoreDirs)
  -> chunk (duration cap and item cap, hard ceilings)
  -> VirtualMediaItem (segments, prefixMs, title, scopeKey)
```

- Overlong exclusion removes only files whose duration is known and strictly
  greater than the threshold. Unknown/zero durations are never excluded; they
  join and degrade at preflight.
- `skipSingleSegment` drops a chunk that ends with one segment.
- Chunk numbering counts chunks, not list rows. Under `sameDirOnly` the counter
  is per directory; otherwise it is per rule. The number is part of `scopeKey`,
  so renumbering changes identity.
- The title is composed from the lit tags in lit order. The title's `seq` is the
  chunk number and is deliberately different from the row's leading position.
- `resolveGroupsForStream` is the only grouping entry point for playback. The
  overlay reads groups and collapses the list.
- Use/exclude polarity (`VmRuleUseMode`): a `notUse` rule never produces items;
  it removes its files from every merge. Per file, four tiers are tried in
  order (`specifiedDir` > `patternDir` > `specifiedDirRecursive` >
  `patternDirRecursive`), first covering tier wins, and `notUse` wins inside a
  tier. The resolver builds `vmEffectiveUseMask` ONLY when an enabled `notUse`
  rule exists — null returns null (fast path). The mask is a `Uint8List` (one
  byte/file, ~0.5 MB at 500k), computed once with tier short-circuiting; the
  per-rule candidate loop indexes it instead of re-matching. Pinned chunks are
  filtered through `vmFileUseState` as well.

## 5. Overlay

- A group always emits exactly one row, placed at its earliest member.
- `vmChildren` is the group's `segments`, so tapping any child opens that
  segment's occurrence, not the first occurrence of the same file.
- The merged row keeps the first member's occurrence identity and replaces the
  display name with the composed title.
- `virtualIndex` is reassigned after collapsing; a row index is a global
  position, not a page row.

## 6. Session lifecycle

A virtual item is played as sequential single-file opens. There is no EDL and no
virtual timeline fed to one decoder; this is a decision, not a missing branch.

- `planVmSessionStart` is shared by a list tap, next/prev, cold start and a tag
  feed. The queue is the displayed merged order across all rules; filtering by
  the current rule would skip rows the reader can see.
- Resume is by file recency (`lastPlayedAt`), not by positional `scopeKey`. A
  completed segment resumes from its head. A 5 s end-safety guard avoids
  resuming on the last frame. A per-context target key overrides recency and
  pins a duplicated occurrence.
- `initialLocalMs` stays `null` when the caller has no seed; `null` means "use
  the legacy file-resume path", not zero.
- Feeds are serialized. A monotonic sequence number drops a stale lookup. An
  in-flight feed owns the timeline, so a fake cut and the Sub Audio overlay stand
  down until it lands.
- A jump uses a write-before-play anchor: the native resume path is steered with
  a targeted intent and a zero restore budget, and a fresh `lastPlayedAt` is
  written. A plain open writes nothing.
- Advance follows the album model: internal segments first, then sibling items;
  wrap only under `Repeat.all`. `Repeat.one` on a multi-segment item replays the
  whole item; a single-segment item defers to the native loop. Infeasible
  siblings are skipped in the same direction. Entering from the back lands on
  the last segment.
- `stop` flushes the anchor and clears this session's progress, queue and
  autoplay. `stopToFirst` parks on segment 0 paused with cleared progress.
  `deactivateForNavigation` leaves queue and autoplay alone and flushes the
  anchor so prev/next can resume.
- `adoptLiveSession` attaches the VM timeline to a feed that is ALREADY open
  (a rule change made the live single mergeable): it writes session state only,
  never re-opens, never touches the queue/autoplay/progress, and refuses when
  the queue moved off that file or a session already owns the timeline. The
  folder toggle calls it through
  `PlaybackProviderRegistry.adoptCurrentFeedAsVirtual`; the tag path
  re-resolves its snapshot first (the cached groups predate the change).
- A stale session is reconciled only while `isActive`. `transitioning` must be
  released first; `releaseOrphanedTransition` handles a transition the queue has
  already left, but leaves a genuine in-flight feed alone.
- A duplicate terminal event for the same segment while feeding or transitioning
  is dropped. Three consecutive segment errors abort with a localized reason.

## 7. Seek and tail

- Ordinary seeks land at `segDur - kSeekTailGuardMs`. Only an explicit finish
  intent (a 100% scrub release or a tail step) may land on `segDur`.
- A tail **step** is finished by the step hook: playing finishes the item,
  paused holds. It is never expressed as a seek, because a seek cannot raise the
  completed state.
- A relative step's base is `virtualBaseMs`, never the current segment's local
  position: the delta must be applied to the virtual axis before mapping back.
- Cross-segment drag defaults to `directSwitch`: each tick may open with the
  intra-segment offset, throttled to one open per 300 ms, and the release commits
  the dropped tail. `previewOnRelease` shows a floating preview and commits once.
  `clampToCurrent` is hidden and degrades to direct.
- A local landing is clamped into the segment before the segment offset is
  added.

## 8. Duration acquisition

The cascade is ordered and each step answers a different question:

1. **DB-only preflight** (blocking, ~1 min budget): read canonical durations in
   batches. A group is feasible only if every segment has a known positive
   duration.
2. **Shell batch scan**: batches of 32, incremental write-back, network segments
   skipped, cancellation honoured between files, partial results kept.
3. **Pseudo-play harvest**: one reused `media_kit` player per scan, per-file
   timeout 20 s, total budget 1 min; failures are recorded, never thrown.

Every step writes through one seam and consumers re-read the DB. The scan facade
therefore ignores scan-reported keys and trusts only the DB. A failed write-back
with no matching row is a failure, not a phantom success. A duration heal bumps
both the playback version and the source-scan revision, because the derived
signature must change too.

A segment whose duration stays unknown after the cascade receives a nominal 60 s
estimated unit for display (the red bar) and is never re-probed in the same
session. The item is rebuilt in place so prefix sums keep the position stable.

## 9. Membership pin

- A desktop physical delete inside a merged item freezes the boundaries of every
  covering rule, not the whole rule.
- The pin holds chunk shapes and removed keys only. Members are re-read from the
  current library by `mediaKey`, so a pinned chunk always carries fresh metadata.
- Infeasible (unknown-duration) groups stay in the pin so their yellow failure
  marks survive.
- A chunk that shrinks to one member stays merged while pinned; a chunk that was
  always single still honours `skipSingleSegment`.
- The freeze lifts on restart, source/scan/duration change, rule change and
  explicit refresh. A management preview resolves with `applyPin: false`.

## 10. Cross-feature boundaries

- **Sub Audio**: the bridge lives on the VM side (`virtual_bg_link.dart`) so
  background playback stays VM-agnostic. The candidate pool is resolved with the
  VM overlay off and is never VM-merged. A switch action is `none` when the pair
  is not applied or when a seek-driven change is already owned by the full lock.
  `wholeVirtual` publishes the virtual identity that was current at activation;
  a saved mapping outranks a rule; tiled overrides are session-only.
- **Fake cut**: a file with a sibling cut project is excluded from merging by an
  injected filesystem criterion, so grouping stays pure. It keeps a single row.
- **Scenario queue**: merged items are excluded from bulk remove/exclude and are
  gated by the `scenario_vm_*` tests. A list tap opens the group the row
  displayed, including its occurrence.
- **Phone dials**: the ring dial honours the same mapping and tick settings.
- **Settings gate**: `DefVisibility.registerPrefix('virtualmedia.', ...)` hides
  the whole settings surface when the gate is off.

## 11. Invariants

- I1: a rule is interpreted, never branched on in playback code; there is no
  priority order.
- I2: a group is a pure function of the rule and the covered files; the list
  order moves the row, never its members.
- I3: a merged row's displayed identity equals the group it plays.
- I4: the title's chunk number is not the row's leading position.
- I5: unknown durations join and degrade; they are never silently dropped.
- I6: the hard ceilings (32 items, 300 minutes) hold even with soft caps off.
- I7: the session queue is the displayed order across all rules.
- I8: resume is by file recency, not by a stored positional index.
- I9: an absent seed stays `null`; it never becomes zero.
- I10: feeds are serialized; a stale answer never lands on a newer item.
- I11: an in-flight feed owns the timeline before `isActive` flips.
- I12: only a finish intent lands on a segment end; ordinary seeks stop at the
  guard.
- I13: a failed duration write-back is a failure, not a success.
- I14: the pin freezes boundaries, not membership snapshots.
- I15: the Sub Audio pool is never VM-merged.
- I16: a file with a sibling cut project never merges.
- I17: the legacy More sheet never executes.
- I18: every schema change has a migration; cascade cleanup is explicit.

## 12. Anti-patterns

- Re-deriving groups from the library snapshot during playback; derive from the
  stream.
- Keying progress or groups by a list index; use `mediaKey` and `scopeKey`.
- Using a seek to finish a tail step.
- Filtering the session queue by the current rule.
- Hiding a group because a duration is unknown instead of degrading it.
- Re-enabling the legacy More sheet.
- Adding a rule priority field.
- Writing a derived group table again without a decision record.
