# 0020 - The editor draws and measures the media it actually names

- Date: 2026-11-21
- Status: accepted
- Private history: `84c5c072`
- Superseded by: none

## Context

Three defects in the A/P/B editor, each a disagreement between what the screen
claims and what the code measures.

1. **The timeline section budgeted a row the layout never emits.**
   `kSegmentBgTrackCenter` and `kSegmentTimelineHeight` both added
   `kSegmentBgNameRowHeight + kSegmentGapAfterBgName`, but `_Timeline._build`
   emits only `fg row → gap → bg row`. The bg track centre it published was 22px
   below the real one, so `SegmentLinkPainter` drew the fg↔bg connector, the
   dash-dot and the A/B edge rules under the bg slider, and the section kept a
   blank strip at its bottom — on every edit session.

2. **An empty bg row was still a live scrubber.** With no 副音 file loaded
   (`bgDurMs <= 0`) the row degraded to `value: 0, max: 1` but kept its
   `onChanged`, which projected `value - bgOffsetMs` onto the FOREGROUND axis:
   touching the visibly dead row yanked the video playhead to 0.

3. **A saved row recorded the engine's duration, not its own file's.**
   `toSegment(bgTotalMs: ctx.bgDurMs)` used the LIVE engine duration, while an
   existing segment keeps its own `bgStorageId`/`bgPath` from the DB row.
   Entering the editor from a playhead that is not inside a segment — the engine
   still plays another bg file, or the natural queue — clamped and normalized
   A/B against a foreign duration, so the persisted `bgStartN`/`bgEndN` covered
   the wrong region and the manager overview drew it wrong.

## Decision

- The track-centre and section-height constants describe the column the layout
  actually builds; the two constants for the non-existent name row are gone.
- A bg row with no axis is INERT: `bgRowDragTargetMs` returns null (and the
  slider's callbacks are null, so it also reads as disabled).
- `resolveDraftBgTotalMs` owns the bg total a save records: the engine's
  duration only when the draft names the file the engine holds, otherwise the
  draft's own DB duration, otherwise `null` (unknown beats fabricated).

## Consequences

- The link line, the A/B edge rules and the bg slider share one axis.
- Touching the empty bg row does nothing instead of seeking the video.
- A segment saved while the engine plays something else keeps a correct covered
  window in the manager.
- `rules.md` gains APB-9 / APB-10 / APB-11; `scripts/check-bg-rules.ps1`
  resolves all three.

## Known limitation (kept out of this change)

A silence draft (or any draft with no 副音 file loaded) still cannot drag its
A/B handles on the LINEAR timeline: `SegmentAbpTrack` is a bg-axis widget and
returns nothing when `bgDurMs <= 0`. The ring/dial surface edits the same span
on the foreground axis, so the two surfaces still differ there
(`segment_span_math.dart` calls that a defect). Fixing it needs a foreground-axis
variant of that track — a new interaction, not a one-line correction — and is
recorded here rather than smuggled into this change.
