# 0003 - The picture tap is the "click outside"

- Status: accepted
- Date: 2026-11-22

## Context

A `PopupRoute` gets "click the barrier to dismiss" for free. The
picture-fullscreen queue is a widget stacked above the player, so a click on the
picture reaches the player's own gesture layer, where a single tap normally
toggles the control bar. There is no other place to put an outside click: a
full-screen catcher inside the overlay would have to be hit-testable above the
video and would then swallow hover, the control bar's reveal included.

## Decision

`useGesture().onTap` consults
`shouldDismissFullscreenDockOnVideoTap(overlayEnabled, shown)` before its normal
toggle. When it returns true the tap is spent on `hideFullscreenDock()` and the
chrome is left alone.

## Consequences

- Clicking the picture with the panel out closes the panel and does nothing else;
  the next click toggles the control bar as usual.
- The predicate is pure and testable without the player widget.
- The floating popup keeps its route barrier; this only affects the overlay.

## Rejected

- **Conceal and also toggle the chrome.** One click with two visible effects, and
  the chrome would appear under the panel the user just dismissed.
- **A `GestureDetector` over the player inside the overlay.** Same hover problem
  as `0001`; it also competes in the gesture arena with the video's tap, double
  tap and drag recognizers.
- **A `Listener` that only observes pointer-down.** It would conceal on every
  drag start (seek, volume) as well as on clicks.
