# PC -> Quest LAN bandwidth (measured by the Quest control page on the headset at workflow start,
# ios_3d_loop_segments\windows\quest\Serve-QuestControlPage.ps1) -> DLNA minute-segment bitrate.
# Result file: %TEMP%\loopsegments-quest-lan-throughput.json
#   { measuredMbps, recommendedMaxMediaBitrateMbps (80%, 5-100; returned capped at 80), measuredAtUtc, ... }
# Dot-source; Get-QuestLanSegmentBitrateMbps returns @{ Mbps; Source } or $null (no result, or older
# than -MaxAgeHours, default 12; QUEST_LAN_BITRATE_MAX_AGE_HOURS overrides).

function Get-QuestLanSegmentBitrateMbps {
    param([double] $MaxAgeHours = 12)
    if ([string]$env:QUEST_LAN_BITRATE_MAX_AGE_HOURS -match '^\s*(\d+(?:\.\d+)?)\s*$') { $MaxAgeHours = [double]$Matches[1] }
    $path = Join-Path $env:TEMP 'loopsegments-quest-lan-throughput.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        $rec = 0
        if ($null -ne $doc.recommendedMaxMediaBitrateMbps) { $rec = [int]$doc.recommendedMaxMediaBitrateMbps }
        if ($rec -le 0) { return $null }
        # Intel av1_qsv CBR breaks down near 100M: frames get padded to the budget but coded at a
        # far worse QP (blocky / "hazy" output, ~33 dB vs ~42 dB at <=95M on 2560x720@24).
        # 80M keeps a margin; quality is already flat from ~20M on typical sources.
        if ($rec -gt 80) { $rec = 80 }
        # ConvertFrom-Json may already have turned the ISO string into a DateTime.
        $at = if ($doc.measuredAtUtc -is [DateTime]) { $doc.measuredAtUtc } else { [DateTime]::Parse([string]$doc.measuredAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
        $ageH = ([DateTime]::UtcNow - $at.ToUniversalTime()).TotalHours
        if ($ageH -gt $MaxAgeHours) { return $null }
        return [pscustomobject]@{
            Mbps   = $rec
            Source = ('PC->Quest LAN test {0} Mbps, {1:0} min ago ({2})' -f $doc.measuredMbps, ($ageH * 60), $path)
        }
    } catch {
        Write-Warning ("Could not read Quest LAN result {0}: {1}" -f $path, $_.Exception.Message)
        return $null
    }
}
