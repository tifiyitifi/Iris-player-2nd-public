# Checks that local, private material is not about to be committed.
#
# The repository is shared and may be published; the machine it is built on is
# not. Five shapes must never reach a tracked file or a commit message:
#
#   1. a local path        a drive letter with a separator, a UNC share, a home
#                          directory or a leading `~/`
#   2. local data          a DB/WAL/journal file, `portable.flag`, `userdata/`,
#                          or a local-only scratch directory (`.local_privacy/`,
#                          `.ai_knowledge/`, `.opensquilla/`, ...)
#   3. a private term      an account, library folder, media title or host name;
#                          the list is `.local_privacy/deny-list.txt`
#   4. a credential URL    `scheme://user:password@host`, which is a secret even
#                          when the path itself is public
#   5. a real title+episode in prose (`CHANGELOG.md`, `AGENTS.md`, `README*`,
#                          `docs/**`); test fixtures and UI strings are exempt
#
# Modes:
#
#   (default)   check what is staged, file names included. If nothing is
#               staged, check the working diff of tracked files. A staged binary
#               file is named in a warning: its bytes are never read, only its
#               name is checked.
#   -All        audit every tracked file. A drive letter that is already
#               committed is a warning, not a failure, so the mode stays usable
#               as an audit.
#   -Pushed     check the commits that are about to leave the machine: their
#               messages, and every line each commit added (not only the net
#               tree diff, so an add-then-remove is still caught). The
#               pre-push hook passes the exact `<remote sha>..<local sha>`
#               range git reported, or the mode falls back to the branch
#               upstream / default branch / whole branch.
#   -Message    check the message git just wrote. The commit-msg hook passes
#               the file it received with `-MessageFile` (COMMIT_EDITMSG for a
#               normal commit, MERGE_MSG for a merge). Without it the mode
#               falls back to `git rev-parse --git-path COMMIT_EDITMSG`.
#
# A path inside `test/` fails like any other: a tracked test is expected to use
# the stand-in roots listed below, and a real path there is still local
# material.
#
# The stand-in roots are a deliberate trade-off: the repository already uses
# generic examples (`C:\work`, `D:/Videos`, `E:/vault`, `D:/Photos/IRIS`, ...),
# so those roots are accepted. A real name below one of them is not detectable
# here; the deny list and the manual rule in AGENTS.md cover it.
#
# The script is deliberately plain ASCII: Windows PowerShell 5.1 reads a .ps1
# without a byte-order mark in the system code page, so a pattern written with
# a literal non-ASCII character silently becomes a different pattern there.
# Samples are assembled at run time for the same reason, and the self-test
# below fails loudly if a pattern stops matching what it is supposed to.
#
# Exit code 1 means something it must not. Exit code 2 means the check itself is
# broken (a pattern, a filter or a git command no longer answers).

param(
    [switch]$All,
    [switch]$Pushed,
    [switch]$Message,
    [string]$MessageFile = "",
    [string]$Range = "",
    [string]$Root = ""
)

$ErrorActionPreference = "Stop"

# Git writes paths and diff text as UTF-8; 5.1 reads native output with the
# console encoding, so name the encoding instead of hoping for the default.
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch {
    # No console attached; git output is then decoded with the default.
}

# -Root exists for the test suite, which runs the script against a throwaway
# repository. The hooks never pass it.
if (-not $Root) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$root = [System.IO.Path]::GetFullPath($Root)
$denyList = Join-Path $root ".local_privacy/deny-list.txt"

# A drive letter followed by a separator, a UNC share, a home directory or a
# leading `~/`. A bare `C:` in prose is not matched.
#
# The roots in $publicRoot name a tool, a documented stand-in or an existing
# generic example. Anything else after a drive letter is local.
$publicRoot = '(Program Files|Windows|Qt|work|videos|Movies|Videos|Media|media|media2|Photos|vault|VAULT|dl|app|a|b|c|x)'
# The rest of the stand-in roots are a path spelled inside a test string, not a
# place on a disk: `C:/tmp/a.png`. The form is pinned to a forward slash, which
# is how a fixture is written, so the same words written with backslashes - the
# way a real scratch folder is spelled - are still local.
$fixtureRoot = '(tmp|temp|out|another)'
# Test files may use a few more generic roots; `Users` is handled separately
# and is never a stand-in.
$testRoot = '(\.{1,3}|Apps|Download|Other|IRIS|iris[0-9A-Za-z-]*|library|keep|other|vault[0-9A-Za-z]*|kid|missing|y|z|s|dir)'
$pathPattern = ('\b[A-Za-z]:[\\/][^\s"''`)>]+' +
    '|\\\\[A-Za-z0-9._$-]{2,}[\\/][^\s"''`)>]*' +
    '|(^|[\s"''(/])/Users/[A-Za-z0-9._-]+' +
    '|(^|[\s"''(/])/home/[A-Za-z0-9._-]+')
# Dart uses `~/` for integer division, so a home path is only a path in prose;
# there it is checked by $tildePattern instead of the general path pattern.
$tildePattern = '(^|[\s"''(/])~[\\/][A-Za-z0-9._-]'

# A non-Latin title, then the word "episode" (U+96C6), then a number. The space
# before "episode" is optional, because the natural Chinese form usually has
# none. Find-TitleEpisode rejects the navigation-prose shape without relying on
# a lookbehind, which the two PowerShell runtimes do not agree on. The pattern
# is only applied to prose files; see Test-ProseFile.
$titlePattern = '[\u3400-\u4dbf\u4e00-\u9fff]{3,}\s*\u7b2c\s*\d+\s*\u96c6'

# A URL that carries userinfo with a password. `https://user@host` is not this
# shape. The fragments are concatenated so this file does not match itself.
$credPattern = ('(?i)\b(?:https?|ftps?|sftp|webdav|dav|smb)' + ':' + '//' +
    '[^\s/@:]+:[^\s/@]+@')

# Files whose very presence in a commit is the leak.
$dataPattern = '(^\.local_privacy/|^\.ai_knowledge/|^\.opensquilla/|^\.commandcode/|^\.opencode/|(^|/)userdata/|(^|/)portable\.flag$|\.(sqlite|db|wal|shm|journal)$)'

# Text files worth reading in audit mode. Generated files are skipped
# separately; translations are left out of the title rule below.
$textFilePattern = '\.(md|txt|json|yaml|yml|dart|arb|ps1|psm1|sh|bat|cmd|py|gradle|kts|properties|xml|java|kt)$'

$deny = @()
$denyMissing = -not (Test-Path -LiteralPath $denyList)
if (-not $denyMissing) {
    $deny = Get-Content -Path $denyList -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" -and -not $_.StartsWith("#") }
}

# The machine's own profile and this checkout are local even when their root
# happens to be on the stand-in list. A generic placeholder account (the names
# the tests use) is skipped so the fixtures keep working.
$machinePrefixes = New-Object System.Collections.Generic.List[string]
$placeholderAccounts = @('%USERNAME%', 'USERNAME', 'u', 'me', 'user', 'A', 'Some Name', '<user>')
foreach ($candidate in @($env:USERPROFILE, $env:HOME)) {
    if (-not $candidate) { continue }
    $full = [System.IO.Path]::GetFullPath($candidate).TrimEnd([char[]]'\/')
    $name = Split-Path -Leaf $full
    if ($placeholderAccounts -contains $name) { continue }
    if ($full.Length -ge 4 -and -not $machinePrefixes.Contains($full)) {
        $machinePrefixes.Add($full)
    }
}
$rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd([char[]]'\/')
# A checkout that lives under a documented stand-in root must not treat its own
# fixtures as the machine path.
if ($rootFull -notmatch '^[A-Za-z]:[\\/](work|videos|Movies|Videos|Media|media|media2|Photos|vault|VAULT|dl|app|a|b|c|x)([\\/]|$)') {
    if ($rootFull.Length -ge 4) { $machinePrefixes.Add($rootFull) }
}

# A test file may use the wider stand-in roots.
function Test-FileName {
    param([string]$Name)
    return ($Name -match '\.test\.dart$') -or ($Name -match '^test/')
}

# Prose is where a real title is a leak; tests and UI strings are not.
function Test-ProseFile {
    param([string]$Name)
    return ($Name -match '^(CHANGELOG\.md|AGENTS\.md|README[^/]*\.md|docs/)')
}

# A drive path under a public root names a tool or a documented stand-in. The
# match keeps the whole path, so the root can be compared as a word.
function Find-LocalPath {
    param([string]$Text, [switch]$InTest)

    foreach ($match in [regex]::Matches($Text, $pathPattern)) {
        $value = $match.Value.Trim([char[]]' "''(,.;:')
        # A drive path written with escaped separators (`C:\\work`) is the same
        # stand-in; compare the collapsed form.
        $normalized = $value
        if ($normalized -match '^[A-Za-z]:') {
            $normalized = $normalized -replace '([\\/])\1+', '$1'
        }
        # A JSON escape (a drive letter, then `\n`, `\r` or `\t`) is not a path.
        if ($normalized -match '^[A-Za-z]:[\\/](n|r|t)(?=[\[\]{}",])') { continue }
        # A drive path whose first segment is a `$` interpolation names no
        # machine. Outside tests a `$` segment is still a local path.
        if ($normalized -match '^[A-Za-z]:[\\/]\$\{') { continue }
        if ($InTest -and $normalized -match '^[A-Za-z]:[\\/]\$') { continue }
        # A bare drive root is an example, not a file path.
        if ($normalized -match '^[A-Za-z]:[\\/]?$') { continue }
        # The documented nested-drive bug shape (`D:/d:/...`) is not a real path.
        if ($normalized -match '^[A-Za-z]:[\\/][A-Za-z]:[\\/]') { continue }
        # A placeholder segment (`E:/...`, `E:/...`) is an example, not a path.
        if ($normalized -match '^[A-Za-z]:[\\/](\u2026|\.{1,3})$') { continue }
        # A UNC fixture for the share parser.
        if ($normalized -match '^[\\/]{2,}server[\\/]+share([\\/]|$)') { continue }
        if ($InTest -and $normalized -match '^[\\/]{2,}(nas|host|100)[\\/]') { continue }
        # A user profile is never a stand-in. Only the generic placeholders pass.
        if ($normalized -match '^[A-Za-z]:[\\/]Users([\\/]|$)') {
            if ($normalized -match '^[A-Za-z]:[\\/]Users[\\/](%USERNAME%|USERNAME|u|me|user|A)([\\/]|$)') {
                continue
            }
            # Names with spaces or angle brackets are truncated by the path
            # pattern; check the full text from the match instead.
            $tail = $Text.Substring($match.Index)
            if ($tail -match '^[A-Za-z]:[\\/]Users[\\/](Some Name|<user>)([\\/]|)') {
                continue
            }
            return $value
        }
        # Test-only stand-in roots.
        if ($InTest -and $normalized -match ('^[A-Za-z]:[\\/](' + $testRoot + ')([\\/]|$|[^\w])')) {
            continue
        }
        # Shared stand-in roots.
        if ($normalized -match ('^[A-Za-z]:[\\/](' + $publicRoot + ')([\\/]|$|[^\w])')) {
            continue
        }
        # Fixture roots are pinned to a forward slash.
        if ($normalized -match ('^[A-Za-z]:/(' + $fixtureRoot + ')(/|$|[^\w])')) {
            continue
        }
        # Documented Unix placeholders.
        if ($normalized -match '^/Users/(u|user|me)(/|$)') { continue }
        if ($normalized -match '^/home/(u|user)(/|$)') { continue }
        # "Program Files" has a space, so the path pattern stops before it.
        $tail = $Text.Substring($match.Index)
        if ($tail -match '^[A-Za-z]:[\\/]Program Files( \(x86\))?([\\/]|$|[^\w])') {
            continue
        }
        if ($value) { return $value }
    }
    return $null
}

# Returns the first title+episode match that looks like a real title, or $null.
# A navigation verb before the episode marker ("jump to episode 2") is ordinary
# prose, not a title. The check is done here rather than with a lookbehind
# because Windows PowerShell 5.1 and PowerShell 7 disagree on the latter.
function Find-TitleEpisode {
    param([string]$Text)

    $episode = [char]0x7b2c
    # Cheap guard: every title match contains the episode marker. Most lines do
    # not, and this keeps the -All audit fast under Windows PowerShell 5.1.
    if ($Text.IndexOf($episode) -lt 0) { return $null }
    $navigation = @(
        [char]0x5230, [char]0x770b, [char]0x5f00, [char]0x9009, [char]0x8df3,
        [char]0x653e, [char]0x64ad, [char]0x8fdb, [char]0x53bb, [char]0x6765,
        [char]0x56de, [char]0x6362, [char]0x7528
    )
    foreach ($match in [regex]::Matches($Text, $titlePattern)) {
        $value = $match.Value
        $at = $value.IndexOf($episode)
        if ($at -lt 1) { continue }
        $i = $at - 1
        while ($i -ge 0 -and [char]::IsWhiteSpace($value[$i])) { $i-- }
        if ($i -ge 0 -and ($navigation -contains $value[$i])) { continue }
        return $match
    }
    return $null
}

# Returns every @{ Kind = 'path' | 'private'; Message = '...' } found on the
# line. Collecting all of them matters in -All mode, where a path is only a
# warning: a private term must not be hidden behind a path on the same line.
function Find-Problems {
    param([string]$Where, [string]$Text, [switch]$InTest, [switch]$InProse)

    $found = New-Object System.Collections.Generic.List[object]
    foreach ($prefix in $machinePrefixes) {
        if ($Text.IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $found.Add(@{ Kind = 'path'; Message = "local machine path at ${Where}: $prefix" })
            break
        }
    }
    if ($InProse) {
        $title = Find-TitleEpisode -Text $Text
        if ($title -ne $null) {
            $found.Add(@{ Kind = 'private'; Message = "real title and episode at ${Where}: $($title.Value)" })
        }
    }
    if ($InProse -and $Text -match $tildePattern) {
        $found.Add(@{ Kind = 'path'; Message = "local home path at ${Where}" })
    }
    if ($Text -match $credPattern) {
        $found.Add(@{ Kind = 'private'; Message = "credential URL at ${Where}" })
    }
    $path = Find-LocalPath -Text $Text -InTest:$InTest
    if ($path -ne $null) {
        $found.Add(@{ Kind = 'path'; Message = "local path at ${Where}: $path" })
    }
    foreach ($term in $deny) {
        if ($Text.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $found.Add(@{ Kind = 'private'; Message = "private term at ${Where}: $term" })
            break
        }
    }
    return $found.ToArray()
}

# A file whose name is the leak never reaches Find-Problem: only its content
# does. Returns a message or $null.
function Find-NameProblem {
    param([string]$Name)

    if ($Name -match $dataPattern) { return "local data in a file name: $Name" }
    $title = Find-TitleEpisode -Text $Name
    if ($title -ne $null) { return "real title and episode in a file name: $Name" }
    if ($Name -match $pathPattern) { return "local path in a file name: $Name" }
    foreach ($term in $deny) {
        if ($Name.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return "private term in a file name: $Name"
        }
    }
    return $null
}

# Samples are assembled here so that this file contains none of the shapes it
# refuses. Each entry says what the patterns must answer.
$BS = [string][char]92
$FS = [string][char]47
$C = [string][char]67
$D = [string][char]68
$E = [string][char]69
# Assembled so this file does not contain the shape it uses as a negative case.
$notPublicRoot = 'work' + 'd'
$selfTests = @(
    @{ what = 'a drive letter with a backslash'; text = ($C + ':' + $BS + 'work' + $BS + 'a.mp4'); path = $true; title = $false; cred = $false },
    @{ what = 'a drive letter with a slash'; text = ($C + ':' + $FS + 'work' + $FS + 'a.mp4'); path = $true; title = $false; cred = $false },
    @{ what = 'a UNC share'; text = ($BS + $BS + 'server' + $BS + 'share' + $BS + 'a.mp4'); path = $true; title = $false; cred = $false },
    @{ what = 'a home directory'; text = ($FS + 'home' + $FS + 'someone' + $FS + 'a.mp4'); path = $true; title = $false; cred = $false },
    @{ what = 'a Mac home directory'; text = ($FS + 'Users' + $FS + 'someone' + $FS + 'a.mp4'); path = $true; title = $false; cred = $false },
    @{ what = 'a tilde path is prose-only'; text = ('~' + $FS + 'Videos' + $FS + 'a.mp4'); path = $false; title = $false; cred = $false },
    @{ what = 'a URL'; text = ('https' + ':' + $FS + $FS + 'example.com' + $FS + 'a'); path = $false; title = $false; cred = $false },
    @{ what = 'a drive letter in prose'; text = ('the ' + $C + ': drive'); path = $false; title = $false; cred = $false },
    @{ what = 'a relative path'; text = ('docs' + $FS + 'features' + $FS + 'a.md'); path = $false; title = $false; cred = $false },
    @{ what = 'a relative home segment'; text = ('lib' + $FS + 'pages' + $FS + 'home' + $FS + 'home.dart'); path = $false; title = $false; cred = $false },
    @{ what = 'a title and an episode'; text = ([string][char]0x8fdb + [string][char]0x51fb + [string][char]0x7684 + [string][char]0x5de8 + [string][char]0x4eba + ' ' + [string][char]0x7b2c + '1' + [string][char]0x96c6); path = $false; title = $true; cred = $false },
    @{ what = 'a title without a space'; text = ([string][char]0x8fdb + [string][char]0x51fb + [string][char]0x7684 + [string][char]0x5de8 + [string][char]0x4eba + [string][char]0x7b2c + '1' + [string][char]0x96c6); path = $false; title = $true; cred = $false },
    @{ what = 'a navigation phrase with an episode'; text = ([string][char]0x7acb + [string][char]0x5373 + [string][char]0x8df3 + [string][char]0x5230 + [string][char]0x7b2c + '2' + [string][char]0x96c6); path = $false; title = $false; cred = $false },
    @{ what = 'an episode number alone'; text = 'the 12th episode'; path = $false; title = $false; cred = $false },
    @{ what = 'a URL with a password'; text = ('https' + ':' + $FS + $FS + 'u' + ':' + 'p' + '@' + 'host' + $FS + 'a'); path = $false; title = $false; cred = $true },
    @{ what = 'an SMB URL with a password'; text = ('smb' + ':' + $FS + $FS + 'u' + ':' + 'p' + '@' + 'host' + $FS + 'a'); path = $false; title = $false; cred = $true },
    @{ what = 'a URL without a password'; text = ('https' + ':' + $FS + $FS + 'u' + '@' + 'host' + $FS + 'a'); path = $false; title = $false; cred = $false }
)

foreach ($case in $selfTests) {
    $hitPath = [bool]($case.text -match $pathPattern)
    $hitTitle = [bool](Find-TitleEpisode -Text $case.text)
    $hitCred = [bool]($case.text -match $credPattern)
    if ($hitPath -ne $case.path -or $hitTitle -ne $case.title -or $hitCred -ne $case.cred) {
        Write-Host ("FAIL: self-test, {0}: path={1} title={2} cred={3}" -f $case.what, $hitPath, $hitTitle, $hitCred)
        Write-Host "FAIL: the check itself is broken; fix the patterns before trusting a green run"
        exit 2
    }
}

# The prose-only tilde rule is separate from the path pattern because Dart's
# integer division (`~/`) is everywhere in this repository.
$tildeSample = '~' + $FS + 'Videos' + $FS + 'a.mp4'
$tildeNegative = 'value ' + '~' + $FS + ' 2'
if (-not ($tildeSample -match $tildePattern)) {
    Write-Host 'FAIL: self-test, a prose tilde path: no match'
    Write-Host 'FAIL: the check itself is broken; fix the tilde pattern before trusting a green run'
    exit 2
}
if ($tildeNegative -match $tildePattern) {
    Write-Host 'FAIL: self-test, a Dart integer division: matched'
    Write-Host 'FAIL: the check itself is broken; fix the tilde pattern before trusting a green run'
    exit 2
}

# The public roots are a filter, not a pattern, so they get their own samples.
$filterTests = @(
    @{ what = 'a documented tool root'; text = ($C + ':' + $FS + 'Program Files' + $FS + 'Qt' + $FS + 'bin'); local = $false },
    @{ what = 'a Visual Studio root'; text = ($C + ':' + $BS + 'Program Files' + $BS + 'Microsoft Visual Studio'); local = $false },
    @{ what = 'a 32-bit tool root'; text = ($C + ':' + $BS + 'Program Files (x86)' + $BS + 'Inno Setup 6' + $BS + 'ISCC.exe'); local = $false },
    @{ what = 'a Windows root'; text = ($C + ':' + $BS + 'Windows' + $BS + 'System32'); local = $false },
    @{ what = 'a stand-in work root'; text = ($C + ':' + $BS + 'work' + $BS + 'a.mp4'); local = $false },
    @{ what = 'a stand-in videos root'; text = ($D + ':' + $BS + 'Videos' + $BS + 'a.mp4'); local = $false },
    @{ what = 'a stand-in media root'; text = ($E + ':' + $FS + 'media2' + $FS + 'a.mp4'); local = $false },
    @{ what = 'a stand-in vault root'; text = ($E + ':' + $BS + 'vault' + $BS + 'a.mp4'); local = $false },
    @{ what = 'a stand-in photos root'; text = ($D + ':' + $FS + 'Photos' + $FS + 'IRIS'); local = $false },
    @{ what = 'a stand-in letter root'; text = ($E + ':' + $BS + 'a' + $BS + 'b.mkv'); local = $false },
    @{ what = 'a fixture root spelled with a slash'; text = ($C + ':' + $FS + 'tmp' + $FS + 'a.png'); local = $false },
    @{ what = 'a fixture root on another drive'; text = ($D + ':' + $FS + 'out' + $FS + 'a.png'); local = $false },
    @{ what = 'a user placeholder'; text = ($C + ':' + $BS + 'Users' + $BS + 'u' + $BS + 'a.bin'); local = $false },
    @{ what = 'a spaced user placeholder'; text = ($C + ':' + $BS + 'Users' + $BS + 'Some Name' + $BS + 'a.bin'); local = $false },
    @{ what = 'an angle-bracket user placeholder'; text = ($C + ':' + $BS + 'Users' + $BS + '<user>' + $BS + 'a.bin'); local = $false },
    @{ what = 'a bare drive root'; text = ($D + ':' + $BS); local = $false },
    @{ what = 'a nested drive'; text = ($D + ':' + $FS + 'd' + ':' + $FS + 'Movies' + $FS + 'a.mp4'); local = $false },
    @{ what = 'a placeholder ellipsis'; text = ($E + ':' + $FS + [string][char]0x2026); local = $false },
    @{ what = 'a UNC fixture'; text = ($BS + $BS + 'server' + $BS + 'share' + $BS + 'a.mp4'); local = $false },
    @{ what = 'a real folder whose name is a fixture root'; text = ($D + ':' + $BS + 'tmp' + $BS + 'a.png'); local = $true },
    @{ what = 'a real library root'; text = ($D + ':' + $BS + 'books' + $BS + 'a.cbz'); local = $true },
    @{ what = 'a real account'; text = ($C + ':' + $BS + 'Users' + $BS + 'acct' + $BS + 'a.mp4'); local = $true },
    @{ what = 'a relative home segment'; text = ('lib' + $FS + 'pages' + $FS + 'home' + $FS + 'home.dart'); local = $false },
    @{ what = 'an interpolated test path'; text = ($C + ':' + $FS + '$path'); local = $false; inTest = $true },
    @{ what = 'an interpolated path outside a test'; text = ($C + ':' + $FS + '$path'); local = $true },
    @{ what = 'a root that only starts with a public word'; text = ($D + ':' + $BS + $notPublicRoot + $BS + 'a.cbz'); local = $true }
)

foreach ($case in $filterTests) {
    $hit = Find-LocalPath -Text $case.text -InTest:([bool]$case['inTest'])
    if ([bool]$hit -ne $case.local) {
        Write-Host ("FAIL: self-test, {0}: local={1}" -f $case.what, (-not $case.local))
        Write-Host "FAIL: the check itself is broken; fix the public roots before trusting a green run"
        exit 2
    }
}

$problems = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

if ($denyMissing) {
    $warnings.Add("deny list not found at .local_privacy/deny-list.txt - private terms are not checked")
}

if ($Message) {
    $path = ""
    if ($MessageFile) {
        # The commit-msg hook passes the file git handed it: COMMIT_EDITMSG for
        # a normal commit, MERGE_MSG for a merge. Reading COMMIT_EDITMSG blindly
        # checks stale text on a merge.
        $path = $MessageFile
        if (-not [System.IO.Path]::IsPathRooted($path)) {
            $path = Join-Path $root $path
        }
    } else {
        # `git rev-parse --git-path` finds the fallback path in a linked
        # worktree, where it lives under the main repository's .git.
        $gitPath = git -C $root rev-parse --git-path COMMIT_EDITMSG 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAIL: git rev-parse failed"
            exit 2
        }
        if ($gitPath) {
            $path = $gitPath
            if (-not [System.IO.Path]::IsPathRooted($path)) {
                $path = Join-Path $root $path
            }
        }
    }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        Write-Host "OK: no commit message to check"
        exit 0
    }
    $number = 0
    foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
        $number++
        foreach ($problem in @(Find-Problems -Where "the commit message:${number}" -Text $line -InProse)) {
            $problems.Add($problem.Message)
        }
    }
    Write-Host ("message: {0} line(s) of the commit message" -f $number)
} elseif ($All) {
    $tracked = @(git -C $root -c core.quotepath=false ls-files)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: git ls-files failed"
        exit 2
    }
    foreach ($file in $tracked) {
        $nameProblem = Find-NameProblem -Name $file
        if ($nameProblem -ne $null) { $problems.Add($nameProblem) }
        if ($file -notmatch $textFilePattern) { continue }
        # Generated files are not prose; their Windows path handling would only
        # add noise to the audit.
        if ($file -match '(\.g\.dart|\.freezed\.dart)$') { continue }
        if ($file -match '^lib/l10n/app_localizations.*\.dart$') { continue }
        $full = Join-Path $root $file
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $number = 0
        $inTest = Test-FileName -Name $file
        $inProse = Test-ProseFile -Name $file
        foreach ($line in (Get-Content -LiteralPath $full -Encoding UTF8)) {
            $number++
            foreach ($problem in @(Find-Problems -Where "${file}:${number}" -Text $line -InTest:$inTest -InProse:$inProse)) {
                if ($problem.Kind -eq 'path') { $warnings.Add($problem.Message) }
                else { $problems.Add($problem.Message) }
            }
        }
    }
    Write-Host ("audit: {0} tracked files, {1} warning(s)" -f $tracked.Count, $warnings.Count)
} else {
    $scope = ""
    $commitScope = ""
    $useCommitLog = $false
    if ($Pushed) {
        if ($Range) {
            # The hook passes shas reported by git, never a branch expression.
            if ($Range -notmatch '^[0-9a-fA-F]{4,64}\.\.[0-9a-fA-F]{4,64}$') {
                Write-Host "FAIL: invalid push range"
                exit 2
            }
            $scope = $Range
            $commitScope = $Range
            $useCommitLog = $true
        } else {
            # A branch has no remote range yet (new branch, or no upstream).
            # Compare it with its upstream merge base or the closest default
            # branch, never only with the last commit: a path in an earlier
            # commit of a new branch must be caught too. With no base at all,
            # the whole branch is checked against the empty tree.
            $scope = "4b825dc642cb6eb9a060e54bf8d69288fbee4904..HEAD"
            $commitScope = "HEAD"
            $hasParent = $false
            try {
                $hasParent = [bool](git -C $root rev-parse --verify "HEAD~1" 2>$null)
            } catch {
                $hasParent = $false
            }
            if ($hasParent) {
                $current = $null
                try {
                    $current = git -C $root symbolic-ref --short HEAD 2>$null
                } catch {
                    $current = $null
                }
                $base = $null
                $upstream = $null
                try {
                    $upstream = git -C $root rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>$null
                } catch {
                    $upstream = $null
                }
                if ($upstream -and $upstream -notmatch '^\s*$') {
                    try {
                        $base = git -C $root merge-base $upstream HEAD 2>$null
                    } catch {
                        $base = $null
                    }
                }
                if (-not $base -or $base -match '^\s*$') {
                    foreach ($candidate in @("origin/HEAD", "origin/main", "origin/master", "upstream/master", "main", "master")) {
                        # Comparing the default branch with itself is empty; only
                        # another branch narrows the range.
                        if ($current -and $candidate -eq $current) { continue }
                        try {
                            $candidateBase = git -C $root merge-base $candidate HEAD 2>$null
                        } catch {
                            $candidateBase = $null
                        }
                        if ($candidateBase -and $candidateBase -notmatch '^\s*$') {
                            $base = $candidateBase
                            break
                        }
                    }
                }
                if ($base -and $base -notmatch '^\s*$') {
                    $scope = "$base..HEAD"
                    $commitScope = $scope
                    $useCommitLog = $true
                }
            }
        }
        Write-Host ("push: checking {0}" -f $scope)
        $staged = @(git -C $root -c core.quotepath=false diff --name-only --diff-filter=ACMR $scope)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAIL: git diff --name-only failed"
            exit 2
        }
        if ($useCommitLog) {
            # Scan every commit's added lines, not only the net tree diff: a
            # path added in one commit and removed in a later one is still in
            # the pushed history.
            $diff = git -C $root -c core.quotepath=false log -p -U0 --no-color --format= --root $commitScope
        } else {
            # No base: the whole branch is new, so the net diff against the
            # empty tree already shows every line as added.
            $diff = git -C $root -c core.quotepath=false diff -U0 --no-color $scope
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAIL: git diff/log failed"
            exit 2
        }

        # Commit messages are published too. A --no-verify commit skipped the
        # commit-msg hook, so the pushed range is the last place to catch it.
        $messages = git -C $root -c core.quotepath=false log --format=%B $commitScope
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAIL: git log --format failed"
            exit 2
        }
        $messageLine = 0
        foreach ($line in ($messages -split "`n")) {
            $messageLine++
            foreach ($problem in @(Find-Problems -Where "a pushed commit message:${messageLine}" -Text $line -InProse)) {
                $problems.Add($problem.Message)
            }
        }
    } else {
        $staged = @(git -C $root -c core.quotepath=false diff --cached --name-only --diff-filter=ACMR)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAIL: git diff --cached --name-only failed"
            exit 2
        }
        if ($staged.Count -gt 0) {
            $diff = git -C $root -c core.quotepath=false diff --cached -U0 --no-color
            $scope = "cached"
        } else {
            $diff = git -C $root -c core.quotepath=false diff -U0 --no-color
            $scope = "worktree"
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAIL: git diff failed"
            exit 2
        }
    }

    foreach ($name in $staged) {
        $nameProblem = Find-NameProblem -Name $name
        if ($nameProblem -ne $null) { $problems.Add($nameProblem) }
    }

    $file = ""
    $number = 0
    foreach ($line in ($diff -split "`n")) {
        if ($line -match '^\+\+\+ b/(.+?)\s*$') {
            $file = $Matches[1]
            $number = 0
            continue
        }
        if ($line -match '^@@ .* \+(\d+)') {
            $number = [int]$Matches[1]
            continue
        }
        if ($line -notmatch '^\+' -or $line -match '^\+\+\+') { continue }
        $inTest = Test-FileName -Name $file
        $inProse = Test-ProseFile -Name $file
        foreach ($problem in @(Find-Problems -Where "${file}:${number}" -Text $line.Substring(1) -InTest:$inTest -InProse:$inProse)) {
            $problems.Add($problem.Message)
        }
        $number++
    }

    # git prints no `+` line for a binary file, so its bytes were never read:
    # the name was checked, the content was not. Say so instead of letting the
    # run look complete. A real video or screenshot whose name says nothing is
    # exactly the case this cannot decide.
    if ($staged.Count -gt 0) {
        $numstat = if ($Pushed) {
            git -C $root -c core.quotepath=false diff --numstat $scope
        } elseif ($scope -eq "cached") {
            git -C $root -c core.quotepath=false diff --cached --numstat
        } else {
            git -C $root -c core.quotepath=false diff --numstat
        }
        foreach ($line in $numstat) {
            if ($line -match "^-\t-\t(.+)$") {
                $warnings.Add("binary file not scanned: $($Matches[1])")
            }
        }
    }
}

foreach ($warning in $warnings) { Write-Host "warning: $warning" }

if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-Host "FAIL: $problem" }
    Write-Host ("FAIL: {0} local or private item(s) would be committed" -f $problems.Count)
    exit 1
}

Write-Host "OK: nothing local in the change"
exit 0
