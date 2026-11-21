# 0004 - Keep the title number distinct from the row position

- Date: 2026-11-21
- Status: accepted
- Private history: `7635f2f7`
- Supersedes: 0003
- Superseded by: none

## Context

`0dd5c947` changed the title number to the queue position but also dropped the
per-directory chunk scope. The list's leading number and the title's number are
two different things: one is a slot, the other is the chunk's identity.

## Decision

The leading column keeps counting list slots. The title's `seq` keeps counting
chunks and stays part of the scope key. Under `sameDirOnly` the chunk counter is
per directory; otherwise it is per rule.

## Consequences

- A title number may repeat across directories; that is correct.
- Renumbering a chunk changes its identity, so progress and anchors follow.
- The two numbers must never be collapsed into one field.

## Rejected alternatives

- One number with two meanings.
- Removing the chunk number from the title.
