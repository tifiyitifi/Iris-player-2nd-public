# Desktop playlist dock - testing

## Gate table

| Gate | Command | Device |
| --- | --- | --- |
| Pure resolvers | `flutter test test/fullscreen_dock_overlay_resolve_test.dart test/playlist_dock_vertical_test.dart test/control_bar_isolation_zone_test.dart` | none |
| Overlay behaviour | `flutter test test/fullscreen_playlist_dock_overlay_test.dart test/fullscreen_playlist_dock_overlay_stability_test.dart test/fullscreen_dock_control_bar_exclusion_test.dart` | none |
| Dismissal + state seam | `flutter test test/fullscreen_dock_video_tap_dismiss_test.dart test/fullscreen_dock_toggle_seam_test.dart` | none |
| Rule register | `pwsh -NoProfile -File scripts/check-window-rules.ps1` | none |
| Analyzer | `flutter analyze` | none |
| Full suite | `flutter test` | none |

## What each gate proves

- `fullscreen_dock_overlay_resolve_test` - the overlay gate (desktop, meta,
  docked mode, picture fullscreen), the entry state, the picture-click
  predicate, the spurious-exit test, the control-bar hit test, the edge-strip
  percentage bounds and the isolation clamp.
- `playlist_dock_vertical_test` - the side-by-side dock keeps its column on a
  narrow window, and the desktop/meta/legacy/fullscreen gates still hold.
- `control_bar_isolation_zone_test` - the isolation-height formula and its
  bounds.
- `fullscreen_playlist_dock_overlay_test` - hover summon, leave + margin
  conceal, a seeded-open panel still concealing, a panel revealed with the
  pointer away concealing on the next move, focus release, no overflow.
- `fullscreen_playlist_dock_overlay_stability_test` - no hover oscillation, the
  leave debounce, wake-on-movement, the dialog-barrier case, re-entry.
- `fullscreen_dock_control_bar_exclusion_test` - the bar wins while hidden, the
  shown panel owns the overlap, the isolation band.
- `fullscreen_dock_video_tap_dismiss_test` - a shown overlay spends the picture
  tap on itself; a hidden one leaves the tap to the chrome toggle; a stale flag
  outside picture fullscreen steals nothing.
- `fullscreen_dock_toggle_seam_test` - `seed` / `show` / `hide` write both flags
  together and stay idempotent.

Note: `flutter_zustand`'s `select` chain does not deliver under the widget-test
FakeAsync zone, so the tap tests seed the store BEFORE pumping.

## Device checks (`M` rows)

Run on Windows desktop, once per control-bar shape (normal long strip and
one-handed side panel).

| Step | What to do | Expected |
| --- | --- | --- |
| `M:overlay occludes the video` | Enter picture fullscreen with the dock mode | The video is not resized; the panel slides in over it |
| `M:esc and P close the panel` | Reveal with `P`, press `Esc`; reveal again, press `P` | Each command conceals the panel; the second `P` reveals it again |
| `M:hover and click dismissal` | Reveal with the queue button, then move the pointer to the middle of the picture; reveal again and click the picture | The panel conceals both times, and the click does not leave the control bar shown |
| `M:control bar reachable` | In picture fullscreen, hover the side bar's slider, then the bottom band | The queue does not pop up over the bar |
| `M:dock width round trip` | Windowed, drag the splitter to both extremes and restart | The width stays clamped and persists |

Also verify: the header X conceals the panel; hovering the strip still summons
it after a click dismissal; a queue row click switches the video without hiding
the panel.
