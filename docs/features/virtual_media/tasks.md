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
- [ ] Wire `FakeCutProjectIndex.invalidate()` into the media-rescan completion
      (and/or the VM re-resolve) so a newly added `.llc` stops merging without
      a manual 简播-tab refresh. The source doc now says this is not wired.

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

## Accepted gaps

Rows whose only coverage is `-:`:

- `GATE-5` - the `DefVisibility` prefix is startup wiring, not a unit.
- `SESS-7` - the null seed belongs to the media progress funnel.
- `UI-4` - the SnackBar ban is a repository convention.
- `MIG-3` - no surviving dedicated fixture for the v45 drop.

File-level `F:` tokens are not gaps; they are a fallback for suites whose test
names are parameterised, and they still prove the file exists.
