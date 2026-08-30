#Requires -Version 5.1
<#
.SYNOPSIS
  Choose flat / fisheye / asis workflow from source resolution, bitrate, and video codec.

.DESCRIPTION
  As-is (stream-copy like 3d_loop_segments) when resolution reference pixels >
  asisAboveReferencePx from hybrid_workflow.json (default 2048 = 2K):
    SBS (width >= 2*height): coded width; otherwise longer edge.
  Else flat when bitrate below flatNonHevcAv1MaxKbps (default 4000) for non-HEVC/AV1,
  or below flatHevcAv1MaxKbps (default 2000) for HEVC/AV1.
  Otherwise fisheye. If bitrate cannot be probed: defaultKindWhenBitrateUnknown (default fisheye).
  As-is Skybox token: asisSegmentSuffix (default LR_180).

  Bitrate prefers format=bit_rate; falls back to video stream bit_rate when format is missing.
#>

$script:HybridAsisAboveReferencePxDefault = 2048
$script:HybridFlatNonHevcAv1MaxKbpsDefault = 4000
$script:HybridFlatHevcAv1MaxKbpsDefault = 2000
$script:HybridDefaultKindWhenBitrateUnknownDefault = 'fisheye'
$script:HybridAsisSegmentSuffixDefault = 'LR_180'
$script:HybridWorkflowConfigCached = $null
$script:HybridWorkflowConfigSource = ''
# Back-compat aliases used by Get-HybridAsisAboveReferencePx
$script:HybridAsisAboveReferencePxCached = $null
$script:HybridAsisAboveReferencePxSource = ''

function Get-HybridFfprobeExePath {
    param([string] $FfmpegExe = 'ffmpeg')
    if (-not [string]::IsNullOrWhiteSpace($FfmpegExe)) {
        $dir = [System.IO.Path]::GetDirectoryName($FfmpegExe)
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            $candidate = Join-Path $dir 'ffprobe.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-HybridFfprobeOutput {
    param(
        [string] $FfprobeExe,
        [string[]] $ArgumentList
    )
    if ([string]::IsNullOrWhiteSpace($FfprobeExe) -or -not (Test-Path -LiteralPath $FfprobeExe -PathType Leaf)) {
        return $null
    }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $FfprobeExe @ArgumentList 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return $out
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Get-HybridFormatBitrateBps {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    $raw = Invoke-HybridFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-show_entries', 'format=bit_rate',
        '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
    )
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -eq '' -or $s -eq 'N/A') { return $null }
    $n = 0L
    if (-not [int64]::TryParse($s, [ref]$n)) { return $null }
    if ($n -le 0) { return $null }
    return $n
}

function Get-HybridVideoStreamBitrateBps {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    $raw = Invoke-HybridFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=bit_rate',
        '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
    )
    if ($null -eq $raw) { return $null }
    foreach ($line in @($raw)) {
        $s = ([string]$line).Trim()
        if ($s -eq '' -or $s -eq 'N/A') { continue }
        $n = 0L
        if ([int64]::TryParse($s, [ref]$n) -and $n -gt 0) {
            return $n
        }
    }
    return $null
}

function Get-HybridVideoCodecName {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    $raw = Invoke-HybridFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=codec_name',
        '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
    )
    if ($null -eq $raw) { return $null }
    foreach ($line in @($raw)) {
        $s = ([string]$line).Trim()
        if ($s -eq '' -or $s -eq 'N/A') { continue }
        return $s.ToLowerInvariant()
    }
    return $null
}

function Test-HybridHevcOrAv1Codec {
    param([string] $CodecName)
    if ([string]::IsNullOrWhiteSpace($CodecName)) { return $false }
    $c = $CodecName.Trim().ToLowerInvariant()
    return ($c -eq 'hevc' -or $c -eq 'h265' -or $c -eq 'hev1' -or $c -eq 'hvc1' -or $c -eq 'av1')
}

function Get-HybridVideoDimensions {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    $raw = Invoke-HybridFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height',
        '-of', 'csv=p=0:s=x', '--', $MediaPath
    )
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -notmatch '^(\d+)x(\d+)$') { return $null }
    $w = [int]$Matches[1]
    $h = [int]$Matches[2]
    if ($w -le 0 -or $h -le 0) { return $null }
    return @{ Width = $w; Height = $h }
}

function Get-HybridResolutionReferencePixels {
    <#
    .SYNOPSIS
      SBS full frame (w >= 2*h) uses coded width; else longer edge. Same idea as Loop Segments nK tier.
    #>
    param(
        [int] $Width,
        [int] $Height
    )
    if ($Width -le 0 -or $Height -le 0) { return 0 }
    if ($Width -ge ($Height * 2)) { return $Width }
    if ($Width -ge $Height) { return $Width }
    return $Height
}

function Get-HybridWorkflowConfigCandidates {
    param(
        [string] $MediaFullPath = '',
        [string] $MediaRoot = '',
        [string] $ConfigPath = ''
    )
    $list = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([string] $p)
        if ([string]::IsNullOrWhiteSpace($p)) { return }
        try {
            $full = [System.IO.Path]::GetFullPath($p.Trim())
        } catch {
            return
        }
        if ($list -notcontains $full) { [void]$list.Add($full) }
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { & $add $ConfigPath }
    $envCfg = [string]$env:HYBRID_WORKFLOW_CONFIG
    if (-not [string]::IsNullOrWhiteSpace($envCfg)) { & $add $envCfg }
    if (-not [string]::IsNullOrWhiteSpace($MediaRoot)) {
        & $add (Join-Path $MediaRoot 'hybrid_workflow.json')
        & $add (Join-Path $MediaRoot '3d_playlist_local\hybrid_workflow.json')
    }
    if (-not [string]::IsNullOrWhiteSpace($MediaFullPath)) {
        try {
            $cur = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($MediaFullPath))
            for ($i = 0; $i -lt 8 -and -not [string]::IsNullOrWhiteSpace($cur); $i++) {
                & $add (Join-Path $cur 'hybrid_workflow.json')
                & $add (Join-Path $cur '3d_playlist_local\hybrid_workflow.json')
                $parent = [System.IO.Path]::GetDirectoryName($cur)
                if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cur) { break }
                $cur = $parent
            }
        } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $playlistLocal = Split-Path -Parent $PSScriptRoot
        & $add (Join-Path $playlistLocal 'hybrid_workflow.json')
        & $add (Join-Path $PSScriptRoot 'hybrid_workflow.json')
    }
    & $add 'P:\all_scripts\3d_playlist_local\hybrid_workflow.json'
    return @($list)
}

function ConvertTo-HybridPositiveInt {
    param(
        $Raw,
        [hashtable] $LabelMap = $null
    )
    if ($null -eq $Raw) { return $null }
    $n = 0
    if ($Raw -is [string]) {
        $s = ([string]$Raw).Trim()
        if ($null -ne $LabelMap -and $LabelMap.ContainsKey($s.ToLowerInvariant())) {
            return [int]$LabelMap[$s.ToLowerInvariant()]
        }
        if ($s -match '^(?i)(\d+)\s*px?$') { $s = $Matches[1] }
        if ($s -match '^(?i)(\d+)\s*k$') {
            return [int]$Matches[1]
        }
        if (-not [int]::TryParse($s, [ref]$n)) { return $null }
    } else {
        try { $n = [int]$Raw } catch { return $null }
    }
    if ($n -lt 1) { return $null }
    return $n
}

function ConvertTo-HybridWorkflowKind {
    param($Raw)
    if ($null -eq $Raw) { return $null }
    $s = ([string]$Raw).Trim().ToLowerInvariant()
    if ($s -in @('asis', 'flat', 'fisheye')) { return $s }
    return $null
}

function ConvertTo-HybridSegmentSuffix {
    param($Raw)
    if ($null -eq $Raw) { return $null }
    $s = ([string]$Raw).Trim() -replace '[\\/:*?"<>|]', '_'
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s
}

function Get-HybridWorkflowConfigDefaults {
    return @{
        AsisAboveReferencePx           = [int]$script:HybridAsisAboveReferencePxDefault
        FlatNonHevcAv1MaxKbps          = [int]$script:HybridFlatNonHevcAv1MaxKbpsDefault
        FlatHevcAv1MaxKbps             = [int]$script:HybridFlatHevcAv1MaxKbpsDefault
        DefaultKindWhenBitrateUnknown  = [string]$script:HybridDefaultKindWhenBitrateUnknownDefault
        AsisSegmentSuffix              = [string]$script:HybridAsisSegmentSuffixDefault
        Source                         = 'defaults'
    }
}

function Read-HybridWorkflowConfigFromFile {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-Warning ("Could not read hybrid_workflow.json {0}: {1}" -f $Path, $_.Exception.Message)
        return $null
    }
    $cfg = Get-HybridWorkflowConfigDefaults
    $cfg.Source = $Path
    $any = $false

    $pxRaw = $null
    foreach ($key in @('asisAboveReferencePx', 'streamCopyAboveReferencePx', 'over2KReferencePx')) {
        if ($null -ne $doc.PSObject.Properties[$key] -and $null -ne $doc.$key) {
            $pxRaw = $doc.$key
            break
        }
    }
    $px = ConvertTo-HybridPositiveInt -Raw $pxRaw -LabelMap @{ '2k' = 2048; '4k' = 3840 }
    if ($null -ne $px) { $cfg.AsisAboveReferencePx = [int]$px; $any = $true }

    $flatNon = $null
    foreach ($key in @('flatNonHevcAv1MaxKbps', 'flatNonHevcAv1MaxKbpsThreshold')) {
        if ($null -ne $doc.PSObject.Properties[$key] -and $null -ne $doc.$key) {
            $flatNon = ConvertTo-HybridPositiveInt -Raw $doc.$key
            break
        }
    }
    if ($null -eq $flatNon -and $null -ne $doc.PSObject.Properties['flatNonHevcAv1MaxBps'] -and $null -ne $doc.flatNonHevcAv1MaxBps) {
        $bps = ConvertTo-HybridPositiveInt -Raw $doc.flatNonHevcAv1MaxBps
        if ($null -ne $bps) { $flatNon = [int][Math]::Max(1, [Math]::Round($bps / 1000.0)) }
    }
    if ($null -ne $flatNon) { $cfg.FlatNonHevcAv1MaxKbps = [int]$flatNon; $any = $true }

    $flatHevc = $null
    foreach ($key in @('flatHevcAv1MaxKbps', 'flatHevcAv1MaxKbpsThreshold')) {
        if ($null -ne $doc.PSObject.Properties[$key] -and $null -ne $doc.$key) {
            $flatHevc = ConvertTo-HybridPositiveInt -Raw $doc.$key
            break
        }
    }
    if ($null -eq $flatHevc -and $null -ne $doc.PSObject.Properties['flatHevcAv1MaxBps'] -and $null -ne $doc.flatHevcAv1MaxBps) {
        $bps = ConvertTo-HybridPositiveInt -Raw $doc.flatHevcAv1MaxBps
        if ($null -ne $bps) { $flatHevc = [int][Math]::Max(1, [Math]::Round($bps / 1000.0)) }
    }
    if ($null -ne $flatHevc) { $cfg.FlatHevcAv1MaxKbps = [int]$flatHevc; $any = $true }

    if ($null -ne $doc.PSObject.Properties['defaultKindWhenBitrateUnknown'] -and $null -ne $doc.defaultKindWhenBitrateUnknown) {
        $kind = ConvertTo-HybridWorkflowKind -Raw $doc.defaultKindWhenBitrateUnknown
        if ($null -ne $kind) { $cfg.DefaultKindWhenBitrateUnknown = $kind; $any = $true }
    }

    foreach ($key in @('asisSegmentSuffix', 'asIsSegmentSuffix', 'streamCopySegmentSuffix')) {
        if ($null -ne $doc.PSObject.Properties[$key] -and $null -ne $doc.$key) {
            $suf = ConvertTo-HybridSegmentSuffix -Raw $doc.$key
            if ($null -ne $suf) { $cfg.AsisSegmentSuffix = $suf; $any = $true }
            break
        }
    }

    if (-not $any) { return $null }
    return $cfg
}

function Get-HybridWorkflowConfig {
    <#
    .SYNOPSIS
      Load hybrid_workflow.json (routing thresholds + as-is suffix). Defaults when missing.
    #>
    param(
        [string] $MediaFullPath = '',
        [string] $MediaRoot = '',
        [string] $ConfigPath = '',
        [switch] $ForceReload
    )
    if (-not $ForceReload.IsPresent -and $null -ne $script:HybridWorkflowConfigCached) {
        return $script:HybridWorkflowConfigCached
    }
    $cfg = Get-HybridWorkflowConfigDefaults
    foreach ($cand in @(Get-HybridWorkflowConfigCandidates -MediaFullPath $MediaFullPath `
            -MediaRoot $MediaRoot -ConfigPath $ConfigPath)) {
        $fromFile = Read-HybridWorkflowConfigFromFile -Path $cand
        if ($null -eq $fromFile) { continue }
        $cfg = $fromFile
        break
    }
    $script:HybridWorkflowConfigCached = $cfg
    $script:HybridWorkflowConfigSource = [string]$cfg.Source
    $script:HybridAsisAboveReferencePxCached = [int]$cfg.AsisAboveReferencePx
    $script:HybridAsisAboveReferencePxSource = [string]$cfg.Source
    return $cfg
}

function Get-HybridAsisAboveReferencePx {
    <#
    .SYNOPSIS
      Threshold for as-is stream-copy: reference pixels GREATER THAN this value.
      Default 2048 (2K). Loads hybrid_workflow.json when present.
    #>
    param(
        [string] $MediaFullPath = '',
        [string] $MediaRoot = '',
        [string] $ConfigPath = '',
        [switch] $ForceReload
    )
    $cfg = Get-HybridWorkflowConfig -MediaFullPath $MediaFullPath -MediaRoot $MediaRoot `
        -ConfigPath $ConfigPath -ForceReload:$ForceReload
    return @{
        Px     = [int]$cfg.AsisAboveReferencePx
        Source = [string]$cfg.Source
    }
}

function Resolve-HybridWorkflowRoute {
    <#
    .SYNOPSIS
      Returns workflow kind 'asis', 'flat', or 'fisheye' plus probe details for logging.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $MediaFullPath,
        [string] $FfprobeExe = '',
        [long] $FlatNonHevcAv1MaxBps = 0,
        [long] $FlatHevcAv1MaxBps = 0,
        [int] $Over2KReferencePx = 0,
        [string] $MediaRoot = '',
        [string] $HybridWorkflowConfigPath = '',
        [string] $DefaultKindWhenBitrateUnknown = '',
        [string] $AsisSegmentSuffix = ''
    )
    $full = [System.IO.Path]::GetFullPath($MediaFullPath)
    if ([string]::IsNullOrWhiteSpace($FfprobeExe)) {
        $FfprobeExe = Get-HybridFfprobeExePath
    }
    $cfg = Get-HybridWorkflowConfig -MediaFullPath $full -MediaRoot $MediaRoot `
        -ConfigPath $HybridWorkflowConfigPath

    if ($Over2KReferencePx -gt 0) {
        $over2kPx = $Over2KReferencePx
        $thresholdSource = '-Over2KReferencePx'
    } else {
        $over2kPx = [int]$cfg.AsisAboveReferencePx
        $thresholdSource = [string]$cfg.Source
    }

    $flatNonHevcMaxBps = if ($FlatNonHevcAv1MaxBps -gt 0) {
        [long]$FlatNonHevcAv1MaxBps
    } else {
        [long]$cfg.FlatNonHevcAv1MaxKbps * 1000L
    }
    $flatHevcMaxBps = if ($FlatHevcAv1MaxBps -gt 0) {
        [long]$FlatHevcAv1MaxBps
    } else {
        [long]$cfg.FlatHevcAv1MaxKbps * 1000L
    }
    $unknownKind = ConvertTo-HybridWorkflowKind -Raw $DefaultKindWhenBitrateUnknown
    if ($null -eq $unknownKind) { $unknownKind = [string]$cfg.DefaultKindWhenBitrateUnknown }
    $asisSuffix = ConvertTo-HybridSegmentSuffix -Raw $AsisSegmentSuffix
    if ($null -eq $asisSuffix) { $asisSuffix = [string]$cfg.AsisSegmentSuffix }
    if ([string]::IsNullOrWhiteSpace($asisSuffix)) {
        $asisSuffix = if (Get-Command Get-AsIsDlnaSegmentSuffix -ErrorAction SilentlyContinue) {
            Get-AsIsDlnaSegmentSuffix -FullPath $full
        } else {
            'LR_180'
        }
    }

    $codec = $null
    $bps = $null
    $bpsSource = ''
    $width = $null
    $height = $null
    $refPx = $null
    if (-not [string]::IsNullOrWhiteSpace($FfprobeExe)) {
        $dims = Get-HybridVideoDimensions -MediaPath $full -FfprobeExe $FfprobeExe
        if ($null -ne $dims) {
            $width = [int]$dims.Width
            $height = [int]$dims.Height
            $refPx = Get-HybridResolutionReferencePixels -Width $width -Height $height
        }
        $codec = Get-HybridVideoCodecName -MediaPath $full -FfprobeExe $FfprobeExe
        $bps = Get-HybridFormatBitrateBps -MediaPath $full -FfprobeExe $FfprobeExe
        if ($null -ne $bps) {
            $bpsSource = 'format'
        } else {
            $bps = Get-HybridVideoStreamBitrateBps -MediaPath $full -FfprobeExe $FfprobeExe
            if ($null -ne $bps) { $bpsSource = 'stream' }
        }
    }

    $isHevcAv1 = Test-HybridHevcOrAv1Codec -CodecName $codec
    $codecLabel = if ([string]::IsNullOrWhiteSpace($codec)) { 'unknown' } else { $codec }
    $kbpsLabel = if ($null -eq $bps) { 'unknown' } else { [string][math]::Round([double]$bps / 1000.0) }
    $dimLabel = if ($null -ne $width -and $null -ne $height) { "${width}x${height}" } else { 'unknown' }
    $flatNonKbps = [int][Math]::Round($flatNonHevcMaxBps / 1000.0)
    $flatHevcKbps = [int][Math]::Round($flatHevcMaxBps / 1000.0)

    $kind = 'fisheye'
    $reason = ''
    $suffix = 'LR_180_FISHEYE'

    # Above configured reference px: stream-copy remux like 3d_loop_segments (skip flat/fisheye encode).
    if ($null -ne $refPx -and $refPx -gt $over2kPx) {
        $kind = 'asis'
        $suffix = $asisSuffix
        $reason = ("resolution {0} ref={1}px > {2} ({3}) -> stream-copy like 3d_loop_segments" -f `
            $dimLabel, $refPx, $over2kPx, $thresholdSource)
    } elseif ($null -eq $bps) {
        $kind = $unknownKind
        if ($kind -eq 'asis') {
            $suffix = $asisSuffix
        } elseif ($kind -eq 'flat') {
            $suffix = 'Full_SBS'
        } else {
            $kind = 'fisheye'
            $suffix = 'LR_180_FISHEYE'
        }
        $reason = ("bitrate unavailable (codec=$codecLabel; $dimLabel); default {0} ({1})" -f $kind, $cfg.Source)
    } elseif ($isHevcAv1) {
        if ($bps -lt $flatHevcMaxBps) {
            $kind = 'flat'
            $suffix = 'Full_SBS'
            $reason = ("hevc/av1 ~{0} kbps < {1} kbps -> flat" -f $kbpsLabel, $flatHevcKbps)
        } else {
            $kind = 'fisheye'
            $suffix = 'LR_180_FISHEYE'
            $reason = ("hevc/av1 ~{0} kbps >= {1} kbps -> fisheye" -f $kbpsLabel, $flatHevcKbps)
        }
    } else {
        if ($bps -lt $flatNonHevcMaxBps) {
            $kind = 'flat'
            $suffix = 'Full_SBS'
            $reason = ("non-hevc/av1 ($codecLabel) ~{0} kbps < {1} kbps -> flat" -f $kbpsLabel, $flatNonKbps)
        } else {
            $kind = 'fisheye'
            $suffix = 'LR_180_FISHEYE'
            $reason = ("non-hevc/av1 ($codecLabel) ~{0} kbps >= {1} kbps -> fisheye" -f $kbpsLabel, $flatNonKbps)
        }
    }

    return @{
        Kind                          = $kind
        Suffix                        = $suffix
        CodecName                     = $codecLabel
        BitrateBps                    = $bps
        BitrateKbps                   = if ($null -eq $bps) { $null } else { [math]::Round([double]$bps / 1000.0) }
        BitrateSource                 = $bpsSource
        IsHevcAv1                     = $isHevcAv1
        Width                         = $width
        Height                        = $height
        ReferencePixels               = $refPx
        AsisAboveReferencePx          = $over2kPx
        AsisThresholdSource           = $thresholdSource
        FlatNonHevcAv1MaxKbps         = $flatNonKbps
        FlatHevcAv1MaxKbps            = $flatHevcKbps
        DefaultKindWhenBitrateUnknown = $unknownKind
        AsisSegmentSuffix             = $asisSuffix
        ConfigSource                  = [string]$cfg.Source
        Reason                        = $reason
        MediaPath                     = $full
    }
}

function Get-HybridVideoFrameRateFraction {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    if ([string]::IsNullOrWhiteSpace($MediaPath) -or -not (Test-Path -LiteralPath $MediaPath -PathType Leaf)) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($FfprobeExe)) {
        $FfprobeExe = Get-HybridFfprobeExePath
    }
    $raw = Invoke-HybridFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=avg_frame_rate',
        '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
    )
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -eq '' -or $s -eq '0/0' -or $s -eq 'N/A') {
        $raw = Invoke-HybridFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
            '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=r_frame_rate',
            '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
        )
        $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    }
    if ($s -match '^(\d+)/(\d+)$') {
        $num = [int64]$Matches[1]
        $den = [int64]$Matches[2]
        if ($num -gt 0 -and $den -gt 0) {
            return @{ Num = $num; Den = $den }
        }
    }
    return $null
}

function ConvertTo-QsvIntegerFrameRateFraction {
    param([int64] $Num, [int64] $Den)
    $fps = if ($Num -gt 0 -and $Den -gt 0) { [double]$Num / [double]$Den } else { 30.0 }
    $snapped = 30
    $hit = $false
    foreach ($t in @(24, 25, 30, 50, 60, 120)) {
        if ([Math]::Abs($fps - $t) -lt 0.08) {
            $snapped = $t
            $hit = $true
            break
        }
    }
    if (-not $hit) {
        $snapped = [int][Math]::Round($fps)
        if ($snapped -lt 5) { $snapped = 5 }
        if ($snapped -gt 120) { $snapped = 120 }
    }
    return @{ Num = [int64]$snapped; Den = 1L }
}

function Get-FlatTempAvsFileName {
    param([string] $MediaFullPath)
    $name = [System.IO.Path]::GetFileName($MediaFullPath)
    return "StreamTo3D.flat_temp.$name.avs"
}

function Export-FlatPassthroughAvsFromTemplate {
    <#
    .SYNOPSIS
      Build a flat Full-SBS AVS from StreamTo3D.fisheye_temp.template.avs (no StreamTo3D GUI).
      Placeholder StreamTo3D_input.mp4 -> source media; mono/narrow frames are StackHorizontal-duplicated to SBS.
      DirectShowSource has no fps=/convertfps (graph FRC blends). AssumeFPS tags integer CFR for QSV.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $MediaFullPath,
        [Parameter(Mandatory = $true)]
        [string] $AvsOutFullPath,
        [string] $TemplatePath = '',
        [string] $FfprobeExe = ''
    )
    $mediaFull = [System.IO.Path]::GetFullPath($MediaFullPath)
    if (-not (Test-Path -LiteralPath $mediaFull -PathType Leaf)) {
        throw "Flat template AVS source media missing: $mediaFull"
    }

    if ([string]::IsNullOrWhiteSpace($TemplatePath)) {
        $scriptDir = $PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($scriptDir)) {
            $scriptDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
        }
        $TemplatePath = Join-Path $scriptDir 'StreamTo3D.fisheye_temp.template.avs'
    }
    $templateFull = [System.IO.Path]::GetFullPath($TemplatePath)
    if (-not (Test-Path -LiteralPath $templateFull -PathType Leaf)) {
        throw "Flat AVS template not found: $templateFull"
    }

    $template = [IO.File]::ReadAllText($templateFull)
    $placeholder = 'StreamTo3D_input.mp4'
    $count = ([regex]::Matches($template, [regex]::Escape($placeholder))).Count
    if ($count -lt 1) {
        throw "Template missing placeholder '$placeholder': $templateFull"
    }

    $fpsNum = 30000
    $fpsDen = 1001
    if ([string]::IsNullOrWhiteSpace($FfprobeExe)) {
        $FfprobeExe = Get-HybridFfprobeExePath
    }
    $fpsParts = Get-HybridVideoFrameRateFraction -MediaPath $mediaFull -FfprobeExe $FfprobeExe
    if ($null -ne $fpsParts) {
        $fpsNum = $fpsParts.Num
        $fpsDen = $fpsParts.Den
    }
    $qsvFps = ConvertTo-QsvIntegerFrameRateFraction -Num $fpsNum -Den $fpsDen
    $fpsNum = $qsvFps.Num
    $fpsDen = $qsvFps.Den

    $avsContent = $template.Replace($placeholder, $mediaFull)
    $avsContent = $avsContent.Replace('StreamTo3D_fps_num=30000', "StreamTo3D_fps_num=$fpsNum")
    $avsContent = $avsContent.Replace('StreamTo3D_fps_den=1001', "StreamTo3D_fps_den=$fpsDen")

    $outAvsDir = [System.IO.Path]::GetDirectoryName($AvsOutFullPath)
    if (-not (Test-Path -LiteralPath $outAvsDir)) {
        New-Item -ItemType Directory -Path $outAvsDir -Force | Out-Null
    }
    $avsOutFull = [System.IO.Path]::GetFullPath($AvsOutFullPath)
    [IO.File]::WriteAllText($avsOutFull, $avsContent, [Text.UTF8Encoding]::new($false))
    Write-Host ("Exported flat AVS ({0}x '{1}' -> media; fps {2}/{3}): {4}" -f `
        $count, $placeholder, $fpsNum, $fpsDen, $avsOutFull)
    return $avsOutFull
}
