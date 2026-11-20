#Requires -Version 5.1
<#
.SYNOPSIS
  Locate the master scripts folder (historically P:\all_scripts) on any drive.

.DESCRIPTION
  The "scripts root" is the folder that holds 3d_playlist_local\, py_venv1\, setup_venv.bat,
  AutoHotkey\, Skybox_vr_pc\ and "iOS apps\". Copy that whole folder to any drive / path and the
  workflows find it in this order:

    1. $env:ALL_SCRIPTS_ROOT (process, then User-scope environment variable)
    2. Walk up from -StartPath / this script's folder (works when run from the master copy)
    2b. <same drive as -StartPath / this script>:ll_scripts (not persisted)
    3. Pointer file %LOCALAPPDATA%\3d_playlist_local\all_scripts_root.txt
       (written by setup_script_files.py and whenever the master copy is found by 2 or 4)
    4. Any ready drive: <X>:\all_scripts
    5. Legacy P:\all_scripts

  A folder counts as the scripts root when it contains
  3d_playlist_local\individual_transcode\Invoke-LeafFfmpegControl.ps1 AND (setup_venv.bat OR py_venv1\).
  Media-folder sync copies (<media>\3d_playlist_local) never match, because the media root has
  neither setup_venv.bat nor py_venv1.

  The three batch launchers (run_batch_*.ps1) carry a compact inline copy of this logic because
  they run from media folders before 3d_playlist_local is synced. Keep the two in step.

.EXAMPLE
  . .\Resolve-AllScriptsRoot.ps1; Resolve-AllScriptsRoot
#>

$script:AllScriptsRootLegacy = 'P:\all_scripts'
$script:AllScriptsRootEnvName = 'ALL_SCRIPTS_ROOT'

function Test-AllScriptsRoot {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path.Trim().Trim('"'))
    } catch {
        return $false
    }
    $leaf = [System.IO.Path]::Combine($full, '3d_playlist_local', 'individual_transcode', 'Invoke-LeafFfmpegControl.ps1')
    if (-not (Test-Path -LiteralPath $leaf -PathType Leaf)) { return $false }
    return ((Test-Path -LiteralPath (Join-Path $full 'setup_venv.bat') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $full 'py_venv1') -PathType Container))
}

function Get-AllScriptsRootPointerPath {
    # LocalApplicationData, not %APPDATA%\3d_playlist_local (that folder is the DLNA segment store / Skybox share).
    $appData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) { $appData = $env:LOCALAPPDATA }
    if ([string]::IsNullOrWhiteSpace($appData)) { return $null }
    return [System.IO.Path]::Combine($appData, '3d_playlist_local', 'all_scripts_root.txt')
}

function Register-AllScriptsRoot {
    <# Persist the scripts root in the %LOCALAPPDATA% pointer file (no-op when unchanged). #>
    param([Parameter(Mandatory = $true)][string] $Path)
    $pointer = Get-AllScriptsRootPointerPath
    if ([string]::IsNullOrWhiteSpace($pointer)) { return $false }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    try {
        if (Test-Path -LiteralPath $pointer -PathType Leaf) {
            $cur = ([System.IO.File]::ReadAllText($pointer)).Trim()
            if ($cur -ieq $full) { return $true }
        }
        $dir = [System.IO.Path]::GetDirectoryName($pointer)
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($dir)
        }
        [System.IO.File]::WriteAllText($pointer, $full)
        return $true
    } catch {
        Write-Warning ("Could not write scripts-root pointer {0}: {1}" -f $pointer, $_.Exception.Message)
        return $false
    }
}

function Resolve-AllScriptsRoot {
    <#
    .SYNOPSIS
      Return the full path of the scripts root, or $null when none is found.
    .PARAMETER StartPath
      Folder to walk up from first (default: this file's folder).
    .PARAMETER NoRegister
      Do not update the %LOCALAPPDATA% pointer file.
    #>
    param(
        [string] $StartPath = '',
        [switch] $NoRegister
    )
    $register = {
        param($p)
        $full = [System.IO.Path]::GetFullPath($p).TrimEnd('\')
        if (-not $NoRegister.IsPresent) { [void](Register-AllScriptsRoot -Path $full) }
        return $full
    }

    foreach ($v in @(
        [Environment]::GetEnvironmentVariable($script:AllScriptsRootEnvName, 'Process'),
        [Environment]::GetEnvironmentVariable($script:AllScriptsRootEnvName, 'User')
    )) {
        if (Test-AllScriptsRoot -Path $v) { return [System.IO.Path]::GetFullPath($v.Trim().Trim('"')).TrimEnd('\') }
    }

    foreach ($start in @($StartPath, $PSScriptRoot)) {
        if ([string]::IsNullOrWhiteSpace($start)) { continue }
        $walk = $start
        for ($i = 0; $i -lt 6 -and -not [string]::IsNullOrWhiteSpace($walk); $i++) {
            if (Test-AllScriptsRoot -Path $walk) { return (& $register $walk) }
            $walk = Split-Path -Parent $walk
        }
    }

    # Same drive as the running script / media folder (I: media -> I:\all_scripts) before the pointer.
    # Not persisted, so the pointer keeps serving media on drives without their own copy.
    foreach ($start in @($StartPath, $PSScriptRoot)) {
        if ([string]::IsNullOrWhiteSpace($start)) { continue }
        try {
            $qual = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($start))
            if (-not [string]::IsNullOrWhiteSpace($qual)) {
                $cand = Join-Path $qual 'all_scripts'
                if (Test-AllScriptsRoot -Path $cand) { return [System.IO.Path]::GetFullPath($cand).TrimEnd('\') }
            }
        } catch { }
    }

    $pointer = Get-AllScriptsRootPointerPath
    if (-not [string]::IsNullOrWhiteSpace($pointer) -and (Test-Path -LiteralPath $pointer -PathType Leaf)) {
        try {
            $p = ([System.IO.File]::ReadAllText($pointer)).Trim()
            if (Test-AllScriptsRoot -Path $p) { return [System.IO.Path]::GetFullPath($p).TrimEnd('\') }
        } catch { }
    }

    foreach ($d in @([System.IO.DriveInfo]::GetDrives())) {
        try {
            if ($d.DriveType -notin @('Fixed', 'Removable', 'Network')) { continue }
            if (-not $d.IsReady) { continue }
            $cand = Join-Path $d.RootDirectory.FullName 'all_scripts'
            if (Test-AllScriptsRoot -Path $cand) { return (& $register $cand) }
        } catch { }
    }

    if (Test-AllScriptsRoot -Path $script:AllScriptsRootLegacy) { return $script:AllScriptsRootLegacy }
    return $null
}

function Get-AllScriptsPath {
    <#
    .SYNOPSIS
      Join a relative path onto the scripts root. Returns $null when the root is unknown.
    .EXAMPLE
      Get-AllScriptsPath 'AutoHotkey'
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)][string] $RelativePath,
        [string] $StartPath = ''
    )
    $root = Resolve-AllScriptsRoot -StartPath $StartPath
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    return (Join-Path $root $RelativePath)
}
