# 0001 - The picture-fullscreen queue is transient

- Status: accepted
- Date: 2026-11-22

## Context

The picture-fullscreen queue overlay was opened from the control bar's queue
button (or `P`) by toggling a `pinned` flag. `pinned` meant "hover-out must not
conceal it", and the overlay is a widget, not a route, so nothing else could
dismiss it: the pointer could leave the panel, the user could click the middle of
the picture, and the panel stayed. The only exits were `Esc`, the header X, or
the same button — which by then sat underneath the panel.

The windowed dock does not have this problem, because it is a column the user
toggles. The reported Windows behaviour was exactly this asymmetry: "the dock
hides normally with the mouse, the panel opened by the play queue button does
not".

## Decision

A revealed overlay is transient. There is no sticky state:

- the entry `keepPanel` setting only seeds "start revealed";
- the queue key/button toggles reveal/conceal;
- the pointer leaving the panel conceals it (debounced) — including a panel the
  pointer never entered, via the full-screen away watcher;
- a picture click, `Esc`, and the header X conceal it.

## Consequences

- `isFullscreenDockPinned` remains as the entry seed and is cleared by the first
  conceal; it no longer means "cannot be dismissed" (`0002`).
- A panel revealed by `P` with the pointer far from the edge stays until the
  pointer moves, the picture is clicked, or `Esc` — see `tasks.md`.
- The side-by-side dock is unaffected.

## Rejected

- **Keep the sticky pin and only add a click-elsewhere path.** The pointer leave
  would still be dead, which is half of the report.
- **A full-screen tap catcher inside the overlay.** A hit-testable full-screen
  child above the player would swallow the video's hover and pointer events (the
  control bar's hover reveal included). The video's own tap handler already has
  the click; see `0003`.
- **Turn the overlay into a `PopupRoute` with a barrier.** It would bring a
  route transition, a modal barrier and a focus scope into a surface that must
  feel like a dock pinned to the edge.

## Follow-up (2026-11-22)

Two gaps surfaced after the first cut:

- A conceal timer armed just before a hide/re-show survived the re-show and
  closed the panel the user had just opened. The overlay now cancels any pending
  conceal on every transition to `shown`.
- The DEFAULT desktop keyboard scheme is `potplayer`, which routes through
  `PotPlayerKeyExecutor`, not the legacy switch. Its queue action (F6) toggled
  the persisted windowed flag and its Esc left fullscreen directly, so the
  transient panel could not be closed from the keyboard. Both now act on the
  overlay first (F6 reveals/conceals it; Esc closes it before leaving
  fullscreen), matching the legacy scheme.
