<#
.SYNOPSIS
  Local release gate for IRIS: the checks CI does not run.

.DESCRIPTION
  `.github/workflows/ci.yml` only runs `pub get`, `build_runner` and the two
  platform builds. It never runs `flutter analyze` or `flutter test`, so a
  release can currently ship compile-clean but untested code. This script is
  the local gate that closes that hole: codegen, localization, ARB parity,
  analyzer errors, the full test suite, and (with -Release) the release-note
  and tree-cleanliness invariants that the squash flow depends on.

  Deliberately NOT wired into `.githooks/pre-push`: codegen plus the full test
  suite costs minutes, and a slow push hook gets bypassed by habit. Run it by
  hand before a release:

      pwsh -File scripts/release-gate.ps1                # fast: analyze + tests
      pwsh -File scripts/release-gate.ps1 -Release       # + release readiness
      pwsh -File scripts/release-gate.ps1 -Release -Build # + both artifacts

  Every step is fail-fast in the summary but all steps still run, so one run
  reports every broken gate instead of only the first.

.PARAMETER Release
  Also assert release readiness: pubspec build number matches the Android
  versionCode, CHANGELOG.md starts with `## v<version>` and carries both the
  English and the Chinese section, and the working tree is clean (the squash
  commit is built from a committed tree, so a dirty tree guarantees a wrong
  release).

.PARAMETER Build
  Also build the Windows release bundle and the universal Android APK. Slow.
  The Android release build needs `android/key.properties` and its keystore.

.PARAMETER SkipCodegen
  Skip `flutter pub get` + `build_runner`. Use only when generated code is
  known fresh.

.PARAMETER SkipTests
  Skip `flutter test`. Use for a quick analyzer-only pass.

.EXAMPLE
  pwsh -File scripts/release-gate.ps1 -Release
#>
[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$Build,
    [switch]$SkipCodegen,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$results = New-Object System.Collections.ArrayList

function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

# Runs one gate step, records the outcome, and keeps going so a single run
# reports every failure. A thrown error (or a non-zero native exit code turned
# into one by Invoke-Native) marks the step failed.
function Invoke-GateStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    Write-Head $Name
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $true
    $detail = ''
    try {
        & $Action
    } catch {
        $ok = $false
        $detail = $_.Exception.Message
        Write-Host "  FAILED: $detail" -ForegroundColor Red
    }
    $sw.Stop()
    $seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    if ($ok) {
        Write-Host ("  done in {0:N1}s" -f $seconds) -ForegroundColor Green
    }
    [void]$results.Add([pscustomobject]@{
            Step    = $Name
            Ok      = $ok
            Seconds = $seconds
            Detail  = $detail
        })
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @()
    )
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Exe $($Arguments -join ' ') exited with $LASTEXITCODE"
    }
}

# Top-level ARB keys only: exactly two spaces of indentation. Deeper keys belong
# to placeholder metadata and must not be compared across locales.
function Get-ArbKeys([string]$Path) {
    $keys = @()
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^  "([^"]+)"\s*:') {
            $key = $Matches[1]
            if (-not $key.StartsWith('@')) { $keys += $key }
        }
    }
    return $keys
}

Push-Location $repoRoot
try {
    # --- Metadata: one source of truth is pubspec.yaml + version.properties ---
    $rawVersion = (Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
    $version = $rawVersion.Split('+')[0]
    $buildNumber = if ($rawVersion.Contains('+')) { [int]$rawVersion.Split('+')[1] } else { 0 }
    $versionCode = [int]((Select-String -Path 'android/version.properties' -Pattern '^versionCode=(\d+)').Matches[0].Groups[1].Value)
    Write-Host "IRIS $version  (pubspec +$buildNumber, android versionCode $versionCode)" -ForegroundColor Cyan

    Invoke-GateStep 'Version lockstep (pubspec +N == Android versionCode)' {
        if ($buildNumber -ne $versionCode) {
            throw "pubspec says +$buildNumber but android/version.properties says $versionCode; the pre-commit hook keeps these in lockstep (scripts/sync-version-code)"
        }
    }

    # --- Codegen: mandatory after ANY Freezed or Drift change ---
    if ($SkipCodegen) {
        Write-Host ''
        Write-Host '==> Codegen (skipped)' -ForegroundColor DarkGray
    } else {
        Invoke-GateStep 'flutter pub get' {
            Invoke-Native 'flutter' @('pub', 'get')
        }
        Invoke-GateStep 'build_runner' {
            Invoke-Native 'dart' @('run', 'build_runner', 'build', '--delete-conflicting-outputs')
        }
    }

    Invoke-GateStep 'flutter gen-l10n' {
        Invoke-Native 'flutter' @('gen-l10n')
    }

    # --- Localization: the template locale is authoritative ---
    Invoke-GateStep 'ARB key parity (app_en is the template)' {
        $en = @(Get-ArbKeys 'lib/l10n/app_en.arb')
        $zh = @(Get-ArbKeys 'lib/l10n/app_zh.arb')
        if ($en.Count -eq 0) { throw 'no keys parsed from lib/l10n/app_en.arb' }
        $missing = @($en | Where-Object { $zh -notcontains $_ })
        if ($missing.Count -gt 0) {
            throw ("app_zh.arb is missing {0} key(s): {1}" -f $missing.Count, (($missing | Select-Object -First 10) -join ', '))
        }
        $extra = @($zh | Where-Object { $en -notcontains $_ })
        if ($extra.Count -gt 0) {
            Write-Host ("  note: {0} key(s) exist only in app_zh.arb: {1}" -f $extra.Count, (($extra | Select-Object -First 10) -join ', ')) -ForegroundColor Yellow
        }
        Write-Host ("  {0} keys per locale" -f $en.Count)
    }

    # --- Analyzer: errors fail, infos/warnings do not (CI runs neither) ---
    Invoke-GateStep 'flutter analyze (errors only)' {
        Invoke-Native 'flutter' @('analyze', '--no-fatal-infos', '--no-fatal-warnings')
    }

    if ($SkipTests) {
        Write-Host ''
        Write-Host '==> flutter test (skipped)' -ForegroundColor DarkGray
    } else {
        Invoke-GateStep 'flutter test' {
            Invoke-Native 'flutter' @('test')
        }
    }

    # --- Release readiness: the invariants the squash/publish flow relies on ---
    if ($Release) {
        Invoke-GateStep "Release readiness (CHANGELOG v$version)" {
            # Explicit UTF-8: the notes carry Chinese, and Windows PowerShell 5.1
            # decodes a BOM-less UTF-8 file with the ANSI codepage, which mangles
            # the section headings (and this script is saved as UTF-8 WITH BOM so
            # its own `### 更新日志` literal is parsed correctly too).
            $lines = @(Get-Content -LiteralPath 'CHANGELOG.md' -Encoding UTF8)
            if ($lines.Count -eq 0) { throw 'CHANGELOG.md is empty' }
            $header = "## v$version"
            if ($lines[0].Trim() -ne $header) {
                throw "CHANGELOG.md must start with '$header', found '$($lines[0].Trim())'. extract_log.py matches this line exactly; a missing section publishes an empty release."
            }
            $section = @()
            if ($lines.Count -gt 1) {
                foreach ($line in $lines[1..($lines.Count - 1)]) {
                    if ($line.StartsWith('## ')) { break }
                    $section += $line
                }
            }
            if (-not ($section | Where-Object { $_.Trim() -eq '### Changelog' })) {
                throw "the v$version section has no '### Changelog' heading"
            }
            if (-not ($section | Where-Object { $_.Trim() -eq '### 更新日志' })) {
                throw "the v$version section has no '### 更新日志' heading"
            }
            $items = @($section | Where-Object { $_ -match '^\d+\.\s+\S' })
            if ($items.Count -eq 0) {
                throw "the v$version section has no numbered entries, so the release notes would be empty"
            }
            Write-Host ("  {0} numbered entries" -f $items.Count)
        }

        Invoke-GateStep 'Working tree is clean (squash takes a committed tree)' {
            $dirty = @(git status --porcelain)
            if ($dirty.Count -gt 0) {
                throw ("{0} uncommitted path(s): {1}" -f $dirty.Count, (($dirty | Select-Object -First 5) -join '; '))
            }
        }
    }

    # --- Real artifacts: the only checks that prove the public CI can compile ---
    if ($Build) {
        Invoke-GateStep 'flutter build windows' {
            Invoke-Native 'flutter' @('build', 'windows')
        }
        Invoke-GateStep 'flutter build apk --flavor tifi7' {
            Invoke-Native 'flutter' @('build', 'apk', '--flavor', 'tifi7')
        }
    }

    # --- Summary ---
    Write-Host ''
    Write-Host '--- gate summary ---' -ForegroundColor Cyan
    foreach ($result in $results) {
        $mark = if ($result.Ok) { 'PASS' } else { 'FAIL' }
        $color = if ($result.Ok) { 'Green' } else { 'Red' }
        Write-Host ("  [{0}] {1} ({2:N1}s)" -f $mark, $result.Step, $result.Seconds) -ForegroundColor $color
        if (-not $result.Ok -and $result.Detail) {
            Write-Host ("         {0}" -f $result.Detail) -ForegroundColor Red
        }
    }
    $failed = @($results | Where-Object { -not $_.Ok })
    if ($failed.Count -gt 0) {
        Write-Host ("{0} gate step(s) failed." -f $failed.Count) -ForegroundColor Red
        exit 1
    }
    Write-Host 'All gates passed.' -ForegroundColor Green
    exit 0
} finally {
    Pop-Location
}
