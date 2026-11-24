# 0007 - Reset one control at a time

- Status: accepted
- Date: 2026-11-22

## Context

The panel had a single "Reset all" action. Clearing one accidental mirror or
one color slider forced the user to lose every other adjustment and set them up
again. A per-item reset is the natural affordance; grouping resets were also
considered.

## Decision

Every adjustable field gets its own reset action, placed as a trailing icon on
its own row (switch, rotation chip row, slider row). The icon is disabled while
that field is already at its default. "Reset all" stays at the bottom.

The store exposes six narrow reset methods (`resetFlipHorizontal`,
`resetFlipVertical`, `resetRotation`, `resetBrightness`, `resetContrast`,
`resetSaturation`). The existing group resets (`resetOrientation`, `resetColor`)
stay available internally but are deliberately NOT shown in the panel: three
reset levels (item / group / all) would be harder to understand than two.

## Consequences

- A single mistaken control can be undone without collateral loss.
- Each reset button must track its own field's default state.
- No new persistence or Drift change.

## Rejected

- Only "Reset all": clearing one field destroyed unrelated adjustments.
- Visible group resets plus item resets plus "Reset all": too many levels.
- A single "Reset..." menu listing items: an extra tap for a common correction.
