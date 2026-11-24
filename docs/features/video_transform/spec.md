# Picture adjustment - requirements

One EARS requirement per sentence. The register that holds them is `rules.md`.

## Entry

- WHEN the user opens the player's More menu, THE SYSTEM SHALL offer a
  "picture adjustment" entry that opens the panel.
- THE SYSTEM SHALL keep the entry available on both backends.

## Orientation

- WHEN the panel is opened, THE SYSTEM SHALL present independent horizontal and
  vertical mirror switches and the four clockwise rotations.
- WHEN a mirror switch is toggled, THE SYSTEM SHALL mirror only that axis.
- WHEN a rotation is selected, THE SYSTEM SHALL rotate the picture clockwise by
  that many quarter turns.
- WHEN both a rotation and a mirror are active, THE SYSTEM SHALL rotate first
  and mirror second, so the mirror is in display space.

## Color

- THE SYSTEM SHALL present brightness, contrast and saturation on a symmetric
  -1..1 range whose neutral value is 0.
- WHEN a color value changes, THE SYSTEM SHALL apply it to the running backend
  without rebuilding the geometric transform.

## Lifetime

- THE SYSTEM SHALL hold picture adjustment per session only.
- WHEN the media changes, THE SYSTEM SHALL return the picture to neutral.
- WHEN the app restarts, THE SYSTEM SHALL start neutral.
- WHEN the user resets, THE SYSTEM SHALL restore neutral for the named field,
  or for all fields.
- WHEN a field is at its default, THE SYSTEM SHALL disable that field's reset
  action.
- WHEN a per-field reset is invoked, THE SYSTEM SHALL leave every other field
  unchanged.

## Saved frame

- WHEN a screenshot is captured while an orientation transform is active THE
  SYSTEM SHALL save the frame with the same rotation and mirror.
- WHEN the orientation transform is neutral, THE SYSTEM SHALL save the raw
  frame unchanged.
- IF the post-process cannot decode the frame, THEN THE SYSTEM SHALL save the
  raw frame rather than fail the capture.

## Surface

- THE SYSTEM SHALL leave the video surface visually and dimensionally
  untouched when the state is neutral.
- THE SYSTEM SHALL keep display fit correct after a quarter-turn rotation.
