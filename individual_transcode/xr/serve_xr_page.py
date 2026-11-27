"""Serve the Quest XR player page and the DLNA minute segments from this PC.

Page: individual_transcode/xr/xr-player.html + xr-app.js (this project's playlists). Engine:
xr-components.js + aframe.min.js from the shared quest_tools repo (quest_tools/xr, the one editable copy;
--engine-dir, else $QUEST_TOOLS_REPO, <ALL_SCRIPTS_ROOT>/quest_tools, a quest_tools folder next to any
parent of this folder, then P:/all_scripts/quest_tools). Ported from ios_3d_loop_segments, where the
iPhone app serves /xr. Here the media is the 3d_playlist_local
DLNA segment store (%APPDATA%\\3d_playlist_local\\{hybrid,fisheye,flat}\\3d_op_NN[_Suffix].mkv), the
same files the subst M:\\m1_media\\3d_fullsbs_trans share shows to SKYBOX.

Started (hidden) by quest\\Start-PlaylistLocalQuestXr.ps1 at a workflow start; also runs by hand:

    py -3 serve_xr_page.py --port 18768
    then open http://<this PC>:18768/xr in Quest Browser

Routes
  /xr                    the player page (?mode=hybrid|fisheye|flat picks the playlist)
  /xr-assets/<js>        aframe.min.js, xr-components.js, xr-app.js
  /xr-assets/lsclean     tiny 404 page without login (Quest helper tab for chrome://flags / history)
  /xr_lists.json         {files: [{name: "hybrid/3d_op_00_LR_180.mkv", bytes, modified, modifiedMs, ageMs}],
                         runStartMs, staleCount}: a slot older than its folder's running workflow (registered
                         in SESSION_PATH, name = folder) is a leftover of an earlier run: "stale": true (the page
                         loops those only until this run has a finished slot). deadlineMs: {folder: epoch ms}
                         of that workflow's -BatchTimeoutSec deadline (session deadlineUtc; the page counts down).
  /media/<folder>/<file> the segment, with HTTP Range (seeking), no-store. ?b=<bytes>&t=<mtime ms> (the
                         page's playlist entry) names the version: a finished one is served from a private
                         snapshot copy (see SNAP_DIR), since segment_wrap 2 truncates and rewrites that slot
                         ~60 s after it closed - while the headset still streams its last seconds.
  /xr_debug.json         GET {lines, snapshot}; POST {lines, snapshot} appends; POST {"action":"clear"}
  /healthz               "ok"

Read-only and LAN-wide (no login): only video files directly in hybrid/, fisheye/ and flat/ are served.
Stops when --parent-pid and every workflow registered in %TEMP%\\loopsegments-playlist-session.json are
gone (checked every 5 s). Stdlib only (py_venv1 or any Python 3.8+).
"""

from __future__ import annotations

import argparse
import ctypes
import datetime as _dt
import hashlib
import html
import json
import os
import re
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
FOLDERS = ("hybrid", "fisheye", "flat")
VIDEO_EXT = {".mkv": "video/webm", ".webm": "video/webm", ".mp4": "video/mp4", ".m4v": "video/mp4", ".mov": "video/mp4"}
PAGE_ASSETS = {"xr-app.js"}                          # this folder
ENGINE_ASSETS = {"aframe.min.js", "xr-components.js"}  # quest_tools/xr
ASSETS = PAGE_ASSETS | ENGINE_ASSETS
BG_COLORS = {"black": "#000000", "green": "#00ff00", "red": "#ff0000", "blue": "#0000ff"}
TEMP = os.environ.get("TEMP") or os.environ.get("TMP") or HERE
STATE_PATH = os.path.join(TEMP, "playlist-xr-server.json")
LOG_PATH = os.path.join(TEMP, "playlist-xr-server.log")
SESSION_PATH = os.path.join(TEMP, "loopsegments-playlist-session.json")
# Last /media request (the page is playing), in quest_tools' shared format (lib\QuestMediaActivity.ps1:
# one file per owner, read with Get-QuestMediaActivity). The Loop Segments companion's keep-awake reads it
# and keeps the phone's Keep Alive (its LAN server, so L:) going while the Quest plays. Written at most
# every ACTIVITY_WRITE_SEC; snapshot lines in the log are no proof of playback (the watcher copies for WATCH_SEC).
ACTIVITY_OWNER = "playlist"
ACTIVITY_PATH = os.path.join(TEMP, "quest-media-activity-%s.json" % ACTIVITY_OWNER)
ACTIVITY_WRITE_SEC = 15
CHUNK = 1024 * 1024
# Finished segments are copied here on first request and served from the copy. The muxer pacing is ~1x
# (flat: plus a 20 s initial burst and 1.2x catch-up), so the slot being watched is reopened with truncate
# before playback reaches its end: Range reads past the new size came back short, the <video> stalled in
# its last seconds and never fired "ended" (no advance to the next segment).
SNAP_DIR = os.path.join(TEMP, "playlist-xr-snapshots")
# snapshot_watcher makes the copy as soon as a slot is finished (for folders a page streamed from in the
# last WATCH_SEC), not on first request: the page drifts a few seconds behind the writer each minute
# (load + buffering), so by the time it asked for a slot the muxer could already be rewriting it.
SNAP_KEEP = 4               # newest copies kept per folder (~2 minutes per slot)
WATCH_SEC = 600
GROWING_SEC = 2.5           # written within this long = still being muxed (xr-app.js GROWING_MS)


def log(msg: str) -> None:
    line = "%s %s" % (_dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass
    try:
        print(line, flush=True)
    except Exception:
        pass


def note_media_activity(server, rel: str) -> None:
    now = time.time()
    if now - server.activity_written < ACTIVITY_WRITE_SEC:
        return
    server.activity_written = now
    rec = {"owner": ACTIVITY_OWNER, "lastMediaEpoch": now,
           "lastMediaUtc": _dt.datetime.now(_dt.timezone.utc).isoformat(),
           "media": rel, "pid": os.getpid()}
    try:
        tmp = ACTIVITY_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(rec, fh)
        os.replace(tmp, ACTIVITY_PATH)
    except OSError:
        pass


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        k32 = ctypes.windll.kernel32
        h = k32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        try:
            code = ctypes.c_ulong()
            if not k32.GetExitCodeProcess(h, ctypes.byref(code)):
                return False
            return code.value == 259  # STILL_ACTIVE
        finally:
            k32.CloseHandle(h)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def read_sessions() -> list[dict]:
    """The workflows registered in SESSION_PATH ([] when it is missing or unreadable)."""
    try:
        with open(SESSION_PATH, "r", encoding="utf-8-sig") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    sessions = data.get("sessions") if isinstance(data, dict) else None
    return [s for s in (sessions or []) if isinstance(s, dict)]


def session_pids() -> list[int]:
    try:
        return [int(s.get("pid", 0)) for s in read_sessions()]
    except (TypeError, ValueError):
        return []


def _parse_utc(s: str) -> float | None:
    """Epoch seconds of a .NET 'o' timestamp (2026-11-23T19:48:47.5822534Z: 7 fraction digits, which
    datetime.fromisoformat rejects before Python 3.11)."""
    m = re.match(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)?$", str(s or "").strip())
    if not m:
        return None
    y, mo, d, h, mi, se = (int(x) for x in m.groups()[:6])
    frac = float("0." + m.group(7)) if m.group(7) else 0.0
    tz = m.group(8) or "Z"
    off = 0 if tz == "Z" else (1 if tz[0] == "+" else -1) * (int(tz[1:3]) * 3600 + int(tz[4:6]) * 60)
    return _dt.datetime(y, mo, d, h, mi, se, tzinfo=_dt.timezone.utc).timestamp() + frac - off


def run_starts() -> tuple[dict[str, float], dict[str, float]]:
    """({folder: epoch s} when the running workflow for that folder registered (newest if several),
    {folder: epoch s} of that workflow's deadline). A slot older than the start is left over from an earlier
    run - this run has not reached it yet, and segment_wrap 2 may never reuse it. The page loops those
    back-to-back while the new run is still standardizing / preparing (it used to wait 90 s per clip for a
    "newer" one), and switches once this run has a finished slot. The deadline (-BatchTimeoutSec; none when
    it is 0 or an older copy registered the session) is the page's workflow timeout countdown."""
    out: dict[str, float] = {}
    deadlines: dict[str, float] = {}
    for s in read_sessions():
        if s.get("name") not in FOLDERS:
            continue
        try:
            if not pid_alive(int(s.get("pid", 0))):
                continue
        except (TypeError, ValueError):
            continue
        t = _parse_utc(s.get("registeredUtc"))
        if t is not None and t > out.get(s["name"], 0):
            out[s["name"]] = t
            d = _parse_utc(s.get("deadlineUtc"))
            if d is not None:
                deadlines[s["name"]] = d
            else:
                deadlines.pop(s["name"], None)
    return out, deadlines


def open_shared(path: str):
    """Open for reading without blocking others: on Windows plain open() lacks FILE_SHARE_DELETE, so
    the workflow's quit rename (segments -> <sha256>.tmp) and the segment muxer's rewrite of a
    wrap-2 slot would fail while the headset streams that file."""
    if os.name != "nt":
        return open(path, "rb")
    import msvcrt
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                                wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    k32.CreateFileW.restype = wintypes.HANDLE
    GENERIC_READ, SHARE_ALL, OPEN_EXISTING, NORMAL = 0x80000000, 0x7, 3, 0x80
    h = k32.CreateFileW(path, GENERIC_READ, SHARE_ALL, None, OPEN_EXISTING, NORMAL, None)
    if h is None or h == wintypes.HANDLE(-1).value:
        raise OSError(ctypes.get_last_error(), "CreateFileW failed", path)
    fd = msvcrt.open_osfhandle(h, os.O_RDONLY | getattr(os, "O_BINARY", 0))
    return os.fdopen(fd, "rb")


def find_engine_dir(explicit: str = "") -> str | None:
    """quest_tools/xr holding xr-components.js + aframe.min.js (same search order as the quest scripts)."""
    cands = []
    if explicit:
        cands.append(explicit)
    if os.environ.get("QUEST_TOOLS_REPO"):
        cands.append(os.path.join(os.environ["QUEST_TOOLS_REPO"], "xr"))
    if os.environ.get("ALL_SCRIPTS_ROOT"):
        cands.append(os.path.join(os.environ["ALL_SCRIPTS_ROOT"], "quest_tools", "xr"))
    d = HERE
    while True:
        cands.append(os.path.join(d, "quest_tools", "xr"))
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    cands.append(r"P:\all_scripts\quest_tools\xr")
    for c in cands:
        if all(os.path.isfile(os.path.join(c, n)) for n in ENGINE_ASSETS):
            return os.path.abspath(c)
    return None


def asset_path(opts, name: str) -> str:
    return os.path.join(opts.engine_dir if name in ENGINE_ASSETS else HERE, name)


def default_root() -> str:
    appdata = os.environ.get("APPDATA") or os.path.expanduser("~")
    return os.path.join(appdata, "3d_playlist_local")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False  # a second server on the same port must fail, not share it

    def __init__(self, addr, handler, opts):
        super().__init__(addr, handler)
        self.opts = opts
        self.debug_lines: list[str] = []
        self.debug_snapshot: dict = {}
        self.debug_lock = threading.Lock()
        self.snap_lock = threading.Lock()
        self.snap_locks: dict[str, threading.Lock] = {}
        self.watched: dict[str, float] = {}  # folder -> last /media request (snapshot_watcher copies these)
        self.activity_written = 0.0  # note_media_activity throttle

    def server_bind(self):
        # HTTPServer.server_bind calls socket.getfqdn(), which took ~6 s on this LAN (the launcher waits 10 s).
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class Handler(BaseHTTPRequestHandler):
    server: Server
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet: media requests are many
        pass

    # ---- helpers ----
    def _send(self, code: int, body: bytes, ctype: str, extra: dict | None = None, head_only=False):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _json(self, obj, code=200, head_only=False):
        self._send(code, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8", head_only=head_only)

    def _not_found(self, head_only=False):
        self._send(404, b"<!doctype html><title>404</title><p>Not found</p>", "text/html; charset=utf-8", head_only=head_only)

    # ---- routes ----
    def do_HEAD(self):
        self._route(head_only=True)

    def do_GET(self):
        self._route(head_only=False)

    def do_POST(self):
        path = urlsplit(self.path).path
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(min(length, 2 * 1024 * 1024)) if length > 0 else b""
        if path == "/xr_debug.json":
            try:
                data = json.loads(body.decode("utf-8") or "{}")
            except ValueError:
                data = {}
            with self.server.debug_lock:
                if data.get("action") == "clear":
                    self.server.debug_lines = []
                    self.server.debug_snapshot = {}
                else:
                    lines = [str(x) for x in (data.get("lines") or [])][:200]
                    self.server.debug_lines = (self.server.debug_lines + lines)[-400:]
                    if isinstance(data.get("snapshot"), dict):
                        self.server.debug_snapshot = data["snapshot"]
            self._json({"ok": True})
            return
        # keep_alive.json etc. are phone app routes: not here.
        self._not_found()

    def _route(self, head_only: bool):
        parts = urlsplit(self.path)
        path = parts.path
        # The page fetches xr_lists.json / xr_debug.json relative to /xr, so /xr/ must redirect too.
        if path in ("/", "/index.html", "/xr/"):
            self.send_response(302)
            self.send_header("Location", "/xr" + (("?" + parts.query) if parts.query else ""))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/xr":
            self._page(parse_qs(parts.query), head_only)
            return
        if path == "/healthz":
            self._send(200, b"ok", "text/plain", head_only=head_only)
            return
        if path == "/xr_lists.json":
            self._json(self._lists(), head_only=head_only)
            return
        if path == "/xr_debug.json":
            with self.server.debug_lock:
                self._json({"lines": list(self.server.debug_lines), "snapshot": self.server.debug_snapshot}, head_only=head_only)
            return
        if path.startswith("/xr-assets/"):
            name = path[len("/xr-assets/"):]
            if name in ASSETS:
                self._file(asset_path(self.server.opts, name), "text/javascript; charset=utf-8", head_only, cache="max-age=3600")
            else:
                # lsclean and anything else: a small no-login page (it must land in Quest history).
                self._not_found(head_only)
            return
        if path.startswith("/media/"):
            rel = unquote(path[len("/media/"):])
            full = self._media_path(rel)
            if not full:
                self._not_found(head_only)
                return
            ext = os.path.splitext(full)[1].lower()
            self.server.watched[rel.split("/")[0]] = time.time()
            if not head_only:
                note_media_activity(self.server, rel)
            q = parse_qs(parts.query)
            try:
                want = (int((q.get("b") or [""])[0]), int((q.get("t") or [""])[0]))
            except ValueError:
                want = None  # old-style URL: the live file
            if want and not q.get("g"):  # g=1: the page knowingly plays a slot still being written
                snap, status = make_snapshot(self.server, rel, full, *want)
                if snap:
                    self._file(snap, VIDEO_EXT[ext], head_only, ranged=True)
                    return
                if status == "gone":
                    # The slot already holds a newer minute and no copy of this one is left: serving the new
                    # bytes under the old version only breaks the decoder. 410 -> the page moves on.
                    self._send(410, b"segment version gone", "text/plain", head_only=head_only)
                    return
            self._file(full, VIDEO_EXT[ext], head_only, ranged=True)
            return
        self._not_found(head_only)

    def _media_path(self, rel: str) -> str | None:
        segs = rel.replace("\\", "/").split("/")
        if len(segs) != 2:
            return None
        folder, leaf = segs
        if folder not in FOLDERS or not leaf or leaf.startswith(".") or "\x00" in leaf:
            return None
        if os.path.splitext(leaf)[1].lower() not in VIDEO_EXT:
            return None
        base = os.path.realpath(os.path.join(self.server.opts.root, folder))
        full = os.path.realpath(os.path.join(base, leaf))
        if os.path.dirname(full) != base or not os.path.isfile(full):
            return None
        return full

    def _lists(self) -> dict:
        now = time.time()
        files = []
        starts, deadlines = run_starts()
        stale: dict[str, int] = {}
        for folder in FOLDERS:
            for e, st, growing in segment_states(self.server.opts.root, folder, now):
                is_stale = folder in starts and st.st_mtime < starts[folder]
                if is_stale:
                    stale[folder] = stale.get(folder, 0) + 1
                files.append({
                    "stale": is_stale,
                    "name": "%s/%s" % (folder, e.name),
                    "bytes": st.st_size,
                    "modified": _dt.datetime.fromtimestamp(st.st_mtime, _dt.timezone.utc).isoformat(),
                    "modifiedMs": int(st.st_mtime * 1000),
                    "ageMs": max(0, int((now - st.st_mtime) * 1000)),
                    "growing": growing,
                })
        return {"root": self.server.opts.root, "now": int(now * 1000), "files": files,
                "runStartMs": {f: int(t * 1000) for f, t in starts.items()}, "staleCount": stale,
                "deadlineMs": {f: int(t * 1000) for f, t in deadlines.items()}}

    def _page(self, query: dict, head_only: bool):
        opts = self.server.opts
        try:
            with open(os.path.join(HERE, "xr-player.html"), "r", encoding="utf-8-sig") as fh:
                page = fh.read()
        except OSError as ex:
            self._send(500, ("xr-player.html: %s" % ex).encode("utf-8"), "text/plain; charset=utf-8")
            return
        host = self.headers.get("Host") or "%s:%s" % (self.server.server_address[0], opts.port)
        mode = (query.get("mode") or [opts.default_mode])[0]
        if mode not in FOLDERS:
            mode = "hybrid"
        bg = (opts.fisheye_bg or os.environ.get("FISHEYE_BACKGROUND_COLOR") or "black").strip().lower()
        if bg not in BG_COLORS:
            bg = "black"
        config = {
            "folders": {f: f + "/" for f in FOLDERS},
            "defaultMode": mode,
            "fisheyeBackground": {"name": bg, "css": BG_COLORS[bg]},
            "root": opts.root,
        }
        cfg_json = json.dumps(config).replace("</", "<\\/")
        page = (page.replace("{{XR_CONFIG_JSON}}", cfg_json)
                .replace("{{XR_MEDIA_ROOT_HTML}}", html.escape(opts.root.rstrip("\\/") + "\\"))
                .replace("{{XR_HOST_HTML}}", html.escape(host))
                .replace("{{XR_ORIGIN_HTML}}", html.escape("http://" + host))
                .replace("{{XR_BG_HTML}}", html.escape("%s (%s)" % (bg, BG_COLORS[bg])))
                .replace("{{XR_BUILD}}", opts.build))
        self._send(200, page.encode("utf-8"), "text/html; charset=utf-8", head_only=head_only)

    def _file(self, full: str, ctype: str, head_only: bool, ranged=False, cache="no-store"):
        try:
            fh = open_shared(full)
        except OSError:
            self._not_found(head_only)
            return
        with fh:
            size = os.fstat(fh.fileno()).st_size
            start, end = 0, size - 1
            code = 200
            rng = self.headers.get("Range") if ranged else None
            if rng:
                m = re.match(r"^bytes=(\d*)-(\d*)$", rng.strip())
                if not m or (not m.group(1) and not m.group(2)):
                    self._send(416, b"", "text/plain", {"Content-Range": "bytes */%d" % size}, head_only=True)
                    return
                if m.group(1):
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else size - 1
                else:  # suffix range: last N bytes
                    start = max(0, size - int(m.group(2)))
                end = min(end, size - 1)
                if start > end or start >= size:
                    self._send(416, b"", "text/plain", {"Content-Range": "bytes */%d" % size}, head_only=True)
                    return
                code = 206
            length = end - start + 1 if size > 0 else 0
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(length))
            self.send_header("Cache-Control", cache)
            if ranged:
                self.send_header("Accept-Ranges", "bytes")
            if code == 206:
                self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
            self.end_headers()
            if head_only or length <= 0:
                return
            fh.seek(start)
            left = length
            try:
                while left > 0:
                    buf = fh.read(min(CHUNK, left))
                    if not buf:
                        # The slot was truncated (segment_wrap rewrite) under us: pad is wrong, just stop.
                        self.close_connection = True
                        return
                    self.wfile.write(buf)
                    left -= len(buf)
            except (ConnectionError, OSError):
                self.close_connection = True


def touch(path: str) -> None:
    try:
        os.utime(path, None)
    except OSError:
        pass


def file_state(entry, now: float):
    """(os.stat result, still being written?) for a segment. On Windows the directory listing (scandir /
    FindFirstFile) is only updated when the writer closes the file: a slot ffmpeg is muxing shows 0 bytes and
    the time it was opened, so it looked finished after 2.5 s and the page played it live and stalled at the
    write head. os.stat opens the file and sees the real size and a fresh mtime; a listing that disagrees
    with it means the file is still open for writing."""
    st = os.stat(entry.path)
    listed = entry.stat()
    growing = listed.st_size != st.st_size or now - st.st_mtime < GROWING_SEC
    return st, growing


def segment_states(root: str, folder: str, now: float):
    """(entry, stat, growing) for each 3d_op_NN*.<video> directly in root/folder (unreadable ones skipped)."""
    try:
        entries = list(os.scandir(os.path.join(root, folder)))
    except OSError:
        return
    for e in entries:
        if not e.is_file() or not re.match(r"(?i)^3d_op_\d+", e.name):
            continue
        if os.path.splitext(e.name)[1].lower() not in VIDEO_EXT:
            continue
        try:
            st, growing = file_state(e, now)
        except OSError:
            continue
        yield e, st, growing


def snapshot_path(rel: str, size: int, mtime_ms: int) -> str:
    leaf = "%s_%d_%d%s" % (rel.replace("/", "__"), size, mtime_ms, os.path.splitext(rel)[1].lower())
    return os.path.join(SNAP_DIR, leaf)


def make_snapshot(server, rel: str, full: str, want_b: int, want_t: int):
    """(path, "ok") for a private copy of version (bytes, mtime ms) of a segment, copying it now if the live
    file is that version and finished. Else (None, status): "growing" (still muxed: serve live), "gone" (the
    slot was rewritten and no copy is left), "fail" (copy failed or the file changed during it: serve live)."""
    dest = snapshot_path(rel, want_b, want_t)
    if os.path.isfile(dest):
        touch(dest)
        return dest, "ok"
    with server.snap_lock:
        lock = server.snap_locks.setdefault(dest, threading.Lock())
    with lock:
        if os.path.isfile(dest):
            return dest, "ok"
        try:
            st = os.stat(full)
        except OSError:
            return None, "gone"
        if st.st_size != want_b or int(st.st_mtime * 1000) != want_t:
            return None, "gone"
        if time.time() - st.st_mtime < GROWING_SEC:
            return None, "growing"
        tmp = dest + ".part"
        try:
            os.makedirs(SNAP_DIR, exist_ok=True)
            t0 = time.time()
            with open_shared(full) as src, open(tmp, "wb") as out:
                while True:
                    buf = src.read(8 * CHUNK)
                    if not buf:
                        break
                    out.write(buf)
            st2 = os.stat(full)
            if (st2.st_size, st2.st_mtime_ns) != (st.st_size, st.st_mtime_ns) or os.path.getsize(tmp) != st.st_size:
                log("XR server: %s changed while copying - no snapshot." % rel)
                os.remove(tmp)
                return None, "fail"
            os.replace(tmp, dest)
            log("XR server: snapshot %s (%.1f MB, %.1f s)." % (rel, st.st_size / 1048576.0, time.time() - t0))
        except OSError as ex:
            log("XR server: snapshot %s failed (%s)." % (rel, ex))
            try:
                os.remove(tmp)
            except OSError:
                pass
            return None, "fail"
    with server.snap_lock:
        server.snap_locks.pop(dest, None)
    prune_snapshots(keep=dest)
    return dest, "ok"


def snapshot_watcher(server) -> None:
    """Copy each finished slot of a watched folder within ~1 s of the muxer closing it."""
    while True:
        time.sleep(1.0)
        now = time.time()
        for folder in [f for f, t in list(server.watched.items()) if now - t < WATCH_SEC]:
            for e, st, growing in segment_states(server.opts.root, folder, now):
                if growing or st.st_size <= 0:
                    continue
                rel = "%s/%s" % (folder, e.name)
                ver = (st.st_size, int(st.st_mtime * 1000))
                if os.path.isfile(snapshot_path(rel, *ver)):
                    continue
                try:
                    make_snapshot(server, rel, e.path, *ver)
                except Exception as ex:  # never let the watcher die
                    log("XR server: snapshot watcher %s: %s" % (rel, ex))


def prune_snapshots(keep: str = "", limit: int = SNAP_KEEP) -> None:
    """Keep the `limit` most recently used copies per folder (limit 0 = remove all, .part included). A copy
    being streamed is opened with FILE_SHARE_DELETE, so removing it only unlinks the name; the reader finishes."""
    try:
        entries = [e for e in os.scandir(SNAP_DIR) if e.is_file() and (limit <= 0 or not e.name.endswith(".part"))]
    except OSError:
        return
    groups = {}
    for e in entries:
        groups.setdefault(e.name.split("__", 1)[0], []).append(e)
    for group in groups.values():
        group.sort(key=lambda e: e.stat().st_mtime, reverse=True)
        for e in (group[limit:] if limit > 0 else group):
            if os.path.abspath(e.path) == os.path.abspath(keep):
                continue
            try:
                os.remove(e.path)
            except OSError:
                pass


def asset_build(opts) -> str:
    h = hashlib.sha1()
    for name in sorted(ASSETS | {"xr-player.html"}):
        try:
            st = os.stat(asset_path(opts, name))
            h.update(("%s:%d:%d;" % (name, st.st_size, int(st.st_mtime))).encode())
        except OSError:
            pass
    return h.hexdigest()[:10]


def watch_parent(server: Server, parent: int):
    while True:
        time.sleep(5)
        if pid_alive(parent):
            continue
        if any(pid_alive(p) for p in session_pids() if p != parent):
            continue
        log("XR server: workflow PID %d gone and no other workflow registered - stopping." % parent)
        server.shutdown()
        return


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=18768)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--root", default="", help="segment store (default %%APPDATA%%\\3d_playlist_local)")
    ap.add_argument("--fisheye-bg", default="", choices=["", *BG_COLORS.keys()],
                    help="fisheye background (default: FISHEYE_BACKGROUND_COLOR env, else black)")
    ap.add_argument("--default-mode", default="hybrid", choices=FOLDERS)
    ap.add_argument("--parent-pid", type=int, default=0, help="stop when this PID (and every registered workflow) is gone")
    ap.add_argument("--engine-dir", default="", help="quest_tools/xr (default: found like the quest scripts find quest_tools)")
    opts = ap.parse_args()
    opts.root = os.path.abspath(opts.root or default_root())
    opts.engine_dir = find_engine_dir(opts.engine_dir)
    if not opts.engine_dir:
        log("XR server: quest_tools/xr (xr-components.js, aframe.min.js) not found - set QUEST_TOOLS_REPO or --engine-dir.")
        return 2
    opts.build = asset_build(opts)
    prune_snapshots(limit=0)  # copies from an earlier run
    try:
        server = Server((opts.bind, opts.port), Handler, opts)
    except OSError as ex:
        log("XR server: cannot listen on %s:%d (%s)." % (opts.bind, opts.port, ex))
        return 3
    state = {"pid": os.getpid(), "port": opts.port, "root": opts.root, "parentPid": opts.parent_pid,
             "started": _dt.datetime.now(_dt.timezone.utc).isoformat()}
    try:
        with open(STATE_PATH, "w", encoding="utf-8") as fh:
            json.dump(state, fh)
    except OSError:
        pass
    log("XR server: listening on %s:%d, root %s, engine %s (PID %d%s)." % (
        opts.bind, opts.port, opts.root, opts.engine_dir, os.getpid(), ", parent %d" % opts.parent_pid if opts.parent_pid else ""))
    threading.Thread(target=snapshot_watcher, args=(server,), daemon=True).start()
    if opts.parent_pid > 0:
        threading.Thread(target=watch_parent, args=(server, opts.parent_pid), daemon=True).start()
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        prune_snapshots(limit=0)
        try:
            with open(STATE_PATH, "r", encoding="utf-8") as fh:
                if json.load(fh).get("pid") == os.getpid():
                    os.remove(STATE_PATH)
        except (OSError, ValueError):
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
