# 0006 - The entry lives in the More menu

- Status: accepted
- Date: 2026-11-22

## Context

The player's primary control bar is space-constrained and every slot competes
for a finger. Picture adjustment (mirror/rotation/color) is a low-frequency
viewing adjustment, used occasionally and often not at all. The More menu is
instantiated by both the modern bar and the legacy bar, so one entry there covers
every layout.

## Decision

The entry is a single More-menu row, "画面调整", opening the panel in the usual
popup host (`showPopup`). No `ControlBarSlot` is added.

## Consequences

- No layout files change; both bars get the entry for free.
- The row must not read stores inside `itemBuilder` (the menu's existing
  select-free constraint); the current row needs no state, so it has no badge.
- Same reasoning as the earlier move of seek-step from the bar into More.

## Rejected

- A dedicated control-bar slot: occupies scarce space for a rare action.
- A settings-page entry: it is not a persisted preference (`0002`).
