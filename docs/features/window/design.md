# Desktop playlist dock - design

## Two surfaces, one queue body

| Surface | Container | Why |
| --- | --- | --- |
| Windowed / window-fullscreen | `Row[Expanded(video) | chrome + dock]` | the picture keeps its aspect and the dock gets a real column |
| Picture fullscreen (画面全屏) | `Stack[player, overlay]` | there is no spare column; the overlay occludes the video |

`PlayerDockShell` keeps ONE shape (`Stack[Row, overlay?]`) in every state. A
theme flip or a dock toggle only adds/removes trailing children, so the player
subtree — which owns GlobalKeys and Tooltip `OverlayPortal`s — is never
deactivated and re-activated (flutter/flutter #177693 / #188500).

## Visibility state

Two runtime flags on `PlayerUiState`, both written together by one seam on
`PlayerUiStore`:

| Call | `isFullscreenDockPinned` | `isFullscreenDockPeeking` | Meaning |
| --- | --- | --- | --- |
| `seedFullscreenDockOnEntry(true)` | `true` | `false` | `keepPanel`: start revealed |
| `seedFullscreenDockOnEntry(false)` | `false` | `false` | `hidePanel`: start hidden |
| `showFullscreenDock()` | `false` | `true` | revealed now (hover, key, button) |
| `hideFullscreenDock()` | `false` | `false` | concealed |

`shown = pinned || peeking`. `pinned` is only the ENTRY seed — it is not a sticky
pin (see `decisions/0001`). Every dismissal writes both flags, so no caller can
leave `peeking` off while a seed is still on, which was the "opened it and
nothing closes it" state.

## Reveal and conceal

```
        pointer in right strip            pointer leaves panel+margin
  hidden ─────────────────────▶ shown ───────────────────────────▶ hidden
     ▲                            │  picture click / Esc / X / key   │
     └────────────────────────────┴─────────────────────────────────┘
```

Three watchers own concealment:

1. **Hover region** — one persistent `MouseRegion` anchored at `right: 0`, whose
   width is the strip while hidden and the panel + `kFullscreenDockHideMargin`
   while shown. Its `onExit` is verified against its own rect
   (`shouldConcealAfterExit`), so a media-switch rebuild or a dialog barrier that
   steals the region cannot conceal the panel under the pointer.
2. **Away watcher** — a full-screen translucent `MouseRegion` (`opaque: false`,
   so it never takes a click) that schedules a conceal on pointer movement
   outside the shown panel. It exists because a key/button or `keepPanel` reveal
   can leave the pointer far from the right edge, where the strip would never see
   an enter/exit pair. Movement only (`onHover`), so an entry seed cannot flash
   away under a stationary pointer.
3. **Picture tap** — `useGesture().onTap` asks
   `shouldDismissFullscreenDockOnVideoTap(overlayEnabled, shown)` and, when true,
   calls `hideFullscreenDock()` and returns without touching the chrome.

Concealment is debounced by `kFullscreenDockConcealDelay` (200 ms) so skirting
the boundary does not flicker. Reveal fires on `onEnter` AND `onHover`: a
conceal that lands while the pointer never left the region cannot produce a new
`onEnter`, so movement must be able to wake the panel.

## Summon strip guards

- `controlPanelKeyNotifier` publishes the control bar's live box. While hidden,
  a pointer on that box does not summon — the one-handed side bar hugs the same
  right edge, and the queue used to pop up over the slider.
- `controlBarIsolationHeightNotifier` publishes `barHeight + pct% of the area`,
  which stays reserved even while the bar is translated off-screen.
- Both guards are disabled while shown: the panel is drawn over the bar and
  shares its rect.

## Focus

While hidden the panel is `IgnorePointer` + `ExcludeFocus`, and it is moved fully
off-screen. `IgnorePointer` alone left the primary focus inside the list, so
`↑`/`↓` drove an invisible queue.

## Invariants

- No Drift change; the overlay state is runtime-only.
- The dock width is clamped by one helper shared by layout and window-resize math
  (`playlistDockChrome`), or a letterbox gap appears.
- The overlay is a sibling of the player inside `PlayerDockShell`, never a route.
- Exactly one surface is visible at a time: the side-by-side dock is suppressed
  in picture fullscreen (`isDockIntentVisible`).
