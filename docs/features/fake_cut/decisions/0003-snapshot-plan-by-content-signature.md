# 0003 - An open plays a snapshot plan keyed by content

- Date: 2026-11-23
- Status: accepted
- Private history: feature work (no single commit)
- Supersedes: none
- Superseded by: none

## Context

Activating a plan used to remember the plan object. A user could edit the
`.llc` while the app was open (LosslessCut writes in place); the next open then
replayed the old timeline. Conversely, saving a project with identical ranges
but a new `mtime` should not force a new EDL.

## Decision

`FakeCutSession` is a snapshot of the parsed plan and its content signature.
The EDL and re-timed subtitle cache keys embed `fakeCutPlanSignature(plan)`.
`FakeCutStore.ensurePlanAt` re-reads a project when its `mtime:size` changes; the
content signature decides whether the cached artefact is still valid. A plan
that cannot be read, is empty, or whose source vanished degrades to the
untouched source without throwing out of the open.

## Consequences

- A touched-but-unchanged project reuses the same EDL.
- Only the session that adopted the EDL owns the picture; a remembered plan is
  not a playing cut until `noteCutPlaying` confirms the open.
