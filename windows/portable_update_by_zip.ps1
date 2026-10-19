<#
.SYNOPSIS
  IRIS Portable Edition ZIP Updater Script (portable_update_by_zip)
.DESCRIPTION
  Adaptively accepts a ZIP file path or directory path containing ZIP files,
  performs L1 filename verification and L2 package content verification (iris.exe),
  compares file versions (upgrade, same version, downgrade with timestamped backup),
  waits for running IRIS processes to exit, and safely overwrites program files
  while strictly preserving the 'userdata' directory.

  Console output is OPTIONAL. The app drives this script from a GUI process that
  owns no console, and in that state any [Console] touch throws. The transcript
  goes to -LogPath; the console is written to only when one exists.
#>

param(
    # Path to the update package. Supplied when the app drives the update (it
    # has already downloaded and verified the file); omitted for a manual run,
    # where the script asks for the path.
    [string]$ZipPath,

    # Transcript destination. Supplied by the app so that a run which failed with
    # nobody watching still leaves something to read.
    [string]$LogPath,

    # Runs without asking anything. The app uses this because nobody is at the
    # keyboard once it has handed over: every prompt below takes its default.
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

# Console I/O is optional, and that is detected once, here. The app starts this
# script from a GUI process that owns no console; in that state every [Console]
# touch throws "The handle is invalid", and with $ErrorActionPreference = "Stop"
# that killed the script on its very first statement — so the update never
# started while the app went on to close. Nothing below may require a console.
$script:HasConsole = $false
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $script:HasConsole = $true
} catch {
    $script:HasConsole = $false
}

$script:LogFile = $null
if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $script:LogFile = $LogPath }

function Write-Log {
    param(
        [Parameter(Position = 0)][string]$Text,
        # Position 1 as well as the name: both call styles are used below
        # (`-ForegroundColor Red` and a bare trailing colour), and a parameter
        # that only has a name cannot be passed positionally once any sibling
        # declares a position.
        [Parameter(Position = 1)][ConsoleColor]$ForegroundColor = "Cyan"
    )
    # The file is the transcript of record: it exists whether or not anyone can
    # see a window, and it survives the program files being replaced (it lives
    # next to the downloaded package, not in the install directory).
    if ($script:LogFile) {
        try {
            Add-Content -LiteralPath $script:LogFile -Value ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text) -Encoding UTF8
        } catch { }
    }
    if (-not $script:HasConsole) { return }
    try {
        $oldColor = [Console]::ForegroundColor
        [Console]::ForegroundColor = $ForegroundColor
        Write-Host $Text
        [Console]::ForegroundColor = $oldColor
    } catch { }
}

function Write-ColorText {
    param([string]$Text, [ConsoleColor]$Color = "Cyan")
    Write-Log -Text $Text -ForegroundColor $Color
}

function Invoke-PausePrompt {
    # Keeps the window open on error paths for both direct .ps1 runs and the
    # .bat wrapper (which has no trailing `pause` by design).
    # Read-Host needs a console, so a headless run never reaches it.
    if ($NonInteractive -or -not $script:HasConsole) { return }
    [void](Read-Host "按回车键继续")
}

function Read-Answer {
    param([string]$Prompt, [string]$Default)
    # A non-interactive run takes the default instead of blocking on stdin: the
    # app launches this window detached and nobody will ever answer.
    if ($NonInteractive -or -not $script:HasConsole) { return $Default }
    $answer = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

$exeDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Test-IrisRunning {
    # Only this installation counts: another IRIS elsewhere on the machine is
    # none of this update's business.
    foreach ($p in (Get-Process -Name "iris" -ErrorAction SilentlyContinue)) {
        try {
            if ($p.Path -and $p.Path.StartsWith($exeDir, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        } catch { }
    }
    return $false
}

function Start-Iris {
    # Starting a second instance on top of a running one is worse than saying
    # nothing, so a MANUAL run (the .bat started while IRIS is open) skips the
    # relaunch while IRIS is up.
    #
    # The APP-DRIVEN run is the opposite case: the app starts this script and
    # then shuts ITSELF down, so a failure inside that first second still sees
    # IRIS running -- and skipping here left the user at a desktop with no
    # player, the exact state this script exists to prevent. Wait (bounded) for
    # the app to finish exiting, then relaunch.
    if (Test-IrisRunning) {
        if (-not $NonInteractive) { return }
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while (Test-IrisRunning -and $wait.ElapsedMilliseconds -lt 15000) {
            Start-Sleep -Milliseconds 250
        }
        if (Test-IrisRunning) { return }
    }
    try {
        Write-Log "正在启动 IRIS..." "Green"
        Start-Process (Join-Path $exeDir "iris.exe")
    } catch {
        Write-Log "无法重新启动 IRIS: $_" "Red"
    }
}

function Exit-WithFailure {
    param([Parameter(Position = 0)][string]$Message)
    # Every failure ends the same way: say what happened, then hand the app back.
    # A failed update must never leave the user at a desktop with no IRIS and no
    # explanation — that is exactly what the silent no-op hand-off used to do.
    Write-Log $Message "Red"
    Invoke-PausePrompt
    Start-Iris
    exit 1
}

# Temp tree of THIS run, published for the trap below: it is created further
# down (next to the extraction), so it is null for the failures that happen
# before that.
$script:TempRoot = $null

# The global safety net this script cannot do without: $ErrorActionPreference is
# "Stop", so ANY unexpected failure — an ACL-denied Get-ChildItem, a path that
# vanished between Test-Path and Resolve-Path, a robocopy that cannot even
# start — is TERMINATING. Without a trap the script simply died mid-flight:
# nothing relaunched IRIS (the user was left at a desktop with no player), the
# transcript recorded nothing, and the partially extracted
# temps_portable_update_* directory stayed in the install folder, where every
# later update's `/XD temps_portable_update*` excludes it forever. Every failure
# now ends exactly like Exit-WithFailure, including the relaunch.
trap {
    Write-Log "未预期的错误: $_" "Red"
    Write-Log $_.ScriptStackTrace "DarkGray"
    if ($script:TempRoot) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Invoke-PausePrompt
    Start-Iris
    exit 1
}

# P0-1: preload the compression assembly BEFORE the L2 ZipFile::OpenRead check.
# Windows PowerShell 5.1 (used by the .bat wrapper) does not guarantee it is
# loaded. Deliberately placed AFTER the trap so a failure here is covered too.
Add-Type -AssemblyName System.IO.Compression.FileSystem

# L2: the package must contain iris.exe. This check is MANDATORY on every path,
# including the app-driven one: the app only pins a byte count when the release
# publishes no checksum index, so the script is the last place that can reject a
# package which is merely the right size. A manual run re-prompts; an
# app-driven run has nobody to ask and fails the update instead.
function Test-IrisPackageContent {
    param([Parameter(Mandatory = $true)][string]$Path)
    $zipArchive = $null
    try {
        $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        foreach ($entry in $zipArchive.Entries) {
            # ZIP entry separators are '/', but tolerate '\'. Case-insensitive (-match default).
            if ($entry.FullName -match '(^|[\\/])iris\.exe$') { return $true }
        }
        return $false
    } catch {
        Write-Log "无法读取 ZIP 文件，可能已损坏: $_" "Red"
        return $false
    } finally {
        # P2: release the file handle even when enumeration throws mid-way.
        if ($null -ne $zipArchive) { $zipArchive.Dispose() }
    }
}

if (-not (Test-Path (Join-Path $exeDir "portable.flag"))) {
    Exit-WithFailure "错误: 未在当前目录找到 portable.flag，本脚本仅适用于 IRIS 便携版。"
}

Write-ColorText "========================================" "Magenta"
Write-ColorText "   IRIS 便携版自适应 ZIP 更新工具       " "Magenta"
Write-ColorText "========================================" "Magenta"
Write-Log ""
if ($script:LogFile) { Write-Log "日志文件: $script:LogFile" "DarkGray" }

# True when -ZipPath supplied the package. The L2 content check below runs for
# this path TOO (after the loop) — skipping it made the app-driven install the
# only update route with no package-structure verification of its own.
$script:AppDriven = -not [string]::IsNullOrWhiteSpace($ZipPath)

while ($true) {
    if ($script:AppDriven) {
        # App-driven: the package is already downloaded and size-checked, so skip
        # the interactive DISCOVERY loop. Content verification still runs below.
        # Strip BOTH surrounding quote styles, like the interactive branch does:
        # a single-quoted path pasted by a caller is otherwise opened verbatim
        # and reported as missing.
        $cleanInput = $ZipPath.Trim().Trim('"').Trim("'")
        if (-not (Test-Path -LiteralPath $cleanInput)) {
            Exit-WithFailure "错误: 指定的更新包不存在: $cleanInput"
        }
        $zipPath = (Resolve-Path -LiteralPath $cleanInput).Path
        break
    }

    $rawInput = Read-Host "请粘贴新版 ZIP 文件的完整路径或所在目录"
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        Write-Log "输入为空，请重新输入。" "Yellow"
        continue
    }

    # Normalize input: trim spaces, strip surrounding quotes (' or "), trim trailing slashes.
    # Drag-drop from Explorer and copy-as-path both yield surrounding double quotes.
    $cleanInput = $rawInput.Trim()
    if ($cleanInput.Length -ge 2) {
        $first = $cleanInput[0]
        $last = $cleanInput[$cleanInput.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $cleanInput = $cleanInput.Substring(1, $cleanInput.Length - 2).Trim()
        }
    }
    # P1: never trim a drive/UNC root (e.g. 'D:\') down to 'D:' (a different location).
    $isRoot = ($cleanInput -match '^[A-Za-z]:[\\/]?$') -or ($cleanInput -match '^\\\\[^\\]+\\[^\\]+[\\/]?$')
    if (-not $isRoot) {
        $cleanInput = $cleanInput.TrimEnd('\', '/')
    }

    if (-not (Test-Path -LiteralPath $cleanInput)) {
        Write-Log "路径不存在: $cleanInput" "Red"
        continue
    }

    $zipPath = $null
    # P1: the path may disappear between Test-Path and Get-Item (e.g. USB unplug).
    try {
        $isContainer = (Get-Item -LiteralPath $cleanInput -ErrorAction Stop) -is [System.IO.DirectoryInfo]
    } catch {
        Write-Log "无法访问路径 (可能已被移除): $cleanInput" "Red"
        continue
    }

    if ($isContainer) {
        # Search for IRIS-windows*.zip first, then IRIS*.zip (priority, then newest).
        $candidates = Get-ChildItem -LiteralPath $cleanInput -Filter "*.zip" | Where-Object {
            $_.Name -like "IRIS-windows*.zip" -or $_.Name -like "IRIS*.zip"
        } | Sort-Object @{ Expression = { if ($_.Name -like "IRIS-windows*.zip") { 0 } else { 1 } }; Ascending = $true }, @{ Expression = "LastWriteTime"; Descending = $true }

        if (-not $candidates) {
            Write-Log "指定目录下未找到符合要求的 ZIP 文件 (需匹配 IRIS-windows*.zip 或 IRIS*.zip)" "Red"
            continue
        }
        $zipPath = $candidates[0].FullName
        Write-Log "自动选择最新包: $(Split-Path -Leaf $zipPath)" "Green"
    } else {
        if ([IO.Path]::GetExtension($cleanInput) -ne ".zip") {
            Write-Log "所选文件不是 ZIP 格式: $cleanInput" "Red"
            continue
        }
        $zipPath = (Resolve-Path -LiteralPath $cleanInput).Path
    }

    # L1: Filename verification
    $fileName = [IO.Path]::GetFileName($zipPath)
    $l1Match = ($fileName -like "IRIS-windows*.zip" -or $fileName -like "IRIS*.zip")
    if (-not $l1Match) {
        Write-Log "警告: 文件名 '$fileName' 不符合标准命名 (IRIS-windows*.zip / IRIS*.zip)" "Yellow"
        $choice = Read-Answer "是否仍要使用此 ZIP 包继续？(Y/N)" "N"
        if ($choice -ne 'Y' -and $choice -ne 'y') {
            continue
        }
    }

    # L2: Package content verification (must contain iris.exe)
    Write-Log "正在校验包内结构..."
    if (-not (Test-IrisPackageContent $zipPath)) {
        Write-Log "校验失败: 压缩包内未找到 iris.exe，无条件拒绝更新！" "Red"
        continue
    }

    Write-Log "双重校验通过！" "Green"
    break
}

# The app-driven branch exits the discovery loop above before the interactive
# L1/L2 checks, so run the SAME mandatory L2 check here. The app's own download
# is only pinned to a byte count when no checksum index exists; without this,
# the unattended path replaced the install with any same-size ZIP.
if ($script:AppDriven) {
    Write-Log "正在校验包内结构..."
    if (-not (Test-IrisPackageContent $zipPath)) {
        Exit-WithFailure "校验失败: 压缩包内未找到 iris.exe，无条件拒绝更新！"
    }
    Write-Log "双重校验通过！" "Green"
}

# Version extraction & comparison helper
function Get-ExeVersion {
    param([string]$path)
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $vi = (Get-Item -LiteralPath $path).VersionInfo
        $v = $vi.FileVersion
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $vi.ProductVersion }
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        # Strip build metadata suffixes like ' (WinBuild.160101.0800)' so the
        # version stays a clean dotted number for display, compare and backup names.
        return ($v.Trim().TrimStart('v', 'V') -replace '\+', '.' -replace '\s*\(.*$', '').Trim()
    } catch {
        return $null
    }
}

function ConvertTo-VersionParts {
    param([string]$v)
    $parts = @()
    foreach ($seg in $v.Split('.')) {
        $digits = ($seg -replace '\D', '')
        if ([string]::IsNullOrEmpty($digits)) { $parts += 0 } else { $parts += [int]$digits }
    }
    return $parts
}

function Compare-Version {
    param([string]$a, [string]$b)
    $pa = ConvertTo-VersionParts $a
    $pb = ConvertTo-VersionParts $b
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $av = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $bv = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($av -lt $bv) { return -1 }
        if ($av -gt $bv) { return 1 }
    }
    return 0
}

$curExePath = Join-Path $exeDir "iris.exe"
$curVer = Get-ExeVersion $curExePath
if (-not $curVer) { $curVer = "0.0.0.0" }

# Extract ZIP to temps (PID suffix keeps concurrent runs from sharing one folder).
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$tempRoot = Join-Path $exeDir "temps_portable_update_${timestamp}_$PID"
$script:TempRoot = $tempRoot
$extractDir = Join-Path $tempRoot "extract"
# P1: a read-only location (e.g. Program Files) fails here; explain instead of dumping a stack.
try {
    New-Item -ItemType Directory -Path $extractDir -Force -ErrorAction Stop | Out-Null
} catch {
    Exit-WithFailure "无法在当前目录创建临时文件夹，便携目录可能不可写（如解压到了 Program Files 只读位置）。请将整个 IRIS 文件夹移到有写权限的位置后再试。"
}

Write-Log "正在解压更新包..."
try {
    # Zip-slip guard: `ZipFile.ExtractToDirectory` on Windows PowerShell
    # (.NET Framework) performs no entry-path validation, so a crafted package
    # could write outside the temp folder (`..\..\` entries or rooted names).
    # PowerShell 7/.NET Core rejects these itself, 5.1 does not.
    $extractFull = [System.IO.Path]::GetFullPath($extractDir).TrimEnd('\') + '\'
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $dest = [System.IO.Path]::GetFullPath((Join-Path $extractDir $entry.FullName))
            if (-not $dest.StartsWith($extractFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "包内条目试图写入解压目录之外: $($entry.FullName)"
            }
        }
    } finally {
        $archive.Dispose()
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
} catch {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Exit-WithFailure "解压失败: $_"
}

# Locate src directory containing iris.exe
$srcDir = $null
if (Test-Path (Join-Path $extractDir "IRIS\iris.exe")) {
    $srcDir = Join-Path $extractDir "IRIS"
} elseif (Test-Path (Join-Path $extractDir "iris.exe")) {
    $srcDir = $extractDir
} else {
    $found = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter "iris.exe" | Select-Object -First 1
    if ($found) {
        $srcDir = $found.DirectoryName
    }
}

if (-not $srcDir -or -not (Test-Path (Join-Path $srcDir "iris.exe"))) {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Exit-WithFailure "错误: 解压后未能在包内定位 iris.exe 目录结构。"
}

$newVer = Get-ExeVersion (Join-Path $srcDir "iris.exe")
if (-not $newVer) {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Exit-WithFailure "错误: 新包中的 iris.exe 无法获取版本号。"
}

Write-Log "当前版本: $curVer"
Write-Log "新包版本: $newVer"

$cmp = Compare-Version $curVer $newVer

# P0-4: wait for running instances BEFORE any backup/copy, so the downgrade
# backup captures a quiescent (fully checkpointed) userdata folder.
Write-Log "检查是否有运行中的 IRIS 进程..."
$sw = [Diagnostics.Stopwatch]::StartNew()
while (Test-IrisRunning) {
    if ($sw.ElapsedMilliseconds -gt 30000) {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        Exit-WithFailure "等待进程退出超时，请手动关闭 IRIS 窗口后再试。"
    }
    Write-Log "等待 IRIS 退出中..." "Yellow"
    Start-Sleep -Seconds 1
}

if ($cmp -lt 0) {
    Write-ColorText "检测到版本升级 ($curVer -> $newVer)，将自动执行更新。" "Green"
} elseif ($cmp -eq 0) {
    Write-Log "当前已是相同版本 ($curVer)。" "Yellow"
    # App-driven, the default is YES: the app only offers a version it believes
    # is newer, so the app's own version and the executable's version disagree --
    # overwriting is what makes them agree again. A manual run defaults to NO.
    $reinstallDefault = if ($NonInteractive) { "Y" } else { "N" }
    $ans = Read-Answer "确认要重新覆盖安装吗？(Y/N)" $reinstallDefault
    if ($ans -ne 'Y' -and $ans -ne 'y') {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "已跳过更新（用户选择不重新覆盖）。" "Yellow"
        Start-Iris
        exit 0
    }
} else {
    Write-ColorText "警告: 正在进行版本降级 ($curVer -> $newVer)！" "Yellow"
    Write-ColorText "降级可能导致数据库 Schema 版本不兼容，系统将自动对 userdata 进行时间戳备份。" "Yellow"
    $ans = Read-Answer "确认要强制降级并更新吗？(Y/N)" "N"
    if ($ans -ne 'Y' -and $ans -ne 'y') {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "已取消降级。" "Yellow"
        # Headless (the app asked for an update and is waiting for it back), the
        # app has to be handed back: nothing else will reopen it.
        Start-Iris
        exit 0
    }

    $userDataDir = Join-Path $exeDir "userdata"
    if (Test-Path $userDataDir) {
        $backupDir = Join-Path $exeDir "userdata.bak_${curVer}_$timestamp"
        Write-Log "正在备份 userdata 到: $(Split-Path -Leaf $backupDir)..."
        # P0-3: a failed backup must abort the downgrade instead of printing success.
        robocopy $userDataDir $backupDir /E /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            Exit-WithFailure "备份 userdata 失败 (Robocopy 错误码: $LASTEXITCODE)，已中止降级以保护数据。"
        }
        Write-ColorText "备份完成！" "Green"
    }
}

Write-Log "正在覆盖程序文件 (保留 userdata)..."
# The updater's own two files ARE copied, like everything else: Windows
# PowerShell parses a -File script up front and releases the handle, so the
# running script can be replaced under itself and the rest of this run continues
# from the already-parsed copy (verified). Excluding them would have frozen this
# script forever, since every in-app update would keep re-running the old one.
$robocopyResult = robocopy $srcDir $exeDir /E /NFL /NDL /NJH /NJS /XD userdata userdata.bak* temps temps_portable_update* /XF *.zip
# Robocopy exit codes 0-7 indicate success
if ($LASTEXITCODE -ge 8) {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Exit-WithFailure "文件覆盖复制出错 (Robocopy 错误码: $LASTEXITCODE)"
}

# Cleanup temp
Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

# The app downloads the package into its own updates directory. When that lives
# outside the install folder it is not covered by the robocopy exclusion list
# above and is dropped here; when it lives inside (portable mode keeps it under
# userdata/updates) it is deliberately left alone — IRIS deletes it once the
# next launch confirms the update actually landed, and keeps it when it did not,
# so the user can finish the job by hand.
if (-not $zipPath.StartsWith($exeDir, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
}

Write-ColorText "========================================" "Green"
Write-ColorText "   IRIS 更新成功完成！                  " "Green"
Write-ColorText "========================================" "Green"

# Relaunch: the default in a non-interactive (app-driven) run, because the user
# asked for the update from inside the app and expects IRIS back.
$startNow = Read-Answer "是否立即启动 IRIS？(Y/N)" "Y"
if ($startNow -eq 'Y' -or $startNow -eq 'y') {
    Start-Iris
}
