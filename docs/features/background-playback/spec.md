# Background playback - specification

Requirements only. `design.md` holds the mechanism; `rules.md` maps each
requirement to the cases that hold it.

## Glossary

| Term | Meaning |
| --- | --- |
| Sub Audio (副音) | the second, independent engine that plays a different real video's audio |
| foreground | the primary video and its player |
| control target | which engine the shared controls, gestures and shortcuts drive |
| candidate pool | the active membership view of the reserved tag, resolved with the VM overlay off |
| window | one bounded page of the candidate stream, plus its global position |
| mapping timeline | saved segments over foreground milliseconds, each binding a background file or silence |
| A/P/B | the segment start, the alignment offset, and the segment end |
| alignment | the anchor pair that maps a foreground position to a background position |

## Requirements

Each requirement is one observable behaviour. The acceptance criterion is
`WHEN <trigger>, THE SYSTEM SHALL <response>`; the `Rules:` line names the
register rows that hold it.

### FR-1 - A second, independent engine

WHEN Sub Audio is enabled, THE SYSTEM SHALL play the background file in a
process-wide engine that does not share transport, Virtual Media state, history
or progress writes with the foreground player.

Rules: `ENG-1`, `ENG-2`.

### FR-2 - Re-targetable controls

WHEN the control target is the background, THE SYSTEM SHALL drive that engine
with the same controls, gestures and shortcuts and SHALL mark the control bar
with the background frame.

Rules: `ENG-2`, `GATE-4`.

### FR-3 - Three independent axes

THE SYSTEM SHALL keep the subsystem switch (`enabled`), the user's gate
(`gateOpen`) and the apply scope separate, and SHALL treat a pair as in effect
only when all three allow it.

Rules: `GATE-1`, `GATE-2`, `GATE-3`.

### FR-4 - Candidate pool

WHEN the pool is resolved, THE SYSTEM SHALL read the reserved tag view with the
Virtual Media overlay off, keep the foreground file in the membership, and
exclude it only at selection time.

Rules: `POOL-1`, `POOL-2`, `POOL-5`.

### FR-5 - Bounded window queue

WHEN the runtime queue is built, THE SYSTEM SHALL resolve one bounded window of
the candidate stream, anchor it by media key, and step by global position.

Rules: `POOL-3`, `POOL-4`.

### FR-6 - Mapping timeline

WHEN a foreground position is covered by saved segments, THE SYSTEM SHALL play
the active segment with the highest activation order; a disabled segment SHALL
be invisible.

Rules: `MAP-1`, `MAP-2`.

### FR-7 - A/P/B editor

WHEN the editor moves the playhead handle, THE SYSTEM SHALL change the
alignment offset and leave the A/B span unchanged; it SHALL freeze transport
while the editor is open.

Rules: `APB-1`, `APB-2`, `APB-4`.

### FR-8 - Automatic alignment

WHEN a background file first opens, THE SYSTEM SHALL derive the anchor from the
two real durations and SHALL NOT persist a default alignment mode.

Rules: `ALIGN-1`, `ALIGN-2`.

### FR-9 - Two-axis progress lock

THE SYSTEM SHALL treat the seek link and the lock level as separate axes, and
SHALL mirror transport and position only on the combinations the policy allows.

Rules: `LOCK-1`, `LOCK-2`, `LOCK-3`.

### FR-10 - Cross-video switches and the VM boundary

THE SYSTEM SHALL keep the list-item switch and the Virtual Media segment switch
independent, and SHALL NOT merge the candidate pool through Virtual Media rules.

Rules: `VM-1`, `VM-2`, `VM-3`.

### FR-11 - Volume ducking

WHEN the pair is active, THE SYSTEM SHALL scale the foreground and the
background by their own percentages of one master, with independent mutes.

Rules: `VOL-1`, `VOL-2`.

### FR-12 - Fake cut coexistence

WHEN a fake cut owns the current media, THE SYSTEM SHALL pause Sub Audio for
that media under every scope and SHALL resume it only if it was sounding.

Rules: `CUT-1`, `CUT-2`.

## Non-goals

- A second video window or a second history writer.
- Writing shuffle order into the shared tag view.
- Persisting an alignment mode as a default.
- Driving an uncommanded foreground episode skip from the background.
- Fabricating a duration when a probe fails.
