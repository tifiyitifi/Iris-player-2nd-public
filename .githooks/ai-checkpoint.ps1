#Requires -Version 7
<#
.SYNOPSIS
  AI checkpoint with guardrails (AGENTS.md R1-R4).

.DESCRIPTION
  Records the current uncommitted AI work onto a FRESH dated record branch
  while keeping the working branch X in its "uncommitted changes" state.

  Guardrails (hardened after the 2026-08 settings-v2 incident):
   R1  fresh dated branch <X>-ai-tmp-commit-YYYYMMDD[-N], created from the
       CURRENT tip of X - never reuse a stale/diverged record branch.
   R2  android/version.properties is reset to X's value right after the pop
       so the pre-commit hook increments the TRUE mainline base; the file is
       excluded from the return trip in both directions. pubspec.yaml's build
       number is re-synced to that base afterwards (step 10).
   R3  the return trip restores ONLY the per-file list captured before
       stashing. Whole-tree restore across branches is forbidden.
   R4  end-state verification: the working-tree path set must equal the
       pre-stash snapshot, otherwise this script FAILS loudly.

.PARAMETER Message
  Conventional-style commit message for the record-branch checkpoint commit.

.EXAMPLE
  ./.githooks/ai-checkpoint.ps1 -Message "feat(settings): add engine funnel"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Message
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$msg) {
    Write-Host "[ai-checkpoint] FAIL: $msg" -ForegroundColor Red
    Write-Host '[ai-checkpoint] if a stash named "ai-save" exists, recover with: git stash pop' -ForegroundColor Yellow
    exit 1
}

function Step([string]$msg) {
    Write-Host "[ai-checkpoint] $msg" -ForegroundColor Cyan
}

function Invoke-Git {
    # Runs git, fails loudly on non-zero exit.
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    $out = & git @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Write-Host $_ }
        Fail "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE)"
    }
    return ,$out
}

function Test-GitRefExists([string]$ref) {
    # Existence probe: quiet git emits NO output in EITHER case, so the
    # decision MUST come from $LASTEXITCODE. Truthiness of the output would
    # always be $false and silently pass a colliding branch name.
    & git show-ref --verify --quiet "refs/heads/$ref"
    return ($LASTEXITCODE -eq 0)
}

function Test-GitPathExists([string]$rev, [string]$path) {
    # Same exit-code discipline as Test-GitRefExists.
    & git cat-file -e "$rev`:$path" 2>$null
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
# 0. Preconditions
# ---------------------------------------------------------------------------
$X = (Invoke-Git 'rev-parse' '--abbrev-ref' 'HEAD') | Select-Object -First 1
if ($X -match '-ai-tmp-commit') {
    Fail "refusing to checkpoint FROM a record branch ('$X'); switch to the working branch first"
}

Write-Host "[ai-checkpoint] working branch: $X"

# ---------------------------------------------------------------------------
# 1. [R4] Pre-stash snapshot (paths only, sorted). Includes untracked;
#        version.properties is recorded but permanently excluded from the
#        return trip by R2.
# ---------------------------------------------------------------------------
$before = @(git status --porcelain |
    ForEach-Object { $_.Substring(3) } |
    Sort-Object)
if ($before.Count -eq 0) { Fail 'nothing to checkpoint (clean working tree)' }
Step ("snapshot: {0} path(s)" -f $before.Count)

# ---------------------------------------------------------------------------
# 2. Stash everything (tracked + untracked).
# ---------------------------------------------------------------------------
Step 'stash push -u'
Invoke-Git 'add' '-A'
Invoke-Git 'stash' 'push' '-u' '-m' 'ai-save'

# ---------------------------------------------------------------------------
# 3. [R1] Fresh dated record branch from the CURRENT tip of X.
# ---------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd'
$record = "$X-ai-tmp-commit-$stamp"
$suffix = 2
while (Test-GitRefExists $record) {
    $record = "$X-ai-tmp-commit-$stamp-$suffix"
    $suffix++
}
Step "fresh record branch: $record"
Invoke-Git 'checkout' '-b' $record

# ---------------------------------------------------------------------------
# 4. Pop the stash back onto the fresh branch.
# ---------------------------------------------------------------------------
Step 'stash pop'
Invoke-Git 'stash' 'pop'

# ---------------------------------------------------------------------------
# 5. [R2] Reset versionCode base to X's value BEFORE committing, so the
#        pre-commit hook increments the TRUE mainline number here.
# ---------------------------------------------------------------------------
Step 'R2: reset android/version.properties to X base'
Invoke-Git 'checkout' $X '--' 'android/version.properties'

# ---------------------------------------------------------------------------
# 6. Commit on the record branch (hook fires HERE).
# ---------------------------------------------------------------------------
Step "commit: $Message"
Invoke-Git 'add' '-A'
Invoke-Git 'commit' '-m' $Message

# ---------------------------------------------------------------------------
# 7. Back to X.
# ---------------------------------------------------------------------------
Step "switch back to $X"
Invoke-Git 'checkout' $X

# ---------------------------------------------------------------------------
# 8. [R3] Explicit-list return trip. Files DELETED by the AI work do not
#        exist in the record tree -> re-delete them instead of restoring.
# ---------------------------------------------------------------------------
$returnFiles = @($before | Where-Object { $_ -ne 'android/version.properties' })
$deleted = @()
$present = @()
foreach ($f in $returnFiles) {
    if (Test-GitPathExists $record $f) { $present += $f } else { $deleted += $f }
}
if ($present.Count -gt 0) {
    Step ("restore {0} path(s) from record" -f $present.Count)
    Invoke-Git 'restore' "--source=$record" '--staged' '--worktree' '--' @present
}
if ($deleted.Count -gt 0) {
    Step ("re-delete {0} path(s) removed by the AI work" -f $deleted.Count)
    Invoke-Git 'rm' '-f' '-q' '--' @deleted
}

# ---------------------------------------------------------------------------
# 9. Unstage everything: X keeps its changes UNCOMMITTED.
# ---------------------------------------------------------------------------
Invoke-Git 'reset' '--mixed' | Out-Null

# ---------------------------------------------------------------------------
# 10. Re-sync pubspec.yaml's build number to X's versionCode. The record-branch
#     commit above ran the pre-commit hook (which bumps versionCode and writes
#     the matching `+N` into pubspec), and the return trip may have brought that
#     bumped pubspec back. Normalize it so X's working tree is never left with
#     pubspec and version.properties disagreeing. No-op when already in sync.
# ---------------------------------------------------------------------------
Step 'R2b: sync pubspec build number to versionCode'
$repoRoot = (Invoke-Git 'rev-parse' '--show-toplevel') | Select-Object -First 1
& (Join-Path $repoRoot 'scripts/sync-version-code.ps1')

# ---------------------------------------------------------------------------
# 11. [R4] End-state verification: path set must equal the snapshot.
# ---------------------------------------------------------------------------
$after = @(git status --porcelain |
    ForEach-Object { $_.Substring(3) } |
    Sort-Object)

$mismatch = Compare-Object -ReferenceObject $before -DifferenceObject $after
if ($mismatch) {
    Write-Host '[ai-checkpoint] end-state mismatch:' -ForegroundColor Red
    $mismatch | ForEach-Object {
        $arrow = if ($_.SideIndicator -eq '<=') { 'missing' } else { 'unexpected' }
        Write-Host ("  {0}: {1}" -f $arrow, $_.InputObject) -ForegroundColor Red
    }
    Fail 'working-tree path set does not match the pre-stash snapshot'
}

$tip = (Invoke-Git 'log' '-1' '--format=%h %s' $record) | Select-Object -First 1
Write-Host "[ai-checkpoint] OK: checkpointed onto '$record'" -ForegroundColor Green
Write-Host "[ai-checkpoint]     record tip : $tip"
Write-Host ("[ai-checkpoint]     paths      : {0} (verified == snapshot)" -f $after.Count)
