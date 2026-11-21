# Virtual Media - what comes back

`rules.md` says what the feature must do. This file says **how the rule set
fails**: the complaints that return, and the couplings that make fixing one of
them break another. A change is not finished until it says which R it is about
and which C it touches.

## R - the complaints that return

| ID | Symptom | Mechanism | Held by | Comes back if |
| --- | --- | --- | --- | --- |
| R1 | Tapping a merged row plays the first file instead of the tapped child | The session plan was built from the rule's own chunk list, or the occurrence was dropped | `SESS-6`, `XFEAT-7`, `f3dda394` | A new start path rebuilds from the library snapshot |
| R2 | The title number looks like it skipped a value | The leading column counts rows while the title counts chunks | `RULE-11`, `D:0004` | The two numbers are collapsed again |
| R3 | A pinned item still shows a renamed or moved file | The pin snapshotted members instead of re-reading by `mediaKey` | `PIN-2`, `28a7c1bc` | The pin stores member rows |
| R4 | The yellow failure mark disappears after a delete | The pin dropped infeasible chunks | `PIN-3`, `29c32d15` | The pin only keeps feasible groups |
| R5 | Deleting one file deletes or re-chunks the whole rule | The delete was rule-scoped, not chunk-scoped | `PIN-1`, `PIN-4`, `7629d867` | A delete invalidates the rule instead of the chunk |
| R6 | Playback freezes after a session goes stale | `transitioning` was never released, so reconcile never became active | `SESS-13`, `SESS-14`, `59f978f4` | Reconcile runs before the orphan release |
| R7 | A stale lookup lands on the newest item | The feed sequence number was ignored, or two opens raced to 0% | `SESS-8`, `60d4f2da` | A feed is started without a generation check |
| R8 | The last step rolls the position back or freezes the picture | A tail step was expressed as a seek instead of a finish | `SEEK-2`, `SEEK-3`, `188c3b31` | A tail path calls the ordinary seek |
| R9 | The next segment's `completed` is swallowed | Terminal dedupe was keyed by the item, not the segment | `SESS-15`, `993cc06c` | The dedupe key loses the segment |
| R10 | Turning the master switch off restarts the video | The switch re-opened the current file instead of pausing resolution | `GATE-3`, `GATE-4`, `4b617fcb` | The switch writes rules or re-opens |
| R11 | A group silently loses its unknown-duration file | Overlong exclusion treated unknown as overlong, or preflight filtered it out | `RULE-9`, `MERGE-6`, `D:0006` | A filter drops null/zero durations |
| R12 | A network scan appears to hang | The probe had no per-file timeout and no total budget | `SCAN-4` | A probe is awaited without a bound |
| R13 | A probe reports success but the row is not updated | A missing DB row was treated as a no-op success | `SCAN-6`, `D:0013` | Write-back ignores the affected-row count |
| R14 | The item's scrubber jumps after a duration heal | The derived signature was not bumped | `SCAN-7`, `D:0016` | Only the playback version bumps |
| R15 | The video freezes with no error after opening a broken merge | The first-feed failure was gated on an expected key that did not exist yet | `SESS-17`, `D:0018` | Error recovery is gated on `isActive` again |
| R16 | A merged row is shown but plays as one file | A failed overlapping group's flat `failByKey` marked a feasible group's shared member | `MERGE-10`, `D:0020` | `failByKey` is consulted before the valid group |
| R17 | A SAF single pick never loses its yellow mark after a scan | The DB readers rebuilt keys from the empty path instead of the uri | `SCAN-10`, `D:0021` | A reader bypasses `canonicalMediaKey` |
| R18 | Turning a folder off still merges it | A non-recursive exclusion lost to a recursive inclusion, or the mask was skipped | `DIR-2`, `DIR-7`, `D:0023` | The tier order changes or the mask is only applied in one path |
| R19 | Two switches fight over one folder | Same-path non-recursive rules were both enabled | `DIR-5`, `D:0023` | An enable entry point bypasses the guard |
| R20 | The 500k list slows down after adding exclusions | A per-rule exclusion pass or a 500k string set was reintroduced | `DIR-7`, `D:0024` | The fast path or the byte mask is replaced |
| R21 | A folder switched off keeps advancing the old session | The live session was left merging after its rule became `notUse` | `DIR-8`, `D:0024` | The toggle stops calling the deactivation fallback |
| R22 | Turning a folder on does nothing until the next file | Only the next feed consulted the rules; the open feed stayed single | `DIR-11`, `DIR-12`, `D:0025` | The toggle stops adopting the live feed, or adoption starts re-opening it |

## C - the couplings

| ID | Input read by several parts | What breaks when one part changes | Hold it with |
| --- | --- | --- | --- |
| C1 | `mediaKey = storageId:path` | Rule matching, pin lookup, resume, progress and the Sub Audio link all key on it | Never derive identity from a list index or a display name |
| C2 | Displayed order | The overlay, the session queue, auto-advance and the tap all read it | Session queue is the displayed order across rules (`SESS-2`) |
| C3 | `scopeKey` (`ruleId` / `dir` / `#chunk`) | Progress, anchors and the pin share it; the chunk number is part of it | A renumber changes identity; a migration must not rewrite it silently |
| C4 | The tail guard | Ordinary seek, tail step, scrub release and cross drag all depend on it | Only the finish intent may bypass it (`SEEK-1`, `SEEK-2`) |
| C5 | The gate | Settings rows, commands, the editor entry and the player entry all read it | Gate off means absent, not disabled (`GATE-1`) |
| C6 | Timeline ownership | VM, fake cut and Sub Audio all want the transport | An in-flight feed owns it before `isActive` (`SESS-10`) |
| C7 | Duration truth | Preflight, scan, harvest and the red bar all consume it | Only the DB is truth (`SCAN-8`) |
| C8 | `occurrenceIndex` | Session start, child list and resume all distinguish duplicates | A duplicated file is opened by occurrence, not by key alone (`SESS-6`) |

A change to the identity key, the displayed order or the tail guard is a change
to the whole table above; say which rows it moves.
