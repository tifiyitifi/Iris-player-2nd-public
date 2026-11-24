# 0015 - A fake cut excludes by sibling project file

- Date: 2026-11-21
- Status: superseded
- Private history: `1b0b2f50`
- Superseded by: 0031

## Context

A fake cut plays a file through a saved segment plan. If that file merged into a
virtual item, the cut and the merge would both own the timeline. The cut project
lives next to the media.

## Decision

A file with a sibling cut project is excluded from merging and keeps its single
row. The filesystem check is injected into grouping so the resolver stays pure;
non-local rows never resolve a project.

## Consequences

- The cut and the merge never compete for one file.
- Grouping remains testable without a filesystem.
- Excluding every member drops the group; one member follows
  `skipSingleSegment`.

## Rejected alternatives

- Pausing the merge at playback time.
- Merging and letting the cut win the transport.
