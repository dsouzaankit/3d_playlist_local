<#
.SYNOPSIS
  Close the XR page's Quest Browser tabs, so nothing reads the segments while the workflow's quit
  renames them.

.DESCRIPTION
  The XR page (Start-PlaylistLocalQuestXr.ps1) streams the DLNA segments from this PC. The workflow's
  quit cleanup (Invoke-LeafFfmpegControl.ps1 Invoke-DlnaWorkflowQuitCleanup) renames them to
  scrambled .tmp names, so first the XR tabs are closed: every tab on an origin registered in
  quest_tools' shared origin list under owner 3d_playlist_local-xr (Close-QuestOurTabs: when they are
  the only tabs, one is kept as a new-tab page, so the page stops either way). Quest Browser itself
  keeps running; its history is deleted later by the Quest cleanup, which still knows these origins.

  Run by the workflow's quit (<= 30 s) and by the control page's End session button (step 1).
  Only reads `adb devices`: a headset off adb is left alone (nothing can stream from it then either).

  -StatusFile: gets the result in one line (End session shows it).
  Log: %TEMP%\loopsegments-quest-lantab.log ("Playlist XR:" lines).
  Exit codes: 0 closed / nothing open, 1 headset not on adb, 3 failed.
#>
[CmdletBinding()]
param(
    [string] $StatusFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'PlaylistLocalQuestCommon.ps1')

function Set-CloseStatus {
    param([string] $Value)
    if ($StatusFile) { try { Set-Content -LiteralPath $StatusFile -Value $Value -Encoding utf8 } catch {} }
}

$origins = @(Get-QuestRegisteredOrigins -Owner $script:PlaylistXrOwner)
if (-not $origins.Count) {
    Write-QuestLog 'Playlist XR: no XR page registered - no tab to close.'
    Set-CloseStatus 'no XR page open'
    exit 0
}
$script:Adb = Find-QuestAdbExe
if (-not $script:Adb) { Write-QuestLog 'Playlist XR: adb not found - XR tabs not closed.'; Set-CloseStatus 'no adb'; exit 3 }
$dev = Get-OnlineQuestSerial
if (-not $dev) {
    Write-QuestLog 'Playlist XR: headset not on adb - XR tabs not closed.'
    Set-CloseStatus 'headset not on adb'
    exit 1
}
if (-not (Open-QuestDevTools -DeviceSerial $dev)) { Set-CloseStatus 'no DevTools connection'; exit 3 }
try {
    $open = @(Get-QuestLanTabs -Origins $origins).Count
    if (-not $open) {
        Write-QuestLog 'Playlist XR: no XR tab open on the headset.'
        Set-CloseStatus 'no XR tab open'
        exit 0
    }
    [void](Close-QuestOurTabs -Origins $origins)
    $left = @(Get-QuestLanTabs -Origins $origins).Count
    Write-QuestLog ("Playlist XR: closed the XR page ({0} tab(s); {1}) before the segments are renamed." -f $open, ($origins -join ', '))
    if ($left) { Set-CloseStatus "XR tab still open ($left)"; exit 3 }
    Set-CloseStatus "XR page closed ($open tab(s))"
    exit 0
} catch {
    Write-QuestLog "Playlist XR: closing the XR tabs failed - $($_.Exception.Message)"
    Set-CloseStatus 'failed'
    exit 3
} finally { Close-QuestDevTools }
