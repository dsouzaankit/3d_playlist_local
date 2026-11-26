// Ported from ios_3d_loop_segments ios/LoopSegments/Resources/xr-app.js (3d_playlist_local
// individual_transcode/xr, served by serve_xr_page.py). Playlists are the DLNA segment folders
// (hybrid / fisheye / flat, 3d_op_NN[_Suffix].mkv, segment_wrap 2) instead of the phone's
// Loop / Working / Archive; each clip picks its projection from the Skybox suffix.
(function () {
  var CFG = window.__XR_CONFIG__ || {};
  var FOLDERS = CFG.folders || { hybrid: "hybrid/", fisheye: "fisheye/", flat: "flat/" };
  var MODES = ["hybrid", "fisheye", "flat"];
  var MODE_LABELS = { hybrid: "Hybrid", fisheye: "Fisheye", flat: "Flat" };
  var PROJ_KEY = "playlistlocal.xr.projection.v1";
  // A file written to within this long is still being muxed (segment_wrap 2 rewrites a slot in place).
  var GROWING_MS = 2500;
  var RATE_KEY = "loopsegments.lan.xrChromaRate.v1";
  var VOL_KEY = "loopsegments.lan.xrVolume.v1";
  var KEY_KEY = "loopsegments.lan.xrChromaKey.v1";
  var MODE_KEY = "playlistlocal.xr.mode.v1";
  var RATES = [0.7, 0.8, 0.85, 0.9, 1, 1.1, 1.2, 1.3];
  var playlists = { hybrid: [], fisheye: [], flat: [] };
  var archivePlaylist = [];
  var mode = MODES.indexOf(CFG.defaultMode) >= 0 ? CFG.defaultMode : "hybrid";
  var loadedModifiedMs = 0;
  var listsLoaded = false;
  var index = 0;
  var wantPlay = false;
  var video = document.getElementById("chroma-stream");
  var overlay = document.getElementById("overlay");
  var label = document.getElementById("xr-label");
  var rateSel = document.getElementById("xr-rate");
  var volumeEl = document.getElementById("xr-volume");
  var volumeLaunchEl = document.getElementById("xr-volume-launch");
  var launchBtn = document.getElementById("xr-launch");
  var prevBtn = document.getElementById("xr-prev");
  var nextBtn = document.getElementById("xr-next");
  var modeBtns = {
    hybrid: document.getElementById("xr-mode-hybrid"),
    fisheye: document.getElementById("xr-mode-fisheye"),
    flat: document.getElementById("xr-mode-flat")
  };
  var projSel = document.getElementById("xr-projection");
  var fileListEl = document.getElementById("xr-file-list");
  var refreshBtn = document.getElementById("xr-refresh-list");
  var reopenBtn = document.getElementById("xr-reopen");
  var transport = document.getElementById("xr-transport");
  var playPauseBtn = document.getElementById("xr-playpause");
  var seekEl = document.getElementById("xr-seek");
  var seekBackBtn = document.getElementById("xr-seek-back");
  var fullscreenBtn = document.getElementById("xr-fullscreen");
  var seekFwdBtn = document.getElementById("xr-seek-fwd");
  var timeEl = document.getElementById("xr-time");
  var chromaToggle = document.getElementById("xr-chroma-toggle");
  var chromaKeyEl = document.getElementById("xr-chroma-key");
  var chromaKeyPlayEl = document.getElementById("xr-chroma-key-play");
  var sbsToggle = document.getElementById("xr-sbs-toggle");
  var seekDragging = false;
  if (!video || !overlay) return;
  // Same-origin LAN files must not use crossOrigin=anonymous (no CORS headers → black WebGL + audio OK).
  try {
    video.crossOrigin = null;
    video.removeAttribute("crossorigin");
  } catch (e) {}

  function sphereEls() {
    return [
      document.getElementById("chroma-screen"),
      document.getElementById("chroma-sphere"),
      document.getElementById("chroma-sphere-right")
    ].filter(Boolean);
  }
  function refreshSphereShader() {
    sphereEls().forEach(function (el) {
      var comp = el.components && el.components["chroma-stereo-sbs"];
      if (comp) try { comp.applyShader(); } catch (e) {}
    });
  }
  function chromaKeyColor() {
    var raw = (chromaKeyEl && chromaKeyEl.value) || "#00ff00";
    if (!/^#[0-9a-fA-F]{6}$/.test(raw)) return "#00ff00";
    return raw.toLowerCase();
  }
  function syncShaderToggles() {
    var chromaOn = !!(chromaToggle && chromaToggle.checked);
    var sbsOn = !sbsToggle || !!sbsToggle.checked;
    var key = chromaKeyColor();
    sphereEls().forEach(function (el) {
      try {
        el.setAttribute("chroma-stereo-sbs", "chroma", chromaOn);
        el.setAttribute("chroma-stereo-sbs", "sbs", sbsOn);
        el.setAttribute("chroma-stereo-sbs", "keyColor", key);
      } catch (e) {}
    });
  }
  function applyChromaKey(hex) {
    if (!/^#[0-9a-fA-F]{6}$/.test(hex || "")) hex = "#00ff00";
    hex = hex.toLowerCase();
    if (chromaKeyEl) chromaKeyEl.value = hex;
    if (chromaKeyPlayEl) chromaKeyPlayEl.value = hex;
    Array.prototype.forEach.call(document.querySelectorAll(".xr-key-swatches button"), function (b) {
      b.classList.toggle("active", (b.getAttribute("data-key") || "").toLowerCase() === hex);
    });
    try { localStorage.setItem(KEY_KEY, hex); } catch (e) {}
    syncShaderToggles();
    refreshSphereShader();
  }

  function setLabel(msg) {
    if (label) label.textContent = msg || "";
  }
  function normalizeMode(m) {
    if (MODES.indexOf(m) >= 0) return m;
    return MODES.indexOf(CFG.defaultMode) >= 0 ? CFG.defaultMode : "hybrid";
  }
  function activePlaylist() {
    return playlists[mode] || [];
  }
  function emptyLabel() {
    return "No " + FOLDERS[mode] + "3d_op_*.mkv from this run yet — start the " + MODE_LABELS[mode].toLowerCase()
      + " workflow (or wait for its first 60 s segment); the list fills in by itself";
  }
  function modeTag() {
    return mode;
  }
  function listGroupTitle() {
    return MODE_LABELS[mode] + " segments (" + FOLDERS[mode] + ", oldest first"
      + (staleLoop[mode] ? "; previous run, until this run writes one" : "") + ")";
  }
  // Projection from the Skybox name suffix (3d_op_NN_<suffix>.mkv), unless the picker forces one.
  function autoProjection(name) {
    var n = String(name || "");
    if (/FISHEYE/i.test(n)) return "fisheye";
    if (/_(LR|TB)?_?180\.[a-z0-9]+$/i.test(n)) return "vr180";
    return "flat";
  }
  function projectionFor(item) {
    var forced = projSel && projSel.value;
    if (forced === "vr180" || forced === "fisheye" || forced === "flat") return forced;
    return autoProjection(item && item.name);
  }
  function applyProjection(item) {
    var p = projectionFor(item);
    window.__xrProjection = p;
    sphereEls().forEach(function (el) {
      var comp = el.components && el.components["chroma-stereo-sbs"];
      if (!comp) return;
      comp._domeGeoReady = false;
      try { comp.ensureDomeGeometry(); comp.syncEyeLayers(); } catch (eP) {}
    });
    return p;
  }
  function leafName(path) {
    var n = normPath(path);
    var i = n.lastIndexOf("/");
    return i >= 0 ? n.slice(i + 1) : n;
  }
  function formatBytes(n) {
    var b = Number(n) || 0;
    if (b <= 0) return "";
    if (b < 1024) return b + " B";
    if (b < 1024 * 1024) return Math.round(b / 1024) + " KB";
    return (b / (1024 * 1024)).toFixed(1) + " MB";
  }
  function formatClock(sec) {
    var s = Math.max(0, Math.floor(Number(sec) || 0));
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    var r = s % 60;
    var mm = (h > 0 ? String(m).padStart(2, "0") : String(m));
    var ss = String(r).padStart(2, "0");
    return h > 0 ? (h + ":" + mm + ":" + ss) : (mm + ":" + ss);
  }
  function syncPlayPauseLabel() {
    if (!playPauseBtn) return;
    playPauseBtn.textContent = video.paused ? "Play" : "Pause";
  }
  function mediaDuration() {
    var dur = Number(video.duration);
    if (isFinite(dur) && dur > 0) return dur;
    try {
      if (video.seekable && video.seekable.length > 0) {
        var end = video.seekable.end(video.seekable.length - 1);
        if (isFinite(end) && end > 0) return end;
      }
    } catch (e) {}
    return 0;
  }
  function clampSeekTime(t) {
    t = Number(t);
    if (!isFinite(t) || t < 0) t = 0;
    var dur = mediaDuration();
    if (dur > 0) t = Math.min(dur, t);
    try {
      if (video.seekable && video.seekable.length > 0) {
        for (var i = 0; i < video.seekable.length; i++) {
          var a = video.seekable.start(i);
          var b = video.seekable.end(i);
          if (t >= a && t <= b) return t;
        }
        // Snap to nearest seekable edge (sparse _working holes, partial buffers).
        var best = video.seekable.start(0);
        var bestDist = Math.abs(t - best);
        for (var j = 0; j < video.seekable.length; j++) {
          var s = video.seekable.start(j);
          var e = video.seekable.end(j);
          if (Math.abs(t - s) < bestDist) { best = s; bestDist = Math.abs(t - s); }
          if (Math.abs(t - e) < bestDist) { best = e; bestDist = Math.abs(t - e); }
        }
        return best;
      }
    } catch (e) {}
    return t;
  }
  function applySeekTime(t) {
    t = clampSeekTime(t);
    if (!isFinite(t)) return;
    try {
      if (typeof video.fastSeek === "function") video.fastSeek(t);
      else video.currentTime = t;
    } catch (e) {
      try { video.currentTime = t; } catch (e2) {}
    }
    try {
      if (typeof __xrVideoTex !== "undefined" && __xrVideoTex && __xrDs.av1Known && __xrDs.av1 === true) __xrVideoTex.needsUpdate = true;
    } catch (e3) {}
    try { refreshSphereShader(); } catch (e4) {}
    syncTransportUI();
  }
  function endSeekDrag() {
    if (!seekDragging) return;
    seekDragging = false;
    if (seekEl) applySeekTime(parseFloat(seekEl.value));
    else syncTransportUI();
  }
  function syncTransportUI() {
    if (!seekEl || !timeEl) return;
    var dur = mediaDuration();
    var cur = Number(video.currentTime) || 0;
    var max = dur > 0 ? dur : Math.max(cur, 1);
    // Keep max current even while dragging so the thumb can travel the full bar.
    seekEl.min = "0";
    seekEl.max = String(max);
    if (!seekDragging) {
      seekEl.value = String(Math.min(cur, max));
    }
    timeEl.textContent = formatClock(seekDragging ? (parseFloat(seekEl.value) || cur) : cur)
      + " / " + formatClock(dur);
    syncPlayPauseLabel();
  }
  function showTransport(show) {
    if (!transport) return;
    transport.style.display = show ? "block" : "none";
    if (show) transport.removeAttribute("hidden");
    else transport.setAttribute("hidden", "");
    if (show) syncTransportUI();
  }
  function exitImmersiveIfNeeded() {
    try {
      var scene = document.querySelector("a-scene");
      if (scene && scene.is && (scene.is("vr-mode") || scene.is("ar-mode")) && scene.exitVR) {
        scene.exitVR();
      }
    } catch (e) {}
  }
  function stopPlaybackForHome() {
    // Pause alone can leave Quest WebXR decoding / audio running under the overlay.
    // Suspend AV1 first, exit XR, then dispose GPU — never dispose while presenting.
    wantPlay = false;
    try { xrSuspendAv1Pipeline(); } catch (eSus) {}
    __xrDs.exiting = false;
    try { video.pause(); } catch (e) {}
    exitImmersiveIfNeeded();
    try {
      video.removeAttribute("src");
      video.load();
    } catch (e2) {}
    try { syncPlayPauseLabel(); } catch (e3) {}
    try { refreshSphereShader(); } catch (e4) {}
    try { xrScheduleDisposeAv1Gpu(); } catch (eDisp) {}
    try { xrLog("files-home", { sawAv1Tex: !!__xrDs.sawAv1Tex }); } catch (eL) {}
  }
  function showOverlay(show) {
    overlay.style.display = show ? "flex" : "none";
    if (reopenBtn) reopenBtn.style.display = show ? "none" : "block";
    showTransport(!show);
    if (show) {
      stopPlaybackForHome();
    } else {
      closeArchiveDropdown();
      __xrDs.exiting = false;
      __xrDs.suspendBlit = false;
      try { refreshSphereShader(); } catch (eKick) {}
      try { xrLog("launch-engine", { sawAv1Tex: !!__xrDs.sawAv1Tex }); } catch (eL) {}
    }
    syncArchiveFloat();
  }
  function seekBy(delta) {
    applySeekTime((Number(video.currentTime) || 0) + delta);
  }
  var workingSeekSec = 0;
  // Phone-only (sparse _working.mp4 resume point); nothing to fetch on the PC.
  function refreshWorkingSeek() {
    workingSeekSec = 0;
    return Promise.resolve();
  }
  function applyWorkingSeekIfNeeded(item) {
    if (!item || !isSparseWorkingName(item.name) || !(workingSeekSec > 0)) return;
    var target = workingSeekSec;
    var apply = function () {
      try {
        if (Math.abs((video.currentTime || 0) - target) > 0.5) video.currentTime = target;
      } catch (e) {}
    };
    if (video.readyState >= 1) apply();
    else {
      var onMeta = function () {
        video.removeEventListener("loadedmetadata", onMeta);
        apply();
      };
      video.addEventListener("loadedmetadata", onMeta);
    }
  }
  var archiveDd = document.getElementById("xr-archive-dd");
  var archiveDdList = document.getElementById("xr-archive-dd-list");
  var archiveDdClose = document.getElementById("xr-archive-dd-close");
  var archiveFloat = document.getElementById("xr-archive-float");
  function archiveSelectionLabel() {
    var playlist = archivePlaylist;
    if (!playlist.length) return emptyLabel();
    var item = playlist[index] || playlist[0];
    var sz = formatBytes(item.bytes);
    return (index + 1) + "/" + playlist.length + " · " + leafName(item.name)
      + (sz ? " · " + sz : "");
  }
  function closeArchiveDropdown() {
    if (!archiveDd) return;
    archiveDd.classList.remove("open");
    archiveDd.setAttribute("aria-hidden", "true");
  }
  function openArchiveDropdown() {
    if (!archiveDd || !archiveDdList) return;
    archiveDdList.innerHTML = "";
    var playlist = archivePlaylist;
    if (!playlist.length) {
      var empty = document.createElement("div");
      empty.className = "xr-file-empty";
      empty.textContent = emptyLabel();
      archiveDdList.appendChild(empty);
    } else {
      playlist.forEach(function (item, idx) {
        var btn = document.createElement("button");
        btn.type = "button";
        btn.className = "xr-file-item" + (idx === index ? " selected" : "");
        btn.setAttribute("role", "option");
        btn.setAttribute("aria-selected", idx === index ? "true" : "false");
        var nameEl = document.createElement("span");
        nameEl.className = "xr-file-name";
        nameEl.textContent = leafName(item.name);
        var meta = document.createElement("span");
        meta.className = "xr-file-meta";
        var bits = [];
        var sz = formatBytes(item.bytes);
        if (sz) bits.push(sz);
        bits.push(item.name);
        meta.textContent = bits.join(" · ");
        btn.appendChild(nameEl);
        btn.appendChild(meta);
        btn.onclick = function () {
          closeArchiveDropdown();
          loadIndex(idx, wantPlay && !video.paused);
        };
        archiveDdList.appendChild(btn);
      });
    }
    archiveDd.classList.add("open");
    archiveDd.setAttribute("aria-hidden", "false");
  }
  function makeArchivePickButton() {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "xr-archive-pick";
    btn.setAttribute("aria-haspopup", "listbox");
    btn.setAttribute("aria-expanded", "false");
    var labelEl = document.createElement("span");
    labelEl.className = "xr-archive-pick-label";
    labelEl.textContent = archiveSelectionLabel();
    var chev = document.createElement("span");
    chev.className = "xr-archive-pick-chevron";
    chev.textContent = "▾";
    btn.appendChild(labelEl);
    btn.appendChild(chev);
    btn.onclick = function (e) {
      e.preventDefault();
      e.stopPropagation();
      openArchiveDropdown();
    };
    return btn;
  }
  function syncArchiveFloat() {
    if (!archiveFloat) return;
    // Floater belongs on the Launch Engine picker page — not over playback.
    var overlayOpen = overlay && overlay.style.display !== "none";
    var show = mode === "archive" && overlayOpen;
    archiveFloat.style.display = show ? "block" : "none";
    if (show) {
      archiveFloat.removeAttribute("hidden");
      archiveFloat.innerHTML = "";
      archiveFloat.appendChild(makeArchivePickButton());
    } else {
      archiveFloat.setAttribute("hidden", "");
      archiveFloat.innerHTML = "";
    }
  }
  function renderFileList() {
    if (!fileListEl) return;
    fileListEl.innerHTML = "";
    var playlist = activePlaylist();
    if (mode === "archive") {
      var wrap = document.createElement("div");
      wrap.className = "xr-archive-pick-wrap";
      if (!playlist.length) {
        var empty = document.createElement("div");
        empty.className = "xr-file-empty";
        empty.textContent = emptyLabel();
        wrap.appendChild(empty);
      } else {
        wrap.appendChild(makeArchivePickButton());
      }
      fileListEl.appendChild(wrap);
      syncArchiveFloat();
      return;
    }
    if (!playlist.length) {
      var empty2 = document.createElement("div");
      empty2.className = "xr-file-empty";
      empty2.textContent = emptyLabel();
      fileListEl.appendChild(empty2);
      syncArchiveFloat();
      return;
    }
    function addGroup(title) {
      var g = document.createElement("div");
      g.className = "xr-file-group";
      g.textContent = title;
      fileListEl.appendChild(g);
    }
    function addItem(item, idx, groupHint) {
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "xr-file-item" + (idx === index ? " selected" : "");
      btn.setAttribute("role", "option");
      btn.setAttribute("aria-selected", idx === index ? "true" : "false");
      btn.dataset.index = String(idx);
      var nameEl = document.createElement("span");
      nameEl.className = "xr-file-name";
      nameEl.textContent = leafName(item.name);
      var meta = document.createElement("span");
      meta.className = "xr-file-meta";
      var bits = [];
      if (groupHint) bits.push(groupHint);
      var sz = formatBytes(item.bytes);
      if (sz) bits.push(sz);
      bits.push(item.name);
      meta.textContent = bits.join(" · ");
      btn.appendChild(nameEl);
      btn.appendChild(meta);
      btn.onclick = function () {
        loadIndex(idx, wantPlay && !video.paused);
      };
      fileListEl.appendChild(btn);
    }
    addGroup(listGroupTitle());
    playlist.forEach(function (item, idx) { addItem(item, idx, modeTag()); });
    syncArchiveFloat();
  }
  if (archiveDdClose) archiveDdClose.onclick = function () { closeArchiveDropdown(); };
  if (archiveDd) {
    archiveDd.addEventListener("click", function (e) {
      if (e.target === archiveDd) closeArchiveDropdown();
    });
  }
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") closeArchiveDropdown();
  });
  function snapRate(v) {
    var r = Math.round(Number(v) * 20) / 20;
    if (!isFinite(r)) return 1;
    for (var i = 0; i < RATES.length; i++) {
      if (Math.abs(RATES[i] - r) < 0.001) return RATES[i];
    }
    return 1;
  }
  function readRate() {
    var v = 1;
    try {
      var raw = localStorage.getItem(RATE_KEY);
      if (raw != null) v = parseFloat(raw);
    } catch (e) {}
    return snapRate(v);
  }
  function writeRate(v) {
    try { localStorage.setItem(RATE_KEY, String(snapRate(v))); } catch (e) {}
  }
  function readMode() {
    try {
      var saved = localStorage.getItem(MODE_KEY);
      if (saved && MODES.indexOf(saved) >= 0) return saved;
    } catch (e) {}
    return normalizeMode("");
  }
  function writeMode(m) {
    try { localStorage.setItem(MODE_KEY, normalizeMode(m)); } catch (e) {}
  }
  function applyRate() {
    var v = readRate();
    if (rateSel) rateSel.value = String(v);
    try { video.playbackRate = v; } catch (e) {}
  }
  function readVolume() {
    var v = 1;
    try {
      var raw = localStorage.getItem(VOL_KEY);
      if (raw != null) v = parseFloat(raw);
    } catch (e) {}
    if (!isFinite(v)) v = 1;
    return Math.max(0, Math.min(1, Math.round(v * 10) / 10));
  }
  function applyVolume(v) {
    v = Math.max(0, Math.min(1, Math.round(Number(v) * 10) / 10));
    if (!isFinite(v)) v = 1;
    try { localStorage.setItem(VOL_KEY, String(v)); } catch (e) {}
    try {
      video.volume = v;
      video.muted = v <= 0;
    } catch (e2) {}
    if (volumeEl) volumeEl.value = String(v);
    if (volumeLaunchEl) volumeLaunchEl.value = String(v);
    var label = document.getElementById("xr-vol-label");
    if (label) label.setAttribute("value", Math.round(v * 100) + "%");
    window.__xrVolume = v;
  }
  window.__xrStepVolume = function (delta) {
    applyVolume(readVolume() + Number(delta || 0));
  };
  function syncModeButtons() {
    MODES.forEach(function (m) {
      if (modeBtns[m]) modeBtns[m].classList.toggle("active", mode === m);
    });
  }
  function normPath(name) {
    return String(name || "").replace(/\\/g, "/");
  }
  function isVideoExt(name) {
    return /\.(mp4|m4v|mov|webm|mkv)$/i.test(name);
  }
  // DLNA minute segment directly in a workflow folder: 3d_op_NN[_Suffix].mkv.
  function isSegmentName(name, prefix) {
    var n = normPath(name);
    if (n.indexOf(prefix) !== 0) return false;
    var rest = n.slice(prefix.length);
    if (!rest || rest.indexOf("/") >= 0) return false;
    return /^3d_op_\d+/i.test(rest) && isVideoExt(rest);
  }
  // No sparse _working.mp4 on the PC (phone-only resume seek).
  function isSparseWorkingName() { return false; }
  function cacheBust(entry) {
    var q = [];
    if (entry.bytes) q.push("b=" + encodeURIComponent(String(entry.bytes)));
    if (entry.modified) q.push("m=" + encodeURIComponent(String(entry.modified)));
    // b + t name this version: the server serves a finished one from a snapshot copy, so the wrap-2
    // rewrite of the slot (~60 s after it closed) cannot cut off its last seconds mid-playback.
    if (entry.modifiedMs) q.push("t=" + encodeURIComponent(String(entry.modifiedMs)));
    if (isGrowing(entry)) q.push("g=1");  // still being muxed: the server serves the live file
    return q.length ? ("?" + q.join("&")) : "";
  }
  // The server's flag (Windows lists an open file with 0 bytes and its open time, so ageMs alone said
  // "finished" for the slot still being written), else the age.
  function isGrowing(f) {
    return !!(f && (f.growing || (Number(f.ageMs) || 0) < GROWING_MS));
  }
  function entryFromFile(f) {
    var name = f && f.name;
    return {
      name: name,
      bytes: Number(f.bytes) || 0,
      modified: f.modified || "",
      modifiedMs: Number(f.modifiedMs) || 0,
      ageMs: Number(f.ageMs) || 0,
      growing: isGrowing(f),
      stale: !!f.stale,
      url: "/media/" + String(name).replace(/^\/+/, "").split("/").map(encodeURIComponent).join("/") + cacheBust(f)
    };
  }
  // Oldest first: with segment_wrap 2 the slot written longest ago plays first, and a hybrid folder
  // that switched route (LR_180 / LR_180_FISHEYE / Full_SBS) keeps the order it was written in.
  function buildPlaylist(files, prefix) {
    var list = Array.isArray(files) ? files : [];
    var out = [];
    var seen = {};
    list.forEach(function (f) {
      var name = f && f.name;
      if (!name || seen[name] || !isSegmentName(name, prefix)) return;
      seen[name] = true;
      out.push(entryFromFile(f));
    });
    out.sort(function (a, b) {
      if (a.modifiedMs !== b.modifiedMs) return a.modifiedMs - b.modifiedMs;
      return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
    });
    return out;
  }
  // Start on the newest finished segment (the newest one is usually still being written).
  function liveStartIndex(list) {
    for (var i = list.length - 1; i >= 0; i--) {
      if (!list[i].growing) return i;
    }
    return 0;
  }
  function buildArchivePlaylist() { return []; }
  function loadIndex(i, autoplay) {
    var playlist = activePlaylist();
    if (!playlist.length) {
      setLabel(emptyLabel());
      renderFileList();
      return;
    }
    index = ((i % playlist.length) + playlist.length) % playlist.length;
    var item = playlist[index];
    wantPlay = !!autoplay;
    // New clip: soft reset in XR (keep last frame); hard reset only outside XR.
    try {
      if (xrIsPresenting()) xrPrepareNewClip();
      else xrResetPlaybackPipeline();
    } catch (eReset) {}
    var proj = applyProjection(item);
    loadedModifiedMs = item.modifiedMs || 0;
    try { xrLog("loadIndex", { i: index, name: item.name, proj: proj, presenting: !!xrIsPresenting(), sawAv1Tex: !!__xrDs.sawAv1Tex }); } catch (eLog) {}
    video.src = item.url;
    applyRate();
    setLabel("[" + modeTag() + " · " + proj + "] " + (index + 1) + "/" + playlist.length + ": " + leafName(item.name)
      + (item.stale ? " · previous run (looping until this run's first segment)" : ""));
    renderFileList();
    syncShaderToggles();
    applyWorkingSeekIfNeeded(item);
    var onReady = function () {
      applyWorkingSeekIfNeeded(item);
      refreshSphereShader();
    };
    var onLoaded = function () {
      video.removeEventListener("loadeddata", onLoaded);
      onReady();
    };
    video.addEventListener("loadeddata", onLoaded);
    if (video.readyState >= 2) onReady();
    if (wantPlay) {
      var p = video.play();
      if (p && typeof p.then === "function") {
        p.then(function () {
          applyWorkingSeekIfNeeded(item);
          refreshSphereShader();
        }).catch(function () {
          wantPlay = false;
          setLabel("Play blocked — tap Launch Engine");
        });
      } else {
        refreshSphereShader();
      }
    } else {
      refreshSphereShader();
    }
  }
  function setMode(next, keepPlay) {
    mode = normalizeMode(next);
    writeMode(mode);
    syncModeButtons();
    index = liveStartIndex(activePlaylist());
    if (activePlaylist().length) loadIndex(index, !!(keepPlay && wantPlay));
    else {
      try {
        video.removeAttribute("src");
        video.load();
      } catch (e) {}
      setLabel(emptyLabel());
      renderFileList();
    }
  }
  // Slots the server marks stale are left over from an earlier run. Loop them until this run has a
  // finished slot (one still being muxed would stall at the write head), then play only this run's.
  var staleLoop = { hybrid: false, fisheye: false, flat: false };
  function pickRun(list) {
    var fresh = list.filter(function (e) { return !e.stale; });
    var stale = list.filter(function (e) { return e.stale; });
    if (!stale.length || fresh.some(function (e) { return !e.growing; })) return { list: fresh, stale: false };
    return { list: stale, stale: true };
  }
  function setPlaylists(files) {
    MODES.forEach(function (m) {
      var r = pickRun(buildPlaylist(files, FOLDERS[m]));
      playlists[m] = r.list;
      staleLoop[m] = r.stale;
    });
    archivePlaylist = buildArchivePlaylist(files);
  }
  function fetchLists() {
    return fetch("xr_lists.json", { cache: "no-store" })
      .then(function (r) { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
      .then(function (j) { noteDeadlines(j); return (j && j.files) || []; });
  }
  // Workflow timeout countdown: the running workflow's -BatchTimeoutSec deadline per folder (xr_lists.json
  // deadlineMs, from the session registration). Counted against the PC clock (server "now"), so a headset
  // clock that is off does not shift it. The deadline keeps running while export is paused, like the workflow's.
  var deadlineEl = document.getElementById("xr-deadline");
  var deadlines = {};       // folder -> epoch ms (PC clock)
  var clockSkewMs = 0;      // PC now - this device's now
  function noteDeadlines(j) {
    if (!j) return;
    deadlines = (j.deadlineMs && typeof j.deadlineMs === "object") ? j.deadlineMs : {};
    if (typeof j.now === "number") clockSkewMs = j.now - Date.now();
    renderDeadline();
  }
  function formatHms(sec) {
    sec = Math.max(0, Math.floor(sec));
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    return (h ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (s < 10 ? "0" : "") + s;
  }
  function renderDeadline() {
    if (!deadlineEl) return;
    // This page's playlist first; else the one running workflow (the page may show another mode).
    var folder = deadlines[mode] ? mode : null;
    if (!folder) {
      var others = MODES.filter(function (m) { return deadlines[m]; });
      if (others.length === 1) folder = others[0];
    }
    if (!folder) { deadlineEl.hidden = true; return; }
    var left = (deadlines[folder] - (Date.now() + clockSkewMs)) / 1000;
    var tag = folder === mode ? "" : MODE_LABELS[folder] + " ";
    deadlineEl.textContent = left > 0
      ? tag + "workflow timeout in " + formatHms(left)
      : tag + "workflow timeout reached";
    deadlineEl.className = left <= 0 ? "over" : (left <= 600 ? "soon" : "");
    deadlineEl.hidden = false;
  }
  setInterval(renderDeadline, 1000);
  // The playback polls only run around clip ends / an empty list: refresh the deadline on its own.
  setInterval(function () { fetchLists().catch(function () {}); }, 20000);
  function applyFiles(files) {
    var curName = (activePlaylist()[index] || {}).name;
    setPlaylists(files);
    applyRate();
    var list = activePlaylist();
    if (list.length) {
      var keep = -1;
      if (listsLoaded && curName) list.forEach(function (e, i) { if (e.name === curName) keep = i; });
      listsLoaded = true;
      loadIndex(keep >= 0 ? keep : liveStartIndex(list), false);
    } else {
      setLabel(emptyLabel());
      renderFileList();
    }
  }
  function refreshPlaylists() {
    setLabel("Refreshing file list…");
    return fetchLists()
      .then(function (files) { applyFiles(files); })
      .catch(function () {
        applyFiles([]);
        setLabel("Could not refresh xr_lists.json (is the PC XR server still running?)");
      });
  }
  // Live follow of the wrap-2 slots: after a clip ends, play the next segment written after it
  // (oldest such first). Wait while it is still being muxed, unless a newer one already exists
  // (the writer has moved on, so it is complete). Falls back to name order when nothing is newer.
  var advancing = false;
  function advanceLive() {
    if (advancing) return;
    advancing = true;
    var curName = (activePlaylist()[index] || {}).name;
    var since = loadedModifiedMs;
    var tries = 0;
    function pick() {
      var list = activePlaylist();
      var newer = list.filter(function (e) { return e.name !== curName && e.modifiedMs > since; });
      if (!newer.length) return null;
      var next = newer[0];
      var growing = next.growing && newer.length === 1;
      return { item: next, growing: growing };
    }
    function step() {
      fetchLists().then(function (files) {
        setPlaylists(files);
        // Still on the previous run's leftovers: no newer slot will come from them, so go straight to
        // the next one (oldest first, wrapping) instead of waiting.
        if (staleLoop[mode] && activePlaylist().length) {
          var ls = activePlaylist();
          var atS = -1;
          ls.forEach(function (e, i) { if (e.name === curName) atS = i; });
          advancing = false;
          loadIndex(atS + 1, true);
          return;
        }
        var p = pick();
        tries++;
        // A slot takes ~60 s to write: wait it out rather than play it live (that stalls at the write head).
        if (p && (!p.growing || tries >= 90)) {
          var list = activePlaylist();
          advancing = false;
          loadIndex(list.indexOf(p.item), true);
          return;
        }
        if (!p && tries >= 90) {
          advancing = false;
          var l2 = activePlaylist();
          if (!l2.length) { setLabel(emptyLabel()); renderFileList(); return; }
          var at = -1;
          l2.forEach(function (e, i) { if (e.name === curName) at = i; });
          loadIndex(at + 1, true);
          return;
        }
        setLabel(p ? ("Waiting for " + leafName(p.item.name) + " to finish writing…") : "Waiting for the next segment…");
        setTimeout(step, 1000);
      }).catch(function () {
        tries++;
        if (tries >= 20) { advancing = false; loadIndex(index + 1, true); return; }
        setTimeout(step, 1000);
      });
    }
    step();
  }
  // Launch pressed before this run wrote its first segment: start it when it appears (emptyListPoll).
  var waitingFirst = false;
  function initializePlayer() {
    var playlist = activePlaylist();
    if (!playlist.length) {
      waitingFirst = true;
      setLabel("Waiting for the first " + MODE_LABELS[mode].toLowerCase() + " segment of this run…");
      return;
    }
    waitingFirst = false;
    wantPlay = true;
    if (!video.src) loadIndex(index, true);
    else {
      applyRate();
      var p = video.play();
      if (p && typeof p.then === "function") {
        p.then(function () { refreshSphereShader(); }).catch(function () {});
      } else {
        refreshSphereShader();
      }
    }
    showOverlay(false);
    // Give the mesh a moment after overlay hide / first paint.
    setTimeout(refreshSphereShader, 200);
    setTimeout(refreshSphereShader, 800);
  }
  if (launchBtn) launchBtn.onclick = initializePlayer;
  // An empty playlist (new run still standardizing / preparing) fills in by itself; if Launch was pressed,
  // or playback was following the slots when the list emptied, playback starts on the first segment.
  setInterval(function () {
    if (advancing || activePlaylist().length) return;
    fetchLists().then(function (files) {
      if (advancing || activePlaylist().length || !buildPlaylist(files, FOLDERS[mode]).length) return;
      var go = waitingFirst || (wantPlay && overlay.style.display === "none");
      applyFiles(files);
      if (go) initializePlayer();
    }).catch(function () {});
  }, 3000);
  MODES.forEach(function (m) {
    if (modeBtns[m]) modeBtns[m].onclick = function () { setMode(m, false); };
  });
  if (projSel) {
    try {
      var savedProj = localStorage.getItem(PROJ_KEY);
      if (savedProj) projSel.value = savedProj;
    } catch (eProj) {}
    projSel.onchange = function () {
      try { localStorage.setItem(PROJ_KEY, projSel.value); } catch (eP2) {}
      var item = activePlaylist()[index];
      var p = applyProjection(item);
      if (item) setLabel("[" + modeTag() + " · " + p + "] " + (index + 1) + "/" + activePlaylist().length + ": " + leafName(item.name));
      refreshSphereShader();
    };
  }
  // Flat screen aspect is known only once the video's size is.
  video.addEventListener("loadedmetadata", function () {
    if (window.__xrProjection === "flat") applyProjection(activePlaylist()[index]);
  });
  if (refreshBtn) refreshBtn.onclick = function () { refreshPlaylists(); };
  var zoomEl = document.getElementById("xr-zoom");
  if (zoomEl) {
    window.__xrZoom = Number(zoomEl.value) || 1;
    zoomEl.addEventListener("input", function () {
      window.__xrZoom = Number(zoomEl.value) || 1;
      var lab = document.getElementById("xr-zoom-label");
      if (lab) lab.setAttribute("value", Math.round(window.__xrZoom * 180) + "°");
      sphereEls().forEach(function (el) {
        var comp = el.components && el.components["chroma-stereo-sbs"];
        if (!comp) return;
        comp._domeGeoReady = false;
        try { comp.ensureDomeGeometry(); comp.syncEyeLayers(); } catch (eZ) {}
      });
    });
  }
  var distEl = document.getElementById("xr-dist");
  if (distEl) {
    window.__xrDist = Number(distEl.value) || 0;
    distEl.addEventListener("input", function () {
      window.__xrDist = Number(distEl.value) || 0;
      // followHead reads __xrDist every immersive frame; nudge once for immediate feedback.
      sphereEls().forEach(function (el) {
        var comp = el.components && el.components["chroma-stereo-sbs"];
        if (comp) try { comp.followHead(); } catch (eD) {}
      });
    });
  }
  if (chromaToggle) chromaToggle.onchange = function () { syncShaderToggles(); refreshSphereShader(); };
  if (chromaKeyEl) chromaKeyEl.oninput = function () { applyChromaKey(chromaKeyEl.value); };
  if (chromaKeyPlayEl) chromaKeyPlayEl.oninput = function () { applyChromaKey(chromaKeyPlayEl.value); };
  Array.prototype.forEach.call(document.querySelectorAll(".xr-key-swatches button"), function (b) {
    b.onclick = function () { applyChromaKey(b.getAttribute("data-key")); };
  });
  try {
    var savedKey = localStorage.getItem(KEY_KEY);
    if (savedKey && /^#[0-9a-fA-F]{6}$/.test(savedKey)) applyChromaKey(savedKey);
  } catch (eKey) {}
  // Fisheye background (Resolve-FisheyeBackgroundColor.ps1): a key color means the area around the
  // fisheye circles is meant to be keyed out -> Chroma on with that key. Black = Chroma on with key
  // #000000, which xr-components.js treats as a luma key (near-black pixels -> passthrough; very dark
  // scene content shows the room too).
  (function applyBackgroundDefaults() {
    var bg = CFG.fisheyeBackground || {};
    var name = String(bg.name || "black");
    var css = String(bg.css || "");
    if (name === "black") css = "#000000";
    if (chromaToggle) chromaToggle.checked = true;
    if (/^#[0-9a-fA-F]{6}$/.test(css)) applyChromaKey(css);
    else syncShaderToggles();
  })();
  if (sbsToggle) sbsToggle.onchange = function () { syncShaderToggles(); refreshSphereShader(); };
  if (reopenBtn) {
    reopenBtn.onclick = function () {
      showOverlay(true);
      setLabel("Stopped — pick a file, then Launch Engine");
      renderFileList();
    };
  }
  function togglePlayPause() {
    if (!video || !video.src) return;
    if (video.paused) {
      wantPlay = true;
      var p = video.play();
      if (p && typeof p.then === "function") {
        p.then(function () { refreshSphereShader(); syncPlayPauseLabel(); }).catch(function () {});
      } else {
        refreshSphereShader();
        syncPlayPauseLabel();
      }
    } else {
      video.pause();
      wantPlay = false;
      syncPlayPauseLabel();
    }
  }
  // Always the <video>, Chroma on or off: the browser player has full resolution and its
  // own controls (screen size, brightness, 180/3D menu). Keying only pays off in AR.
  function toggleFullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen();
      return;
    }
    if (xrIsPresenting()) return;
    var request = video.requestFullscreen || video.webkitRequestFullscreen;
    if (!request) return;
    var result = request.call(video);
    if (result && result.catch) {
      result.catch(function (e) {
        try { xrLog("fullscreen-failed", { error: String(e) }); } catch (eLog) {}
      });
    }
  }
  function onFullscreenChange() {
    var full = document.fullscreenElement;
    video.controls = full === video;
    if (fullscreenBtn) fullscreenBtn.textContent = full ? "Exit Fullscreen" : "Fullscreen";
    try { xrLog("fullscreen", { on: !!full }); } catch (eLog) {}
    // Back to the normal preview: rebind, or the plane stays on the fullscreen path.
    if (!full) {
      try { xrClearComponentModes(); } catch (eModes) {}
      try { refreshSphereShader(); } catch (eShader) {}
    }
  }
  document.addEventListener("fullscreenchange", onFullscreenChange);
  function isXrChromeTarget(el) {
    if (!el || !el.closest) return false;
    return !!el.closest(
      "#xr-transport, #xr-reopen, #overlay, #xr-archive-float, #xr-archive-dd,"
      + " .a-enter-vr, .a-enter-ar, .a-dialog, .a-modal, button, input, select, a, label"
    );
  }
  if (playPauseBtn) playPauseBtn.onclick = function () { togglePlayPause(); };
  // Click / tap the scene (not chrome) toggles play/pause during playback.
  document.addEventListener("click", function (e) {
    if (overlay && overlay.style.display !== "none") return;
    if (isXrChromeTarget(e.target)) return;
    // The fullscreen <video> has native controls. A tap here would toggle twice.
    if (document.fullscreenElement === video) return;
    togglePlayPause();
  });
  // Quest controller trigger (WebXR select) toggles play/pause in AR/VR.
  (function wireXrTriggerPlayPause() {
    var lastMs = 0;
    var boundSession = null;
    function onSelect(ev) {
      try {
        if (ev && ev.inputSource && ev.inputSource.targetRayMode === "gaze") return;
      } catch (eGaze) {}
      if (overlay && overlay.style.display !== "none") return;
      var now = Date.now();
      if (now - lastMs < 280) return;
      lastMs = now;
      togglePlayPause();
    }
    function unbind() {
      if (!boundSession) return;
      try { boundSession.removeEventListener("select", onSelect); } catch (eOff) {}
      boundSession = null;
    }
    function bind() {
      unbind();
      var session = null;
      try {
        var scene = document.querySelector("a-scene");
        session = scene && scene.renderer && scene.renderer.xr && scene.renderer.xr.getSession
          ? scene.renderer.xr.getSession()
          : null;
      } catch (eSess) {}
      if (!session) return;
      boundSession = session;
      try { session.addEventListener("select", onSelect); } catch (eOn) {}
    }
    var sceneEl = document.querySelector("a-scene");
    if (sceneEl) {
      sceneEl.addEventListener("enter-vr", function () { setTimeout(bind, 0); setTimeout(bind, 200); });
      sceneEl.addEventListener("exit-vr", unbind);
    }
  })();
  if (fullscreenBtn) fullscreenBtn.onclick = toggleFullscreen;
  if (seekBackBtn) seekBackBtn.onclick = function () { seekBy(-10); };
  if (seekFwdBtn) seekFwdBtn.onclick = function () { seekBy(10); };
  if (seekEl) {
    function beginSeekDrag() { seekDragging = true; }
    // Always seek on input — do not require pointerdown (Quest/PC often skip it on range).
    seekEl.addEventListener("pointerdown", beginSeekDrag);
    seekEl.addEventListener("mousedown", beginSeekDrag);
    seekEl.addEventListener("touchstart", beginSeekDrag, { passive: true });
    seekEl.addEventListener("input", function () {
      seekDragging = true;
      applySeekTime(parseFloat(seekEl.value));
    });
    seekEl.addEventListener("change", function () {
      applySeekTime(parseFloat(seekEl.value));
      seekDragging = false;
    });
    window.addEventListener("pointerup", endSeekDrag);
    window.addEventListener("pointercancel", endSeekDrag);
    window.addEventListener("mouseup", endSeekDrag);
    window.addEventListener("touchend", endSeekDrag);
    window.addEventListener("blur", endSeekDrag);
  }
  if (prevBtn) prevBtn.onclick = function () {
    if (!activePlaylist().length) return;
    loadIndex(index - 1, wantPlay && !video.paused);
  };
  if (nextBtn) nextBtn.onclick = function () {
    if (!activePlaylist().length) return;
    loadIndex(index + 1, wantPlay && !video.paused);
  };
  if (rateSel) {
    rateSel.value = String(readRate());
    rateSel.onchange = function () {
      var v = parseFloat(rateSel.value);
      if (!isFinite(v)) v = 1;
      writeRate(v);
      applyRate();
    };
  }
  function onVolumeInput(e) {
    applyVolume(e && e.target ? e.target.value : readVolume());
  }
  if (volumeEl) {
    volumeEl.value = String(readVolume());
    volumeEl.addEventListener("input", onVolumeInput);
  }
  if (volumeLaunchEl) {
    volumeLaunchEl.value = String(readVolume());
    volumeLaunchEl.addEventListener("input", onVolumeInput);
  }
  applyVolume(readVolume());
  video.addEventListener("loadedmetadata", function () { applyVolume(readVolume()); });
  video.addEventListener("timeupdate", syncTransportUI);
  video.addEventListener("durationchange", syncTransportUI);
  video.addEventListener("loadedmetadata", syncTransportUI);
  video.addEventListener("seeked", function () {
    try {
      if (typeof __xrVideoTex !== "undefined" && __xrVideoTex && __xrDs.av1Known && __xrDs.av1 === true) __xrVideoTex.needsUpdate = true;
    } catch (e) {}
    try { refreshSphereShader(); } catch (e2) {}
    syncTransportUI();
  });
  video.addEventListener("progress", syncTransportUI);
  video.addEventListener("play", syncPlayPauseLabel);
  video.addEventListener("pause", syncPlayPauseLabel);
  video.addEventListener("ended", function () {
    if (!activePlaylist().length) return;
    advanceLive();
  });
  // Safety net: a clip that stops progressing in its last seconds (slot rewritten before the server
  // could snapshot it, short final cluster, audio/video tail mismatch) never fires "ended". Treat a
  // 6 s stall within 8 s of the end, or a 20 s stall anywhere, as the end and move on.
  (function stallWatchdog() {
    var lastT = -1;
    var lastMoveMs = Date.now();
    setInterval(function () {
      var now = Date.now();
      var cur = Number(video.currentTime) || 0;
      if (!wantPlay || video.paused || advancing || !video.src || seekDragging) {
        lastT = cur;
        lastMoveMs = now;
        return;
      }
      if (Math.abs(cur - lastT) > 0.05) {
        lastT = cur;
        lastMoveMs = now;
        return;
      }
      var dur = mediaDuration();
      var stalledMs = now - lastMoveMs;
      // 6 s near the end, or 20 s anywhere (unknown duration: a live slot stalled at its write head).
      var nearEnd = dur > 0 && dur - cur <= 8;
      if ((nearEnd && stalledMs >= 6000) || stalledMs >= 20000) {
        try { xrLog("stall-advance", { t: cur, dur: dur, nearEnd: nearEnd, readyState: video.readyState, name: (activePlaylist()[index] || {}).name }); } catch (eL) {}
        lastMoveMs = now;
        if (activePlaylist().length) advanceLive();
      }
    }, 1000);
  })();
  // A clip that fails while following the live slots (the server answers 410 once a version is gone)
  // moves on to the next segment; only repeated failures drop back to the file list.
  var errorStreak = 0;
  video.addEventListener("playing", function () { errorStreak = 0; });
  video.addEventListener("error", function () {
    var playlist = activePlaylist();
    var item = playlist[index];
    var err = video.error;
    try { xrLog("media-error", { name: item && item.name, code: err && err.code, msg: err && err.message, streak: errorStreak + 1 }); } catch (eL) {}
    if (!video.getAttribute("src")) return;  // src removed on purpose (home / mode switch)
    if (wantPlay && playlist.length && ++errorStreak <= 3) {
      setLabel("Could not play " + leafName(item && item.name) + " — moving to the next segment…");
      advanceLive();
      return;
    }
    errorStreak = 0;
    setLabel("Could not load " + (item && item.name ? item.name : "media")
      + (playlist.length > 1 ? " — pick another from the list" : " (no finished segment yet?)"));
    wantPlay = false;
    showOverlay(true);
    renderFileList();
  });
  mode = readMode();
  syncModeButtons();
  showOverlay(true);
  try {
    var params = new URLSearchParams(window.location.search || "");
    var qMode = params.get("mode");
    var hashMode = String(window.location.hash || "").replace(/^#/, "");
    if (qMode) mode = normalizeMode(qMode);
    else if (hashMode) mode = normalizeMode(hashMode);
    writeMode(mode);
    syncModeButtons();
  } catch (e) {}
  (function probeWebXR() {
    var el = document.getElementById("xr-webxr-status");
    if (!el) return;
    var secure = !!(window.isSecureContext);
    var origin = String(location.origin || "");
    function setStatus(msg) { el.textContent = msg; }
    if (!navigator.xr) {
      setStatus("WebXR API missing — origin " + origin
        + (secure ? " (secure context OK)" : " (NOT a secure context — need https:// tunnel or Quest flags)"));
      return;
    }
    var done = false;
    function finish(vr, ar) {
      if (done) return;
      done = true;
      setStatus("WebXR @ " + origin
        + " — immersive-vr: " + (vr ? "yes" : "no")
        + ", immersive-ar (passthrough): " + (ar ? "yes — use Enter AR" : "no")
        + (secure ? "" : " — insecure context"));
    }
    var timeout = setTimeout(function () {
      if (done) return;
      done = true;
      setStatus("WebXR probe timed out @ " + origin
        + (secure ? "" : " — insecure context; PC preview still works after Launch"));
    }, 2500);
    Promise.all([
      navigator.xr.isSessionSupported("immersive-vr").catch(function () { return false; }),
      navigator.xr.isSessionSupported("immersive-ar").catch(function () { return false; })
    ]).then(function (bits) {
      clearTimeout(timeout);
      finish(!!bits[0], !!bits[1]);
    }).catch(function () {
      clearTimeout(timeout);
      finish(false, false);
    });
  })();
  refreshWorkingSeek().finally(function () {
    refreshPlaylists();
  });
})();
