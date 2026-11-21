# 0005 - The store never touches a player

- Date: 2026-09-09
- Status: accepted
- Private history: `8bf05042`, `243b7376`
- Superseded by: none

## Context

Player calls are asynchronous and side-effecting. A store that both mutates
state and opens a file has two owners for "what is playing", and the two
disagree after a rebuild, a scope change or a rapid step.

## Decision

`BackgroundPlaybackStore` owns queue math and state mutation only. A scope
widget observes state and performs the engine calls declaratively. "What is
playing" has one resolver: mapped file, then engine file, then natural queue
entry.

## Consequences

- Scope changes and rebuilds cannot leave a half-open engine.
- The engine lifecycle is observable and testable.

## Rejected alternatives

- Let the store call `media_kit` directly. It produced stale audio after a
  queue rebuild and made the state impossible to assert in a host test.
