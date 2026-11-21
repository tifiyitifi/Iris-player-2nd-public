# Background playback (Sub Audio, 副音)

Status: **shipped** (v2.1.0).

Sub Audio is a second, independent player: it plays the audio of a different
real video while the foreground video keeps playing. The two pictures can be
separate; the shared control bar can be re-targeted to either engine.

This document says what the reader sees. `spec.md` says what must be true,
`design.md` says how it is built, `rules.md` names the cases that hold it.

## Scope

In scope:

- one process-wide background engine, independent of the foreground player;
- control-target re-targeting (blue frame on the control bar only);
- the candidate pool, its window queue, and shuffle;
- saved mapping timelines and the A/P/B editor;
- automatic alignment and progress locking;
- cross-video switches and the Virtual Media boundary;
- volume ducking and the fake-cut coexistence rules.

Out of scope:

- a second video window with its own layout (the layout enum keeps placeholders
  but no separate window is built);
- a second history, progress or playback-state writer;
- merging the candidate pool through Virtual Media rules.

## Version facts

| Fact | Value |
| --- | --- |
| Shipped in | v2.1.0 |
| Drift schema | 53; the feature owns v26, v27, v30, v35, v48, v49 |
| Availability gate | metadata settings era only (`BackgroundPlaybackGate.enabled`) |
| Playback backends | `media_kit` and `fvp` (`AppState.playerBackend`) |
| Platforms | Android, Windows (Linux builds pass CI) |
| Settings namespace | `background_playback.*` |
| Persisted state | KV `bg_playback_state` + `bg.*` meta AUX rows + two Drift tables |

## Reading order

1. `spec.md` - requirements.
2. `design.md` - mechanism and invariants.
3. `rules.md` - the case register.
4. `recurrences.md` - what keeps coming back.
5. `testing.md` - how to prove it.
6. `decisions/` - why, and what was rejected.

## Code map

| Path | Role |
| --- | --- |
| `lib/features/background_playback/model/` | Freezed state, domain models, enums, Drift tables/DAOs |
| `lib/features/background_playback/store/` | the one store that owns queue math and mutations |
| `lib/features/background_playback/engine/` | the engine, its scope, and the pure queue/scope logic |
| `lib/features/background_playback/services/` | candidate pool, window, sync policy, alignment, probes |
| `lib/features/background_playback/resolver/` | pure mapping and editor math |
| `lib/features/background_playback/view/` | the runtime observer, quick bar, editor and manager UI |
| `lib/features/virtual_media/interaction/controller/virtual_bg_link.dart` | the VM to Sub Audio bridge |
| `lib/pages/player/player_view.dart` | mounts the runtime and VM-link scopes |

The store never touches a player. The engine is mounted once at the Home root
and driven declaratively from store state.

## Known limitations

- The source-rule subsystem is retired; `bg_src_*` ARB keys and
  `invalidateSourceRules()` are dead code kept for rollback.
- The layout enum keeps `pip`/`split` placeholders; only the surface toggle is
  wired.
- Some legacy preference rows migrate but no longer drive behaviour.

## Privacy note

Real libraries, saved mappings and screenshots stay outside the repository.
This document uses stand-in paths only.
