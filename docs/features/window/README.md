# Desktop playlist dock (window / 画面全屏 side queue)

Status: **shipped** (the transient overlay is the v2.1.x behaviour).

The desktop dock is the PotPlayer-style queue surface on the right. In a window
it takes its own column and the video shrinks beside it. In picture fullscreen
(画面全屏) it cannot have a column, so it becomes a transient overlay over the
video: a thin right-edge strip summons it, the pointer can move into it, and it
conceals again when the pointer leaves, when the picture is clicked, or with
`Esc` / the header X / the queue key.

This document says what the reader sees. `spec.md` says what must be true,
`design.md` says how it is built, `rules.md` names the cases that hold it.

## Scope

In scope:

- the side-by-side dock (windowed and window-fullscreen) and its width clamp;
- the picture-fullscreen overlay: right-edge summon, transient visibility,
  pointer-leave conceal, picture-click dismiss;
- the 副音 queue body inside the same dock;
- the control-bar exclusion and the bottom isolation band that keep the summon
  strip off the control bar.

Out of scope:

- the floating popup queue (`PlaylistPanelMode.popup`), which stays a
  `PopupRoute`;
- the scenario queue's rows, sorting, paging and bulk actions (owned by the
  scenario playback documentation);
- Android / iOS (the dock is desktop-only);
- persisted dock width beyond the existing meta-setting.

## Version facts

| Fact | Value |
| --- | --- |
| Platforms | Windows desktop (Linux builds pass CI) |
| Modes | side-by-side dock; picture-fullscreen overlay; floating popup untouched |
| State lifetime | two runtime flags on `PlayerUiStore`; the width lives in a meta-setting |
| Settings namespace | `window.*` |
| Persisted state | dock mode, width, theme, edge strip %, isolation % |
| Drift schema | unchanged |

## Reading order

1. `spec.md` - requirements.
2. `design.md` - mechanism and invariants.
3. `rules.md` - the case register.
4. `recurrences.md` - what keeps coming back.
5. `testing.md` - how to prove it.
6. `decisions/` - why, and what was rejected.

## Code map

| Path | Role |
| --- | --- |
| `lib/features/window/playlist_dock/resolve_playlist_dock.dart` | pure resolvers: dock intent, overlay gate, edge strip, isolation band, click-dismiss predicate |
| `lib/features/window/playlist_dock/fullscreen_playlist_dock_overlay.dart` | the picture-fullscreen overlay (hover region, away watcher, debounce) |
| `lib/features/window/playlist_dock/playlist_dock_panel.dart` | dock chrome + body (scenario queue or 副音 queue) |
| `lib/features/window/playlist_dock/resolve_playlist_theme.dart` | dock/popup theme resolution |
| `lib/pages/home/home.dart` | mounts the side-by-side dock and the overlay, seeds the entry state |
| `lib/pages/home/player_dock_shell.dart` | the stable Stack/Row shape that keeps the player subtree alive |
| `lib/pages/player/control_bar/control_bar_widgets/play_queue_button.dart` | the queue button: dock toggle or overlay toggle |
| `lib/hooks/use_keyboard.dart` | `P` (queue) and `Esc` in picture fullscreen |
| `lib/hooks/use_gesture.dart` | the picture tap that dismisses the overlay |
| `lib/store/use_player_ui_store.dart` | the single visibility seam (`show` / `seed` / `hide`) |

## Neighbouring behaviours

- The floating popup queue and the dock share `PlaylistDockPanel`; only the dock
  is themed as a dock (`dockedPanel`), the popup keeps its own theme.
- The picture tap normally toggles the control bar; while the overlay is shown
  that tap is spent on the overlay instead.
