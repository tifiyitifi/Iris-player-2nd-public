# 0030 - One notification fan-out per folder action

- Status: accepted
- Date: 2026-11-22

## Context

`toggleVmDirUseMode` must notify rule changes before it adopts the live feed
(the provider resolves merge groups through version/revision-keyed caches). The
manager's `afterMutate` then notified again to reload its own rule list. One
folder click therefore ran the tag-view revalidate and every open-queue refetch
twice (three revalidates in the tag case, because `setVmMasterEnabled` also
revalidates while a session is live).

## Decision

`VmDirToggleResult.notified` reports whether the command already ran
`notifyRulesChanged` successfully. The manager's `afterMutate` takes a
`notify` flag and skips the fan-out when the command did it, while still
bumping the local revision that reloads the rule list.

A failed command (rolled back) or a failed master write did not notify, so the
manager runs the fan-out in those cases.

## Consequences

- One action refreshes the open surfaces once.
- The manager's own list still reloads after every action.
- The result honestly distinguishes "already refreshed" from "not refreshed".

## Rejected

- Removing the command's notification and relying on the manager: adoption runs
  before the manager's callback, so it would read stale merge groups.
- Coalescing inside `notifyRulesChanged`: it is also called for independent
  changes and dropping one would leave a surface stale.

## Follow-up (2026-11-22)

The rule EDITOR has the same single-choke-point shape: `openVmRuleEditor`
notifies once on save. The manager's four editor call sites still followed it
with a default `afterMutate()`, so a save ran the fan-out twice. They now call
`afterMutate(notify: false)` (and `_ManagerCard`'s `onMutated` takes the same
flag): the editor notifies, the manager only reloads its local list. A save is
one fan-out, exactly like a folder action.
