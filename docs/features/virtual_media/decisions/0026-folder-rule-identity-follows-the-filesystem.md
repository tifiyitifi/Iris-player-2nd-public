# 0026 - Folder rule identity follows the filesystem

- Date: 2026-11-21
- Status: accepted
- Private history: post-release corner fixes (no single commit)
- Superseded by: none

## Context

The folder toggle looks an existing `specifiedDir` rule up by the video's direct
parent path. That path is stored as the storage-relative form produced by
`relativeToStoragePath`, which preserves the case of the row it came from. On a
case-insensitive filesystem (Windows drive/UNC, SMB) the same directory can be
spelled with different case in different rows or after a rename, and a raw
string comparison treated it as a different folder: the toggle minted a second
rule for the same directory, or missed a real conflict.

## Decision

Rule IDENTITY (find-or-reuse in `vmFindDirRule`, conflict detection in
`vmDirRuleConflicts`) folds case when the backing storage rides a
case-insensitive filesystem, and stays case-sensitive elsewhere. The caller
decides from the storage base paths via `pathRidesCaseInsensitiveFs`; the
helpers take an explicit `caseInsensitive` flag so the decision stays with the
storage, not with the matcher.

This is deliberately limited to de-duplication. The resolver's own coverage
matching (`compiledDirRuleMatchesFile`) keeps its existing semantics, so the
change cannot silently re-scope an existing rule.

## Consequences

- The same Windows/SMB folder can no longer grow duplicate rules, and the
  same-path conflict prompt fires for a case-only spelling difference.
- POSIX, Android SAF (`content://…`) and remote-server paths stay
  case-sensitive, where folding would merge two genuinely distinct folders.

## Rejected alternatives

- Fold case unconditionally in the shared `dirsEqual`: it is also the resolver's
  matcher, and collapsing two distinct POSIX folders there would change
  playback behaviour, not just rule identity.
- Fold case from the relative path alone: the relative path has no drive or
  share prefix, so it cannot tell a case-insensitive volume from a POSIX one.
