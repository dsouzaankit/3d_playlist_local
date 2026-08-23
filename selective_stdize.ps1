# Selective standardization: re-encode vertical (aspect < 1:1) media to a common MP4 layout.
# Faststart (moov at file head) applies to every MP4/MOV/M4V in the media folder, not only
# vertical clips. Existing standardized encodes without moov in the first 768 KB are remuxed.

Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

function Get-ShellDetailPropertyId {
    param(
        [Parameter(Mandatory)]
        [string] $PropertyName,
        [int] $MaxId = 400
    )
    $shell = New-Object -ComObject Shell.Application
    # Property column names are global; any local folder works (not L: / UNC).
    $folder = $shell.Namespace($env:WINDIR)
    if (-not $folder) { return $null }
    for ($i = 0; $i -lt $MaxId; $i++) {
        if ($folder.GetDetailsOf($null, $i) -eq $PropertyName) {
            return $i
        }
    }
    return $null
}

function Get-VideoDimensions {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [int] $WidthPropId,
        [int] $HeightPropId
    )

    $ffprobe = Get-Command ffprobe.exe -ErrorAction SilentlyContinue
    if ($ffprobe) {
        $jsonText = & $ffprobe.Source -v error -select_streams v:0 -show_entries stream=width,height -of json "$Path" 2>$null
        if ($jsonText) {
            $json = $jsonText | ConvertFrom-Json
            if ($json.streams -and $json.streams[0].width -and $json.streams[0].height) {
                return [pscustomobject]@{
                    Width  = [int]$json.streams[0].width
                    Height = [int]$json.streams[0].height
                    Source = 'ffprobe'
                }
            }
        }
    }

    if ($null -eq $WidthPropId -or $null -eq $HeightPropId) { return $null }

    $shell = New-Object -ComObject Shell.Application
    $folder = $shell.Namespace((Split-Path -Parent $Path))
    if (-not $folder) { return $null }
    $file = $folder.ParseName((Split-Path -Leaf $Path))
    if (-not $file) { return $null }

    $wRaw = ($folder.GetDetailsOf($file, $WidthPropId) -replace '[^\d]', '').Trim()
    $hRaw = ($folder.GetDetailsOf($file, $HeightPropId) -replace '[^\d]', '').Trim()
    if ($wRaw -match '^\d+$' -and $hRaw -match '^\d+$' -and [int]$wRaw -gt 0 -and [int]$hRaw -gt 0) {
        return [pscustomobject]@{ Width = [int]$wRaw; Height = [int]$hRaw; Source = 'shell' }
    }
    return $null
}

function Test-SkipExportPipelineFile {
    param([string] $Name)
    $lower = $Name.ToLowerInvariant()
    if ($lower -like '_vanilla_download*') { return $true }
    if ($lower -like '_working*') { return $true }
    if ($lower -like '.faststart-temp-*') { return $true }
    if ($lower -eq 'op_00.mp4' -or $lower -eq 'op_01.mp4') { return $true }
    return $false
}

function Test-FaststartContainer {
    param([string] $Extension)
    $ext = $Extension.ToLowerInvariant()
    return ($ext -eq '.mp4' -or $ext -eq '.mov' -or $ext -eq '.m4v')
}

function Test-Mp4MoovAtHead {
    param(
        [Parameter(Mandatory)]
        [string] $LiteralPath,
        [int] $ScanBytes = 786432
    )
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { return $false }
    $len = (Get-Item -LiteralPath $LiteralPath).Length
    if ($len -lt 9) { return $false }

    $toRead = [int][Math]::Min([int64]$ScanBytes, [int64]$len)
    $chunkSize = 65536
    $stream = [System.IO.File]::Open(
        $LiteralPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        $buf = New-Object byte[] $chunkSize
        $remaining = $toRead
        while ($remaining -gt 0) {
            $want = [Math]::Min($chunkSize, $remaining)
            $read = $stream.Read($buf, 0, $want)
            if ($read -le 0) { break }
            $ascii = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
            if ($ascii.Contains('moov')) { return $true }
            $remaining -= $read
        }
        return $false
    }
    finally {
        $stream.Dispose()
    }
}

function Invoke-FaststartRemux {
    param(
        [Parameter(Mandatory)]
        [string] $FFmpegPath,
        [Parameter(Mandatory)]
        [string] $SourcePath
    )
    $dir = [System.IO.Path]::GetDirectoryName($SourcePath)
    $ext = [System.IO.Path]::GetExtension($SourcePath)
    if ([string]::IsNullOrWhiteSpace($ext)) { $ext = '.mp4' }
    $tmp = Join-Path $dir ('.faststart-temp-' + [guid]::NewGuid().ToString('N') + $ext)
    Write-Host "  Remux faststart: $SourcePath"
    & $FFmpegPath -hide_banner -y -nostdin -i $SourcePath -c copy -movflags +faststart $tmp
    $exit = $LASTEXITCODE
    $ok = ($exit -eq 0) -and (Test-Path -LiteralPath $tmp -PathType Leaf) -and (Test-Mp4MoovAtHead -LiteralPath $tmp)
    if (-not $ok) {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        Write-Warning "Faststart remux failed (exit $exit): $SourcePath"
        return $false
    }
    try {
        Move-Item -LiteralPath $tmp -Destination $SourcePath -Force
        Write-Host "  Faststart applied (moov at head): $SourcePath"
        return $true
    }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-Warning "Faststart remux could not replace '$SourcePath': $_"
        return $false
    }
}

$widthPropId = Get-ShellDetailPropertyId -PropertyName 'Frame width'
$heightPropId = Get-ShellDetailPropertyId -PropertyName 'Frame height'
if ($null -eq $widthPropId -or $null -eq $heightPropId) {
    Write-Host "Shell column IDs not resolved (width=$widthPropId height=$heightPropId); using ffprobe for dimensions."
}

$InputDir = '..\*'
$OutputDir = 'standardized'
$FFmpegPath = 'ffmpeg.exe'

if (-not (Get-Command ffprobe.exe -ErrorAction SilentlyContinue)) {
    Write-Warning 'ffprobe.exe not on PATH. Install ffmpeg or add its folder to PATH (needed for files on L:).'
}

if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory | Out-Null
}

Get-ChildItem -Path $InputDir -Include '*.ts', '*.mp4', '*.wmv', '*.mkv', '*.mov', '*.m4v' | ForEach-Object {
    if (Test-SkipExportPipelineFile -Name $_.Name) {
        Write-Host "Skipping phone export file: $($_.Name)"
        return
    }

    $isFaststartContainer = Test-FaststartContainer -Extension $_.Extension
    if ($isFaststartContainer) {
        if (Test-Mp4MoovAtHead -LiteralPath $_.FullName) {
            Write-Host "Faststart already present: $($_.Name)"
        }
        else {
            Write-Host "moov not at head: $($_.FullName)"
            [void](Invoke-FaststartRemux -FFmpegPath $FFmpegPath -SourcePath $_.FullName)
        }
    }

    $dims = Get-VideoDimensions -Path $_.FullName -WidthPropId $widthPropId -HeightPropId $heightPropId
    if (-not $dims) {
        Write-Warning "Could not read frame size for '$($_.Name)' - skipping encode."
        return
    }

    $aspect = $dims.Width / $dims.Height
    Write-Host "Dimensions for '$($_.Name)': $($dims.Width)x$($dims.Height) ($($dims.Source)), aspect=$aspect"
    if ($aspect -ge 1) {
        Write-Host "  Not vertical (aspect >= 1:1). Skipping encode."
        return
    }

    $OutputExtension = '.mp4'
    $BaseNameNoQuote = $_.BaseName.Replace("'", '')
    $DestinationPath = Join-Path -Path $OutputDir -ChildPath ($BaseNameNoQuote + $OutputExtension)

    if (Test-Path -LiteralPath $DestinationPath) {
        if (Test-Mp4MoovAtHead -LiteralPath $DestinationPath) {
            Write-Host "Already exists (faststart): $DestinationPath. Skipping."
        }
        else {
            Write-Host "Already exists, moov not at head: $DestinationPath"
            [void](Invoke-FaststartRemux -FFmpegPath $FFmpegPath -SourcePath $DestinationPath)
        }
        return
    }

    $InputFile = $_.FullName
    $OutputFile = $DestinationPath
    $Arguments = "-init_hw_device d3d11va=hw -filter_hw_device hw -i `"$InputFile`" -/filter_complex filter_complex_fhd.txt -map `"[vout]`" -map `"[aout]`"? -c:v hevc_qsv -global_quality 20 -c:a aac -movflags +faststart `"$OutputFile`""

    Write-Host "Processing: $InputFile"
    Write-Host "Output to: $OutputFile"
    Start-Process -FilePath $FFmpegPath -ArgumentList $Arguments -NoNewWindow -Wait

    if (-not (Test-Path -LiteralPath $OutputFile -PathType Leaf)) {
        Write-Warning "Encode produced no output: $OutputFile"
        return
    }
    if (Test-Mp4MoovAtHead -LiteralPath $OutputFile) {
        Write-Host "  Faststart present (moov at head)."
    }
    else {
        Write-Host "  Encode wrote moov at EOF; remuxing faststart."
        [void](Invoke-FaststartRemux -FFmpegPath $FFmpegPath -SourcePath $OutputFile)
    }
}

Write-Host 'Selective batch complete (faststart all MP4/MOV/M4V; vertical encode to standardized).'
