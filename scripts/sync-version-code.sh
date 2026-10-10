#!/usr/bin/env sh
# Keep pubspec.yaml's build number (`version: X.Y.Z+N`) equal to the Android
# versionCode in android/version.properties.
#
# Single source of truth is android/version.properties (auto-incremented by
# .githooks/pre-commit). This rewrites ONLY the `+N` part, preserving the X.Y.Z
# marketing version. Idempotent: a no-op when already in sync. Called by
# .githooks/pre-commit, so the two files can never drift.
#
# Usage: sh scripts/sync-version-code.sh
set -eu

root=$(git rev-parse --show-toplevel 2>/dev/null || echo .)
props="$root/android/version.properties"
pub="$root/pubspec.yaml"

[ -f "$props" ] || { echo "[sync-version] missing $props" >&2; exit 1; }
[ -f "$pub" ] || { echo "[sync-version] missing $pub" >&2; exit 1; }

code=$(sed -n 's/^versionCode=\([0-9][0-9]*\).*/\1/p' "$props")
code=${code:-0}

cur=$(sed -n 's/^version:[[:space:]]*//p' "$pub" | head -n1)
[ -n "$cur" ] || { echo "[sync-version] no 'version:' line in $pub" >&2; exit 1; }

base=${cur%%+*}
target="$base+$code"
[ "$cur" = "$target" ] && exit 0

# Portable in-place replace (macOS/BSD sed lacks `-i` without a suffix).
tmp="$pub.tmp"
sed "s|^version:.*|version: $target|" "$pub" > "$tmp"
mv "$tmp" "$pub"
echo "[sync-version] pubspec: $cur -> $target"
