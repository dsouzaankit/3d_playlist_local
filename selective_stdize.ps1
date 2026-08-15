# Selective standardization: re-encode vertical (aspect < 1:1) media to a common MP4 layout.

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
    if ($lower -eq 'op_00.mp4' -or $lower -eq 'op_01.mp4') { return $true }
    return $false
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

Get-ChildItem -Path $InputDir -Include '*.ts', '*.mp4', '*.wmv', '*.mkv' | ForEach-Object {
    if (Test-SkipExportPipelineFile -Name $_.Name) {
        Write-Host "Skipping phone export file: $($_.Name)"
        return
    }

    $dims = Get-VideoDimensions -Path $_.FullName -WidthPropId $widthPropId -HeightPropId $heightPropId
    if (-not $dims) {
        Write-Warning "Could not read frame size for '$($_.Name)' - skipping."
        return
    }

    $aspect = $dims.Width / $dims.Height
    Write-Host "Dimensions for '$($_.Name)': $($dims.Width)x$($dims.Height) ($($dims.Source)), aspect=$aspect"
    if ($aspect -ge 1) {
        Write-Host "  Not vertical (aspect >= 1:1). Skipping."
        return
    }

    $OutputExtension = '.mp4'
    $BaseNameNoQuote = $_.BaseName.Replace("'", '')
    $DestinationPath = Join-Path -Path $OutputDir -ChildPath ($BaseNameNoQuote + $OutputExtension)

    if (Test-Path -LiteralPath $DestinationPath) {
        Write-Host "Already exists: $DestinationPath. Skipping."
        return
    }

    $InputFile = $_.FullName
    $OutputFile = $DestinationPath
    $Arguments = "-init_hw_device d3d11va=hw -filter_hw_device hw -i `"$InputFile`" -/filter_complex filter_complex_fhd.txt -map `"[vout]`" -map `"[aout]`"? -c:v hevc_qsv -global_quality 20 -c:a aac `"$OutputFile`""

    Write-Host "Processing: $InputFile"
    Write-Host "Output to: $OutputFile"
    Start-Process -FilePath $FFmpegPath -ArgumentList $Arguments -NoNewWindow -Wait
}

Write-Host 'Selective (aspect ratio < 1:1) batch standardization complete!'
