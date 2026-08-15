#Requires AutoHotkey v2.0
#SingleInstance Force

; Three left-clicks close PotPlayer (same video-area rules as HoldLMB/HoldMMB scripts).
; Max ms between consecutive clicks (1->2 and 2->3). First->third span is at most 2*this (~2600 ms at 1300).
; Raise if logs show "gap Xms >" with intentional triples.
TRIPLE_GAP_MS := 1300

; Do not run alongside PotPlayer-HoldLMB-Close.ahk or PotPlayer-DoubleLButton-Close.ahk (same ~LButton).
; Pick one LButton companion or compile a single merged script.

; Set true: PotPlayer-TripleLButton-debug.log + OutputDebug + TrayTip (Sysinternals DebugView).
DEBUG_TRIPLE_LCLICK := false

; Pixels to ignore at bottom (taskbar / seek / control strip). Increase if it still triggers on the bar.
VIDEO_BOTTOM_MARGIN := 90
; Client-area exclusions (left/top/right). LEFT 0: synthetic pointers sometimes report x=0 on valid video.
EDGE_LEFT := 0
EDGE_TOP := 8
EDGE_RIGHT := 8

~LButton:: PotPlayerTripleLButtonToClose()

DebugTplL(msg) {
    global DEBUG_TRIPLE_LCLICK
    if !DEBUG_TRIPLE_LCLICK
        return
    line := Format("{} | {}\n", A_Now, msg)
    try FileAppend line, A_ScriptDir "\PotPlayer-TripleLButton-debug.log"
    OutputDebug msg
    TrayTip msg, "PotPlayer triple-L debug"
}

PotPlayerTripleLButtonToClose() {
    static lastTick := 0, firstTick := 0, clickCount := 0
    now := A_TickCount
    if (clickCount == 0 || lastTick == 0) {
        firstTick := now
        lastTick := now
        clickCount := 1
        DebugTplL("1st LClick -- armed; each gap <= " TRIPLE_GAP_MS " ms (~" (2 * TRIPLE_GAP_MS) " ms max first->third)")
        return
    }
    delta := now - lastTick
    span := now - firstTick
    if (delta > TRIPLE_GAP_MS) {
        DebugTplL(Format("1st LClick new triple: gap expired ({}ms > {}ms max between clicks)", delta, TRIPLE_GAP_MS))
        firstTick := now
        lastTick := now
        clickCount := 1
        return
    }
    clickCount += 1
    lastTick := now
    if clickCount < 3 {
        DebugTplL(Format(
            "LClick {} of 3 (delta={}ms since prior, span={}ms since first; gap<={}ms)",
            clickCount,
            delta,
            span,
            TRIPLE_GAP_MS))
        return
    }
    DebugTplL(Format("3rd LClick delta={}ms span={}ms -- checking PotPlayer...", delta, span))
    lastTick := 0
    firstTick := 0
    clickCount := 0

    MouseGetPos(, , &hwndUnder)
    if !hwndUnder {
        DebugTplL("abort: no hwnd under cursor")
        return
    }
    try exe := WinGetProcessName("ahk_id " hwndUnder)
    catch {
        DebugTplL("abort: WinGetProcessName failed")
        return
    }
    if exe != "PotPlayerMini64.exe" {
        DebugTplL(Format("abort: exe={} (want PotPlayerMini64.exe)", exe))
        return
    }

    pt := ScreenToClient(hwndUnder)
    if !pt {
        DebugTplL("abort: ScreenToClient failed")
        return
    }

    rect := Buffer(16, 0)
    if !DllCall("user32\GetClientRect", "ptr", hwndUnder, "ptr", rect) {
        DebugTplL("abort: GetClientRect failed")
        return
    }
    cw := NumGet(rect, 8, "int")
    ch := NumGet(rect, 12, "int")

    if (pt.x < EDGE_LEFT || pt.y < EDGE_TOP || pt.x > cw - EDGE_RIGHT || pt.y > ch - VIDEO_BOTTOM_MARGIN) {
        DebugTplL(Format(
            "abort: outside video rect client=({},{}) cw={} ch={} bottom_margin={} edges L/T/R={}/{}/{}",
            pt.x, pt.y, cw, ch, VIDEO_BOTTOM_MARGIN, EDGE_LEFT, EDGE_TOP, EDGE_RIGHT))
        return
    }

    DebugTplL(Format("OK: WinClose PotPlayer hwnd={} client=({},{})", hwndUnder, pt.x, pt.y))
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
