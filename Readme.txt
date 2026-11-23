Run sequence:

# Script layout (flat / fisheye / hybrid)
#   Scripts root:      the folder holding 3d_playlist_local\, py_venv1\, setup_venv.bat, AutoHotkey\,
#                      Skybox_vr_pc\ ("iOS apps"\ optional). Default P:\all_scripts, but ANY drive/path works
#                      (see "Moving the scripts root to another drive" below). Written as <root> here.
#   Canonical scripts: <root>\3d_playlist_local  (robocopy source at batch start)
#                      F:\all_scripts hub is retired — do not sync or run from F:\all_scripts
#   Deploy:            <root>\3d_playlist_local -> each {media}\3d_playlist_local
#                      (+ parent run_batch_*.ps1 launchers beside media_files.txt)
#   Web companion hub: P:\p_cld_media\web_compann_plst\ (no local source media; skipped if P: is absent)
#                      ios_3d_loop_segments pCloud companion Ctrl+Shift+H overwrites media_files.txt
#                      with selected video Drive paths (absolute P:\…); run any run_batch_*.ps1 beside the list.
#                      Deploy hub: setup_script_files.py (copies 3 launchers + 3d_playlist_local\).
#   Other deps:        <root>\py_venv1, <root>\setup_venv.bat, <root>\AutoHotkey
#
# Moving the scripts root to another drive (e.g. P:\all_scripts -> I:\all_scripts):
#   1. Copy the whole scripts folder to the new location first (any drive / any path).
#   2. From the NEW copy run:  <newroot>\py_venv1\Scripts\python.exe <newroot>\3d_playlist_local\setup_script_files.py
#        [MEDIA_ROOT ...] [--hub PATH | --no-hub]
#      It records the new root in %LOCALAPPDATA%\3d_playlist_local\all_scripts_root.txt and redeploys
#      the 3 launchers to every media folder under MEDIA_ROOT (default: F:\f1_media, E:\e1_media,
#      D:\d1_media, P:\p_cld_media, L:\pcld_ios_media; missing roots are skipped).
#   3. Run any run_batch_*.ps1 beside media_files.txt as before. The console prints "Scripts root: ...".
#   How launchers find <root> (individual_transcode\Resolve-AllScriptsRoot.ps1; the run_batch_*.ps1
#   launchers carry an inline copy because they run before 3d_playlist_local is synced):
#     ALL_SCRIPTS_ROOT env var (process, then User) -> walk up from the running script ->
#     <same drive as the launcher>:ll_scripts (I: media uses I:ll_scripts with no setup step) ->
#     %LOCALAPPDATA%\3d_playlist_local\all_scripts_root.txt -> <any ready drive>:\all_scripts -> P:\all_scripts.
#     A folder counts only if it has 3d_playlist_local\individual_transcode\ AND setup_venv.bat or py_venv1\.
#     Running a launcher from the master copy (or the drive scan) re-registers the pointer, so the copy
#     you set up or ran last wins for media on drives WITHOUT their own <drive>:ll_scripts. Pin one with: setx ALL_SCRIPTS_ROOT I:\all_scripts
#   The launchers export ALL_SCRIPTS_ROOT to child scripts (companion AutoHotkey, hybrid_workflow.json,
#   Skybox_vr_pc, "iOS apps"\ios_3d_loop_segments for the Quest session).
#   setup_venv.bat uses its own folder (%~dp0) and rebuilds py_venv1 only when its python is missing or
#   broken (a copied venv still runs: pyvenv.cfg home= is the base Python on C:). It calls the venv python
#   directly (a copied activate.bat still points at the old drive). Requires `py -3.12` on the PC.
#   Still drive-specific by design: media roots, the web companion hub, Skybox_vr_pc\skybox_vr_pc.config.json
#   SharePath (P:\p_cld_media) and the dummy M: DLNA output letter.
#   Virtual / cloud drives (e.g. Icedrive): Defender may quarantine the compiled AutoHotkey *.exe
#   (Trojan:Win32/Bearfoos.B!ml, false positive) while it syncs, so robocopy reports exit 8 for that file.
#   Restore / allow it in Windows Security, or run with -SkipCompanionBinaries.
#                      Skybox PC client helpers: git submodule Skybox_vr_pc (github.com/dsouzaankit/skybox-vr-pc)
#                      After clone: git submodule update --init. Override root with SKYBOX_VR_PC_ROOT.
#   Context menu:      run individual_transcode\Install-ContextMenu.ps1 once per user from the deploy copy you want Explorer to use
# Logs/cleanup:  individual_transcode\LOGS.md (full catalog + purge commands);
#                  Cleanup-TranscodeLogs.ps1 (all deploy copies' *.log by default, including media_folder_watcher / hybrid;
#                    also deletes 3d_playlist_local\standardized\ copies; -NoStandardized skips)
#   AVS purge:     Purge-OldAvs.ps1 (beside this Readme / orchestrator)
#                  standalone/double-click = full purge of .\avs; workflows pass -KeepCount 50 (newest only)
#
# Manual refresh of a media-side deploy copy (same flags as batch robocopy):
#   robocopy <root>\3d_playlist_local {media}\3d_playlist_local /E /XF *.log /XD ai ign .git standardized avs op_logs transcode_logs
#   /XF keeps local *.log; /XD skips chat dumps, ign\, .git, media/runtime trees so P:/L: cloud sync stays light.
#
# LAN / bandwidth: if DLNA or segment viewing stalls from network bandwidth issues, reboot routers
#   using scripts in <root>\5g_router_reboot
#
# Source media accessibility (flat / fisheye / hybrid):
#   Before each clip: Test-Path on the queue item; if missing/inaccessible (e.g. network drive
#     mapping lost), warn [Missing], skip that clip, continue the live queue (not a hard abort).
#   Mid-encode / prepare: child non-zero (ffmpeg/prepare IO fail) -> warn / record failure, continue
#     next clip (no retry). Fisheye/hybrid batch exit 1 if any clip failed; flat logs failures and
#     may still exit 0 when the queue empties.
#   Hung read on a dead share: no short "drive lost" timeout. -BatchTimeoutSec (default 5400s)
#     wall-clock deadline kills the child/ffmpeg (exit 124) and stops the batch. Enter cancel = 130.
#   No automatic remount of source UNC/mapped drives. Ensure-DlnaSegmentRoot only keeps dummy
#     subst M: for DLNA *output*, not input media.
#
# DLNA segment root (flat / fisheye / hybrid): M:\m1_media\3d_fullsbs_trans
#   Skybox PC client share should keep pointing at that path.
#   Ensure-DlnaSegmentRoot always stores under %AppData%\3d_playlist_local. During the run,
#   Explorer dummy M: is subst'd to %AppData%\m1_media_dlna_subst + junction so the Skybox path
#   stays M:\m1_media\3d_fullsbs_trans. Never writes onto a real M: volume. If a real M: (or a
#   subst to some other folder) is already mapped, a free D–Z letter is chosen for that run
#   ({letter}:\m1_media\3d_fullsbs_trans). Ensure-DlnaSegmentRoot starts the Skybox PC client if
#   idle, then updates Add folders (remove stale 3d_fullsbs_trans / old k1_media / f1_media entries,
#   add the live dummy path). If Skybox cannot be started, the console warns you to add that path.
#   Set 3D_PLAYLIST_SKIP_SKYBOX=1 to skip launching Skybox (mappings still sync if it is already up).
#   All three workflows (flat orchestrator, fisheye batch, hybrid batch) call
#   Ensure-DlnaSegmentRoot and write under the mapped letter.
#   av1_qsv GPU encode stays on for all minute-segment exports (flat DLNA, fisheye pass-1+2,
#     hybrid routes). Encoder is still -c:v av1_qsv CBR; only fps resample was removed.
#     Integer CFR 24/25/30/50/60. NTSC 29.97/23.976/59.94 tagged 30/24/60 via AVS AssumeFPS
#     (no DirectShow fps=/convertfps, no ffmpeg -vf fps= — those blend via AviSynth/QSV VPP
#     and look soft). QSV rejects NTSC rates.
#   DLNA minute slots are .mkv (3d_op_%02d[_Suffix].mkv), not .mp4: Matroska remuxes mixed
#     sources with -c copy (as-is / >2K), tolerates wrap-2 overwrite while Skybox reads the
#     sibling slot, and carries av1_qsv without MP4 brand/moov pain. Pass-1 mezzanine stays
#     fragmented .fisheye.frag.mp4 so the file can grow while chase reads it. Prefer MP4 for
#     phone/progressive export (ios_3d_loop_segments), not Skybox PC DLNA slots.
#   Run start (all 3): Ensure-DlnaSegmentRoot -Force recreates empty flat/fisheye/hybrid/fisheye_temp
#     trees and restores any <sha256>.tmp media and .avs (via .dlna_obf_map.json) from a prior quit.
#     Also starts the Skybox PC client if it is idle (locate exe / Steam, hide to tray, wait for
#     :8018 via the Skybox_vr_pc submodule — same idea as the Loop Segments companion), maps the AirScreen share
#     from skybox_vr_pc.config.json, and adds 3d_fullsbs_trans Add folders.
#   Run quit (all 3 finally: success / abort / timeout): Invoke-DlnaWorkflowQuitCleanup removes
#     Skybox Add-folders 3d_fullsbs_trans and the Skybox_vr_pc AirScreen share (p_cld_media).
#     Does not touch Loop Segments pcld_ios_media / L: rclone nodes. Then quits Skybox only if this run
#     started it (already-running Skybox is left alone; the started-by-workflow marker is kept when Skybox
#     is already up so hidden pass-2 / leaf children do not wipe it). Obfuscates media and .avs to <sha256(relativePath)>.tmp (scrambled .dlna_obf_map.json;
#     includes fisheye_temp\avs\*.avs), then Remove-DlnaSegmentRootSubst (clears dummy subst M:
#     + junction; Explorer icon goes away). Idempotent. Next start recreates dummy M:.
#     Hybrid/fisheye robocopy re-invoke wrapper also runs quit cleanup so stale media-side
#     deploy copies cannot leave M: subst / clear segment names behind.
#     Explorer context-menu quit obfuscates the AppData store before the close pause. It skips that
#     obfuscate only when a follow-up batch process actually started (that process quits later).
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
#   Delete old/existing segment exports only (all workflows): Cleanup-DlnaSegmentExports.ps1 (beside this Readme)
#     (calls Remove-DlnaWorkflowSegmentExports in individual_transcode\Invoke-LeafFfmpegControl.ps1)
#     Deletes 3d_op_*.mkv in flat\ fisheye\ hybrid\ (Full_SBS / LR_180_FISHEYE / LR_180 as-is, context menu
#     too) plus their quit-obfuscated <sha256>.tmp / _dlna_obf_* copies, and drops those .dlna_obf_map.json
#     entries. Keeps fisheye_temp\avs, logs and the folder tree. Reads the %AppData%\3d_playlist_local store
#     directly (no subst M:, no restore, no Skybox start). Stops leaf export ffmpeg first.
#       .\Cleanup-DlnaSegmentExports.ps1 -DryRun              # list files + sizes, delete nothing
#       .\Cleanup-DlnaSegmentExports.ps1                      # delete
#       -IncludeFisheyeTemp   also pass-1 mezzanines (fisheye_temp\*.fisheye.frag.mp4)
#       -IncludeLegacyRoots   also <drive>:\{m1_media,f1_media,k1_media}\3d_fullsbs_trans
#       -Root <path[]>  -NoStopLeafExport  -NoPause
#   Which one: Cleanup-DlnaSegmentExports.ps1 for routine "clear old segments / free space before a run"
#     (keeps .avs + logs for debugging, no side effects). Cleanup-DlnaSegmentRoot.ps1 for a clean slate
#     (e.g. after a crash): wipes everything under the root - segments, hidden .tmp copies, fisheye_temp
#     mezzanines + avs, logs (unless -KeepLogs), .dlna_obf_map.json - and maps M: / restores hidden media
#     first. Its -DryRun gives counts only; the exports script lists each file with its size.
#     Both stop leaf export ffmpeg first (-NoStopLeafExport skips) and recreate the empty folder tree.
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
# | Flat context menu .avs | Run-TranscodeFfmpeg.ps1 | visible transcode console | pause leaf export | cancel clip (AllowEnterCancel / -ContextMenu) | Invoke-TranscodeConsoleKeyPoll + deadline |
# | Fisheye batch queue | run_batch_fisheye_v360.ps1 | batch window | pause leaf export | cancel clip or inter-clip wait | Invoke-BatchConsoleControlPoll |
# | Fisheye batch prepare (per clip) | Run-V360PrepareFisheye.ps1 -ChaseSync (hidden) | batch window (not prepare) | same as batch row | same as batch row | batch parent polls; hidden shell Space-only |
# | Fisheye context menu | Run-V360PrepareFisheye.ps1 (visible) | prepare window | pause during pass-2 rounds | cancel clip (AllowEnterCancel when not -ChaseWorker) | Invoke-TranscodeConsoleKeyPoll in prepare waits |
# | Hybrid batch queue | run_batch_vr_hybrid.ps1 | batch window | pause leaf export | cancel clip or inter-clip wait | Invoke-BatchConsoleControlPoll (same as fisheye) |
# | Fisheye / flat pass-2 inline | Run-TranscodeFfmpeg.ps1 (inside prepare or child) | parent control window | pause while export ffmpeg running | cancel when parent wires -AllowEnterCancel | Invoke-TranscodeConsoleKeyPoll + -WorkflowDeadlineUtc |
#
# Space (all workflows that poll): pause/resume pass-2 DLNA export ffmpeg only — cmd line contains 3d_op_
#   (legacy 3d_op_%02d.mkv / 3d_op_00.mkv / 3d_op_01.mkv, or Skybox-suffixed 3d_op_%02d_LR_180_FISHEYE.mkv / 3d_op_%02d_Full_SBS.mkv).
#   Pass-1 mezzanine (*.fisheye.frag.mp4) is never paused.
#   Flat orchestrator: one long export ffmpeg per .avs (pause mid segment-mux).
#   Fisheye pass-2: ~60s chase rounds (-readrate 1); pause only while a round's export process is alive.
#   Between chase rounds or while only watching segments already on disk: Space may report no export running.
# Enter: stop prepare shell + ffmpeg tree (fisheye batch), orchestrator child (flat queue), or Explorer
#   context-menu transcode/prepare (-ContextMenu / -AllowEnterCancel); exit 130 / batch cancel.
# Deadline: -BatchTimeoutSec / -WorkflowTimeoutSec / -WorkflowDeadlineUtc still tick while export is paused (exit 124).
# Messages: [leaf-export] Paused/Resumed N DLNA export ffmpeg process(es)...
#
# Quest headset (ios_3d_loop_segments, optional): hybrid / fisheye batch and the flat orchestrator call
#   individual_transcode\Start-PlaylistQuestSession.ps1 at start (not -DryRun): in the background it holds the
#   Quest proximity sensor off and opens the Quest control page in Quest Browser; this window prints a sign-in
#   link to the same page for the PC (optional, nothing opens there). Once the headset is awake and the page is open,
#   the Quest player opens in front - questPlaylistPlayer (ios_3d_loop_segments\windows\loop-segments-windows.json) or
#   $env:PLAYLIST_QUEST_PLAYER = xr (default) | skybox | none:
#   xr: the XR player page (below), served from this PC and opened in Quest Browser next to the control page.
#   skybox: SKYBOX VR Player is opened in front (quest\Start-PlaylistLocalQuestSkybox.ps1; app only - pick the segments
#   from the SKYBOX PC share; SKYBOX not installed on the headset = logged, not launched; off: $env:PLAYLIST_QUEST_SKYBOX='0'
#   or questPlaylistLaunchSkybox=false).
#   Caveat (skybox): SKYBOX resets Global Settings > Passthrough on every launch (also after a normal quit, so not caused by
#   the workflow's force-stop) - switch it on by hand each session. It cannot be preset: the setting is in SKYBOX's
#   internal storage (app not debuggable, so no adb run-as/backup), and its menus take controller input, not adb taps.
#   (Per-video passthrough IS persisted, in /sdcard/Android/data/xyz.skybox.player.ovr/files/SkyboxDataBase
#   MediaCustomSettings "IsPassthrough", but that is a ChromaKey video effect, not the home environment.)
#   Every quit (End session or natural end) first force-stops the Quest
#   players reading the segments (Invoke-DlnaWorkflowQuitCleanup, before the rename), and after the workflow is gone
#   the Quest tabs / history are cleaned, the sensor goes back on and the Quest Wi-Fi off. That page's Space button = Space
#   here; its End session button stops everything running: Quest players reading the output, Enter in every
#   3d_playlist_local window (an Enter that did not get through is retried every 5 s, up to 3 times; Enter again
#   after 60 s; killed after ~3 min), then the Loop Segments companion
#   (its own quit cleans up the Quest, L: and the phone) - or, without the companion, the Quest cleanup itself
#   (tabs, history, sensor on, Wi-Fi off). Quest history is deleted once either way. End session runs its helpers at
#   above-normal priority (a fisheye run slowed them down to timeouts). Phone not answering at cleanup: the helper page
#   that clears Quest Browser's Recently closed list is served from this PC (port questControlPort + 1, default 18767).
#   Headset not worn at quit: an after-quit history helper (-RetryHistory) finishes that cleanup when it is next worn.
#   A new workflow start stops any such helper first (log: "stopped the last quit's history helper"), so it cannot
#   close the new run's control page / Quest Browser or switch Wi-Fi off mid-run; the new run's quit cleans instead.
#   Off: $env:PLAYLIST_QUEST_SESSION='0'. Repo path: $env:LOOPSEGMENTS_IOS_REPO.
#   Details: ios_3d_loop_segments\windows\quest\README.md (3d_playlist_local workflow session).
#   Generic headset layer (adb, finding the headset, proximity sensor, Wi-Fi off, Quest Browser DevTools, SKYBOX
#   database): the quest_tools repo, P:\all_scripts\quest_tools ($env:QUEST_TOOLS_REPO, else <scripts root>\quest_tools,
#   else a quest_tools folder next to this repo), loaded by both this repo's quest\ scripts and Loop Segments'. One
#   checkout for both. Setup (adb, developer mode, wireless adb) and adb trouble: quest_tools\README.md.
#   By hand: pwsh -File P:\all_scripts\quest_tools\Invoke-QuestHeadset.ps1 (read-only status; -ResetAdb, -EnableProximity, ...).
#   adb hangs (adb devices / connect / even kill-server never return, PowerShell windows freeze with them; headset
#   still on USB or listed by mDNS): the adb server is stuck (seen: two adb.exe running). The session's keep-awake
#   helper (Loop Segments Watch-LoopSegmentsQuestLanTab.ps1, through quest_tools) resets it by itself once `adb devices` times out (10 s):
#   kills that adb.exe, starts a fresh server, reconnects; this repo's Quest scripts only read `adb devices` (10 s
#   timeout) and pick the headset up again after that. By hand: taskkill /F /IM adb.exe, then adb mdns services and
#   adb connect <ip:port> from its _adb-tls-connect line (the port changes on every reboot / wireless debugging
#   toggle), or Invoke-QuestHeadset.ps1 -ResetAdb. See quest_tools\README.md, "How the PC finds the headset" > adb server hung.
#
# Quest XR page (individual_transcode\xr: xr-player.html + xr-app.js, this project's playlists; ported from
#   ios_3d_loop_segments' /xr). The engine - xr-components.js and the vendored A-Frame 1.6.0 aframe.min.js - is shared:
#   quest_tools\xr is the one editable copy (see quest_tools\README.md "XR player engine"; Loop Segments bundles a copy
#   generated by quest_tools\xr\Sync-QuestXrEngine.ps1). serve_xr_page.py serves it from there (--engine-dir, else
#   found like quest_tools itself). Do not upgrade A-Frame casually.
#   Server: xr\serve_xr_page.py (stdlib Python; py_venv1) on port questPlaylistXrPort (default 18768), all interfaces,
#     read-only, no login. Serves /xr, the A-Frame assets and the DLNA segments straight from the store
#     %APPDATA%\3d_playlist_local\{hybrid,fisheye,flat}\3d_op_NN[_Suffix].mkv (HTTP Range; opened with full share flags
#     so the quit rename and the wrap-2 rewrite still work while the headset streams). Stops when the workflow (and every
#     other registered workflow) is gone. Log %TEMP%\playlist-xr-server.log; quest steps in %TEMP%\loopsegments-quest-lantab.log
#     ("Playlist XR:"). By hand: quest\Start-PlaylistLocalQuestXr.ps1 -WorkflowPid <pid> -ServeOnly, or
#     py -3 xr\serve_xr_page.py, then http://<pc>:18768/xr?mode=hybrid|fisheye|flat.
#     First run: Windows Firewall asks to allow python.exe - allow it on private networks or the headset cannot connect.
#   Page: playlists Hybrid / Fisheye / Flat = those folders, oldest segment first; Launch starts on the newest finished
#     segment, and at each end it plays the next one written after it (waits while that slot is still being muxed).
#     Projection Auto from the Skybox suffix: _LR_180_FISHEYE = fisheye 180 (equidistant circle per eye), _LR_180 = VR180
#     half sphere, _Full_SBS / none = flat screen; the Projection picker overrides it. Enter AR = passthrough.
#     Enter AR is 3D too (left dome on WebGL layer 1, right on layer 2, as in VR). The iOS page kept AR mono (its
#     build 345: layers 1/2 blanked Quest AR video while it still edited the XR cameras by hand); that is gone since
#     its eye-layer rewrite. "3D in AR" off on the page = the old mono AR (left half to both eyes).
#     Checked on Quest 3 (2026-11-22): <COMPUTERNAME>.local resolves on the headset, the page is a secure context,
#     AV1 + AAC .mkv plays at 1x (no dropped frames), Enter AR keys the green background with each eye on its own
#     half, next segment loads in AR, VR right after AR shows video (xr-enabled-fixed at ticks 1), Chroma off and
#     Fullscreen fine.
#     Chroma keys the fisheye background (below). xr_debug.json keeps the page's debug ring (see the iOS repo's
#     .cursor/skills/xr-debug).
#   Push to the headset: quest\Start-PlaylistLocalQuestXr.ps1 (session step 4) waits for the control page open and an
#     awake headset, then opens http://<host>:<port>/xr?mode=<workflow> with ios_3d_loop_segments'
#     Watch-LoopSegmentsQuestLanTab.ps1 -Url <it> -NoLanLogin: control page tab, XR tab in front, then isSecureContext is
#     read and, when false, the origin is added to Quest Browser chrome://flags #unsafely-treat-insecure-origin-as-secure
#     and the browser restarts once (WebXR needs a secure context).
#   Host (the flag lists exact origins, so a new DHCP address means one more flag add + browser restart):
#     questPlaylistXrHost / $env:PLAYLIST_XR_HOST = auto (default): <COMPUTERNAME>.local, then <COMPUTERNAME>, when the headset
#     resolves it to this PC (adb shell ping), else this PC's IPv4 on the route to the headset; ip = always the IPv4;
#     <name> = that name (e.g. a router DNS name). A name that then fails to load falls back to the IPv4 once.
#     Most reliable static option: a DHCP reservation for this PC in the router (the IPv4 then never changes).
#   Quit: the XR origins opened (%TEMP%\playlist-xr-origins.json) and http://{pc}:<port> are added to the control page's
#     tab close + history delete. (A running Loop Segments companion does its own quit cleanup without them: add
#     "http://{pc}:18768" to questPlaylistHistoryOrigins if you want them covered there too.)
#
# Fisheye background color (fisheye + hybrid workflows, Explorer v360 prepare too): the area around each eye's fisheye
#   circle. run_batch_fisheye_v360.ps1 / run_batch_vr_hybrid.ps1 -FisheyeBackgroundColor black (default) | green | red | blue,
#   or a persistent default: setx FISHEYE_BACKGROUND_COLOR green. The launcher exports FISHEYE_BACKGROUND_COLOR so every
#   child uses it: Run-FisheyeV360.ps1 (pass-1 mezzanine) and Run-TranscodeFfmpeg.ps1 -Fisheye take -FisheyeBackgroundColor
#   too (individual_transcode\Resolve-FisheyeBackgroundColor.ps1). Colors are pure (#00FF00 / #FF0000 / #0000FF; ffmpeg's
#   own 'green' is #008000). The XR page turns Chroma on with that key color, so with Enter AR the room (passthrough) shows
#   around the fisheye picture; black = Chroma off by default. Pick a color the video itself does not use much.
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
#   waits one idle poll (-LiveQueueIdlePollSec, default 20s) then finishes (or Enter / BatchTimeoutSec).
#   Each .avs -> Run-TranscodeFfmpeg.ps1 child -> 3d_op_%02d_Full_SBS.mkv
#   av1_qsv integer CFR (24/25/30/50/60); NTSC 29.97 tagged 30 via AssumeFPS (QSV rejects 29.97).
#   DLNA segments: -segment_time 60 -segment_wrap 2 (~60s per file, two-slot rotation; one encode per clip)
#   Clips shorter than 60s only mux 3d_op_00; Copy-DlnaWrapSlotIfShortClip copies 00 -> 01 so both slots refresh
#   -BatchTimeoutSec 5400 default (entire queue wall-clock; same semantics as fisheye batch)
#   Child wait heartbeat: source_duration/5s per clip (Get-FisheyePrepareHeartbeat.ps1; -PrepareHeartbeatDivisor)
#   Keys: orchestrator window — Space=pause leaf export; Enter=cancel clip (see top matrix). Deadline applies while paused.
#   PotPlayer DPL playname/playtime for queue anchor + per-clip seek (30s backoff on playtime)
#   Per-clip -ss also uses PotPlayer RememberFiles registry (Get-PotPlayerRegistrySeek.ps1)
#   Context menu (Install-ContextMenu.ps1):
#     .mp4/.mkv/.mov/.m4v/.avi/.wmv/.ts/.m2ts/.webm -> flat or fisheye prepare (RememberFiles + 5s key override; standardized if present)
#     .avs -> flat SBS transcode; successful .avs may hand off to orchestrator
#   Output: M:\m1_media\3d_fullsbs_trans\flat\3d_op_%02d_Full_SBS.mkv
#   AVS purge: Purge-OldAvs.ps1 — workflows keep newest 50 under .\avs at start of
#     run_batch_convert_streamTo3D.ps1, Run-TranscodeOrchestrator.ps1, and run_batch_vr_hybrid.ps1;
#     running Purge-OldAvs.ps1 alone does a full .\avs purge

# =============================================================================
# HYBRID workflow (per-clip asis / flat / fisheye from resolution + bitrate + codec)
# =============================================================================
# Recommended: .\run_batch_vr_hybrid.ps1 beside media_files.txt (setup_script_files.py deploys it with the other batch launchers)
#   Same PotPlayer gate, live media_files.txt queue, -BatchTimeoutSec 5400, Space/Enter, resume sidecar as fisheye batch.
#   Startup: Purge-OldAvs.ps1 -KeepCount 50 under .\avs (standalone purge = full wipe).
#   av1_qsv integer CFR (same as flat / fisheye): 24/25/30/50/60; NTSC 29.97 tagged 30 via AssumeFPS.
#   Minute-segment encode bitrate (flat + fisheye pass-2): -SegmentVideoBitrateMbps, else
#     LOOP_SEGMENTS_SEGMENT_VIDEO_BITRATE_MBPS, else the PC -> Quest LAN test the Quest control page runs on
#     the headset at workflow start (%TEMP%\loopsegments-quest-lan-throughput.json: 80% of measured, 5-100 Mbps,
#     under 12 h old; read by every encode: each ~1 min fisheye chase round; a running flat clip checks it every 5 s and
#     restarts its ffmpeg at the next segment boundary when it moves >= 15% (same timestamp, next wrap slot, new -b:v) -
#     so a test made after the start applies within ~1-2 min in both; the hybrid batch only pins a value you chose, otherwise it passes
#     its sidecar result as -SegmentVideoBitrateFallbackMbps below the Quest result), else lan_recommended_segment_bitrate.json /
#     scripts\lan_throughput.json from Measure-LoopSegmentsLanThroughput.ps1 (after rclone L: mount;
#     default recommend = 80% of measured LAN Mbps). -SkipLanBitrateCap ignores sidecars (falls back to ~30M).
#   Per clip: if already-3D (Test-Skip3dFormattedMediaName) OR resolution above asisAboveReferencePx
#     -> Run-SegmentCopyAsIs (-c copy -re) into ...\hybrid\ with asisSegmentSuffix (default LR_180).
#     Config: hybrid_workflow.json (HYBRID_WORKFLOW_CONFIG, {media}\hybrid_workflow.json, or
#     .\3d_playlist_local\hybrid_workflow.json from hub robocopy):
#       asisAboveReferencePx (default 2048) — SBS coded width when w>=2*h, else longer edge; ref > threshold
#       flatNonHevcAv1MaxKbps (default 4000) / flatHevcAv1MaxKbps (default 2000) — below -> flat, else fisheye
#       defaultKindWhenBitrateUnknown (asis|flat|fisheye, default fisheye)
#       asisSegmentSuffix (default LR_180)
#     As-is remux ignores encode bitrate / -maxrate caps; -BatchTimeoutSec / -WorkflowDeadlineUtc still apply;
#     -TranscodeTimeoutSec -1.
#     Else Resolve-HybridWorkflowRoute (bitrate + codec using the flat* thresholds above):
#     fisheye -> Run-V360PrepareFisheye.ps1 -AutoChaseTranscode -ChaseSync -SegmentNameSuffix LR_180_FISHEYE
#               -SegmentOutputDirectory M:\m1_media\3d_fullsbs_trans\hybrid
#     flat    -> Export StreamTo3D.fisheye_temp.template.avs with source path (no StreamTo3D GUI).
#               Same idea as flat's per-clip .avs (path + fps filled in), but this template is
#               passthrough only: DirectShowSource + AssumeFPS integer + StackHorizontal if 2D.
#               It does not run StreamTo3D 2D->3D / MDepan (unlike the flat GUI .avs).
#               then Run-TranscodeFfmpeg -SegmentNameSuffix Full_SBS -OutputDirectory ...\hybrid
#   Minute segments multiplexed to one folder (Skybox tokens): ...\hybrid\3d_op_%02d_Full_SBS.mkv /
#     ...\hybrid\3d_op_%02d_LR_180_FISHEYE.mkv / ...\hybrid\3d_op_%02d_LR_180.mkv (as-is). Suffix switches keep the prior pair until the new encode
#   Clips / chase rounds shorter than 60s: Copy-DlnaWrapSlotIfShortClip copies the written slot onto the other
#     (00->01 or 01->00) so wrap-2 always has two files (flat Full_SBS, fisheye pass-2, as-is LR_180)
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
#   cursor to the oldest live item (skips completed-this-run paths). If still empty, waits one idle poll
#   (-LiveQueueIdlePollSec, default 20s; separate from -MediaFolderWatcherPollSec) then finishes
#   (or until BatchTimeoutSec / Enter).
#   AutoHotkey companions from <root>\AutoHotkey (or -SkipPotPlayer / -SkipCompanionBinaries).
#   -BatchTimeoutSec 5400 entire queue; prepare children get -WorkflowDeadlineUtc (not per-clip timeout).
#   DPL playtime (first batch clip only, 30s backoff): pass-1 mezzanine -SsSec; pass-2 from mezzanine t=0.
#   -SkipPotPlayerSeek: pass-1 and pass-2 start at 0s for every clip.
#   Per clip: if already-3D (Test-Skip3dFormattedMediaName) -> Run-SegmentCopyAsIs (-c copy -re) into
#     ...\hybrid\ with Skybox suffix LR_180 (Get-AsIsDlnaSegmentSuffix; skips prepare/chase). As-is
#     remux ignores encode bitrate / -maxrate caps; batch deadline still applies.
#     Else Run-V360PrepareFisheye.ps1 -AutoChaseTranscode -ChaseSync (inline pass-2 in hidden prepare shell).
#   -InterClipWaitSec 0 disables inter-clip DLNA buffer (default 0 in script; set 60 if you want minute gap).
#   Pass 1: Run-FisheyeV360.ps1 -LiteralPath ... -> fisheye_temp\{base}.fisheye.frag.mp4 (av1_qsv 50M fragmented)
#     (no F:\f1_media\fisheye_test defaults; omitted -OutputDirectory writes beside the input)
#     av1_qsv integer CFR (24/25/30/50/60); NTSC 29.97 tagged 30 via AssumeFPS (QSV rejects 29.97).
#   Pass 2: Run-TranscodeFfmpeg.ps1 chase -> M:\m1_media\3d_fullsbs_trans\fisheye\3d_op_%02d_LR_180_FISHEYE.mkv (av1_qsv 75M, readrate 1)
#     same integer CFR snap as pass 1 / flat.
#     60-second DLNA segments: -segment_time 60 -segment_wrap 2 -reset_timestamps 1
#     Chase (fisheye_temp\avs): each round -t 60 max; alternates -segment_start_number 0 then 1
#     After a round (or tail mux) shorter than 60s: copy that slot onto the other (00<->01)
#       so both 3d_op_00/01_LR_180_FISHEYE.mkv refresh (short clips never open the second mux file)
#     Tail refresh at chase end may re-mux up to ~120s from clip tail when last round <60s
#     Context-menu / -ChaseWorker: same chase logic; see individual_transcode\LOGS.md
#   AVS: fisheye_temp\avs\StreamTo3D.fisheye_temp.{source}.avs (passthrough template; no StreamTo3D MDepan)
#   Context menu (common video types) -> Prepare v360 fisheye + chase DLNA segments:
#     standardized\{filename} under 3d_playlist_local used when present (generate_media_listings_lcl.py / selective_stdize.ps1)
#     -WorkflowTimeoutSec 5400 default (same wall-clock as -BatchTimeoutSec, one clip from prepare start; no duration scaling)
#     pass-1 RememberFiles resume (+ 5s key override); pass-2 hidden background worker (shared deadline; TranscodeTimeoutSec -1)
#     prepare window wait heartbeat: source_duration/5s (Get-FisheyePrepareHeartbeat.ps1; same as batch) + chase transcript tail
#   Keys: batch control window — Space=pause leaf export; Enter=cancel clip/batch (see top matrix). Hidden prepare does not receive keys.
#     prepare window waits for hidden pass-2 worker then auto-closes in 8s on success (Enter cancels while waiting)
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
# 'media_files.txt' will auto-refresh on batch runs! (generate_media_listings_lcl.py at every batch start, -DryRun too)
#   Recursive walk of the media root, but one media_files.txt PER FOLDER listing only that folder's own files
#   (oldest first) - not one combined list; a launcher queues only its own folder's list.
#   Listed: .mp4 .wmv .ts .mkv only (.webm / .m4v / .avi skipped); macOS ._name sidecars ignored;
#   3d_playlist_local\standardized\<same name> listed instead of the original when present.
# Folder watcher (both workflows): Watch-MediaFolderPlaylists.ps1
#   Polls media root in background; on new/changed media or flat .avs refreshes media_files.txt,
#   fisheye_batch.m3u/_potplayer.dpl, and playlist.m3u/playlist_potplayer.dpl (via gen_dpl.py).
#   Auto-started by run_batch_fisheye_v360.ps1, run_batch_vr_hybrid.ps1, and run_batch_convert_streamTo3D.ps1 (one instance per media root).
#   Fisheye/hybrid batch and flat orchestrator both continue after the current clip through the live playlist tail;
#   on empty tail they reset the cursor to the oldest live item, then one idle poll (-LiveQueueIdlePollSec, default 20s) if still empty.
#   Manual: .\3d_playlist_local\Watch-MediaFolderPlaylists.ps1 [-Once] [-PollSeconds 60] [-Foreground]
#   Polls recursively every 60 s; keeps running after the batch ends (stop its hidden powershell.exe to end it).
#   Opt out: -SkipMediaFolderWatcher on either batch script (also not started with -DryRun). Logs: individual_transcode\transcode_logs\media_folder_watcher\

# optional/as-needed
# <root>\global_rand_3d_playlist\purge_old_data.py
