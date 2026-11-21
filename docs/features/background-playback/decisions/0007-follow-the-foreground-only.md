# 0007 - Sub Audio follows the foreground; it never drives an episode skip

- Date: 2026-09-12
- Status: accepted
- Private history: `f40b2bdc`, `4117eb37`, `f91b0ed3`, `7a5a54fe`, `34a96c68`, `783c388b`
- Superseded by: none

## Context

The first two-way link fed the background's local position back as a foreground
seek. Under Virtual Media that local position was read as a virtual position,
so the foreground flashed back to the first block. Each fix widened the guard
until the background could start an episode the user never asked for.

## Decision

The background follows the foreground. It never triggers an uncommanded
foreground episode advance. A system seek is latched by a sequence counter.
Seeks mirror only on linked + high. Background-master actions are gated so they
cannot seek the foreground past the window.

## Consequences

- The mirror loops settle: a landing is swallowed instead of mirrored back.
- A drift correction never rewinds the video.
- A limited bidirectional lockstep is allowed only with the swallow latch.

## Rejected alternatives

- A free two-way link. It ping-ponged and produced the VM flash.
- Background-driven episode skips. Forbidden outright.
- Bidirectional high-sync without a latch. It replayed the same bug.
