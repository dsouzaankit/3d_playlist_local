<#
.SYNOPSIS
  3d_playlist_local workflow start: hold the Quest proximity sensor off and push the Quest control
  page (with this repo's tiles) to the headset's browser.

.DESCRIPTION
  Lives in 3d_playlist_local\individual_transcode\quest; the generic headset helpers it starts are
  in the quest_tools repo (PlaylistLocalQuestCommon.ps1 finds it). Called (hidden, fire and forget)
  by 3d_playlist_local\individual_transcode\Start-PlaylistQuestSession.ps1 from
  run_batch_vr_hybrid.ps1, run_batch_fisheye_v360.ps1 and Run-TranscodeOrchestrator.ps1. It
  starts these in the background and exits:

    1. the shared Quest control page (quest_tools QuestControlHost.ps1) on this PC's LAN address,
       with this repo's tiles (PlaylistControlTiles.ps1: Space, End session, segment bitrate) for
       as long as -WorkflowPid runs; a host that already runs (e.g. for the Loop Segments companion)
       just gets the tiles added;
    2. keep-awake (quest_tools Invoke-QuestHeadset.ps1 -KeepAwakeSession -ParentPid <workflow>):
       finds the headset on adb and holds the proximity sensor off (prox_close) once it is awake,
       re-applied every ~20 s;
    3. Invoke-QuestHeadset.ps1 -OpenControlPage: waits for an awake headset (every 5 s, until the
       workflow ends; openWaitMinutes > 0 caps it) and opens the control page in its own signed-in
       Quest Browser tab, where it also measures PC -> Quest (the segment bitrate);
    4. the XR player page, unless player / $env:PLAYLIST_QUEST_PLAYER = none
       (Get-PlaylistQuestPlayer): Start-PlaylistLocalQuestXr.ps1 (this folder) serves it (..\xr, the
       DLNA segments with fisheye / VR180 / flat projection and chroma key over passthrough) from this
       PC and, once the control page open has finished and the headset is awake, opens it in Quest
       Browser in front of the control page;
    5. the natural-end cleanup: once no registered workflow runs any more (and no Loop Segments
       companion, whose own quit does it), Invoke-QuestHeadset.ps1 -Cleanup (tabs, history, sensor
       on, Wi-Fi off).

  Nothing opens on the PC; the workflow window prints a sign-in link to the page instead.

  The workflow PID goes into %TEMP%\loopsegments-playlist-session.json, so the control page's
  End session button (Invoke-PlaylistLocalQuestShutdown.ps1) knows which PowerShell window to stop.

  session=false in playlist-quest.json (or the older questPlaylistSession=false) turns it off.
  Log: %TEMP%\loopsegments-quest-lantab.log ("Playlist session:" lines).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $WorkflowPid,
    [string] $WorkflowName = '',
    # Workflow deadline (ISO 'o' UTC, empty = none): stored with the session for the XR page's countdown.
    [string] $DeadlineUtc = '',
    # Internal: wait until no registered workflow runs any more, then run the Quest cleanup (tabs,
    # history, sensor on, Wi-Fi off per wifiOffOnExit). The End session button stops this
    # helper and does that itself.
    [switch] $CleanupWhenGone
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'PlaylistLocalQuestCommon.ps1')

if ($CleanupWhenGone) {
    # One helper for all workflows: done when none of them runs any more.
    while ((Get-Process -Id $WorkflowPid -ErrorAction SilentlyContinue) -or @(Get-PlaylistQuestSessions).Count) { Start-Sleep -Seconds 3 }
    # A running companion does the same Quest cleanup at its own quit (and still uses the headset).
    if (@(Get-PlaylistQuestCompanionProcesses).Count) {
        Write-QuestLog 'Playlist session: workflow gone - Quest cleanup left to the running companion.'
        exit 0
    }
    Write-QuestLog 'Playlist session: workflow gone - Quest cleanup (tabs, history, sensor on, Wi-Fi off).'
    $p = Start-QuestHiddenProcess -Pwsh (Get-QuestPwshExe) -Script $script:PlaylistQuestHeadset -Arguments (Get-PlaylistQuestCleanupArgs)
    if (-not $p.WaitForExit(180000)) { try { $p.Kill($true) } catch {} }
    $res = if (-not $p.HasExited) { 'timed out' } else { @{ 0 = 'done'; 1 = 'headset not on adb - the after-quit helper does it when it is back'; 3 = 'incomplete'; 4 = 'history delete postponed until the headset is worn' }[$p.ExitCode] }
    Write-QuestLog "Playlist session: Quest cleanup after the workflow - $res."
    exit 0
}

$cfg = Get-PlaylistQuestSettings
if ($cfg.session -eq $false) {
    Write-QuestLog 'Playlist session: off (session=false).'
    exit 0
}
if (-not (Get-Process -Id $WorkflowPid -ErrorAction SilentlyContinue)) {
    Write-QuestLog "Playlist session: workflow PID $WorkflowPid is not running - nothing started."
    exit 2
}

Register-PlaylistQuestSession -WorkflowPid $WorkflowPid -WorkflowName $WorkflowName -DeadlineUtc $DeadlineUtc
# The last End session's progress belongs to an earlier workflow (unless one is still running).
try {
    $prev = Get-Content -LiteralPath $script:PlaylistShutdownPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if (-not ($prev.state -eq 'running' -and (Get-Process -Id ([int]$prev.pid) -ErrorAction SilentlyContinue))) { Remove-Item -LiteralPath $script:PlaylistShutdownPath -Force }
} catch {}
Write-QuestLog "Playlist session: $WorkflowName workflow started (PID $WorkflowPid) - sensor off + control page to the headset."
# historyOrigins: into the shared origin list, so every cleanup (also the Loop Segments companion's
# quit) closes their tabs and deletes their history.
foreach ($o in @(Get-PlaylistQuestExtraOrigins)) { Register-QuestBrowserOrigin -Origin $o -Owner '3d_playlist_local-history' }

# 0. A previous quit's after-quit history helper (quest_tools' Invoke-QuestHistoryRetry.ps1) still
#    waiting for the headset would run that old quit's cleanup once the headset is worn - mid-run:
#    close this session's control page tab and Quest Browser, switch Wi-Fi off. Stop it first; this
#    session's quit deletes the same entries.
$stopped = Stop-QuestHistoryRetry
if ($stopped.Stopped -or $stopped.Pending) {
    # The Wi-Fi AP bounce that helper was holding: this session's quit probes again.
    Remove-Item -LiteralPath (Join-Path $env:TEMP 'loopsegments-wifi-bounce-pending.json') -Force -ErrorAction SilentlyContinue
    Write-QuestLog "Playlist session: stopped the last quit's history helper ($($stopped.Stopped) process(es)); this session's quit deletes those entries."
}

$pwsh = Get-QuestPwshExe
$controlOn = ($cfg.controlPage -ne $false)

# 1. This repo's tiles on the shared control page (the host starts with the first registration).
if ($controlOn) {
    $h = Register-QuestControlTiles -Owner $script:PlaylistControlOwner -OwnerPid $WorkflowPid -Module $script:PlaylistControlTiles
    if ($h.Pid) {
        $how = if ($h.Started) { 'host started' } else { 'added to the running host' }
        Write-QuestLog "Playlist session: control page tiles registered ($how, port $($h.Port), PID $($h.Pid); they go when the workflow exits)."
    } else {
        Write-QuestLog 'Playlist session: control page host did not start - the page is not served (see %TEMP%\quest-control-host.log).'
    }
} else {
    Write-QuestLog 'Playlist session: control page off (controlPage=false) - not served, not opened.'
}

# 1c. Cleanup when the workflow ends by itself: Quest tabs + history, sensor, Wi-Fi.
if (-not @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { ([string]$_.CommandLine) -like '*Start-PlaylistLocalQuestSession.ps1*-CleanupWhenGone*' }).Count) {
    [void](Start-QuestHiddenProcess -Pwsh $pwsh -Script $PSCommandPath -Arguments @('-WorkflowPid', "$WorkflowPid", '-CleanupWhenGone'))
}

# 2. Keep-awake: sensor off while the workflow runs (once per workflow PID).
$have = @(Get-PlaylistQuestHelperProcesses -Pattern '*-KeepAwakeSession*' | Where-Object { ([string]$_.CommandLine) -match "-ParentPid\s+$WorkflowPid\b" })
if ($have.Count) {
    Write-QuestLog "Playlist session: keep-awake already running for PID $WorkflowPid."
} else {
    $p = Start-QuestHiddenProcess -Pwsh $pwsh -Script $script:PlaylistQuestHeadset -Arguments @('-KeepAwakeSession', '-ParentPid', "$WorkflowPid")
    Write-QuestLog "Playlist session: keep-awake started (PID $($p.Id)): proximity sensor held off while the workflow runs."
}

# 3. Push the control page to the headset browser (waits for an awake headset). Its -StatusFile
#    tells step 4 when the browser is done coming to the front.
$controlStatus = ''
if ($controlOn) {
    @(Get-PlaylistQuestHelperProcesses -Pattern '*-OpenControlPage*') | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
    $controlStatus = Join-Path $env:TEMP 'loopsegments-playlist-controlpage-status.txt'
    Remove-Item -LiteralPath $controlStatus -Force -ErrorAction SilentlyContinue
    # 0 = until the workflow ends (the helper gets -ParentPid): the headset's Wi-Fi is usually off at a
    # workflow start, so it can take a while before it is on adb.
    $wait = 0
    try { $wait = [int]$cfg.openWaitMinutes } catch {}
    $args3 = @('-OpenControlPage', '-WaitMinutes', "$wait", '-ParentPid', "$WorkflowPid", '-StatusFile', $controlStatus)
    $p = Start-QuestHiddenProcess -Pwsh $pwsh -Script $script:PlaylistQuestHeadset -Arguments $args3
    Write-QuestLog ("Playlist session: opening the control page on the headset (PID {0}, waits {1} for it to be awake)." -f $p.Id, $(if ($wait -gt 0) { "up to $wait min" } else { 'until the workflow ends' }))
}

# 4. The XR page once the headset is awake (after the control page open), unless the player is 'none'.
$player = Get-PlaylistQuestPlayer
if ($player -eq 'xr') {
    $xrScript = Join-Path $PSScriptRoot 'Start-PlaylistLocalQuestXr.ps1'
    $haveXr = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $c = [string]$_.CommandLine; $c -like '*Start-PlaylistLocalQuestXr.ps1*' -and $c -match "-WorkflowPid\s+$WorkflowPid\b" })
    if ($haveXr.Count) {
        Write-QuestLog "Playlist session: XR page already queued for PID $WorkflowPid."
    } else {
        $argsXr = @('-WorkflowPid', "$WorkflowPid", '-WorkflowName', $WorkflowName)
        if ($controlStatus) { $argsXr += @('-ControlPageStatusFile', $controlStatus) }
        $p = Start-QuestHiddenProcess -Pwsh $pwsh -Script $xrScript -Arguments $argsXr
        Write-QuestLog "Playlist session: XR page queued (PID $($p.Id)): served from this PC, opened in Quest Browser once the headset is awake."
    }
} else {
    Write-QuestLog 'Playlist session: no player opened (player=none).'
}
exit 0
