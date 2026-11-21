# Background playback - what comes back

Two tables. `R` is a complaint or failure that returned. `C` is a coupling: two
areas that share an input, where a safe change in one can break the other. Every
row names the private-history commits that show the pattern.

## R - the complaints that return

| ID | Symptom | Mechanism | Held by | Comes back if | Source |
| --- | --- | --- | --- | --- | --- |
| R1 | Dragging P flips which readout grows | No single spec for a reversible gesture plus a numeric readout; each report refined one case | `D:0010`, `APB-1`, `segment_span_math_test` | a new drag mode is added without a golden test | `230b77a7`, `64afb45b`, `9df05b2e`, `323b0237`, `512af46f`, `85ba7bbd` |
| R2 | The candidate source is rewritten again | The same reserved tag was modelled as a rule table, a scenario source and a tag view | `D:0002`, `D:0003`, `POOL-1` | a new source shape is layered on instead of the tag view | `6879187d`, `d716706a`, `d396ea47`, `e5c50ca8` |
| R3 | The pair ping-pongs or the background drives an episode skip | A two-way link fed the background's local position back as a foreground seek | `D:0007`, `LOCK-3` | mirroring is widened without a swallow latch | `f40b2bdc`, `4117eb37`, `f91b0ed3`, `7a5a54fe`, `34a96c68` |
| R4 | Armed is mistaken for playing | `enabled`, gate, armed, out-of-scope and ended were mixed | `D:0006`, `GATE-1`, `GATE-2` | a new flag is added beside the axes instead of on them | `2b8c2f63`, `20d5bb2d`, `18a853d1`, `1c69a715` |
| R5 | The q handle stops moving or fights the playhead | Hit area and drawn handle drifted apart | `APB-8` | the handle geometry and the hit test are edited separately | `0d3a10ec`, `e8c330e2`, `66ef9311` |
| R6 | The alignment dialog gains options, then loses them | A persisted default mode competed with the automatic rule | `D:0012`, `ALIGN-1`, `ALIGN-2` | a new "default alignment" setting is proposed | `2a17137e`, `456d9b34`, `fd399a31`, `472d59b9` |
| R7 | "Next at the queue end" is fixed twice with opposite answers | Hand-back state and a real queue end shared one code path | `D:0014`, `GATE-5` | end-of-queue and collision are detected by flags rather than by the pair state | `9eadfde9`, `a2b088b7`, `19d63eb2`, `a0c3a984`, `75ba1cd5`, `6e96413e`, `1b444e0b` |
| R8 | A fake cut and Sub Audio disagree about who is playing | The remembered plan was treated as the cut that is actually open | `D:0015`, `CUT-1`, `CUT-2` | resume is decided from memory instead of from the open file | `1b0b2f50`, `993cc06c`, `9ab1f27f` |
| R9 | A migration is repaired by a later migration | v27 hard-coded a table name; v48 swallowed a failed DROP | `D:0016`, `MIG-1`, `MIG-3` | a migration is not re-entrant or catches its own failure | `ed42c848`, `625ec3e3` |

## C - the couplings

| ID | Shared input | Readers | Safe change | Source |
| --- | --- | --- | --- | --- |
| C1 | Reserved tag membership | tag view, candidate pool, queue window | change the pool only through `BgPoolRevision` | `82784a89`, `e5c50ca8` |
| C2 | Virtual Media overlay | VM resolver, candidate pool | never pass `withVmOverlay: true` in the pool | `6afffc08` |
| C3 | Scenario resolver | foreground scenarios, candidate pool | the pool calls it with `ignoreScenario: true` | `38062adb`, `82784a89` |
| C4 | Media identity | duration probe, mapping key, double-play guard | resolve identity in one helper; never compare file names | `0eb10527`, `74fd28ba`, `838c15f9` |
| C5 | Foreground file | queue start, double-play guard, apply-to-current | exclude at selection, never at membership | `ca09b4fb`, `75ba1cd5` |
| C6 | Engine lifecycle | gate, keep-warm, shutdown | drive it from state only; register the disposer | `8bf05042`, `c16d70a9` |
| C7 | Fake-cut routing | player transport, Sub Audio resume | resume from the open file, not the remembered plan | `993cc06c`, `9ab1f27f` |

## How a report becomes a row

1. Write the symptom as one sentence, without a fix.
2. Name the mechanism that produced it, not the line that was edited.
3. Point at the rule or decision that now holds it.
4. Say what would have to be true for it to come back.
5. Cite the private-history commits that show the pattern.
