# This shuffles and combines multiple media files into single file

Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Attach/map p-cloud network drive first!
$FilePath = "P:\_My Videos\pCloud.mp4" # Replace with the actual path to sample mp4!
# Replace below with the name of the property you are looking for (e.g., "Title", "Subject", "Date created")
$PropertyName = "Frame width"		# 324
# $PropertyName = "Frame height"	# 322 
# $vidBitratePropId = 328 # default Id for video bitrate, but this changes with Windows version!

$Shell = New-Object -ComObject Shell.Application
$folder = $Shell.Namespace((Split-Path -Parent $FilePath))
$file = $folder.ParseName((Split-Path -Leaf $FilePath))

# Iterate through all possible property IDs to find the matching name
for ($i = 0; $i -lt 400; $i++) { # You can adjust the upper limit of the loop if needed
    $propName = $folder.GetDetailsOf($null, $i)
    if ($propName -eq $PropertyName) {
        $propid = $i
        Write-Host "Property '$PropertyName' has Property ID: $propid"
        # $vidBitratePropId = $i
        break
    }
}

if (-not (Get-Variable -Name propid -ErrorAction SilentlyContinue)) {
    Write-Host "Property '$PropertyName' not found for file '$FilePath'."
}


# Define Input and Output directories
$InputDir = "..\*"
$OutputDir = "standardized"
$FFmpegPath = "ffmpeg.exe"

# Create the output directory if it doesn't exist
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory | Out-Null
}

# Get all media files in the input directory and loop through them
Get-ChildItem -Path $InputDir -Include "*.ts","*.mp4","*.wmv","*.mkv" | ForEach-Object {

    $Folder = $Shell.Namespace($_.DirectoryName)
    $File = $Folder.ParseName($_.Name)
    $defaultValue = 1
    $FrmW = $Folder.GetDetailsOf($File, 324) ?? $defaultValue
    $FrmH = $Folder.GetDetailsOf($File, 322) ?? $defaultValue
    $Var = $FrmW / $FrmH
    if ($Var -ge 1) {
        Write-Host "Video '$($_.Name)' has aspect ratio: '$($Var)' >= 1:1 (its not vertical). Skipping standardization!"
        return # To skip current iteration and continue in a ForEach-Object, use return instead of continue!
    }

    # re-encode to a common container!
    $OutputExtension = ".mp4"
    
    # remove single quotes from filename
    $BaseNameNoQuote = $_.BaseName.Replace("'", "")

    # Construct the full path of the potential destination file
    $DestinationPath = Join-Path -Path $OutputDir -ChildPath $($BaseNameNoQuote + $OutputExtension)

    # Check if the file already exists in the destination
    if (Test-Path -Path $DestinationPath -PathType Leaf) {
        Write-Host "File '$($_.Name)' already exists in $OutputDir. Skipping..."
        return # Skip the rest of the code in this iteration and move to the next file
          # To skip current iteration and continue in a ForEach-Object, use return instead of continue!
    }

    $InputFile = $_.FullName
    $OutputFile = Join-Path -Path $OutputDir -ChildPath $($BaseNameNoQuote + $OutputExtension)

    # Build the full FFmpeg command arguments
    # Note: Use backticks (`) to escape quotes within the string, as required by PowerShell for external commands.
    # Optional stream mapping (?) syntax doesn't seem to work? Move them to 'no_audio' folder and ignore
    $Arguments = "-init_hw_device d3d11va=hw -filter_hw_device hw -i `"$InputFile`" -/filter_complex filter_complex_fhd.txt -map `"[vout]`" -map `"[aout]`"? -c:v hevc_qsv -global_quality 20 -c:a aac `"$OutputFile`""
    # $Arguments = "-i `"$InputFile`" -/filter_complex filter_complex_vr.txt -map `"[vout]`" -map `"[aout]`" -c:v libx264 -preset medium -crf 20 -c:a aac `"$OutputFile`""

    Write-Host "Processing: $InputFile"
    Write-Host "Output to: $OutputFile"

    # Execute the FFmpeg command
    # The -NoNewWindow and -Wait parameters ensure the script runs smoothly and waits for each file to finish
    Start-Process -FilePath $FFmpegPath -ArgumentList $Arguments -NoNewWindow -Wait
}

Write-Host "Selective (aspect ratio < 1:1) batch standardization complete!"
