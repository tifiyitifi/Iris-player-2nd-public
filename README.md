<img height="100px" width="100px" alt="logo" src="./assets/images/logo.png"/>

# IRIS - A Second-Development Fork of the Upstream IRIS Project

[English](./README.md) | [中文](./README_CN.md)

## About This Project (Fork Notice)

This project is a second-development fork of the open-source IRIS project:

https://github.com/nini22P/Iris

The upstream project provides a lightweight local / WebDAV / FTP video player;
this fork goes further into playback organization and the desktop experience,
adding scenario playback, virtual media, tag play, sub-audio (background voice)
synchronized playback, the MediaDb media library, a PotPlayer-aligned desktop
keymap, and much more (see "Added in this fork"). The main differences from
upstream are summarized in the comparison table below.

This project inherits the MPL-2.0 license; the `LICENSE` file is unchanged, and
dependency and source copyright notices are also kept as-is.

## Features

Inherited from upstream:
- [X] Base on [Media Kit](https://github.com/media-kit/media-kit) | [FVP](https://github.com/wang-bin/fvp), supports multiple video formats
- [X] Local storage, WebDAV and FTP support
- [X] Switchable subtitle and audio track
- [X] Playback queue support for random and repeat
- [X] Comprehensive gesture support
- [X] Custom desktop entries: personalized icon & name, bindable to a scenario + tag for independent playback

Added in this fork (see below for details):
- [X] Metadata-driven settings engine (database persistence, import/export)
- [X] Scenario playback: named, reusable playback plans (override / append / batch generation)
- [X] Virtual media rules and merged playback
- [X] Tag virtual collections with a numeric command grammar
- [X] Sub-audio synchronized playback (second track + A-P-B timeline mapping)
- [X] MediaDb media library (recursive scan / resumable scan / standalone search)
- [X] PotPlayer desktop keymap, rebindable keys, A-B section repeat
- [X] Desktop context menu, docked playlist, keyboard OSD
- [X] WebDAV wildcard host auto-discovery
- [X] Screenshot / frame step / open-with, settings transfer with a password audit log

## Differences From Upstream

| Area            | Upstream IRIS              | This fork                                                        |
| :-------------- | :------------------------- | :--------------------------------------------------------------- |
| Settings        | Single config in secure storage | Metadata-driven settings engine, database persistence, import/export with encrypted migration |
| Playback organization | Play files/queues directly | Three layers: scenarios (named plans) + virtual media merging + tag collections |
| Sub audio       | None                       | Second-track synchronized playback with A-P-B mapping and candidate-source rules |
| Media library   | Directory browsing         | MediaDb index library, recursive/resumable scans, path tree and standalone search |
| Desktop keyboard | Fixed keymap              | PotPlayer scheme, rebindable keys, `;` prefix sequences, A-B repeat, recycle-bin delete |
| Desktop UI      | Floating queue             | Context menu, docked playlist (with fullscreen hover reveal), 3-row control bar, keyboard OSD |
| Network storage | Fixed addresses            | WebDAV wildcard host auto-discovery (cache → SSDP → subnet scan) |
| Updates         | Check upstream releases    | No in-app update check (fetch new builds from this project's Releases page yourself) |

## Added in This Fork

All features below are new in this fork; upstream IRIS does not have them.
Each entry notes where to find it.

### 1. Metadata-driven settings engine

Settings are declared as data driving one shared renderer, storage layer and
visibility logic. Values persist in the database; legacy configuration is
imported once on first enable. Entry: the Settings popup tabs
Play / General / About / Dependencies. Some experimental rows only appear while
the metadata settings system is on.

### 2. Scenario playback

Stores "where to play from, how to order, how to repeat" as named, reusable
plans, separate from runtime state. Entry: Storages popup → **Scenarios**.
- Play Override: replace the current playing workspace and start playback
- Play Append: merge content without clearing the current scope
- Preview queue: read-only resolved result, never persisted
- Create scenario: single or batch auto-generate (name pattern + count + start index)
- Source management: directory sources, item sources, directory/item exclude rules
- Scan sources: refresh a scenario's resolved media

### 3. Virtual media

Merge multiple segments into one virtual item for continuous playback via
rules. Entry: Settings → Play → virtual media. Rule changes reflect in scenario
lists immediately; works together with tag views.

### 4. Tag virtual collections

Collections by tag instead of by directory; every tag keeps its own playback
bookmark, and switching tags swaps the play list. Entry: player More menu /
Settings → General → Tag play.
- Command bar (desktop): `+n` add, `-n` remove, `*n` switch to tag view, dot-joined ordinals (e.g. `+1.2.5`)
- Retention policy (keep forever / auto-clear) and jump-back window
- Pin presets: save the current pinned-tag order as a named preset
- Built-in reserved tags: Favorite (permanent retention + jump-back) and background-voice candidate (default sub-audio source)

### 5. Sub-audio synchronized playback

Plays a second audio/video track in sync with the main video (e.g. another dub
or commentary). Entry: control-bar sub-audio menu / Settings → Play → sub audio.
- A-P-B timeline mapping: align a foreground window to a background file's interval, saved per video
- Candidate source rules: match by tag members, folders, single files or intersections, in order
- Control handoff: the bar/keys/gestures can target the video or the sub audio; a blue frame marks the target
- Alignment tuning: snapping, stretch-ratio warnings (outside 0.5×–2.0×), runs-out reminder

### 6. MediaDb media library

A persistent media index over scanned storage. Entry: the **MediaDb** tab;
scan options: Settings → General → library scan.
- System libraries auto-maintained per storage; removed storages' nodes move to a Detached library, never silently deleted
- Three views: path tree (with breadcrumbs), all media, all directories; sort by name/size/duration/resolution/modified
- Recursive scan: progress overlay, pause/resume/interruption-resume, optional deep probing of duration and resolution
- Standalone search page: paged search with scopes (all / current-dir recursive / direct), highlight, play single / folder / append / override
- Bulk selection: multi-select then enqueue, override queue, play folder, set as source, remove from library (index only, disk files untouched)

### 7. Custom desktop entries

Create desktop entries with a custom icon and name (Android home-screen
shortcuts), each with an independent playback workspace bindable to a scenario
+ tag. Entry: Settings → General → Custom desktop entries. Android 8.0+;
some third-party launchers are unsupported.

### 8. Phone gestures and one-handed scrubbing

Entry: Settings → Play → gesture layout / one-handed.
- Gesture region editor: assign actions per intent (tap / double tap / long press / swipe), with left/right-hand layouts
- Gesture guide overlay: openable from the player More menu, visualizing the current layout
- One-handed ring dial: dual-ring scrubber in landscape side controls (whole-media wayfinding + in-block fine scrub), thumb-reachable corner shortcuts
- Speed gesture: single axis (horizontal 0.1 steps only) / dual axis (horizontal 0.1 + vertical 1.0)

### 9. Desktop keyboard

Two keymap schemes, switchable in **Settings → Play →
Keyboard shortcut scheme**:
- **PotPlayer (Windows)**: aligned with PotPlayer's official Windows defaults (see key tables)
- **IRIS classic**: the original bindings, always active while the metadata system is off
- Rebindable keys: bind multiple combos per action with conflict detection; desktop only
- `;` prefix sequences: `; F` storages, `; H` history, `; P` docked queue, `; R` repeat, `; X` shuffle
- A-B section repeat: `[` sets A, `]` sets B and loops, `B` quick arm/reset
- `Shift + Delete`: move the playing file to the Recycle Bin (Windows only, confirmable)

### 10. Desktop UI

- Context menu: PotPlayer-style right-click player menu (open / playback / video / audio / subtitle / window / panels)
- Docked playlist: desktop right-side queue panel with draggable width and fullscreen hover reveal (right-edge hot zone)
- Desktop control bar layout: classic single line / PotPlayer-style three rows
- Keyboard OSD: transient on-screen feedback for desktop key actions (volume / seek / speed / track switches), 9-grid placement; entry: Settings → General → keyboard OSD

### 11. WebDAV auto-discovery

A storage entry's host can be a wildcard (e.g. `192.168.1.*`); the actual device
is found automatically on connect: cache hit → SSDP discovery → subnet scan.
Wrong passwords are reported explicitly instead of triggering silent rescans.
Entry: the add/edit WebDAV storage dialog; lookup mode: Settings → General →
WebDAV host lookup.

### 12. Playback tools and data transfer

- Screenshot: save the current frame as PNG (mediaKit backend required); phones get a draggable floating panel plus a direct More-menu item
- Frame step: tap for a single step (pauses first), long-press for continuous stepping; entry: More menu → frame tools
- Open with (Android only): hand a local file to another app
- Screenshot directory: Settings → Play → screenshot save directory (separate for mobile/desktop)
- Settings import/export: Settings → General → data; per-section (settings/history/favorites/scenarios/tag play/virtual media/network storages), passphrase encryption enforced when network storages are included
- Password import/export log: audits every password-touching transfer (time/operation/encryption/result), clear-all only

## Download

Builds of this project (Windows portable zip, Android APKs) are published on
the project's **Releases** page. Download the latest version from there.

> **Build status**: Only the **Windows portable ZIP** has been manually tested.
> The Windows installer, the Microsoft Store MSIX and all Android APKs are
> produced automatically by CI and have **not** been manually tested.

## Android Packages

Android native libraries are architecture-specific, so IRIS publishes three
split APKs plus one universal APK:

- `IRIS-android-arm64-v8a-*.apk` — 64-bit ARM. **Most phones** released since
  around 2016 use this.
- `IRIS-android-armeabi-v7a-*.apk` — 32-bit ARM. Older or low-end devices.
- `IRIS-android-x86_64-*.apk` — x86_64 emulators and the rare Intel device.
- `IRIS-android-universal-*.apk` — carries every architecture above, so it
  installs on any supported device.

A split APK contains only its own architecture's native libraries, which makes
it much smaller; the universal APK contains all of them, so its installed size
is roughly two to three times larger.

**If you do not know your phone's architecture, take the universal APK** — at
the cost of a larger install size. Otherwise just try `arm64-v8a` first: it
covers the vast majority of phones. If the install is rejected as
architecture-incompatible, try another split or switch to the universal APK.

### Switching between packages

All four APKs share one package name and signing key, and Android compares
their versionCode on install. A split APK's versionCode is rewritten to
`ABI × 1000 + base` (arm64-v8a = base + 2000); the universal APK keeps the
plain base. So:

- universal → any split APK: an upgrade; installs over the existing app and
  keeps all data.
- any split APK → universal: a downgrade; Android rejects it
  (`INSTALL_FAILED_VERSION_DOWNGRADE`) unless you uninstall first.
- between splits: `x86_64` (base + 4000) > `arm64-v8a` (base + 2000) >
  `armeabi-v7a` (base + 1000); going down is a downgrade.

To get past a downgrade without losing data, either use
`adb install -r -d <apk>` (needs the same signing key — true for official
builds), or uninstall, reinstall and restore from a settings export. The same
applies to developers: installing a split APK and then running from Android
Studio is a downgrade, so use the universal APK for manual installs and run
`scripts/check-apk-install.ps1` before any `adb install`.

**Settings export/import** (Settings → General → data) covers settings, history,
favorites, scenarios, tag play, virtual media and network storages (including
passwords, protected by a passphrase you choose). It does **not** cover the
media library index, scan states, local storage paths, the play queue or the
current playback position — after a reinstall, re-add local storages and rescan
the media library.

## Portable Edition (Windows)

The Windows portable package (download it from the **Releases** page) is a
no-install build: unzip and run. Please note:

- **Data location**: All data (media library database, scenarios, tag play, playback history, UI settings, etc.) lives in the `userdata\` folder next to the exe (`db\` for the databases, `settings\` for UI state). To move it elsewhere or to another PC, copy the whole folder.
- **In-app update**: **Settings → About → Check update** downloads the new package and runs the same updater for you: IRIS closes, the updater window shows the overwrite, and IRIS reopens on the new version (if the updater cannot run at all, IRIS stays open and says why). It writes a log and keeps the downloaded package in `userdata\updates\`; the next launch reports whether the update landed, and a package that did not is kept so the `.bat` below can finish the job by hand.
- **One-click update (manual)**: after downloading a new portable package from the **Releases** page, double-click `portable_update_by_zip.bat` next to the exe, then paste or drag in the zip file (or its folder). The script runs dual verification (file name + `iris.exe` inside), compares versions (upgrade proceeds automatically, downgrade auto-backs up `userdata`), waits for IRIS to exit, and overwrites program files while keeping `userdata\` intact. Update is overlay-only: obsolete program files from older versions are never deleted, and `userdata\` (plus timestamped `userdata.bak_*` backups) is never touched.
- **Migrating from the installed version**: On first launch on the same machine, the portable build offers to import the installed version's data; the original data is left untouched.
- **Passwords do not travel**: WebDAV / FTP credentials are kept by the operating system's encrypted storage and bound to the current computer; they are NOT part of `userdata\` and must be re-entered after moving machines.
- **Security notice**: When the metadata-driven settings system is enabled, network-storage passwords are stored in plaintext inside the database file at `userdata\db\`. Do not share a folder containing password data with others; delete the affected storage entries (or clear their passwords) before sharing. See **Settings → About → Data & password storage** in the app for full details.
- **Advanced**: Set the environment variable `IRIS_NO_PORTABLE=1` to force installed-mode behavior (data stays in the system locations).

## Keyboard and Gesture Controls

Two desktop keyboard schemes are available. Switch them in **Settings → Play →
Keyboard shortcut scheme**:

- **PotPlayer (Windows)** — the default while the experimental *metadata
  settings system* is enabled; aligned with PotPlayer's official Windows keys.
- **IRIS classic** — the original bindings below. Always active while the
  metadata system is off, so upgrading never changes existing behavior.

### Keyboard Controls

#### IRIS classic

| Key                    | Description                                        |
| ---------------------- | -------------------------------------------------- |
| `Space`              | Play / Pause / Select file                         |
| `Arrow Left`         | Fast backward                    |
| `Arrow Right`        | Fast forward                    |
| `Arrow Up`           | Volume up                                          |
| `Arrow Down`         | Volume down                                        |
| `Ctrl + Arrow Left`  | Previous                                           |
| `Ctrl + Arrow Right` | Next                                               |
| `Ctrl + X`           | Shuffle                                            |
| `Ctrl + R`           | Repeat                                             |
| `Ctrl + V`           | Video zoom                                         |
| `Ctrl + M`           | Volume mute                                        |
| `S`                  | Subtitles and audio tracks                         |
| `P`                  | Play queue                                         |
| `F`                  | Storages                                           |
| `Ctrl + O`           | Open file                                          |
| `Ctrl + L`           | Open link                                          |
| `Ctrl + C`           | Close currently media file                         |
| `Ctrl + H`           | Play history                                       |
| `Ctrl + P`           | Settings                                           |
| `+`                  | Step forward                                       |
| `-`                  | Step backward                                      |
| `Enter`              | Enter full screen / Exit full screen / Select file |
| `F11`                | Enter full screen / Exit full screen               |
| `Esc`                | Exit current Menu / Go back / Exit full screen     |
| `F10`                | Toggle always on top                               |
| `Alt + X`            | Exit application                                   |

#### PotPlayer (Windows)

Strict replacement: a key either performs its PotPlayer action or does nothing —
it never falls back to an IRIS-classic binding.

| Key                 | Description                                            |
| ------------------- | ------------------------------------------------------ |
| `Space`             | Play / Pause                                           |
| `Enter` / `Alt + Enter` | Fullscreen toggle                                  |
| `Esc`               | Exit fullscreen                                        |
| `Arrow Up/Down`     | Volume up / down                                       |
| `Arrow Left/Right`  | Seek backward / forward by the seek-step setting       |
| `Ctrl + Arrow Left/Right` | Big seek (dynamic ×2–×6 of the base step)        |
| `Page Up/Down`      | Previous / next item                                   |
| `D` / `F`           | Previous / next frame                                  |
| `X` / `C` / `Z`     | Slower / faster speed (hold to run) / reset speed      |
| `M`                 | Mute                                                   |
| `Backspace`         | Restart from the beginning                             |
| `G`                 | Jump to time                                           |
| `L` / `A`           | Subtitle & audio track panel                           |
| `J`                 | Cycle fit mode (contain → fill → cover → 1:1)          |
| `F3` / `Ctrl + O`   | Open file                                              |
| `Ctrl + U`          | Open link                                              |
| `F4`                | Close playback                                         |
| `F5`                | Settings                                               |
| `F6`                | Play queue                                             |
| `Ctrl + T`          | Toggle always on top                                   |
| `Alt + X`           | Exit application                                       |
| `Context Menu`      | More menu                                              |
| `Alt + L` / `Alt + A` | Cycle subtitle / audio track                         |
| `Alt + H`           | Show / hide subtitles                                  |
| `>` `<` `/`         | Subtitle sync +0.5s / −0.5s / reset                    |
| `Shift + >` `,` `/` | Audio sync +0.5s / −0.5s / reset                       |
| `Ctrl + Home`       | Jump to middle                                         |
| `Shift + Backspace` | Jump to 30s before the end                             |
| `K` / `Ctrl + E`    | Capture current frame (PNG, mediaKit backend)          |
| `Shift + Delete`    | Move playing file to Recycle Bin (Windows, confirmable)|

Prefix sequences (`;` then one more key) host features that have no PotPlayer
default key; a small indicator shows while waiting, and any other legal key
cancels the sequence and runs normally:

| Sequence | Description        |
| -------- | ------------------ |
| `; F`    | Storages           |
| `; H`    | Play history       |
| `; R`    | Repeat mode        |
| `; X`    | Shuffle            |

A-B section repeat: `[` sets point A, `]` sets point B (arms the loop),
`\` toggles it, and `B` is a quick arm/reset toggle; an indicator chip shows
while looping.

Hardware media keys (play/pause, previous, next) keep working under both schemes.
Keys whose PotPlayer functions are not implemented yet (`B`, `K`, `H`, `V`, `Tab`,
`F11`, …) stay intentionally unbound until those capabilities land.

### Gesture Controls

| Gesture                           | Description                   |
| --------------------------------- | ----------------------------- |
| Tap                               | Select an item or open a menu |
| Double tap center                 | Play / Pause                  |
| Double tap left side              | Fast backward                |
| Double tap right side             | Fast forward                  |
| Swipe left / right                | Adjust playback progress      |
| Swipe up / down on left side      | Adjust screen brightness      |
| Swipe up / down on right side     | Adjust device volume          |
| Long press                        | Display Playback Speed Selector |
| Long press and swipe left / right | Adjust speed playback speed   |

## Custom Desktop Entries

In **Settings → General → Custom desktop entries** you can create desktop
launchers for IRIS with your own icon and name, optionally bound to an
independent playback configuration (requires the metadata settings system).

### Creating an entry

1. Pick an image, crop and scale it freely
2. Enter a custom name
3. (Optional) Bind a scenario and a tag — launching via this entry plays
   that configuration
4. Tap "Create & pin" and confirm the system dialog

| Platform | Behavior                                                                 |
| :------- | :----------------------------------------------------------------------- |
| Android  | Adds a home-screen shortcut; the original IRIS icon stays and can be removed manually |
| Windows  | Creates a shortcut on the Desktop; Start-menu/taskbar icons are unchanged |

### Editing & deleting

- **Edit anytime**: reopen the editor to change the image or name — the
  desktop entry updates in place after saving
- Deleting: on Windows simply delete the .lnk file from the Desktop;
  on Android the app cannot remove an already-pinned shortcut (system
  limitation) — long-press the icon to delete it manually

### Playback binding rules

- Each entry binds its own scenario + tag pair and remembers its own last
  playback position
- Launching via a custom entry resumes through the bound scenario; with a
  bound tag, the tag view is entered automatically
- Launching via the default icon restores the default playback state
- If a bound scenario or tag is deleted, the entry prompts to re-bind or
  falls back to normal playback

### Known limitations

- Uninstalling the app removes its shortcuts automatically
- Clearing app data may invalidate existing shortcuts; recreate them in Settings
- Some third-party launchers do not support adding shortcuts; Android 8.0+ required

## Contribution

Contributions of any kind are welcome! If you have suggestions, bug reports, or want to add new features, please submit an issue or directly submit a Pull Request.

## Sponsorship

TBD.

## License

This project is licensed under the MPL-2.0 license. For more details, please see the [LICENSE](./LICENSE) file.
