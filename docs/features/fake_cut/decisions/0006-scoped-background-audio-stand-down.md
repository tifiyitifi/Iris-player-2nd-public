# 0006 - 副音 stands down only for the cut's own file

- Date: 2026-11-23
- Status: accepted
- Private history: feature work (no single commit)
- Supersedes: none
- Superseded by: none

## Context

副音 pauses while a virtual cut owns the picture. Keying that on "some cut is
active" froze the audio of a different file playing in another window, and an
armed-but-not-playing cut froze audio before any EDL had opened.

## Decision

The stand-down is keyed on the physical file whose OPEN adopted the EDL. A
remembered plan, a failed preparation or another file's cut never stands 副音
down; leaving the cut resumes it.

## Consequences

- `noteCutPlaying` is the one signal that arms the stand-down.
- The cut tab explains the stand-down while it applies, not before.
