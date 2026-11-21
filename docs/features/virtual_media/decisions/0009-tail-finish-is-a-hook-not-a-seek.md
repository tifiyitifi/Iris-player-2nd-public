# 0009 - A tail finish is a hook, not a seek

- Date: 2026-11-21
- Status: accepted
- Private history: `188c3b31`, `c4f8abb8`, `993cc06c`, `11c27717`
- Superseded by: none

## Context

Pressing next on the last step seeked to the segment end. The seek either rolled
the position back a guard distance or stopped one frame short, so the item never
finished. A later fix made the seek land exactly on the end, which could raise a
completed event twice.

## Decision

Ordinary seeks stop at `segDur - kSeekTailGuardMs`. Only an explicit finish
intent may land on `segDur`. A tail step is finished by the step hook: playing
finishes the item, paused holds without advancing or writing.

## Consequences

- A tail step cannot depend on the decoder's end event.
- A second terminal event for the same segment is dropped.
- The guard is shared by seek, step, scrub release and cross drag.

## Rejected alternatives

- Seeking to the exact end and relying on `completed`.
- Finishing from the UI layer without the hook.
