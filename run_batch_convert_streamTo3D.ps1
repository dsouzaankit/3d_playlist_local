# This runs a sequential 3D playlist creation workflow
param(
    [switch] $SkipMediaFolderWatcher,
    [int] $MediaFolderWatcherPollSec = 60
)

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    [System.IO.Path]::GetFullPath($PSScriptRoot)
} else {
    [System.IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
}
if ((Split-Path -Leaf $scriptDir) -ieq '3d_playlist_local') {
    $playlistLocal = $scriptDir
    $mediaRoot = Split-Path -Parent $scriptDir
    Write-Host "Batch script is inside 3d_playlist_local; media root resolved to: $mediaRoot"
} else {
    $mediaRoot = $scriptDir
    $playlistLocal = Join-Path $mediaRoot '3d_playlist_local'
}
$syncSource = 'P:\all_scripts\3d_playlist_local'
$pythonExe = 'P:\all_scripts\py_venv1\Scripts\python.exe'

Set-Location -LiteralPath $mediaRoot

try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -ErrorAction Stop
} catch {
    Write-Host "Note: Set-ExecutionPolicy skipped (effective policy unchanged): $($_.Exception.Message)"
}

# place alongside media_files.txt (if available)!
P:\all_scripts\setup_venv.bat
# copy recursively and merge (overwrite with latest version wherever applicable)
# /XF: keep local transcode/orchestrator logs (individual_transcode\transcode_logs, etc.)
robocopy $syncSource $playlistLocal /E /XF *.log /XD ai ign .git standardized avs op_logs transcode_logs
Set-Location -LiteralPath $playlistLocal

# Retain newest 50 flat/hybrid .avs under .\avs (StreamTo3D GUI + flat_temp exports)
$purgeAvsScript = Join-Path $playlistLocal 'Purge-OldAvs.ps1'
if (Test-Path -LiteralPath $purgeAvsScript -PathType Leaf) {
    & $purgeAvsScript -AvsFolder (Join-Path $playlistLocal 'avs') -KeepCount 50
} else {
    Write-Warning "Purge-OldAvs.ps1 not found: $purgeAvsScript"
}

# standardize vertical videos without blocking current script!
$stdizeScript = Join-Path $playlistLocal 'selective_stdize.ps1'
Start-Process pwsh.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$stdizeScript`"" -WorkingDirectory $playlistLocal
# refresh ..\media_files.txt!
& $pythonExe (Join-Path $playlistLocal 'generate_media_listings_lcl.py')

# Background poll: new media / .avs -> refresh media_files.txt + fisheye + flat playlists
if (-not $SkipMediaFolderWatcher) {
    $watcherScript = Join-Path $playlistLocal 'Watch-MediaFolderPlaylists.ps1'
    if (Test-Path -LiteralPath $watcherScript -PathType Leaf) {
        & $watcherScript -StartBackground -MediaRoot $mediaRoot -PlaylistLocal $playlistLocal `
            -PollSeconds $MediaFolderWatcherPollSec -PythonExe $pythonExe
    } else {
        Write-Warning "Media folder watcher not found: $watcherScript"
    }
}

$mutexName = "Global\UniqueScriptName"
$timeoutSeconds = $(30*60)
$mutex = $null
$hasHandle = $false
$mutexAcquired = $false

try {
    # Attempt to open an existing Mutex, otherwise create a new one
    # $false means the calling thread does not initially own the mutex
    $mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$hasHandle)
    # Wait until the mutex is available, up to the specified timeout
    try {
        if ($false -eq $mutex.WaitOne([System.TimeSpan]::FromSeconds($timeoutSeconds))) {
            Write-Warning "Another StreamTo3d conversion already running or $($timeoutSeconds)s wait timed out. Exiting"
            return
        }
        $mutexAcquired = $true
    } catch [System.Threading.AbandonedMutexException] {
        Write-Warning 'Previous StreamTo3D batch left an abandoned mutex (window closed); taking ownership and continuing.'
        $mutexAcquired = $true
    }
    # If we get here, this script owns the Mutex and can access the critical section
    Write-Host "Mutex acquired. Starting StreamTo3D automated conversion..."
    # below is non-blocking call for StreamTo3D batch conversion
    $st3d_jb = Start-Job -ScriptBlock {
        param($Py, $Dir)
        Set-Location -LiteralPath $Dir
        & $Py .\batch_convert_streamTo3D.py
    } -ArgumentList $pythonExe, $playlistLocal
    Write-Host "StreamTo3D automation running in background..."
    do {
        Write-Host "StreamTo3D automation still running. Moving new avs files to .\avs and updating 3D media playlists (M3U + DPL)!"
        & $pythonExe (Join-Path $playlistLocal 'gen_dpl.py')
        Write-Host "Moved new avs files and updated playlists. Sleeping 60s"
        Start-Sleep -Seconds 60
        # Refresh the job state
        $st3d_jb = Get-Job -Id $st3d_jb.Id
    } while ($st3d_jb.State -ne "Completed" -and $st3d_jb.State -ne "Failed")
    # re-run gen_dpl.py to grab remaining avs files and refresh both playlists
    & $pythonExe (Join-Path $playlistLocal 'gen_dpl.py')
    # Cleanup and final message after the loop exits
    if ($st3d_jb.State -eq "Completed") {
        Write-Host "StreamTo3D automated batch processing (ID: $($st3d_jb.Id)) has completed."
        Receive-Job -Job $st3d_jb # Retrieve the job output
        Remove-Job -Job $st3d_jb # Clean up the job
    } else {
        Write-Host "StreamTo3D automated batch processing (ID: $($st3d_jb.Id)) ended with state: $($st3d_jb.State)"
        # Handle failed state if necessary
    }
    Write-Host "Critical section finished."
}
catch [System.UnauthorizedAccessException] {
    Write-Error "Access denied for the Mutex name. Try a different name (e.g., 'Local\...') or check permissions."
}
catch {
    Write-Error "An error occurred: $_"
}
finally {
    # It is crucial to release the mutex in a finally block to ensure it's always released,
    # even if an error occurs. The owning thread *must* release it.
    if ($null -ne $mutex -and $mutexAcquired) {
        try { $mutex.ReleaseMutex() | Out-Null } catch { }
        try { $mutex.Dispose() } catch { }
        Write-Host "Mutex released."
    }
}
