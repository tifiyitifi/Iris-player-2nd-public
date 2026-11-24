# Virtual Cut - tasks

## Open

- [ ] A device pass on the EDL last mile (`M:device checklist#edl`): host tests
      prove the wiring, not mpv's decoding of the generated EDL.
- [ ] Decide whether a `.llc` edit should re-derive the merged group without
      the segment being opened again (a directory watcher would be needed).
- [ ] Decide whether `fake_cut` should gain its own `DefVisibility` feature flag
      instead of relying on backend/storage preflight alone.

## Done

- [x] LosslessCut JSON5 v1/v2/v3 parsing, markers, deselected fallback,
      clamping, malformed-file notices.
- [x] Pairing by recorded `mediaFileName` with a stem fallback and a cached,
      explicitly invalidated directory index.
- [x] Plan-order timeline with reordered/repeated/overlapping ranges; first-hit
      resume in a merge, explicit sync-point prompt standalone.
- [x] EDL generation with a content-signature cache and re-timed subtitles.
- [x] Explicit activation state, snapshot plan per open, and defensive fallback
      to the source when anything fails.
- [x] 副音 stand-down scoped to the file whose EDL is open.
- [x] Coexistence with Virtual Merge: an active plan (any range count) is one
      merged segment; activation/close re-segments the live session; added or
      removed `.llc` files are picked up by a media rescan.
- [x] Localized blocked reasons and plan notices in en + zh.
- [x] The standard feature documentation set and its own rule checker.

## Accepted gaps

- fvp has no EDL: standalone cutting is blocked and a merged file plays its
  source (ADR 0004).
- Remote/SAF siblings are not readable through the filesystem path, so no cut
  discovery there.
- The project index is explicit, not watched: an in-place edit while no segment
  is opening stays invisible until the plan is opened or the tab refreshed.
