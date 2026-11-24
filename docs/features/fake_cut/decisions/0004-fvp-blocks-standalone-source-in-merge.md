# 0004 - fvp blocks standalone cutting; a merge plays the source

- Date: 2026-11-23
- Status: accepted
- Private history: feature work (no single commit)
- Supersedes: none
- Superseded by: none

## Context

The EDL is mpv's native format; fvp has no equivalent and would need its own
seek/completed/loop adapter. Offering a plan there produced a black screen or
source playback with a cut-looking scrubber.

## Decision

`FakeCutPreflight` blocks standalone 虚拟剪播 on fvp with a localized reason.
Virtual Merge does NOT exclude such a file: its segment plays the source, which
is what standalone playback does there too (see the VM register, ADR 0037).

## Consequences

- Preflight is a single choke point for backend, storage type and media type.
- The blocked reason has its own localized line; cutting is never silently
  ignored.
