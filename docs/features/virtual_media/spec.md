# Virtual Media - specification

Requirements only. `design.md` holds the mechanism; `rules.md` maps each
requirement to the cases that hold it.

## Glossary

| Term | Meaning |
| --- | --- |
| rule | a saved selector plus ordering, boundary and cap settings; rules are data |
| virtual item | one merged row: several segments, one title, one progress point |
| segment | one real file inside a virtual item, identified by `mediaKey = storageId:path` |
| occurrence | which copy of a duplicated file a segment means (`occurrenceIndex`) |
| group | the pure result of applying one rule to the files it covers |
| overlay | the list transform that shows one row per group at its earliest member |
| chunk | a bounded run of group members after caps and boundaries are applied |
| scope key | `ruleId` / `dir` / `#chunk`; the identity used by progress, anchors and the pin |
| preflight | deciding whether every segment of a group has a known positive duration |
| pin | a session-scoped freeze of chunk boundaries after a physical delete |
| seed | the initial program position inside a segment when a session starts |
| tail guard | the shared distance kept from a segment's end by ordinary seeks |

## Requirements

Each requirement is one observable behaviour. The acceptance criterion is
`WHEN <trigger>, THE SYSTEM SHALL <response>`; the `Rules:` line names the
register rows that hold it.

### FR-1 - Rules are data

THE SYSTEM SHALL interpret every grouping decision from the saved rule and
SHALL NOT hard-code matching, ordering or chunking into playback code, and SHALL
NOT define a rule priority order.

Rules: `RULE-1`, `RULE-5`.

### FR-2 - Selection by directories or patterns

WHEN a rule selects files, THE SYSTEM SHALL support specified directories and
name patterns in both recursive and non-recursive modes, SHALL require every
activated pattern entry to hold, and SHALL fail a rule closed on an invalid
regular expression.

Rules: `RULE-2`, `RULE-3`.

### FR-3 - Ordering and directory boundaries

WHEN a group is ordered, THE SYSTEM SHALL apply the chosen single-level sort with
unknown probe values last in both directions, and SHALL apply the boundary mode
`sameDirOnly`, `crossDirMerge` or `ignoreDirs`.

Rules: `RULE-6`, `RULE-7`.

### FR-4 - Bounded chunks

WHEN a group is chunked, THE SYSTEM SHALL treat at least one cap as required and
SHALL enforce the hard ceilings of 32 items and 300 minutes even when the soft
switches are off.

Rules: `RULE-8`.

### FR-5 - Overlong exclusion and one-file merges

WHEN a file has a known duration above the overlong threshold, THE SYSTEM SHALL
exclude it from candidates; a file with an unknown or zero duration SHALL NOT be
excluded, and a chunk left with one segment SHALL follow `skipSingleSegment`.

Rules: `RULE-9`, `RULE-10`.

### FR-6 - Numbering and naming

WHEN a chunk is numbered, THE SYSTEM SHALL number chunks, not list rows, within
the rule scope, and SHALL compose the display title from the lit tags in their
lit order; rule names SHALL follow the configured naming strategy.

Rules: `RULE-11`, `RULE-12`, `RULE-13`, `RULE-14`.

### FR-7 - Derived groups and the list overlay

WHEN the list is built, THE SYSTEM SHALL collapse each group to exactly one row
placed at its earliest member, SHALL carry the group's segments as children, and
SHALL keep the merged row's identity equal to the group it displayed.

Rules: `MERGE-1`, `MERGE-2`, `MERGE-3`, `XFEAT-7`.

### FR-8 - Feasibility and degradation

WHEN any segment of a group has an unknown or zero duration, THE SYSTEM SHALL
degrade the whole group to ordinary single rows with a visible failure mark, and
SHALL publish the failure reasons by group identity.

Rules: `MERGE-5`, `MERGE-6`, `SCAN-2`.

### FR-9 - Session start and resume

WHEN a virtual item starts, THE SYSTEM SHALL build the queue from the displayed
merged order across all rules, SHALL resume by the most recently watched file
unless a target occurrence overrides it, and SHALL keep an absent seed `null`
rather than inventing zero.

Rules: `SESS-2`, `SESS-3`, `SESS-4`, `SESS-5`, `SESS-6`, `SESS-7`, `SESS-17`.

### FR-10 - Sequential playback contract

THE SYSTEM SHALL play a virtual item as sequential single-file opens, SHALL
serialize feeds and discard stale answers, and SHALL advance inside the item
before moving to a sibling and wrap only under `Repeat.all`.

Rules: `SESS-1`, `SESS-8`, `SESS-11`.

### FR-11 - Seek, step and the tail

WHEN a seek lands near a segment end, THE SYSTEM SHALL stop at the shared tail
guard; only an explicit finish intent SHALL land on the segment end, and a tail
step SHALL be finished by the step hook rather than by a seek.

Rules: `SEEK-1`, `SEEK-2`, `SEEK-3`, `SEEK-4`.

### FR-12 - Stop, reconcile and terminal events

THE SYSTEM SHALL give stop, stop-to-first and navigation-deactivate distinct
scopes, SHALL release an orphaned transition before reconciling a stale session,
and SHALL drop duplicate terminal events for the same segment.

Rules: `SESS-12`, `SESS-13`, `SESS-14`, `SESS-15`, `SESS-16`.

### FR-13 - Duration acquisition

WHEN durations are missing, THE SYSTEM SHALL resolve them through DB-only
preflight, then a Shell batch scan, then pseudo-play harvest, SHALL write through
one seam, and SHALL require consumers to re-read the DB rather than trust scan
claims.

Rules: `SCAN-1`, `SCAN-3`, `SCAN-4`, `SCAN-5`, `SCAN-6`, `SCAN-8`, `SCAN-10`, `SCAN-11`, `SCAN-12`.

### FR-14 - Membership pin

WHEN a physical delete lands inside a merged item, THE SYSTEM SHALL freeze only
the affected chunk boundaries for the session, SHALL re-read members by
`mediaKey`, SHALL keep infeasible groups, and SHALL lift the freeze on restart,
source change, rule change or explicit refresh.

Rules: `PIN-1`, `PIN-2`, `PIN-3`, `PIN-4`, `PIN-5`, `PIN-6`.

### FR-15 - Cross-feature boundaries

THE SYSTEM SHALL keep the Sub Audio bridge on the Virtual Media side, SHALL NOT
VM-merge the Sub Audio candidate pool, SHALL exclude a file with a sibling cut
project from merging, and SHALL keep list taps aligned with the displayed group.

Rules: `XFEAT-1`, `XFEAT-2`, `XFEAT-3`, `XFEAT-4`, `XFEAT-5`, `XFEAT-6`, `MERGE-10`.

### FR-16 - Gate, master switch and the legacy seal

WHEN the metadata-settings gate is off, THE SYSTEM SHALL make the feature
absent; the master switch SHALL pause merging without mutating rules, and the
legacy More sheet SHALL never execute.

Rules: `GATE-1`, `GATE-2`, `GATE-3`, `GATE-4`, `GATE-5`.

### FR-17 - UI contract

WHEN a rule or manual-entry form is shown, THE SYSTEM SHALL use the canonical
keyboard shell and SHALL NOT rebuild the form on `viewInsets` changes; feedback
SHALL use a Dialog, never a SnackBar.

Rules: `UI-1`, `UI-2`, `UI-3`, `UI-4`.

### FR-18 - Player surfaces

THE SYSTEM SHALL draw scrubber marks from the virtual timeline, SHALL keep the
dual time's total axis exact, SHALL show merged totals and children, and SHALL
surface fatal playback errors in a dialog host.

Rules: `UI-5`, `UI-6`, `UI-7`, `UI-8`, `UI-9`, `UI-10`.

### FR-19 - Schema evolution

WHEN the schema changes, THE SYSTEM SHALL add a migration under
`lib/models/db/migration/`, SHALL keep cascade cleanup explicit in the
repository, and SHALL NOT bump the schema without its migration.

Rules: `MIG-1`, `MIG-2`, `MIG-3`, `MIG-4`, `MIG-5`.

### FR-20 - Direct-folder use/exclude

WHEN the player More-menu is open, THE SYSTEM SHALL show the video that was
playing when it opened and a single toggle for that video's DIRECT folder. The
toggle SHALL create a default-config rule when none covers the file, reuse the
existing folder rule, or carve out only that folder when a recursive rule
covers it. Non-recursive decisions SHALL outrank recursive ones, a
`specifiedDir` SHALL outrank a name `patternDir`, and at most one enabled
non-recursive `specifiedDir` rule SHALL exist per path (conflicts are asked).
A folder switched to `notUse` while the live session's current segment is no
longer merged SHALL fall back to single playback — including a folder carved
out of another rule's recursive merge. Switching it to `use` while that very
video is playing SHALL bind the live feed to its merged group WITHOUT reopening
it (position, queue and autoplay untouched); when the queue has moved on, the
adoption SHALL be refused and the next feed merges. WHEN no enabled `notUse`
rule exists, THE SYSTEM SHALL NOT pay for the exclusion mask (the 500k-media
pipeline stays unchanged).

Rules: `DIR-1` ... `DIR-12`, `RULE-15`.

## Non-goals

- A virtual timeline or EDL, and any muxing or rewriting of source files.
- Rule priority; overlapping rules are a user-visible duplicate, not an error.
- A derived group index; it was tried and removed.
- VM-merging the Sub Audio candidate pool.
- Persisting a dual-time sync choice as anything other than a normal setting.
- Hiding a group whose duration is unknown instead of degrading it.
