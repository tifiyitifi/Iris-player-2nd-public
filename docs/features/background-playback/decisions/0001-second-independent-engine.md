# 0001 - Sub Audio runs in a second, independent engine

- Date: 2026-09-09
- Status: accepted
- Private history: `8bf05042`, `243b7376`
- Superseded by: none

## Context

Sub Audio plays the audio of a different real video while the foreground video
keeps playing. Reusing the foreground player would entangle transport, Virtual
Media state, history and progress writes. A second track that seeks the first
player, or writes the first player's history, is not a second track.

## Decision

One process-wide `BackgroundPlaybackEngine`, built on `media_kit` and `fvp`,
mounted once at the Home root. It has no Virtual Media, no A/B loop, no history
or progress writer and no wakelock. It is driven declaratively from store state
and disposed through `AppShutdown`.

## Consequences

- The shared controls are bridged as a `MediaPlayer` with seek floor/ceiling.
- The engine can be kept warm to avoid a black flash on launch.
- A stale open is guarded by a generation counter.

## Rejected alternatives

- Reuse the foreground player. It shares transport and VM state, and the
  first back-and-forth attempt flashed back to the first VM block.
- One engine per window. The feature is one pair at a time, and a second engine
  per window multiplies the lifecycle bugs.
