# 0013 - Duration acquisition has one write-back seam

- Date: 2026-11-21
- Status: accepted
- Private history: `80d091b7`, `6e8ae78f`
- Superseded by: none

## Context

Durations arrived from three places: a DB read, a Shell scan and a pseudo-play
probe. Each wrote back differently, and each consumer read a different answer.
A scan could report success while the row was never updated.

## Decision

The three steps write through one seam and consumers re-read the DB. A scan's
reported keys are never trusted. A write-back that affects no row is a failure,
not a success.

## Consequences

- The DB is the only duration truth.
- A scan's partial result is still visible after a cancel.
- A missing row is reported as a failure.

## Rejected alternatives

- Trusting the scanner's in-memory result.
- Treating a no-op update as success.
