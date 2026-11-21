# 0007 - Playback is sequential opens, not a virtual timeline

- Date: 2026-11-21
- Status: accepted
- Private history: `48473b9f`
- Superseded by: none

## Context

Merging several files into one logical video can be done by building an EDL and
feeding one decoder, or by opening each file in sequence. An EDL needs every
file to be present and seekable and turns one bad file into a broken timeline.

## Decision

A virtual item is played as sequential single-file opens. The controller plans
segment transitions, anchors and degradation; there is no EDL.

## Consequences

- One bad segment degrades locally instead of breaking the item.
- Resource use stays constant; only the current file is open.
- A cross-segment seek opens a file and seeds it.

## Rejected alternatives

- An EDL or concat demuxer per item.
- Muxing a temporary file.
