<#
.SYNOPSIS
  Workflow start hook: Quest proximity sensor off + Quest control page on the headset and the PC.

.DESCRIPTION
  On by default in all three workflows: run_batch_vr_hybrid.ps1, run_batch_fisheye_v360.ps1 and
  Run-TranscodeOrchestrator.ps1 call it near their start (skipped only with -DryRun). Starts, hidden
  and without waiting, quest\Start-PlaylistLocalQuestSession.ps1 -WorkflowPid <this window> (this
  folder), which in the background holds the Quest proximity sensor off while the workflow runs,
  serves the Quest control page and opens it in Quest Browser. Nothing opens on the PC: this
  window prints a sign-in link to the page (http://127.0.0.1:18766/pc?t=...) for when you want it.
  The page's End session button runs quest\Invoke-PlaylistLocalQuestShutdown.ps1: stops the Quest
  players reading the output, presses Enter in every 3d_playlist_local window, quits the Loop
  Segments companion if it runs (its quit cleans up the Quest), else cleans
  up the Quest itself (tabs, history, sensor on, Wi-Fi off). The workflow's quit also stops the
  Quest players before renaming the segments, and when it ends by itself the same Quest cleanup runs.

  The Quest helpers themselves (adb, Quest Browser, control page server, settings) are in
  ios_3d_loop_segments\windows\quest. Never fails the workflow: a missing repo / pwsh only prints a line.

  Off:   $env:PLAYLIST_QUEST_SESSION = '0'   (or questPlaylistSession=false in ios_3d_loop_segments\windows\loop-segments-windows.json)
  Repo:  $env:LOOPSEGMENTS_IOS_REPO = '<path to ios_3d_loop_segments>'  (default <scripts root>\iOS apps\ios_3d_loop_segments)
  Log:   %TEMP%\loopsegments-quest-lantab.log  ("Playlist session:" / "Playlist stop:" lines)
#>
[CmdletBinding()]
param(
    [int] $WorkflowPid = $PID,
    [string] $WorkflowName = ''
)

try {
    if ($env:PLAYLIST_QUEST_SESSION -eq '0') {
        Write-Host 'Quest session: off (PLAYLIST_QUEST_SESSION=0).'
        return
    }
    $starter = Join-Path $PSScriptRoot 'quest\Start-PlaylistLocalQuestSession.ps1'
    if (-not (Test-Path -LiteralPath $starter -PathType Leaf)) {
        Write-Host "Quest session: $starter missing - skipped."
        return
    }
    $repo = @($env:LOOPSEGMENTS_IOS_REPO, $(if ($env:ALL_SCRIPTS_ROOT) { Join-Path $env:ALL_SCRIPTS_ROOT 'iOS apps\ios_3d_loop_segments' }), 'P:\all_scripts\iOS apps\ios_3d_loop_segments') |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath (Join-Path $_ 'windows\quest\Watch-LoopSegmentsQuestLanTab.ps1') -PathType Leaf) } |
        Select-Object -First 1
    if (-not $repo) {
        Write-Host 'Quest session: ios_3d_loop_segments not found (set LOOPSEGMENTS_IOS_REPO) - skipped.'
        return
    }
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }
    if (-not (Test-Path -LiteralPath $pwsh)) {
        Write-Host 'Quest session: PowerShell 7 (pwsh.exe) not found - skipped.'
        return
    }
    $env:LOOPSEGMENTS_IOS_REPO = $repo
    # Invoke-LeafFfmpegControl.ps1 quit cleanup stops the Quest players first (this process only).
    $env:PLAYLIST_QUEST_SESSION_PID = [string]$WorkflowPid
    Remove-Item Env:PLAYLIST_QUEST_PLAYERS_STOPPED -ErrorAction SilentlyContinue
    $argLine = '-NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File "{0}" -WorkflowPid {1} -WorkflowName "{2}"' -f $starter, $WorkflowPid, ($WorkflowName -replace '"', '')
    Start-Process -FilePath $pwsh -ArgumentList $argLine -WindowStyle Hidden | Out-Null
    Write-Host 'Quest session: sensor off + Quest control page on the headset (background). Its End session button stops this window and cleans up the Quest.'
    # Nothing opens on the PC: print a sign-in link instead (Ctrl+click in Windows Terminal). Loopback
    # only; the server swaps the token for a cookie (same token file as the quest\ session scripts).
    try {
        $port = 18766
        $cfgPath = Join-Path $repo 'windows\loop-segments-windows.json'
        if (Test-Path -LiteralPath $cfgPath) {
            $c = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
            if ($c.PSObject.Properties['questControlPort'] -and [int]$c.questControlPort -gt 0) { $port = [int]$c.questControlPort }
        }
        $tokPath = Join-Path $env:TEMP 'loopsegments-quest-control-pctoken.txt'
        $tok = ''
        if (Test-Path -LiteralPath $tokPath) { $tok = (Get-Content -LiteralPath $tokPath -Raw).Trim() }
        if ($tok -notmatch '^[A-Za-z0-9]{32,}$') {
            $bytes = [byte[]]::new(24)
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
            $tok = -join ($bytes | ForEach-Object { $_.ToString('x2') })
            Set-Content -LiteralPath $tokPath -Value $tok -Encoding ascii -NoNewline
        }
        Write-Host "Quest control on this PC (optional): http://127.0.0.1:$port/pc?t=$tok"
    } catch {}
} catch {
    Write-Host "Quest session: not started ($($_.Exception.Message))."
}
