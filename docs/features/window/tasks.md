# Desktop playlist dock - open work and accepted gaps

## Open

- Device verification of the `M` rows in `testing.md` on Windows, both
  control-bar shapes.
- The away watcher conceals on pointer MOVEMENT only. A panel revealed by the
  queue key while the pointer sits perfectly still therefore stays until the
  next move, a picture click, `Esc` or the X. Polling the pointer to close a panel
  under a motionless cursor is deliberately not done; if this turns out to be the
  reported behaviour, add a "conceal when the panel is revealed and the pointer
  is already outside" check driven by the strip's live pointer state.
- The dock width clamp (`clampPlaylistPanelWidth`) has no executable test
  (DOCK-4). Its two consumers (layout and window-resize math) are covered only by
  the device round trip.

## Accepted gaps

- **Two flags, one meaning.** `isFullscreenDockPinned` survives in the state as
  the entry seed; it is no longer a sticky pin. Renaming it would be a Freezed
  change with no behavioural gain (`D:0002`).
- **No overlay route.** The overlay is a widget sibling of the player, not a
  `PopupRoute`: it must not own the keyboard, dim the video or animate a barrier.
- **Desktop only.** Android and iOS never mount the dock; the phone queue is the
  full-page scenario browser.
- **The floating popup is untouched.** `PlaylistPanelMode.popup` still uses the
  `PopupRoute` with its own tap-outside dismissal.
