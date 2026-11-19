<#
.SYNOPSIS
  3d_playlist_local workflow start: hold the Quest proximity sensor off and push the Quest control
  page to the headset's browser.

.DESCRIPTION
  Lives in 3d_playlist_local\individual_transcode\quest; the Quest helpers it starts are in
  ios_3d_loop_segments\windows\quest (PlaylistLocalQuestCommon.ps1 finds that repo).
  Called (hidden, fire and forget) by 3d_playlist_local\individual_transcode\Start-PlaylistQuestSession.ps1
  from run_batch_vr_hybrid.ps1, run_batch_fisheye_v360.ps1 and Run-TranscodeOrchestrator.ps1. It
  starts three background processes and exits:

    1. the Quest control page (Serve-QuestControlPage.ps1) on this PC's LAN address, until
       -WorkflowPid exits; reused when it already runs (for example the companion's);
    2. keep-awake (Watch-LoopSegmentsQuestLanTab.ps1 -KeepAwakeSession -ParentPid <workflow>):
       finds the headset on adb (adb devices, questAdbHost, last address, mDNS, adb server restart)
       and holds the proximity sensor off (prox_close) once it is awake, re-applied every ~20 s;
    3. Watch-LoopSegmentsQuestLanTab.ps1 -OpenControlPage: waits up to questPlaylistOpenWaitMinutes
       for an awake headset and opens the control page in its own signed-in Quest Browser tab.

  The workflow PID goes into %TEMP%\loopsegments-playlist-session.json, so the control page's
  Enter button (Invoke-PlaylistLocalQuestShutdown.ps1) knows which PowerShell window to stop.

  questPlaylistSession=false (windows\loop-segments-windows.json) turns it off.
  Log: %TEMP%\loopsegments-quest-lantab.log ("Playlist session:" lines).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $WorkflowPid,
    [string] $WorkflowName = '',
    # Internal: wait until no registered workflow runs any more, then close the control page Chromium
    # and run the Quest cleanup (tabs, history, sensor on, Wi-Fi off per questWifiOffOnExit). The Enter
    # button stops this helper and does all of that itself.
    [switch] $CleanupWhenGone
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'PlaylistLocalQuestCommon.ps1')

if ($CleanupWhenGone) {
    $cfg0 = Get-LoopSegmentsWindowsSettings
    # One helper for all workflows: done when none of them runs any more.
    while ((Get-Process -Id $WorkflowPid -ErrorAction SilentlyContinue) -or @(Get-PlaylistQuestSessions).Count) { Start-Sleep -Seconds 3 }
    $n = Stop-PlaylistQuestPcChromium
    if ($n) { Write-PlaylistQuestLog 'Playlist session: workflow gone - closed the control page Chromium on the PC.' }
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

# 1b. The same page in this PC's default browser, signed in through a loopback-only token link
#     (/pc?t=<token> -> HttpOnly cookie; the Basic login never goes on a command line).
if (-not ($cfg.Contains('questPlaylistOpenOnPc') -and $cfg.questPlaylistOpenOnPc -eq $false) -and
    -not ($cfg.Contains('questControlPage') -and $cfg.questControlPage -eq $false)) {
    $port = 18766
    try { if ([int]$cfg.questControlPort -gt 0) { $port = [int]$cfg.questControlPort } } catch {}
    $t0 = [DateTime]::UtcNow
    $up = $false
    while (-not $up -and ([DateTime]::UtcNow - $t0).TotalSeconds -lt 15) {
        $c = [System.Net.Sockets.TcpClient]::new()
        try { $c.Connect('127.0.0.1', $port); $up = $true } catch { Start-Sleep -Milliseconds 500 } finally { $c.Dispose() }
    }
    if ($up) {
        $token = Get-PlaylistQuestPcToken
        $pcUrl = "http://127.0.0.1:$port/pc?t=$token"
        $how = $null
        try { $how = Open-PlaylistQuestPcChromium -Url $pcUrl } catch { Write-PlaylistQuestLog "Playlist session: Chromium launch failed ($($_.Exception.Message))." }
        if ($how) {
            Write-PlaylistQuestLog ("Playlist session: control page opened on the PC in {0} (http://127.0.0.1:{1}/)." -f $(if ($how -eq 'tab') { 'the open control page Chromium (new tab)' } else { 'a fresh Chromium window' }), $port)
        } else {
            Start-Process $pcUrl
            Write-PlaylistQuestLog "Playlist session: Playwright Chromium not found - control page opened in this PC's default browser (http://127.0.0.1:$port/)."
        }
    } else {
        Write-PlaylistQuestLog "Playlist session: control page not listening on port $port - not opened on the PC."
    }
}

# 1c. Cleanup when the workflow ends by itself: PC Chromium, Quest tabs + history, sensor, Wi-Fi.
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

# 3. Push the control page to the headset browser (waits for an awake headset).
if (-not ($cfg.Contains('questControlPage') -and $cfg.questControlPage -eq $false)) {
    @(Get-PlaylistQuestHelperProcesses -Pattern '*-OpenControlPage*') | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
    $wait = 30
    try { if ($null -ne $cfg.questPlaylistOpenWaitMinutes) { $wait = [int]$cfg.questPlaylistOpenWaitMinutes } } catch {}
    $args3 = @('-OpenControlPage', '-WaitMinutes', "$wait", '-ParentPid', "$WorkflowPid")
    if ($url) { $args3 += @('-Url', $url) }
    $p = Start-PlaylistQuestHidden -Pwsh $pwsh -Script $watch -Arguments $args3
    Write-PlaylistQuestLog "Playlist session: opening the control page on the headset (PID $($p.Id), waits up to $wait min for it to be awake)."
}
exit 0
