#Requires -Version 5.1
<#
.SYNOPSIS
  Poll the media folder for new/changed media (and flat .avs), then refresh:
    - ..\media_files.txt          (generate_media_listings_lcl.py)
    - fisheye_batch.m3u / fisheye_batch_potplayer.dpl
    - playlist.m3u / playlist_potplayer.dpl (+ move StreamTo3D .avs via gen_dpl.py)

.DESCRIPTION
  Resolves media root like the batch scripts (parent of 3d_playlist_local, or cwd).
  Single-instance per media root (named mutex). Designed to run hidden in the background;
  both run_batch_*.ps1 scripts can Start-Process this watcher after sync.

.EXAMPLE
  .\Watch-MediaFolderPlaylists.ps1
.EXAMPLE
  .\Watch-MediaFolderPlaylists.ps1 -Once
.EXAMPLE
  .\Watch-MediaFolderPlaylists.ps1 -PollSeconds 30 -Foreground
#>
[CmdletBinding()]
param(
    [string] $MediaRoot = '',
    [string] $PlaylistLocal = '',
    [int] $PollSeconds = 60,
    [switch] $Once,
    [switch] $Foreground,
    [switch] $StartBackground,
    [string] $PythonExe = 'P:\all_scripts\py_venv1\Scripts\python.exe'
)

$ErrorActionPreference = 'Stop'
try { $PSNativeCommandUseErrorActionPreference = $false } catch { }

function Resolve-MediaPlaylistRoots {
    param(
        [string] $MediaRootExplicit,
        [string] $PlaylistLocalExplicit,
        [string] $ScriptDir
    )
    if (-not [string]::IsNullOrWhiteSpace($MediaRootExplicit) -and -not [string]::IsNullOrWhiteSpace($PlaylistLocalExplicit)) {
        return @{
            MediaRoot     = [System.IO.Path]::GetFullPath($MediaRootExplicit)
            PlaylistLocal = [System.IO.Path]::GetFullPath($PlaylistLocalExplicit)
        }
    }
    $dir = if (-not [string]::IsNullOrWhiteSpace($ScriptDir)) {
        [System.IO.Path]::GetFullPath($ScriptDir)
    } else {
        [System.IO.Path]::GetFullPath((Get-Location).Path)
    }
    if ((Split-Path -Leaf $dir) -ieq '3d_playlist_local') {
        $pl = $dir
        $mr = Split-Path -Parent $dir
    } else {
        $mr = $dir
        $pl = Join-Path $mr '3d_playlist_local'
    }
    if (-not [string]::IsNullOrWhiteSpace($MediaRootExplicit)) {
        $mr = [System.IO.Path]::GetFullPath($MediaRootExplicit)
        if ([string]::IsNullOrWhiteSpace($PlaylistLocalExplicit)) {
            $pl = Join-Path $mr '3d_playlist_local'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($PlaylistLocalExplicit)) {
        $pl = [System.IO.Path]::GetFullPath($PlaylistLocalExplicit)
        if ([string]::IsNullOrWhiteSpace($MediaRootExplicit)) {
            $mr = Split-Path -Parent $pl
        }
    }
    return @{
        MediaRoot     = [System.IO.Path]::GetFullPath($mr)
        PlaylistLocal = [System.IO.Path]::GetFullPath($pl)
    }
}

function Get-MediaFolderWatcherMutexName {
    param([string] $MediaRoot)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($MediaRoot.ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
    return "Local\3dPlaylistMediaFolderWatcher_$($hash.Substring(0, 16))"
}

function Start-MediaFolderPlaylistWatcher {
    <#
    .SYNOPSIS
      Launch Watch-MediaFolderPlaylists.ps1 hidden in the background (no-op if already running for this media root).
    #>
    param(
        [string] $WatcherScriptPath,
        [string] $MediaRoot,
        [string] $PlaylistLocal,
        [int] $PollSeconds = 60,
        [string] $PythonExe = 'P:\all_scripts\py_venv1\Scripts\python.exe',
        [string] $ShellExe = ''
    )
    if ([string]::IsNullOrWhiteSpace($WatcherScriptPath) -or -not (Test-Path -LiteralPath $WatcherScriptPath -PathType Leaf)) {
        Write-Warning "Media folder watcher script not found: $WatcherScriptPath"
        return $false
    }
    $roots = Resolve-MediaPlaylistRoots -MediaRootExplicit $MediaRoot -PlaylistLocalExplicit $PlaylistLocal `
        -ScriptDir (Split-Path -Parent $WatcherScriptPath)
    # Child process enforces single-instance via named mutex; a second start exits 0 immediately.
    $shell = $ShellExe
    if ([string]::IsNullOrWhiteSpace($shell)) {
        $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    $argList = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', $WatcherScriptPath,
        '-MediaRoot', $roots.MediaRoot,
        '-PlaylistLocal', $roots.PlaylistLocal,
        '-PollSeconds', "$PollSeconds",
        '-PythonExe', $PythonExe
    )
    $p = Start-Process -FilePath $shell -ArgumentList $argList -WorkingDirectory $roots.PlaylistLocal `
        -WindowStyle Hidden -PassThru
    if ($null -eq $p) {
        Write-Warning 'Failed to start media folder playlist watcher.'
        return $false
    }
    Write-Host "Media folder playlist watcher launch pid=$($p.Id) poll=${PollSeconds}s root=$($roots.MediaRoot) (no-op if already running)"
    return $true
}

function Get-MediaFolderWatchFingerprint {
    param(
        [string] $MediaRoot,
        [string] $PlaylistLocal
    )
    $mediaExts = @('.mp4', '.wmv', '.ts', '.mkv')
    $parts = New-Object System.Collections.Generic.List[string]
    $playlistPrefix = $PlaylistLocal.TrimEnd('\') + '\'

    if (Test-Path -LiteralPath $MediaRoot -PathType Container) {
        Get-ChildItem -LiteralPath $MediaRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $full = $_.FullName
            if ($full.StartsWith($playlistPrefix, [StringComparison]::OrdinalIgnoreCase)) { return }
            if ($_.Name.StartsWith('._')) { return }
            $ext = $_.Extension.ToLowerInvariant()
            if ($mediaExts -notcontains $ext) { return }
            [void]$parts.Add(('M|{0}|{1}|{2}' -f $full.ToLowerInvariant(), $_.Length, $_.LastWriteTimeUtc.Ticks))
        }
    }

    $avsDir = Join-Path $PlaylistLocal 'avs'
    if (Test-Path -LiteralPath $avsDir -PathType Container) {
        Get-ChildItem -LiteralPath $avsDir -File -Filter '*.avs' -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$parts.Add(('A|{0}|{1}|{2}' -f $_.FullName.ToLowerInvariant(), $_.Length, $_.LastWriteTimeUtc.Ticks))
        }
    }

    $stdDir = Join-Path $PlaylistLocal 'standardized'
    if (Test-Path -LiteralPath $stdDir -PathType Container) {
        Get-ChildItem -LiteralPath $stdDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name.StartsWith('._')) { return }
            $ext = $_.Extension.ToLowerInvariant()
            if ($mediaExts -notcontains $ext) { return }
            [void]$parts.Add(('S|{0}|{1}|{2}' -f $_.FullName.ToLowerInvariant(), $_.Length, $_.LastWriteTimeUtc.Ticks))
        }
    }

    $sorted = @($parts | Sort-Object)
    if ($sorted.Count -eq 0) { return 'empty' }
    $text = $sorted -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
        return (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function Update-MediaFolderPlaylists {
    param(
        [string] $MediaRoot,
        [string] $PlaylistLocal,
        [string] $PythonExe
    )
    $listingsPy = Join-Path $PlaylistLocal 'generate_media_listings_lcl.py'
    $genDplPy = Join-Path $PlaylistLocal 'gen_dpl.py'
    $gatePs1 = Join-Path $PlaylistLocal 'individual_transcode\Invoke-BatchPotPlayerGate.ps1'
    $resolvePs1 = Join-Path $PlaylistLocal 'individual_transcode\Resolve-FisheyePlaylistMedia.ps1'
    $mediaListFile = Join-Path $MediaRoot 'media_files.txt'

    Push-Location -LiteralPath $PlaylistLocal
    try {
        if (Test-Path -LiteralPath $listingsPy -PathType Leaf) {
            if (Test-Path -LiteralPath $PythonExe -PathType Leaf) {
                & $PythonExe $listingsPy
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "generate_media_listings_lcl.py exit $LASTEXITCODE"
                } else {
                    Write-Host "Updated media_files.txt under media tree (root=$MediaRoot)"
                }
            } else {
                Write-Warning "Python not found: $PythonExe (skipped media_files.txt refresh)"
            }
        } else {
            Write-Warning "Missing listings script: $listingsPy"
        }

        # Fisheye batch playlists from media_files.txt
        if ((Test-Path -LiteralPath $gatePs1 -PathType Leaf) -and (Test-Path -LiteralPath $mediaListFile -PathType Leaf)) {
            if (Test-Path -LiteralPath $resolvePs1 -PathType Leaf) {
                . $resolvePs1
            }
            . $gatePs1
            $raw = @(Get-Content -LiteralPath $mediaListFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            $eligible = if (Get-Command Get-FisheyeBatchEligibleMediaPaths -ErrorAction SilentlyContinue) {
                @(Get-FisheyeBatchEligibleMediaPaths -MediaLines $raw)
            } else {
                @($raw | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
            }
            if ($eligible.Count -gt 0) {
                $bundle = Write-BatchPotPlayerPlaylists -MediaFullPaths $eligible -PlaylistDir $PlaylistLocal
                Write-Host "Updated fisheye playlists: $($bundle.M3uPath) ($($eligible.Count) eligible)"
            } else {
                Write-Warning "No eligible fisheye media in $mediaListFile; skipped fisheye_batch playlists."
            }
        } else {
            Write-Warning "Skipped fisheye playlist refresh (missing gate script or media_files.txt)."
        }

        # Flat playlists (+ move StreamTo3D AVS exports)
        if (Test-Path -LiteralPath $genDplPy -PathType Leaf) {
            if (Test-Path -LiteralPath $PythonExe -PathType Leaf) {
                & $PythonExe $genDplPy
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "gen_dpl.py exit $LASTEXITCODE"
                } else {
                    Write-Host 'Updated flat playlists (playlist.m3u / playlist_potplayer.dpl)'
                }
            }
        } else {
            Write-Warning "Missing gen_dpl.py: $genDplPy"
        }
    } finally {
        Pop-Location
    }
}

# --- entry (skip when dot-sourced for Start-MediaFolderPlaylistWatcher) ---
if ($MyInvocation.InvocationName -eq '.') {
    return
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    [System.IO.Path]::GetFullPath($PSScriptRoot)
} else {
    [System.IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
}

if ($StartBackground) {
    $started = Start-MediaFolderPlaylistWatcher -WatcherScriptPath (Join-Path $scriptDir 'Watch-MediaFolderPlaylists.ps1') `
        -MediaRoot $MediaRoot -PlaylistLocal $PlaylistLocal -PollSeconds $PollSeconds -PythonExe $PythonExe
    if ($started) { exit 0 } else { exit 2 }
}

$roots = Resolve-MediaPlaylistRoots -MediaRootExplicit $MediaRoot -PlaylistLocalExplicit $PlaylistLocal -ScriptDir $scriptDir
$MediaRoot = $roots.MediaRoot
$PlaylistLocal = $roots.PlaylistLocal

if (-not (Test-Path -LiteralPath $PlaylistLocal -PathType Container)) {
    throw "Playlist folder not found: $PlaylistLocal"
}
if ($PollSeconds -lt 5) { $PollSeconds = 5 }

$mutexName = Get-MediaFolderWatcherMutexName -MediaRoot $MediaRoot
$createdNew = $false
$mutex = $null
$hasHandle = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew)
    if (-not $mutex.WaitOne(0)) {
        Write-Host "Another media folder watcher already holds mutex for: $MediaRoot"
        exit 0
    }
    $hasHandle = $true
} catch {
    Write-Warning "Watcher mutex unavailable ($mutexName); continuing without single-instance guard: $_"
}

$logDir = Join-Path $PlaylistLocal 'individual_transcode\transcode_logs\media_folder_watcher'
if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($logDir)
}
$logPath = Join-Path $logDir ("watcher_{0}_{1}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $PID)
try {
    Start-Transcript -LiteralPath $logPath -Append | Out-Null
} catch {
    Write-Warning "Transcript unavailable: $_"
}

Write-Host "Media folder playlist watcher"
Write-Host "  media root:     $MediaRoot"
Write-Host "  playlist local: $PlaylistLocal"
Write-Host "  poll seconds:   $PollSeconds"
Write-Host "  log:            $logPath"
if ($Once) {
    Write-Host '  mode:           once'
} else {
    Write-Host '  mode:           background poll (Ctrl+C / end process to stop)'
}

$lastFingerprint = $null
try {
    do {
        try {
            $fp = Get-MediaFolderWatchFingerprint -MediaRoot $MediaRoot -PlaylistLocal $PlaylistLocal
            if ($null -eq $lastFingerprint -or $fp -ne $lastFingerprint) {
                if ($null -eq $lastFingerprint) {
                    Write-Host "[$(Get-Date -Format o)] Initial playlist refresh (fingerprint=$fp)"
                } else {
                    Write-Host "[$(Get-Date -Format o)] Change detected; refreshing playlists (fingerprint=$fp)"
                }
                Update-MediaFolderPlaylists -MediaRoot $MediaRoot -PlaylistLocal $PlaylistLocal -PythonExe $PythonExe
                $lastFingerprint = Get-MediaFolderWatchFingerprint -MediaRoot $MediaRoot -PlaylistLocal $PlaylistLocal
            } else {
                Write-Host "[$(Get-Date -Format o)] No change (fingerprint=$fp)"
            }
        } catch {
            Write-Warning "[$(Get-Date -Format o)] Watcher refresh failed: $_"
        }
        if ($Once) { break }
        Start-Sleep -Seconds $PollSeconds
    } while ($true)
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    if ($null -ne $mutex -and $hasHandle) {
        try { $mutex.ReleaseMutex() | Out-Null } catch { }
        try { $mutex.Dispose() } catch { }
    }
}
