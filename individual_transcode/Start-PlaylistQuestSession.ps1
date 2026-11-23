<#
.SYNOPSIS
  Workflow start hook: Quest proximity sensor off + Quest control page on the headset and the PC.

.DESCRIPTION
  On by default in all three workflows: run_batch_vr_hybrid.ps1, run_batch_fisheye_v360.ps1 and
  Run-TranscodeOrchestrator.ps1 call it near their start (skipped only with -DryRun). Starts, hidden
  and without waiting, quest\Start-PlaylistLocalQuestSession.ps1 -WorkflowPid <this window> (this
  folder), which in the background holds the Quest proximity sensor off while the workflow runs,
  adds this repo's tiles to the shared Quest control page and opens it in Quest Browser. Nothing
  opens on the PC: this window prints a sign-in link to the page (http://127.0.0.1:18766/pc?t=...)
  for when you want it. The page's End session button runs quest\Invoke-PlaylistLocalQuestShutdown.ps1:
  stops the Quest players reading the output, presses Enter in every 3d_playlist_local window,
  quits the Loop Segments companion if it runs (its quit cleans up the Quest), else cleans up the
  Quest itself (tabs, history, sensor on, Wi-Fi off). The workflow's quit also stops the Quest
  players before renaming the segments, and when it ends by itself the same Quest cleanup runs.

  The playlist's Quest logic is in quest\ (this repo); the generic headset layer (adb, sensor,
  Wi-Fi, Quest Browser, the control page host, the cleanup) is the quest_tools repo. Never fails
  the workflow: a missing quest_tools / pwsh only prints a line.

  Off:   $env:PLAYLIST_QUEST_SESSION = '0', or "session": false in quest\playlist-quest.json
  Repo:  $env:QUEST_TOOLS_REPO = '<path to quest_tools>'  (default <scripts root>\quest_tools)
  Log:   %TEMP%\loopsegments-quest-lantab.log  ("Playlist session:" / "Playlist stop:" lines)
#>
[CmdletBinding()]
param(
    [int] $WorkflowPid = $PID,
    [string] $WorkflowName = ''
)

# First of: quest\playlist-quest.json (this repo), quest_tools\quest-tools.json, the older shared
# ios_3d_loop_segments\windows\loop-segments-windows.json key. Plain JSON reads (this runs in the
# workflow's own PowerShell, which may be 5.1).
function Get-PlaylistHookSetting {
    param([string[]] $Files, [string[]] $Keys)
    for ($i = 0; $i -lt $Files.Count; $i++) {
        $f = $Files[$i]
        if (-not $f -or -not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        try {
            $c = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            if ($c.PSObject.Properties[$Keys[$i]] -and $null -ne $c.($Keys[$i])) { return $c.($Keys[$i]) }
        } catch {}
    }
    return $null
}

try {
    if ($env:PLAYLIST_QUEST_SESSION -eq '0') {
        Write-Host 'Quest session: off (PLAYLIST_QUEST_SESSION=0).'
        return
    }
    $starter = Join-Path $PSScriptRoot 'quest\Start-PlaylistLocalQuestSession.ps1'
    if (-not (Test-Path -LiteralPath $starter -PathType Leaf)) {
        Write-Host "Quest session: $starter missing - skipped."
        return
    }
    # The generic headset layer (same order as quest\PlaylistLocalQuestCommon.ps1).
    $qtCandidates = @($env:QUEST_TOOLS_REPO, $(if ($env:ALL_SCRIPTS_ROOT) { Join-Path $env:ALL_SCRIPTS_ROOT 'quest_tools' }))
    $d = $PSScriptRoot
    while ($d) { $qtCandidates += (Join-Path $d 'quest_tools'); $d = Split-Path -Parent $d }
    $questTools = @($qtCandidates + 'P:\all_scripts\quest_tools') |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath (Join-Path $_ 'QuestTools.ps1') -PathType Leaf) } |
        Select-Object -First 1
    if (-not $questTools) {
        Write-Host 'Quest session: quest_tools not found (set QUEST_TOOLS_REPO) - skipped.'
        return
    }
    $env:QUEST_TOOLS_REPO = [System.IO.Path]::GetFullPath($questTools)
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }
    if (-not (Test-Path -LiteralPath $pwsh)) {
        Write-Host 'Quest session: PowerShell 7 (pwsh.exe) not found - skipped.'
        return
    }
    $playlistCfg = Join-Path $PSScriptRoot 'quest\playlist-quest.json'
    $qtCfg = Join-Path $env:QUEST_TOOLS_REPO 'quest-tools.json'
    $lsRoots = @($env:LOOPSEGMENTS_IOS_REPO, $(if ($env:ALL_SCRIPTS_ROOT) { Join-Path $env:ALL_SCRIPTS_ROOT 'iOS apps\ios_3d_loop_segments' }), 'P:\all_scripts\iOS apps\ios_3d_loop_segments')
    $legacyCfg = @($lsRoots | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'windows\loop-segments-windows.json' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) | Select-Object -First 1
    if ((Get-PlaylistHookSetting -Files @($playlistCfg, $legacyCfg) -Keys @('session', 'questPlaylistSession')) -eq $false) {
        Write-Host 'Quest session: off (session=false).'
        return
    }
    # Invoke-LeafFfmpegControl.ps1 quit cleanup closes the XR page first (this process only).
    $env:PLAYLIST_QUEST_SESSION_PID = [string]$WorkflowPid
    Remove-Item Env:PLAYLIST_QUEST_XR_CLOSED -ErrorAction SilentlyContinue
    $argLine = '-NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File "{0}" -WorkflowPid {1} -WorkflowName "{2}"' -f $starter, $WorkflowPid, ($WorkflowName -replace '"', '')
    Start-Process -FilePath $pwsh -ArgumentList $argLine -WindowStyle Hidden | Out-Null
    Write-Host 'Quest session: sensor off + Quest control page on the headset (background). Its End session button stops this window and cleans up the Quest.'
    # Nothing opens on the PC: print a sign-in link instead (Ctrl+click in Windows Terminal). Loopback
    # only; the page host swaps the token for a cookie (same token file as quest_tools lib\QuestControl.ps1).
    try {
        $port = 18766
        $p = Get-PlaylistHookSetting -Files @($qtCfg, $legacyCfg) -Keys @('controlPort', 'questControlPort')
        if ($p -and [int]$p -gt 0) { $port = [int]$p }
        $tokPath = Join-Path $env:TEMP 'loopsegments-quest-control-pctoken.txt'
        $tok = ''
        if (Test-Path -LiteralPath $tokPath) { $tok = (Get-Content -LiteralPath $tokPath -Raw).Trim() }
        if ($tok -notmatch '^[A-Za-z0-9]{32,}$') {
            $bytes = [byte[]]::new(24)
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
            $tok = -join ($bytes | ForEach-Object { $_.ToString('x2') })
            Set-Content -LiteralPath $tokPath -Value $tok -Encoding ascii -NoNewline
        }
        Write-Host "Quest control on this PC (optional): http://127.0.0.1:$port/pc?t=$tok"
    } catch {}
    # XR player page (default Quest player; quest\Start-PlaylistLocalQuestXr.ps1 serves it).
    try {
        $player = ([string]$env:PLAYLIST_QUEST_PLAYER).Trim().ToLowerInvariant()
        if (-not $player) { $player = ([string](Get-PlaylistHookSetting -Files @($playlistCfg, $legacyCfg) -Keys @('player', 'questPlaylistPlayer'))).Trim().ToLowerInvariant() }
        $xrPort = 18768
        $xp = Get-PlaylistHookSetting -Files @($playlistCfg, $legacyCfg) -Keys @('xrPort', 'questPlaylistXrPort')
        if ($xp -and [int]$xp -gt 0) { $xrPort = [int]$xp }
        if ($player -ne 'none') {
            $xrMode = if ($WorkflowName -in @('hybrid', 'fisheye', 'flat')) { $WorkflowName } else { 'hybrid' }
            Write-Host "Quest XR page (opens on the headset; also on this PC): http://127.0.0.1:$xrPort/xr?mode=$xrMode"
        }
    } catch {}
} catch {
    Write-Host "Quest session: not started ($($_.Exception.Message))."
}
