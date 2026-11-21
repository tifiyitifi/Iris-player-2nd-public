# Installs the local privacy gate for this clone.
#
# The gate itself is tracked (`.githooks/*`, `scripts/check-local-paths.ps1`),
# so this script does not write hooks. It does the two things a fresh clone
# cannot carry:
#
#   1. point git at the tracked hook directory (`core.hooksPath`);
#   2. create the gitignored deny list and seed it with the machine account and
#      the checkout's machine-specific ancestor folder names.
#
# The deny list has to be local: CI cannot run the gate, and a term that names
# this machine must never reach the repository. Re-running is safe; an existing
# deny list is extended, never overwritten.
#
# Exit code 1 means git is unavailable or the repository is not a checkout.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$root = [System.IO.Path]::GetFullPath($root)

& git -C $root rev-parse --git-dir > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: not a git checkout: $root"
    exit 1
}

& git -C $root config --local core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: could not set core.hooksPath"
    exit 1
}
Write-Host "hooks: core.hooksPath = .githooks"

$denyDir = Join-Path $root '.local_privacy'
$denyFile = Join-Path $denyDir 'deny-list.txt'
$example = Join-Path $root 'scripts/local-gate-deny-list.example.txt'

if (-not (Test-Path -LiteralPath $denyDir)) {
    New-Item -ItemType Directory -Path $denyDir -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $denyFile)) {
    if (Test-Path -LiteralPath $example) {
        Copy-Item -LiteralPath $example -Destination $denyFile
        Write-Host "created: $denyFile"
    } else {
        New-Item -ItemType File -Path $denyFile -Force | Out-Null
        Write-Host "created: $denyFile (no example file found)"
    }
}

$existing = @(Get-Content -LiteralPath $denyFile -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })

function Add-Term([string]$term, [string]$reason) {
    if ([string]::IsNullOrWhiteSpace($term)) { return }
    if ($term.Length -lt 3) { return }
    foreach ($line in $existing) {
        if ([string]::Equals($line, $term, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }
    Add-Content -LiteralPath $denyFile -Value '' -Encoding UTF8
    Add-Content -LiteralPath $denyFile -Value "# $reason" -Encoding UTF8
    Add-Content -LiteralPath $denyFile -Value $term -Encoding UTF8
    $script:existing += $term
    Write-Host "added: $term ($reason)"
}

Add-Term $env:USERNAME 'machine account (added automatically)'

# The checkout folder name is the strongest local identifier that is not a
# generic word. Ancestor segments are deliberately not added: a short folder
# name such as `workd` collides with ordinary code (`workDir`) and turns the
# audit into noise; the path pattern already catches the full ancestor path.
$stop = @(
    'Users', 'Android', 'Desktop', 'Documents', 'Downloads', 'work', 'dev',
    'src', 'home', 'tmp', 'temp', 'out', 'AppData', 'Local', 'Roaming'
)
$leaf = Split-Path -Leaf ([System.IO.Path]::GetFullPath($root).TrimEnd([char[]]'\/'))
if ($leaf -and ($stop -notcontains $leaf) -and $leaf.Length -ge 4) {
    Add-Term $leaf 'checkout folder (added automatically)'
}

Write-Host "deny list: $denyFile"
Write-Host 'This file is gitignored and must never be committed.'
Write-Host 'Run scripts/check-local-paths.ps1 -All to audit the tracked tree.'
