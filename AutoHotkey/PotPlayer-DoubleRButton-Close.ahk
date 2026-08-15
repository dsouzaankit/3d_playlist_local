#Requires AutoHotkey v2.0
#SingleInstance Force

; Alternative: PotPlayer Right click > Exit.

; Two right-clicks within this many ms close PotPlayer (same video-area rules as HoldLMB/HoldMMB scripts).
; Slow or deliberate pacing may need a higher value — raise if logs show "previous expired".
DOUBLE_RBUTTON_MS := 650

; Set true to append lines to PotPlayer-DoubleRButton-debug.log beside this script and to OutputDebug
; (view with Sysinternals DebugView). Also shows last reason in a tray tip when DEBUG_DOUBLE_RCLICK.
DEBUG_DOUBLE_RCLICK := false

; Pixels to ignore at bottom (taskbar / seek / control strip). Increase if it still triggers on the bar.
VIDEO_BOTTOM_MARGIN := 90
; Client-area exclusions (left/top/right). Left uses 0: synthetic pointers sometimes report x=0 on valid video (see debug log).
EDGE_LEFT := 0
EDGE_TOP := 8
EDGE_RIGHT := 8

~RButton:: PotPlayerDoubleRButtonToClose()

DebugDbl(msg) {
    global DEBUG_DOUBLE_RCLICK
    if !DEBUG_DOUBLE_RCLICK
        return
    line := Format("{} | {}\n", A_Now, msg)
    try FileAppend line, A_ScriptDir "\PotPlayer-DoubleRButton-debug.log"
    OutputDebug msg
    TrayTip msg, "PotPlayer double-R debug"
}

PotPlayerDoubleRButtonToClose() {
    static lastTick := 0
    now := A_TickCount
    delta := (lastTick != 0) ? now - lastTick : -1
    if (lastTick != 0 && now - lastTick <= DOUBLE_RBUTTON_MS) {
        DebugDbl(Format("2nd RClick Δ={}ms (window {}ms) — checking PotPlayer...", delta, DOUBLE_RBUTTON_MS))
        lastTick := 0
    } else {
        if (lastTick != 0)
            DebugDbl(Format("1st RClick new double: previous expired (gap {}ms > {}ms)", delta, DOUBLE_RBUTTON_MS))
        else
            DebugDbl("1st RClick — armed; second within " DOUBLE_RBUTTON_MS " ms to close")
        lastTick := now
        return
    }

    MouseGetPos(, , &hwndUnder)
    if !hwndUnder {
        DebugDbl("abort: no hwnd under cursor")
        return
    }
    try exe := WinGetProcessName("ahk_id " hwndUnder)
    catch {
        DebugDbl("abort: WinGetProcessName failed")
        return
    }
    if exe != "PotPlayerMini64.exe" {
        DebugDbl(Format("abort: exe={} (want PotPlayerMini64.exe)", exe))
        return
    }

    pt := ScreenToClient(hwndUnder)
    if !pt {
        DebugDbl("abort: ScreenToClient failed")
        return
    }

    rect := Buffer(16, 0)
    if !DllCall("user32\GetClientRect", "ptr", hwndUnder, "ptr", rect) {
        DebugDbl("abort: GetClientRect failed")
        return
    }
    cw := NumGet(rect, 8, "int")
    ch := NumGet(rect, 12, "int")

    if (pt.x < EDGE_LEFT || pt.y < EDGE_TOP || pt.x > cw - EDGE_RIGHT || pt.y > ch - VIDEO_BOTTOM_MARGIN) {
        DebugDbl(Format(
            "abort: outside video rect client=({},{}) cw={} ch={} bottom_margin={} edges L/T/R={}/{}/{}",
            pt.x, pt.y, cw, ch, VIDEO_BOTTOM_MARGIN, EDGE_LEFT, EDGE_TOP, EDGE_RIGHT))
        return
    }

    DebugDbl(Format("OK: WinClose PotPlayer hwnd={} client=({},{})", hwndUnder, pt.x, pt.y))
    try WinClose("ahk_id " hwndUnder)
}

ScreenToClient(hwnd) {
    pt := Buffer(8, 0)
    if !DllCall("user32\GetCursorPos", "ptr", pt)
        return 0
    if !DllCall("user32\ScreenToClient", "ptr", hwnd, "ptr", pt)
        return 0
    return { x: NumGet(pt, 0, "int"), y: NumGet(pt, 4, "int") }
}
