#Requires -Version 5.1
<#
.SYNOPSIS
  Runs Run-TranscodeFfmpeg.ps1 for every .avs under a folder until the live playlist/disk set is done.
  No required parameters: defaults to .\avs beside this script and playlist.m3u here (double-click friendly).

.DESCRIPTION
  Intended to live beside playlist.m3u (same folder as this script after your setup copy).
  Double-click friendly: working directory is set to this script's folder, so default .\avs is the .\avs
  next to this script. Creates .\avs if it does not exist yet.
  Fisheye DLNA flow: right-click prepare (Run-V360PrepareFisheye.ps1) or run_batch_fisheye_v360.ps1; flat orchestrator for StreamTo3D SBS .avs only.
  Before each clip, re-reads playlist.m3u and re-scans .\avs (watcher/gen_dpl may replace files mid-run),
  skipping paths already completed this run. On-disk .avs not listed in the M3U are processed as orphans
  after the live M3U remainder is empty.

  Press Enter in this console while a transcode is running to kill the child workflow and exit.
  Safety timeout: entire orchestrator run is capped at 1.5 hours (5400s) by default (-BatchTimeoutSec), same as
  run_batch_fisheye_v360.ps1. Children use -TranscodeTimeoutSec -1 so only this batch deadline applies. On timeout
  it stops the active child tree, saves last successful sidecar anchor when available, and exits with code 124.

  Transcode queue resume (not media player): optional anchor path from (1) -ResumePlaylistAfter, else (2) PotPlayer DPL
  playname (playlist_potplayer.dpl preferred; playlist.dpl fallback), else (3) DPL sidecar (*.dpl.transcode_queue_last).
  That path is the last completed (or current) clip. Handover runs (parameter -ResumePlaylistAfter from
  Run-TranscodeFfmpeg.ps1) rotate to the next M3U entry after a match (matching line moved to end, wrap). Non-handover runs
  anchored by DPL playname start on the matching current item.
  Child -SsMsOverride precedence: non-handover uses DPL playtime first (backed off by 30s, floored at 0), then DPL per-entry
  *start* timestamp for that clip, then DAUM RememberFiles registry fallback in the child. Handover uses per-entry *start*
  only (no DPL playtime usage in handover), then registry fallback.

  Session startup order (after mutex + at least one .avs):
    A) Companion binaries: non-recursive *.exe in -CompanionBinaryFolder (default P:\all_scripts\AutoHotkey), name order,
       WorkingDirectory = that folder. They keep running through the PotPlayer gate and the whole transcode queue until finally.
    B) Inside try: load M3U paths, then PotPlayer DPL gate (below), then DPL/sidecar anchor + transcode loop.

  PotPlayer spawn (DPL gate):
   - DPL path: playlist_potplayer.dpl (M3U stem + _potplayer.dpl), else playlist.dpl beside the M3U.
   - If the file exists and -SkipPotPlayer is off: Start-Process PotPlayer with the DPL path only (-PotPlayerExe optional).
      Daum PotPlayer often ignores /fullscreen on the CLI; the script then waits for the process main window and sends
      Alt+Enter (best effort) to toggle fullscreen. Wait-Process on the spawned PID, then sleep 2s for DPL flush.
   - Single-instance PotPlayer may exit the launcher while the player stays open - Wait-Process is not always "preview done."
      Use -SkipPotPlayer for unattended runs. -DryRun does not launch PotPlayer.

  Companion shutdown (AutoHotkey folder helpers):
   - Companions are placed in a Windows job with Kill On Job Close so closing the orchestrator console (X) or ending the
      PowerShell process tears down companion trees even when try/finally does not run.
   - try/finally also calls Stop-OrchestratorCompanionBinaries: taskkill /PID <root> /T /F per recorded companion root PID.
   - -SkipCompanionBinaries skips start and stop. -DryRun skips starting companions. Exit before companions (no .avs, mutex
      busy) leaves nothing to kill.

  Companion scripts (typical AutoHotkey *.exe in CompanionBinaryFolder) may automate PotPlayer via mouse clicks.

.PARAMETER AvsFolder
  Directory whose .avs files (immediate children only) participate. Default is .\avs (relative to this
  script's folder after startup).

.PARAMETER PlaylistFile
  Path to M3U. Default: playlist.m3u next to this script (same folder as Run-TranscodeOrchestrator.ps1).

.PARAMETER TranscodeScript
  Path to Run-TranscodeFfmpeg.ps1. If omitted, searches: individual_transcode\ under this script's folder,
  then this folder, then parent\individual_transcode (first existing file wins). If you start the orchestrator by
  double-clicking this copy (no -TranscodeScript), that resolution picks the transcode script next to this orchestrator
  (typically .\individual_transcode\Run-TranscodeFfmpeg.ps1). Child transcode_logs\ and transcode_failures.log then live
  under that file's directory. When the orchestrator is started after a context-menu transcode, the launcher passes
  -TranscodeScript as that run's full path to Run-TranscodeFfmpeg.ps1, so child logs stay on the same path as the
  registered launcher unless you override here.

.PARAMETER Recurse
  Include .avs in subfolders of -AvsFolder.

.PARAMETER DryRun
  Log planned order and commands only; no transcodes.

.PARAMETER SkipPotPlayer
  Skip the PotPlayer DPL gate: do not spawn PotPlayer; read DPL file and sidecar immediately (automation / headless).
  Run-TranscodeFfmpeg.ps1 passes this and -SkipCompanionBinaries when it hands off to the orchestrator after a successful context-menu transcode.

.PARAMETER PotPlayerExe
  Full path to PotPlayer (e.g. ...\PotPlayerMini64.exe). If empty, Get-Command and Program Files DAUM\PotPlayer paths are tried.

.PARAMETER CompanionBinaryFolder
  Folder of companion *.exe files (default P:\all_scripts\AutoHotkey). Started after mutex + .avs check; each root process is
  assigned to a Windows job (kill on job close) and finally also uses taskkill /T /F on each root PID. Not recursive; only *.exe
  in the folder root.

.PARAMETER SkipCompanionBinaries
  Do not start or stop companion executables from CompanionBinaryFolder (no AutoHotkey companion session).
  Run-TranscodeFfmpeg.ps1 passes this on context-menu handover together with -SkipPotPlayer so companions are not relaunched there.

.PARAMETER Fisheye
  Pass -Fisheye to each child Run-TranscodeFfmpeg.ps1 (.avs only): per-eye v360 after StreamTo3D SBS. Use flat source in StreamTo3D.

.PARAMETER BatchTimeoutSec
  Entire-queue wall-clock limit in seconds (default 5400). Same parameter name and semantics as run_batch_fisheye_v360.ps1.
  Deadline is orchestrator process start + this value. Children get -TranscodeTimeoutSec -1 so only this limit applies.

.PARAMETER PrepareHeartbeatSec
  Fixed child-wait heartbeat interval in seconds. When > 0, overrides -PrepareHeartbeatDivisor for every clip.

.PARAMETER PrepareHeartbeatDivisor
  Per-clip child-wait heartbeat = ceil(source_duration / divisor) via ffprobe on the .avs DirectShowSource path when
  present (else the .avs path). Default 5 (same as fisheye batch). Set 0 to disable heartbeat lines.

.PARAMETER ResumePlaylistAfter
  Full path to the last processed clip (anchor). Traversal starts at the next M3U line after the first line whose file name
  matches this path's leaf (case-insensitive), or matches the anchor leaf with a trailing ".avs" removed (e.g. foo.mp4.avs
  matches a playlist line for foo.mp4). The matching line is placed at the end of the rotated pass (wrap). Overrides DPL
  sidecar and DPL playname for choosing the anchor only; DPL playtime still applies per playname rules in .DESCRIPTION.

.NOTES
  Mutex behavior:
   - Orchestrator uses a per-playlist mutex (hashed from resolved playlist path) so only one orchestrator can run for
      the same playlist at a time (duplicate starts exit with code 3).
   - Run-TranscodeFfmpeg.ps1 has its own global transcode mutex (Local\FfmpegAvsTranscodeLock), so child transcodes
      still serialize process-wide even across different orchestrators or manual/context-menu launches.
      Result: per-playlist queue duplication is prevented here, while the transcode script remains the final single-lane gate.

  PotPlayer + companions summary:
    Companion exes start first (each root assigned to a Kill-On-Close Windows job so closing the orchestrator window ends them);
    PotPlayer (if DPL exists) runs next while companions stay up; finally taskkills companions after the queue finishes or cancels.
    See .DESCRIPTION for full order and limits.

  This script does not Start-Transcript or write an orchestrator log file; output is the hosting console only.
  Queue progress is reflected in playlist_potplayer.dpl.transcode_queue_last
  (or playlist.dpl.transcode_queue_last when using legacy DPL name). That sidecar is created/updated after each
  successful child transcode, and on cancel (Enter or child exit 130) when at least one clip already succeeded in
  the current run; if no clip has succeeded yet, no sidecar is written. On full completion (all pending processed),
  the DPL sidecar is removed so the next full run starts from top unless DPL playname/parameter provide an anchor.
  Queue anchor persistence is separate from seek persistence: orchestrator stores clip order anchor only; per-clip seek
  still comes from PotPlayer RememberFiles lookup in Run-TranscodeFfmpeg.ps1, which reads but does not update PotPlayer registry.

  Each transcode runs in its own child PowerShell process (Run-TranscodeFfmpeg.ps1). Children use -NoLogFile so the
  queue does not create a full transcript per clip; on failure a short line is appended to transcode_logs\transcode_failures.log
  beside whichever Run-TranscodeFfmpeg.ps1 path -TranscodeScript resolves to (command line only, not ffmpeg stderr).
  Child process stdout/stderr are redirected to per-clip files under transcode_logs\orchestrator_child\ and child windows
  are started hidden, so live ffmpeg output is not shown in child consoles during orchestrator runs.
  FFmpeg typically writes stream info/progress/errors to stderr, so the per-clip *.stderr.log is usually the primary
  diagnostic log (stdout may be sparse). While waiting on each hidden child, the orchestrator prints a heartbeat at
  source_duration/-PrepareHeartbeatDivisor seconds per clip (Get-FisheyePrepareHeartbeat.ps1; fallback 60s if unknown;
  same as fisheye batch) with elapsed time, stdout log tail hint, and stderr log path.
  With default -TranscodeScript (search under this orchestrator's folder), that is typically
  .\individual_transcode\Run-TranscodeFfmpeg.ps1 next to this script, so logs are under .\individual_transcode\transcode_logs\.
  If you only pass -TranscodeScript from a context-menu transcode, that path is usually the same as the registered
  Explorer launcher. See Run-TranscodeFfmpeg.ps1 and Install-ContextMenu.ps1 for log-root details. For deep traces run
  the transcode script once on the same input without -NoLogFile.

  A warning "Transcode exit code -1073741510" means the child exited with NTSTATUS 0xC000013A (STATUS_CONTROL_C_EXIT):
  Windows aborted the process - typically because you closed that PowerShell window, pressed Ctrl+C, or the tree
  was killed - not a normal "FFmpeg finished with an error" code (those are usually small positive integers).
#>
param(
    [string] $AvsFolder = '.\avs',
    [string] $PlaylistFile = '',
    [string] $TranscodeScript = '',
    [string] $ResumePlaylistAfter = '',
    [switch] $Recurse,
    [switch] $DryRun,
    [switch] $SkipPotPlayer,
    [string] $PotPlayerExe = '',
    [string] $CompanionBinaryFolder = 'P:\all_scripts\AutoHotkey',
    [switch] $SkipCompanionBinaries,
    [switch] $Fisheye,
    [int] $BatchTimeoutSec = 5400,
    [int] $PrepareHeartbeatSec = 0,
    [int] $PrepareHeartbeatDivisor = 5,
    [int] $LiveQueueIdlePollSec = 60
)

$ErrorActionPreference = 'Stop'

# 0xC000013A STATUS_CONTROL_C_EXIT (shown as signed int when reading Process.ExitCode)
$script:ExitCodeStatusControlCExit = -1073741510
$script:ExitCodeTimeout = 124

function Get-OrchestratorStartTimeUtc {
    try {
        return (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
    } catch {
        Write-Warning "Could not read orchestrator start time for pid=$PID; parent watch will use PID only."
        return ''
    }
}

function Convert-BatchUtcIsoToDateTime {
    param([string] $UtcIso)
    if ([string]::IsNullOrWhiteSpace($UtcIso)) { return $null }
    try {
        return [datetime]::Parse(
            $UtcIso,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    } catch {
        return $null
    }
}

function Get-BatchDeadlineUtcIso {
    param(
        [string] $StartUtcIso,
        [int] $TimeoutSec
    )
    if ($TimeoutSec -lt 1) { return '' }
    $start = Convert-BatchUtcIsoToDateTime -UtcIso $StartUtcIso
    if ($null -eq $start) {
        $start = [DateTime]::UtcNow
    }
    return $start.AddSeconds($TimeoutSec).ToString('o')
}

function Get-BatchRemainingSeconds {
    param([datetime] $DeadlineUtc)
    if ($null -eq $DeadlineUtc) { return $null }
    $rem = [Math]::Floor(($DeadlineUtc - [DateTime]::UtcNow).TotalSeconds)
    if ($rem -lt 0) { return 0 }
    return [int]$rem
}

function Test-BatchDeadlineExpired {
    param([datetime] $DeadlineUtc)
    if ($null -eq $DeadlineUtc -or $DeadlineUtc -le [datetime]::MinValue) { return $false }
    return [DateTime]::UtcNow -ge $DeadlineUtc
}

function Stop-OrchestratorForBatchDeadline {
    param(
        [datetime] $DeadlineUtc,
        [ref] $TimedOutByLimit,
        [ref] $Cancelled
    )
    if (-not (Test-BatchDeadlineExpired -DeadlineUtc $DeadlineUtc)) { return $false }
    Write-Warning "Orchestrator batch deadline reached (${BatchTimeoutSec}s entire-queue limit)."
    $TimedOutByLimit.Value = $true
    $Cancelled.Value = $true
    return $true
}

function Get-ChildTranscodeExitWarningSuffix {
    param([int] $ExitCode)
    if ($ExitCode -eq $script:ExitCodeStatusControlCExit) {
        return ' [0xC000013A STATUS_CONTROL_C_EXIT: child aborted - e.g. closed that PowerShell window or Ctrl+C; not a typical FFmpeg error code]'
    }
    if ($ExitCode -eq -2146232797) {
        return ' [0x80131623 unhandled PowerShell exception in child - check orchestrator_child/*.stdout.log; if empty, update orchestrator (uses -File launch, not -Command)]'
    }
    return ''
}

function New-TranscodeChildPowerShellArgs {
    param(
        [Parameter(Mandatory = $true)]
        [string] $TranscodeScript,
        [Parameter(Mandatory = $true)]
        [string] $InputPath,
        [Parameter(Mandatory = $true)]
        [int] $OrchestratorPid,
        [string] $OrchestratorStartTimeUtc = '',
        [string] $WorkflowDeadlineUtc = '',
        [string] $SegmentNameSuffix = '',
        [string] $OutputDirectory = '',
        [switch] $Fisheye,
        [object] $SsMsOverride = $null
    )
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $TranscodeScript,
        '-LiteralPath', $InputPath,
        '-NoPause', '-SkipOrchestrator', '-NoLogFile',
        '-OrchestratorPid', "$OrchestratorPid"
    )
    if (-not [string]::IsNullOrWhiteSpace($OrchestratorStartTimeUtc)) {
        $args += @('-OrchestratorStartTimeUtc', $OrchestratorStartTimeUtc)
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkflowDeadlineUtc)) {
        $args += @('-WorkflowDeadlineUtc', $WorkflowDeadlineUtc)
    }
    if (-not [string]::IsNullOrWhiteSpace($SegmentNameSuffix)) {
        $args += @('-SegmentNameSuffix', $SegmentNameSuffix)
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $args += @('-OutputDirectory', $OutputDirectory)
    }
    if ($null -ne $SsMsOverride -and [int64]$SsMsOverride -ge 0) {
        $args += @('-SsMsOverride', "$SsMsOverride")
    }
    if ($Fisheye.IsPresent) {
        $args += '-Fisheye'
    }
    # Single batch deadline on orchestrator; do not apply per-child 5400s (matches fisheye batch prepare).
    $args += @('-TranscodeTimeoutSec', '-1')
    return $args
}

function Write-OrchestratorFailureSummary {
    param(
        [string] $FailureLogPath,
        [string] $InputPath,
        [int] $ExitCode,
        [string] $Phase
    )
    try {
        if ([string]::IsNullOrWhiteSpace($FailureLogPath)) { return }
        $dir = [System.IO.Path]::GetDirectoryName($FailureLogPath)
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            [void][System.IO.Directory]::CreateDirectory($dir)
        }
        $when = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $sep = ('=' * 72)
        $lines = @(
            $sep,
            "$when | exit=$ExitCode | source=orchestrator | phase=$Phase",
            "input: $InputPath",
            $sep
        )
        Add-Content -LiteralPath $FailureLogPath -Value ($lines -join [Environment]::NewLine) -Encoding utf8
    } catch {
        Write-Warning "Could not append orchestrator failure summary: $_"
    }
}

function Get-NormalizedChildExitCode {
    param([object] $RawExitCode)
    try {
        if ($null -eq $RawExitCode) { return 1 }
        return [int]$RawExitCode
    } catch {
        return 1
    }
}

function Initialize-OrchestratorFailureLog {
    param([string] $FailureLogPath)
    try {
        if ([string]::IsNullOrWhiteSpace($FailureLogPath)) { return $false }
        $dir = [System.IO.Path]::GetDirectoryName($FailureLogPath)
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            [void][System.IO.Directory]::CreateDirectory($dir)
        }
        $when = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $FailureLogPath -Value ("=== orchestrator session start: $when ===") -Encoding utf8
        return $true
    } catch {
        Write-Warning "Could not initialize failure summary log at '$FailureLogPath': $_"
        return $false
    }
}

function New-ChildProcessLogPaths {
    param(
        [string] $TranscodeScriptPath,
        [string] $InputPath
    )
    $work = [System.IO.Path]::GetDirectoryName($TranscodeScriptPath)
    $root = [System.IO.Path]::Combine($work, 'transcode_logs', 'orchestrator_child')
    [void][System.IO.Directory]::CreateDirectory($root)
    $leaf = [System.IO.Path]::GetFileName($InputPath)
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'unknown' }
    $safe = ($leaf -replace '[^A-Za-z0-9._-]', '_')
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $base = [System.IO.Path]::Combine($root, "${stamp}_${safe}")
    return @{
        StdOut = "$base.stdout.log"
        StdErr = "$base.stderr.log"
    }
}

function Convert-ToProcessArgumentLine {
    param([string[]] $Args)
    return (($Args | ForEach-Object {
        if ($null -eq $_) { '""' }
        elseif ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' }
        else { $_ }
    }) -join ' ')
}

function Resolve-TranscodeScriptPath {
    param(
        [string] $OrchestratorRoot,
        [string] $Explicit
    )
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "TranscodeScript not found: $Explicit"
        }
        return [System.IO.Path]::GetFullPath($Explicit)
    }
    if ([string]::IsNullOrWhiteSpace($OrchestratorRoot)) {
        $OrchestratorRoot = $PSScriptRoot
    }
    $candidates = @(
        (Join-Path $OrchestratorRoot 'individual_transcode\Run-TranscodeFfmpeg.ps1'),
        (Join-Path $OrchestratorRoot 'Run-TranscodeFfmpeg.ps1'),
        (Join-Path ([System.IO.Path]::GetDirectoryName($OrchestratorRoot)) 'individual_transcode\Run-TranscodeFfmpeg.ps1')
    )
    foreach ($c in $candidates) {
        try {
            $full = [System.IO.Path]::GetFullPath($c)
        } catch {
            continue
        }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            return $full
        }
    }
    throw 'Run-TranscodeFfmpeg.ps1 not found. Pass -TranscodeScript with the full path.'
}

function Get-OrchestratorMutexName {
    param([string] $PlaylistFullPath)
    $norm = ([System.IO.Path]::GetFullPath($PlaylistFullPath)).ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($norm)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = $md5.ComputeHash($bytes)
    } finally {
        $md5.Dispose()
    }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return "Local\TranscodeOrchestrator_$hex"
}

function Get-FullPathOrNull {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        return [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $null
    }
}

function Resolve-M3uMediaEntry {
    param(
        [string] $PlaylistDir,
        [string] $Entry
    )
    $e = $Entry.Trim()
    if ($e.Length -gt 0 -and [int][char]$e[0] -eq 0xFEFF) {
        $e = $e.Substring(1).TrimStart()
    }
    if ($e -eq '') { return $null }
    if ($e.StartsWith('file:///', [StringComparison]::OrdinalIgnoreCase)) {
        $e = [Uri]::UnescapeDataString($e.Substring(8)).Replace('/', [System.IO.Path]::AltDirectorySeparatorChar)
        $e = $e.Replace([System.IO.Path]::AltDirectorySeparatorChar, [System.IO.Path]::DirectorySeparatorChar)
    }
    if ($e -match '^(?i)(https?|ftp)://') {
        return $null
    }
    try {
        if ([System.IO.Path]::IsPathRooted($e)) {
            return [System.IO.Path]::GetFullPath($e)
        }
        return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PlaylistDir, $e))
    } catch {
        return $null
    }
}

function Read-M3uOrderedPaths {
    param([string] $M3uPath)
    if (-not (Test-Path -LiteralPath $M3uPath -PathType Leaf)) {
        throw "Playlist not found: $M3uPath"
    }
    $playlistDir = [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($M3uPath))
    $lines = Get-Content -LiteralPath $M3uPath
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trim = $line.Trim()
        if ($trim.StartsWith('#EXTINF', [StringComparison]::OrdinalIgnoreCase)) {
            if ($i + 1 -lt $lines.Count) {
                $i++
                $next = $lines[$i].Trim()
                if ($next -ne '' -and $next[0] -ne '#') {
                    $resolved = Resolve-M3uMediaEntry -PlaylistDir $playlistDir -Entry $next
                    if ($resolved) { [void]$out.Add($resolved) }
                }
            }
            continue
        }
        if ($trim[0] -eq '#') { continue }
        $resolved = Resolve-M3uMediaEntry -PlaylistDir $playlistDir -Entry $trim
        if ($resolved) { [void]$out.Add($resolved) }
    }
    return [string[]]$out.ToArray()
}

function Get-TranscodeProgressSidecarPath {
    param([string] $M3uPath)
    return "$M3uPath.transcode_queue_last"
}

function Get-LastAnchorFromM3uCommentLines {
    param(
        [string] $M3uPath,
        [string] $PlaylistDir
    )
    $lines = Get-Content -LiteralPath $M3uPath
    $last = $null
    foreach ($line in $lines) {
        $m = [regex]::Match($line, '^\s*#\s*transcode-queue-last:\s*(.+?)\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) { continue }
        $raw = $m.Groups[1].Value.Trim()
        if ($raw -eq '') { continue }
        $resolved = Resolve-M3uMediaEntry -PlaylistDir $PlaylistDir -Entry $raw
        if ($resolved) { $last = $resolved }
    }
    return $last
}

function Read-AnchorPathFromSidecar {
    param([string] $SidecarPath)
    if (-not (Test-Path -LiteralPath $SidecarPath)) { return $null }
    $line = @(Get-Content -LiteralPath $SidecarPath -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ($line.Count -eq 0) { return $null }
    $t = [string]$line[0].Trim()
    if ($t -eq '') { return $null }
    try {
        return [System.IO.Path]::GetFullPath($t)
    } catch {
        return $null
    }
}

function Read-DplPlaybackState {
    param([string] $DplPath)
    if (-not (Test-Path -LiteralPath $DplPath -PathType Leaf)) { return $null }
    $lines = Get-Content -LiteralPath $DplPath -ErrorAction SilentlyContinue
    $playname = $null
    $playtimeMs = $null
    foreach ($line in $lines) {
        if ($null -eq $playname) {
            $mName = [regex]::Match($line, '^\s*playname\s*=\s*(.*?)\s*$')
            if ($mName.Success) {
                $val = $mName.Groups[1].Value.Trim()
                if ($val -ne '') { $playname = $val }
            }
        }
        if ($null -eq $playtimeMs) {
            $mTime = [regex]::Match($line, '^\s*playtime\s*=\s*(.*?)\s*$')
            if ($mTime.Success) {
                $raw = $mTime.Groups[1].Value.Trim()
                if ($raw -match '^\d+$') {
                    try { $playtimeMs = [int64]$raw } catch { $playtimeMs = $null }
                }
            }
        }
        if ($null -ne $playname -and $null -ne $playtimeMs) { break }
    }
    if ($null -eq $playname -and $null -eq $playtimeMs) { return $null }
    return @{
        PlayName = $playname
        PlayTimeMs = $playtimeMs
    }
}

function Read-DplEntryStartTimesMs {
    param(
        [string] $DplPath,
        [string] $PlaylistDir
    )
    $map = [System.Collections.Generic.Dictionary[string,int64]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $DplPath -PathType Leaf)) { return $map }
    $lines = Get-Content -LiteralPath $DplPath -ErrorAction SilentlyContinue
    foreach ($line in @($lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $tokens = @(([string]$line).Split('*'))
        if ($tokens.Count -lt 4) { continue }
        $fileVal = $null
        $startVal = $null
        for ($i = 0; $i -lt $tokens.Count - 1; $i++) {
            $k = $tokens[$i].Trim()
            if ($k.Equals('file', [StringComparison]::OrdinalIgnoreCase)) {
                $fileVal = $tokens[$i + 1].Trim()
            } elseif ($k.Equals('start', [StringComparison]::OrdinalIgnoreCase)) {
                $startVal = $tokens[$i + 1].Trim()
            }
        }
        if ([string]::IsNullOrWhiteSpace($fileVal) -or [string]::IsNullOrWhiteSpace($startVal)) { continue }
        $ms = 0L
        if (-not [int64]::TryParse($startVal, [ref]$ms)) { continue }
        if ($ms -lt 0) { continue }
        $resolved = Resolve-M3uMediaEntry -PlaylistDir $PlaylistDir -Entry $fileVal
        if ([string]::IsNullOrWhiteSpace($resolved)) { continue }
        $full = [System.IO.Path]::GetFullPath($resolved)
        $map[$full] = $ms
    }
    return $map
}

function Get-AdjustedSeekMsForScenario {
    param(
        [Nullable[int64]] $SeekMs,
        [int64] $BackoffMs
    )
    if ($null -eq $SeekMs) { return $null }
    if ($SeekMs -lt 0) { return $null }
    if ($BackoffMs -le 0) { return [int64]$SeekMs }
    $adj = [int64]$SeekMs - [int64]$BackoffMs
    if ($adj -lt 0) { $adj = 0 }
    return $adj
}

function Write-TranscodeProgressSidecar {
    param(
        [string] $SidecarPath,
        [string] $CompletedAvsFullPath
    )
    $dir = [System.IO.Path]::GetDirectoryName($SidecarPath)
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -LiteralPath $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $SidecarPath -Value ([System.IO.Path]::GetFullPath($CompletedAvsFullPath)) -Encoding utf8
}

function Write-TranscodeProgressSidecars {
    param(
        [string[]] $SidecarPaths,
        [string] $CompletedAvsFullPath
    )
    foreach ($sidecar in @($SidecarPaths)) {
        if ([string]::IsNullOrWhiteSpace($sidecar)) { continue }
        Write-TranscodeProgressSidecar -SidecarPath $sidecar -CompletedAvsFullPath $CompletedAvsFullPath
    }
}

function Remove-TranscodeProgressSidecars {
    param([string[]] $SidecarPaths)
    foreach ($sidecar in @($SidecarPaths)) {
        if ([string]::IsNullOrWhiteSpace($sidecar)) { continue }
        if (Test-Path -LiteralPath $sidecar) {
            Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue
            Write-Host "Removed progress sidecar (next full run starts at top of M3U): $sidecar"
        }
    }
}

function Test-PlaylistEntryMatchesResumeAnchor {
    param(
        [string] $PlaylistEntryFullPath,
        [string] $AnchorFullPath
    )
    if ([string]::IsNullOrWhiteSpace($PlaylistEntryFullPath) -or [string]::IsNullOrWhiteSpace($AnchorFullPath)) {
        return $false
    }
    $p = Get-FullPathOrNull -Path $PlaylistEntryFullPath
    $a = Get-FullPathOrNull -Path $AnchorFullPath
    if ($null -eq $p -or $null -eq $a) { return $false }
    $entryLeaf = [System.IO.Path]::GetFileName($p)
    $anchorLeaf = [System.IO.Path]::GetFileName($a)
    if ($entryLeaf.Equals($anchorLeaf, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($anchorLeaf.Length -gt 4 -and $anchorLeaf.EndsWith('.avs', [StringComparison]::OrdinalIgnoreCase)) {
        $withoutAvs = $anchorLeaf.Substring(0, $anchorLeaf.Length - 4)
        if ($entryLeaf.Equals($withoutAvs, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Playlist order for "resume after": next M3U line after a match runs first; matching line wraps to end.
function Get-M3uOrderRotatedAfterPath {
    param(
        [string[]] $OrderedPaths,
        [string] $AfterFullPath
    )
    if ($null -eq $OrderedPaths -or $OrderedPaths.Count -eq 0) { return [string[]]@() }
    if ([string]::IsNullOrWhiteSpace($AfterFullPath)) { return [string[]]$OrderedPaths }
    $idx = -1
    for ($i = 0; $i -lt $OrderedPaths.Count; $i++) {
        if (Test-PlaylistEntryMatchesResumeAnchor -PlaylistEntryFullPath $OrderedPaths[$i] -AnchorFullPath $AfterFullPath) {
            $idx = $i
            break
        }
    }
    if ($idx -lt 0) { return [string[]]$OrderedPaths }
    $n = $OrderedPaths.Count
    $rot = New-Object System.Collections.Generic.List[string]
    for ($j = $idx + 1; $j -lt $n; $j++) {
        [void]$rot.Add($OrderedPaths[$j])
    }
    for ($j = 0; $j -le $idx; $j++) {
        [void]$rot.Add($OrderedPaths[$j])
    }
    return [string[]]$rot.ToArray()
}

# Playlist order for "resume at": matching line runs first.
function Get-M3uOrderRotatedAtPath {
    param(
        [string[]] $OrderedPaths,
        [string] $AnchorFullPath
    )
    if ($null -eq $OrderedPaths -or $OrderedPaths.Count -eq 0) { return [string[]]@() }
    if ([string]::IsNullOrWhiteSpace($AnchorFullPath)) { return [string[]]$OrderedPaths }
    $idx = -1
    for ($i = 0; $i -lt $OrderedPaths.Count; $i++) {
        if (Test-PlaylistEntryMatchesResumeAnchor -PlaylistEntryFullPath $OrderedPaths[$i] -AnchorFullPath $AnchorFullPath) {
            $idx = $i
            break
        }
    }
    if ($idx -lt 0) { return [string[]]$OrderedPaths }
    if ($idx -eq 0) { return [string[]]$OrderedPaths }
    return [string[]]@($OrderedPaths[$idx..($OrderedPaths.Count - 1)] + $OrderedPaths[0..($idx - 1)])
}

function Get-AvsInFolder {
    param(
        [string] $Folder,
        [bool] $DoRecurse
    )
    $root = [System.IO.Path]::GetFullPath($Folder)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "AvsFolder not found or not a directory: $Folder"
    }
    if ($DoRecurse) {
        return @(Get-ChildItem -LiteralPath $root -Recurse -ErrorAction Stop |
            Where-Object { -not $_.PSIsContainer -and ($_.Extension -ieq '.avs') } |
            ForEach-Object { $_.FullName })
    }
    return @(Get-ChildItem -LiteralPath $root -ErrorAction Stop |
        Where-Object { -not $_.PSIsContainer -and ($_.Extension -ieq '.avs') } |
        ForEach-Object { $_.FullName })
}

function Test-PathUnderOrEqual {
    param(
        [string] $CandidateFullPath,
        [string] $RootFullPath
    )
    $c = [System.IO.Path]::GetFullPath($CandidateFullPath).TrimEnd('\', '/')
    $r = [System.IO.Path]::GetFullPath($RootFullPath).TrimEnd('\', '/')
    if ($c -eq $r) { return $true }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    return $c.StartsWith($r + $sep, [StringComparison]::OrdinalIgnoreCase)
}

function Test-AvsInWorkFolder {
    param(
        [string] $Path,
        [string] $WorkRoot
    )
    if (-not ($Path -like '*.avs')) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return (Test-PathUnderOrEqual -CandidateFullPath $Path -RootFullPath $WorkRoot)
}

function Get-FlatOrchestratorPathsFromCursor {
    <#
    .SYNOPSIS
      Continue forward from the cursor through the list tail only (no wrap to head).
      StartAt: include that item through end. After: items strictly after through end.
      If the cursor is missing from the live list, return the full list.
    #>
    param(
        [string[]] $OrderedPaths,
        [string] $AfterFullPath = '',
        [string] $StartAtFullPath = ''
    )
    if ($null -eq $OrderedPaths -or $OrderedPaths.Count -eq 0) { return [string[]]@() }
    $n = $OrderedPaths.Count
    if (-not [string]::IsNullOrWhiteSpace($StartAtFullPath)) {
        for ($i = 0; $i -lt $n; $i++) {
            if (Test-PlaylistEntryMatchesResumeAnchor -PlaylistEntryFullPath $OrderedPaths[$i] -AnchorFullPath $StartAtFullPath) {
                return [string[]]$OrderedPaths[$i..($n - 1)]
            }
        }
        return [string[]]$OrderedPaths
    }
    if (-not [string]::IsNullOrWhiteSpace($AfterFullPath)) {
        for ($i = 0; $i -lt $n; $i++) {
            if (Test-PlaylistEntryMatchesResumeAnchor -PlaylistEntryFullPath $OrderedPaths[$i] -AnchorFullPath $AfterFullPath) {
                if ($i + 1 -ge $n) { return [string[]]@() }
                return [string[]]$OrderedPaths[($i + 1)..($n - 1)]
            }
        }
        return [string[]]$OrderedPaths
    }
    return [string[]]$OrderedPaths
}

function Get-FlatOrchestratorLiveQueue {
    <#
    .SYNOPSIS
      Re-read playlist.m3u and scan .\avs. Continue after the current/last clip through the
      M3U tail only (new items appended to the playlist are picked up). No wrap to head.
      Orphans (on-disk .avs not in M3U) are used only when there is no active cursor.
    #>
    param(
        [string] $M3uPath,
        [string] $AvsFolderRoot,
        [bool] $DoRecurse,
        [System.Collections.Generic.HashSet[string]] $CompletedFullPaths,
        [string] $AfterFullPath = '',
        [string] $StartAtFullPath = ''
    )
    $diskAvs = @()
    try {
        $diskAvs = @(Get-AvsInFolder -Folder $AvsFolderRoot -DoRecurse:$DoRecurse |
            ForEach-Object { [System.IO.Path]::GetFullPath($_) })
    } catch {
        $diskAvs = @()
    }
    $diskAvailable = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $diskAvs) {
        if ($null -ne $CompletedFullPaths -and $CompletedFullPaths.Contains($a)) { continue }
        if (Test-Path -LiteralPath $a -PathType Leaf) {
            [void]$diskAvailable.Add($a)
        }
    }

    $m3uOrder = @()
    if (Test-Path -LiteralPath $M3uPath -PathType Leaf) {
        try {
            $m3uOrder = @(Read-M3uOrderedPaths -M3uPath $M3uPath)
        } catch {
            $m3uOrder = @()
        }
    }
    $m3uFromCursor = @(Get-FlatOrchestratorPathsFromCursor -OrderedPaths $m3uOrder `
        -AfterFullPath $AfterFullPath -StartAtFullPath $StartAtFullPath)

    $queue = [System.Collections.Generic.List[string]]::new()
    $inQueue = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $m3uFromCursor) {
        if (-not (Test-AvsInWorkFolder -Path $entry -WorkRoot $AvsFolderRoot)) { continue }
        $full = Get-FullPathOrNull -Path $entry
        if ([string]::IsNullOrWhiteSpace($full)) { continue }
        if ($null -ne $CompletedFullPaths -and $CompletedFullPaths.Contains($full)) { continue }
        if (-not $diskAvailable.Contains($full)) { continue }
        if ($inQueue.Add($full)) {
            [void]$queue.Add($full)
        }
    }

    $orphans = [System.Collections.Generic.List[string]]::new()
    $hasCursor = -not [string]::IsNullOrWhiteSpace($AfterFullPath) -or -not [string]::IsNullOrWhiteSpace($StartAtFullPath)
    if (-not $hasCursor) {
        foreach ($a in @($diskAvailable | Sort-Object)) {
            if ($inQueue.Contains($a)) { continue }
            [void]$orphans.Add($a)
        }
    }

    return @{
        Queue     = [string[]]$queue.ToArray()
        Orphans   = [string[]]$orphans.ToArray()
        DiskCount = $diskAvs.Count
        M3uCount  = $m3uOrder.Count
    }
}

function Wait-OrchestratorIdleOrEnterCancel {
    param(
        [int] $Seconds,
        [ref] $CancelledByEnter,
        [datetime] $DeadlineUtc,
        [ref] $TimedOutByBatch
    )
    $CancelledByEnter.Value = $false
    $TimedOutByBatch.Value = $false
    if ($Seconds -le 0) { return }
    $deadline = (Get-Date).AddSeconds($Seconds)
    Clear-PendingConsoleKeys
    while ((Get-Date) -lt $deadline) {
        if ($null -ne $DeadlineUtc -and $DeadlineUtc -gt [datetime]::MinValue -and (Get-Date).ToUniversalTime() -ge $DeadlineUtc) {
            $TimedOutByBatch.Value = $true
            return
        }
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq [ConsoleKey]::Enter) {
                $CancelledByEnter.Value = $true
                return
            }
        }
        Start-Sleep -Milliseconds 200
    }
}

function Get-HostPowerShellExe {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        return (Get-Command pwsh -ErrorAction Stop).Source
    }
    return (Get-Command powershell -ErrorAction Stop).Source
}

function Stop-TranscodeProcessTree {
    param([System.Diagnostics.Process] $Proc)
    if ($null -eq $Proc -or $Proc.HasExited) { return }
    try {
        & taskkill.exe /PID $Proc.Id /T /F 2>$null | Out-Null
    } catch {
        try { Stop-Process -Id $Proc.Id -Force -ErrorAction Stop } catch { }
    }
}

function Clear-PendingConsoleKeys {
    try {
        while ([Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
        }
    } catch {
        # Non-interactive host: ignore.
    }
}

function Wait-TranscodeOrEnter {
    param(
        [System.Diagnostics.Process] $Proc,
        [ref] $CancelledByEnter
    )
    while (-not $Proc.HasExited) {
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Spacebar) {
                    if (Get-Command Toggle-LeafFfmpegExportSuspend -ErrorAction SilentlyContinue) {
                        [void](Toggle-LeafFfmpegExportSuspend)
                    }
                } elseif ($key.Key -eq [ConsoleKey]::Enter) {
                    $CancelledByEnter.Value = $true
                    Write-Host ''
                    Write-Host 'Enter pressed - terminating transcode process tree...'
                    Stop-TranscodeProcessTree -Proc $Proc
                    return
                }
            }
        } catch {
            # Non-interactive host: only wait for process exit.
        }
        Start-Sleep -Milliseconds 200
    }
}

function Get-OrchestratorAvsDirectShowSourcePath {
    param([string] $AvsFullPath)
    if (-not (Test-Path -LiteralPath $AvsFullPath -PathType Leaf)) {
        return $null
    }
    try {
        $text = [IO.File]::ReadAllText($AvsFullPath)
        $match = [regex]::Match($text, 'DirectShowSource\s*\(\s*"([^"]+)"')
        if ($match.Success) {
            $path = $match.Groups[1].Value
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                return [System.IO.Path]::GetFullPath($path)
            }
        }
    } catch { }
    return $null
}

function Get-OrchestratorClipMediaPathForHeartbeat {
    param([string] $InputFullPath)
    if ([string]::IsNullOrWhiteSpace($InputFullPath)) { return '' }
    if ($InputFullPath.EndsWith('.avs', [StringComparison]::OrdinalIgnoreCase)) {
        $dss = Get-OrchestratorAvsDirectShowSourcePath -AvsFullPath $InputFullPath
        if (-not [string]::IsNullOrWhiteSpace($dss) -and (Test-Path -LiteralPath $dss -PathType Leaf)) {
            return $dss
        }
    }
    return $InputFullPath
}

function Resolve-OrchestratorChildWaitHeartbeatSeconds {
    param([string] $InputFullPath)
    if ($PrepareHeartbeatSec -gt 0) { return $PrepareHeartbeatSec }
    if ($PrepareHeartbeatDivisor -le 0) { return 0 }
    if (-not (Get-Command Resolve-PrepareWaitHeartbeatSeconds -ErrorAction SilentlyContinue)) {
        return 60
    }
    $mediaPath = Get-OrchestratorClipMediaPathForHeartbeat -InputFullPath $InputFullPath
    return Resolve-PrepareWaitHeartbeatSeconds -MediaFullPath $mediaPath `
        -FixedHeartbeatSec $PrepareHeartbeatSec -Divisor $PrepareHeartbeatDivisor
}

function Write-OrchestratorChildWaitHeartbeatPlan {
    param([string] $InputFullPath)
    $sec = Resolve-OrchestratorChildWaitHeartbeatSeconds -InputFullPath $InputFullPath
    if ($PrepareHeartbeatSec -gt 0) {
        Write-Host "Child wait heartbeat: ${sec}s (fixed)"
    } elseif ($PrepareHeartbeatDivisor -gt 0) {
        $mediaPath = Get-OrchestratorClipMediaPathForHeartbeat -InputFullPath $InputFullPath
        $durHint = if (Get-Command Get-PrepareMediaDurationSeconds -ErrorAction SilentlyContinue) {
            Get-PrepareMediaDurationSeconds -MediaFullPath $mediaPath
        } else { $null }
        $durNote = if ($null -ne $durHint -and $durHint -gt 0) {
            "~$([math]::Round($durHint))s source / $PrepareHeartbeatDivisor"
        } else { 'duration unknown; fallback 60s' }
        Write-Host "Child wait heartbeat: ${sec}s ($durNote)"
    } else {
        Write-Host 'Child wait heartbeat: disabled'
    }
    return $sec
}

function Wait-TranscodeOrEnterWithHeartbeat {
    param(
        [System.Diagnostics.Process] $Proc,
        [ref] $CancelledByEnter,
        [ref] $TimedOut,
        [string] $StdOutPath,
        [string] $StdErrPath,
        [datetime] $TimeoutAtUtc = [datetime]::MinValue,
        [int] $HeartbeatSeconds = 60
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $Proc.HasExited) {
        if ($TimeoutAtUtc -gt [datetime]::MinValue -and [DateTime]::UtcNow -ge $TimeoutAtUtc) {
            $TimedOut.Value = $true
            Write-Host ''
            Write-Warning "Orchestrator batch deadline reached (${BatchTimeoutSec}s). Terminating running child process tree..."
            Stop-TranscodeProcessTree -Proc $Proc
            return
        }
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Spacebar) {
                    if (Get-Command Toggle-LeafFfmpegExportSuspend -ErrorAction SilentlyContinue) {
                        [void](Toggle-LeafFfmpegExportSuspend)
                    }
                } elseif ($key.Key -eq [ConsoleKey]::Enter) {
                    $CancelledByEnter.Value = $true
                    Write-Host ''
                    Write-Host 'Enter pressed - terminating transcode process tree...'
                    Stop-TranscodeProcessTree -Proc $Proc
                    return
                }
            }
        } catch {
            # Non-interactive host: only wait for process exit.
        }
        if ($HeartbeatSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $HeartbeatSeconds) {
            $elapsedSec = [int][Math]::Floor($sw.Elapsed.TotalSeconds)
            $statusHint = if (-not [string]::IsNullOrWhiteSpace($StdOutPath) `
                    -and (Get-Command Get-PrepareLogStatusHint -ErrorAction SilentlyContinue)) {
                Get-PrepareLogStatusHint -StdOutPath $StdOutPath
            } else { '' }
            $statusNote = if ($statusHint) { " last: $statusHint" } else { '' }
            Write-Host "[wait] Child still running (${elapsedSec}s).$statusNote stdout: $StdOutPath"
            Write-Host "[wait] stderr: $StdErrPath (Space=pause/resume leaf DLNA export)"
            $sw.Restart()
        }
        Start-Sleep -Milliseconds 200
    }
}

function Resolve-PotPlayerExecutable {
    param([string] $ExplicitPath = '')
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($ExplicitPath)
        }
        Write-Warning "PotPlayerExe not found: $ExplicitPath"
        return $null
    }
    foreach ($exeName in @('PotPlayerMini64.exe', 'PotPlayerMini.exe', 'PotPlayer.exe')) {
        try {
            $cmd = Get-Command $exeName -ErrorAction SilentlyContinue
            if ($cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source) -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) {
                return $cmd.Source
            }
        } catch { }
    }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $dirs = @(
        [System.IO.Path]::Combine($env:ProgramFiles, 'DAUM', 'PotPlayer'),
        [System.IO.Path]::Combine($env:ProgramFiles, 'PotPlayer')
    )
    if (-not [string]::IsNullOrWhiteSpace($pf86)) {
        $dirs += @(
            [System.IO.Path]::Combine($pf86, 'DAUM', 'PotPlayer'),
            [System.IO.Path]::Combine($pf86, 'PotPlayer')
        )
    }
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($exeName in @('PotPlayerMini64.exe', 'PotPlayerMini.exe', 'PotPlayer.exe')) {
            $candidate = Join-Path $dir $exeName
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
        }
    }
    return $null
}

function Request-PotPlayerMainWindowFullscreenKick {
    param(
        [int] $ProcessId,
        [int] $TimeoutSec = 18
    )
    if ($ProcessId -le 0) { return }
    if (-not ('OrchestratorPotWin32' -as [type])) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class OrchestratorPotWin32 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
        } catch { }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $hwnd = [IntPtr]::Zero
    while ((Get-Date) -lt $deadline) {
        try {
            $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if ($null -eq $proc) {
                Start-Sleep -Milliseconds 300
                continue
            }
            $proc.Refresh()
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                $hwnd = $proc.MainWindowHandle
                break
            }
        } catch { }
        Start-Sleep -Milliseconds 300
    }
    if ($hwnd -eq [IntPtr]::Zero) {
        Write-Warning 'PotPlayer: main window not ready in time; Alt+Enter fullscreen kick skipped. Use F5 startup fullscreen or Alt+Enter manually.'
        return
    }
    try {
        if ('OrchestratorPotWin32' -as [type]) {
            [void][OrchestratorPotWin32]::ShowWindow($hwnd, 9)
            Start-Sleep -Milliseconds 150
            [void][OrchestratorPotWin32]::SetForegroundWindow($hwnd)
            Start-Sleep -Milliseconds 250
        }
        $wshell = New-Object -ComObject WScript.Shell
        $wshell.SendKeys('%({ENTER})')
        Write-Host 'PotPlayer: Alt+Enter sent for fullscreen (best effort).'
    } catch {
        Write-Warning "PotPlayer fullscreen kick failed: $_"
    }
}

function Get-OrchestratorPotPlayerRunningIds {
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($name in @('PotPlayerMini64', 'PotPlayerMini', 'PotPlayer')) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            if ($null -ne $p -and $p.Id -gt 0) {
                [void]$ids.Add($p.Id)
            }
        }
    }
    # Prevent PowerShell from unwrapping a 1-element HashSet into a bare [int].
    Write-Output -NoEnumerate $ids
}

function ConvertTo-OrchestratorPotPlayerIdSet {
    param($Ids)
    if ($null -eq $Ids) {
        return [System.Collections.Generic.HashSet[int]]::new()
    }
    if ($Ids -is [System.Collections.Generic.HashSet[int]]) {
        Write-Output -NoEnumerate $Ids
        return
    }
    if ($Ids -is [System.Array] -and $Ids.Length -eq 1) {
        ConvertTo-OrchestratorPotPlayerIdSet -Ids $Ids.GetValue(0)
        return
    }
    $set = [System.Collections.Generic.HashSet[int]]::new()
    if ($Ids -is [int] -or $Ids -is [long] -or $Ids -is [uint32]) {
        [void]$set.Add([int]$Ids)
        Write-Output -NoEnumerate $set
        return
    }
    foreach ($rawId in @($Ids)) {
        if ($null -eq $rawId) { continue }
        if ($rawId -is [System.Collections.Generic.HashSet[int]]) {
            foreach ($inner in $rawId) { [void]$set.Add([int]$inner) }
            continue
        }
        try { [void]$set.Add([int]$rawId) } catch { }
    }
    Write-Output -NoEnumerate $set
}

function Get-OrchestratorPotPlayerSessionRunningIds {
    param(
        [int] $StarterPid = 0,
        $BaselineIds = $null
    )
    $baseline = ConvertTo-OrchestratorPotPlayerIdSet -Ids $BaselineIds
    $session = [System.Collections.Generic.HashSet[int]]::new()
    $current = ConvertTo-OrchestratorPotPlayerIdSet -Ids (Get-OrchestratorPotPlayerRunningIds)
    if ($StarterPid -gt 0 -and $current.Contains([int]$StarterPid)) {
        [void]$session.Add([int]$StarterPid)
    }
    foreach ($id in $current) {
        if (-not $baseline.Contains([int]$id)) {
            [void]$session.Add([int]$id)
        }
    }
    Write-Output -NoEnumerate $session
}

function Test-OrchestratorPotPlayerAnyRunning {
    param(
        [int] $StarterPid = 0,
        $BaselineIds = $null
    )
    try {
        $session = ConvertTo-OrchestratorPotPlayerIdSet -Ids (
            Get-OrchestratorPotPlayerSessionRunningIds -StarterPid $StarterPid -BaselineIds $BaselineIds
        )
        return ($session.Count -gt 0)
    } catch {
        return $false
    }
}

function Wait-OrchestratorPotPlayerUserFinished {
    param(
        [int] $StarterPid,
        $BaselineIds = $null,
        [int] $StartupTimeoutSec = 180
    )
    $baseline = ConvertTo-OrchestratorPotPlayerIdSet -Ids $BaselineIds
    Write-Host 'Waiting for PotPlayer to close (exit PotPlayer when clip selection is done)...'
    Write-Host '  Exit PotPlayer: File > Exit (or triple-left-click if TripleL companion is running).'
    if ($baseline.Count -gt 0) {
        Write-Host ("  Ignoring {0} pre-existing PotPlayer pid(s): {1}" -f `
            $baseline.Count, ((@($baseline) | Sort-Object) -join ', '))
    }
    $startupDeadline = (Get-Date).AddSeconds($StartupTimeoutSec)
    $sessionSeen = $false
    $lastStatusAt = [datetime]::MinValue
    while ($true) {
        $sessionIds = ConvertTo-OrchestratorPotPlayerIdSet -Ids (
            Get-OrchestratorPotPlayerSessionRunningIds -StarterPid $StarterPid -BaselineIds $baseline
        )
        $running = $sessionIds.Count -gt 0
        if (-not $sessionSeen) {
            if ($running) {
                $sessionSeen = $true
                Write-Host ("PotPlayer session detected (pid {0}); waiting for you to exit PotPlayer..." -f `
                    ((@($sessionIds) | Sort-Object) -join ', '))
            } elseif ((Get-Date) -gt $startupDeadline) {
                throw "PotPlayer did not start within ${StartupTimeoutSec}s; start-clip gate aborted."
            }
        } elseif (-not $running) {
            Write-Host 'PotPlayer closed; continuing.'
            return
        } elseif (((Get-Date) - $lastStatusAt).TotalSeconds -ge 30) {
            $lastStatusAt = Get-Date
            Write-Host ("Still waiting for gate PotPlayer to exit (pid {0})..." -f `
                ((@($sessionIds) | Sort-Object) -join ', '))
        }
        Start-Sleep -Milliseconds 400
    }
}

function Invoke-OrchestratorPotPlayerDplGate {
    param(
        [string] $DplFullPath,
        [switch] $DryRun,
        [switch] $Skip,
        [string] $PotPlayerExePath = ''
    )
    if ($Skip) {
        Write-Host 'Skipping PotPlayer DPL gate (-SkipPotPlayer).'
        return
    }
    if ([string]::IsNullOrWhiteSpace($DplFullPath) -or -not (Test-Path -LiteralPath $DplFullPath -PathType Leaf)) {
        Write-Host "PotPlayer DPL gate skipped (DPL not found): $DplFullPath"
        return
    }
    if ($DryRun) {
        Write-Host "DryRun: PotPlayer DPL gate would launch: $DplFullPath (then Alt+Enter fullscreen kick when window appears)"
        return
    }
    $exe = Resolve-PotPlayerExecutable -ExplicitPath $PotPlayerExePath
    if ([string]::IsNullOrWhiteSpace($exe)) {
        Write-Warning 'PotPlayer executable not found; skipping PotPlayer DPL gate. Install PotPlayer, add to PATH, or pass -PotPlayerExe.'
        return
    }
    Write-Host "PotPlayer DPL gate: starting `"$exe`" with DPL (fullscreen via Alt+Enter when main window appears):"
    Write-Host "  $DplFullPath"
    Write-Host 'Close PotPlayer when finished - orchestrator continues after PotPlayer closes, then 2s for DPL to settle.'
    $baselineIds = ConvertTo-OrchestratorPotPlayerIdSet -Ids (Get-OrchestratorPotPlayerRunningIds)
    if ($baselineIds.Count -gt 0) {
        Write-Warning ("Pre-existing PotPlayer still running (pid {0}); gate wait will ignore it and only track this launch." -f `
            ((@($baselineIds) | Sort-Object) -join ', '))
    }
    $pp = Start-Process -FilePath $exe -ArgumentList @($DplFullPath) -PassThru
    if ($null -eq $pp) {
        throw 'Start-Process did not return a PotPlayer process object.'
    }
    $starterPid = 0
    try { $starterPid = [int]$pp.Id } catch { $starterPid = 0 }
    Request-PotPlayerMainWindowFullscreenKick -ProcessId $starterPid
    Wait-OrchestratorPotPlayerUserFinished -StarterPid $starterPid -BaselineIds $baselineIds
    Write-Host 'Sleeping 2 seconds for DPL file (playname/playtime) to update...'
    Start-Sleep -Seconds 2
    Write-Host 'PotPlayer gate complete; continuing queue / resume logic.'
}

$script:OrchestratorCompanionJobHandle = [IntPtr]::Zero

function Ensure-OrchestratorCompanionJobNativeType {
    if ('OrchestratorCompanionJobNative' -as [type]) { return }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OrchestratorCompanionJobNative {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool SetInformationJobObject(IntPtr hJob, int jobObjectInfoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInformation, uint cbJobObjectInformationLength);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool CloseHandle(IntPtr hObject);
  public const int JobObjectExtendedLimitInformation = 9;
  public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public Int64 PerProcessUserTimeLimit;
    public Int64 PerJobUserTimeLimit;
    public UInt32 LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public UInt32 ActiveProcessLimit;
    public UIntPtr Affinity;
    public UInt32 PriorityClass;
    public UInt32 SchedulingClass;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct IO_COUNTERS {
    public UInt64 ReadOperationCount, WriteOperationCount, OtherOperationCount;
    public UInt64 ReadTransferCount, WriteTransferCount, OtherTransferCount;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
  }
  public static bool TryCreateKillOnCloseJob(out IntPtr jobHandle) {
    jobHandle = IntPtr.Zero;
    IntPtr h = CreateJobObject(IntPtr.Zero, null);
    if (h == IntPtr.Zero) return false;
    var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    uint cb = (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    if (!SetInformationJobObject(h, JobObjectExtendedLimitInformation, ref info, cb)) {
      CloseHandle(h);
      return false;
    }
    jobHandle = h;
    return true;
  }
}
'@
    } catch {
        Write-Warning "Orchestrator companion job API unavailable: $_"
    }
}

function Initialize-OrchestratorCompanionKillOnCloseJob {
    Ensure-OrchestratorCompanionJobNativeType
    if ($script:OrchestratorCompanionJobHandle -ne [IntPtr]::Zero) { return }
    if ($null -eq ('OrchestratorCompanionJobNative' -as [type])) { return }
    [IntPtr]$jh = [IntPtr]::Zero
    $ok = [OrchestratorCompanionJobNative]::TryCreateKillOnCloseJob([ref]$jh)
    if (-not $ok -or $jh -eq [IntPtr]::Zero) {
        Write-Warning 'Could not create Kill-On-Close job for companions; closing the console may leave AutoHotkey processes running.'
        return
    }
    $script:OrchestratorCompanionJobHandle = $jh
}

function Register-OrchestratorCompanionProcessInKillJob {
    param([System.Diagnostics.Process] $Process)
    if ($null -eq $Process -or $Process.Id -le 0) { return }
    if ($script:OrchestratorCompanionJobHandle -eq [IntPtr]::Zero) { return }
    if ($null -eq ('OrchestratorCompanionJobNative' -as [type])) { return }
    try {
        $h = $Process.Handle
        $ok = [OrchestratorCompanionJobNative]::AssignProcessToJobObject($script:OrchestratorCompanionJobHandle, $h)
        if (-not $ok) {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-Warning "AssignProcessToJobObject failed for companion PID $($Process.Id) (Win32 $err); taskkill in finally still applies."
        }
    } catch {
        Write-Warning "Could not assign companion PID $($Process.Id) to Kill-On-Close job: $_"
    }
}

function Close-OrchestratorCompanionKillOnCloseJob {
    if ($script:OrchestratorCompanionJobHandle -eq [IntPtr]::Zero) { return }
    try {
        if ($null -ne ('OrchestratorCompanionJobNative' -as [type])) {
            [void][OrchestratorCompanionJobNative]::CloseHandle($script:OrchestratorCompanionJobHandle)
        }
    } catch { }
    $script:OrchestratorCompanionJobHandle = [IntPtr]::Zero
}

$script:OrchestratorCompanionRootPids = [System.Collections.Generic.List[int]]::new()
$script:OrchestratorCompanionsStopped = $false

function Stop-OrchestratorCompanionProcessTree {
    param([int] $PidToKill)
    if ($PidToKill -le 0) { return }
    try {
        & taskkill.exe /PID $PidToKill /T /F 2>$null | Out-Null
    } catch {
        try { Stop-Process -Id $PidToKill -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Stop-OrchestratorCompanionBinaries {
    if ($script:OrchestratorCompanionsStopped) { return }
    $script:OrchestratorCompanionsStopped = $true
    try {
        if ($null -ne $script:OrchestratorCompanionRootPids -and $script:OrchestratorCompanionRootPids.Count -gt 0) {
            Write-Host "Stopping $($script:OrchestratorCompanionRootPids.Count) orchestrator companion process tree(s)..."
            $distinct = @($script:OrchestratorCompanionRootPids | Sort-Object -Unique -Descending)
            foreach ($cid in $distinct) {
                try {
                    Stop-OrchestratorCompanionProcessTree -PidToKill $cid
                } catch { }
            }
        }
    } finally {
        if ($null -ne $script:OrchestratorCompanionRootPids) {
            [void]$script:OrchestratorCompanionRootPids.Clear()
        }
        Close-OrchestratorCompanionKillOnCloseJob
    }
}

function Start-OrchestratorCompanionBinaries {
    param(
        [string] $FolderPath,
        [switch] $Skip,
        [switch] $DryRun
    )
    $script:OrchestratorCompanionsStopped = $false
    if ($script:OrchestratorCompanionRootPids) {
        [void]$script:OrchestratorCompanionRootPids.Clear()
    } else {
        $script:OrchestratorCompanionRootPids = [System.Collections.Generic.List[int]]::new()
    }
    if ($Skip) {
        Write-Host 'Skipping companion binaries (-SkipCompanionBinaries).'
        return
    }
    if ($DryRun) {
        Write-Host 'DryRun: skipping companion binary launch.'
        return
    }
    if ([string]::IsNullOrWhiteSpace($FolderPath) -or -not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        Write-Host "Companion binary folder missing; skipping launch: $FolderPath"
        return
    }
    $exes = @(Get-ChildItem -LiteralPath $FolderPath -File -Filter '*.exe' -ErrorAction SilentlyContinue | Sort-Object { $_.Name })
    if ($exes.Count -eq 0) {
        Write-Host "No *.exe files in companion folder: $FolderPath"
        return
    }
    Write-Host "Starting $($exes.Count) companion executable(s) from: $FolderPath"
    Initialize-OrchestratorCompanionKillOnCloseJob
    foreach ($exeFile in $exes) {
        try {
            Write-Host "  -> $($exeFile.Name)"
            $pp = Start-Process -FilePath $exeFile.FullName -WorkingDirectory $FolderPath -PassThru -WindowStyle Normal
            if ($null -ne $pp -and $pp.Id -gt 0) {
                Register-OrchestratorCompanionProcessInKillJob -Process $pp
                [void]$script:OrchestratorCompanionRootPids.Add($pp.Id)
            }
        } catch {
            Write-Warning "Could not start companion '$($exeFile.FullName)': $_"
        }
    }
}

# --- main ---
$orchestratorRoot = $null
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $orchestratorRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
} elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    $orchestratorRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($PSCommandPath))
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    $orchestratorRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path))
}
if ([string]::IsNullOrWhiteSpace($orchestratorRoot)) {
    Write-Error "Cannot resolve this script's directory (PSScriptRoot empty). Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit 2
}
Set-Location -LiteralPath $orchestratorRoot

$prepareHeartbeatScript = Join-Path $orchestratorRoot 'individual_transcode\Get-FisheyePrepareHeartbeat.ps1'
if (-not (Test-Path -LiteralPath $prepareHeartbeatScript -PathType Leaf)) {
    $parentHeartbeat = Join-Path ([System.IO.Path]::GetDirectoryName($orchestratorRoot)) 'individual_transcode\Get-FisheyePrepareHeartbeat.ps1'
    if (Test-Path -LiteralPath $parentHeartbeat -PathType Leaf) {
        $prepareHeartbeatScript = $parentHeartbeat
    }
}
if (Test-Path -LiteralPath $prepareHeartbeatScript -PathType Leaf) {
    . $prepareHeartbeatScript
} else {
    Write-Warning "Get-FisheyePrepareHeartbeat.ps1 not found; child wait heartbeat uses 60s fallback."
}
$leafFfmpegControlScript = Join-Path $orchestratorRoot 'individual_transcode\Invoke-LeafFfmpegControl.ps1'
if (Test-Path -LiteralPath $leafFfmpegControlScript -PathType Leaf) {
    . $leafFfmpegControlScript
}
if (Get-Command Ensure-DlnaSegmentRoot -ErrorAction SilentlyContinue) {
    [void](Ensure-DlnaSegmentRoot -Force)
}

$orchestratorStartUtc = Get-OrchestratorStartTimeUtc
$orchestratorDeadlineUtcIso = Get-BatchDeadlineUtcIso -StartUtcIso $orchestratorStartUtc -TimeoutSec $BatchTimeoutSec
$orchestratorDeadlineUtc = if ([string]::IsNullOrWhiteSpace($orchestratorDeadlineUtcIso)) {
    [datetime]::MinValue
} else {
    Convert-BatchUtcIsoToDateTime -UtcIso $orchestratorDeadlineUtcIso
}

if ([string]::IsNullOrWhiteSpace($AvsFolder)) {
    $AvsFolder = '.\avs'
}
if ([string]::IsNullOrWhiteSpace($PlaylistFile)) {
    $PlaylistFile = Join-Path $orchestratorRoot 'playlist.m3u'
}
$PlaylistFile = [System.IO.Path]::GetFullPath($PlaylistFile)
$TranscodeScript = Resolve-TranscodeScriptPath -OrchestratorRoot $orchestratorRoot -Explicit $TranscodeScript
if ([System.IO.Path]::IsPathRooted($AvsFolder)) {
    $AvsFolderRoot = [System.IO.Path]::GetFullPath($AvsFolder)
} else {
    $AvsFolderRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($orchestratorRoot, $AvsFolder))
}
if (-not (Test-Path -LiteralPath $AvsFolderRoot -PathType Container)) {
    New-Item -ItemType Directory -LiteralPath $AvsFolderRoot -Force | Out-Null
    Write-Host "Created avs folder: $AvsFolderRoot"
}

$purgeAvsScript = Join-Path $orchestratorRoot 'Purge-OldAvs.ps1'
if (Test-Path -LiteralPath $purgeAvsScript -PathType Leaf) {
    & $purgeAvsScript -AvsFolder $AvsFolderRoot -KeepCount 50
} else {
    Write-Warning "Purge-OldAvs.ps1 not found: $purgeAvsScript"
}

$playlistDir = [System.IO.Path]::GetDirectoryName($PlaylistFile)
$playlistStem = [System.IO.Path]::GetFileNameWithoutExtension($PlaylistFile)
$dplPreferredPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($playlistDir, $playlistStem + '_potplayer.dpl'))
$dplLegacyPath = [System.IO.Path]::GetFullPath([System.IO.Path]::ChangeExtension($PlaylistFile, '.dpl'))
$dplPath = $dplPreferredPath
if (-not (Test-Path -LiteralPath $dplPath -PathType Leaf) -and (Test-Path -LiteralPath $dplLegacyPath -PathType Leaf)) {
    $dplPath = $dplLegacyPath
}
$dplProgressSidecar = "$dplPath.transcode_queue_last"
$progressSidecars = @($dplProgressSidecar)
$orchestratorMutex = $null
$ownsOrchestratorMutex = $false
$orchestratorMutexName = Get-OrchestratorMutexName -PlaylistFullPath $PlaylistFile
try {
    $orchestratorMutex = New-Object System.Threading.Mutex($false, $orchestratorMutexName)
    try {
        $ownsOrchestratorMutex = $orchestratorMutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $ownsOrchestratorMutex = $true
    }
    if (-not $ownsOrchestratorMutex) {
        Write-Warning "Another orchestrator is already running for this playlist. Mutex: $orchestratorMutexName"
        exit 3
    }
} catch {
    Write-Warning "Could not acquire orchestrator mutex; continuing without per-playlist lock: $_"
}

$allAvs = @(Get-AvsInFolder -Folder $AvsFolderRoot -DoRecurse:($Recurse.IsPresent))
if ($allAvs.Count -eq 0) {
    Write-Host "No .avs files under: $AvsFolderRoot"
    if ($orchestratorMutex -and $ownsOrchestratorMutex) { [void]$orchestratorMutex.ReleaseMutex() }
    if ($orchestratorMutex) { $orchestratorMutex.Dispose() }
    exit 0
}

$companionFolderResolved = if (-not [string]::IsNullOrWhiteSpace($CompanionBinaryFolder)) {
    [System.IO.Path]::GetFullPath($CompanionBinaryFolder)
} else {
    ''
}
Start-OrchestratorCompanionBinaries -FolderPath $companionFolderResolved `
    -Skip:$SkipCompanionBinaries.IsPresent -DryRun:$DryRun.IsPresent

$orchestratorExitCode = 0
$orchestratorHadChildFailure = $false
try {
Write-Host "Batch timeout: ${BatchTimeoutSec}s for entire queue (passes -TranscodeTimeoutSec -1 to each child; same as fisheye batch)"
if ($BatchTimeoutSec -gt 0 -and $null -ne $orchestratorDeadlineUtc) {
    Write-Host "Orchestrator deadline (UTC): $orchestratorDeadlineUtcIso (~$(Get-BatchRemainingSeconds -DeadlineUtc $orchestratorDeadlineUtc)s remaining)"
}
if ($PrepareHeartbeatSec -gt 0) {
    Write-Host "Child wait heartbeat: fixed ${PrepareHeartbeatSec}s per clip (-PrepareHeartbeatSec)"
} elseif ($PrepareHeartbeatDivisor -gt 0) {
    Write-Host "Child wait heartbeat: source_duration/${PrepareHeartbeatDivisor}s per clip (ffprobe; fallback 60s if unknown)"
} else {
    Write-Host 'Child wait heartbeat: disabled'
}
$completedThisRun = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$m3uOrderRaw = @(Read-M3uOrderedPaths -M3uPath $PlaylistFile)

Invoke-OrchestratorPotPlayerDplGate -DplFullPath $dplPath -DryRun:($DryRun.IsPresent) -Skip:($SkipPotPlayer.IsPresent) -PotPlayerExePath $PotPlayerExe

$anchorPath = ''
$anchorMode = ''
$queueStartAt = ''
$lastSuccessfulFull = ''
$dplSeekMs = $null
$dplSeekApplied = $false
$dplState = Read-DplPlaybackState -DplPath $dplPath
$dplEntryStartMsByFull = Read-DplEntryStartTimesMs -DplPath $dplPath -PlaylistDir $playlistDir
$dplEntryStartCount = if ($null -ne $dplEntryStartMsByFull) { $dplEntryStartMsByFull.Count } else { 0 }
if ($dplEntryStartCount -gt 0) {
    Write-Host "DPL per-entry *start* seek map loaded: $dplEntryStartCount item(s)"
}
$dplSeekPlayFull = ''
if ($null -ne $dplState -and -not [string]::IsNullOrWhiteSpace($dplState.PlayName)) {
    $resolvedSeek = Resolve-M3uMediaEntry -PlaylistDir $playlistDir -Entry $dplState.PlayName
    if (-not [string]::IsNullOrWhiteSpace($resolvedSeek)) {
        $dplSeekPlayFull = [System.IO.Path]::GetFullPath($resolvedSeek)
    }
}
if ($null -ne $dplState -and $null -ne $dplState.PlayTimeMs -and $dplState.PlayTimeMs -ge 0) {
    $dplSeekMs = [int64]$dplState.PlayTimeMs
    Write-Host "DPL playtime (ms) to prefer over registry for matching child launch: $dplSeekMs"
}
if (-not [string]::IsNullOrWhiteSpace($ResumePlaylistAfter)) {
    $anchorPath = [System.IO.Path]::GetFullPath($ResumePlaylistAfter)
    $anchorMode = 'after'
    Write-Host "Last processed (parameter): $anchorPath"
} else {
    if ($null -ne $dplState -and -not [string]::IsNullOrWhiteSpace($dplState.PlayName)) {
        $fromDpl = Resolve-M3uMediaEntry -PlaylistDir $playlistDir -Entry $dplState.PlayName
        if (-not [string]::IsNullOrWhiteSpace($fromDpl)) {
            $anchorPath = [System.IO.Path]::GetFullPath($fromDpl)
            $anchorMode = 'at'
            Write-Host "Last processed (PotPlayer DPL playname): $anchorPath"
        }
    }
    if ([string]::IsNullOrWhiteSpace($anchorPath)) {
        $fromDplSidecar = Read-AnchorPathFromSidecar -SidecarPath $dplProgressSidecar
        if (-not [string]::IsNullOrWhiteSpace($fromDplSidecar)) {
            $anchorPath = [System.IO.Path]::GetFullPath($fromDplSidecar)
            $anchorMode = 'after'
            Write-Host "Last processed ($dplProgressSidecar): $anchorPath"
        }
    }
}
$nonHandoverDplPlaytimeBackoffMs = if ([string]::IsNullOrWhiteSpace($ResumePlaylistAfter)) { 30000L } else { 0L }
if ($nonHandoverDplPlaytimeBackoffMs -gt 0) {
    Write-Host "Non-handover DPL playtime backoff active: -$nonHandoverDplPlaytimeBackoffMs ms"
}

if (-not [string]::IsNullOrWhiteSpace($anchorPath)) {
    $foundInM3u = $false
    foreach ($mp in $m3uOrderRaw) {
        if (Test-PlaylistEntryMatchesResumeAnchor -PlaylistEntryFullPath $mp -AnchorFullPath $anchorPath) {
            $foundInM3u = $true
            break
        }
    }
    if ($anchorMode -eq 'at') {
        $queueStartAt = $anchorPath
        if ($foundInM3u) {
            Write-Host 'Playlist traversal will start at that anchor through the live tail (no wrap).'
        }
    } else {
        [void]$completedThisRun.Add($anchorPath)
        $lastSuccessfulFull = $anchorPath
        if ($foundInM3u) {
            Write-Host 'Playlist traversal will continue after that anchor through the live tail (no wrap).'
        }
    }
    if (-not $foundInM3u) {
        Write-Warning "Anchor path not found in M3U media lines at gate; live refresh will use current playlist.m3u order."
    }
}
$shellExe = Get-HostPowerShellExe
$workDir = [System.IO.Path]::GetDirectoryName($TranscodeScript)
$transcodeFailureLogPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($workDir, 'transcode_logs\transcode_failures.log'))

Write-Host "Orchestrator: $PSCommandPath"
Write-Host "Playlist:   $PlaylistFile"
Write-Host "Avs folder: $AvsFolderRoot ($($allAvs.Count) file(s) at start)"
Write-Host "Queue:      continues after current through live tail; empty tail resets cursor to oldest"
Write-Host "Transcode:  $TranscodeScript"
Write-Host "Failure log: $transcodeFailureLogPath"
if (Initialize-OrchestratorFailureLog -FailureLogPath $transcodeFailureLogPath) {
    Write-Host "Failure log ready: $transcodeFailureLogPath"
}
Write-Host 'Press Space during a transcode to pause/resume DLNA export ffmpeg (3d_op_*.mkv). Enter cancels and exits.'
Write-Host ''

$cancelled = $false
$timedOutByLimit = $false
$clipOrdinal = 0
$emptyTailStreak = 0

while (-not $cancelled) {
    if (Stop-OrchestratorForBatchDeadline -DeadlineUtc $orchestratorDeadlineUtc `
            -TimedOutByLimit ([ref]$timedOutByLimit) -Cancelled ([ref]$cancelled)) {
        break
    }

    $startAt = ''
    $after = $lastSuccessfulFull
    if ([string]::IsNullOrWhiteSpace($after) -and -not [string]::IsNullOrWhiteSpace($queueStartAt)) {
        $startAt = $queueStartAt
    }
    $live = Get-FlatOrchestratorLiveQueue -M3uPath $PlaylistFile -AvsFolderRoot $AvsFolderRoot `
        -DoRecurse:($Recurse.IsPresent) -CompletedFullPaths $completedThisRun `
        -AfterFullPath $after -StartAtFullPath $startAt

    $full = $null
    $fromOrphan = $false
    if ($live.Queue.Count -gt 0) {
        $full = $live.Queue[0]
    } elseif ($live.Orphans.Count -gt 0) {
        $full = $live.Orphans[0]
        $fromOrphan = $true
    } else {
        $hadCursor = -not [string]::IsNullOrWhiteSpace($after) -or -not [string]::IsNullOrWhiteSpace($startAt)
        if ($hadCursor) {
            Write-Host ("Live tail empty (m3u={0} disk_avs={1} completed={2}); resetting cursor to oldest live item." -f `
                $live.M3uCount, $live.DiskCount, $completedThisRun.Count)
            $lastSuccessfulFull = ''
            $queueStartAt = ''
            $emptyTailStreak = 0
            continue
        }
        $idlePoll = [Math]::Max(5, [int]$LiveQueueIdlePollSec)
        $emptyTailStreak++
        if ($emptyTailStreak -gt 1) {
            Write-Host ("No new items after cursor reset + idle wait (m3u={0} disk_avs={1} completed={2}). Finishing." -f `
                $live.M3uCount, $live.DiskCount, $completedThisRun.Count)
            break
        }
        Write-Host ("Live list empty after cursor reset (m3u={0} disk_avs={1} completed={2}); waiting up to {3}s for new items..." -f `
            $live.M3uCount, $live.DiskCount, $completedThisRun.Count, $idlePoll)
        $enterCancel = $false
        $idleTimedOut = $false
        Wait-OrchestratorIdleOrEnterCancel -Seconds $idlePoll -CancelledByEnter ([ref]$enterCancel) `
            -DeadlineUtc $orchestratorDeadlineUtc -TimedOutByBatch ([ref]$idleTimedOut)
        if ($idleTimedOut) {
            $timedOutByLimit = $true
            $cancelled = $true
            break
        }
        if ($enterCancel) {
            if (-not [string]::IsNullOrWhiteSpace($lastSuccessfulFull)) {
                Write-TranscodeProgressSidecars -SidecarPaths $progressSidecars -CompletedAvsFullPath $lastSuccessfulFull
                Write-Host "Saved last processed on cancel: $lastSuccessfulFull"
            }
            $cancelled = $true
            break
        }
        continue
    }
    $emptyTailStreak = 0

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Write-Warning "[Missing] $full (refreshing live queue; not counted as failure)"
        [void]$completedThisRun.Add($full)
        continue
    }

    $clipOrdinal++
    $remainHint = $live.Queue.Count + $live.Orphans.Count
    $tag = if ($fromOrphan) { 'extra' } else { 'live' }
    Write-Host ("[{0} #{1}] {2} left -> {3}" -f $tag, $clipOrdinal, $remainHint, $full)

    if ($DryRun) {
        [void]$completedThisRun.Add($full)
        continue
    }

    $childSsMsOverride = $null
    $isNonHandover = [string]::IsNullOrWhiteSpace($ResumePlaylistAfter)
    if ($isNonHandover -and -not $dplSeekApplied -and $null -ne $dplSeekMs -and $dplSeekMs -ge 0) {
        $adjDplSeekMs = Get-AdjustedSeekMsForScenario -SeekMs $dplSeekMs -BackoffMs $nonHandoverDplPlaytimeBackoffMs
        $childSsMsOverride = $adjDplSeekMs
        $dplSeekApplied = $true
        Write-Host "Applying DPL playtime override for this child launch: raw=$dplSeekMs ms adjusted=$adjDplSeekMs ms"
    } else {
        $dplEntrySeekMs = $null
        if ($null -ne $dplEntryStartMsByFull -and $dplEntryStartMsByFull.ContainsKey($full)) {
            $dplEntrySeekMs = [int64]$dplEntryStartMsByFull[$full]
        }
        if ($null -ne $dplEntrySeekMs -and $dplEntrySeekMs -ge 0) {
            $childSsMsOverride = $dplEntrySeekMs
            Write-Host "Applying DPL *start* override for this child launch: $dplEntrySeekMs ms"
        } elseif (-not $isNonHandover -and $null -eq $dplEntrySeekMs) {
            # Handover: do not apply DPL playtime; fallback is registry in child.
        } elseif (-not $dplSeekApplied -and $null -ne $dplSeekMs -and $dplSeekMs -ge 0) {
            $useDplSeek = $false
            if ([string]::IsNullOrWhiteSpace($dplSeekPlayFull)) {
                $useDplSeek = $true
            } elseif (Test-PlaylistEntryMatchesResumeAnchor -PlaylistEntryFullPath $full -AnchorFullPath $dplSeekPlayFull) {
                $useDplSeek = $true
            }
            if ($useDplSeek) {
                $childSsMsOverride = $dplSeekMs
                $dplSeekApplied = $true
                Write-Host "Applying DPL playtime override for this child launch: $dplSeekMs ms"
            }
        }
    }
    $childSegmentSuffix = if ($Fisheye.IsPresent) { 'LR_180_FISHEYE' } else { 'Full_SBS' }
    $childSegmentDir = if (Get-Command Get-DlnaSegmentOutputDirectory -ErrorAction SilentlyContinue) {
        Get-DlnaSegmentOutputDirectory -Kind $(if ($Fisheye.IsPresent) { 'fisheye' } else { 'flat' })
    } else {
        Join-Path 'F:\f1_media\3d_fullsbs_trans' $(if ($Fisheye.IsPresent) { 'fisheye' } else { 'flat' })
    }
    $argList = New-TranscodeChildPowerShellArgs -TranscodeScript $TranscodeScript -InputPath $full `
        -OrchestratorPid $PID -OrchestratorStartTimeUtc $orchestratorStartUtc -Fisheye:$Fisheye.IsPresent `
        -WorkflowDeadlineUtc $orchestratorDeadlineUtcIso -SsMsOverride $childSsMsOverride `
        -SegmentNameSuffix $childSegmentSuffix -OutputDirectory $childSegmentDir
    Write-Host "DLNA segments: $childSegmentDir\3d_op_%02d_${childSegmentSuffix}.mkv"
    $childLogs = New-ChildProcessLogPaths -TranscodeScriptPath $TranscodeScript -InputPath $full
    $p = Start-Process -FilePath $shellExe -ArgumentList $argList -WorkingDirectory $workDir `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $childLogs.StdOut -RedirectStandardError $childLogs.StdErr

    Clear-PendingConsoleKeys
    $enterCancel = $false
    $timedOut = $false
    $clipHeartbeatSec = Write-OrchestratorChildWaitHeartbeatPlan -InputFullPath $full
    Wait-TranscodeOrEnterWithHeartbeat -Proc $p -CancelledByEnter ([ref]$enterCancel) `
        -TimedOut ([ref]$timedOut) -StdOutPath $childLogs.StdOut -StdErrPath $childLogs.StdErr `
        -TimeoutAtUtc $orchestratorDeadlineUtc -HeartbeatSeconds $clipHeartbeatSec

    if ($enterCancel) {
        if (-not [string]::IsNullOrWhiteSpace($lastSuccessfulFull)) {
            Write-TranscodeProgressSidecars -SidecarPaths $progressSidecars -CompletedAvsFullPath $lastSuccessfulFull
            Write-Host "Saved last processed on cancel: $lastSuccessfulFull"
        }
        $cancelled = $true
        break
    }
    if ($timedOut) {
        if (-not [string]::IsNullOrWhiteSpace($lastSuccessfulFull)) {
            Write-TranscodeProgressSidecars -SidecarPaths $progressSidecars -CompletedAvsFullPath $lastSuccessfulFull
            Write-Host "Saved last processed on timeout: $lastSuccessfulFull"
        }
        $timedOutByLimit = $true
        $cancelled = $true
        break
    }

    $childExitCode = Get-NormalizedChildExitCode -RawExitCode $p.ExitCode
    if ($childExitCode -eq 130) {
        if (-not [string]::IsNullOrWhiteSpace($lastSuccessfulFull)) {
            Write-TranscodeProgressSidecars -SidecarPaths $progressSidecars -CompletedAvsFullPath $lastSuccessfulFull
            Write-Host "Saved last processed on cancel: $lastSuccessfulFull"
        }
        Write-Warning "Child transcode cancelled (exit 130). Stopping orchestrator; next run will retry: $full"
        $cancelled = $true
        break
    }
    if ($childExitCode -ne 0) {
        Write-Warning "Transcode exit code $childExitCode$(Get-ChildTranscodeExitWarningSuffix -ExitCode $childExitCode) for: $full"
        Write-Host "See failure summary log: $transcodeFailureLogPath (written when child uses -NoLogFile)."
        Write-Host "Child stdout: $($childLogs.StdOut)"
        Write-Host "Child stderr: $($childLogs.StdErr)"
        $failPhase = if ($fromOrphan) { 'extra-pass' } else { 'playlist-pass' }
        Write-OrchestratorFailureSummary -FailureLogPath $transcodeFailureLogPath -InputPath $full -ExitCode $childExitCode -Phase $failPhase
        $orchestratorHadChildFailure = $true
    } else {
        Write-TranscodeProgressSidecars -SidecarPaths $progressSidecars -CompletedAvsFullPath $full
        $lastSuccessfulFull = $full
    }

    [void]$completedThisRun.Add($full)

    $peek = Get-FlatOrchestratorLiveQueue -M3uPath $PlaylistFile -AvsFolderRoot $AvsFolderRoot `
        -DoRecurse:($Recurse.IsPresent) -CompletedFullPaths $completedThisRun `
        -AfterFullPath $lastSuccessfulFull -StartAtFullPath ''
    $peekNext = if ($peek.Queue.Count -gt 0) { $peek.Queue[0] } elseif ($peek.Orphans.Count -gt 0) { $peek.Orphans[0] } else { $null }
    $peekRemain = $peek.Queue.Count + $peek.Orphans.Count
    if (-not [string]::IsNullOrWhiteSpace($peekNext)) {
        Write-Host "Next in live queue: $peekNext ($peekRemain remaining)"
    } else {
        Write-Host 'Next in live queue: (none)'
    }
}

if ($cancelled) {
    if ($timedOutByLimit) {
        Write-Warning "Orchestrator batch timed out after ${BatchTimeoutSec}s (batch deadline exceeded)."
        $orchestratorExitCode = $script:ExitCodeTimeout
    } else {
        Write-Host 'Orchestrator stopped by user (Enter).'
        $orchestratorExitCode = 130
    }
} else {
Write-Host ''
Write-Host 'Orchestrator finished (live playlist/disk queue empty).'

if (-not $DryRun) {
    Remove-TranscodeProgressSidecars -SidecarPaths $progressSidecars
}
$orchestratorExitCode = 0
}

} finally {
    Stop-OrchestratorCompanionBinaries
    if (-not $DryRun -and (Get-Command Invoke-DlnaWorkflowQuitCleanup -ErrorAction SilentlyContinue)) {
        # Keep logs only for real errors. Timeout (124) and user cancel (130) purge DLNA-root logs.
        $isTimeoutOrCancel = ($orchestratorExitCode -eq $script:ExitCodeTimeout) -or
            ($orchestratorExitCode -eq 130)
        $keepLogsOnError = (-not $isTimeoutOrCancel) -and (
            $orchestratorHadChildFailure -or (
                ($orchestratorExitCode -ne 0) -and
                ($orchestratorExitCode -ne $script:ExitCodeTimeout) -and
                ($orchestratorExitCode -ne 130)
            )
        )
        try {
            [void](Invoke-DlnaWorkflowQuitCleanup -KeepLogs:$keepLogsOnError)
        } catch {
            Write-Warning ("DLNA quit cleanup failed: {0}" -f $_.Exception.Message)
        }
    } elseif (-not $DryRun -and (Get-Command Obfuscate-DlnaSegmentRootMedia -ErrorAction SilentlyContinue)) {
        $isTimeoutOrCancel = ($orchestratorExitCode -eq $script:ExitCodeTimeout) -or
            ($orchestratorExitCode -eq 130)
        $keepLogsOnError = (-not $isTimeoutOrCancel) -and (
            $orchestratorHadChildFailure -or (
                ($orchestratorExitCode -ne 0) -and
                ($orchestratorExitCode -ne $script:ExitCodeTimeout) -and
                ($orchestratorExitCode -ne 130)
            )
        )
        try {
            [void](Obfuscate-DlnaSegmentRootMedia -KeepLogs:$keepLogsOnError)
        } catch {
            Write-Warning ("DLNA root media obfuscate on quit failed: {0}" -f $_.Exception.Message)
        }
        if (Get-Command Remove-DlnaSegmentRootSubst -ErrorAction SilentlyContinue) {
            try { [void](Remove-DlnaSegmentRootSubst) } catch {
                Write-Warning ("DLNA root F: subst cleanup on quit failed: {0}" -f $_.Exception.Message)
            }
        }
    }
    try {
        if ($orchestratorMutex -and $ownsOrchestratorMutex) {
            [void]$orchestratorMutex.ReleaseMutex()
            $ownsOrchestratorMutex = $false
        }
    } catch { }
    try {
        if ($null -ne $orchestratorMutex) {
            $orchestratorMutex.Dispose()
            $orchestratorMutex = $null
        }
    } catch { }
}

exit $orchestratorExitCode
