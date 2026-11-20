#Requires -Version 5.1
<#
.SYNOPSIS
  Delete old / existing DLNA segment exports of ALL workflows (flat, fisheye, hybrid incl. as-is,
  context menu) so the next run starts with empty segment folders.

.DESCRIPTION
  Calls Remove-DlnaWorkflowSegmentExports in individual_transcode\Invoke-LeafFfmpegControl.ps1:
    - stop leaf 3d_op_* export ffmpeg (unless -NoStopLeafExport / -DryRun)
    - delete under M:\m1_media\3d_fullsbs_trans (or the remapped letter / AppData store):
        flat\3d_op_*.mkv      (Full_SBS)
        fisheye\3d_op_*.mkv   (LR_180_FISHEYE)
        hybrid\3d_op_*.mkv    (Full_SBS / LR_180_FISHEYE / LR_180 as-is)
      plus their <sha256>.tmp / legacy _dlna_obf_* copies renamed on workflow quit
      (matching .dlna_obf_map.json entries are dropped)
    - keep fisheye_temp\avs\*.avs, logs and the folder tree (Skybox share stays valid)

  Narrower than Cleanup-DlnaSegmentRoot.ps1, which wipes everything under the DLNA root
  (avs, logs, map, fisheye_temp). Works from the master scripts copy or any media-folder
  3d_playlist_local copy, on any drive.

.PARAMETER Root
  One or more DLNA roots. Default: Ensure-DlnaSegmentRoot (preferred M:\m1_media\3d_fullsbs_trans).

.PARAMETER IncludeFisheyeTemp
  Also delete fisheye pass-1 mezzanine media under fisheye_temp\ (not avs\ or logs\).

.PARAMETER IncludeLegacyRoots
  Also clean <any drive>:\{m1_media,f1_media,k1_media}\3d_fullsbs_trans left by older layouts.

.PARAMETER DryRun
  List what would be deleted (with sizes); delete nothing.

.PARAMETER NoStopLeafExport
  Do not taskkill running leaf DLNA export ffmpeg first (in-use segments then fail to delete).

.PARAMETER NoPause
  Do not wait for Enter before closing (double-click window).

.EXAMPLE
  .\Cleanup-DlnaSegmentExports.ps1 -DryRun

.EXAMPLE
  .\Cleanup-DlnaSegmentExports.ps1 -IncludeFisheyeTemp -IncludeLegacyRoots
#>
[CmdletBinding()]
param(
    [string[]] $Root = @(),
    [switch] $IncludeFisheyeTemp,
    [switch] $IncludeLegacyRoots,
    [switch] $DryRun,
    [switch] $NoStopLeafExport,
    [switch] $NoPause
)

$ErrorActionPreference = 'Stop'
$leafControl = Join-Path $PSScriptRoot 'individual_transcode\Invoke-LeafFfmpegControl.ps1'
if (-not (Test-Path -LiteralPath $leafControl -PathType Leaf)) {
    throw "Invoke-LeafFfmpegControl.ps1 not found: $leafControl"
}
. $leafControl
if (-not (Get-Command Remove-DlnaWorkflowSegmentExports -ErrorAction SilentlyContinue)) {
    throw 'Remove-DlnaWorkflowSegmentExports is not available after loading Invoke-LeafFfmpegControl.ps1 (sync individual_transcode).'
}

$mode = if ($DryRun.IsPresent) { 'DRY RUN - nothing is deleted' } else { 'deleting' }
Write-Host "Cleanup-DlnaSegmentExports: $mode segment exports of all workflows (flat / fisheye / hybrid)."
$result = Remove-DlnaWorkflowSegmentExports `
    -Root $Root `
    -IncludeFisheyeTemp:$IncludeFisheyeTemp.IsPresent `
    -IncludeLegacyRoots:$IncludeLegacyRoots.IsPresent `
    -DryRun:$DryRun.IsPresent `
    -NoStopLeafExport:$NoStopLeafExport.IsPresent

$verb = if ($DryRun.IsPresent) { 'Would delete' } else { 'Deleted' }
Write-Host ("Done. {0}={1} Truncated={2} Failed={3} Freed~{4:N1} MB StoppedLeafFfmpeg={5} Roots={6}" -f `
    $verb, $result.Deleted, $result.Truncated, $result.Failed, ($result.Bytes / 1MB), $result.Stopped, ($result.Roots -join '; '))

if (-not $NoPause.IsPresent -and $Host.Name -eq 'ConsoleHost' -and [Environment]::UserInteractive -and
    -not [Console]::IsInputRedirected) {
    Write-Host 'Press Enter to close...'
    try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 3 }
}
if ($result.Failed -gt 0) { exit 1 }
