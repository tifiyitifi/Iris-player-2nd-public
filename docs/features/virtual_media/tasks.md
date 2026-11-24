# Virtual Media - tasks

## Open

- [ ] Replace the file-level `F:` tokens (`vm_resolver_test`, `vm_naming_test`,
      `vm_groups_cache_test`, `vm_search_segment_test`, `vm_playback_plan_test`,
      `vm_relative_seek_test`, `vm_drag_strategy_test`, `vm_duration_backfill_test`,
      `vm_preflight_db_only_test`, `vm_playback_session_fixes_test`,
      `vm_reconcile_stale_session_test`) with literal test names as each suite
      settles on one.
- [ ] Add a dedicated fixture for the v45 derived-index drop; the current row is
      held only by a decision record.
- [ ] Decide whether the phone `M:device checklist#ring` step stays manual or can
      be covered by a golden.
- [ ] Give the sealed legacy sheet a removal decision; it is dead code today.
- [x] Phase 2: admit multi-range / reordered / repeated cut plans into a merge
      (ADR 0037): the segment's timeline is the plan's concatenated cut
      timeline and a repeated/overlapping source point resumes from its first
      hit.
- [x] An end-to-end test drives the real chain (`activate` → registry handler →
      `notifyCutPlanChanged` → `refreshLiveVirtualGroups` → DB-resolved groups →
      resegment) and a spelling-insensitive active-plan match; the actual
      `player.open` still needs one device run.
- [x] An edited active plan re-derives the live merge after the in-flight feed
      settles, with a forced re-resolve that bypasses the scenario-keyed group
      caches (ADR 0038); the e2e test edits the `.llc` while its segment is open.
- [x] A merged cut resume auto-resolves a repeated/overlapping source point to
      its first hit instead of opening the sync dialog (ADR 0037).
- [ ] One device run confirms an edited plan updates the merged duration without
      reopening the media (host tests prove the wiring, not the EDL decode).

## Done

- [x] Rule model, selection, ordering and boundaries.
- [x] Chunking caps, overlong exclusion and one-file merges.
- [x] Derived groups, overlay and merged-row children.
- [x] Session start, resume by recency and occurrence.
- [x] Serialized feeds, advance, repeat and stop scopes.
- [x] Seek, tail step and cross-segment drag.
- [x] DB-only preflight, Shell scan and pseudo-play harvest.
- [x] Membership pin and localized physical delete.
- [x] Sub Audio bridge, fake-cut exclusion and scenario tap parity.
- [x] A single-range 虚拟剪播 plan joins a merge and plays its kept range
      (ADR 0031); multi-range/unusable plans keep the old exclusion.
- [x] A merge follows the ACTIVE cut only (ADR 0032): closing a cut merges the
      source, activating it merges the cut, and a plan change re-segments the
      live session before the reopen.
- [x] A completed media rescan drops the cut-project index and re-derives open
      merges, so an added/removed `.llc` needs no 虚拟剪播 tab refresh (ADR 0033).
- [x] Editing the active plan re-derives the live merge on the next open of that
      segment: the group carries the plan's content signature and a mismatch
      requests one re-resolve (ADR 0034).
- [x] A cut-plan change re-groups with `notifyCutPlanChanged`, so the rule cache
      and the per-session scan bookkeeping survive a toggle (ADR 0035).
- [x] The folder toggle explains an unmergeable active cut instead of promising
      "next play" (ADR 0036).
- [x] Rule editor V2 with the canonical keyboard shell and zero rebuilds.
- [x] Scrubber marks, tick appearance, dual time and merged totals.
- [x] Audit fixes: first-feed recovery, terminal dedupe, overlapping-group
      ownership, SAF uri key, tiled overshoot, timeout remainder and
      shell-empty tagging.
- [x] Direct-folder use/exclude toggle in the More-menu manager, with priority,
      same-path uniqueness, single-playback fallback and the 500k fast path.
- [x] Immediate live adoption: enabling a folder binds the playing video to its
      merged group without reopening it; disabling stops the live merge even
      when it belongs to a recursive rule above the folder.
- [x] Open surfaces follow a rule change: the always-mounted desktop playlist
      dock re-groups in place, an active tag view re-resolves its snapshot
      first, and a follow-enabled queue scrolls to the playing row's new
      element without moving on a plain refresh.
- [x] A paused master switch is visible and explicit: the folder panel says
      merging is paused, "use" asks whether to resume only this folder, resume
      everything or cancel (cancel writes nothing), the prompt's option
      explanation stays collapsed until asked for, and the three choices never
      change shape (the folder-only one is only greyed out when there is
      nothing else to close). The switch shows a resume made by the folder
      action immediately.

## Accepted gaps

Rows whose only coverage is `-:`:

- `GATE-5` - the `DefVisibility` prefix is startup wiring, not a unit.
- `SESS-7` - the null seed belongs to the media progress funnel.
- `UI-4` - the SnackBar ban is a repository convention.
- `MIG-3` - no surviving dedicated fixture for the v45 drop.

File-level `F:` tokens are not gaps; they are a fallback for suites whose test
names are parameterised, and they still prove the file exists.
