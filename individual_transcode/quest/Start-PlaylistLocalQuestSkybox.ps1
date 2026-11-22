<#
.SYNOPSIS
  3d_playlist_local workflow start: open SKYBOX VR Player on the Quest once the headset is awake.

.DESCRIPTION
  Started hidden by Start-PlaylistLocalQuestSession.ps1 (step 4). Waits (every -PollSeconds,
  until -WorkflowPid exits) for the headset to be online on adb and awake, then launches SKYBOX
  (xyz.skybox.player.ovr) in front, so the workflow's DLNA segments can be picked from the
  SKYBOX PC share right away. It only opens the app: SKYBOX plays nothing it is handed from
  outside (an http link crashes it), and the two-slot 3d_op_00 / 3d_op_01 rotation plays best
  from the PC share anyway.

  Order: the control page open (Watch-LoopSegmentsQuestLanTab.ps1 -OpenControlPage) brings Quest
  Browser to the front, so with the control page on this waits for that helper's -StatusFile to
  reach a final word (opened / failed / unreachable / cancelled), or for -ControlPageWaitSec after
  the headset is awake, before launching. Quest Browser keeps running behind SKYBOX.

  Finding the headset (adb connect, mDNS, adb server restart) is left to the keep-awake helper the
  session starts; this only reads `adb devices`. One launch per workflow: exits after SKYBOX is in
  front (up to -LaunchAttempts tries) or when the workflow ends. SKYBOX not installed on the
  headset (`pm path`): logged and exits 4 at once, no launch tries. The workflow quit force-stops
  SKYBOX as before (questPlaylistMediaPlayers).

  Off: questPlaylistLaunchSkybox=false (windows\loop-segments-windows.json) or
       $env:PLAYLIST_QUEST_SKYBOX = '0'.
  Log: %TEMP%\loopsegments-quest-lantab.log ("Playlist Skybox:" lines).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $WorkflowPid,
    # Watch-LoopSegmentsQuestLanTab.ps1 -OpenControlPage -StatusFile; '' = control page not opened.
    [string] $ControlPageStatusFile = '',
    [int] $ControlPageWaitSec = 90,
    [int] $PollSeconds = 5,
    [int] $LaunchAttempts = 3,
    [string] $SkyboxPackage = 'xyz.skybox.player.ovr'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'PlaylistLocalQuestCommon.ps1')

$cfg = Get-LoopSegmentsWindowsSettings
if ($env:PLAYLIST_QUEST_SKYBOX -eq '0' -or ($cfg.Contains('questPlaylistLaunchSkybox') -and $cfg.questPlaylistLaunchSkybox -eq $false)) {
    Write-PlaylistQuestLog 'Playlist Skybox: off (questPlaylistLaunchSkybox=false / PLAYLIST_QUEST_SKYBOX=0).'
    exit 0
}

# adb helpers: PlaylistLocalQuestCommon.ps1 (shared with Start-PlaylistLocalQuestXr.ps1).
$script:Adb = Find-PlaylistQuestAdb
if (-not $script:Adb) {
    Write-PlaylistQuestLog 'Playlist Skybox: adb not found (set questAdbExe) - SKYBOX not launched.'
    exit 1
}
function Invoke-PlaylistSkyboxAdb { param([string[]] $Arguments, [int] $TimeoutSec = 10) Invoke-PlaylistQuestAdb -Arguments $Arguments -TimeoutSec $TimeoutSec }
function Get-PlaylistSkyboxSerial { Get-PlaylistQuestSerial }
function Get-PlaylistSkyboxWakefulness { param([string] $Serial) Get-PlaylistQuestWakefulness -Serial $Serial }

function Test-PlaylistSkyboxInFront {
    param([string] $Serial)
    $r = Invoke-PlaylistSkyboxAdb -Arguments @('-s', $Serial, 'shell', 'dumpsys', 'activity', 'activities') -TimeoutSec 10
    return [bool](@($r.Out -split "`r?`n" | Where-Object { $_ -match 'topResumedActivity=.*' + [regex]::Escape($SkyboxPackage) }).Count)
}

function Test-PlaylistControlPageSettled {
    if (-not $ControlPageStatusFile) { return $true }
    try { $w = (Get-Content -LiteralPath $ControlPageStatusFile -Raw -ErrorAction Stop).Trim() } catch { return $false }
    return ($w -in @('opened', 'failed', 'unreachable', 'cancelled'))
}

Write-PlaylistQuestLog 'Playlist Skybox: queued - opening SKYBOX when the headset is awake (until the workflow ends).'
$lastState = ''
$awakeSince = $null
while ($true) {
    if (-not (Get-Process -Id $WorkflowPid -ErrorAction SilentlyContinue)) {
        Write-PlaylistQuestLog 'Playlist Skybox: workflow gone before the headset was ready - SKYBOX not launched.'
        exit 1
    }
    try {
        $dev = Get-PlaylistSkyboxSerial
        $state = if ($dev) { Get-PlaylistSkyboxWakefulness -Serial $dev } else { 'Unreachable' }
        if (-not $state) { $state = 'Unknown' }
        if ($state -ne $lastState) { Write-PlaylistQuestLog ("Playlist Skybox: headset {0}{1}" -f $state, $(if ($dev) { " ($dev)" } else { '' })); $lastState = $state }
        if ($state -ne 'Awake') {
            $awakeSince = $null
        } else {
            if (-not $awakeSince) { $awakeSince = [DateTime]::UtcNow }
            $settled = Test-PlaylistControlPageSettled
            if ($settled -or ([DateTime]::UtcNow - $awakeSince).TotalSeconds -ge $ControlPageWaitSec) {
                # Not installed: monkey only prints "No activities found" - say so instead of retrying.
                $pm = Invoke-PlaylistSkyboxAdb -Arguments @('-s', $dev, 'shell', 'pm', 'path', $SkyboxPackage) -TimeoutSec 10
                if ($pm.Code -ne -1 -and ([string]$pm.Out) -notmatch '(?m)^package:') {
                    if ($pm.Code -eq 0 -or ([string]$pm.Out + [string]$pm.Err) -notmatch '(?i)offline|not found|no devices|closed') {
                        Write-PlaylistQuestLog "Playlist Skybox: SKYBOX ($SkyboxPackage) not installed on the headset ($dev) - not launched."
                        exit 4
                    }
                    throw "pm path failed: $((([string]$pm.Out) + ' ' + ([string]$pm.Err)).Trim())"
                }
                if (-not $settled) { Write-PlaylistQuestLog "Playlist Skybox: control page not open after ${ControlPageWaitSec}s - launching SKYBOX anyway." }
                for ($i = 1; $i -le $LaunchAttempts; $i++) {
                    [void](Invoke-PlaylistSkyboxAdb -Arguments @('-s', $dev, 'shell', 'monkey', '-p', $SkyboxPackage, '-c', 'android.intent.category.LAUNCHER', '1') -TimeoutSec 15)
                    $t0 = [DateTime]::UtcNow
                    while (([DateTime]::UtcNow - $t0).TotalSeconds -lt 20) {
                        Start-Sleep -Seconds 2
                        if (Test-PlaylistSkyboxInFront -Serial $dev) {
                            Write-PlaylistQuestLog "Playlist Skybox: SKYBOX open in front ($dev, try $i) - pick the segments from the SKYBOX PC share."
                            exit 0
                        }
                    }
                    Write-PlaylistQuestLog "Playlist Skybox: SKYBOX not in front after try $i."
                }
                Write-PlaylistQuestLog "Playlist Skybox: SKYBOX did not come to the front after $LaunchAttempts tries - giving up."
                exit 3
            }
        }
    } catch {
        Write-PlaylistQuestLog "Playlist Skybox: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds ([Math]::Max(2, $PollSeconds))
}
