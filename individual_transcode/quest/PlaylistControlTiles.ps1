# 3d_playlist_local tiles on the shared Quest control page (quest_tools QuestControlHost.ps1).
# Registered by Start-PlaylistLocalQuestSession.ps1 for as long as a workflow runs
# (Register-QuestControlTiles -Owner playlist). The host dot-sources this file once and keeps the
# returned hashtable; everything here is prefixed PlaylistTiles so it cannot clash with the host or
# another project's tiles.
#
#   Session Control  Space: presses Space in the workflow's PowerShell window (pause / resume the
#                    leaf DLNA export; Send-PlaylistLocalSpaceKey.ps1). Badge: paused / playing,
#                    read from the export ffmpeg processes. End session: Invoke-PlaylistLocalQuestShutdown.ps1,
#                    detached (progress in %TEMP%\loopsegments-playlist-shutdown.json).
#   Segment bitrate  what the next minute segments are encoded at, from the page's PC -> Quest
#                    speed test (80% of the result, 5-80 Mbps; ..\Get-QuestLanSegmentBitrate.ps1).

$script:PlaylistTilesDir = $PSScriptRoot
$script:PlaylistTilesSessionPath = Join-Path $env:TEMP 'loopsegments-playlist-session.json'
$script:PlaylistTilesShutdownPath = Join-Path $env:TEMP 'loopsegments-playlist-shutdown.json'
$script:PlaylistTilesSpaceScript = Join-Path $PSScriptRoot 'Send-PlaylistLocalSpaceKey.ps1'
$script:PlaylistTilesShutdownScript = Join-Path $PSScriptRoot 'Invoke-PlaylistLocalQuestShutdown.ps1'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Get-QuestLanSegmentBitrate.ps1')

# Runs the key helper in its own process (it detaches from its console to attach to the target's)
# and waits for it: a few seconds at most. Returns the helper's JSON object.
function Invoke-PlaylistTilesSpace {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:PlaylistTilesSpaceScript)) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(20000)) {
        try { $proc.Kill($true) } catch {}
        Write-QuestControlLog 'PLAYLIST_SPACE timed out'
        return [ordered]@{ ok = $false; sent = 0; error = 'timed out' }
    }
    $text = ($outTask.Result -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    $r = $null
    if ($text) { try { $r = $text | ConvertFrom-Json } catch {} }
    if (-not $r) {
        $e = ($errTask.Result + ' ' + $outTask.Result).Trim()
        if ($e.Length -gt 300) { $e = $e.Substring(0, 300) }
        $r = [pscustomobject]@{ ok = $false; sent = 0; error = $(if ($e) { $e } else { "exit $($proc.ExitCode)" }) }
    }
    $who = @(@($r.PSObject.Properties['consoles'] | ForEach-Object { $_.Value }) | Where-Object { $_ } | ForEach-Object { '{0} pid {1}' -f $_.script, $_.pid }) -join ', '
    Write-QuestControlLog ("PLAYLIST_SPACE sent={0} {1}{2}" -f $r.sent, $who, $(if ($r.PSObject.Properties['error'] -and $r.error) { " error: $($r.error)" } else { '' }))
    return $r
}

# Paused / playing, read from the leaf DLNA export ffmpeg processes themselves (command line has
# 3d_op_, as Test-FfmpegCommandLineIsLeafDlnaExport): Space there runs NtSuspendProcess, which leaves
# every thread waiting with WaitReason Suspended. The workflow's own pause flag lives in its process,
# so this is the state a Space from anywhere (PC keyboard or this page) left.
# state = 'paused' | 'playing' | 'idle' (no export running).
function Get-PlaylistTilesPlayback {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'ffmpeg.exe'" -ErrorAction SilentlyContinue |
            Where-Object { ([string]$_.CommandLine) -like '*3d_op_*' })
    if ($procs.Count -eq 0) { return [ordered]@{ state = 'idle'; pids = @() } }
    $paused = 0
    $seen = 0
    foreach ($p in $procs) {
        $proc = $null
        try {
            $proc = Get-Process -Id ([int]$p.ProcessId) -ErrorAction Stop
            $threads = @($proc.Threads)
            if ($threads.Count -eq 0) { continue }
            $seen++
            $allSuspended = $true
            foreach ($t in $threads) {
                $susp = $false
                try { $susp = ($t.ThreadState -eq [System.Diagnostics.ThreadState]::Wait) -and ($t.WaitReason -eq [System.Diagnostics.ThreadWaitReason]::Suspended) } catch {}
                if (-not $susp) { $allSuspended = $false; break }
            }
            if ($allSuspended) { $paused++ }
        } catch {
        } finally { if ($proc) { $proc.Dispose() } }
    }
    $pids = @($procs | ForEach-Object { [int]$_.ProcessId })
    if ($seen -eq 0) { return [ordered]@{ state = 'idle'; pids = @() } }
    return [ordered]@{ state = $(if ($paused -eq $seen) { 'paused' } else { 'playing' }); pids = $pids }
}

# Each workflow registers its own copy of the shutdown script (media folders keep their own synced
# 3d_playlist_local). Newest running one wins, else the one next to this file.
function Get-PlaylistTilesShutdownScript {
    try {
        $list = @((Get-Content -LiteralPath $script:PlaylistTilesSessionPath -Raw -ErrorAction Stop | ConvertFrom-Json).sessions)
        [array]::Reverse($list)
        foreach ($e in $list) {
            if (-not $e -or -not $e.PSObject.Properties['shutdownScript']) { continue }
            if (-not (Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue)) { continue }
            if (Test-Path -LiteralPath ([string]$e.shutdownScript) -PathType Leaf) { return [string]$e.shutdownScript }
        }
    } catch {}
    if (Test-Path -LiteralPath $script:PlaylistTilesShutdownScript -PathType Leaf) { return $script:PlaylistTilesShutdownScript }
    return $null
}

function Get-PlaylistTilesStop {
    if (-not (Test-Path -LiteralPath $script:PlaylistTilesShutdownPath)) { return $null }
    try { $j = Get-Content -LiteralPath $script:PlaylistTilesShutdownPath -Raw | ConvertFrom-Json } catch { return $null }
    # A run that died mid-way (killed, PC restarted) is not 'running' any more.
    if ($j.state -eq 'running' -and -not (Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue)) { $j.state = 'stopped' }
    return $j
}

# Detached from the host on purpose (WMI Win32_Process.Create, so its parent is not the host): the
# workflow exits during the run, the host may stop with it, and the run goes on with the Quest steps.
function Start-PlaylistTilesShutdown {
    $cur = Get-PlaylistTilesStop
    if ($cur -and $cur.state -eq 'running') { return 'running' }
    $shutdownPath = Get-PlaylistTilesShutdownScript
    if (-not $shutdownPath) { Write-QuestControlLog 'PLAYLIST_ENTER no Invoke-PlaylistLocalQuestShutdown.ps1 found'; return 'missing' }
    $exe = (Get-Process -Id $PID).Path
    $cmd = '"{0}" -NoProfile -NoLogo -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $exe, $shutdownPath
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; ProcessStartupInformation = $startup }
    if ($r.ReturnValue -ne 0) { Write-QuestControlLog "PLAYLIST_ENTER Win32_Process.Create failed ($($r.ReturnValue))"; return 'missing' }
    $newPid = [int]$r.ProcessId
    try { @{ pid = $newPid; state = 'running'; startedAt = (Get-Date -Format 'HH:mm:ss'); steps = @() } | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:PlaylistTilesShutdownPath -Encoding utf8 } catch {}
    Write-QuestControlLog "PLAYLIST_ENTER started End session (pid $newPid, detached, $shutdownPath)"
    return 'started'
}

# What End session would stop: registered workflows still running, and the Loop Segments companion
# (its launcher shell or its Chromium; not its REST log sink, which can outlive it).
function Get-PlaylistTilesParts {
    $wf = @()
    try {
        foreach ($e in @((Get-Content -LiteralPath $script:PlaylistTilesSessionPath -Raw -ErrorAction Stop | ConvertFrom-Json).sessions)) {
            if ($e -and (Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue)) { $wf += [string]$e.name }
        }
    } catch {}
    $comp = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe' OR Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $c = [string]$_.CommandLine
                ($_.Name -ne 'chrome.exe' -and $c -match '(?i)pcloud_web_companion[\\/]+(Run-PCloudWebCompanion|_run_chromium)\.ps1') -or
                ($_.Name -eq 'chrome.exe' -and $c -notlike '*--type=*' -and $c -match '(?i)pcloud_web_companion[\\/]+chromium-profile')
            }).Count -gt 0
    return [ordered]@{ workflows = @($wf); companion = $comp }
}

function Get-PlaylistTilesBitrate {
    $q = Get-QuestLanSegmentBitrateMbps
    if (-not $q) { return $null }
    return [ordered]@{ mbps = $q.Mbps; measuredMbps = $q.MeasuredMbps; ageMin = $q.AgeMinutes }
}

$script:PlaylistTilesHtml = @'
    <section>
      <h2>Session Control</h2>
      <div class="buttons">
        <button id="plSpace" class="primary">Space: pause / resume export</button>
        <span id="plState" class="pstate" role="status" aria-live="polite"></span>
        <button id="plEnter" class="danger">End session: stop all</button>
      </div>
      <dl style="margin-top:12px">
        <dt>Segment bitrate</dt><dd id="plRate">-</dd>
      </dl>
      <div id="plParts" class="msg"></div>
      <div id="plMsg" class="msg" role="status" aria-live="polite"></div>
      <pre id="plStop" hidden></pre>
      <p class="note">Space presses Space once in the 3d_playlist_local PowerShell window on the PC (run_batch_*.ps1 / Run-TranscodeOrchestrator.ps1), the same as pressing it there: while a clip runs it pauses or resumes the leaf DLNA export. The window does not need focus.</p>
      <p class="note">Segment bitrate: the next minute segments are encoded at 80% of the PC &rarr; Quest result, 5-80 Mbps (the Intel AV1 encoder turns blocky near 100M).</p>
      <p class="note">End session stops whatever is running, in this order, and skips what is not: closes the XR page; presses Enter in every 3d_playlist_local window and waits for it to exit (killed after a few minutes); closes the Loop Segments PC companion's Chromium, so its normal quit runs (Quest tabs, history, SKYBOX, sensor, Wi-Fi off, the phone mount, iPhone Home). Without the companion it cleans up the headset itself: closes these tabs, deletes their history, turns the sensor back on, switches the Wi-Fi off. The Quest history is deleted once either way.</p>
    </section>
'@

$script:PlaylistTilesScript = @'
  const { $, onQuest } = QC;

  // End session progress; returns true while it runs.
  function renderStop(j) {
    const pre = $('plStop'), b = $('plEnter');
    if (!j) { pre.hidden = true; b.disabled = false; return false; }
    const running = j.state === 'running';
    b.disabled = running;
    const mark = { ok: 'ok  ', warn: 'warn', bad: 'FAIL', running: '... ', skip: '--  ' };
    const lines = ['End session ' + (running ? 'running' : j.state) + ' (started ' + j.startedAt + (j.doneAt ? ', done ' + j.doneAt : '') + ')'];
    (j.steps || []).forEach(st => lines.push((mark[st.level] || '    ') + ' ' + st.name + ': ' + st.result));
    pre.textContent = lines.join('\n');
    pre.hidden = false;
    return running;
  }

  // After End session: on the PC the tab closes itself (one history entry, so the browser allows
  // it). On the Quest the cleanup's history step closes it within seconds: it keeps one tab open,
  // which Quest Browser's History list needs, so closing it from here could leave no tab.
  function closeOwnTab() {
    if (onQuest) { $('plMsg').textContent += ' (closed by the Quest cleanup in a few seconds)'; return; }
    setTimeout(() => {
      window.close();
      setTimeout(() => { $('plMsg').textContent = 'End session started. The browser did not let this tab close itself: close it by hand.'; }, 600);
    }, 1200);
  }

  // Paused / playing badge + button label. Returns true while an export ffmpeg runs.
  function renderPlayback(p) {
    const st = (p && p.state) || 'idle', b = $('plSpace'), e = $('plState');
    b.disabled = false;
    if (st === 'paused') { e.textContent = '⏸ Paused'; e.className = 'pstate paused'; b.textContent = '▶ Space: resume export'; }
    else if (st === 'playing') { e.textContent = '▶ Playing'; e.className = 'pstate playing'; b.textContent = '⏸ Space: pause export'; }
    else { e.textContent = 'No export running'; e.className = 'pstate'; b.textContent = 'Space: pause / resume export'; }
    return st !== 'idle';
  }

  function renderParts(p) {
    const list = [];
    if (p && p.workflows && p.workflows.length) list.push('3d_playlist_local (' + p.workflows.join(', ') + ')');
    if (p && p.companion) list.push('Loop Segments companion');
    $('plParts').textContent = 'End session stops: ' + (list.length ? list.join(' + ') : 'nothing running: Quest cleanup only');
  }

  function renderRate(r) {
    $('plRate').textContent = r ? (r.mbps + ' Mbps (80% of ' + Number(r.measuredMbps).toFixed(1) + ' Mbps, 5-80; measured ' + r.ageMin + ' min ago)') : 'no PC -> Quest result in the last 12 h (fallback rate)';
  }

  QC.register('playlist', (s) => {
    s = s || {};
    const stopRunning = renderStop(s.stop);
    renderParts(s.session);
    renderRate(s.bitrate);
    const exporting = renderPlayback(s.playback);
    // While an export runs, poll faster so Space pressed on the PC keyboard shows up here too.
    return stopRunning ? 1500 : (exporting ? 3000 : 10000);
  });

  $('plEnter').addEventListener('click', async () => {
    const b = $('plEnter'), m = $('plMsg');
    b.disabled = true; m.textContent = 'Starting End session...'; m.className = 'msg warn';
    const r = await QC.post('playlist/enter');
    if (r.ok) {
      m.textContent = 'End session started at ' + new Date().toLocaleTimeString() + '. This tab closes now.'; m.className = 'msg ok';
      closeOwnTab();
    } else { m.textContent = 'Not started: ' + (r.json.error || ('HTTP ' + r.status)) + '.'; m.className = 'msg bad'; b.disabled = false; }
    QC.schedule(800);
  });

  $('plSpace').addEventListener('click', async () => {
    const b = $('plSpace'), m = $('plMsg');
    b.disabled = true; m.textContent = 'Pressing Space...'; m.className = 'msg warn';
    const r = await QC.post('playlist/space');
    const t = new Date().toLocaleTimeString();
    if (r.ok && r.json.ok) {
      const who = (r.json.consoles || []).filter(c => c.ok).map(c => c.script + ' (pid ' + c.pid + ')').join(', ');
      m.textContent = 'Space sent at ' + t + ' to ' + who + '.'; m.className = 'msg ok';
    } else { m.textContent = 'Not sent at ' + t + ': ' + (r.json.error || ('HTTP ' + r.status)) + '.'; m.className = 'msg bad'; }
    b.disabled = false;
    // The workflow reads the key on its next poll: refresh the badge shortly after.
    QC.schedule(1200);
  });
'@

@{
    Label   = '3d_playlist_local'
    Tiles   = @(@{ Column = 0; Order = 20; Html = $script:PlaylistTilesHtml })
    Script  = $script:PlaylistTilesScript
    Status  = {
        [ordered]@{
            stop     = (Get-PlaylistTilesStop)
            session  = (Get-PlaylistTilesParts)
            playback = (Get-PlaylistTilesPlayback)
            bitrate  = (Get-PlaylistTilesBitrate)
        }
    }
    Routes  = @{
        '/playlist/space' = {
            param($Ctx)
            $r = Invoke-PlaylistTilesSpace
            @{ Code = $(if ($r.ok) { 200 } else { 409 }); Body = $r }
        }
        '/playlist/enter' = {
            param($Ctx)
            switch (Start-PlaylistTilesShutdown) {
                'started' { @{ Code = 202; Body = @{ ok = $true; action = 'playlist-enter'; state = 'running' } } }
                'missing' { @{ Code = 409; Body = @{ ok = $false; error = '3d_playlist_local Invoke-PlaylistLocalQuestShutdown.ps1 not found' } } }
                default { @{ Code = 409; Body = @{ ok = $false; error = 'End session is already running' } } }
            }
        }
    }
    # Older 3d_playlist_local copies (media folders not synced yet) read the result with its bitrate
    # from the file the control page used to write.
    OnSpeedTest = { param($Result) Save-QuestLanLegacyResult -Result $Result }
}
