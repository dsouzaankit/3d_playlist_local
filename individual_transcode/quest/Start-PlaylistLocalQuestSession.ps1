<#
.SYNOPSIS
  3d_playlist_local workflow start: hold the Quest proximity sensor off and push the Quest control
  page to the headset's browser.

.DESCRIPTION
  Lives in 3d_playlist_local\individual_transcode\quest; the Quest helpers it starts are in
  ios_3d_loop_segments\windows\quest (PlaylistLocalQuestCommon.ps1 finds that repo).
  Called (hidden, fire and forget) by 3d_playlist_local\individual_transcode\Start-PlaylistQuestSession.ps1
  from run_batch_vr_hybrid.ps1, run_batch_fisheye_v360.ps1 and Run-TranscodeOrchestrator.ps1. It
  starts four background processes and exits:

    1. the Quest control page (Serve-QuestControlPage.ps1) on this PC's LAN address, until
       -WorkflowPid exits; reused when it already runs (for example the companion's);
    2. keep-awake (Watch-LoopSegmentsQuestLanTab.ps1 -KeepAwakeSession -ParentPid <workflow>):
       finds the headset on adb (adb devices, questAdbHost, last address, mDNS, adb server restart)
       and holds the proximity sensor off (prox_close) once it is awake, re-applied every ~20 s;
    3. Watch-LoopSegmentsQuestLanTab.ps1 -OpenControlPage: waits for an awake headset (every 5 s,
       until the workflow ends; questPlaylistOpenWaitMinutes > 0 caps it) and opens the control page
       in its own signed-in Quest Browser tab, where it also measures PC -> Quest;
    4. Start-PlaylistLocalQuestSkybox.ps1 (this folder): once the headset is awake and the control
       page open has finished, opens SKYBOX VR Player in front (Quest Browser keeps running
       behind it) so the segments can be picked from the SKYBOX PC share. It only opens the app,
       it does not start a video. questPlaylistLaunchSkybox=false / PLAYLIST_QUEST_SKYBOX=0 skip it.

  Nothing opens on the PC; the workflow window prints a sign-in link to the page instead.

  The workflow PID goes into %TEMP%\loopsegments-playlist-session.json, so the control page's
  End session button (Invoke-PlaylistLocalQuestShutdown.ps1) knows which PowerShell window to stop.

  questPlaylistSession=false (windows\loop-segments-windows.json) turns it off.
  Log: %TEMP%\loopsegments-quest-lantab.log ("Playlist session:" lines).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $WorkflowPid,
    [string] $WorkflowName = '',
    # Internal: wait until no registered workflow runs any more, then run the Quest cleanup (tabs,
    # history, sensor on, Wi-Fi off per questWifiOffOnExit). The End session button stops this
    # helper and does that itself.
    [switch] $CleanupWhenGone
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'PlaylistLocalQuestCommon.ps1')

if ($CleanupWhenGone) {
    $cfg0 = Get-LoopSegmentsWindowsSettings
    # One helper for all workflows: done when none of them runs any more.
    while ((Get-Process -Id $WorkflowPid -ErrorAction SilentlyContinue) -or @(Get-PlaylistQuestSessions).Count) { Start-Sleep -Seconds 3 }
    # A running companion does the same Quest cleanup at its own quit (and still uses the headset).
    if (@(Get-PlaylistQuestCompanionProcesses).Count) {
        Write-PlaylistQuestLog 'Playlist session: workflow gone - Quest cleanup left to the running companion.'
        exit 0
    }
    Write-PlaylistQuestLog 'Playlist session: workflow gone - Quest cleanup (tabs, history, sensor on, Wi-Fi off).'
    $p = Start-PlaylistQuestHidden -Pwsh (Get-PlaylistQuestPwsh) -Script (Join-Path $script:LsQuestDir 'Watch-LoopSegmentsQuestLanTab.ps1') -Arguments (Get-PlaylistQuestHistoryArgs)
    if (-not $p.WaitForExit(180000)) { try { $p.Kill($true) } catch {} }
    $res = if (-not $p.HasExited) { 'timed out' } else { @{ 0 = 'done'; 1 = 'headset not on adb - the after-quit helper does it when it is back'; 3 = 'incomplete'; 4 = 'history delete postponed until the headset is worn' }[$p.ExitCode] }
    Write-PlaylistQuestLog "Playlist session: Quest cleanup after the workflow - $res."
    exit 0
}

$cfg = Get-LoopSegmentsWindowsSettings
if ($cfg.Contains('questPlaylistSession') -and $cfg.questPlaylistSession -eq $false) {
    Write-PlaylistQuestLog 'Playlist session: off (questPlaylistSession=false).'
    exit 0
}
if (-not (Get-Process -Id $WorkflowPid -ErrorAction SilentlyContinue)) {
    Write-PlaylistQuestLog "Playlist session: workflow PID $WorkflowPid is not running - nothing started."
    exit 2
}

Register-PlaylistQuestSession -WorkflowPid $WorkflowPid -WorkflowName $WorkflowName
# The last Enter run's progress belongs to an earlier workflow (unless one is still running).
try {
    $prev = Get-Content -LiteralPath $script:PlaylistShutdownPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if (-not ($prev.state -eq 'running' -and (Get-Process -Id ([int]$prev.pid) -ErrorAction SilentlyContinue))) { Remove-Item -LiteralPath $script:PlaylistShutdownPath -Force }
} catch {}
Write-PlaylistQuestLog "Playlist session: $WorkflowName workflow started (PID $WorkflowPid) - sensor off + control page to the headset."

# 0. A previous quit's after-quit history helper (Watch-LoopSegmentsQuestLanTab.ps1 -RetryHistory) still
#    waiting for the headset would run that old quit's cleanup once the headset is worn - mid-run: close
#    this session's control page tab and Quest Browser, switch Wi-Fi off. Stop it first, as the Loop
#    Segments companion does at its start (QuestCompanionHooks.ps1 Stop-QuestHistoryRetry); this session's
#    quit deletes the same entries.
$historyPending = Join-Path $env:TEMP 'loopsegments-quest-history-pending.json'
$stoppedHelpers = 0
try {
    Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { ([string]$_.CommandLine) -like '*Watch-LoopSegmentsQuestLanTab.ps1*' -and ([string]$_.CommandLine) -like '*-RetryHistory*' } |
        ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue; $stoppedHelpers++ }
} catch {}
if ($stoppedHelpers -or (Test-Path -LiteralPath $historyPending)) {
    Remove-Item -LiteralPath $historyPending -Force -ErrorAction SilentlyContinue
    # The Wi-Fi AP bounce that helper was holding: this session's quit probes again.
    Remove-Item -LiteralPath (Join-Path $env:TEMP 'loopsegments-wifi-bounce-pending.json') -Force -ErrorAction SilentlyContinue
    Write-PlaylistQuestLog "Playlist session: stopped the last quit's history helper ($stoppedHelpers process(es)); this session's quit deletes those entries."
}

$pwsh = Get-PlaylistQuestPwsh
$lanConfig = Get-PlaylistQuestLanConfigPath
$url = Get-PlaylistQuestPhoneUrl -LanConfig $lanConfig

# 1. Control page server (the companion's, if it runs, else ours until the workflow exits).
$serverPid = Get-PlaylistQuestControlServerPid
if ($serverPid) {
    Write-PlaylistQuestLog "Playlist session: control page already served (PID $serverPid) - reused."
} elseif ($cfg.Contains('questControlPage') -and $cfg.questControlPage -eq $false) {
    Write-PlaylistQuestLog 'Playlist session: control page off (questControlPage=false) - not served, not opened.'
} else {
    # A fresh session: Quest Browser ownership is noted again by the page open below.
    Remove-Item -LiteralPath (Join-Path $env:TEMP 'loopsegments-quest-browser-ours.json') -Force -ErrorAction SilentlyContinue
    $port = 18766
    try { if ([int]$cfg.questControlPort -gt 0) { $port = [int]$cfg.questControlPort } } catch {}
    $args1 = @('-Port', "$port", '-CompanionPid', "$WorkflowPid")
    if ($lanConfig) { $args1 += @('-LanConfig', $lanConfig) }
    $p = Start-PlaylistQuestHidden -Pwsh $pwsh -Script (Join-Path $script:LsQuestDir 'Serve-QuestControlPage.ps1') -Arguments $args1
    Write-PlaylistQuestLog "Playlist session: control page server started on port $port (PID $($p.Id), stops with the workflow)."
}

# Nothing is opened on the PC: the workflow window prints a sign-in link to the page
# (individual_transcode\Start-PlaylistQuestSession.ps1, loopback-only /pc?t=<token>).

# 1c. Cleanup when the workflow ends by itself: Quest tabs + history, sensor, Wi-Fi.
if (-not @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { ([string]$_.CommandLine) -like '*Start-PlaylistLocalQuestSession.ps1*-CleanupWhenGone*' }).Count) {
    [void](Start-PlaylistQuestHidden -Pwsh $pwsh -Script $PSCommandPath -Arguments @('-WorkflowPid', "$WorkflowPid", '-CleanupWhenGone'))
}

# 2. Keep-awake: sensor off while the workflow runs (once per workflow PID).
$watch = Join-Path $script:LsQuestDir 'Watch-LoopSegmentsQuestLanTab.ps1'
$have = @(Get-PlaylistQuestHelperProcesses -Pattern '*-KeepAwakeSession*' | Where-Object { ([string]$_.CommandLine) -match "-ParentPid\s+$WorkflowPid\b" })
if ($have.Count) {
    Write-PlaylistQuestLog "Playlist session: keep-awake already running for PID $WorkflowPid."
} else {
    $p = Start-PlaylistQuestHidden -Pwsh $pwsh -Script $watch -Arguments @('-KeepAwakeSession', '-ParentPid', "$WorkflowPid")
    Write-PlaylistQuestLog "Playlist session: keep-awake started (PID $($p.Id)): proximity sensor held off while the workflow runs."
}

# 3. Push the control page to the headset browser (waits for an awake headset). Its -StatusFile
#    tells step 4 when the browser is done coming to the front.
$controlStatus = ''
if (-not ($cfg.Contains('questControlPage') -and $cfg.questControlPage -eq $false)) {
    @(Get-PlaylistQuestHelperProcesses -Pattern '*-OpenControlPage*') | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
    $controlStatus = Join-Path $env:TEMP 'loopsegments-playlist-controlpage-status.txt'
    Remove-Item -LiteralPath $controlStatus -Force -ErrorAction SilentlyContinue
    # 0 = until the workflow ends (the helper gets -ParentPid): the headset's Wi-Fi is usually off at a
    # workflow start, so it can take a while before it is on adb.
    $wait = 0
    try { if ($null -ne $cfg.questPlaylistOpenWaitMinutes) { $wait = [int]$cfg.questPlaylistOpenWaitMinutes } } catch {}
    $args3 = @('-OpenControlPage', '-WaitMinutes', "$wait", '-ParentPid', "$WorkflowPid", '-StatusFile', $controlStatus)
    if ($url) { $args3 += @('-Url', $url) }
    $p = Start-PlaylistQuestHidden -Pwsh $pwsh -Script $watch -Arguments $args3
    Write-PlaylistQuestLog ("Playlist session: opening the control page on the headset (PID {0}, waits {1} for it to be awake)." -f $p.Id, $(if ($wait -gt 0) { "up to $wait min" } else { 'until the workflow ends' }))
}

# 4. SKYBOX in front once the headset is awake (after the control page open), so the segments can
#    be picked from the SKYBOX PC share. questPlaylistLaunchSkybox=false / PLAYLIST_QUEST_SKYBOX=0 skip it.
if ($env:PLAYLIST_QUEST_SKYBOX -ne '0' -and -not ($cfg.Contains('questPlaylistLaunchSkybox') -and $cfg.questPlaylistLaunchSkybox -eq $false)) {
    $skyScript = Join-Path $PSScriptRoot 'Start-PlaylistLocalQuestSkybox.ps1'
    $haveSky = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $c = [string]$_.CommandLine; $c -like '*Start-PlaylistLocalQuestSkybox.ps1*' -and $c -match "-WorkflowPid\s+$WorkflowPid\b" })
    if ($haveSky.Count) {
        Write-PlaylistQuestLog "Playlist session: SKYBOX launch already queued for PID $WorkflowPid."
    } else {
        $args4 = @('-WorkflowPid', "$WorkflowPid")
        if ($controlStatus) { $args4 += @('-ControlPageStatusFile', $controlStatus) }
        $p = Start-PlaylistQuestHidden -Pwsh $pwsh -Script $skyScript -Arguments $args4
        Write-PlaylistQuestLog "Playlist session: SKYBOX launch queued (PID $($p.Id)): opens in front once the headset is awake."
    }
}
exit 0
