# Shared by Start-PlaylistLocalQuestSession.ps1 (3d_playlist_local workflow start) and
# Invoke-PlaylistLocalQuestShutdown.ps1 (Quest control page Enter button), both in this folder.
# The Quest helpers they drive stay in ios_3d_loop_segments\windows\quest (adb discovery, Quest
# Browser DevTools, control page server, settings): found at $env:LOOPSEGMENTS_IOS_REPO, else
# <scripts root>\iOS apps\ios_3d_loop_segments (ALL_SCRIPTS_ROOT), then legacy P:. Dot-sourcing this loads its settings lib.
# The generic headset layer (adb, finding the headset, sensor, Wi-Fi, Quest Browser DevTools) is the
# quest_tools repo, which Loop Segments' scripts load too: $env:QUEST_TOOLS_REPO, else
# <scripts root>\quest_tools, else a quest_tools folder next to this repo. Dot-sourcing this loads it
# (Find-QuestAdbExe, Invoke-Adb, Get-QuestWakefulness, Write-QuestLog, ...).

function Find-PlaylistQuestRepo {
    foreach ($r in @($env:LOOPSEGMENTS_IOS_REPO, $(if ($env:ALL_SCRIPTS_ROOT) { Join-Path $env:ALL_SCRIPTS_ROOT 'iOS apps\ios_3d_loop_segments' }), 'P:\all_scripts\iOS apps\ios_3d_loop_segments')) {
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

# Same order as Loop Segments' windows\quest\QuestToolsPath.ps1, so both use one checkout (shared
# %TEMP% state, one adb server).
function Find-PlaylistQuestToolsRepo {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($env:QUEST_TOOLS_REPO) { $candidates.Add($env:QUEST_TOOLS_REPO) }
    if ($env:ALL_SCRIPTS_ROOT) { $candidates.Add((Join-Path $env:ALL_SCRIPTS_ROOT 'quest_tools')) }
    $d = $PSScriptRoot
    while ($d) { $candidates.Add((Join-Path $d 'quest_tools')); $d = Split-Path -Parent $d }
    $candidates.Add('P:\all_scripts\quest_tools')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'QuestTools.ps1') -PathType Leaf)) { return [System.IO.Path]::GetFullPath($c) }
    }
    return $null
}

$script:QuestToolsRepo = Find-PlaylistQuestToolsRepo
if (-not $script:QuestToolsRepo) { throw 'quest_tools not found (set QUEST_TOOLS_REPO).' }
$env:QUEST_TOOLS_REPO = $script:QuestToolsRepo
. (Join-Path $script:QuestToolsRepo 'QuestTools.ps1')
try {
    $qtCfg = Get-LoopSegmentsWindowsSettings
    Initialize-QuestTools -AdbExe ([string]$qtCfg.questAdbExe) -Serial ([string]$qtCfg.questAdbSerial)
} catch {}

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

# Loopback sign-in token for a PC browser tab (Serve-QuestControlPage.ps1 /pc?t=<token>; the workflow
# window prints that link). Kept across workflow starts so tabs opened earlier stay signed in. The
# hook (individual_transcode\Start-PlaylistQuestSession.ps1) writes the same file the same way.
function Get-PlaylistQuestPcToken {
    $path = Join-Path $env:TEMP 'loopsegments-quest-control-pctoken.txt'
    try { $t = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim(); if ($t -match '^[A-Za-z0-9]{32,}$') { return $t } } catch {}
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $t = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    Set-Content -LiteralPath $path -Value $t -Encoding ascii -NoNewline
    return $t
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

# Watcher arguments for the Quest step (tabs, history, sensor on; Wi-Fi off per questWifiOffOnExit),
# with the same settings as the companion's quit: questCloseLanTabsOnExit / questClearHistoryOnExit.
# No origins of its own: the watcher covers every page in quest_tools' shared origin list (the XR
# page is registered when it opens) and questPlaylistHistoryOrigins from the config.
function Get-PlaylistQuestHistoryArgs {
    $cfg = Get-LoopSegmentsWindowsSettings
    Sync-PlaylistXrOriginsToShared
    $a = @('-Url', (Get-PlaylistQuestHistoryUrl), '-ClearHistory')
    if (-not ($cfg.Contains('questCloseLanTabsOnExit') -and $cfg.questCloseLanTabsOnExit -eq $false)) { $a += '-CloseLanTabs' }
    if ($cfg.Contains('questClearHistoryOnExit') -and $cfg.questClearHistoryOnExit -eq $false) { $a += '-SkipHistoryClear' }
    $a += '-EnableProximityAfter'
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

# ---- adb (Start-PlaylistLocalQuestXr.ps1, Close-PlaylistLocalQuestXrTabs.ps1) ----
# quest_tools' Find-QuestAdbExe / Invoke-Adb / Get-QuestWakefulness ($script:Adb = Find-QuestAdbExe
# first). Only reads `adb devices`: finding the headset (adb connect, mDNS, adb server restart) is left
# to the keep-awake helper the session starts.

# Online headset serial (questAdbSerial when set, else the first device), or $null.
function Get-PlaylistQuestSerial {
    $r = Invoke-Adb -Arguments @('devices')
    $serials = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^(\S+)\s+device\s*$' } | ForEach-Object { ($_ -split '\s+')[0] })
    $want = ([string](Get-LoopSegmentsWindowsSettings).questAdbSerial).Trim()
    if ($want) { return @($serials | Where-Object { $_ -eq $want } | Select-Object -First 1) }
    return @($serials | Select-Object -First 1)
}

# ---- Quest XR page (individual_transcode\xr, Start-PlaylistLocalQuestXr.ps1) ----

# What the workflow start opens on the headset: 'xr' (default: the XR page in Quest Browser, served
# from this PC) or 'none'. $env:PLAYLIST_QUEST_PLAYER, else questPlaylistPlayer in
# loop-segments-windows.json. Anything else (e.g. a leftover 'skybox': SKYBOX VR Player as the player
# was removed 2026-11-23) = 'xr'.
function Get-PlaylistQuestPlayer {
    $raw = [string]$env:PLAYLIST_QUEST_PLAYER
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $cfg = Get-LoopSegmentsWindowsSettings
        if ($cfg.Contains('questPlaylistPlayer') -and $cfg.questPlaylistPlayer) { $raw = [string]$cfg.questPlaylistPlayer }
    }
    if (([string]$raw).Trim().ToLowerInvariant() -eq 'none') { return 'none' }
    return 'xr'
}

# Port (questPlaylistXrPort, default 18768 = control page 18766 + 2) and host mode
# ($env:PLAYLIST_XR_HOST, else questPlaylistXrHost): 'auto' (default) = this PC's name when the headset
# resolves it to this PC, else its LAN IPv4; 'ip' = always the IPv4; anything else = that host name.
function Get-PlaylistXrSettings {
    $cfg = Get-LoopSegmentsWindowsSettings
    $port = 18768
    try { if ($cfg.Contains('questPlaylistXrPort') -and [int]$cfg.questPlaylistXrPort -gt 0) { $port = [int]$cfg.questPlaylistXrPort } } catch {}
    $hostMode = [string]$env:PLAYLIST_XR_HOST
    if ([string]::IsNullOrWhiteSpace($hostMode) -and $cfg.Contains('questPlaylistXrHost')) { $hostMode = [string]$cfg.questPlaylistXrHost }
    if ([string]::IsNullOrWhiteSpace($hostMode)) { $hostMode = 'auto' }
    return [pscustomobject]@{ Port = $port; HostMode = $hostMode.Trim() }
}

# XR page origins opened on the headset go into quest_tools' shared origin list under this owner;
# every Quest cleanup (this repo's quit, End session, the Loop Segments companion's quit, the
# after-quit helper) closes their tabs and deletes their history.
$script:PlaylistXrOwner = '3d_playlist_local-xr'
# Older list (before the shared one; older 3d_playlist_local copies still write it): moved into the
# shared list by Sync-PlaylistXrOriginsToShared.
$script:PlaylistXrOriginsPath = Join-Path $env:TEMP 'playlist-xr-origins.json'

function Add-PlaylistXrSavedOrigin {
    param([string] $Origin)
    if (-not $Origin) { return }
    Register-QuestBrowserOrigin -Origin $Origin -Owner $script:PlaylistXrOwner
}

# XR origins an older copy saved in %TEMP%\playlist-xr-origins.json: register them, drop the file.
function Sync-PlaylistXrOriginsToShared {
    if (-not (Test-Path -LiteralPath $script:PlaylistXrOriginsPath)) { return }
    $old = @()
    try { $old = @((Get-Content -LiteralPath $script:PlaylistXrOriginsPath -Raw -ErrorAction Stop | ConvertFrom-Json).origins | Where-Object { $_ }) } catch {}
    foreach ($o in $old) { Register-QuestBrowserOrigin -Origin ([string]$o) -Owner $script:PlaylistXrOwner }
    Remove-Item -LiteralPath $script:PlaylistXrOriginsPath -Force -ErrorAction SilentlyContinue
}
