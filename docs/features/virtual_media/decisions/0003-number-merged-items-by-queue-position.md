# 0003 - Number merged items by queue position

- Date: 2026-11-21
- Status: superseded by 0004
- Private history: `0dd5c947`
- Superseded by: 0004

## Context

The title showed the rule's chunk number, which restarted per directory. In a
long cross-directory list the visible numbers repeated, and readers read them as
queue positions.

## Decision

The title's number was changed to the queue position, and chunk numbers were
made to run across rules instead of per directory.

## Consequences

- The title number matched the visible list position.
- The chunk number lost its per-directory scope, which broke `sameDirOnly`
  identity and changed `scopeKey` for re-chunked directories.

## Rejected alternatives

- Keeping both numbers in one field.

## Superseded

The display half was right and the identity half was wrong. See 0004.
