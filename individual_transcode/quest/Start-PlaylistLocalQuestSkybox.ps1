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
  front (up to -LaunchAttempts tries) or when the workflow ends. The workflow quit force-stops
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
    [int] $LaunchAttempts = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'PlaylistLocalQuestCommon.ps1')

$SkyboxPackage = 'xyz.skybox.player.ovr'

$cfg = Get-LoopSegmentsWindowsSettings
if ($env:PLAYLIST_QUEST_SKYBOX -eq '0' -or ($cfg.Contains('questPlaylistLaunchSkybox') -and $cfg.questPlaylistLaunchSkybox -eq $false)) {
    Write-PlaylistQuestLog 'Playlist Skybox: off (questPlaylistLaunchSkybox=false / PLAYLIST_QUEST_SKYBOX=0).'
    exit 0
}

function Find-PlaylistSkyboxAdb {
    $want = [string]$cfg.questAdbExe
    if (-not [string]::IsNullOrWhiteSpace($want) -and (Test-Path -LiteralPath $want)) { return $want }
    $cmd = Get-Command -Name adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return [string]$cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\adb.exe')
        (Join-Path $env:ProgramFiles 'Meta Quest Developer Hub\resources\bin\adb.exe')
        'C:\platform-tools\adb.exe'
    )
    $pkgs = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $pkgs) {
        $candidates += @(Get-ChildItem -LiteralPath $pkgs -Directory -Filter 'Google.PlatformTools*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'platform-tools\adb.exe' })
    }
    foreach ($p in $candidates) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

$script:Adb = Find-PlaylistSkyboxAdb
if (-not $script:Adb) {
    Write-PlaylistQuestLog 'Playlist Skybox: adb not found (set questAdbExe) - SKYBOX not launched.'
    exit 1
}

function Invoke-PlaylistSkyboxAdb {
    param([string[]] $Arguments, [int] $TimeoutSec = 10)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:Adb
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill($true) } catch {}
        return [pscustomobject]@{ Code = -1; Out = ''; Err = 'timeout' }
    }
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}

# Online headset serial (questAdbSerial when set, else the first device).
function Get-PlaylistSkyboxSerial {
    $r = Invoke-PlaylistSkyboxAdb -Arguments @('devices')
    $serials = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^(\S+)\s+device\s*$' } | ForEach-Object { ($_ -split '\s+')[0] })
    $want = ([string]$cfg.questAdbSerial).Trim()
    if ($want) { return @($serials | Where-Object { $_ -eq $want } | Select-Object -First 1) }
    return @($serials | Select-Object -First 1)
}

function Get-PlaylistSkyboxWakefulness {
    param([string] $Serial)
    $r = Invoke-PlaylistSkyboxAdb -Arguments @('-s', $Serial, 'shell', 'dumpsys', 'power') -TimeoutSec 8
    if ($r.Code -eq 0 -and $r.Out -match 'mWakefulness=(\w+)') { return $Matches[1] }
    return $null
}

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
