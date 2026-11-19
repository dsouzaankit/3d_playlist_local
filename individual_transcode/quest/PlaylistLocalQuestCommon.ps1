# Shared by Start-PlaylistLocalQuestSession.ps1 (3d_playlist_local workflow start) and
# Invoke-PlaylistLocalQuestShutdown.ps1 (Quest control page Enter button), both in this folder.
# The Quest helpers they drive stay in ios_3d_loop_segments\windows\quest (adb discovery, Quest
# Browser DevTools, control page server, settings): found at $env:LOOPSEGMENTS_IOS_REPO, else
# P:\all_scripts\iOS apps\ios_3d_loop_segments. Dot-sourcing this loads its settings lib.

function Find-PlaylistQuestRepo {
    foreach ($r in @($env:LOOPSEGMENTS_IOS_REPO, 'P:\all_scripts\iOS apps\ios_3d_loop_segments')) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        if (Test-Path -LiteralPath (Join-Path $r 'windows\quest\Watch-LoopSegmentsQuestLanTab.ps1') -PathType Leaf) { return [System.IO.Path]::GetFullPath($r) }
    }
    return $null
}

$script:LsRepo = Find-PlaylistQuestRepo
if (-not $script:LsRepo) { throw 'ios_3d_loop_segments not found (set LOOPSEGMENTS_IOS_REPO).' }
# Child processes (control page server -> Enter run) find it the same way.
$env:LOOPSEGMENTS_IOS_REPO = $script:LsRepo
$script:LsWindowsDir = Join-Path $script:LsRepo 'windows'
$script:LsQuestDir = Join-Path $script:LsWindowsDir 'quest'
. (Join-Path $script:LsWindowsDir 'lib\LoopSegments-Windows.ps1')

$script:PlaylistQuestLog = Join-Path $env:TEMP 'loopsegments-quest-lantab.log'
# Workflow shells registered at workflow start: { sessions: [ { pid, name, started, startedUtc } ] }.
$script:PlaylistSessionPath = Join-Path $env:TEMP 'loopsegments-playlist-session.json'
# Enter button progress, shown by the control page.
$script:PlaylistShutdownPath = Join-Path $env:TEMP 'loopsegments-playlist-shutdown.json'

function Write-PlaylistQuestLog {
    param([string] $Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $script:PlaylistQuestLog -Value $line -Encoding utf8 } catch {}
    Write-Host "[quest] $Message"
}

function Get-PlaylistQuestPwsh {
    if (Get-Command Get-LoopSegmentsPwshExe -ErrorAction SilentlyContinue) { try { return (Get-LoopSegmentsPwshExe) } catch {} }
    return (Get-Process -Id $PID).Path
}

# Start a hidden pwsh -File <Script> <Arguments>; returns the process.
function Start-PlaylistQuestHidden {
    param([string] $Pwsh, [string] $Script, [string[]] $Arguments = @())
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Pwsh
    foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}

# The companion extension's lan_config.json (phone address the companion found), if any.
function Get-PlaylistQuestLanConfigPath {
    $p = Join-Path $env:LOCALAPPDATA 'pcloud_web_companion\extension\lan_config.json'
    if (Test-Path -LiteralPath $p) { return $p }
    return ''
}

# Phone LAN page URL: lan_config.json, else phoneLanHost from loop-segments-windows.json. '' = none.
function Get-PlaylistQuestPhoneUrl {
    param([string] $LanConfig)
    if ($LanConfig) {
        try {
            $c = Get-Content -LiteralPath $LanConfig -Raw | ConvertFrom-Json
            $h = ([string]$c.phoneLanHost).Trim()
            $pt = 8765
            if ($c.PSObject.Properties['lanPort'] -and [int]$c.lanPort -gt 0) { $pt = [int]$c.lanPort }
            if ($h) { return "http://${h}:${pt}/" }
        } catch {}
    }
    try {
        $h = ([string](Get-LoopSegmentsWindowsSettings).phoneLanHost).Trim()
        if ($h) { return "http://${h}:8765/" }
    } catch {}
    return ''
}

# PID of the running control page server (%TEMP%\loopsegments-quest-control.json), or $null.
function Get-PlaylistQuestControlServerPid {
    $state = Join-Path $env:TEMP 'loopsegments-quest-control.json'
    if (-not (Test-Path -LiteralPath $state)) { return $null }
    try {
        $c = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
        if (Get-Process -Id ([int]$c.pid) -ErrorAction SilentlyContinue) { return [int]$c.pid }
    } catch {}
    return $null
}

# Watch-LoopSegmentsQuestLanTab.ps1 processes whose command line is -like $Pattern.
function Get-PlaylistQuestHelperProcesses {
    param([string] $Pattern = '*')
    return @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $c = [string]$_.CommandLine; $c -like '*Watch-LoopSegmentsQuestLanTab.ps1*' -and $c -like $Pattern })
}

function Get-PlaylistQuestProcessStart {
    param([int] $ProcessId)
    # Ticks with a prefix: ConvertFrom-Json would turn an ISO date string into a DateTime.
    try { return 't' + (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().Ticks } catch { return '' }
}

# Loopback sign-in token for the PC browser tab (Serve-QuestControlPage.ps1 /pc?t=<token>). Kept
# across workflow starts so tabs opened earlier stay signed in.
function Get-PlaylistQuestPcToken {
    $path = Join-Path $env:TEMP 'loopsegments-quest-control-pctoken.txt'
    try { $t = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim(); if ($t -match '^[A-Za-z0-9]{32,}$') { return $t } } catch {}
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $t = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    Set-Content -LiteralPath $path -Value $t -Encoding ascii -NoNewline
    return $t
}

# ---- PC Chromium for the control page (own fresh profile, like the companion's Playwright Chromium) ----

$script:PlaylistChromiumProfile = Join-Path $env:LOCALAPPDATA 'loopsegments-quest-control-chromium'

# Playwright's Chromium (the companion's browser): LOOP_SEGMENTS_PLAYWRIGHT_BROWSERS, else
# %LOCALAPPDATA%\ms-playwright, newest chromium-<rev>. $null when not installed.
function Find-PlaylistQuestChromium {
    $roots = @($env:LOOP_SEGMENTS_PLAYWRIGHT_BROWSERS, (Join-Path $env:LOCALAPPDATA 'ms-playwright')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($r in $roots) {
        $exe = Get-ChildItem -LiteralPath $r -Directory -Filter 'chromium-*' -ErrorAction SilentlyContinue |
            Sort-Object { $n = 0; [void][int]::TryParse(($_.Name -replace '^chromium-', ''), [ref]$n); $n } -Descending |
            ForEach-Object { Join-Path $_.FullName 'chrome-win64\chrome.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($exe) { return $exe }
    }
    return $null
}

# chrome.exe processes on the control page profile (browser and its children).
function Get-PlaylistQuestChromiumProcesses {
    $needle = ($script:PlaylistChromiumProfile -replace '\\', '/').ToLowerInvariant()
    return @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and (([string]$_.CommandLine) -replace '\\', '/').ToLowerInvariant().Contains($needle) })
}

# Open -Url in the control page Chromium: a new window on a freshly wiped profile, or a new tab
# when it is already open (another workflow). Returns 'chromium' / 'tab' or $null (not installed).
function Open-PlaylistQuestPcChromium {
    param([string] $Url)
    $exe = Find-PlaylistQuestChromium
    if (-not $exe) { return $null }
    $running = @(Get-PlaylistQuestChromiumProcesses).Count -gt 0
    if (-not $running) {
        Remove-Item -LiteralPath $script:PlaylistChromiumProfile -Recurse -Force -ErrorAction SilentlyContinue
        [void](New-Item -ItemType Directory -Path $script:PlaylistChromiumProfile -Force)
    }
    $prof = $script:PlaylistChromiumProfile -replace '\\', '/'
    # --disable-features=LaunchOnStartup: no "Begin browsing instantly: Chromium can now launch when
    # Windows starts" infobar (chrome\browser\startup\startup_launch_manager.cc; --disable-infobars
    # does not cover it).
    $argLine = ('--user-data-dir="{0}" --no-first-run --no-default-browser-check --disable-infobars --disable-features=LaunchOnStartup --disable-restore-session-state ' +
        '--disable-session-crashed-bubble --force-dark-mode --proxy-bypass-list="<local>;127.0.0.1;localhost" "{1}"') -f $prof, $Url
    $psi = [System.Diagnostics.ProcessStartInfo]::new($exe, $argLine)
    $psi.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($psi)
    if ($running) { return 'tab' }
    return 'chromium'
}

# Close the control page Chromium (whole browser) and delete its profile.
function Stop-PlaylistQuestPcChromium {
    $procs = @(Get-PlaylistQuestChromiumProcesses)
    foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {} }
    for ($i = 0; $i -lt 20 -and @(Get-PlaylistQuestChromiumProcesses).Count; $i++) { Start-Sleep -Milliseconds 250 }
    Remove-Item -LiteralPath $script:PlaylistChromiumProfile -Recurse -Force -ErrorAction SilentlyContinue
    return $procs.Count
}

# ---- Shared by the end-session run and the natural-end cleanup ----

# Phone LAN URL for -ClearHistory (it needs one), else a placeholder: the watcher adds the control
# page origin itself.
function Get-PlaylistQuestHistoryUrl {
    $url = Get-PlaylistQuestPhoneUrl -LanConfig (Get-PlaylistQuestLanConfigPath)
    if ($url) { return $url }
    $port = 18766
    try { $p = [int](Get-LoopSegmentsWindowsSettings).questControlPort; if ($p -gt 0) { $port = $p } } catch {}
    return "http://127.0.0.1:$port/"
}

function Get-PlaylistQuestExtraOrigins {
    $cfg = Get-LoopSegmentsWindowsSettings
    if (-not ($cfg.Contains('questPlaylistHistoryOrigins') -and $null -ne $cfg.questPlaylistHistoryOrigins)) { return @() }
    return @(@($cfg.questPlaylistHistoryOrigins) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
}

# Watcher arguments for the Quest step (tabs, history, sensor on; Wi-Fi off per questWifiOffOnExit),
# with the same settings as the companion's quit: questCloseLanTabsOnExit / questClearHistoryOnExit.
function Get-PlaylistQuestHistoryArgs {
    $cfg = Get-LoopSegmentsWindowsSettings
    $a = @('-Url', (Get-PlaylistQuestHistoryUrl), '-ClearHistory')
    if (-not ($cfg.Contains('questCloseLanTabsOnExit') -and $cfg.questCloseLanTabsOnExit -eq $false)) { $a += '-CloseLanTabs' }
    if ($cfg.Contains('questClearHistoryOnExit') -and $cfg.questClearHistoryOnExit -eq $false) { $a += '-SkipHistoryClear' }
    $a += '-EnableProximityAfter'
    $extra = @(Get-PlaylistQuestExtraOrigins)
    if ($extra.Count) { $a += '-ExtraOrigins'; $a += ($extra -join ',') }
    return $a
}

# The running companion: its launcher shell or its Chromium (profile ...\pcloud_web_companion\
# chromium-profile, main process). Not the REST log sink / exit watchdog, which can outlive it.
function Get-PlaylistQuestCompanionProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe' OR Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $c = [string]$_.CommandLine
                ($_.Name -ne 'chrome.exe' -and $c -match '(?i)pcloud_web_companion[\\/]+(Run-PCloudWebCompanion|_run_chromium)\.ps1') -or
                ($_.Name -eq 'chrome.exe' -and $c -notlike '*--type=*' -and $c -match '(?i)pcloud_web_companion[\\/]+chromium-profile')
            })
}

# Companion REST log sinks whose -CompanionPid is gone (left by a companion that died without its finish).
function Get-PlaylistQuestOrphanSinks {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $c = [string]$_.CommandLine
                if ($c -notlike '*_rest_log_sink.ps1*') { return $false }
                if ($c -match '-CompanionPid\s+(\d+)') { return -not (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue) }
                return $false
            })
}

# Registered workflow shells that are still running (same PID and start time).
function Get-PlaylistQuestSessions {
    if (-not (Test-Path -LiteralPath $script:PlaylistSessionPath)) { return @() }
    $list = @()
    try { $list = @((Get-Content -LiteralPath $script:PlaylistSessionPath -Raw | ConvertFrom-Json).sessions) } catch { return @() }
    return @($list | Where-Object { $_ -and [int]$_.pid -gt 0 -and (Get-PlaylistQuestProcessStart -ProcessId ([int]$_.pid)) -eq [string]$_.started })
}

function Register-PlaylistQuestSession {
    param([int] $WorkflowPid, [string] $WorkflowName)
    $keep = @(Get-PlaylistQuestSessions | Where-Object { [int]$_.pid -ne $WorkflowPid })
    # shutdownScript: the control page's Enter button runs this workflow's copy (media folders keep
    # their own synced 3d_playlist_local).
    $entry = [pscustomobject]@{ pid = $WorkflowPid; name = $WorkflowName; started = (Get-PlaylistQuestProcessStart -ProcessId $WorkflowPid)
        registeredUtc = [DateTime]::UtcNow.ToString('o'); shutdownScript = (Join-Path $PSScriptRoot 'Invoke-PlaylistLocalQuestShutdown.ps1') }
    try { @{ sessions = @($keep + $entry) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:PlaylistSessionPath -Encoding utf8 } catch {}
}
