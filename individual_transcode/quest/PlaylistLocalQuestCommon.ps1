# Shared by this folder's Quest session scripts: Start-PlaylistLocalQuestSession.ps1 (workflow start),
# Invoke-PlaylistLocalQuestShutdown.ps1 (the control page's End session), Start-PlaylistLocalQuestXr.ps1,
# Close-PlaylistLocalQuestXrTabs.ps1. Everything playlist-specific lives here, in 3d_playlist_local;
# the generic headset layer (adb, sensor, keep-awake, Wi-Fi, Quest Browser, the shared control page
# host, the session cleanup) is the quest_tools repo: $env:QUEST_TOOLS_REPO, else
# <ALL_SCRIPTS_ROOT>\quest_tools, else a quest_tools folder next to this repo, then P:\all_scripts.
# Dot-sourcing this loads it (Find-QuestAdbExe, Invoke-Adb, Write-QuestLog, Register-QuestControlTiles, ...).
#
# Settings: playlist-quest.json next to this file (per PC, git-ignored; playlist-quest.example.json
# lists the keys). A key missing there falls back to the older questPlaylist* / questControlPage keys
# in ios_3d_loop_segments\windows\loop-segments-windows.json, then to the default.

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
# Child processes (helpers, the control page host) find the same checkout.
$env:QUEST_TOOLS_REPO = $script:QuestToolsRepo
. (Join-Path $script:QuestToolsRepo 'QuestTools.ps1')
try { Initialize-QuestToolsFromSettings } catch {}
$script:PlaylistQuestHeadset = Join-Path $script:QuestToolsRepo 'Invoke-QuestHeadset.ps1'

# ---- Settings ----

$script:PlaylistQuestSettingsPath = Join-Path $PSScriptRoot 'playlist-quest.json'
$script:PlaylistQuestDefaults = [ordered]@{
    session         = $true     # workflow start runs the Quest session at all
    controlPage     = $true     # serve the control page tiles and open the page on the headset
    openWaitMinutes = 0         # wait for an asleep / off-adb headset (0 = until the workflow ends)
    player          = 'xr'      # 'xr' (the XR page) or 'none'
    xrPort          = 18768
    xrHost          = 'auto'    # 'auto' | 'ip' | a host name
    historyOrigins  = @()       # extra origins the cleanup deletes ({pc} = this PC's address)
    enterExitSec    = 180       # End session: seconds a workflow window gets after Enter (0 = never kill)
}
$script:PlaylistQuestLegacyKeys = [ordered]@{
    session         = 'questPlaylistSession'
    controlPage     = 'questControlPage'
    openWaitMinutes = 'questPlaylistOpenWaitMinutes'
    player          = 'questPlaylistPlayer'
    xrPort          = 'questPlaylistXrPort'
    xrHost          = 'questPlaylistXrHost'
    historyOrigins  = 'questPlaylistHistoryOrigins'
    enterExitSec    = 'questPlaylistEnterExitSec'
}

function Get-PlaylistQuestSettings {
    $own = Read-QuestJsonFile -Path $script:PlaylistQuestSettingsPath
    $legacy = Read-QuestJsonFile -Path (Get-QuestLegacySettingsPath)
    $out = [ordered]@{}
    foreach ($k in $script:PlaylistQuestDefaults.Keys) {
        $v = $script:PlaylistQuestDefaults[$k]
        $old = $script:PlaylistQuestLegacyKeys[$k]
        if ($legacy -and $legacy.PSObject.Properties[$old] -and $null -ne $legacy.$old) { $v = $legacy.$old }
        if ($own -and $own.PSObject.Properties[$k] -and $null -ne $own.$k) { $v = $own.$k }
        $out[$k] = $v
    }
    return $out
}

# ---- State ----

# Workflow shells registered at workflow start: { sessions: [ { pid, name, started, registeredUtc, deadlineUtc, shutdownScript } ] }.
# deadlineUtc: the workflow's -BatchTimeoutSec deadline ('' = none); the XR page counts down to it.
$script:PlaylistSessionPath = Join-Path $env:TEMP 'loopsegments-playlist-session.json'
# End session progress, shown by the control page.
$script:PlaylistShutdownPath = Join-Path $env:TEMP 'loopsegments-playlist-shutdown.json'
# This repo's tiles on the shared control page.
$script:PlaylistControlTiles = Join-Path $PSScriptRoot 'PlaylistControlTiles.ps1'
$script:PlaylistControlOwner = 'playlist'

# quest_tools Invoke-QuestHeadset.ps1 helpers (and the Loop Segments watcher a pre-split run may have
# left) whose command line is -like $Pattern.
function Get-PlaylistQuestHelperProcesses {
    param([string] $Pattern = '*')
    return @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $c = [string]$_.CommandLine; ($c -like '*Invoke-QuestHeadset.ps1*' -or $c -like '*Watch-LoopSegmentsQuestLanTab.ps1*') -and $c -like $Pattern })
}

function Get-PlaylistQuestProcessStart {
    param([int] $ProcessId)
    return (Get-QuestProcessStartStamp -ProcessId $ProcessId)
}

# ---- Shared by the end-session run and the natural-end cleanup ----

# historyOrigins with {pc} replaced by this PC's address.
function Get-PlaylistQuestExtraOrigins {
    $raw = @(@((Get-PlaylistQuestSettings).historyOrigins) | ForEach-Object { ([string]$_).Trim().TrimEnd('/') } | Where-Object { $_ })
    if (-not $raw.Count) { return @() }
    $pc = $null
    try { $pc = Get-QuestPcAddress -DeviceSerial (Get-OnlineQuestSerial) -DefaultRoute } catch {}
    return @($raw | ForEach-Object { if ($_ -like '*{pc}*') { if ($pc) { $_.Replace('{pc}', $pc) } } else { $_ } } | Where-Object { $_ })
}

# quest_tools Invoke-QuestHeadset.ps1 -Cleanup arguments (tabs, history, sensor on; Wi-Fi off and the
# tab / history choices per quest-tools.json). It covers every page in quest_tools' shared origin
# list (the control page and the XR page register theirs when they open) plus historyOrigins. The
# after-quit helper stops if the Loop Segments companion starts (its own quit does the same cleanup).
function Get-PlaylistQuestCleanupArgs {
    Sync-PlaylistXrOriginsToShared
    $a = @('-Cleanup', '-StopIfCommandLine', 'Run-PCloudWebCompanion\.ps1|_run_chromium\.ps1')
    $extra = @(Get-PlaylistQuestExtraOrigins)
    if ($extra.Count) { $a += @('-ExtraOrigins', ($extra -join ',')) }
    return $a
}

# The running Loop Segments companion: its launcher shell or its Chromium (profile
# ...\pcloud_web_companion\chromium-profile, main process). Not the REST log sink / exit watchdog,
# which can outlive it. End session quits it, so its own quit cleans up the Quest.
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
    param([int] $WorkflowPid, [string] $WorkflowName, [string] $DeadlineUtc = '')
    $keep = @(Get-PlaylistQuestSessions | Where-Object { [int]$_.pid -ne $WorkflowPid })
    # shutdownScript: the control page's End session runs this workflow's copy (media folders keep
    # their own synced 3d_playlist_local).
    $entry = [pscustomobject]@{ pid = $WorkflowPid; name = $WorkflowName; started = (Get-PlaylistQuestProcessStart -ProcessId $WorkflowPid)
        registeredUtc = [DateTime]::UtcNow.ToString('o'); deadlineUtc = $DeadlineUtc; shutdownScript = (Join-Path $PSScriptRoot 'Invoke-PlaylistLocalQuestShutdown.ps1') }
    try { @{ sessions = @($keep + $entry) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:PlaylistSessionPath -Encoding utf8 } catch {}
}

# ---- Quest XR page (individual_transcode\xr, Start-PlaylistLocalQuestXr.ps1) ----

# What the workflow start opens on the headset: 'xr' (default: the XR page in Quest Browser, served
# from this PC) or 'none'. $env:PLAYLIST_QUEST_PLAYER, else the player setting. Anything else (e.g. a
# leftover 'skybox': SKYBOX VR Player as the player was removed 2026-11-23) = 'xr'.
function Get-PlaylistQuestPlayer {
    $raw = [string]$env:PLAYLIST_QUEST_PLAYER
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = [string](Get-PlaylistQuestSettings).player }
    if (([string]$raw).Trim().ToLowerInvariant() -eq 'none') { return 'none' }
    return 'xr'
}

# Port (xrPort, default 18768 = control page 18766 + 2) and host mode ($env:PLAYLIST_XR_HOST, else
# xrHost): 'auto' (default) = this PC's name when the headset resolves it to this PC, else its LAN
# IPv4; 'ip' = always the IPv4; anything else = that host name.
function Get-PlaylistXrSettings {
    $cfg = Get-PlaylistQuestSettings
    $port = 18768
    try { if ([int]$cfg.xrPort -gt 0) { $port = [int]$cfg.xrPort } } catch {}
    $hostMode = [string]$env:PLAYLIST_XR_HOST
    if ([string]::IsNullOrWhiteSpace($hostMode)) { $hostMode = [string]$cfg.xrHost }
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
