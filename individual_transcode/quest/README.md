# 3d_playlist_local on the Quest: session, control page tiles, End session

Everything the 3d_playlist_local workflows do with the Quest headset lives in this folder. The generic headset layer it uses (adb, finding the headset, proximity sensor, keep-awake, Wi-Fi off, Quest Browser, the shared **Quest control page** host, the end-of-session cleanup) is the [quest_tools](../../../quest_tools/README.md) repo: `$env:QUEST_TOOLS_REPO`, else `<scripts root>\quest_tools` (found by [`PlaylistLocalQuestCommon.ps1`](PlaylistLocalQuestCommon.ps1)). The Loop Segments repo is not needed; when its PC companion runs, both projects' tiles share one page and End session also quits the companion. Log: `%TEMP%\loopsegments-quest-lantab.log` (`Playlist session:`, `Playlist stop:`, `Playlist XR:` lines).

| File | What |
|------|------|
| [`Start-PlaylistLocalQuestSession.ps1`](Start-PlaylistLocalQuestSession.ps1) | Workflow start (below) |
| [`PlaylistControlTiles.ps1`](PlaylistControlTiles.ps1) | This repo's tiles on the control page: **Session Control** (Space, End session, playback badge, segment bitrate) |
| [`Invoke-PlaylistLocalQuestShutdown.ps1`](Invoke-PlaylistLocalQuestShutdown.ps1) | **End session: stop all** |
| [`Send-PlaylistLocalSpaceKey.ps1`](Send-PlaylistLocalSpaceKey.ps1) | Space / Enter into the workflow's PowerShell window |
| [`Start-PlaylistLocalQuestXr.ps1`](Start-PlaylistLocalQuestXr.ps1), [`Close-PlaylistLocalQuestXrTabs.ps1`](Close-PlaylistLocalQuestXrTabs.ps1) | The XR player page (`..\xr`) |
| [`PlaylistLocalQuestCommon.ps1`](PlaylistLocalQuestCommon.ps1) | Shared: loads quest_tools, settings, registered workflows |
| [`..\Get-QuestLanSegmentBitrate.ps1`](../Get-QuestLanSegmentBitrate.ps1) | PC → Quest result → minute-segment bitrate (80 %, 5-80) |
| [`..\Start-PlaylistQuestSession.ps1`](../Start-PlaylistQuestSession.ps1) | The hook the workflows call |

## Workflow start

When a workflow starts (`run_batch_vr_hybrid.ps1`, `run_batch_fisheye_v360.ps1`, `Run-TranscodeOrchestrator.ps1`; not with `-DryRun`), its hook `..\Start-PlaylistQuestSession.ps1` starts `Start-PlaylistLocalQuestSession.ps1` hidden (`-WorkflowPid` = the workflow window) and the workflow goes on at once. It:

| Step | What |
|------|------|
| Control page | `Register-QuestControlTiles -Owner playlist -OwnerPid <workflow> -Module PlaylistControlTiles.ps1` (quest_tools): this repo's tiles are on the page while the workflow runs. The host starts with the first registration (port `controlPort`, default **18766**) and stops once neither a workflow nor the companion is left |
| Sensor | quest_tools `Invoke-QuestHeadset.ps1 -KeepAwakeSession -ParentPid <workflow>`: finds the headset on adb and holds the proximity sensor off once it is awake, every ~20 s; the end-of-workflow Quest step turns it back on after the history delete |
| Page on the PC | Nothing opens on the PC. The workflow window prints `Quest control on this PC (optional): http://127.0.0.1:<port>/pc?t=<token>` (Ctrl+click in Windows Terminal); loopback only, the host swaps the token for a cookie. A tab opened this way closes itself ~1 s after End session starts |
| Page on the headset | `Invoke-QuestHeadset.ps1 -OpenControlPage -ParentPid <workflow>`: waits for an awake headset (every 5 s) until the workflow ends (`openWaitMinutes` `0`; a number = minutes; the headset's Wi-Fi is usually off at a workflow start), then opens the control page in its own Quest Browser tab, signed in with the token link (`/s?t=`). Writes `opened` / `failed` / `unreachable` / `cancelled` to `%TEMP%\loopsegments-playlist-controlpage-status.txt` for the XR step |
| XR page in front | `Start-PlaylistLocalQuestXr.ps1`: serves the XR player page from this PC and, once the control page open has finished, opens it in Quest Browser in front of it; `player: "none"` skips it |
| Extra origins | `historyOrigins` go into quest_tools' shared origin list, so every cleanup (also the companion's quit) closes their tabs and deletes their history |
| Workflow ends by itself | Its quit cleanup (`Invoke-DlnaWorkflowQuitCleanup` in `Invoke-LeafFfmpegControl.ps1`) first closes the XR page's tabs, before it renames the segments. Once every registered workflow has exited, the hidden `Start-PlaylistLocalQuestSession.ps1 -CleanupWhenGone` runs `Invoke-QuestHeadset.ps1 -Cleanup` (tabs, history, sensor on, Wi-Fi off unless `wifiOffOnExit` is false; headset not worn or off adb: quest_tools' after-quit helper does it later). Skipped while the companion runs: its own quit does it |

The workflow PID is registered in `%TEMP%\loopsegments-playlist-session.json`. Off: `session: false`, or `$env:PLAYLIST_QUEST_SESSION = '0'` in the workflow shell.

## Session Control tile

**Space: pause / resume export** presses **Space once** in the visible 3d_playlist_local PowerShell window, the same as pressing it there: while a clip runs, the batch pauses or resumes the leaf DLNA export ffmpeg (`[leaf-export] Paused ...` / `Resumed ...`). [`Send-PlaylistLocalSpaceKey.ps1`](Send-PlaylistLocalSpaceKey.ps1) finds `pwsh.exe` / `powershell.exe` running a script from a `3d_playlist_local` folder (hidden children mapped to their visible parent shell), attaches to that console and writes a Space key-down and key-up into its input buffer: no focus needed, nothing typed into other windows. Logged `PLAYLIST_SPACE` in `%TEMP%\quest-control-host.log`. From a shell: `pwsh -File Send-PlaylistLocalSpaceKey.ps1 -WhatIf` lists the windows.

The badge shows **▶ Playing**, **⏸ Paused** or **No export running**, read from the export ffmpeg processes (`3d_op_` in the command line; Space suspends them, so every thread waiting with reason *Suspended* = paused). It also shows a Space pressed on the PC keyboard. The page polls every 3 s while an export runs.

**Segment bitrate**: what the next minute segments are encoded at, from the page's built-in **LAN bandwidth: PC → Quest** test (quest_tools): **80 % of the measured Mbps, 5-80**. Capped at 80 because Intel `av1_qsv` CBR near 100M pads frames to the budget but codes them far worse (blocky, "hazy" segments: 33 dB vs 42 dB at ≤ 95M on 2560×720@24); quality is flat from ~20M on typical sources. The test runs by itself each time the page opens on the headset.

`..\Get-QuestLanSegmentBitrate.ps1` reads the measurement (`%TEMP%\quest-lan-throughput.json`, results under 12 h old; `QUEST_LAN_BITRATE_MAX_AGE_HOURS`) after `-SegmentVideoBitrateMbps` and `LOOP_SEGMENTS_SEGMENT_VIDEO_BITRATE_MBPS`, before the PC ↔ phone sidecars and the 30 Mbps default. `Run-TranscodeFfmpeg.ps1` reads it on every encode (each fisheye pass-2 chase round, each flat clip) and caps whatever it gets at 80M; a running flat clip checks it every 5 s and, when it moves by 15 % or more, restarts at the next segment boundary with the new bitrate (no gap). After each test the tile also writes the older `%TEMP%\loopsegments-quest-lan-throughput.json` with this rule's number, for media-folder copies of this repo not synced yet.

## End session: stop all

Runs on click, no confirmation (the line above it says what it will stop). It runs `Invoke-PlaylistLocalQuestShutdown.ps1` (the registered workflow's copy, else the one next to the tiles), started through WMI so it is not a child of the page host. One at a time; the tile lists the steps as they finish (`%TEMP%\loopsegments-playlist-shutdown.json`).

0. stops the workflows' keep-awake, a pending page open and the natural-end cleanup helper (this run does that cleanup);
1. **XR page**: its Quest Browser tabs are closed first, so nothing streams the segments while the workflows' quit renames them;
2. **Workflows**: Enter in every registered 3d_playlist_local window plus any other one (`Send-PlaylistLocalSpaceKey.ps1 -Key Enter`, allowed 45 s; not delivered = tried again every 5 s, up to 3 times), then waits for each to exit through its own quit cleanup: Enter again after 60 s, killed with its child processes (never the Quest helpers) after `enterExitSec` (180 s; `0` = never);
3. **Loop Segments companion**, when it runs (its launcher shell or its Chromium): its Chromium is closed gracefully (force-closed after 30 s), which runs the companion's normal quit (its Quest step covers every page in the shared origin list, the control page and XR page included). Waits up to 180 s for `Cleanup: finished` in the log or the after-quit helper's pending file; neither: step 4 runs here;
4. **Quest cleanup** when the companion did not do it: `Invoke-QuestHeadset.ps1 -Cleanup` (tabs per `closeTabsOnExit`, history per `clearHistoryOnExit`, sensor on), then **Wi-Fi off** (unless `wifiOffOnExit` is false, or the delete was handed to the after-quit helper, which switches it off after its delete);
5. **Leftovers**: companion REST log sinks whose companion is gone.

The run and its helpers run at AboveNormal priority (a fisheye run starved them before). So the Quest history is deleted once: by the companion's quit, by step 4, or by the after-quit helper when the headset is next worn.

## Settings

`playlist-quest.json` next to these scripts (per PC, git-ignored; [`playlist-quest.example.json`](playlist-quest.example.json) lists the keys). A key missing there falls back to the older key in `ios_3d_loop_segments\windows\loop-segments-windows.json`, then to the default. adb, port and cleanup settings are quest_tools' (`quest-tools.json`).

| Key | Older key | Default | What |
|-----|-----------|---------|------|
| `session` | `questPlaylistSession` | `true` | Workflow start runs the Quest session at all |
| `controlPage` | `questControlPage` | `true` | Tiles on the control page, page opened on the headset |
| `openWaitMinutes` | `questPlaylistOpenWaitMinutes` | `0` | `0` = keep trying to open the page until the workflow ends; a number = minutes |
| `player` | `questPlaylistPlayer` | `xr` | `xr` (the XR page) or `none`; `$env:PLAYLIST_QUEST_PLAYER` wins |
| `xrPort` | `questPlaylistXrPort` | `18768` | XR page port |
| `xrHost` | `questPlaylistXrHost` | `auto` | `auto` (the PC's name when the headset resolves it, else its IPv4), `ip`, or a host name; `$env:PLAYLIST_XR_HOST` wins. Opened on a name, it falls back to the IPv4 mid-run when the headset stops resolving it (page idle, Quest Browser in front) |
| `historyOrigins` | `questPlaylistHistoryOrigins` | `[]` | Extra origins every cleanup closes and deletes (`{pc}` = this PC's address), e.g. `http://{pc}:8200` |
| `enterExitSec` | `questPlaylistEnterExitSec` | `180` | End session: seconds a workflow window gets after Enter before it is killed (`0` = never) |
