# Background playback - tasks

## Open

- [ ] Give the retired `bg_src_*` ARB keys a decision: delete them or mark them
      retired in the ARB comments.
- [ ] Decide whether the `pip`/`split` layout placeholders ship or are removed.
- [ ] Replace the file-level `F:` tokens (ENG, GATE-7) with literal test names
      where the tests settle on one.

## Done

- [x] Second independent engine.
- [x] Candidate pool on the reserved tag view, VM overlay off.
- [x] Bounded window queue.
- [x] Mapping timelines and the A/P/B editor.
- [x] Automatic alignment from the two real durations.
- [x] Two-axis progress lock.
- [x] Fake-cut coexistence.

## Accepted gaps

Rows whose only coverage is `M` or `-:`:

- `APB-8` - the ring feel is `M:device checklist#ring`; the drawn handle and
  the hit area can only be judged on a device.
- `PLAT-4` - probe progress timing is `-:visual timing only` plus
  `M:device checklist#probe`.

File-level `F:` tokens are not gaps; they are a fallback for tests whose names
are generated, and they still prove the file exists.
