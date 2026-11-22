<#
.SYNOPSIS
  Fisheye output background color (the area around each eye's fisheye circle): black, green, red or blue.

.DESCRIPTION
  Dot-sourced by Run-FisheyeV360.ps1 (pass-1 mezzanine) and Run-TranscodeFfmpeg.ps1 (-Fisheye on .avs).
  Black is the default. Green / red / blue are pure key colors (#00FF00 / #FF0000 / #0000FF), so a
  chroma-key player (the Quest XR page, individual_transcode\xr) can key them out and show passthrough
  around the picture. ffmpeg's own color name 'green' is #008000, so the hex value is always passed.

  Order: the -FisheyeBackgroundColor parameter, else $env:FISHEYE_BACKGROUND_COLOR, else black.
  The fisheye and hybrid launchers (run_batch_fisheye_v360.ps1 / run_batch_vr_hybrid.ps1
  -FisheyeBackgroundColor green) set that env var, so every child (prepare, v360 mezzanine, pass-2,
  Quest XR page) sees the same color. Persistent default: setx FISHEYE_BACKGROUND_COLOR green
#>

$script:FisheyeBackgroundColors = [ordered]@{
    black = '000000'
    green = '00FF00'
    red   = 'FF0000'
    blue  = '0000FF'
}

function Resolve-FisheyeBackgroundColor {
    param([string] $Name = '')
    $raw = $Name
    $source = 'parameter'
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $env:FISHEYE_BACKGROUND_COLOR; $source = 'FISHEYE_BACKGROUND_COLOR' }
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = 'black'; $source = 'default' }
    $key = $raw.Trim().ToLowerInvariant()
    if (-not $script:FisheyeBackgroundColors.Contains($key)) {
        Write-Warning ("Fisheye background '{0}' ({1}) is not one of {2} - using black." -f $raw, $source, ($script:FisheyeBackgroundColors.Keys -join ', '))
        $key = 'black'
        $source = 'default'
    }
    $hex = $script:FisheyeBackgroundColors[$key]
    return [pscustomobject]@{
        Name   = $key
        Ffmpeg = "0x$hex"
        Css    = "#$($hex.ToLowerInvariant())"
        Source = $source
    }
}
