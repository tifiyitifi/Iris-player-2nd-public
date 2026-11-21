# 0021 - SAF identity uses the uri key

- Date: 2026-11-21
- Status: accepted
- Private history: audit of the current tree (no single commit)
- Superseded by: none

## Context

A SAF single pick stores an EMPTY `path` and carries its identity in `uri`.
`canonicalMediaKey` already prefers the uri in that case, but two readers rebuilt
keys from the DB path column: the VM duration reader and
`progressForMediaKeys`. A healed duration was therefore never confirmed and a
VM session never resumed such a file.

## Decision

Both readers resolve through `nodesByMediaKeysOrUris` with the segment uris and
rebuild their keys with `canonicalMediaKey(storageId, path, uri: uri)`. The
repository already exposes this lookup specifically for SAF rows.

## Consequences

- A SAF single pick can heal and resume.
- The key form matches every other producer.
- A write-back no-op is not confused with a genuinely shell-empty probe
  (0013).

## Rejected alternatives

- Special-casing `content://` in the caller instead of the shared helper.
- Storing a synthetic path for SAF rows.
