# 0031 - A single-range cut may join a merge

- Date: 2026-11-23
- Status: superseded
- Private history: feature work (no single commit)
- Supersedes: 0015
- Superseded by: 0032

## Context

ADR 0015 excluded every video with a sibling `.llc` from merging. Users
reasonably expect their cut videos to merge and play their cuts: dragging three
files from one folder and switching the folder on did not merge when the files
had projects, and closing the cut did not help because the project lives on
disk.

A Virtual Merge is sequential single-file opens, not a muxed timeline, so a
segment MAY open an EDL instead of the source. What the old rule protected was
correct: a merge must not silently ignore the authored cut.

## Decision

A video with a bound `.llc` joins a merge only when it has a usable
**single-range** plan (exactly one kept range with positive length) and the
backend supports the mpv EDL (media_kit). The segment's duration is the kept
range's length and its local offset is a position on the cut timeline.

The plan is chosen deterministically: the user's active plan wins; otherwise the
first bound usable single-range plan in natural name order. Group resolution and
the player use the same rule, so the displayed duration and the opened EDL
describe one plan.

Everything else keeps the old exclusion: multi-range, reordered or repeated
plans, an unusable project, non-local rows, and the fvp backend. Those files
keep their single row.

## Consequences

- Preflight, chunking, the scrubber and merged totals use the cut length.
- Source progress maps through the one range:
  `source = start + local`, `local = source - start`. A source point outside the
  range resumes from the segment head, like a completed file.
- The VM pre-write writes SOURCE milliseconds; the player's cut-aware resume
  maps them back onto the EDL.
- Merging does not activate a plan in the 虚拟剪播 tab: the plan is materialized
  for the segment only.
- Removing the `.llc` restores ordinary merging; a multi-range project leaves
  the file single.

## Rejected alternatives

- Playing the source inside the merge (hides the cut).
- Muxing one EDL for the whole group (turns a sequential-open feature into a
  muxer).
- Supporting multi-range/reordered plans without the cut timeline mapping.
- Falling back to a different plan when the active one cannot merge (silently
  plays a cut the user did not choose).
