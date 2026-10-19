# AGENTS.md — IRIS Project Guide

IRIS is a lightweight, cross-platform video/audio player built with Flutter. It targets
**Android** and **Windows** desktop (CI also emits Linux-compatible builds), and supports
local files, WebDAV, and FTP. Package `iris`, version `1.6.0+6` (`pubspec.yaml`), MPL-2.0.

> `.ai_knowledge/`, `.opensquilla/`, `.commandcode/` are gitignored, local-only, and stale.
> Do not read them as rules and do not reference them.

## CRITICAL RULES

- NEVER push directly to `main` or `dev`. Push branches only; touch `main`/`dev` only when
  explicitly asked.
- NEVER bump the Drift `schemaVersion` without adding a matching migration script under
  `lib/models/db/migration/`.
- NEVER commit AI work unless the user explicitly asks to commit. When asked, commit to the
  working branch (NOT the `-ai-tmp` record branch) with a suitable English
  conventional-commit message — use the user's if provided, otherwise author one.
- NEVER whole-tree restore across branches (`git restore --source=<ref> .`). Return AI work
  only via the recorded per-file list; prefer `.githooks/ai-checkpoint.ps1`.

## Tech Stack

| Concern | Library | Notes |
|---|---|---|
| State | `flutter_zustand` | Zustand stores. NOT Riverpod. |
| DB | `drift` (SQLite) | Tables / DAOs / repositories / migrations. Schema **v51**. |
| Models | `freezed` + `json_serializable` | All domain models and DTOs. |
| Widgets | `flutter_hooks` | `HookWidget` preferred over `StatefulWidget`. |
| Playback | `media_kit` + `fvp` | Two swappable backends (`AppState.playerBackend`). |
| Secret/legacy persistence | `flutter_secure_storage` | Legacy settings blob. |
| Localization | Flutter ARB | `en` + `zh`, deferred loading. |
| Theming | `dynamic_color` + `google_fonts` | Material 3. |

## Repo Map

`lib/features/*` are vertical slices, one module per feature:

- `app_identity` — custom desktop entries (icon/name bound to a scenario + tag).
- `background_playback` — 副音 (secondary-audio) mapping + candidate-source rules.
- `media_library` — library browsing, recursive scan, selection, play queue.
- `meta_settings` — metadata-driven settings engine (defs / values / feature flags).
- `osd` — desktop keyboard transient HUD.
- `paginated_browser` — generic paged-browser component.
- `phone` — phone gesture guide + one-handed scrubber.
- `playback_tools` — screenshot, frame-step, open-with.
- `scenario_playback` — scenario-driven playback.
- `settings_transfer` — import/export + transfer audit.
- `speed` — speed-gesture model + settings contribution.
- `tag_play` — tag-based virtual collections + tag-view playback.
- `virtual_media` — virtual-media (VM) rules, merging, playback planner.
- `webdav_discovery` — SSDP/subnet discovery + connect coordination.
- `window` — desktop playlist dock.
- `windows` — Windows shell integration (context menu, keyboard, recycle bin, desktop bar).

Other key paths:

- `lib/models/db/` — global Drift layer: `app_database.dart` (schema), `db_module.dart`
  (DAO→repository wiring), `tables/`, `dao/`, `repositories/`, `adapters/`,
  `migration/` (`v2`–`v51`).
- `lib/store/` — global Zustand stores; `persistent_store.dart` is the `PersistentStore<T>`
  base class (`load`/`save` lifecycle).
- `lib/pages/` — top-level pages (`home/`, `player/`, `bootstrap_gate.dart`).
- `lib/widgets/adaptive/` — canonical keyboard-form shell (`keyboard_form_shell.dart`,
  `keyboard_inset_padder.dart`).
- `lib/l10n/` — `app_en.arb` (template) / `app_zh.arb`.
- `test/` — unit/widget tests; shared fixtures in `test/helpers/`.

## Architecture

- **State:** global state lives in Zustand stores extending `PersistentStore<T>`. Consume in
  widgets via `useXStore().select(context, (s) => s.value)`. Keep widgets dumb; put logic,
  mutations, and DB access in stores.
- **DB:** Drift runs on the UI isolate (`NativeDatabase`, not `createInBackground`) — never
  persist per keystroke; debounce or commit on blur/submit.
- **Startup:** `main.dart` → `AppPaths.init()` (portable-mode decision; MUST precede any DB
  or store init) → desktop `windowManagerEnsureReady()` → `runApp(StoreScope(BootstrapGate))`.
  Heavy init lives in `lib/app_startup.dart:completeStartupInitialization()` (DB,
  `DbModule.init`, feature bootstraps, `fvp.registerWith`). Feature availability is gated at
  runtime via `DefVisibility.registerPrefix` — unavailable functionality must never be shown.
- **Settings:** new features/settings ship through the metadata-driven stack
  (`lib/features/meta_settings/`, Drift + AUX rows, `useMetadataSettings` gate ON). The legacy
  `PersistentStore` secure-storage path is FROZEN — do not add options to it.
- **New features are modular:** add a module under `lib/features/<name>/` following the
  vertical-slice layout (`model/` incl. `db/{tables,dao,repositories,adapters}`, `domain`,
  `enum`; `store/`; `view/`; `services/`; plus `resolver/`, `playback/`, `contributions/`,
  `commands/` as needed). Do NOT scatter feature code into `lib/pages/` or unrelated modules;
  only genuinely cross-cutting pieces go in `lib/widgets/` / `lib/utils/`. Mirror the existing
  16 modules.
- **Models:** Freezed as `abstract class Model with _$Model`, with the mandatory `part`
  headers and `@Default()` for defaults.
- **Imports:** always absolute `package:iris/...`; never relative.

## Commands

Codegen — mandatory after ANY Freezed or Drift change:
```bash
flutter pub get; dart run build_runner build --delete-conflicting-outputs
```

Tests (TDD is mandatory for behavior changes: Red → Green → Refactor):
```bash
flutter test                       # full suite
flutter test test/<file>_test.dart # single test
```

Lint: `flutter analyze` (flutter_lints; `invalid_annotation_target` ignored, custom_lint off).

Build:
```bash
flutter build windows
flutter build apk --split-per-abi
dart run msix:build --store true
dart run msix:pack --store true --output-name IRIS-windows-store
```

Localization: add the key to `lib/l10n/app_en.arb` in the same change, consume via
`getLocalizations(context).key` (`lib/utils/get_localizations.dart`), then run
`flutter gen-l10n`; mirror `app_zh.arb` before release.

## Conventions

- **Localization:** never hardcode user-facing strings; never build display text by
  concatenation — use ARB placeholders with runtime args. Every new feature ships its
  `app_en.arb` key in the same change (zero exemptions). Developer logs, technical constants
  (URLs, storage keys, enum names, route paths), and test names are out of scope.
- **Feedback:** never use SnackBar / `ScaffoldMessenger.showSnackBar`; use a Dialog
  (`showDialog`) for info, confirmation, and errors.
- **Comments:** explain the "Why"/design intent, not the "What"; concise English.

## Keyboard / IME Contract

- Input popups use the canonical shell: `showAdaptiveKeyboardForm` + `KeyboardFormScaffold`
  + `KeyboardInsetPadder` (`lib/widgets/adaptive/`). Single-field prompts use
  `showKeyboardTextPrompt`. Never hand-roll a shell or padder.
- Never read `MediaQuery.viewInsetsOf` inside a form — only the leaf padder may. Input-bearing
  popups MUST NOT be `AlertDialog`.
- Never rebuild a form per keystroke or persist per keystroke; controllers own the text and
  commit on submit/blur. `autofocus` is desktop-only.
- Ship a `debugOnFormBuild` seam + a widget test asserting zero form rebuilds on `viewInsets`
  change (`test/keyboard_form_shell_test.dart` is the reference).

## Gotchas

- **Android versionCode:** lives in `android/version.properties`, auto-incremented by
  `.githooks/pre-commit` (base 2025). Enable hooks with `git config core.hooksPath .githooks`.
  Never edit it downward.
- **pubspec build number:** `pubspec.yaml`'s `version: X.Y.Z+N` build number is kept
  equal to the Android `versionCode` by the same `pre-commit` hook (via
  `scripts/sync-version-code.sh`). Never hand-edit the `+N`; a release commit changes only
  `X.Y.Z`.
- **Split vs universal APK:** `flutter build apk --split-per-abi` rewrites versionCode to
  `ABI×1000 + base` (arm64 = base+2000), while `flutter run` keeps the plain base. Installing
  a split APK then running via Android Studio is a versionCode DOWNGRADE → forced uninstall +
  data loss. Manual installs must use the universal APK. Run
  `scripts/check-apk-install.ps1` (or `.sh`) before any manual `adb install`.
- **Git deps pinned:** `drives_windows` is pinned to a commit because newer main requires
  `win32 ^6`, conflicting with `package_info_plus` (`win32 ^5`); bump both together.
  `media_stream` tracks `main`.
- **Windows semantics:** `wrapPlatformSemantics` (`lib/main.dart`) intentionally excludes the
  Windows semantics tree to dodge an engine AXTree-corruption bug. Do not remove it as a
  "fix".
- **Portable mode:** presence of `portable.flag` next to the exe redirects all data to
  `userdata/`; `AppPaths.init()` must run before any DB/store init.
- **CHANGELOG encoding:** `CHANGELOG.md` is strict-valid UTF-8 without BOM; Chinese
  mojibake in GBK viewers (codepage 936 console, `Get-Content` without `-Encoding utf8`,
  legacy Notepad) is a viewer artifact, not corruption. Do NOT re-encode or add BOM.

## Release Process (private → public mirror)

Public releases are cut from a dedicated **squash branch** that mirrors the public
repository's `main`; the development branch is never rewritten.

1. **Release commit on the development branch.** Add ONE `chore(release): vX.Y.Z` commit: a new
   `## vX.Y.Z` CHANGELOG section (English `### Changelog` + Chinese `### 更新日志`) plus the
   `X.Y.Z` bump in `pubspec.yaml`. Let the `pre-commit` hook bump `versionCode` and sync the
   `+N`; push fast-forward.
2. **Squash one commit onto the squash branch.** The tip tree must be byte-identical to the
   development branch's release commit, and its parent must be the current public `main` tip
   (fast-forward). Build it WITHOUT checking the branch out, so the working tree is untouched:
   ```bash
   tree=$(git show -s --format=%T <dev-release-commit>)
   new=$(git commit-tree "$tree" -p <squash-tip> -m "feat: X.Y.Z — <headline items>")
   git branch -f <squash-branch> "$new"
   git diff <squash-branch> <dev-release-commit> -- .   # must be empty
   ```
   Message style: `feat: X.Y.Z — <three or four headline items>`.
3. **Publish.** Push the squash branch to the **public** repository's `main` (fast-forward). A
   push to `main` there triggers that repo's `ci.yml` → `build-android` + `build-windows` →
   `release` (tag `vX.Y.Z`, notes extracted from `CHANGELOG.md` by `extract_log.py`, all
   artifacts plus `SHA256SUMS.txt`).

- Preferred path is the manual `workflow_dispatch` sync workflow
  (`.github/workflows/sync-to-public.yml`): it uses a repository secret for public-repo write
  access, so credentials are centralised and auditable. Dispatch it **on the squash branch**
  and leave the message override empty so the baked commit message is kept. A direct
  fast-forward push is the fallback when the secret / `gh` is unavailable.
- Publishing needs write access to the public repository (the CI secret, or the local git
  credential helper for a direct push). Never commit a real token.

Desensitized on purpose: repository URLs and token/secret names are placeholders here because
this file is mirrored to the public repository.

## AI Session Conventions

- Reply in the user's language (Chinese or mixed).
- Keep the working branch `X` **uncommitted** during a session so `git status` / `git diff`
  show exactly what the AI changed.
- **Explicit commit request:** commit to `X` (NOT `-ai-tmp`) the working-tree changes, with an
  English conventional-commit message — the user's if given, otherwise AI-authored.
- `-ai-tmp` record branches are only for automatic checkpoints (audit trail).
- **Checkpoint:** `.githooks/ai-checkpoint.ps1 -Message "<conventional message>"`. Guardrails:
  (R1) create `<X>-ai-tmp-commit-YYYYMMDD[-N]` fresh from the current tip of `X`; (R2) reset
  `android/version.properties` to `X`'s value after stash pop; (R3) return ONLY the recorded
  per-file list — never whole-tree; (R4) verify the final path set equals the pre-stash
  snapshot.
- Commit messages: English, conventional-commit style (`feat(...)`, `fix(...)`, `chore(...)`,
  `docs(...)`).
