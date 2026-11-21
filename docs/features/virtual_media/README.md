# Virtual Media (virtual merge)

Status: **shipped**, current release line **v2.1.0**; post-release corner fixes are
in progress on the working branch.

Virtual Media turns a rule over real files into virtual items: several files play
as one row, in order, with one composed title, one progress point and one set of
scrubber marks. The files are never rewritten and no archive is produced; the
merge exists only while browsing and playing.

This document says what the reader sees. `spec.md` says what must be true,
`design.md` says how it is built, `rules.md` names the cases that hold it.

## Scope

In scope:

- the rule model: specified directories or name patterns, recursive or not;
- sorting, directory boundaries, chunking and the per-chunk caps;
- derived groups, the list overlay, and merged-row children;
- the playback session: start, resume, feed, advance, repeat, stop, reconcile;
- the seek and tail contract, including cross-segment drag;
- duration acquisition: DB-only preflight, Shell batch scan, pseudo-play harvest;
- the membership pin and the localized physical delete;
- the player UI: rule editor, scrubber marks, dual time, merged totals, errors;
- cross-feature boundaries: Sub Audio, fake cut, scenario queues, phone dials.

Out of scope:

- producing a new file (this is not a cutter or a muxer);
- a virtual timeline or EDL fed to one decoder; playback stays sequential;
- merging the Sub Audio candidate pool through VM rules;
- a rule priority order; overlapping rules are allowed and produce overlapping
  items.

## Version facts

| Fact | Value |
| --- | --- |
| Shipped | incrementally through the v2.0.x line; v2.1.0 adds the player "More" entry and the seamless-merge master switch |
| Current version | `2.1.0` (`pubspec.yaml`) |
| Drift schema | 53; the feature owns v16, v18, v19, v21, v33, v36 |
| Derived index | `vm_groups` / `vm_group_members` existed v39-v44 and were dropped in v45 |
| Availability gate | metadata settings era only (`VirtualMediaGate.enabled`) |
| Platforms | Android, Windows (Linux builds pass CI) |
| Settings namespace | `virtualmedia.*` |
| Persisted state | `vm_rules`, `virtual_media_states`, `vm_progress` + AUX `virtualmedia.*` prefs |

## Reading order

1. `spec.md` - requirements.
2. `design.md` - mechanism and invariants.
3. `rules.md` - the case register.
4. `recurrences.md` - what keeps coming back.
5. `testing.md` - how to prove it.
6. `decisions/` - why, and what was rejected.

## Code map

| Path | Role |
| --- | --- |
| `lib/features/virtual_media/model/` | Freezed rule/state models, enums, Drift tables, DAOs, repository |
| `lib/features/virtual_media/rule/` | pure numbering, naming, sorter, title composer, tick helpers |
| `lib/features/virtual_media/resolver/` | pure grouping, overlay, stream merge, preflight, resume, fake-cut exclusion |
| `lib/features/virtual_media/playback/` | session plan, controller, duration backfill, timeline ownership |
| `lib/features/virtual_media/scan/`, `service/` | DB durations, scan facade, preflight coordinator, pin, overlay service |
| `lib/features/virtual_media/store/` | playback store, prefs, bootstrap defaults |
| `lib/features/virtual_media/interaction/` | facade, controllers, gestures/buttons/sliders, drag gate, Sub Audio bridge |
| `lib/features/virtual_media/view/` | rule editor, manager page, scrubber marks, merged row pieces, dialogs |
| `lib/features/virtual_media/commands/` | sheet/editor entry points, master switch actions |
| `lib/features/virtual_media/contributions/` | metadata-settings rows under `virtualmedia.*` |

The resolver is pure. The controller owns session and feed state. The store
holds the current item, segment index and queue. The anchor never lives in the
store.

## Known limitations

- There is no virtual timeline: a merged item is a sequence of single-file opens
  with graceful degradation, not one decoder over an EDL.
- The derived `vm_groups` index is gone (v45). Search falls back to a full walk.
- The legacy More-menu control center is permanently sealed
  (`VirtualMediaGate.legacySheetEnabled == false`); the file remains as dead code
  and must not be re-enabled.
- `VmCrossSegmentDragStrategy.clampToCurrent` is hidden from settings and degrades
  to direct switching; the name is kept only to avoid a migration.
- A network segment whose duration cannot be probed stays unknown. It joins the
  group and degrades the whole group at playback; it is never silently dropped.
- Rules have no priority. Two rules over one directory produce two items.

## Privacy note

Real libraries, media titles, saved rules and screenshots stay outside the
repository. This document uses stand-in paths only (`C:/work/...`, `a.mp4`,
`USER`).
