#Requires -Version 5.1
<#
.SYNOPSIS
  Purge .avs files under a folder.

.DESCRIPTION
  Standalone / double-click (no -KeepCount): delete ALL .avs (full purge).
  Workflows pass -KeepCount 50 to retain only the newest N files by LastWriteTime.
  Does not touch fisheye_temp\avs unless you point -AvsFolder there.

.PARAMETER AvsFolder
  Folder containing .avs files. Default: .\avs

.PARAMETER KeepCount
  Number of newest .avs files to keep. Default: 0 (full purge - used when run separately).
  Flat/hybrid workflows call this script with -KeepCount 50.

.PARAMETER Recurse
  Include .avs in subfolders.

.PARAMETER DryRun
  List deletions without removing files.

.EXAMPLE
  .\Purge-OldAvs.ps1
  Full purge of .\avs

.EXAMPLE
  .\Purge-OldAvs.ps1 -AvsFolder '.\avs' -KeepCount 50
  Retain newest 50 (workflow mode)
#>
[CmdletBinding()]
param(
    [string] $AvsFolder = '.\avs',
    [int] $KeepCount = 0,
    [switch] $Recurse,
    [switch] $DryRun
)

function Invoke-PurgeOldAvs {
    param(
        [Parameter(Mandatory = $true)]
        [string] $AvsFolder,
        [int] $KeepCount = 0,
        [switch] $Recurse,
        [switch] $DryRun
    )

    if ($KeepCount -lt 0) {
        throw "KeepCount must be >= 0 (got $KeepCount)."
    }

    $folderFull = [System.IO.Path]::GetFullPath($AvsFolder)
    if (-not (Test-Path -LiteralPath $folderFull -PathType Container)) {
        Write-Host "AVS purge skipped (folder missing): $folderFull"
        return @{
            Folder   = $folderFull
            Kept     = 0
            Deleted  = 0
            Skipped  = $true
        }
    }

    $files = if ($Recurse.IsPresent) {
        @(Get-ChildItem -LiteralPath $folderFull -Recurse -File -Filter '*.avs' -ErrorAction SilentlyContinue)
    } else {
        @(Get-ChildItem -LiteralPath $folderFull -File -Filter '*.avs' -ErrorAction SilentlyContinue)
    }

    $sorted = @($files | Sort-Object LastWriteTimeUtc -Descending)
    $total = $sorted.Count
    if ($total -eq 0) {
        Write-Host "AVS purge: no .avs files under $folderFull"
        return @{
            Folder  = $folderFull
            Kept    = 0
            Deleted = 0
            Skipped = $false
        }
    }
    if ($KeepCount -gt 0 -and $total -le $KeepCount) {
        Write-Host ("AVS purge: {0} file(s) under {1} (keep {2}; nothing to delete)" -f $total, $folderFull, $KeepCount)
        return @{
            Folder  = $folderFull
            Kept    = $total
            Deleted = 0
            Skipped = $false
        }
    }

    $toDelete = if ($KeepCount -le 0) {
        Write-Host ("AVS full purge: deleting all {0} .avs under {1}" -f $total, $folderFull)
        $sorted
    } else {
        @($sorted | Select-Object -Skip $KeepCount)
    }
    $deleted = 0
    $failed = 0
    foreach ($f in $toDelete) {
        if ($DryRun.IsPresent) {
            Write-Host ("[DryRun] Would delete AVS: {0} (mtime {1:u})" -f $f.FullName, $f.LastWriteTimeUtc)
            $deleted++
            continue
        }
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            Write-Host ("Deleted AVS: {0}" -f $f.Name)
            $deleted++
        } catch {
            $failed++
            Write-Warning ("Could not delete AVS '{0}': {1}" -f $f.FullName, $_.Exception.Message)
        }
    }

    $keptAfter = if ($KeepCount -le 0) { 0 } else { $KeepCount }
    if ($DryRun.IsPresent) {
        if ($KeepCount -le 0) {
            Write-Host ("AVS purge dry-run: would delete all {0} under {1}" -f $deleted, $folderFull)
        } else {
            Write-Host ("AVS purge dry-run: would keep {0}, delete {1} under {2}" -f $KeepCount, $deleted, $folderFull)
        }
    } else {
        if ($KeepCount -le 0) {
            Write-Host ("AVS full purge done: deleted {0} (failed {1}) under {2}" -f $deleted, $failed, $folderFull)
        } else {
            Write-Host ("AVS purge: kept newest {0}, deleted {1} (failed {2}) under {3}" -f `
                $KeepCount, $deleted, $failed, $folderFull)
        }
    }
    return @{
        Folder  = $folderFull
        Kept    = $keptAfter
        Deleted = $deleted
        Failed  = $failed
        Skipped = $false
    }
}

# Direct execution (-File / &); when dotted (.), only load Invoke-PurgeOldAvs.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PurgeOldAvs -AvsFolder $AvsFolder -KeepCount $KeepCount -Recurse:$Recurse.IsPresent -DryRun:$DryRun.IsPresent | Out-Null
}
