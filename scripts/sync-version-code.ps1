#Requires -Version 7
<#
.SYNOPSIS
  Sync pubspec.yaml's build number (+N) to the Android versionCode.

.DESCRIPTION
  Windows twin of scripts/sync-version-code.sh (see that file for the contract).
  The single source of truth is android/version.properties; this rewrites ONLY
  the `+N` part of `version: X.Y.Z+N`, preserving X.Y.Z. Idempotent: a no-op
  when already in sync. Invoked by .githooks/pre-commit (which runs under Git's
  sh, so the .sh is the one that fires there) and by .githooks/ai-checkpoint.ps1.

.EXAMPLE
  pwsh -NoProfile -File scripts/sync-version-code.ps1
#>
$ErrorActionPreference = 'Stop'

$root = (git rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
    $root = (Get-Location).Path
}
$props = Join-Path $root 'android/version.properties'
$pub = Join-Path $root 'pubspec.yaml'

if (-not (Test-Path -LiteralPath $props)) { throw "[sync-version] missing $props" }
if (-not (Test-Path -LiteralPath $pub)) { throw "[sync-version] missing $pub" }

$m = Select-String -LiteralPath $props -Pattern '^versionCode=(\d+)' | Select-Object -First 1
$code = if ($m) { $m.Matches[0].Groups[1].Value } else { '0' }

$raw = Get-Content -LiteralPath $pub -Raw
$v = [regex]::Match($raw, '(?m)^version:[ \t]*([^\r\n]+)')
if (-not $v.Success) { throw "[sync-version] no 'version:' line in $pub" }

$cur = $v.Groups[1].Value.Trim()
$base = ($cur -split '\+')[0]
$target = "$base+$code"
if ($cur -eq $target) { return }

$newRaw = $raw.Substring(0, $v.Index) + "version: $target" + $raw.Substring($v.Index + $v.Length)
# WriteAllText keeps LF (no BOM); Set-Content would normalize line endings.
[System.IO.File]::WriteAllText($pub, $newRaw)
Write-Host "[sync-version] pubspec: $cur -> $target"
