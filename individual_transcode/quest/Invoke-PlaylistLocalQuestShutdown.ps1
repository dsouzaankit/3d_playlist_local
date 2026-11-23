<#
.SYNOPSIS
  Quest control page "End session: stop all": stop every running part of the session
  (3d_playlist_local workflows, the Loop Segments PC companion) and clean up the Quest once.

.DESCRIPTION
  Lives in 3d_playlist_local\individual_transcode\quest; drives the Quest helpers in
  ios_3d_loop_segments\windows\quest. Started by that repo's Serve-QuestControlPage.ps1
  (POST /playlist/enter) fully detached from it (the companion's quit kills the server and
  everything it started). One run at a time. Every step is skipped when its part is not running.
  Progress: %TEMP%\loopsegments-playlist-shutdown.json (shown on the control page).

    0. stop the workflows' keep-awake, a pending page open and the natural-end cleanup helper
       (this run does that cleanup);
    1. Quest media apps (-StopMediaApps): apps connected to this PC + questPlaylistMediaPlayers,
       first, so nothing streams the segments while the workflows' quit renames them;
    2. 3d_playlist_local workflows: Enter in every workflow window (key helper allowed 45 s; not
       delivered = tried again every 5 s, up to 3 times), wait for each to exit (its own quit
       cleanup), Enter again after 60 s, kill after questPlaylistEnterExitSec (180 s);
    3. (nothing opens on the PC any more: a control page tab you opened there closes itself);
    4. the companion (launcher shell or its Chromium running):
       a. close its Chromium gracefully (taskkill without /F: profile saved and synced), force after
          30 s: its normal quit runs (Quest tabs / history / SKYBOX / sensor / Wi-Fi off, rclone L:,
          Keep Alive, iPhone Home: the Loop Segments app). Its tab and history step covers every
          page in quest_tools' shared origin list (the XR page included) and questPlaylistHistoryOrigins;
       b. wait (<= 180 s) for its Quest step in the log ("Cleanup: finished") or the after-quit
          helper's pending file; neither (crashed, force-killed, no phone URL): step 5 runs instead;
    5. Quest step when the companion did not do it: -ClearHistory (tabs per questCloseLanTabsOnExit,
       history per questClearHistoryOnExit, sensor on, Wi-Fi off per questWifiOffOnExit), then
       Wi-Fi off once more unless the history delete was handed to the after-quit helper or the
       cleanup's log already says it switched Wi-Fi off;
    This run and every helper it starts run at AboveNormal priority (a fisheye run can starve them).
    6. leftovers: companion REST log sinks whose companion is gone.

  So the Quest history is deleted exactly once: by the companion's quit, by step 5, or by the
  after-quit helper when the headset was not worn.

  Log: %TEMP%\loopsegments-quest-lantab.log ("Playlist stop:" lines)
#>
[CmdletBinding()]
param(
    # Extra workflow shells to stop, besides the registered ones.
    [int[]] $WorkflowPid = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'PlaylistLocalQuestCommon.ps1')

$cfg = Get-LoopSegmentsWindowsSettings
$pwsh = Get-PlaylistQuestPwsh
$watch = Join-Path $script:LsQuestDir 'Watch-LoopSegmentsQuestLanTab.ps1'
$keyScript = Join-Path $script:LsQuestDir 'Send-PlaylistLocalSpaceKey.ps1'
# The after-quit helper's pending delete (quest_tools lib\QuestHistoryRetry.ps1).
$pendingHistoryPath = $script:QuestHistoryPendingPath

# ---- Progress file (one run at a time) ----

if (Test-Path -LiteralPath $script:PlaylistShutdownPath) {
    try {
        $prev = Get-Content -LiteralPath $script:PlaylistShutdownPath -Raw | ConvertFrom-Json
        if ($prev.state -eq 'running' -and [int]$prev.pid -ne $PID -and (Get-Process -Id ([int]$prev.pid) -ErrorAction SilentlyContinue)) {
            Write-PlaylistQuestLog "Playlist stop: already running (PID $($prev.pid))."
            exit 9
        }
    } catch {}
}

# Above-normal priority for this run and its helpers: a fisheye run (pass-1 + chase encode) can
# starve them (2026-11-19: 10 s to start, 37 s to stop SKYBOX, Enter helper past its timeout).
function Set-HelperPriority {
    param([System.Diagnostics.Process] $Process)
    try { if ($Process -and -not $Process.HasExited) { $Process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal } } catch {}
}
Set-HelperPriority (Get-Process -Id $PID)

$script:Status = [ordered]@{ pid = $PID; state = 'running'; startedAt = (Get-Date -Format 'HH:mm:ss'); steps = [System.Collections.Generic.List[object]]::new() }

function Save-ShutdownStatus {
    try { $script:Status | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath $script:PlaylistShutdownPath -Encoding utf8 } catch {}
}

function Set-ShutdownStep {
    param([string] $Name, [string] $Result, [ValidateSet('running', 'ok', 'warn', 'bad', 'skip')] [string] $Level = 'ok')
    $s = @($script:Status.steps | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
    if (-not $s) { $s = [ordered]@{ name = $Name; result = ''; level = '' }; $script:Status.steps.Add($s) }
    $s.result = $Result
    $s.level = $Level
    Save-ShutdownStatus
    if ($Level -ne 'running') { Write-PlaylistQuestLog "Playlist stop: $Name - $Result" }
}

# Runs the watcher hidden and waits. Returns @{ Code; Status } (Code -1 = timed out).
function Invoke-ShutdownWatch {
    param([string[]] $Arguments, [int] $TimeoutSec = 60)
    $statusFile = Join-Path $env:TEMP ('loopsegments-playlist-stop-{0}.txt' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $p = Start-PlaylistQuestHidden -Pwsh $pwsh -Script $watch -Arguments (@($Arguments) + @('-StatusFile', $statusFile))
        Set-HelperPriority $p
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch {}
            return [pscustomobject]@{ Code = -1; Status = '' }
        }
        $st = ''
        if (Test-Path -LiteralPath $statusFile) { try { $st = (Get-Content -LiteralPath $statusFile -Raw).Trim() } catch {} }
        return [pscustomobject]@{ Code = $p.ExitCode; Status = $st }
    } finally {
        Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    }
}

# Send-PlaylistLocalSpaceKey.ps1 -Key Enter; returns its JSON object. 45 s: during a fisheye run
# its pwsh start + process list + Add-Type took over 20 s (seen 2026-11-19), so Enter was never sent.
function Send-WorkflowEnter {
    param([int[]] $Pids, [int] $TimeoutSec = 45)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $keyScript, '-Key', 'Enter')) { [void]$psi.ArgumentList.Add($a) }
    if (@($Pids).Count) { [void]$psi.ArgumentList.Add('-ProcessId'); [void]$psi.ArgumentList.Add((@($Pids) -join ',')) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    Set-HelperPriority $p
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill($true) } catch {}; return [pscustomobject]@{ ok = $false; sent = 0; consoles = @(); error = "timed out after $TimeoutSec s" } }
    $line = ($out.Result -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if ($line) { try { return ($line | ConvertFrom-Json) } catch {} }
    return [pscustomobject]@{ ok = $false; sent = 0; consoles = @(); error = (($err.Result + ' ' + $out.Result).Trim()) }
}

# Kill a workflow shell and its child processes (children first), never the Quest helpers.
function Stop-WorkflowTree {
    param([int] $Root)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $byParent = @{}
    foreach ($p in $all) {
        $pp = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($pp)) { $byParent[$pp] = [System.Collections.Generic.List[object]]::new() }
        $byParent[$pp].Add($p)
    }
    $rootProc = @($all | Where-Object { [int]$_.ProcessId -eq $Root }) | Select-Object -First 1
    if (-not $rootProc) { return 0 }
    $order = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue($rootProc)
    while ($queue.Count) {
        $cur = $queue.Dequeue()
        $order.Add($cur)
        if (-not $byParent.ContainsKey([int]$cur.ProcessId)) { continue }
        foreach ($c in $byParent[[int]$cur.ProcessId]) {
            # A reused parent PID: the child must be younger than the parent.
            if ($c.CreationDate -and $cur.CreationDate -and $c.CreationDate -lt $cur.CreationDate) { continue }
            $ccl = [string]$c.CommandLine
            if ($ccl -like '*\windows\quest\*' -or $ccl -like '*PlaylistLocalQuest*') { continue }
            if ([int]$c.ProcessId -eq $PID) { continue }
            $queue.Enqueue($c)
        }
    }
    $n = 0
    for ($i = $order.Count - 1; $i -ge 0; $i--) {
        try { Stop-Process -Id ([int]$order[$i].ProcessId) -Force -ErrorAction Stop; $n++ } catch {}
    }
    return $n
}

# Quest log lines written since -Since (local time stamps "yyyy-MM-dd HH:mm:ss ...").
function Get-QuestLogSince {
    param([DateTime] $Since)
    if (-not (Test-Path -LiteralPath $script:PlaylistQuestLog)) { return @() }
    $cut = $Since.ToString('yyyy-MM-dd HH:mm:ss')
    return @(Get-Content -LiteralPath $script:PlaylistQuestLog -Tail 400 -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -ge 19 -and [string]::CompareOrdinal($_.Substring(0, 19), $cut) -ge 0 })
}

function Test-PendingHistorySince {
    param([DateTime] $Since)
    return (Test-Path -LiteralPath $pendingHistoryPath) -and ((Get-Item -LiteralPath $pendingHistoryPath).LastWriteTime -ge $Since)
}

$clickAt = (Get-Date).AddSeconds(-1)
Write-PlaylistQuestLog 'Playlist stop: End session pressed on the Quest control page.'
Save-ShutdownStatus

# ---- What is running ----

$sessions = @(Get-PlaylistQuestSessions)
$pids = @(@($sessions | ForEach-Object { [int]$_.pid }) + @($WorkflowPid | Where-Object { $_ -gt 0 }) | Select-Object -Unique)
$companion = @(Get-PlaylistQuestCompanionProcesses)
$parts = @()
if ($sessions.Count) { $parts += ('3d_playlist_local ({0})' -f (@($sessions | ForEach-Object { $_.name }) -join ', ')) }
if ($companion.Count) { $parts += 'Loop Segments companion' }
Set-ShutdownStep -Name 'Session' -Result $(if ($parts.Count) { 'stopping ' + ($parts -join ' + ') } else { 'no workflow or companion running - Quest cleanup only' })

# 0. Helpers this run replaces.
foreach ($h in @(Get-PlaylistQuestHelperProcesses -Pattern '*-OpenControlPage*')) { try { Stop-Process -Id $h.ProcessId -Force } catch {} }
@(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { ([string]$_.CommandLine) -like '*Start-PlaylistLocalQuestSession.ps1*-CleanupWhenGone*' }) |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
foreach ($id in $pids) {
    foreach ($h in @(Get-PlaylistQuestHelperProcesses -Pattern '*-KeepAwakeSession*' | Where-Object { ([string]$_.CommandLine) -match "-ParentPid\s+$id\b" })) {
        try { Stop-Process -Id $h.ProcessId -Force } catch {}
    }
}

# 1. Quest apps reading the segments + configured players.
Set-ShutdownStep -Name 'Quest media apps' -Result 'stopping...' -Level running
$r = Invoke-ShutdownWatch -Arguments @('-StopMediaApps') -TimeoutSec 60
switch ($r.Code) {
    0 { Set-ShutdownStep -Name 'Quest media apps' -Result $(if ($r.Status) { $r.Status } else { 'done' }) }
    1 { Set-ShutdownStep -Name 'Quest media apps' -Result 'headset not on adb - skipped' -Level warn }
    -1 { Set-ShutdownStep -Name 'Quest media apps' -Result 'timed out' -Level bad }
    default { Set-ShutdownStep -Name 'Quest media apps' -Result ("failed (exit {0}){1}" -f $r.Code, $(if ($r.Status) { ": $($r.Status)" } else { '' })) -Level bad }
}

# 2. Workflows: Enter, then wait for each window to exit (it runs its own quit cleanup).
$k = Send-WorkflowEnter -Pids $pids
$targets = @(@(@($k.consoles) | Where-Object { $_ -and $_.ok } | ForEach-Object { [int]$_.pid }) + $pids | Select-Object -Unique)
if (-not $targets.Count) {
    Set-ShutdownStep -Name 'Workflows' -Result 'none running' -Level skip
} else {
    $enterAt = [DateTime]::UtcNow
    $who = @(@($k.consoles) | Where-Object { $_ -and $_.ok } | ForEach-Object { '{0} (pid {1})' -f $_.script, $_.pid }) -join ', '
    if (-not $k.ok) { $who = "Enter not sent ($($k.error))" }
    Set-ShutdownStep -Name 'Workflows' -Result "Enter sent to $who - waiting for exit..." -Level running
    $limit = 180
    try { if ($null -ne $cfg.questPlaylistEnterExitSec) { $limit = [int]$cfg.questPlaylistEnterExitSec } } catch {}
    $resent = $false
    # Enter not delivered (helper timed out / failed): try again after 5 s, up to 3 times, before
    # the usual 60 s resend - else the window just waits a minute for a key it never got.
    $quickTries = 0
    $lastTryAt = [DateTime]::UtcNow
    while ($true) {
        $alive = @($targets | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        $elapsed = ([DateTime]::UtcNow - $enterAt).TotalSeconds
        if (-not $alive.Count) { Set-ShutdownStep -Name 'Workflows' -Result ('{0}: exited ({1:0} s)' -f $who, $elapsed); break }
        if (-not $k.ok -and $quickTries -lt 3 -and ([DateTime]::UtcNow - $lastTryAt).TotalSeconds -ge 5) {
            $quickTries++
            $k = Send-WorkflowEnter -Pids $alive
            $lastTryAt = [DateTime]::UtcNow
            if ($k.ok) {
                $who = @(@($k.consoles) | Where-Object { $_ -and $_.ok } | ForEach-Object { '{0} (pid {1})' -f $_.script, $_.pid }) -join ', '
                Write-PlaylistQuestLog "Playlist stop: Enter sent on retry $quickTries ($who)."
                Set-ShutdownStep -Name 'Workflows' -Result "Enter sent to $who (retry $quickTries) - waiting for exit..." -Level running
                # The 60 s resend counts from the Enter that got through.
                $enterAt = [DateTime]::UtcNow
            } else {
                Write-PlaylistQuestLog "Playlist stop: Enter retry $quickTries not sent ($($k.error))."
            }
            continue
        }
        if (-not $resent -and $elapsed -ge 60) {
            $resent = $true
            [void](Send-WorkflowEnter -Pids $alive)
            Write-PlaylistQuestLog "Playlist stop: workflow still running after 60 s - Enter sent again (pid $($alive -join ', '))."
        }
        if ($limit -gt 0 -and $elapsed -ge $limit) {
            $n = 0
            foreach ($id in $alive) { $n += Stop-WorkflowTree -Root $id }
            Set-ShutdownStep -Name 'Workflows' -Result ("killed after {0} s (pid {1}, {2} process(es))" -f $limit, ($alive -join ', '), $n) -Level warn
            break
        }
        if ($limit -le 0 -and $elapsed -ge 600) {
            Set-ShutdownStep -Name 'Workflows' -Result ("still running (pid {0}); questPlaylistEnterExitSec=0 never kills it" -f ($alive -join ', ')) -Level warn
            break
        }
        Start-Sleep -Seconds 2
    }
}

# 4. Companion: its own quit does the Quest teardown (once).
$questDoneBy = ''
$companion = @(Get-PlaylistQuestCompanionProcesses)
if (-not $companion.Count) {
    Set-ShutdownStep -Name 'Companion' -Result 'not running' -Level skip
} else {
    # The XR page and questPlaylistHistoryOrigins need no step of their own: the companion's quit
    # cleans up every page in quest_tools' shared origin list (the XR page is registered when it
    # opens) and the configured origins.
    Sync-PlaylistXrOriginsToShared
    # a. Graceful close of its Chromium -> its normal quit.
    Set-ShutdownStep -Name 'Companion' -Result 'closing its Chromium (its quit cleans up the Quest, L:, phone)...' -Level running
    $closeAt = Get-Date
    $chrome = @($companion | Where-Object { $_.Name -eq 'chrome.exe' })
    foreach ($c in $chrome) { try { & taskkill.exe /PID ([int]$c.ProcessId) 2>&1 | Out-Null } catch {} }
    $forced = $false
    while (@(Get-PlaylistQuestCompanionProcesses | Where-Object { $_.Name -eq 'chrome.exe' }).Count) {
        if (((Get-Date) - $closeAt).TotalSeconds -ge 30) {
            foreach ($c in @(Get-PlaylistQuestCompanionProcesses | Where-Object { $_.Name -eq 'chrome.exe' })) { try { Stop-Process -Id $c.ProcessId -Force } catch {} }
            $forced = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $chrome.Count) {
        # Launcher shell without Chromium (still starting, or Chromium already gone): stop the shell.
        foreach ($c in $companion) { try { & taskkill.exe /PID ([int]$c.ProcessId) 2>&1 | Out-Null } catch {} }
    }
    # b. Its Quest step: "Cleanup: finished" in the log, or the after-quit helper's pending file.
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-QuestLogSince -Since $closeAt | Where-Object { $_ -match ' Cleanup: finished ' }).Count) { $questDoneBy = 'companion'; break }
        if (Test-PendingHistorySince -Since $closeAt) { $questDoneBy = 'helper'; break }
        if (-not @(Get-PlaylistQuestCompanionProcesses).Count -and ((Get-Date) - $closeAt).TotalSeconds -ge 20 -and
            -not @(Get-PlaylistQuestHelperProcesses -Pattern '*-ClearHistory*').Count) { break }
        Start-Sleep -Seconds 2
    }
    $how = if ($forced) { 'Chromium force-closed after 30 s' } else { 'Chromium closed' }
    switch ($questDoneBy) {
        'companion' { Set-ShutdownStep -Name 'Companion' -Result "$how; its quit cleaned up the Quest" }
        'helper' { Set-ShutdownStep -Name 'Companion' -Result "$how; its quit left the history delete to the after-quit helper (headset not worn)" -Level warn }
        default { Set-ShutdownStep -Name 'Companion' -Result "$how; no Quest cleanup from its quit seen - doing it here" -Level warn }
    }
}

# 5. Quest step when the companion did not do it.
if ($questDoneBy) {
    Set-ShutdownStep -Name 'Quest cleanup' -Result $(if ($questDoneBy -eq 'companion') { 'done by the companion quit' } else { 'after-quit helper (deletes when the headset is worn, then Wi-Fi off)' }) -Level skip
} elseif (Test-PendingHistorySince -Since $clickAt) {
    Set-ShutdownStep -Name 'Quest cleanup' -Result 'already handed to the after-quit helper' -Level skip
} else {
    Set-ShutdownStep -Name 'Quest cleanup' -Result 'tabs, history, sensor...' -Level running
    $cleanAt = (Get-Date).AddSeconds(-1)
    $h = Invoke-ShutdownWatch -Arguments (Get-PlaylistQuestHistoryArgs) -TimeoutSec 120
    switch ($h.Code) {
        0 { Set-ShutdownStep -Name 'Quest cleanup' -Result 'tabs closed, history entries deleted, sensor back on' }
        4 { Set-ShutdownStep -Name 'Quest cleanup' -Result 'tabs closed, sensor back on; history delete postponed until the headset is worn' -Level warn }
        1 { Set-ShutdownStep -Name 'Quest cleanup' -Result 'headset not on adb - the after-quit helper does it when it is back' -Level warn }
        -1 { Set-ShutdownStep -Name 'Quest cleanup' -Result 'timed out' -Level bad }
        default { Set-ShutdownStep -Name 'Quest cleanup' -Result "incomplete (exit $($h.Code)); see %TEMP%\loopsegments-quest-lantab.log" -Level bad }
    }
    if ($cfg.Contains('questWifiOffOnExit') -and $cfg.questWifiOffOnExit -eq $false) {
        Set-ShutdownStep -Name 'Quest Wi-Fi' -Result 'left on (questWifiOffOnExit=false)' -Level skip
    } elseif ($h.Code -eq 4 -or $h.Code -eq 1) {
        Set-ShutdownStep -Name 'Quest Wi-Fi' -Result 'left on: the after-quit helper needs it and switches it off after the history delete' -Level warn
    } elseif (@(Get-QuestLogSince -Since $cleanAt | Where-Object { $_ -match " Wi-Fi: switched the headset's Wi-Fi off" }).Count) {
        # The cleanup already did it; a second -WifiOff only waits ~10 s for a headset gone from adb.
        Set-ShutdownStep -Name 'Quest Wi-Fi' -Result 'off (by the Quest cleanup)'
    } else {
        $w = Invoke-ShutdownWatch -Arguments @('-WifiOff') -TimeoutSec 60
        switch ($w.Code) {
            0 { Set-ShutdownStep -Name 'Quest Wi-Fi' -Result 'off' }
            1 { Set-ShutdownStep -Name 'Quest Wi-Fi' -Result 'off (headset already gone from adb)' }
            default { Set-ShutdownStep -Name 'Quest Wi-Fi' -Result "not switched off (exit $($w.Code))" -Level bad }
        }
    }
}

# 6. Leftovers of a companion that died without its finish.
if (-not @(Get-PlaylistQuestCompanionProcesses).Count) {
    $orph = @(Get-PlaylistQuestOrphanSinks)
    foreach ($o in $orph) { try { Stop-Process -Id $o.ProcessId -Force } catch {} }
    if ($orph.Count) { Set-ShutdownStep -Name 'Leftovers' -Result ("stopped {0} orphaned companion REST sink(s) (pid {1})" -f $orph.Count, (@($orph | ForEach-Object { $_.ProcessId }) -join ', ')) }
}

$script:Status.state = 'done'
$script:Status.doneAt = (Get-Date -Format 'HH:mm:ss')
Save-ShutdownStatus
Write-PlaylistQuestLog 'Playlist stop: finished.'
exit 0
