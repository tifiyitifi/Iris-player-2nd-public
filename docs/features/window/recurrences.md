# Desktop playlist dock - recurrences

Symptoms and couplings that keep coming back. This is not a changelog.

## The fullscreen panel opens and then nothing closes it

Symptom: in picture fullscreen the queue opens from the queue button / `P` and
then neither moving the pointer away nor clicking the picture hides it; only
`Esc` or the header X works, and the control bar sits under the panel.

Cause: the reveal wrote a "pin" flag that the conceal path deliberately skipped
(`if (pinned) return`), and the overlay is not a route, so it had no barrier to
catch a click outside. Two independent gaps, one visible state.

Guard: DOCK-9..DOCK-12 (`decisions/0001`, `decisions/0002`). The two runtime
flags are now written together, no reveal path is sticky, and the picture tap is
a dismissal path.

## Hover reveal/conceal oscillation

Symptom: with the cursor parked on the right edge the panel reveals and conceals
continuously.

Cause: the activation strip existed only while hidden, so a conceal mounted a
fresh region under the stationary pointer, whose `onEnter` re-revealed it.

Guard: DOCK-16. One persistent region whose width changes, never a new region;
conceal is debounced so a transient geometry exit is absorbed.

## Hover "does nothing" until the pointer leaves and comes back

Symptom: after a conceal that happened while the pointer never left the edge,
moving the mouse along the edge does not bring the panel back.

Cause: the annotation stayed active, so no new `onEnter` could arrive, and only
`onEnter` revealed.

Guard: DOCK-16. Reveal also fires on `onHover`.

## Tapping a queue row hides the queue

Symptom: switching the video from the dock makes the panel slide away.

Cause: a media switch fires a rebuild burst and can raise a dialog whose barrier
steals the hover region, emitting an `onExit` under the pointer. Concealing on
that exit looked like "the row I tapped closed the list".

Guard: DOCK-18/DOCK-19. An exit whose reported position is still inside the
region is spurious; the away watcher only reacts to movement.

## The queue pops up over the control bar

Symptom: reaching for the one-handed side bar's slider summons the queue on top
of it, or the pointer cannot reach the bar because the summon strip covers it.

Cause: the strip covers the same right edge the side control panel is anchored
to, and the bar's live rect disappears (it is translated off-screen) the moment
it auto-hides.

Guard: DOCK-20/DOCK-22. Exclude the live bar rect, and reserve the isolation
band by height while hidden. Both guards must switch OFF once the panel is shown
(DOCK-21), or the panel would conceal itself on appearance.

## The player subtree dies when the dock toggles

Symptom: `_RenderLayoutBuilder was mutated in performLayout`, then a poisoned
element tree and a dead process; or a bogus `RenderFlex overflowed by 97890
pixels`.

Cause: returning a different widget SHAPE for the dock on/off states
deactivated the player subtree, which owns GlobalKeys and Tooltip
`OverlayPortal`s; re-taking the inactive GlobalKey re-activated an element whose
deferred overlay child was grafted during layout.

Guard: `PlayerDockShell` keeps one `Stack[Row, overlay?]` shape; a toggle only
adds/removes trailing children.
