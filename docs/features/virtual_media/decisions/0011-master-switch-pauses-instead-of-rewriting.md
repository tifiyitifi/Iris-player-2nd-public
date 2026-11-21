# 0011 - The master switch pauses, it does not rewrite

- Date: 2026-11-21
- Status: accepted
- Private history: `4b617fcb`
- Superseded by: none

## Context

Turning merging off used to disable every rule, so turning it back on could not
restore the previous state. It also re-opened the current file, which restarted
playback.

## Decision

The master switch pauses resolution. Rules are untouched. The current physical
file keeps playing; the live segment is captured as a bookmark; the VM state is
dropped; both re-resolution signals bump. No file is re-opened.

## Consequences

- Off then on restores the same rules.
- The switch is safe to use while a video is playing.
- A settings change never doubles as a playback restart.

## Rejected alternatives

- Writing `enabled = false` to every rule.
- Re-opening the current file to apply the change.
