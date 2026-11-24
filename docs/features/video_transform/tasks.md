# Picture adjustment - open work and accepted gaps

## Open

- Device verification of the `M` rows in `testing.md` on Windows and Android,
  both backends.
- media_kit color after a reopen/fullscreen/background round trip: the code now
  re-applies the triple after every `player.open` (VT-21), but the VO-reset
  behaviour still needs a device pass. If a reset survives, re-apply again on
  the first `videoParams`/`position` tick after the open.
- If a media_kit output driver turns out not to support the video-equalizer
  properties, add a `vf`/`lavfi eq` color fallback for the color path only
  (geometry stays on the Flutter surface). Tracked as a potential follow-up,
  not part of the first cut.

## Accepted gaps

- **Session only.** No persistence, no per-file profiles. Deliberate (`D:0002`).
- **Foreground player only.** The independent Sub Audio engine, desktop dock and
  picture-in-picture are not adjusted.
- **Quarter turns only.** No arbitrary-angle rotation, crop, zoom or shear.
- **Color is backend-native.** The saved frame carries color only insofar as the
  backend's own capture includes it; the PNG post-process handles geometry
  only.
- **No kernel shortcut.** The entry is a More menu row; no dedicated key binding
  in this cut.
- **Group resets stay internal.** `resetOrientation` / `resetColor` exist in the
  store but are not shown in the panel; only per-item and Reset all are visible
  (`0007`).
