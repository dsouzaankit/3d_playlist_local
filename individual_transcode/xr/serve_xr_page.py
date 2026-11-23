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
  /xr_lists.json         {files: [{name: "hybrid/3d_op_00_LR_180.mkv", bytes, modified, modifiedMs, ageMs}]}
  /media/<folder>/<file> the segment, with HTTP Range (seeking), no-store
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
CHUNK = 1024 * 1024


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


def session_pids() -> list[int]:
    try:
        with open(SESSION_PATH, "r", encoding="utf-8-sig") as fh:
            data = json.load(fh)
        return [int(s.get("pid", 0)) for s in (data.get("sessions") or []) if isinstance(s, dict)]
    except (OSError, ValueError, TypeError):
        return []


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
        for folder in FOLDERS:
            d = os.path.join(self.server.opts.root, folder)
            try:
                entries = list(os.scandir(d))
            except OSError:
                continue
            for e in entries:
                if not e.is_file() or not re.match(r"(?i)^3d_op_\d+", e.name):
                    continue
                if os.path.splitext(e.name)[1].lower() not in VIDEO_EXT:
                    continue
                try:
                    st = e.stat()
                except OSError:
                    continue
                files.append({
                    "name": "%s/%s" % (folder, e.name),
                    "bytes": st.st_size,
                    "modified": _dt.datetime.fromtimestamp(st.st_mtime, _dt.timezone.utc).isoformat(),
                    "modifiedMs": int(st.st_mtime * 1000),
                    "ageMs": max(0, int((now - st.st_mtime) * 1000)),
                })
        return {"root": self.server.opts.root, "now": int(now * 1000), "files": files}

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
    if opts.parent_pid > 0:
        threading.Thread(target=watch_parent, args=(server, opts.parent_pid), daemon=True).start()
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        try:
            with open(STATE_PATH, "r", encoding="utf-8") as fh:
                if json.load(fh).get("pid") == os.getpid():
                    os.remove(STATE_PATH)
        except (OSError, ValueError):
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
