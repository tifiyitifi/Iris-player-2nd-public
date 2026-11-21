#!/usr/bin/env pwsh
# check-vm-rules.ps1 - resolve the Virtual Media rule register.
#
# Parses docs/features/virtual_media/rules.md and checks:
#   - F:<file>#<test name> resolves to a literal test in test/<file>.dart
#   - F:<file> resolves to an existing test file
#   - D:<nnnn> resolves to a decision record under decisions/
#   - every filename in decisions/README.md resolves
#   - every "Superseded by: NNNN" target resolves
#
# It deliberately does NOT read git history: the public repository receives a
# squashed history, so private SHAs do not resolve there.
#
# ASCII-only. Exit 1 when a row claims coverage it does not have, or a link
# points nowhere.

[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$rulesRel = 'docs/features/virtual_media/rules.md'
$decisionsRel = 'docs/features/virtual_media/decisions'
$testRel = 'test'

function Parse-Coverage([string]$line) {
  # Backticks are markdown decoration; strip them before matching.
  $clean = $line.Replace(([char]96).ToString(), '')
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($m in [regex]::Matches($clean, 'F:([A-Za-z0-9_]+)(?:#([^;|]+))?')) {
    $name = $m.Groups[2].Value
    if ($name) { $name = $name.Trim() }
    $out.Add([pscustomobject]@{ Kind = 'F'; File = $m.Groups[1].Value; Name = $name })
  }
  foreach ($m in [regex]::Matches($clean, 'D:(\d{4})')) {
    $out.Add([pscustomobject]@{ Kind = 'D'; File = $null; Name = $m.Groups[1].Value })
  }
  return $out
}

if ($SelfTest) {
  $sample = '| X-1 | c | e | b | w | `F:foo_test#a name`; `F:bar_test`; `D:0007` |'
  $tokens = Parse-Coverage $sample
  $ok = ($tokens.Count -eq 3) -and
        ($tokens[0].Kind -eq 'F') -and ($tokens[0].File -eq 'foo_test') -and ($tokens[0].Name -eq 'a name') -and
        ($tokens[1].Kind -eq 'F') -and ($tokens[1].File -eq 'bar_test') -and (-not $tokens[1].Name) -and
        ($tokens[2].Kind -eq 'D') -and ($tokens[2].Name -eq '0007')
  if (-not $ok) {
    Write-Host '[FAIL] self-test: the coverage parser changed shape'
    exit 1
  }
  Write-Host '[OK] self-test'
  exit 0
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $scriptDir }
Set-Location $RepoRoot

$failures = New-Object System.Collections.Generic.List[string]
function Fail([string]$msg) { $script:failures.Add($msg) }

$rulesPath = $rulesRel
if (-not (Test-Path $rulesPath)) {
  Write-Host "[FAIL] missing $rulesPath"
  exit 1
}

$rows = 0
foreach ($line in (Get-Content $rulesPath -Encoding utf8)) {
  if (-not $line.StartsWith('|')) { continue }
  $cells = $line.Split('|')
  if ($cells.Count -lt 4) { continue }
  $id = $cells[1].Trim()
  if ($id -notmatch '^[A-Z]{2,5}-\d+$') { continue }
  $rows++

  foreach ($tok in (Parse-Coverage $line)) {
    if ($tok.Kind -eq 'F') {
      $testPath = Join-Path $testRel ($tok.File + '.dart')
      if (-not (Test-Path $testPath)) {
        Fail "$id : missing test file $testPath"
        continue
      }
      if ($tok.Name) {
        $content = Get-Content $testPath -Raw -Encoding utf8
        if (-not $content.Contains($tok.Name)) {
          Fail "$id : '$($tok.Name)' not found in $testPath"
        }
      }
    }
    elseif ($tok.Kind -eq 'D') {
      $match = Get-ChildItem $decisionsRel -Filter "$($tok.Name)-*.md" -ErrorAction SilentlyContinue
      if (-not $match) { Fail "$id : D:$($tok.Name) has no decision record" }
    }
  }
}

if ($rows -eq 0) { Fail 'rules.md has no rule rows' }

$indexPath = Join-Path $decisionsRel 'README.md'
if (Test-Path $indexPath) {
  $index = Get-Content $indexPath -Raw -Encoding utf8
  foreach ($m in [regex]::Matches($index, '(\d{4})-[A-Za-z0-9\-]+\.md')) {
    $target = Join-Path $decisionsRel $m.Value
    if (-not (Test-Path $target)) { Fail "decisions/README.md : dead link $($m.Value)" }
  }
}

if (Test-Path $decisionsRel) {
  foreach ($adr in (Get-ChildItem $decisionsRel -Filter '*.md')) {
    if ($adr.Name -eq 'README.md') { continue }
    $text = Get-Content $adr.FullName -Raw -Encoding utf8
    foreach ($m in [regex]::Matches($text, 'Superseded by:\s*(\d{4})')) {
      $targetId = $m.Groups[1].Value
      $match = Get-ChildItem $decisionsRel -Filter "$targetId-*.md" -ErrorAction SilentlyContinue
      if (-not $match) { Fail "$($adr.Name) : Superseded by $targetId has no record" }
    }
  }
}

if ($failures.Count -gt 0) {
  foreach ($f in $failures) { Write-Host "[FAIL] $f" }
  Write-Host "[FAIL] $($failures.Count) problem(s)"
  exit 1
}

Write-Host "[OK] $rows rule rows resolved"
exit 0
