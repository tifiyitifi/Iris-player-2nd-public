# Background playback - design

## 1. Shape of the slice

```
lib/features/background_playback/
  model/        state, domain, enums, db
  store/        the one store (queue math, mutations)
  engine/       engine + declarative scope + pure logic
  services/     pool, window, policy, alignment, probes
  resolver/     pure mapping/editor math
  view/         runtime observer, quick bar, editor, manager
  actions/      launch/stop entry points
  contributions/ settings definitions
```

The feature is a vertical slice. Cross-cutting pieces it touches are the player
page, the VM bridge, the tag view resolver, the metadata settings engine, and
the drift layer.

## 2. Pipeline

```
enable -> resolve window -> store.startWithCandidates
       -> engine.open(file) -> auto-align -> run
       -> mapping overlay (saved segment) -> boundary -> retarget
```

1. **Enable.** `BackgroundPlaybackActions` resolves the candidate window and
   starts the store with it.
2. **Store.** The store picks a start index, sets the queue, anchor and target,
   and persists the session position.
3. **Engine.** `BackgroundPlaybackScope` sees `enabled` and opens the file.
4. **Align.** `BackgroundRuntimeScope` derives the anchor from the two real
   durations and seeks once.
5. **Run.** Position samples go through the sync policy; scope and pool changes
   are reconciled.
6. **Mapping.** `MappingScope` resolves the effective segment and prefers the
   mapped file over the natural queue entry.
7. **Boundary.** Natural completion advances, repeats or hands the pair back.
8. **Retarget.** The router sends navigation to the background store while the
   background owns the controls.

## 3. Data model

| Layer | Holds | Key |
| --- | --- | --- |
| KV JSON | queue, window, index, ratio, rate, shuffle, repeat | `bg_playback_state` |
| meta AUX | preferences (`bg.*`) | metadata settings rows |
| `bg_mappings` | one saved timeline per foreground file | `UNIQUE(storage_id, path)` |
| `bg_mapping_segments` | segments, cascade-deleted | parent row id |

Session-only fields are excluded from JSON and from AUX. Legacy rows
(`progressLock`, `vmAlignRule`, `alignDefault`) migrate but no longer drive
behaviour.

## 4. Invariants

- The store never calls a player; the engine is driven from state.
- The candidate pool is never merged through Virtual Media.
- Shuffle is local; the shared tag view is never reordered.
- A membership write is coalesced before it reaches the queue.
- Overlapping segments resolve by highest `activeSeq`, tie-broken by foreground
  start then id.
- A background file swap keeps the A/B span and the offset byte-identical.
- The foreground file may stay in the candidate membership but is excluded at
  selection.
- The pair is in effect only when enabled, gate open, in scope, not exhausted
  and not at a terminal queue end.

## 5. Anti-patterns

- A second boolean that means "armed" and "playing" at once. Use the axes.
- Writing the resolved shuffle order into the tag view.
- Re-clamping A/B when the background file is replaced.
- Advancing the foreground episode from a background completion.
- Reusing the foreground player for the second track.

## 6. Cross-module boundaries

- `virtual_bg_link.dart` publishes the VM scope override and owns the tiled
  plan; the background module stays VM-agnostic.
- `TagViewResolver` is called with `withVmOverlay: false` and
  `ignoreScenario: true`.
- `PlaybackProviderRegistry` routes navigation through the background router.
- The engine registers its disposer with `AppShutdown`.
