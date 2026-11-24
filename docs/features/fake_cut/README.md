# Virtual Cut (虚拟剪播)

Status: **shipped**; the merge interaction documented here is in progress on
the working branch (v2.1.x).

虚拟剪播 plays a LosslessCut `.llc` project over a video without touching the
source file. Open a video, go to the 虚拟剪播 tab, pick one of its projects and
activate it: playback follows the kept ranges instead of the whole file, the
scrubber and the dual-time rows use the cut timeline, and external subtitles are
re-timed to it. A project can be closed again to return to the untouched source.

This document says what the reader sees. `spec.md` says what must be true,
`design.md` says how it is built, `rules.md` names the cases that hold it.

## Scope

In scope:

- discover `.llc` siblings of a local video and bind them to the video they name;
- parse LosslessCut JSON5 projects (v1 numeric seconds, v2/v3 timecodes), with
  markers, deselected ranges, clamping and notices;
- build one EDL over the kept ranges, in project order, with reordered,
  repeated and overlapping ranges preserved;
- activate / close a plan for the playing file; cache the generated EDL by
  content signature;
- resume from source-millisecond progress (ask when several ranges contain the
  saved point);
- re-time external subtitles to the cut timeline;
- coexist with 副音 (it stands down for the cut's own file) and with Virtual
  Merge (an active plan becomes one merged segment, see
  `../virtual_media/README.md` and ADR 0037 there).

Out of scope:

- editing or writing `.llc` files (LosslessCut owns the project);
- fvp playback (no EDL there: standalone is blocked, a merge plays the source);
- remote / SAF siblings (no filesystem sibling access through this path);
- cutting the media itself; the source file is never modified;
- a project bound to another video (it is shown as unmatched, never activated).

## Version facts

| Fact | Value |
| --- | --- |
| Shipped in | standalone cut in v2.1.0; every kept range joins Virtual Merge in v2.1.2 |
| Platforms | Android, Windows (CI also emits Linux-compatible builds) |
| Backends | media_kit (mpv EDL) only; fvp blocked |
| Project format | LosslessCut `.llc`, JSON5, versions 1/2/3 |
| Persisted state | active plan paths + content signatures (secure KV) |
| Generated artefacts | `.edl` and re-timed subtitles under the app temp cache, keyed by signature |
| Drift schema | unchanged; no feature tables |
| Settings namespace | none (no meta-setting; the 虚拟剪播 tab is the UI) |
| Code generation | none (plain immutable classes, no Freezed/Drift here) |

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
| `lib/features/fake_cut/services/json5_light.dart`, `llc_parser.dart` | LosslessCut JSON5 / timecode parsing |
| `lib/features/fake_cut/services/fake_cut_plan_builder.dart` | raw project → playable plan (markers, deselect, clamp, notices) |
| `lib/features/fake_cut/model/domain/fake_cut_plan.dart`, `fake_cut_segment.dart`, `fake_cut_timeline.dart` | plan, ranges and the cut↔source prefix-sum map |
| `lib/features/fake_cut/services/fake_cut_pairing.dart` | which `.llc` belongs to which video in a folder |
| `lib/features/fake_cut/services/fake_cut_project_index.dart` | per-directory project cache, explicit invalidation |
| `lib/features/fake_cut/services/fake_cut_discovery.dart` | list/read sibling projects, `mtime:size` signature |
| `lib/features/fake_cut/store/use_fake_cut_store.dart` | active plans, activation, snapshot plan for a merged segment |
| `lib/features/fake_cut/playback/fake_cut_session.dart`, `services/fake_cut_edl_builder.dart` | EDL preparation and the opened-session snapshot |
| `lib/features/fake_cut/services/fake_cut_subtitle_remapper.dart` | external subtitle re-timing |
| `lib/features/fake_cut/core/fake_cut_preflight.dart` | backend / storage / media-type gating |
| `lib/features/fake_cut/core/fake_cut_background_scope.dart` | 副音 stand-down scoped to the cut's file |
| `lib/features/fake_cut/view/fake_cut_tab.dart`, `fake_cut_texts.dart` | the player tab, refresh and localized notices |
| `lib/features/fake_cut/model/domain/fake_cut_resume.dart` | source → cut resume policy |
| `lib/hooks/player/use_media_kit_player.dart` | opens `session.edlPath`, maps progress back to source |
| `lib/features/virtual_media/resolver/vm_fake_cut_exclusions.dart` | the merge's admission of an active plan |

## Neighbouring behaviours

- The merge layer owns the group timeline; this feature only supplies the plan.
  See `../virtual_media/decisions/0037-every-kept-range-of-the-active-cut-merges.md`.
- A newly added/removed `.llc` is picked up by the tab's refresh button or a
  completed media rescan (ADR 0007); editing an existing project is picked up on
  the next open via its content signature (ADR 0003).
- Progress in `media_nodes` always stays in SOURCE milliseconds.
