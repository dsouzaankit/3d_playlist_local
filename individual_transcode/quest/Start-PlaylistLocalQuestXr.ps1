<#
.SYNOPSIS
  3d_playlist_local workflow start: serve the XR player page from this PC and open it on the Quest
  (instead of SKYBOX), next to the Quest control page.

.DESCRIPTION
  Started hidden by Start-PlaylistLocalQuestSession.ps1 (step 4) unless questPlaylistPlayer /
  $env:PLAYLIST_QUEST_PLAYER = none. Before the workflow's quit renames the segments,
  Close-PlaylistLocalQuestXrTabs.ps1 closes its tabs.

    1. Serves ..\xr (serve_xr_page.py: xr-player.html + xr-app.js; the engine xr-components.js and
       A-Frame from quest_tools\xr; the DLNA segments in
       %APPDATA%\3d_playlist_local\{hybrid,fisheye,flat}) on port questPlaylistXrPort (18768), all
       interfaces, until the workflow (and any other registered workflow) ends. A server already
       answering on that port is reused.
    2. Waits for the control page open (-ControlPageStatusFile) to finish, so the two do not drive
       Quest Browser at the same time, and for the headset to be on adb and awake.
    3. Picks the page's host (questPlaylistXrHost / $env:PLAYLIST_XR_HOST):
         auto (default) - this PC's name (<COMPUTERNAME>.local, then <COMPUTERNAME>) when the headset
                          resolves it to this PC (adb shell ping), else this PC's LAN IPv4;
         ip             - always the IPv4 on the route to the headset;
         <name>         - that host name (e.g. a router DNS name for a DHCP reservation).
       A name keeps the chrome://flags entry valid when DHCP hands the PC another address.
    4. Opens http://<host>:<port>/xr?mode=<workflow> in a normal Quest Browser tab, in this process,
       with quest_tools' Open-QuestPage (no sign-in; an open tab on this origin is reused; the control
       page opened in step 2 stays behind it): then window.isSecureContext is read in the XR tab and,
       when false, its origin is added to chrome://flags "unsafely-treat-insecure-origin-as-secure"
       (helper tab: this server's /xr-assets/lsclean) and Quest Browser restarts once (WebXR needs a
       secure context). A name the browser then fails to load falls back to the IPv4 once.

  The opened origin goes into quest_tools' shared origin list (%TEMP%\quest-browser-origins.json,
  owner 3d_playlist_local-xr); every Quest cleanup (the workflow quit, End session, the Loop
  Segments companion's quit) closes its tabs and deletes its history.

  First run: Windows Firewall may ask to allow python.exe on private networks - allow it, or the
  headset cannot reach the page.

  Log: %TEMP%\loopsegments-quest-lantab.log ("Playlist XR:" lines); server: %TEMP%\playlist-xr-server.log.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $WorkflowPid,
    [string] $WorkflowName = 'hybrid',
    # Watch-LoopSegmentsQuestLanTab.ps1 -OpenControlPage -StatusFile; '' = control page not opened.
    [string] $ControlPageStatusFile = '',
    [int] $PollSeconds = 5,
    # Only serve the page (no headset steps): for opening it by hand.
    [switch] $ServeOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'PlaylistLocalQuestCommon.ps1')

$xr = Get-PlaylistXrSettings
$mode = if ($WorkflowName -in @('hybrid', 'fisheye', 'flat')) { $WorkflowName } else { 'hybrid' }
$serverScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\xr\serve_xr_page.py'))
$serverStatePath = Join-Path $env:TEMP 'playlist-xr-server.json'

function Test-PlaylistXrServer {
    param([int] $Port)
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/healthz" -TimeoutSec 3 -UseBasicParsing
        return ($r.StatusCode -eq 200 -and ([string]$r.Content).Trim() -eq 'ok')
    } catch { return $false }
}

# <scripts root>\py_venv1 python (ALL_SCRIPTS_ROOT, else three levels up from here), else py -3, else python.
function Get-PlaylistXrPython {
    $roots = @($env:ALL_SCRIPTS_ROOT, [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')))
    foreach ($r in $roots) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $p = Join-Path $r 'py_venv1\Scripts\python.exe'
        if (Test-Path -LiteralPath $p) { return @{ Exe = $p; Args = @() } }
    }
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) { return @{ Exe = $py.Source; Args = @('-3') } }
    $python = Get-Command python.exe -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1
    if ($python) { return @{ Exe = $python.Source; Args = @() } }
    return $null
}

function Start-PlaylistXrServer {
    if (Test-PlaylistXrServer -Port $xr.Port) {
        $owner = ''
        try { $owner = " (PID $((Get-Content -LiteralPath $serverStatePath -Raw | ConvertFrom-Json).pid))" } catch {}
        Write-QuestLog "Playlist XR: page already served on port $($xr.Port)$owner - reused."
        return $true
    }
    $py = Get-PlaylistXrPython
    if (-not $py) { Write-QuestLog 'Playlist XR: no Python (py_venv1, py -3 or python) - XR page not served.'; return $false }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $py.Exe
    # Engine (xr-components.js, A-Frame): quest_tools\xr, the same checkout the quest helpers loaded.
    $engineArgs = @(); if ($script:QuestToolsRepo) { $engineArgs = @('--engine-dir', (Join-Path $script:QuestToolsRepo 'xr')) }
    foreach ($a in @($py.Args) + @('-I', $serverScript, '--port', "$($xr.Port)", '--parent-pid', "$WorkflowPid", '--default-mode', $mode) + $engineArgs) { [void]$psi.ArgumentList.Add([string]$a) }
    $bg = ([string]$env:FISHEYE_BACKGROUND_COLOR).Trim().ToLowerInvariant()
    if ($bg -in @('black', 'green', 'red', 'blue')) { [void]$psi.ArgumentList.Add('--fisheye-bg'); [void]$psi.ArgumentList.Add($bg) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-PlaylistXrServer -Port $xr.Port) {
            Write-QuestLog ("Playlist XR: page served on port {0} (PID {1}, fisheye background {2}; stops with the workflow)." -f $xr.Port, $p.Id, $(if ($bg) { $bg } else { 'black' }))
            return $true
        }
        if ($p.HasExited) { break }
    }
    Write-QuestLog "Playlist XR: server did not start on port $($xr.Port) (exit $(if ($p.HasExited) { $p.ExitCode } else { 'n/a' })) - see %TEMP%\playlist-xr-server.log."
    return $false
}

# quest_tools' Open-QuestPage, in this process: registered in the shared origin list (owner
# 3d_playlist_local-xr), a normal tab with no sign-in (an open tab on this origin reused), then
# isSecureContext read and, when false, the origin added to chrome://flags (Quest Browser restarts)
# and the page opened again. The flags helper tab uses this server's /xr-assets/lsclean (a small 404
# page, no login).
function Invoke-PlaylistXrOpen {
    param([string] $DeviceSerial, [string] $Origin, [string] $Url)
    try {
        return [bool](Open-QuestPage -DeviceSerial $DeviceSerial -Url $Url -Owner $script:PlaylistXrOwner -HelperUrl "$Origin/xr-assets/lsclean")
    } catch {
        Write-QuestLog "Playlist XR: $($_.Exception.Message)"
        return $false
    }
}

# ---- 1. server ----
if (-not (Start-PlaylistXrServer)) { exit 3 }
if ($ServeOnly) { exit 0 }

# ---- 2. wait: control page open finished, headset awake ----
$script:Adb = Find-QuestAdbExe
if (-not $script:Adb) {
    Write-QuestLog 'Playlist XR: adb not found (set questAdbExe) - page served, not opened on the headset.'
    exit 1
}
# quest_tools' Wait-QuestHeadsetAwake: until the workflow ends; only reads adb devices (-NoConnect:
# finding the headset is left to the session's keep-awake helper).
$w = Wait-QuestHeadsetAwake -ParentPid $WorkflowPid -PollSeconds $PollSeconds -Label 'Playlist XR: ' -NoConnect `
    -ReadyLabel 'control page still opening' -Ready {
        if (-not $ControlPageStatusFile) { return $true }
        $s = ''
        try { $s = (Get-Content -LiteralPath $ControlPageStatusFile -Raw -ErrorAction Stop).Trim() } catch {}
        return ($s -in @('opened', 'failed', 'unreachable', 'cancelled'))
    }
if (-not $w.Serial) { exit 1 }
$dev = $w.Serial

# ---- 3. host ----
$ip = Get-QuestPcAddress -DeviceSerial $dev -DefaultRoute
if (-not $ip) { Write-QuestLog 'Playlist XR: no IPv4 route to the headset - XR page not opened.'; exit 3 }
$xrHost = Resolve-QuestPcHost -DeviceSerial $dev -Ip $ip -Mode $xr.HostMode -Label 'Playlist XR: '
Write-QuestLog ("Playlist XR: page host {0} (questPlaylistXrHost={1}; PC IPv4 {2})." -f $xrHost, $xr.HostMode, $ip)

# ---- 4. open ----
$hosts = @($xrHost)
if ($xrHost -ne $ip) { $hosts += $ip }
foreach ($h in $hosts) {
    $origin = "http://${h}:$($xr.Port)"
    Add-PlaylistXrSavedOrigin -Origin $origin
    $url = "$origin/xr?mode=$mode"
    if (Invoke-PlaylistXrOpen -DeviceSerial $dev -Origin $origin -Url $url) {
        Write-QuestLog "Playlist XR: $url open on the headset (Enter AR = passthrough). chrome://flags insecure-origin covers $origin."
        exit 0
    }
    Write-QuestLog "Playlist XR: opening $url failed."
    if (-not (Get-OnlineQuestSerial)) { Write-QuestLog 'Playlist XR: headset gone from adb - not trying another host.'; break }
}
exit 3
