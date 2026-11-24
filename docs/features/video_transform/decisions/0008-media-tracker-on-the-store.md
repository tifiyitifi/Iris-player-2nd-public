# 0008 - The media tracker lives on the store, not the surface

- Status: accepted
- Date: 2026-11-22

## Context

The reset-on-media-change rule needs the previous media identity. Keeping it in
`video_view.dart` as a `useRef` broke two cases:

- a backend switch remounts the surface, so the ref is lost and a media that
  changed while unmounted keeps the old mirror/rotation/color;
- the ref conflated "first mount" with "no media", so a transient `null`
  during a queue rebuild reset a same-media re-open (the documented
  recurrence), while a first real file after `null` was never compared.

## Decision

`VideoTransformStore` owns the runtime tracker. `syncMediaKey(mediaKey)`:

- ignores a `null` key ("nothing playing": a stop or a transient queue
  rebuild) rather than treating it as a new media;
- records the first real key without resetting (state set before the surface
  mounted survives);
- resets when a later DIFFERENT real key arrives;
- keeps the adjustment when the same key is reported again (a remount).

`video_view.dart` calls it from an effect keyed on the media key, so a reset
never notifies listeners during build.

## Consequences

- A surface remount no longer leaks a transform into a new file or clears it
  for the same one.
- A stop keeps the session; returning to a different file resets, returning to
  the same file keeps the adjustment.
- Runtime-only like the state itself; no persistence or Drift change.
- `forgetMediaKey()` is a `@visibleForTesting` seam because the store is a
  process-wide singleton.

## Rejected

- A widget-local `useRef`: lost on remount, and it cannot tell a first mount
  from a null media.
- Resetting on every media-key evaluation: it would clear a re-opened
  same-media file.
