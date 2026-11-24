# IRIS feature documentation

This tree is the in-repo record of how a feature is meant to behave, why it is
built that way, and how each claim is held. It mirrors the shape used by the
sibling projects: spec-driven, test-driven, behaviour-named, with no Gherkin
runner. Flutter's `test()`/`group()` stays the executor; the rule register is
the link between a sentence and a test.

## Layout

```
docs/
  README.md                               this file
  features/
    background-playback/                  Sub Audio (副音)
      README.md                           what the reader sees; scope; code map
      spec.md                             SDD: requirements (EARS)
      design.md                           SDD: mechanism, data model, invariants
      rules.md                            BDD+TDD: normative case register
      recurrences.md                      the complaints and couplings that return
      testing.md                          TDD: gates, fixtures, device checks
      tasks.md                            open work and accepted gaps
      decisions/                          append-only ADRs
        README.md
        0001-...md ... 0016-...md
    fake_cut/                             Virtual Cut (虚拟剪播)
      README.md                           what the reader sees; scope; code map
      spec.md                             SDD: requirements (EARS)
      design.md                           SDD: mechanism, data model, invariants
      rules.md                            BDD+TDD: normative case register
      recurrences.md                      the complaints and couplings that return
      testing.md                          TDD: gates, fixtures, device checks
      tasks.md                            open work and accepted gaps
      decisions/                          append-only ADRs
        README.md
        0001-...md ... 0008-...md
    virtual_media/                        Virtual Media (virtual merge)
      README.md                           what the reader sees; scope; code map
      spec.md                             SDD: requirements (EARS)
      design.md                           SDD: mechanism, data model, invariants
      rules.md                            BDD+TDD: normative case register
      recurrences.md                      the complaints and couplings that return
      testing.md                          TDD: gates, fixtures, device checks
      tasks.md                            open work and accepted gaps
      decisions/                          append-only ADRs
        README.md
        0001-...md ... 0037-...md
    video_transform/                      Picture adjustment (mirror/rotate/color)
      README.md                           what the reader sees; scope; code map
      spec.md                             SDD: requirements (EARS)
      design.md                           SDD: mechanism, data model, invariants
      rules.md                            BDD+TDD: normative case register
      recurrences.md                      the complaints and couplings that return
      testing.md                          TDD: gates, fixtures, device checks
      tasks.md                            open work and accepted gaps
      decisions/                          append-only ADRs
        README.md
        0001-...md ... 0008-...md
    window/                               Desktop playlist dock (画面全屏 side queue)
      README.md                           what the reader sees; scope; code map
      spec.md                             SDD: requirements (EARS)
      design.md                           SDD: mechanism, data model, invariants
      rules.md                            BDD+TDD: normative case register
      recurrences.md                      the complaints and couplings that return
      testing.md                          TDD: gates, fixtures, device checks
      tasks.md                            open work and accepted gaps
      decisions/                          append-only ADRs
        README.md
        0001-...md ... 0003-...md
```

## What each document owns

| Document | Owns | Does not own |
| --- | --- | --- |
| `README.md` | what the reader sees, scope, code map | mechanism, normative rules |
| `spec.md` | one EARS sentence per requirement | implementation detail |
| `design.md` | mechanism, data model, invariants | acceptance criteria |
| `rules.md` | the normative case register and its coverage | prose rationale longer than a sentence |
| `recurrences.md` | symptoms that return and cross-module couplings | a changelog |
| `testing.md` | how each gate is run | what the behaviour is |
| `tasks.md` | open work and accepted gaps | the rule register |
| `decisions/` | why a decision was made and what was rejected | the current behaviour |

A sentence moves between documents; it is not copied.

## Status vocabulary

- **shipped** - in a released build.
- **in progress** - on a development branch, not released.
- **planned** - agreed, not built.

## Coverage tokens

Every row in `rules.md` names how it is held:

| Token | Meaning |
| --- | --- |
| `F:<file>#<test name>` | a literal test name in `test/<file>.dart`; it must fail when the rule breaks |
| `F:<file>` | a file-level fallback for parameterised or generated tests whose name is not a literal |
| `D:<nnnn>` | the governing decision record |
| `M` | needs a human on a device; the step is in `testing.md` |
| `-:<reason>` | deliberately not held by an executable test; the reason is the whole point |

`scripts/check-bg-rules.ps1`, `scripts/check-fake-cut-rules.ps1`,
`scripts/check-vm-rules.ps1`, `scripts/check-video_transform-rules.ps1` and
`scripts/check-window-rules.ps1` resolve every `F:` token, every `D:` token and
every `decisions/` link for their feature. They do not read git history.

## Provenance and the public mirror

Short SHAs in `rules.md`, `recurrences.md` and `decisions/*.md` cite the private
development history. The public repository receives one squashed commit per
release (`.github/workflows/sync-to-public.yml`), so those SHAs do **not**
resolve there. They are provenance, not links: the prose in this tree is the
authoritative record, and the checker never validates a SHA.

## How to read history

The private clone carries many `*-ai-tmp-commit-*` checkpoint branches. They
re-submit the same work under a near-identical message, so `git log --all`
shows apparent churn that never happened. Read the development branch only.

## Writing rules

- One observable behaviour per sentence.
- A rule that stops being true is **superseded**, not deleted: keep the row and
  point at the decision that replaced it.
- A decision record is append-only; a reversed decision keeps its text and
  gains a `Superseded by` line.
- No real local path, library root, media title or account name. Use the
  documented stand-ins (`C:\work\...`, `D:/Videos/...`, `a.mp4`, `USER`).

## Features

| Feature | Status | Entry |
| --- | --- | --- |
| Background playback (Sub Audio, 副音) | shipped (v2.1.0) | `features/background-playback/README.md` |
| Virtual Cut (虚拟剪播) | shipped (v2.1.0; joins a merge in v2.1.2) | `features/fake_cut/README.md` |
| Virtual Media (virtual merge) | shipped (v2.1.0; cut plans join in v2.1.2) | `features/virtual_media/README.md` |
| Picture adjustment (video transform) | shipped (v2.1.2) | `features/video_transform/README.md` |
| Desktop playlist dock (window) | shipped (v2.1.1) | `features/window/README.md` |
