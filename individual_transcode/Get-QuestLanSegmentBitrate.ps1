# PC -> Quest LAN bandwidth -> DLNA minute-segment bitrate (this repo's rule).
#
# The measurement comes from the shared Quest control page (quest_tools QuestControlHost.ps1, its
# built-in PC -> Quest tile, run on the headset at workflow start): %TEMP%\quest-lan-throughput.json
#   { ok, measuredMbps, bytes, seconds, client, measuredAtUtc }
# The older control page wrote %TEMP%\loopsegments-quest-lan-throughput.json (same fields plus its
# own recommendation); the newer of the two files is used, and the rule below is always applied here.
#
# Rule: 80% of the measured Mbps, at least 5, at most 80. Not 100: Intel av1_qsv CBR near 100M pads
# frames to the budget but codes them far worse (blocky / "hazy" segments, ~33 dB vs ~42 dB at
# <= 95M on 2560x720@24); quality is flat from ~20M on typical sources.
#
# Dot-source. Get-QuestLanSegmentBitrateMbps returns @{ Mbps; MeasuredMbps; AgeMinutes; Source } or
# $null (no result, or older than -MaxAgeHours, default 12; QUEST_LAN_BITRATE_MAX_AGE_HOURS overrides).

$script:QuestLanResultPath = Join-Path $env:TEMP 'quest-lan-throughput.json'
$script:QuestLanLegacyResultPath = Join-Path $env:TEMP 'loopsegments-quest-lan-throughput.json'
$script:QuestLanHeadroom = 0.8
$script:QuestLanMinMbps = 5
$script:QuestLanMaxMbps = 80

function Get-QuestLanSegmentBitrateRule {
    param([double] $MeasuredMbps)
    $rec = [int][Math]::Floor($MeasuredMbps * $script:QuestLanHeadroom)
    if ($rec -lt $script:QuestLanMinMbps) { $rec = $script:QuestLanMinMbps }
    if ($rec -gt $script:QuestLanMaxMbps) { $rec = $script:QuestLanMaxMbps }
    return $rec
}

# One result file as @{ MeasuredMbps; At (UTC); Path } or $null.
function Read-QuestLanResultFile {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        $m = 0.0
        if ($null -ne $doc.measuredMbps) { $m = [double]$doc.measuredMbps }
        if ($m -le 0) { return $null }
        # ConvertFrom-Json may already have turned the ISO string into a DateTime.
        $at = if ($doc.measuredAtUtc -is [DateTime]) { $doc.measuredAtUtc } else { [DateTime]::Parse([string]$doc.measuredAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
        return [pscustomobject]@{ MeasuredMbps = $m; At = $at.ToUniversalTime(); Path = $Path }
    } catch {
        Write-Warning ("Could not read Quest LAN result {0}: {1}" -f $Path, $_.Exception.Message)
        return $null
    }
}

function Get-QuestLanSegmentBitrateMbps {
    param([double] $MaxAgeHours = 12)
    if ([string]$env:QUEST_LAN_BITRATE_MAX_AGE_HOURS -match '^\s*(\d+(?:\.\d+)?)\s*$') { $MaxAgeHours = [double]$Matches[1] }
    $r = @(@(Read-QuestLanResultFile -Path $script:QuestLanResultPath) + @(Read-QuestLanResultFile -Path $script:QuestLanLegacyResultPath) |
            Where-Object { $_ } | Sort-Object At -Descending) | Select-Object -First 1
    if (-not $r) { return $null }
    $ageH = ([DateTime]::UtcNow - $r.At).TotalHours
    if ($ageH -gt $MaxAgeHours) { return $null }
    $mbps = Get-QuestLanSegmentBitrateRule -MeasuredMbps $r.MeasuredMbps
    return [pscustomobject]@{
        Mbps         = $mbps
        MeasuredMbps = $r.MeasuredMbps
        AgeMinutes   = [int]($ageH * 60)
        Source       = ('PC->Quest LAN test {0} Mbps, {1:0} min ago ({2}; 80%, 5-80)' -f $r.MeasuredMbps, ($ageH * 60), $r.Path)
    }
}

# The older result file, with this rule's recommendation, for 3d_playlist_local copies from before
# the shared control page (media folders not synced yet). Called by PlaylistControlTiles.ps1.
function Save-QuestLanLegacyResult {
    param($Result)
    if (-not $Result -or $null -eq $Result.measuredMbps) { return }
    $o = [ordered]@{
        ok = $true; path = 'pc->quest'; measuredMbps = [double]$Result.measuredMbps
        recommendedMaxMediaBitrateMbps = (Get-QuestLanSegmentBitrateRule -MeasuredMbps ([double]$Result.measuredMbps))
        recommendHeadroom = $script:QuestLanHeadroom
        bytes = $Result.bytes; seconds = $Result.seconds; client = $Result.client; measuredAtUtc = [string]$Result.measuredAtUtc
    }
    $tmp = "$($script:QuestLanLegacyResultPath).tmp"
    ($o | ConvertTo-Json -Compress) | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:QuestLanLegacyResultPath -Force
}
