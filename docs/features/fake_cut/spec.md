# Virtual Cut - specification

One EARS requirement per sentence. `rules.md` binds each to literal tests.

### FR-1 - Bind a project to its video

WHEN the 虚拟剪播 tab inspects a local video, THE SYSTEM SHALL find sibling
`.llc` files that name that video in their recorded `mediaFileName` and SHALL
fall back to the project stem only when that name is unreadable.

Rules: `FC-01`, `FC-02`.

### FR-2 - Cache the directory listing explicitly

WHEN a directory's projects are listed, THE SYSTEM SHALL cache the result and
SHALL drop it only on an explicit invalidate (the tab's refresh or a completed
media rescan); a failed listing SHALL NOT be cached as "no projects".

Rules: `FC-03`.

### FR-3 - Parse a LosslessCut project

WHEN a `.llc` file is read, THE SYSTEM SHALL accept LosslessCut JSON5 versions
1/2/3 with numeric or timecode ranges, SHALL treat a segment without `end` as a
marker, and SHALL report an invalid file without throwing.

Rules: `FC-04`.

### FR-4 - Build a playable plan

WHEN a project is built, THE SYSTEM SHALL drop markers, deselected and invalid
ranges, clamp ranges past the source duration, keep the remaining ranges in
PROJECT order without sorting or de-duplicating them, and SHALL surface each
tradeoff as a localized notice.

Rules: `FC-05`, `FC-15`.

### FR-5 - Map the cut timeline

WHEN a cut position is converted to source time, THE SYSTEM SHALL locate the
range containing it on the concatenated timeline; WHEN several ranges play one
source point, THE SYSTEM SHALL report all hits in project order.

Rules: `FC-06`.

### FR-6 - Open one EDL snapshot

WHEN a plan is played, THE SYSTEM SHALL generate one EDL whose parts reference
the same source file and SHALL key the cached artefact on the plan's content
signature, so an edited project can never replay an old timeline.

Rules: `FC-07`, `FC-09`.

### FR-7 - Resolve an open defensively

WHEN a remembered plan cannot be read, is empty, or its source is unreadable,
THE SYSTEM SHALL play the untouched source instead of aborting the open.

Rules: `FC-08`.

### FR-8 - Activate explicitly

WHEN the user activates a plan, THE SYSTEM SHALL play that plan for the file;
WHEN the user closes it, THE SYSTEM SHALL play the source; a bound-but-inactive
project SHALL NOT be played by the merge.

Rules: `FC-10`.

### FR-9 - Resume from source progress

WHEN saved progress falls in exactly one kept range, THE SYSTEM SHALL resume at
the corresponding cut position; WHEN it falls in several ranges, THE SYSTEM
SHALL ask for a sync point; WHEN it falls in a removed gap, THE SYSTEM SHALL
resume at the next kept range in project order.

Rules: `FC-11`.

### FR-10 - Gate on the backend

WHEN the backend is fvp, THE SYSTEM SHALL block standalone 虚拟剪播 with an
explanatory message and SHALL let a merged file play its source instead.

Rules: `FC-12`.

### FR-11 - Coexist with 副音 and subtitles

WHEN a cut is opened, THE SYSTEM SHALL stand 副音 down only for that file while
the EDL is playing, and SHALL re-time external subtitle cues to the cut
timeline; a cue that cannot be re-timed SHALL NOT be emitted with source timing.

Rules: `FC-13`, `FC-14`.
