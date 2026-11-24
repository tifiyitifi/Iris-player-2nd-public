# 0029 - A failed VM write changes nothing and is reported

- Status: accepted
- Date: 2026-11-22

## Context

Two write paths could fail halfway and leave a state that was neither before nor
after:

- "Keep only this folder" disabled the other rules one by one. A failure on the
  second rule left the first disabled, the switch off and the folder rule
  unwritten, and the exception skipped the manager refresh.
- `VmPrefs.setMasterEnabled` swallowed a failed AUX write, so
  `setVmMasterEnabled` invalidated caches and emitted re-resolution signals as
  if the switch had moved. The controlled switch usually snapped back, but the
  user got no explanation.

## Decision

- `disableOtherRulesForKeepOnly` is all-or-nothing: it restores every rule it
  already disabled when one write fails and returns null. The command then
  returns `failed: true` without writing the folder rule; the UI says nothing
  changed.
- `VmPrefs.setMasterEnabled` returns whether the row was written.
  `setVmMasterEnabled` returns false on failure and does nothing else (no cache
  invalidation, no notifications). The switch shows its existing error dialog.
- A folder action whose master write fails returns `masterSaveFailed: true`:
  the folder rule is saved but merging stays paused, and the UI says so.

## Consequences

- A failure leaves the old state or the fully-applied new state, never a mix.
- Failure paths are visible instead of looking like a no-op.
- The rollback loop is unit-testable through the injected `setEnabled`, and
  `VmPrefs.debugFailMasterWrite` exercises the write failure without a broken
  database.

## Rejected

- A single batch DAO transaction: correct too, but the repository has no batch
  method and the rollback keeps the change local to the command.
- Letting the exception escape: the toggle's `onPressed` has no handler, so the
  user would see an unhandled async error and a stale manager.

## Follow-up (2026-11-22)

The original change rolled back only the disable batch. The folder-rule write
that follows it (`setRuleUseMode` / `setRuleEnabled` / `saveRule`) was still
outside any handler, so a failure there left the other rules disabled and the
exception escaped — the same mix the Consequences section forbids.

`disableOtherRulesForKeepOnly` now returns the rules it disabled, and the
command wraps the folder-rule write: on failure it re-enables that batch, puts
a partially-edited folder rule back to its stored polarity/enabled state, and
returns `failed: true`. The whole folder action is now all-or-nothing, not just
its first batch. `debugFailFolderRuleWrite` exercises the path without a broken
database.
