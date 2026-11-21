# 0008 - Resume by file recency

- Date: 2026-11-21
- Status: accepted
- Private history: `f3dda394`, `11c27717`
- Superseded by: none

## Context

Resume used a stored segment index inside the chunk. When a file was added or
removed, the chunk re-derived and the index pointed at a different file. A
reader resumed in the wrong place or at the wrong file.

## Decision

Resume chooses the most recently watched file in the group by `lastPlayedAt`.
A per-context target key overrides recency and pins the occurrence. A completed
segment resumes from its head. A 5 s end-safety guard avoids the last frame.

## Consequences

- A re-chunk does not move the resume point.
- A duplicated file resumes its own occurrence.
- The anchor stores `mediaKey`, never a positional index.

## Rejected alternatives

- Storing the display index.
- Storing the chunk number alone.
