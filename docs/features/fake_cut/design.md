# Virtual Cut - design

## Mechanism

1. **Discovery.** `FakeCutProjectIndex` lists a directory once and remembers
   each `.llc`'s `mediaFileName`; `FakeCutPairing` binds projects to videos
   (recorded name first, stem fallback, case-insensitive on Windows). A failed
   listing is dropped from the cache so one IO blip cannot disable the feature
   for the session. `invalidate()` is explicit: tab refresh or a completed media
   rescan.
2. **Parse.** `LLCParser` + `Json5Light` read the project shape (v1/v2/v3,
   seconds or `HH:MM:SS.mmm` timecodes). `FakeCutPlanBuilder` applies
   LosslessCut's product rules: markers ignored, deselected ignored (with the
   all-deselected fallback), invalid and too-short ranges dropped/flagged,
   past-the-end ranges clamped and flagged, and a mismatch notice when the
   recorded source name differs from the playing file.
3. **Plan.** `FakeCutPlan` holds segments in PROJECT order and a
   `FakeCutTimeline`: prefix sums of the kept durations give the virtual start
   of each part; `sourceHits(sourceMs)` returns every containing range in plan
   order; `nextFakeStartAfterSource` handles a saved point in a removed gap.
   Ordering is never sorted or de-duplicated: reordered, repeated and
   overlapping ranges are legitimate LosslessCut exports.
4. **Open.** `FakeCutStore.activate` materializes the plan against the duration
   known now and stores it with the project's `mtime:size` signature. The player
   opens `FakeCutSession.edlPath`, a generated mpv EDL with one part per kept
   range. The cache key includes the plan's CONTENT signature, so a project
   touched with identical ranges still reuses the EDL while a real edit does not.
5. **Progress.** The session is a snapshot: every progress write maps its cut
   position back through `plan.timeline.toSourceMs` before touching
   `media_nodes.duration_ms`/progress. The DB column always holds SOURCE time.
6. **Resume.** `FakeCutResume.resolve` maps saved source progress through the
   timeline: one hit → that cut position; several hits → an explicit sync-point
   prompt (standalone only); zero hits → the next kept range in playback order.
7. **Coexistence.** `FakeCutPreflight` blocks fvp, remote/SAF and non-video
   rows. 副音 stands down only while this file's EDL is the open session. In a
   merged group the play layer uses `VmCutRange` (which mirrors
   `FakeCutTimeline`) and opens exactly `cutRange.planPath`; the merge's own
   rules live in `../virtual_media/`.

## Data model

| Value | Fields | Lifetime |
| --- | --- | --- |
| `LlcSibling` | project path + recorded media file name | directory cache |
| `FakeCutPlanSource` | path, `mtime:size` signature, parsed plan, bound flag | one discovery pass |
| `FakeCutSegment` | index, `startMs`, `endMs`, name | one plan |
| `FakeCutPlan` | ordered segments, notices, timeline, content signature | open + active store state |
| `FakeCutSession` | plan, edlPath, source duration, content signature | one player open |
| active state | `mediaKey → (path, plan, path signature)` | secure KV, across restarts |

## Invariants

- The source file is never written; only generated EDL/subtitle artefacts are.
- `media_nodes.duration_ms` and progress are always SOURCE milliseconds.
- Plan segment order is project order, never sorted or de-duplicated.
- An unreadable/invalid project degrades to the source, never to an exception
  out of `player.init`.
- A remembered plan is not a playing cut: `noteCutPlaying` is the only thing
  that marks the EDL as actually owning the picture.
- Activation is explicit; no component silently activates a bound plan.
- The plan opened by the player is the one the UI/merge displayed (path AND
  content signature), or the feature falls back to the source.
- User-facing text is localized and a blocked reason always has its own line.
