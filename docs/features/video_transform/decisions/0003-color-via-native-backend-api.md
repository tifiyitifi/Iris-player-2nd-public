# 0003 - Color uses the native backend API, independent of geometry

- Status: accepted
- Date: 2026-11-22

## Context

Color could be applied as a Flutter `ColorFiltered`, as a pixel filter, or
through each backend's own controls. fvp already exposes
`setBrightness/setContrast/setHue/setSaturation` (-1..1); mpv exposes
`brightness/contrast/saturation` VO properties (-100..100).

## Decision

Color is applied per backend:

- media_kit: `setProperty('brightness' | 'contrast' | 'saturation', value * 100)`,
- fvp: `controller.setBrightness/Contrast/Saturation(value)`.

The store uses one symmetric -1..1 range with 0 neutral. Color is applied from a
tuple-keyed effect and never touches the geometric wrappers.

## Consequences

- Smooth slider drags; no filter-chain rebuild.
- A media_kit output driver without the properties keeps the picture untouched;
  a `lavfi eq` fallback remains a documented follow-up (`tasks.md`).
- The saved frame carries color only as far as the backend's own capture does;
  the PNG post-process handles geometry only.

## Rejected

- Flutter `ColorFiltered`: backend-agnostic but paint-only, does not survive the
  backend capture, and duplicates color math.
- A single `vf` chain carrying color and geometry: a color drag would rebuild
  the transform and could stutter.
