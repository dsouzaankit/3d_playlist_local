<#
.SYNOPSIS
  3d_playlist_local workflow start: serve the XR player page from this PC and open it on the Quest
  (instead of SKYBOX), next to the Quest control page.

.DESCRIPTION
  Started hidden by Start-PlaylistLocalQuestSession.ps1 (step 4) when the Quest player is 'xr' (the
  default; questPlaylistPlayer / $env:PLAYLIST_QUEST_PLAYER = skybox | none switch it).

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
    4. Opens http://<host>:<port>/xr?mode=<workflow> in a normal Quest Browser tab with
       ios_3d_loop_segments' Watch-LoopSegmentsQuestLanTab.ps1 -Url ... -NoLanLogin: the control page
       tab first, the XR page in front, then window.isSecureContext is read in the XR tab and, when
       false, its origin is added to chrome://flags "unsafely-treat-insecure-origin-as-secure" and Quest
       Browser restarts once (WebXR needs a secure context). A name the browser then fails to load
       falls back to the IPv4 once.

  The opened origin is kept in %TEMP%\playlist-xr-origins.json; the workflow quit closes its tabs and
  deletes its history with the control page's (PlaylistLocalQuestCommon.ps1 Get-PlaylistQuestExtraOrigins).

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
        Write-PlaylistQuestLog "Playlist XR: page already served on port $($xr.Port)$owner - reused."
        return $true
    }
    $py = Get-PlaylistXrPython
    if (-not $py) { Write-PlaylistQuestLog 'Playlist XR: no Python (py_venv1, py -3 or python) - XR page not served.'; return $false }
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
            Write-PlaylistQuestLog ("Playlist XR: page served on port {0} (PID {1}, fisheye background {2}; stops with the workflow)." -f $xr.Port, $p.Id, $(if ($bg) { $bg } else { 'black' }))
            return $true
        }
        if ($p.HasExited) { break }
    }
    Write-PlaylistQuestLog "Playlist XR: server did not start on port $($xr.Port) (exit $(if ($p.HasExited) { $p.ExitCode } else { 'n/a' })) - see %TEMP%\playlist-xr-server.log."
    return $false
}

# This PC's IPv4 on the route to the headset (its adb ip:port serial), else on the default route.
function Get-PlaylistXrPcAddress {
    param([string] $Serial)
    $target = if ($Serial -match '^(\d{1,3}(?:\.\d{1,3}){3}):\d+$') { $Matches[1] } else { '192.0.2.1' }
    $u = [System.Net.Sockets.UdpClient]::new()
    try {
        $u.Connect($target, 9)
        return ([System.Net.IPEndPoint]$u.Client.LocalEndPoint).Address.ToString()
    } catch { return $null } finally { $u.Dispose() }
}

# Does the headset resolve $Name to $Ip? (ping prints "PING name (a.b.c.d)" even with no reply:
# Windows Firewall drops ICMP echo by default.)
function Test-PlaylistXrHeadsetResolves {
    param([string] $Serial, [string] $Name, [string] $Ip)
    $r = Invoke-Adb -Arguments @('-s', $Serial, 'shell', 'ping', '-c', '1', '-W', '2', $Name) -TimeoutSec 10
    $text = [string]$r.Out + ' ' + [string]$r.Err
    if ($text -match 'PING\s+\S+\s+\((\d{1,3}(?:\.\d{1,3}){3})\)') {
        $got = $Matches[1]
        $mine = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
        if ($got -eq $Ip -or $mine -contains $got) { return $true }
        Write-PlaylistQuestLog "Playlist XR: the headset resolves $Name to $got, not this PC ($Ip) - not used."
        return $false
    }
    return $false
}

function Resolve-PlaylistXrHost {
    param([string] $Serial, [string] $Ip)
    $hm = $xr.HostMode
    if ($hm -ieq 'ip') { return $Ip }
    if ($hm -ine 'auto') { return $hm }
    $pcName = ([string]$env:COMPUTERNAME).ToLowerInvariant()
    foreach ($n in @("$pcName.local", $pcName)) {
        if ($n -and $n -ne '.local' -and (Test-PlaylistXrHeadsetResolves -Serial $Serial -Name $n -Ip $Ip)) { return $n }
    }
    return $Ip
}

function Invoke-PlaylistXrOpen {
    param([string] $Url)
    $watch = Join-Path $script:LsQuestDir 'Watch-LoopSegmentsQuestLanTab.ps1'
    # -NoLanLogin: no phone admin:<password>@ sign-in for this PC page.
    $p = Start-PlaylistQuestHidden -Pwsh (Get-PlaylistQuestPwsh) -Script $watch -Arguments @('-Url', $Url, '-NoLanLogin', '-WaitMinutes', '3')
    if (-not $p.WaitForExit(420000)) { try { $p.Kill($true) } catch {}; return -1 }
    return $p.ExitCode
}

# ---- 1. server ----
if (-not (Start-PlaylistXrServer)) { exit 3 }
if ($ServeOnly) { exit 0 }

# ---- 2. wait: control page open finished, headset awake ----
$script:Adb = Find-QuestAdbExe
if (-not $script:Adb) {
    Write-PlaylistQuestLog 'Playlist XR: adb not found (set questAdbExe) - page served, not opened on the headset.'
    exit 1
}
Write-PlaylistQuestLog 'Playlist XR: queued - opening the XR page when the headset is awake (until the workflow ends).'
$lastState = ''
$dev = $null
while ($true) {
    if (-not (Get-Process -Id $WorkflowPid -ErrorAction SilentlyContinue)) {
        Write-PlaylistQuestLog 'Playlist XR: workflow gone before the headset was ready - XR page not opened.'
        exit 1
    }
    try {
        $settled = $true
        if ($ControlPageStatusFile) {
            $w = ''
            try { $w = (Get-Content -LiteralPath $ControlPageStatusFile -Raw -ErrorAction Stop).Trim() } catch {}
            $settled = $w -in @('opened', 'failed', 'unreachable', 'cancelled')
        }
        $dev = Get-PlaylistQuestSerial
        $state = if ($dev) { Get-QuestWakefulness -DeviceSerial $dev } else { 'Unreachable' }
        if (-not $state) { $state = 'Unknown' }
        $label = "headset $state$(if ($dev) { " ($dev)" })$(if (-not $settled) { ', control page still opening' })"
        if ($label -ne $lastState) { Write-PlaylistQuestLog "Playlist XR: $label"; $lastState = $label }
        if ($state -eq 'Awake' -and $settled) { break }
    } catch {
        Write-PlaylistQuestLog "Playlist XR: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds ([Math]::Max(2, $PollSeconds))
}

# ---- 3. host ----
$ip = Get-PlaylistXrPcAddress -Serial $dev
if (-not $ip) { Write-PlaylistQuestLog 'Playlist XR: no IPv4 route to the headset - XR page not opened.'; exit 3 }
$xrHost = Resolve-PlaylistXrHost -Serial $dev -Ip $ip
Write-PlaylistQuestLog ("Playlist XR: page host {0} (questPlaylistXrHost={1}; PC IPv4 {2})." -f $xrHost, $xr.HostMode, $ip)

# ---- 4. open ----
$hosts = @($xrHost)
if ($xrHost -ne $ip) { $hosts += $ip }
foreach ($h in $hosts) {
    $origin = "http://${h}:$($xr.Port)"
    Add-PlaylistXrSavedOrigin -Origin $origin
    $url = "$origin/xr?mode=$mode"
    $code = Invoke-PlaylistXrOpen -Url $url
    if ($code -eq 0) {
        Write-PlaylistQuestLog "Playlist XR: $url open on the headset (Enter AR = passthrough). chrome://flags insecure-origin covers $origin."
        exit 0
    }
    Write-PlaylistQuestLog ("Playlist XR: opening {0} failed ({1})." -f $url, $(switch ($code) { -1 { 'timed out' } 1 { 'headset not awake / on adb' } 2 { 'no adb' } default { "exit $code" } }))
    if ($code -in @(1, 2)) { break }
}
exit 3
