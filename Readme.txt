Run sequence:

# Script layout (flat / fisheye / hybrid)
#   Canonical scripts: P:\all_scripts\3d_playlist_local  (robocopy source at batch start)
#   Deploy:            P:\all_scripts\3d_playlist_local -> each {media}\3d_playlist_local
#                      (+ parent run_batch_*.ps1 launchers beside media_files.txt)
#   Other deps:        P:\all_scripts\py_venv1, P:\all_scripts\setup_venv.bat, P:\all_scripts\AutoHotkey
#   Context menu:      run individual_transcode\Install-ContextMenu.ps1 once per user from the deploy copy you want Explorer to use
# Logs/cleanup:  individual_transcode\LOGS.md (full catalog + purge commands);
#                  Cleanup-TranscodeLogs.ps1 (all deploy copies' *.log by default, including media_folder_watcher / hybrid)
#   AVS purge:     Purge-OldAvs.ps1 (beside this Readme / orchestrator)
#                  standalone/double-click = full purge of .\avs; workflows pass -KeepCount 50 (newest only)
#
# Manual refresh of a media-side deploy copy (same flags as batch robocopy):
#   robocopy P:\all_scripts\3d_playlist_local {media}\3d_playlist_local /E /XF *.log
#   /XF keeps local transcode_logs on media-side deploy copies; scripts still overwrite from P:\ hub.
#
# LAN / bandwidth: if DLNA or segment viewing stalls from network bandwidth issues, reboot routers
#   using scripts in P:\all_scripts\5g_router_reboot
#
# Source media accessibility (flat / fisheye / hybrid):
#   Before each clip: Test-Path on the queue item; if missing/inaccessible (e.g. network drive
#     mapping lost), warn [Missing], skip that clip, continue the live queue (not a hard abort).
#   Mid-encode / prepare: child non-zero (ffmpeg/prepare IO fail) -> warn / record failure, continue
#     next clip (no retry). Fisheye/hybrid batch exit 1 if any clip failed; flat logs failures and
#     may still exit 0 when the queue empties.
#   Hung read on a dead share: no short "drive lost" timeout. -BatchTimeoutSec (default 5400s)
#     wall-clock deadline kills the child/ffmpeg (exit 124) and stops the batch. Enter cancel = 130.
#   No automatic remount of source UNC/mapped drives. Ensure-DlnaSegmentRoot only remaps missing
#     F: DLNA *output*, not input media.
#
# DLNA segment root (flat / fisheye / hybrid): F:\f1_media\3d_fullsbs_trans
#   Skybox web-client share should keep pointing at that path.
#   If F: is missing, Ensure-DlnaSegmentRoot (Invoke-LeafFfmpegControl.ps1) stores under
#   %AppData%\3d_playlist_local and recreates F:\f1_media\3d_fullsbs_trans via subst + junction
#   so the Skybox share path is unchanged. When F: is present, segments write on the drive as usual.
#   Run start (all 3): Ensure-DlnaSegmentRoot -Force recreates empty flat/fisheye/hybrid/fisheye_temp
#     trees and restores any <sha256>.tmp media (via .dlna_obf_map.json) from a prior quit.
#   Run quit (all 3 finally): Invoke-DlnaWorkflowQuitCleanup obfuscates media to
#     <sha256(relativePath)>.tmp (scrambled .dlna_obf_map.json; also hides fisheye_temp\avs),
#     then Remove-DlnaSegmentRootSubst (our AppData subst F: + junction). Idempotent.
#     Hybrid/fisheye robocopy re-invoke wrapper also runs quit cleanup so stale media-side
#     deploy copies cannot leave F: subst / clear segment names behind.
#     Hard-kill of the console window still skips finally (no cleanup until next manual
#     Cleanup-DlnaSegmentRoot / quit cleanup).
#       flat:   Run-TranscodeOrchestrator.ps1
#       fisheye: run_batch_fisheye_v360.ps1
#       hybrid: run_batch_vr_hybrid.ps1
#   On error (all 3): same obfuscate, but -KeepLogs retains *.log / logs\ (including fisheye_temp\logs).
#     Triggers: clip/child failures, fatal batch stop (exit 1).
#     Batch timeout (124) and user cancel (130) purge DLNA-root logs like clean success.
#     Subst cleanup still runs on those exits.
#   Manual delete (former quit clear): Cleanup-DlnaSegmentRoot.ps1 (beside this Readme)
#     (script; calls function Clear-DlnaSegmentRootContents in individual_transcode\) - covers
#     flat+fisheye+hybrid+fisheye_temp\avs under the shared root. Playlist-local transcode_logs\
#     are never under this root.
#
#
# Console controls (Space / Enter) — see matrix below; implementation in:
#   individual_transcode\Invoke-LeafFfmpegControl.ps1   (leaf ffmpeg detect, NtSuspend; 3d_op_%02d.mkv pattern)
#   individual_transcode\Invoke-BatchPotPlayerGate.ps1  (Invoke-BatchConsoleControlPoll: native Enter + ReadKey)
#
# Keys apply only in the listed CONTROL window (click that PowerShell title bar first). Hidden child shells
# (Run-TranscodeFfmpeg, batch prepare -ChaseSync) do not receive your keystrokes — use the parent window.
#
# | Workflow step | Script / launcher | Control window | Space | Enter | Poll implementation |
# |---------------|-------------------|----------------|-------|-------|---------------------|
# | Flat step 1 (StreamTo3D GUI) | run_batch_convert_streamTo3D.ps1 | that console | — | — | no key poll (Ctrl+C only) |
# | Flat transcode queue | Run-TranscodeOrchestrator.ps1 | orchestrator window | pause leaf DLNA export | cancel current child clip | inline ReadKey (Space + Enter same handler) |
# | Flat context menu .avs | Run-TranscodeFfmpeg.ps1 | visible transcode console | pause leaf export | — | Invoke-TranscodeConsoleKeyPoll (Space only) + deadline |
# | Fisheye batch queue | run_batch_fisheye_v360.ps1 | batch window | pause leaf export | cancel clip or inter-clip wait | Invoke-BatchConsoleControlPoll |
# | Fisheye batch prepare (per clip) | Run-V360PrepareFisheye.ps1 -ChaseSync (hidden) | batch window (not prepare) | same as batch row | same as batch row | batch parent polls; hidden shell Space-only |
# | Fisheye context menu | Run-V360PrepareFisheye.ps1 (visible) | prepare window | pause during pass-2 rounds | error/cancel paths only | Invoke-TranscodeConsoleKeyPoll in prepare waits |
# | Hybrid batch queue | run_batch_vr_hybrid.ps1 | batch window | pause leaf export | cancel clip or inter-clip wait | Invoke-BatchConsoleControlPoll (same as fisheye) |
# | Fisheye / flat pass-2 inline | Run-TranscodeFfmpeg.ps1 (inside prepare or child) | parent control window | pause while export ffmpeg running | cancel when parent wires -AllowEnterCancel | Invoke-TranscodeConsoleKeyPoll + -WorkflowDeadlineUtc |
#
# Space (all workflows that poll): pause/resume pass-2 DLNA export ffmpeg only — cmd line contains 3d_op_
#   (legacy 3d_op_%02d.mkv / 3d_op_00.mkv / 3d_op_01.mkv, or Skybox-suffixed 3d_op_%02d_LR_180_FISHEYE.mkv / 3d_op_%02d_Full_SBS.mkv).
#   Pass-1 mezzanine (*.fisheye.frag.mp4) is never paused.
#   Flat orchestrator: one long export ffmpeg per .avs (pause mid segment-mux).
#   Fisheye pass-2: ~60s chase rounds (-readrate 1); pause only while a round's export process is alive.
#   Between chase rounds or while only watching segments already on disk: Space may report no export running.
# Enter: stop prepare shell + ffmpeg tree (fisheye batch) or orchestrator child (flat queue); exit 130 / batch cancel.
# Deadline: -BatchTimeoutSec / -WorkflowTimeoutSec / -WorkflowDeadlineUtc still tick while export is paused (exit 124).
# Messages: [leaf-export] Paused/Resumed N DLNA export ffmpeg process(es)...
#
# Why different poll code paths: flat orchestrator never shared the fisheye batch wait loop. Orchestrator uses one
# ReadKey for Space+Enter; fisheye batch uses Invoke-BatchConsoleControlPoll (Win32 Enter queue + ReadKey fallback).
# run_batch_convert_streamTo3D.ps1 has no transcode wait loop — keys are documented under orchestrator / fisheye batch.

# =============================================================================
# FLAT workflow (StreamTo3D SBS -> playlist .avs -> DLNA segments)
# =============================================================================
# Setup: setup_script_files.py or copy run_batch_convert_streamTo3D.ps1 beside media_files.txt
#   run_batch_convert_streamTo3D.ps1 robocopies hub -> .\3d_playlist_local (/E; /XF *.log keeps local logs).
#   Paths use $PSScriptRoot (safe for double-click / System32 cwd).
#   Space / Enter: no key poll in this step (see top console matrix).

# 1. Batch listings + StreamTo3D GUI convert
# StreamTo3D > Settings > Conversion > Ffmpeg Options: -h
# StreamTo3D > Settings > Format > 3D File Name Pattern: (?i).*((_3D)|(\.SBS\.)|(\.TB\.)|(\.HSBS\.)|(\.HTB\.)|(\.3DA\.)).*
# Batch/hybrid detect broader already-3D tokens via Test-Skip3dFormattedMediaName (SBS/FISHEYE/VR180/Full_SBS/…)
# and remux them with Run-SegmentCopyAsIs (-c copy -re) into ...\hybrid\ as 3d_op_%02d_LR_180.mkv (not skipped from the queue).
# StreamTo3D > Convert > 'Select 2D Video...' dialog > Filter: List (.txt) > .\media_files.txt
# StreamTo3D > Convert > 'Select Dest. Dir...' dialog > .\op_logs

.\run_batch_convert_streamTo3D.ps1 (ignore .\3d_playlist_local\*.ps1!)
(stable internet connection required!)

# 2. Move StreamTo3D AVS exports + refresh playlists (after step 1 GUI convert)
#   moves new avs from C:\ProgramData\StreamTo3D\... to .\3d_playlist_local\avs
#   sorts avs list (rand_combo priority up to 30, mtime asc within groups) + regenerates playlist.m3u and playlist_potplayer.dpl
#   .\3d_playlist_local\gen_dpl.py  (also run from batch step 1 at end)

# 3. Transcode queue (flat SBS .avs -> DLNA segments)
#   Double-click .\3d_playlist_local\Run-TranscodeOrchestrator.ps1 beside playlist.m3u
#   Walks playlist.m3u; continues after current clip through the live tail (new items appended are picked up;
#   reloads playlist + .\avs before each clip; no wrap while the tail has work). When the tail is empty,
#   resets the cursor to the oldest live item (skips paths already completed this run); if still empty,
#   waits one idle poll (-LiveQueueIdlePollSec) then finishes (or Enter / BatchTimeoutSec).
#   Each .avs -> Run-TranscodeFfmpeg.ps1 child -> 3d_op_%02d_Full_SBS.mkv
#   DLNA segments: -segment_time 60 -segment_wrap 2 (~60s per file, two-slot rotation; one encode per clip)
#   -BatchTimeoutSec 5400 default (entire queue wall-clock; same semantics as fisheye batch)
#   Child wait heartbeat: source_duration/5s per clip (Get-FisheyePrepareHeartbeat.ps1; -PrepareHeartbeatDivisor)
#   Keys: orchestrator window — Space=pause leaf export; Enter=cancel clip (see top matrix). Deadline applies while paused.
#   PotPlayer DPL playname/playtime for queue anchor + per-clip seek (30s backoff on playtime)
#   Per-clip -ss also uses PotPlayer RememberFiles registry (Get-PotPlayerRegistrySeek.ps1)
#   Context menu (Install-ContextMenu.ps1):
#     .mp4/.mkv/.mov/.m4v/.avi/.wmv/.ts/.m2ts/.webm -> flat or fisheye prepare (RememberFiles + 5s key override; standardized if present)
#     .avs -> flat SBS transcode; successful .avs may hand off to orchestrator
#   Output: F:\f1_media\3d_fullsbs_trans\flat\3d_op_%02d_Full_SBS.mkv
#   AVS purge: Purge-OldAvs.ps1 — workflows keep newest 50 under .\avs at start of
#     run_batch_convert_streamTo3D.ps1, Run-TranscodeOrchestrator.ps1, and run_batch_vr_hybrid.ps1;
#     running Purge-OldAvs.ps1 alone does a full .\avs purge

# =============================================================================
# HYBRID workflow (per-clip flat vs fisheye from bitrate + codec)
# =============================================================================
# Recommended: .\run_batch_vr_hybrid.ps1 beside media_files.txt (setup_script_files.py deploys it with the other batch launchers)
#   Same PotPlayer gate, live media_files.txt queue, -BatchTimeoutSec 5400, Space/Enter, resume sidecar as fisheye batch.
#   Startup: Purge-OldAvs.ps1 -KeepCount 50 under .\avs (standalone purge = full wipe).
#   Minute-segment encode bitrate (flat + fisheye pass-2): -SegmentVideoBitrateMbps, else
#     LOOP_SEGMENTS_SEGMENT_VIDEO_BITRATE_MBPS, else lan_recommended_segment_bitrate.json /
#     scripts\lan_throughput.json from Measure-LoopSegmentsLanThroughput.ps1 (after rclone L: mount;
#     default recommend = 80% of measured LAN Mbps). -SkipLanBitrateCap ignores sidecars (falls back to ~30M).
#   Per clip probes format/stream bitrate + v:0 codec_name (Resolve-HybridWorkflowRoute.ps1):
#     flat when: (<4 Mbps AND not hevc/av1) OR (<2 Mbps AND hevc/av1); otherwise fisheye
#   Per clip: if already-3D (Test-Skip3dFormattedMediaName) -> Run-SegmentCopyAsIs (-c copy -re) into
#     ...\hybrid\ with Skybox suffix LR_180 (Get-AsIsDlnaSegmentSuffix); else Resolve-HybridWorkflowRoute:
#     fisheye -> Run-V360PrepareFisheye.ps1 -AutoChaseTranscode -ChaseSync -SegmentNameSuffix LR_180_FISHEYE
#               -SegmentOutputDirectory F:\f1_media\3d_fullsbs_trans\hybrid
#     flat    -> Export StreamTo3D.fisheye_temp.template.avs with source path (no StreamTo3D GUI);
#               mono/narrow -> StackHorizontal Full SBS; already-wide SBS -> passthrough;
#               then Run-TranscodeFfmpeg -SegmentNameSuffix Full_SBS -OutputDirectory ...\hybrid
#   Minute segments multiplexed to one folder (Skybox tokens): ...\hybrid\3d_op_%02d_Full_SBS.mkv /
#     ...\hybrid\3d_op_%02d_LR_180_FISHEYE.mkv / ...\hybrid\3d_op_%02d_LR_180.mkv (as-is). Suffix switches keep the prior pair until the new encode
#     writes (>=1 MiB); Sync-DlnaHybridSegmentHandoff then retires inactive leaves one-by-one toward two
#     playable files; clip end -Finalize clears other-suffix leaves only when active has >=1 ready file
#     (otherwise holds the prior pair so hybrid is never emptied).
#   Ref: https://skybox.xyz/support/How-to-Adjust-2D&3D&VR-Video-Formats
#   Flat AVS written as 3d_playlist_local\avs\StreamTo3D.flat_temp.{source}.avs

# =============================================================================
# FISHEYE workflow (v360 mezzanine — bypasses StreamTo3D GUI; no op_logs / ProgramData AVS)
# =============================================================================
# Recommended after setup: .\run_batch_fisheye_v360.ps1 beside media_files.txt
#   Same sync/listings preamble as flat step 1; selective_stdize.ps1 via Start-Process pwsh (visible, non-blocking; survives batch timeout/kill).
#   Opens PotPlayer fisheye_batch_potplayer.dpl for start clip.
#   fisheye_batch.m3u / fisheye_batch_potplayer.dpl rebuilt each batch run from media_files.txt; when the
#   eligible path list is unchanged (same paths, same order), prior playname/playtime/topindex are preserved
#   if playname still resolves to a list entry (basename match). Empty/broken playname or playname not in list
#   resets playname/playtime even when the m3u is unchanged. List add/remove/reorder always resets playname/playtime.
#   Does not touch flat playlist_potplayer.dpl.
#   During the run, the batch continues after the current clip through the live media_files.txt tail
#   (new items appended are picked up; no wrap while the tail has work). When the tail is empty, resets the
#   cursor to the oldest live item (skips completed-this-run paths). If still empty, waits one watcher poll
#   then finishes (or until BatchTimeoutSec / Enter).
#   AutoHotkey companions from P:\all_scripts\AutoHotkey (or -SkipPotPlayer / -SkipCompanionBinaries).
#   -BatchTimeoutSec 5400 entire queue; prepare children get -WorkflowDeadlineUtc (not per-clip timeout).
#   DPL playtime (first batch clip only, 30s backoff): pass-1 mezzanine -SsSec; pass-2 from mezzanine t=0.
#   -SkipPotPlayerSeek: pass-1 and pass-2 start at 0s for every clip.
#   Per clip: if already-3D (Test-Skip3dFormattedMediaName) -> Run-SegmentCopyAsIs (-c copy -re) into
#     ...\hybrid\ with Skybox suffix LR_180 (Get-AsIsDlnaSegmentSuffix; skips prepare/chase); else
#     Run-V360PrepareFisheye.ps1 -AutoChaseTranscode -ChaseSync (inline pass-2 in hidden prepare shell).
#   -InterClipWaitSec 0 disables inter-clip DLNA buffer (default 0 in script; set 60 if you want minute gap).
#   Pass 1: Run-FisheyeV360.ps1 -> fisheye_temp\{base}.fisheye.frag.mp4 (av1_qsv 50M fragmented)
#   Pass 2: Run-TranscodeFfmpeg.ps1 chase -> F:\f1_media\3d_fullsbs_trans\fisheye\3d_op_%02d_LR_180_FISHEYE.mkv (av1_qsv 75M, readrate 1)
#     60-second DLNA segments: -segment_time 60 -segment_wrap 2 -reset_timestamps 1
#     Chase (fisheye_temp\avs): each round -t 60 max; alternates -segment_start_number 0 then 1
#       (short mezzanine-edge rounds still overwrite both slots; sibling file stays playable)
#     Tail refresh at chase end may re-mux up to ~120s from clip tail when last round <60s
#     Context-menu / -ChaseWorker: same chase logic; see individual_transcode\LOGS.md
#   AVS: fisheye_temp\avs\StreamTo3D.fisheye_temp.{source}.avs (passthrough template; no StreamTo3D MDepan)
#   Context menu (common video types) -> Prepare v360 fisheye + chase DLNA segments:
#     standardized\{filename} under 3d_playlist_local used when present (generate_media_listings_lcl.py / selective_stdize.ps1)
#     -WorkflowTimeoutSec 5400 default (same wall-clock as -BatchTimeoutSec, one clip from prepare start; no duration scaling)
#     pass-1 RememberFiles resume (+ 5s key override); pass-2 hidden background worker (shared deadline; TranscodeTimeoutSec -1)
#     prepare window wait heartbeat: source_duration/5s (Get-FisheyePrepareHeartbeat.ps1; same as batch) + chase transcript tail
#   Keys: batch control window — Space=pause leaf export; Enter=cancel clip/batch (see top matrix). Hidden prepare does not receive keys.
#     prepare window waits for hidden pass-2 worker then auto-closes in 8s on success (Enter only on error)
#     on success with 2+ clips in media_files.txt: 3d_playlist_local\run_batch_fisheye_v360.ps1 -ResumeAfter (SkipPotPlayer, SkipPotPlayerSeek; no PotPlayer gate); last clip wraps to first; see fisheye_context_handoff.log
#     pass-2 worker is detached while prepare waits (closing prepare early does not stop pass-2)

# VR: For appropriate clicks, point controller cursor downwards/outside the screen to deactivate it and only keep host mouse active!
# VR: Click coordinates hold true even when host screen is disabled (VR screen-only mode)!
# if no 'Converting: ...' process loop, restart app and retry!
# Batch processing time depends on input media count
# Do Not change window or use key/mouse inputs during Gui initialization!
#   Flat StreamTo3D error logs: .\op_logs (ignore them)
# Playlists / PotPlayer:
#   - 3d_playlist_local\playlist.m3u (flat orchestrator input; F6 + F3 to refresh as needed)
#   - 3d_playlist_local\playlist_potplayer.dpl
# StreamTo3D automation + avs transfer cannot run in parallel, else .avs mixes between multiple destination folders!
# Filenames containing `3d` are ignored by StreamTo3D regex: (?i).*((3D)|(\.SBS\.)|(\.TB\.)|(\.HSBS\.)|(\.HTB\.)|(\.3DA\.)).*
# May not format vertical videos correctly!
# Standardization using ffmpeg appears thread-safe but can overload system!
# Vertical videos will be gradually standardized and prioritized during 2nd flat batch attempt (after 1st successful attempt)!
# 'media_files.txt' will auto-refresh on batch runs!
# Folder watcher (both workflows): Watch-MediaFolderPlaylists.ps1
#   Polls media root in background; on new/changed media or flat .avs refreshes media_files.txt,
#   fisheye_batch.m3u/_potplayer.dpl, and playlist.m3u/playlist_potplayer.dpl (via gen_dpl.py).
#   Auto-started by run_batch_fisheye_v360.ps1, run_batch_vr_hybrid.ps1, and run_batch_convert_streamTo3D.ps1 (one instance per media root).
#   Fisheye/hybrid batch and flat orchestrator both continue after the current clip through the live playlist tail;
#   on empty tail they reset the cursor to the oldest live item, then one idle poll if still empty.
#   Manual: .\3d_playlist_local\Watch-MediaFolderPlaylists.ps1 [-Once] [-PollSeconds 60] [-Foreground]
#   Opt out: -SkipMediaFolderWatcher on either batch script. Logs: individual_transcode\transcode_logs\media_folder_watcher\

# optional/as-needed
# P:\all_scripts\global_rand_3d_playlist\purge_old_data.py
