# 0001 - Pair a project by its recorded source name

- Date: 2026-11-23
- Status: accepted
- Private history: feature work (no single commit)
- Supersedes: none
- Superseded by: none

## Context

A folder may hold `ep01.mp4` and `ep02.mp4` with one `.llc` each. Matching a
project to a video by the project's file name alone (or by "nearest stem")
silently cut the wrong episode when LosslessCut used a suffix or the user renamed
the project. The `.llc` itself records the source file name.

## Decision

`mediaFileName` from the parsed project is authoritative. The stem fallback is
used only when the name is unreadable (older projects, hand-edited files), and
then LosslessCut's default suffixes are stripped before comparing. Matching is
case-insensitive on case-insensitive filesystems. A project naming no video in
the folder is an orphan: visible in the tab, never activatable.

## Consequences

- Pairing is a per-directory computation: the index keeps every project's
  recorded name so a video added later can bind to an existing orphan.
- A renamed source turns its project into an orphan until the name is fixed.
