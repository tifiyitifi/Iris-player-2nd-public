# Desktop playlist dock - requirements

One EARS requirement per sentence. The register that holds them is `rules.md`.

## Availability

- THE SYSTEM SHALL offer the dock only on desktop, only while the metadata
  stack is ON, and only while the legacy-storage backend is OFF.
- WHEN the dock mode is `dockedRight` and picture fullscreen is off, THE SYSTEM
  SHALL show the queue beside the video, never over it.
- WHEN picture fullscreen is on, THE SYSTEM SHALL show the queue as an overlay
  that occludes the video instead of shrinking it.
- THE SYSTEM SHALL keep the floating popup queue untouched by the dock.

## Windowed dock

- THE SYSTEM SHALL clamp the dock width to the allowed range and at most half
  the available width.
- WHEN the dock is revealed in a window with spare screen space, THE SYSTEM
  SHALL grow the window before it shrinks the video.
- WHEN the dock is hidden, THE SYSTEM SHALL reserve no dock chrome.

## Picture-fullscreen overlay

- WHEN picture fullscreen begins with `keepPanel`, THE SYSTEM SHALL start with
  the overlay revealed.
- WHEN picture fullscreen begins with `hidePanel`, THE SYSTEM SHALL start with
  the overlay hidden and summonable.
- WHEN the pointer enters the right-edge strip, THE SYSTEM SHALL reveal the
  overlay.
- WHEN the pointer leaves the panel plus its hide margin, THE SYSTEM SHALL
  conceal the overlay after a debounce.
- WHEN the pointer moves outside a shown overlay that the pointer never entered
  (a key/button reveal, or the `keepPanel` seed), THE SYSTEM SHALL conceal it.
- WHEN the user clicks the picture while the overlay is shown, THE SYSTEM SHALL
  conceal the overlay and SHALL NOT toggle the control bar with that click.
- WHEN the overlay is hidden, THE SYSTEM SHALL leave the picture click to the
  normal control-bar toggle.
- WHEN the user presses `Esc`, the header X, or the queue key while the overlay
  is shown, THE SYSTEM SHALL conceal it.
- THE SYSTEM SHALL treat the revealed overlay as transient: no reveal path may
  produce a state that only another explicit command can undo.

## Summon strip

- WHILE the overlay is hidden, THE SYSTEM SHALL not summon it while the pointer
  is on the live control bar or inside the reserved isolation band.
- WHILE the overlay is shown, THE SYSTEM SHALL NOT conceal it because the
  pointer crossed the control bar or the isolation band it overlaps.
- WHEN the edge-strip percentage is 0, THE SYSTEM SHALL disable hover summoning
  without breaking the key/button reveal.

## Stability

- THE SYSTEM SHALL keep one persistent hover region, so a conceal can never
  place a fresh region under a stationary pointer.
- WHEN an `onExit` reports a position still inside the hover region, THE SYSTEM
  SHALL treat it as spurious and SHALL NOT conceal.
- WHEN a dialog barrier is raised above the overlay, THE SYSTEM SHALL NOT
  conceal the overlay because of the barrier.
- WHEN the overlay conceals, THE SYSTEM SHALL release its keyboard focus.

## State

- THE SYSTEM SHALL write the overlay's two runtime flags together, so no reader
  can observe a half-open state.
- WHEN picture fullscreen ends, THE SYSTEM SHALL clear both flags.
