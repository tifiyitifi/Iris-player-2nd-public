# Virtual Cut - recurrences

The complaints that keep returning, and the couplings that cause them.

| ID | Symptom | Root cause | Held by | Coupling to watch |
| --- | --- | --- | --- | --- |
| R1 | "It cut the wrong episode" | Pairing guessed from the `.llc` stem, ignoring the recorded `mediaFileName` | `FC-01`, `D:0001` | any new source of project paths (picker, network, import) |
| R2 | "I created a `.llc` and nothing happened" | Directory cache was only dropped by the tab's button | `FC-03`, `D:0007` | a new filesystem-watching path must call the same invalidate |
| R3 | "I edited the cut but it replayed the old one" | EDL cache keyed by path or `mtime:size` instead of plan content | `FC-09`, `D:0003` | any new artefact derived from the plan (subtitles, thumbnails) |
| R4 | "The tab says the cut is on, playback/merge shows the source" | An unreadable plan, a wrong backend, or an inactive-but-bound project was treated as active | `FC-08`, `FC-10`, `FC-12`, `D:0003`, `D:0005` | the merge's active-path hand-off and path spellings (VM `XFEAT-22`) |
| R5 | "Progress jumped to the wrong place" | Cut time written into source progress, or a multi-hit resume guessed | `FC-06`, `FC-11`, `D:0002` | any new seek/resume surface (phone dial, OSD, external intents) |
| R6 | "副音 stopped for the other video" | Stand-down keyed on "a cut is playing" instead of "this file's EDL is open" | `FC-13`, `D:0006` | a second window opening a different file |
| R7 | "The subtitle timings are wrong" | Cue re-time fell back to source timing on a parse failure | `FC-14`, `D:0002` | new subtitle formats and BOM/encoding variants |
