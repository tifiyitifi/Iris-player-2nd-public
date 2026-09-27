<#
.SYNOPSIS
  IRIS Portable Edition ZIP Updater Script (portable_update_by_zip)
.DESCRIPTION
  Adaptively accepts a ZIP file path or directory path containing ZIP files,
  performs L1 filename verification and L2 package content verification (iris.exe),
  compares file versions (upgrade, same version, downgrade with timestamped backup),
  waits for running IRIS processes to exit, and safely overwrites program files
  while strictly preserving the 'userdata' directory.
#>

param(
    # Path to the update package. Supplied when the app drives the update (it
    # has already downloaded and verified the file); omitted for a manual run,
    # where the script asks for the path.
    [string]$ZipPath,

    # Runs without asking anything. The app uses this because nobody is at the
    # keyboard once it has handed over: every prompt below takes its default.
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# P0-1: preload the compression assembly BEFORE the L2 ZipFile::OpenRead check.
# Windows PowerShell 5.1 (used by the .bat wrapper) does not guarantee it is loaded.
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-ColorText {
    param([string]$Text, [ConsoleColor]$Color = "Cyan")
    $oldColor = [Console]::ForegroundColor
    [Console]::ForegroundColor = $Color
    Write-Host $Text
    [Console]::ForegroundColor = $oldColor
}

function Invoke-PausePrompt {
    # Keeps the window open on error paths for both direct .ps1 runs and the
    # .bat wrapper (which has no trailing `pause` by design).
    # Read-Host is available in both Windows PowerShell 5.1 and PowerShell 7.
    if ($NonInteractive) { return }
    [void](Read-Host "按回车键继续")
}

function Read-Answer {
    param([string]$Prompt, [string]$Default)
    # A non-interactive run takes the default instead of blocking on stdin: the
    # app launches this window detached and nobody will ever answer.
    if ($NonInteractive) { return $Default }
    $answer = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

$exeDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not (Test-Path (Join-Path $exeDir "portable.flag"))) {
    Write-ColorText "错误: 未在当前目录找到 portable.flag，本脚本仅适用于 IRIS 便携版。" "Red"
    Invoke-PausePrompt
    exit 1
}

Write-ColorText "========================================" "Magenta"
Write-ColorText "   IRIS 便携版自适应 ZIP 更新工具       " "Magenta"
Write-ColorText "========================================" "Magenta"
Write-Host ""

while ($true) {
    if (-not [string]::IsNullOrWhiteSpace($ZipPath)) {
        # App-driven: the package is already downloaded and verified, so skip the
        # interactive discovery loop entirely.
        $cleanInput = $ZipPath.Trim().Trim('"')
        if (-not (Test-Path -LiteralPath $cleanInput)) {
            Write-ColorText "错误: 指定的更新包不存在: $cleanInput" "Red"
            exit 1
        }
        $zipPath = (Resolve-Path -LiteralPath $cleanInput).Path
        break
    }

    $rawInput = Read-Host "请粘贴新版 ZIP 文件的完整路径或所在目录"
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        Write-Host "输入为空，请重新输入。" -ForegroundColor Yellow
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
        Write-ColorText "路径不存在: $cleanInput" "Red"
        continue
    }

    $zipPath = $null
    # P1: the path may disappear between Test-Path and Get-Item (e.g. USB unplug).
    try {
        $isContainer = (Get-Item -LiteralPath $cleanInput -ErrorAction Stop) -is [System.IO.DirectoryInfo]
    } catch {
        Write-ColorText "无法访问路径 (可能已被移除): $cleanInput" "Red"
        continue
    }

    if ($isContainer) {
        # Search for IRIS-windows*.zip first, then IRIS*.zip (priority, then newest).
        $candidates = Get-ChildItem -LiteralPath $cleanInput -Filter "*.zip" | Where-Object {
            $_.Name -like "IRIS-windows*.zip" -or $_.Name -like "IRIS*.zip"
        } | Sort-Object @{ Expression = { if ($_.Name -like "IRIS-windows*.zip") { 0 } else { 1 } }; Ascending = $true }, @{ Expression = "LastWriteTime"; Descending = $true }

        if (-not $candidates) {
            Write-ColorText "指定目录下未找到符合要求的 ZIP 文件 (需匹配 IRIS-windows*.zip 或 IRIS*.zip)" "Red"
            continue
        }
        $zipPath = $candidates[0].FullName
        Write-Host "自动选择最新包: $(Split-Path -Leaf $zipPath)" -ForegroundColor Green
    } else {
        if ([IO.Path]::GetExtension($cleanInput) -ne ".zip") {
            Write-ColorText "所选文件不是 ZIP 格式: $cleanInput" "Red"
            continue
        }
        $zipPath = (Resolve-Path -LiteralPath $cleanInput).Path
    }

    # L1: Filename verification
    $fileName = [IO.Path]::GetFileName($zipPath)
    $l1Match = ($fileName -like "IRIS-windows*.zip" -or $fileName -like "IRIS*.zip")
    if (-not $l1Match) {
        Write-Host "警告: 文件名 '$fileName' 不符合标准命名 (IRIS-windows*.zip / IRIS*.zip)" -ForegroundColor Yellow
        $choice = Read-Answer "是否仍要使用此 ZIP 包继续？(Y/N)" "N"
        if ($choice -ne 'Y' -and $choice -ne 'y') {
            continue
        }
    }

    # L2: Package content verification (must contain iris.exe)
    Write-Host "正在校验包内结构..." -ForegroundColor Cyan
    $hasIrisExe = $false
    $zipArchive = $null
    try {
        $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        foreach ($entry in $zipArchive.Entries) {
            # ZIP entry separators are '/', but tolerate '\'. Case-insensitive (-match default).
            if ($entry.FullName -match '(^|[\\/])iris\.exe$') {
                $hasIrisExe = $true
                break
            }
        }
    } catch {
        Write-ColorText "无法读取 ZIP 文件，可能已损坏: $_" "Red"
        continue
    } finally {
        # P2: release the file handle even when enumeration throws mid-way.
        if ($null -ne $zipArchive) { $zipArchive.Dispose() }
    }

    if (-not $hasIrisExe) {
        Write-ColorText "校验失败: 压缩包内未找到 iris.exe，无条件拒绝更新！" "Red"
        continue
    }

    Write-ColorText "双重校验通过！" "Green"
    break
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
$extractDir = Join-Path $tempRoot "extract"
# P1: a read-only location (e.g. Program Files) fails here; explain instead of dumping a stack.
try {
    New-Item -ItemType Directory -Path $extractDir -Force -ErrorAction Stop | Out-Null
} catch {
    Write-ColorText "无法在当前目录创建临时文件夹，便携目录可能不可写（如解压到了 Program Files 只读位置）。请将整个 IRIS 文件夹移到有写权限的位置后再试。" "Red"
    Invoke-PausePrompt
    exit 1
}

Write-Host "正在解压更新包..." -ForegroundColor Cyan
try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
} catch {
    Write-ColorText "解压失败: $_" "Red"
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-PausePrompt
    exit 1
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
    Write-ColorText "错误: 解压后未能在包内定位 iris.exe 目录结构。" "Red"
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-PausePrompt
    exit 1
}

$newVer = Get-ExeVersion (Join-Path $srcDir "iris.exe")
if (-not $newVer) {
    Write-ColorText "错误: 新包中的 iris.exe 无法获取版本号。" "Red"
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-PausePrompt
    exit 1
}

Write-Host "当前版本: $curVer" -ForegroundColor Cyan
Write-Host "新包版本: $newVer" -ForegroundColor Cyan

$cmp = Compare-Version $curVer $newVer

# P0-4: wait for running instances BEFORE any backup/copy, so the downgrade
# backup captures a quiescent (fully checkpointed) userdata folder.
Write-Host "检查是否有运行中的 IRIS 进程..." -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($true) {
    $procs = @()
    foreach ($p in (Get-Process -Name "iris" -ErrorAction SilentlyContinue)) {
        try { $pp = $p.Path } catch { $pp = $null }
        if ($pp -and $pp.StartsWith($exeDir, [StringComparison]::OrdinalIgnoreCase)) { $procs += $p }
    }
    if (-not $procs) { break }
    if ($sw.ElapsedMilliseconds -gt 30000) {
        Write-ColorText "等待进程退出超时，请手动关闭 IRIS 窗口后再试。" "Red"
        Invoke-PausePrompt
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Host "等待 IRIS 退出中..." -ForegroundColor Yellow
    Start-Sleep -Seconds 1
}

if ($cmp -lt 0) {
    Write-ColorText "检测到版本升级 ($curVer -> $newVer)，将自动执行更新。" "Green"
} elseif ($cmp -eq 0) {
    Write-Host "当前已是相同版本 ($curVer)。" -ForegroundColor Yellow
    $ans = Read-Answer "确认要重新覆盖安装吗？(Y/N)" "N"
    if ($ans -ne 'Y' -and $ans -ne 'y') {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        exit 0
    }
} else {
    Write-ColorText "警告: 正在进行版本降级 ($curVer -> $newVer)！" "Yellow"
    Write-ColorText "降级可能导致数据库 Schema 版本不兼容，系统将自动对 userdata 进行时间戳备份。" "Yellow"
    $ans = Read-Answer "确认要强制降级并更新吗？(Y/N)" "N"
    if ($ans -ne 'Y' -and $ans -ne 'y') {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        exit 0
    }

    $userDataDir = Join-Path $exeDir "userdata"
    if (Test-Path $userDataDir) {
        $backupDir = Join-Path $exeDir "userdata.bak_${curVer}_$timestamp"
        Write-Host "正在备份 userdata 到: $(Split-Path -Leaf $backupDir)..." -ForegroundColor Cyan
        # P0-3: a failed backup must abort the downgrade instead of printing success.
        robocopy $userDataDir $backupDir /E /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) {
            Write-ColorText "备份 userdata 失败 (Robocopy 错误码: $LASTEXITCODE)，已中止降级以保护数据。" "Red"
            Invoke-PausePrompt
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            exit 1
        }
        Write-ColorText "备份完成！" "Green"
    }
}

Write-Host "正在覆盖程序文件 (保留 userdata)..." -ForegroundColor Cyan
$robocopyResult = robocopy $srcDir $exeDir /E /NFL /NDL /NJH /NJS /XD userdata userdata.bak* temps temps_portable_update* /XF *.zip
# Robocopy exit codes 0-7 indicate success
if ($LASTEXITCODE -ge 8) {
    Write-ColorText "文件覆盖复制出错 (Robocopy 错误码: $LASTEXITCODE)" "Red"
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-PausePrompt
    exit 1
}

# Cleanup temp
Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

# The app downloads the package outside the install folder (its own support
# directory), so it is not covered by the robocopy exclusion list above. Drop it
# once the files are in place, otherwise every update leaves a full-size ZIP
# behind in the user's profile.
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
    Start-Process (Join-Path $exeDir "iris.exe")
}
