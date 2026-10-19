// plat_win.mc - Windows driver: window creation, the blocking event
// loop (MsgWaitForMultipleObjectsEx), and translation of native events
// into the app_* calls from plat.mc. Renders only on WM_PAINT.

// The editor is a windowed program, not a console one: a shell that
// starts it gets its prompt back, and a launch from Explorer or a
// shortcut opens no console behind the window. Output still reaches a
// pipe or a file, so --version, --smoke and the probes' logs read the
// same; what changes is that a console sees them after the prompt has
// returned, since the shell no longer waits. The tag rides on this
// module, so it reaches the editor and not the harnesses, which stub
// the platform and stay console programs.
@gui

import thread;

private const i32 WIN_DEFAULT_W = 1200;
private const i32 WIN_DEFAULT_H = 800;
private const i32 WHEEL_LINES = 3;

// The user's wheel settings (Mouse settings, "lines to scroll at a
// time"), which touchpads follow too: lines per notch, WHEEL_PAGE for
// a screen at a time, and columns per sideways notch.
private const u32 SPI_GETWHEELSCROLLLINES = 0x0068;
private const u32 SPI_GETWHEELSCROLLCHARS = 0x006C;
private const u32 WHEEL_PAGE = 0xFFFFFFFF;
private const u64 MK_SHIFT = 0x0004;
private u32 g_wheel_lines = 3;
private u32 g_wheel_chars = 3;

private void win_wheel_settings() {
    u32 v = 0;
    if SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &v, 0) != 0 { g_wheel_lines = v; }
    v = 0;
    if SystemParametersInfoW(SPI_GETWHEELSCROLLCHARS, 0, &v, 0) != 0 { g_wheel_chars = v; }
}

// A wheel message's delta in pixels, and whether it is a whole notch:
// a mouse wheel sends multiples of WHEEL_DELTA, a precision touchpad
// sends small deltas that are already smooth.
private void win_wheel(HWND hwnd, i32 delta, bool sideways, LPARAM lParam) {
    POINT pt;
    pt.x = win_lo16s(lParam);
    pt.y = win_hi16s(lParam);
    ignore ScreenToClient(hwnd, &pt);
    f32 dx = 0.0f;
    f32 dy = 0.0f;
    if sideways {
        dx = cast(f32, delta * cast(i32, g_wheel_chars) * font_cell_w) / cast(f32, WHEEL_DELTA);
    } else {
        i32 per = cast(i32, g_wheel_lines) * font_line_h;
        if g_wheel_lines == WHEEL_PAGE {
            RECT cr;
            ignore GetClientRect(hwnd, &cr);
            per = cr.bottom - cr.top - g_caption_h - 2 * font_line_h;
            if per < font_line_h { per = font_line_h; }
        }
        dy = cast(f32, -(delta * per)) / cast(f32, WHEEL_DELTA);
    }
    if delta % WHEEL_DELTA == 0 {
        app_scroll_notch(dx, dy, pt.x, pt.y - g_caption_h);
    } else {
        app_scroll(dx, dy, pt.x, pt.y - g_caption_h);
    }
}

private i32 g_dpi_override = 0;   // --dpi: what the window reports, overridden
private i64 g_char_t = 0;      // WM_CHAR arrival, for input latency
private i64 g_key_t = 0;       // the previous WM_KEYDOWN, for the repeat rate
// the last pointer position in client pixels, so a modifier-only change
// can re-report the hover where the pointer already is
private i32 g_last_mx = 0;
private i32 g_last_my = 0;
private i64 g_load_us = 0;
private u32 g_surrogate = 0;   // pending WM_CHAR high surrogate
private bool g_dragging = false;
private void* g_cur_arrow = null;
private void* g_cur_ibeam = null;
private void* g_cur_sizewe = null;
private void* g_cur_sizens = null;
private void* g_cur_hand = null;

// One native window per editor window; the driver record parks the
// per-window driver state (caption band and its hover/press, the drag
// flag) and swaps it into the g_* singletons at the wndproc boundary,
// the way the core swaps a WinCtx. The driver index equals the core
// window index (both stable slots), and each has its own gpu surface.
private struct WinRec {
    HWND hwnd;
    i32 gpu;
    i32 caption_h;
    i32 caption_hover;
    i32 caption_press;
    bool dragging;
    bool used;
}
private WinRec[WIN_MAX] g_winrec;

private i32 g_cur_win = 0;
private bool g_quitting = false;   // tearing every window down to quit

// A paint waits for its swapchain's latency object. The loop's
// WM_PAINT defers the frame while the object is unsignalled, and the
// loop waits on the object together with the queue, so input keeps
// arriving until the frame can go out. An unsignalled object means the
// compositor has not taken the previous frame, and a Present made then
// would block the UI thread for the same wait, so the loop does not
// force one: the deferred frame goes out when the object signals, and
// shows everything that arrived meanwhile. Only an object that stays
// unsignalled for FRAME_FORCE_US, a lost signal, gets a frame forced.
// A paint nested in another handler (a modal loop, the folder picker,
// a resize's synchronous paint) is outside this loop and renders at
// once, taking the signal if it is there.
private bool[WIN_MAX] g_paint_wait;     // a frame deferred until the object signals
private bool[WIN_MAX] g_frame_ready;    // the loop consumed the signal for the next paint
private i64[WIN_MAX] g_defer_t;         // when the deferred frame was first held
private const i64 FRAME_FORCE_US = 200000;
private i32 g_wndproc_depth = 0;        // nesting of ed_wndproc; 1 inside the loop's dispatch
private const u32 QS_ALLINPUT = 0x04FF;
private const u32 MWMO_INPUTAVAILABLE = 0x0004;
private const u32 PM_REMOVE = 1;
private const u32 WM_QUIT = 0x0012;
private const u32 WAIT_FOREVER = 0xFFFFFFFF;
private const u32 WAIT_TIMEOUT = 0x0102;

// Latency with --time: scripts/latency.ps1 posts WM_BENCH with its QPC
// count in lParam. Each presented frame records the oldest and newest
// input it carries, and the DXGI frame statistics give the refresh
// that showed it.
private const u64 BENCH_WHEEL = 0;
private const u64 BENCH_CHAR = 1;
private const i32 BENCH_Q = 64;
private i64 g_bench_old = 0;
private i64 g_bench_new = 0;
private u32[BENCH_Q] g_bq_pc;
private i64[BENCH_Q] g_bq_old;
private i64[BENCH_Q] g_bq_new;
private i64[BENCH_Q] g_bq_pres;
private i32 g_bq_n = 0;
private i64 g_bench_freq = 0;

private i64 bench_us(i64 ticks) {
    if g_bench_freq == 0 { ignore QueryPerformanceFrequency(&g_bench_freq); }
    return ticks * 1000000 / g_bench_freq;
}

// the frame just presented on window 0 carries the pending input
private void bench_presented() {
    if g_bench_old == 0 || g_cur_win != 0 { return; }
    if g_bq_n == BENCH_Q {
        for i32 i = 1; i < BENCH_Q; i++ {
            g_bq_pc[i - 1] = g_bq_pc[i];
            g_bq_old[i - 1] = g_bq_old[i];
            g_bq_new[i - 1] = g_bq_new[i];
            g_bq_pres[i - 1] = g_bq_pres[i];
        }
        g_bq_n--;
    }
    i64 now = 0;
    ignore QueryPerformanceCounter(&now);
    g_bq_pc[g_bq_n] = gpu_last_present(g_winrec[0].gpu);
    g_bq_old[g_bq_n] = g_bench_old;
    g_bq_new[g_bq_n] = g_bench_new;
    g_bq_pres[g_bq_n] = now;
    g_bq_n++;
    g_bench_old = 0;
    g_bench_new = 0;
}

// The statistics name only the latest present on screen, so a thread
// reads them every millisecond and records when each present count
// appeared.
private const i32 BENCH_RING = 1024;
private const u32 BENCH_POLL_MS = 1;
private u32[BENCH_RING] g_shown_pc;
private i64[BENCH_RING] g_shown_qpc;
private u32 g_shown_last = 0;       // the latest present count recorded
private Thread g_bench_thr;
private bool g_bench_thr_on = false;

private extern "winmm.dll" {
    u32 timeBeginPeriod(u32 ms);
}

private void bench_watch(void* arg) {
    ignore timeBeginPeriod(BENCH_POLL_MS);
    i64 period = 0;
    u32 last_sync = 0;
    i64 last_q = 0;
    while true {
        u32 pc = 0;
        u32 shown = 0;
        u32 sync = 0;
        i64 q = 0;
        if gpu_frame_stats(g_winrec[0].gpu, &pc, &shown, &sync, &q) && q > 0 {
            if last_sync != 0 && sync != last_sync {
                period = (q - last_q) / cast(i64, sync - last_sync);
            }
            last_sync = sync;
            last_q = q;
            if pc != g_shown_last {
                i32 slot = cast(i32, pc % cast(u32, BENCH_RING));
                // the present appeared at refresh `shown`; q is the time
                // of refresh `sync`
                g_shown_qpc[slot] = q + cast(i64, cast(i32, shown - sync)) * period;
                g_shown_pc[slot] = pc;
                g_shown_last = pc;
            }
        }
        win_sleep_ms(BENCH_POLL_MS);
    }
}

// print the recorded frames that are on screen by now; a present the
// thread did not see between two polls has no time
private void bench_poll() {
    if g_bq_n == 0 { return; }
    u32 last = g_shown_last;
    i32 k = 0;
    while k < g_bq_n && g_bq_pc[k] <= last {
        i32 slot = cast(i32, g_bq_pc[k] % cast(u32, BENCH_RING));
        if g_shown_pc[slot] == g_bq_pc[k] {
            i64 q = g_shown_qpc[slot];
            print("bench_frame old_us {} new_us {} pres_us {}\n",
                bench_us(q - g_bq_old[k]), bench_us(q - g_bq_new[k]), bench_us(g_bq_pres[k] - g_bq_old[k]));
        } else {
            print("bench_miss\n");
        }
        k++;
    }
    if k == 0 { return; }
    for i32 i = k; i < g_bq_n; i++ {
        g_bq_pc[i - k] = g_bq_pc[i];
        g_bq_old[i - k] = g_bq_old[i];
        g_bq_new[i - k] = g_bq_new[i];
        g_bq_pres[i - k] = g_bq_pres[i];
    }
    g_bq_n -= k;
}

// the longest a nested paint waits for the swapchain: two refreshes at
// 60 Hz
private const u32 FRAME_WAIT_NESTED_MS = 34;

// whether window i may render now; false defers the frame to the loop
private bool win_frame_ok(i32 i) {
    void* h = gpu_wait_handle(g_winrec[i].gpu);
    if h == null { return true; }
    if g_frame_ready[i] {
        g_frame_ready[i] = false;
        return true;
    }
    if g_wndproc_depth > 1 {
        // A modal loop does not return to the loop that defers frames,
        // so the frame waits here for the compositor, up to a bound.
        // Rendering past an unsignalled object queues frames that the
        // compositor then shows one per refresh, behind the drag.
        bool got = win_wait_object(h, FRAME_WAIT_NESTED_MS) == 0;
        if g_time && !got { print("frame_nested_unsignalled\n"); }
        g_paint_wait[i] = false;
        return true;
    }
    if win_wait_object(h, 0) == 0 {
        g_paint_wait[i] = false;
        return true;
    }
    if !g_paint_wait[i] { g_defer_t[i] = plat_time_us(); }
    g_paint_wait[i] = true;
    return false;
}

// the message loop: waits on the queue and on the latency objects of
// the windows with a deferred frame
private void win_loop() {
    MSG msg;
    while true {
        void*[WIN_MAX + 1] hs;
        i32[WIN_MAX] hw;
        u32 n = 0;
        for i32 i = 0; i < WIN_MAX; i++ {
            if !g_winrec[i].used || !g_paint_wait[i] { continue; }
            void* h = gpu_wait_handle(g_winrec[i].gpu);
            if h == null { continue; }
            hs[n] = h;
            hw[n] = i;
            n++;
        }
        // no timeout at all without a deferred frame, so idle makes no
        // wakeups; with one, the time left until it is forced
        u32 ms = WAIT_FOREVER;
        i64 now = plat_time_us();
        for u32 j = 0; j < n; j++ {
            i64 left = (FRAME_FORCE_US - (now - g_defer_t[hw[j]])) / 1000;
            if left < 1 { left = 1; }
            if cast(u32, left) < ms { ms = cast(u32, left); }
        }
        // the workers' wake goes last, so a frame handle keeps its index
        u32 nw = n;
        void* wev = win_wake_event();
        if wev != null {
            hs[n] = wev;
            nw = n + 1;
        }
        u32 r = MsgWaitForMultipleObjectsEx(nw, &hs[0], ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        // The wait took the event when it returned for it. Otherwise the
        // take tests it. The drain below handles the one WM_WAKE and then
        // reaches the input and WM_PAINT, because no worker posts while
        // it runs.
        if wev != null && r == n {
            ignore PostMessageW(g_hwnd, WM_WAKE, 0, 0);
        } else {
            win_wake_take();
        }
        now = plat_time_us();
        for u32 j = 0; j < n; j++ {
            i32 w = hw[j];
            if r != j {
                if now - g_defer_t[w] < FRAME_FORCE_US { continue; }
                if g_time { print("frame_wait_timeout\n"); }
            }
            g_paint_wait[w] = false;
            g_frame_ready[w] = true;
            ignore InvalidateRect(g_winrec[w].hwnd, null, 0);
        }
        while PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0 {
            if msg.message == WM_QUIT { return; }
            ignore TranslateMessage(&msg);
            ignore DispatchMessageW(&msg);
            if g_time { bench_poll(); }
        }
    }
}

private i32 win_find(HWND hwnd) {
    for i32 i = 0; i < WIN_MAX; i++ {
        if g_winrec[i].used && g_winrec[i].hwnd == hwnd { return i; }
    }
    return -1;
}

// point the g_* singletons, the core and the gpu at window i
private void win_activate_idx(i32 i) {
    if i < 0 || i >= WIN_MAX || !g_winrec[i].used || i == g_cur_win { return; }
    WinRec* o = &g_winrec[g_cur_win];
    o.caption_h = g_caption_h;
    o.caption_hover = g_caption_hover;
    o.caption_press = g_caption_press;
    o.dragging = g_dragging;
    WinRec* c = &g_winrec[i];
    g_hwnd = c.hwnd;
    g_caption_h = c.caption_h;
    g_caption_hover = c.caption_hover;
    g_caption_press = c.caption_press;
    g_dragging = c.dragging;
    g_cur_win = i;
    app_use_window(i);
    gpu_bind(c.gpu);
}

// every live window repaints, so an edit in one shows in the others
void plat_damage() {
    for i32 i = 0; i < WIN_MAX; i++ {
        if g_winrec[i].used { ignore InvalidateRect(g_winrec[i].hwnd, null, 0); }
    }
}

void plat_damage_window(i32 win) {
    if win < 0 || win >= WIN_MAX || !g_winrec[win].used { return; }
    ignore InvalidateRect(g_winrec[win].hwnd, null, 0);
}

// close every window and quit. The dirty gate (app_close) has already
// saved the session with every window present; disable further saves so
// the focus-loss each DestroyWindow raises cannot overwrite it with a
// partial window set.
private void win_quit_all() {
    g_quitting = true;
    session_set_enabled(false);
    for i32 i = 0; i < WIN_MAX; i++ {
        if g_winrec[i].used { ignore DestroyWindow(g_winrec[i].hwnd); }
    }
    PostQuitMessage(0);
}

// create a native window at a window rect (CW_USEDEFAULT for x to let
// Windows place it) with an editor window behind it; returns the index
private i32 win_native_create(i32 x, i32 y, i32 w, i32 h, i32 maxi) {
    i32 wi = ed_window_new(ed_buf_active());
    if wi < 0 { return -1; }
    HWND hwnd = CreateWindowExW(0, win_wide("edmincWindow"), win_wide("edminc"),
        WS_OVERLAPPEDWINDOW, x, y, w, h, null, null, GetModuleHandleA(null), null);
    if hwnd == null {
        ignore ed_window_close();
        return -1;
    }
    i32 dark = 1;
    ignore DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, 4);
    i32 dpi = cast(i32, GetDpiForWindow(hwnd));
    if dpi == 0 { dpi = DPI_BASE; }
    if g_dpi_override > 0 { dpi = g_dpi_override; }
    i32 caph = caption_default_h(dpi);
    RECT cr;
    ignore GetClientRect(hwnd, &cr);
    i32 gpu = gpu_win_create(hwnd, cr.right - cr.left, cr.bottom - cr.top);
    if gpu < 0 {
        ignore DestroyWindow(hwnd);
        ignore ed_window_close();
        return -1;
    }
    g_winrec[wi].hwnd = hwnd;
    g_winrec[wi].gpu = gpu;
    g_winrec[wi].caption_h = caph;
    g_winrec[wi].caption_hover = -1;
    g_winrec[wi].caption_press = -1;
    g_winrec[wi].dragging = false;
    g_winrec[wi].used = true;
    // ed_window_new already made the core's current window wi; point the
    // driver singletons and the gpu at it, reclaim the caption, size it
    g_cur_win = wi;
    g_hwnd = hwnd;
    g_caption_h = caph;
    g_caption_hover = -1;
    g_caption_press = -1;
    g_dragging = false;
    gpu_bind(gpu);
    // the new window may be on a display of another scale than the opener,
    // whose dpi the core is still on; move it to this window's dpi so the
    // font and metrics match the monitor (the mac driver does the same).
    // WM_DPICHANGED only fires on a later move, not at creation. app_scale
    // no-ops when the dpi already matches.
    app_scale(dpi);
    ed_retitle();
    ignore SetWindowPos(hwnd, null, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    ignore GetClientRect(hwnd, &cr);
    app_resize(cr.right - cr.left, cr.bottom - cr.top - caph);
    if maxi != 0 { ignore ShowWindow(hwnd, SW_MAXIMIZE); }
    else { ignore ShowWindow(hwnd, SW_SHOW); }
    return wi;
}

// the Ctrl+K N command: a new window at the default place/size, showing
// the active file. The source window is left as it is.
i32 plat_window_open() {
    RECT r;
    r.right = WIN_DEFAULT_W;
    r.bottom = WIN_DEFAULT_H;
    ignore AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, 0);
    i32 wi = win_native_create(cast(i32, CW_USEDEFAULT), cast(i32, CW_USEDEFAULT),
        r.right - r.left, r.bottom - r.top, 0);
    if wi < 0 { return -1; }
    plat_damage();
    return wi;
}

// restore: a window at a saved rect, no pane move (its panes come from
// the session)
i32 plat_window_open_at(i32 x, i32 y, i32 w, i32 h, i32 maxi) {
    i32 wi = win_native_create(x, y, w, h, maxi);
    plat_damage();
    return wi;
}

// the native rect of window `win` (its position and size on screen),
// for the session; false when the index is not a live window
bool plat_window_rect(i32 win, i32* x, i32* y, i32* w, i32* h, i32* maxi) {
    if win < 0 || win >= WIN_MAX || !g_winrec[win].used { return false; }
    HWND hwnd = g_winrec[win].hwnd;
    RECT r;
    ignore GetWindowRect(hwnd, &r);
    *maxi = 0;
    if IsZoomed(hwnd) != 0 { *maxi = 1; }
    if IsIconic(hwnd) != 0 {
        // a minimized window's rect is a stub far off screen; the
        // placement holds the rect it restores to, in work-area
        // coordinates, which match the screen's unless the taskbar is
        // at the top or the left
        WINDOWPLACEMENT wp;
        wp.length = cast(u32, sizeof(WINDOWPLACEMENT));
        if GetWindowPlacement(hwnd, &wp) != 0 {
            r = wp.rcNormalPosition;
            if (wp.flags & WPF_RESTORETOMAXIMIZED) != 0 { *maxi = 1; }
        }
    }
    *x = r.left;
    *y = r.top;
    *w = r.right - r.left;
    *h = r.bottom - r.top;
    return true;
}

// move/size window `win` to a saved rect (restore of the primary)
void plat_window_set_rect(i32 win, i32 x, i32 y, i32 w, i32 h, i32 maxi) {
    if win < 0 || win >= WIN_MAX || !g_winrec[win].used { return; }
    HWND hwnd = g_winrec[win].hwnd;
    if maxi != 0 {
        ignore ShowWindow(hwnd, SW_MAXIMIZE);
        return;
    }
    ignore SetWindowPos(hwnd, null, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

// The key left of 1 is the backtick chord's key, by its scan code: its
// virtual key depends on the layout (the backtick's VK_OEM_3 on a US
// board, VK_OEM_5 for the section sign on a Nordic one, where VK_OEM_3
// is a letter). VS Code binds the same physical key.
private const i32 SCAN_GRAVE = 0x29;
private const i32 SCAN_Z = 0x2C;   // Alt+Z, the word wrap toggle

private i32 win_scan(LPARAM lParam) {
    return cast(i32, (lParam >> 16) & 0xFF);
}

// the key of a key-down message: the backtick key by position, the
// rest by virtual key
private i32 win_key_of(WPARAM wParam, LPARAM lParam) {
    if win_scan(lParam) == SCAN_GRAVE { return 96; }
    return win_key_translate(cast(i32, wParam));
}

private i32 win_key_translate(i32 vk) {
    if vk == VK_LEFT { return K_LEFT; }
    if vk == VK_RIGHT { return K_RIGHT; }
    if vk == VK_UP { return K_UP; }
    if vk == VK_DOWN { return K_DOWN; }
    if vk == VK_PRIOR { return K_PGUP; }
    if vk == VK_NEXT { return K_PGDN; }
    if vk == VK_HOME { return K_HOME; }
    if vk == VK_END { return K_END; }
    if vk == VK_DELETE { return K_DELETE; }
    if vk == VK_ESCAPE { return K_ESCAPE; }
    if vk == VK_TAB { return K_TAB; }
    if vk == VK_OEM_2 { return '/'; }
    if vk == VK_OEM_5 { return 92; }
    if vk == VK_OEM_PERIOD { return '.'; }
    // zoom: the = key (+ shifted), the minus key, and the keypad's
    if vk == 0xBB || vk == 0x6B { return '='; }   // VK_OEM_PLUS, VK_ADD
    if vk == 0xBD || vk == 0x6D { return '-'; }   // VK_OEM_MINUS, VK_SUBTRACT
    if vk == 0x7B { return K_F12; }   // VK_F12
    if vk == 0x76 { return K_F7; }    // VK_F7
    if vk == 0x77 { return K_F8; }    // VK_F8
    if vk == 0x74 { return K_F5; }    // VK_F5
    if vk == 0x70 { return K_F1; }    // VK_F1
    if vk == 0x71 { return K_F2; }    // VK_F2
    if vk == 0x72 { return K_F3; }    // VK_F3
    if vk == 0x73 { return K_F4; }    // VK_F4
    if vk == 0x75 { return K_F6; }    // VK_F6
    if vk == 0x78 { return K_F9; }    // VK_F9
    if vk == 0x79 { return K_F10; }   // VK_F10
    if vk == 0x7A { return K_F11; }   // VK_F11
    if vk == 0x5D { return K_MENU; }  // VK_APPS
    if vk >= '0' && vk <= '9' { return vk; }
    if vk >= 'A' && vk <= 'Z' { return vk; }
    return 0;
}

// the window button under (mx, my): 0 minimize, 1 maximize, 2 close,
// -1 anywhere else
private i32 win_caption_zone(i32 mx, i32 my) {
    if g_caption_h <= 0 || my < 0 || my >= g_caption_h { return -1; }
    i32 bw = caption_btn_w();
    if mx < g_w - 3 * bw || mx >= g_w { return -1; }
    return (mx - (g_w - 3 * bw)) / bw;
}

private void win_caption_act(HWND hwnd, i32 zone) {
    if zone == 0 { ignore PostMessageW(hwnd, WM_SYSCOMMAND, SC_MINIMIZE, 0); }
    if zone == 1 {
        u64 cmd = SC_MAXIMIZE;
        if IsZoomed(hwnd) != 0 { cmd = SC_RESTORE; }
        ignore PostMessageW(hwnd, WM_SYSCOMMAND, cmd, 0);
    }
    if zone == 2 { ignore PostMessageW(hwnd, WM_CLOSE, 0, 0); }
}

private void win_track_leave(HWND hwnd) {
    TRACKMOUSEEVENT t;
    t.cbSize = cast(u32, sizeof(TRACKMOUSEEVENT));
    t.dwFlags = TME_LEAVE;
    t.hwndTrack = hwnd;
    ignore TrackMouseEvent(&t);
}

// an Alt chord the editor took since Alt went down; see WM_SYSKEYUP
private bool g_alt_chord = false;

private i32 win_mods() {
    i32 m = 0;
    if win_key_down(VK_CONTROL) { m = m | MOD_CTRL; }
    if win_key_down(VK_SHIFT) { m = m | MOD_SHIFT; }
    if win_key_down(VK_MENU) { m = m | MOD_ALT; }
    return m;
}

// A modifier key went up or down on its own. The other three drivers
// report this already (flagsChanged: on macOS, the modifier keysyms on
// X11, keyup on the page); here nothing did, and app_hover only ran on
// pointer motion, so a chord held down had no way to say it was let go.
// GetKeyState is current as of the message being handled, so win_mods()
// reads the state after this key.
private void win_mod_change(i32 vk) {
    if vk != VK_CONTROL && vk != VK_SHIFT && vk != VK_MENU { return; }
    app_hover(g_last_mx, g_last_my - g_caption_h, win_mods());
}

// --time: a message that holds the UI thread this long is logged, with
// the timer or the wake step that took the time
private const i64 SLOW_MSG_US = 12000;

private LRESULT ed_wndproc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    i64 t0 = 0;
    if g_time { t0 = plat_time_us(); }
    LRESULT r = ed_wndproc_depth(hwnd, msg, wParam, lParam);
    if g_time && g_wndproc_depth == 0 {
        i64 dt = plat_time_us() - t0;
        if dt > SLOW_MSG_US {
            u64 timer = 0;
            if msg == WM_TIMER { timer = wParam; }
            print("slow_msg msg {} timer {} ms {}", msg, timer, dt / 1000);
            if msg == WM_WAKE { print(" step {} ms {}", g_wake_slow_step, g_wake_slow_us / 1000); }
            print("\n");
        }
    }
    return r;
}

private LRESULT ed_wndproc_depth(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    g_wndproc_depth++;
    // a modal loop dispatches outside win_loop, which then cannot
    // render a deferred frame; the modal loop's own WM_PAINT does. Nor
    // does win_loop see the workers' wake there, so it is taken here.
    if g_wndproc_depth > 1 {
        for i32 i = 0; i < WIN_MAX; i++ {
            if g_winrec[i].used && g_paint_wait[i] { ignore InvalidateRect(g_winrec[i].hwnd, null, 0); }
        }
        win_wake_take();
    }
    LRESULT r = ed_wndproc_msg(hwnd, msg, wParam, lParam);
    g_wndproc_depth--;
    return r;
}

private LRESULT ed_wndproc_msg(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    i32 g_wi = win_find(hwnd);
    if g_wi < 0 {
        // messages that arrive during CreateWindowExW, before the window
        // is registered: let the default handler deal with them
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
    win_activate_idx(g_wi);
    switch msg {
        case WM_PAINT: {
            PAINTSTRUCT ps;
            i64 t_paint = 0;
            if g_time { t_paint = plat_time_us(); }
            ignore BeginPaint(hwnd, &ps);
            if !win_frame_ok(g_wi) {
                ignore EndPaint(hwnd, &ps);
                return 0;
            }
            i64 t0 = 0;
            if g_smoke || g_time { t0 = plat_time_us(); }
            if g_time && t0 - t_paint > 5000 { print("paint_pre_us {}\n", t0 - t_paint); }
            g_tp_paint_n++;
            app_render();
            i64 t_end = 0;
            if g_time { t_end = plat_time_us(); }
            ignore EndPaint(hwnd, &ps);
            if g_time && plat_time_us() - t_end > 5000 { print("paint_endpaint_us {}\n", plat_time_us() - t_end); }
            if g_smoke {
                g_smoke = false;
                i64 fr = plat_time_us() - t0;
                print("smoke: rendered {} verts, {} lines, load {} us, frame {} us\n",
                    draw_nverts, tb.nlines, g_load_us, fr);
                PostQuitMessage(0);
            }
            if g_time {
                bench_presented();
                bench_poll();
                i64 now = plat_time_us();
                if g_char_t != 0 {
                    print("char_to_present_us {}\n", now - g_char_t);
                    g_char_t = 0;
                }
                print("paint_us {} dur {} glide {}\n", now, now - t0, ed_glide_frame_offset());
                if plat_time_us() - now > 5000 { print("paint_print_us {}\n", plat_time_us() - now); }
            }
            return 0;
        }
        case WM_ERASEBKGND: {
            return 1;
        }
        case WM_SIZE: {
            i32 w = cast(i32, lParam & 0xFFFF);
            i32 h = cast(i32, (lParam >> 16) & 0xFFFF);
            g_win_zoomed = wParam == SIZE_MAXIMIZED;
            gpu_resize(w, h);
            i32 ah = h - g_caption_h;
            if ah < 0 { ah = 0; }
            app_resize(w, ah);
            // paint the reflowed frame synchronously; without it a live
            // resize shows the previous frame stretched by the compositor
            if w > 0 && h > 0 {
                ignore InvalidateRect(hwnd, null, 0);
                ignore UpdateWindow(hwnd);
            }
            return 0;
        }
        case WM_NCCALCSIZE: {
            // reclaim the caption band into the client area; the
            // resize borders stay native. Maximized windows are
            // inset by the frame so content is not clipped.
            if wParam != 0 && g_caption_h > 0 {
                RECT* rc = cast(RECT*, lParam);   // rgrc[0]
                i32 top = rc.top;
                ignore DefWindowProcW(hwnd, msg, wParam, lParam);
                rc.top = top;
                if IsZoomed(hwnd) != 0 {
                    rc.top += GetSystemMetrics(SM_CYSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
                }
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        }
        case WM_NCHITTEST: {
            i64 hit = DefWindowProcW(hwnd, msg, wParam, lParam);
            if g_caption_h == 0 || hit != HTCLIENT { return hit; }
            POINT pt;
            pt.x = win_lo16s(lParam);
            pt.y = win_hi16s(lParam);
            ignore ScreenToClient(hwnd, &pt);
            if IsZoomed(hwnd) == 0
                && pt.y < GetSystemMetrics(SM_CYSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER) {
                return HTTOP;
            }
            if pt.y < g_caption_h {
                // the window buttons stay client so clicks reach us
                if pt.x >= g_w - 3 * caption_btn_w() { return HTCLIENT; }
                return HTCAPTION;
            }
            return HTCLIENT;
        }
        case WM_CHAR: {
            if g_time { g_char_t = plat_time_us(); }
            u32 ch = cast(u32, wParam);
            // Ctrl+Space is the completion chord (delivered via WM_KEYDOWN);
            // its WM_CHAR is a plain space that must not be inserted. A
            // Ctrl+letter arrives as a control code below 32 and app_char
            // already drops it; AltGr (Ctrl+Alt) can type a real space, so
            // it is left alone.
            if ch == 0x20 && (win_mods() & (MOD_CTRL | MOD_ALT)) == MOD_CTRL {
                return 0;
            }
            if ch >= SURR_HI && ch < SURR_LO {
                g_surrogate = ch;
                return 0;
            }
            if ch >= SURR_LO && ch <= SURR_END {
                if g_surrogate != 0 {
                    u32 cp = SURR_BASE + ((g_surrogate - SURR_HI) << 10) + (ch - SURR_LO);
                    g_surrogate = 0;
                    app_char(cp);
                }
                return 0;
            }
            g_surrogate = 0;
            app_char(ch);
            return 0;
        }
        case WM_KEYDOWN: {
            if g_time {
                // the gap between key messages: a held key's repeat rate
                i64 kt = plat_time_us();
                print("key_us {} gap_us {} repeat {}\n", kt, kt - g_key_t, (lParam >> 30) & 1);
                g_key_t = kt;
                if g_char_t == 0 { g_char_t = kt; }
            }
            i32 key = win_key_of(wParam, lParam);
            // Ctrl+Space triggers completion; space is not otherwise a
            // chord key, so it is not in the translate table.
            if key == 0 && cast(i32, wParam) == 0x20
                && (win_mods() & (MOD_CTRL | MOD_ALT)) == MOD_CTRL {
                key = ' ';
            }
            if key != 0 { app_key(key, win_mods()); }
            if g_time && plat_time_us() - g_key_t > 5000 { print("key_app_us {}\n", plat_time_us() - g_key_t); }
            return 0;
        }
        case WM_KEYUP: {
            win_mod_change(cast(i32, wParam));
            return 0;
        }
        case WM_SYSKEYUP: {
            // Alt goes up as a system key; the release still has to be
            // reported. After an Alt chord the editor took, the release
            // stays here: DefWindowProc never saw the chord's key, reads
            // the release as Alt pressed alone, and opens the window
            // menu, which then takes the next keys.
            win_mod_change(cast(i32, wParam));
            if cast(i32, wParam) == VK_MENU && g_alt_chord {
                g_alt_chord = false;
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        }
        case WM_IME_STARTCOMPOSITION: {
            // anchor the composition UI at the caret; DefWindowProc
            // still runs so the default composition window exists
            void* himc = ImmGetContext(hwnd);
            if himc != null {
                i32 cx = 0;
                i32 cy = 0;
                ed_caret_px(&cx, &cy);
                COMPOSITIONFORM cf;
                cf.style = CFS_POINT;
                cf.pt.x = cx;
                cf.pt.y = cy + g_caption_h;
                ignore ImmSetCompositionWindow(himc, &cf);
                ignore ImmReleaseContext(hwnd, himc);
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        }
        case WM_SYSKEYDOWN: {
            // Alt+arrows: line ops up and down, the navigation history
            // left and right. Everything else (Alt+F4, Alt+Space) stays
            // with DefWindowProc. F10 is the menu key, so it arrives
            // here with no Alt held.
            // Alt+` is the switcher's chord (Cmd+` on a Mac keyboard,
            // where Cmd sits where Alt does). Alt+Z toggles word wrap.
            i32 key = win_key_of(wParam, lParam);
            if key == K_UP || key == K_DOWN || key == K_LEFT || key == K_RIGHT || key == K_F10
                || key == 96 || key == 'Z' {
                if key != K_F10 { g_alt_chord = true; }
                app_key(key, win_mods());
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        }
        case WM_SYSCHAR: {
            // the character of an Alt chord the editor took: DefWindowProc
            // would look it up as a menu mnemonic and beep
            if win_scan(lParam) == SCAN_GRAVE || win_scan(lParam) == SCAN_Z { return 0; }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        }
        case WM_MOUSEWHEEL: {
            // with Shift the wheel scrolls sideways, up to the left
            i32 delta = win_hi16s(cast(i64, wParam));
            if (wParam & MK_SHIFT) != 0 {
                win_wheel(hwnd, -delta, true, lParam);
            } else {
                win_wheel(hwnd, delta, false, lParam);
            }
            return 0;
        }
        case WM_MOUSEHWHEEL: {
            // a tilt or a sideways swipe; a positive delta is to the right
            win_wheel(hwnd, win_hi16s(cast(i64, wParam)), true, lParam);
            return 0;
        }
        case WM_SETTINGCHANGE: {
            win_wheel_settings();
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        }
        case WM_LBUTTONDOWN: {
            i32 mx = win_lo16s(lParam);
            i32 my = win_hi16s(lParam);
            if g_caption_h > 0 && my < g_caption_h {
                // only the window-button zone is client in the
                // caption; the rest is HTCAPTION and never arrives. A
                // button acts on release over itself, not on press:
                // the press arms it and shows the held look.
                i32 zone = win_caption_zone(mx, my);
                if zone >= 0 {
                    g_caption_press = zone;
                    g_caption_hover = zone;
                    ignore SetCapture(hwnd);
                    plat_damage();
                }
                return 0;
            }
            ignore SetCapture(hwnd);
            g_dragging = true;
            app_mouse(mx, my - g_caption_h, 0, true, win_mods());
            return 0;
        }
        // the right button, which the terminal pane takes for copy and
        // paste. No capture and no drag: it acts on the press, and the
        // caption band is not its business.
        case WM_RBUTTONDOWN: {
            i32 mx = win_lo16s(lParam);
            i32 my = win_hi16s(lParam);
            if g_caption_h > 0 && my < g_caption_h { return 0; }
            app_mouse(mx, my - g_caption_h, 1, true, win_mods());
            return 0;
        }
        case WM_RBUTTONUP: {
            i32 mx = win_lo16s(lParam);
            i32 my = win_hi16s(lParam);
            if g_caption_h > 0 && my < g_caption_h { return 0; }
            app_mouse(mx, my - g_caption_h, 1, false, win_mods());
            return 0;
        }
        case WM_MOUSEMOVE: {
            i32 mx = win_lo16s(lParam);
            i32 my = win_hi16s(lParam);
            g_last_mx = mx;
            g_last_my = my;
            i32 zone = win_caption_zone(mx, my);
            if g_caption_press >= 0 {
                // held: the pressed look follows the pointer on and off
                // the button, and a release elsewhere cancels
                i32 want = -1;
                if zone == g_caption_press { want = zone; }
                if want != g_caption_hover {
                    g_caption_hover = want;
                    plat_damage();
                }
                return 0;
            }
            if zone != g_caption_hover {
                g_caption_hover = zone;
                plat_damage();
                if zone >= 0 { win_track_leave(hwnd); }
            }
            if g_dragging {
                app_mouse_move(mx, my - g_caption_h);
            } else {
                app_hover(mx, my - g_caption_h, win_mods());
            }
            return 0;
        }
        case WM_MOUSELEAVE: {
            if g_caption_hover >= 0 && g_caption_press < 0 {
                g_caption_hover = -1;
                plat_damage();
            }
            return 0;
        }
        case WM_LBUTTONUP: {
            i32 mx = win_lo16s(lParam);
            i32 my = win_hi16s(lParam);
            if g_caption_press >= 0 {
                i32 z = g_caption_press;
                g_caption_press = -1;
                g_caption_hover = -1;
                ignore ReleaseCapture();
                plat_damage();
                if win_caption_zone(mx, my) == z { win_caption_act(hwnd, z); }
                return 0;
            }
            if g_dragging {
                g_dragging = false;
                ignore ReleaseCapture();
            }
            app_mouse(mx, my - g_caption_h, 0, false, win_mods());
            return 0;
        }
        case WM_SETCURSOR: {
            // I-beam over text, arrow over chrome (app_cursor_kind);
            // the caption band is chrome
            if (cast(i64, lParam) & 0xFFFF) == HTCLIENT {
                POINT pt;
                ignore GetCursorPos(&pt);
                ignore ScreenToClient(hwnd, &pt);
                void* cur = g_cur_arrow;
                if pt.y >= g_caption_h {
                    i32 k = app_cursor_kind(pt.x, pt.y - g_caption_h);
                    if k == CURSOR_IBEAM { cur = g_cur_ibeam; }
                    if k == CURSOR_RESIZE_H { cur = g_cur_sizewe; }
                    if k == CURSOR_RESIZE_V { cur = g_cur_sizens; }
                    if k == CURSOR_HAND { cur = g_cur_hand; }
                }
                ignore SetCursor(cur);
                return 1;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        }
        case WM_SETFOCUS: {
            app_focus(true);
            return 0;
        }
        case WM_KILLFOCUS: {
            app_focus(false);
            return 0;
        }
        case WM_WAKE: {
            app_wake();
            if g_term_probe { term_probe_wake(); }
            return 0;
        }
        case WM_BENCH: {
            // the statistics thread polls every millisecond, so it
            // starts with the first timed input and not with --time
            if !g_bench_thr_on {
                g_bench_thr_on = true;
                thread_create(&g_bench_thr, bench_watch, null);
            }
            if lParam > 0 {
                if g_bench_old == 0 { g_bench_old = lParam; }
                g_bench_new = lParam;
            }
            RECT br;
            ignore GetClientRect(hwnd, &br);
            i32 cx = (br.right - br.left) / 2;
            i32 cy = (br.bottom - br.top) / 2;
            if wParam == BENCH_WHEEL {
                app_scroll(0.0f, cast(f32, WHEEL_LINES * font_line_h), cx, cy - g_caption_h);
            } else if wParam == BENCH_CHAR {
                app_char('a');
            }
            bench_poll();
            return 0;
        }
        case WM_PICK_FOLDER: {
            win_pick_folder_run();
            return 0;
        }
        case WM_PICK_SAVE: {
            win_pick_save_run();
            return 0;
        }
        case WM_RECENT_REMOVED: {
            win_jl_deliver_gone();
            return 0;
        }
        case WM_TIMER: {
            i32 tid = cast(i32, wParam);
            if g_term_probe && tid == TERM_PROBE_TIMER {
                term_probe_tick();
                return 0;
            }
            if !play_timer(tid) { app_timer(tid); }
            return 0;
        }
        case WM_DPICHANGED: {
            RECT* sr = cast(RECT*, lParam);
            i32 ndpi = cast(i32, wParam & 0xFFFF);
            app_scale(ndpi);
            g_caption_h = caption_default_h(ndpi);   // dpi derived
            ignore SetWindowPos(hwnd, null, sr.left, sr.top, sr.right - sr.left, sr.bottom - sr.top, SWP_NOZORDER | SWP_NOACTIVATE);
            return 0;
        }
        case WM_CLOSE: {
            // closing the main window (index 0, the one the app opened
            // with) or the last window quits the whole app, with the
            // dirty gate over every buffer; closing a secondary window
            // just drops that view, the buffers stay open. Alt+F4 arrives
            // here too, so it quits from the main window the same way.
            if ed_window_active() == 0 || ed_window_count() <= 1 {
                if !app_close() { return 0; }
                win_quit_all();
                return 0;
            }
            ignore DestroyWindow(hwnd);
            return 0;
        }
        case WM_DESTROY: {
            i32 gpu = g_winrec[g_wi].gpu;
            if g_quitting {
                // win_quit_all is tearing every window down; leave the
                // core state alone and let it post the quit
                gpu_win_destroy(gpu);
                g_winrec[g_wi].used = false;
                return 0;
            }
            bool last = ed_window_count() <= 1;
            if !last { ignore ed_window_close(); }   // core drops g_wi, moves on
            gpu_win_destroy(gpu);
            g_winrec[g_wi].used = false;
            if last {
                PostQuitMessage(0);
            } else {
                i32 nc = ed_window_active();
                g_cur_win = nc;
                g_hwnd = g_winrec[nc].hwnd;
                g_caption_h = g_winrec[nc].caption_h;
                g_caption_hover = g_winrec[nc].caption_hover;
                g_caption_press = g_winrec[nc].caption_press;
                g_dragging = g_winrec[nc].dragging;
                gpu_bind(g_winrec[nc].gpu);
            }
            return 0;
        }
        default: {
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        }
    }
    return 0;
}

// Class icon from the embedded app logo (lib/icon_edmc.mc): the blue
// "ed"/"mc" box, straight RGBA box-downsampled to the icon and
// premultiplied. Full-bleed, as the favicon is.
private void* win_make_icon(i32 size) {
    u8* px = alloc<u8>(size * size * 4);
    memset(px, 0, size * size * 4);
    // the box fills the icon (full-bleed, as the favicon is); the nearest
    // native render box-downsampled, then premultiplied into BGRA
    i32 sz = 0;
    u8* src = icon_edmc_rgba(size, &sz);
    if src == null { return null; }
    for i32 y = 0; y < size; y++ {
        i32 sy0 = y * sz / size;
        i32 sy1 = (y + 1) * sz / size;
        for i32 x = 0; x < size; x++ {
            i32 sx0 = x * sz / size;
            i32 sx1 = (x + 1) * sz / size;
            i32 ar = 0;
            i32 ag = 0;
            i32 ab = 0;
            i32 aa = 0;
            i32 cnt = 0;
            for i32 sy = sy0; sy < sy1; sy++ {
                for i32 sx = sx0; sx < sx1; sx++ {
                    i32 o = (sy * sz + sx) * 4;
                    ar += cast(i32, src[o]);
                    ag += cast(i32, src[o + 1]);
                    ab += cast(i32, src[o + 2]);
                    aa += cast(i32, src[o + 3]);
                    cnt++;
                }
            }
            if cnt < 1 { cnt = 1; }
            i32 a = aa / cnt;
            u8* p = px + (y * size + x) * 4;
            p[0] = cast(u8, (ab / cnt) * a / 255);   // BGRA, premultiplied
            p[1] = cast(u8, (ag / cnt) * a / 255);
            p[2] = cast(u8, (ar / cnt) * a / 255);
            p[3] = cast(u8, a);
        }
    }
    void* color = CreateBitmap(size, size, 1, 32, px);
    // all-zero AND mask; the 32-bit alpha channel wins
    u8* mb = alloc<u8>(size * 4);
    memset(mb, 0, size * 4);
    void* mask = CreateBitmap(size, size, 1, 1, mb);
    free(px);
    free(mb);
    if color == null || mask == null { return null; }
    ICONINFO ii;
    ii.fIcon = 1;
    ii.hbmMask = mask;
    ii.hbmColor = color;
    void* icon = CreateIconIndirect(&ii);
    ignore DeleteObject(color);
    ignore DeleteObject(mask);
    return icon;
}

// --- terminal probe (--term-probe) -----------------------------------
// The risk prototype that came before the emulator: pwsh behind ConPTY
// inside the editor, with every byte the host sends printed as it
// arrives and the escapes shown. No emulator; nothing here interprets
// a byte. The probe walks a script on a timer, one stage at a time,
// waiting for the stream to go quiet before the next, so the prompt,
// a command, a history recall, a completion, a resize and a burst are
// recorded separately. Those streams are the emulator's first
// fixtures, and the paints under the burst are what the coalescing
// wake has to hold. `--term-flags 1` runs the same script under
// PSEUDOCONSOLE_INHERIT_CURSOR instead of the default host mode.

private const i32 TERM_PROBE_TIMER = 8;
private const i32 TERM_PROBE_MS = 250;
private const i32 TP_QUIET = 4;    // ticks of silence that end a stage
private const i32 TP_MAX_DWELL = 80;   // and a stage ends anyway, quiet or not

private bool g_term_probe = false;
// --term-grid feeds the emulator instead of dumping the raw bytes, so
// the screen a real shell produces can be read as text. That is the
// live check for the emulator: the same stream, through the parser.
private bool g_tp_grid = false;
private i32 g_tp_h = -1;
private i32 g_tp_stage = 0;
private i32 g_tp_dwell = 0;
private i32 g_tp_quiet = 0;
private i32 g_tp_min = 0;
private bool g_tp_show = true;
private i64 g_tp_bytes = 0;
private i32 g_tp_drains = 0;
private i32 g_tp_paints = 0;      // WM_PAINT since the stage began
private i32 g_tp_paint_n = 0;     // every paint, counted in WM_PAINT
private i64 g_tp_t0 = 0;

// one line of the dump at a time, so a burst is not a print per byte
private u8[4096] g_tp_line;
private i32 g_tp_n = 0;

// --term-log <file> sends the dump to a file instead of stdout, which
// is how the probe runs with a real console attached: a redirected
// stdout is inherited by the shell, and then its output goes to the
// redirect rather than through the pty.
private u8[1024] g_tp_log;
private i32 g_tp_log_len = 0;
private u8* g_tp_buf = null;
private i64 g_tp_buf_n = 0;
private i64 g_tp_buf_cap = 0;

private void tp_out(str s) {
    if g_tp_log_len == 0 {
        print("{}", s);
        return;
    }
    if g_tp_buf_n + s.len > g_tp_buf_cap {
        i64 ncap = g_tp_buf_cap * 2 + s.len + 65536;
        u8* nb = alloc<u8>(ncap);
        if g_tp_buf != null {
            memcpy(nb, g_tp_buf, g_tp_buf_n);
            free(g_tp_buf);
        }
        g_tp_buf = nb;
        g_tp_buf_cap = ncap;
    }
    memcpy(g_tp_buf + g_tp_buf_n, s.data, s.len);
    g_tp_buf_n += s.len;
}

private void tp_line(str s) {
    tp_out(s);
    tp_out("\n");
}

// the dump carries its own numbers: print formats, a file does not
private void tp_num(i64 v) {
    noinit u8[24] d;
    i32 n = 0;
    if v < 0 {
        tp_out("-");
        v = 0 - v;
    }
    if v == 0 {
        tp_out("0");
        return;
    }
    while v > 0 {
        d[n] = cast(u8, '0' + cast(i32, v % 10));
        n++;
        v = v / 10;
    }
    noinit u8[24] r;
    for i32 i = 0; i < n; i++ { r[i] = d[n - 1 - i]; }
    tp_out(str_from(&r[0], n));
}

private void tp_flush() {
    if g_tp_n == 0 { return; }
    tp_line(str_from(&g_tp_line[0], g_tp_n));
    g_tp_n = 0;
}

private void tp_log_save() {
    if g_tp_log_len == 0 || g_tp_buf == null { return; }
    FileData fd;
    fd.data = g_tp_buf;
    fd.len = g_tp_buf_n;
    ignore file_write(str_from(&g_tp_log[0], g_tp_log_len), fd);
}

private void tp_put(u8 c) {
    if g_tp_n >= 4000 { tp_flush(); }
    g_tp_line[g_tp_n] = c;
    g_tp_n++;
}

private void tp_puts(str s) {
    for i32 i = 0; i < s.len; i++ { tp_put(s.data[i]); }
}

private void tp_hex(u8 c) {
    str d = "0123456789abcdef";
    tp_puts("\\x");
    tp_put(d.data[(c >> 4) & 15]);
    tp_put(d.data[c & 15]);
}

// the stream as text with the controls named: \e for escape, and a
// line break after each \n so the dump reads in order
private void tp_show(u8* p, i64 n) {
    for i64 i = 0; i < n; i++ {
        u8 c = p[i];
        if c == 27 {
            tp_puts("\\e");
        } else if c == 13 {
            tp_puts("\\r");
        } else if c == 10 {
            tp_puts("\\n");
            tp_flush();
        } else if c == 7 {
            tp_puts("\\a");
        } else if c == 8 {
            tp_puts("\\b");
        } else if c == 9 {
            tp_puts("\\t");
        } else if c < 32 || c == 127 {
            tp_hex(c);
        } else {
            tp_put(c);
        }
    }
}

private void tp_send(str s) {
    term_send(g_tp_h, s.data, cast(i64, s.len));
}

// The host asks where the cursor is (CSI 6 n) and waits for the
// answer: under PSEUDOCONSOLE_INHERIT_CURSOR it sends nothing at all
// until it has one. The probe has no grid, so it answers the home
// position; the emulator will answer where the cursor really is. A
// request split across two reads is not handled here, which the
// parser upstream will do for itself.
private void tp_answer_dsr(u8* p, i64 n) {
    for i64 i = 0; i + 3 < n; i++ {
        if p[i] == 27 && p[i + 1] == '[' && p[i + 2] == '6' && p[i + 3] == 'n' {
            noinit u8[8] r;
            r[0] = 27;
            r[1] = '[';
            r[2] = '1';
            r[3] = ';';
            r[4] = '1';
            r[5] = 'R';
            term_send(g_tp_h, &r[0], 6);
            tp_line("<< answered CSI 6 n with CSI 1;1 R");
            return;
        }
    }
}

// the queue the reader thread filled, drained on the main thread the
// way the pane will drain it into the emulator
private void term_probe_wake() {
    if g_tp_h < 0 { return; }
    i64 n = 0;
    u8* p = term_take(g_tp_h, &n);
    if p == null || n == 0 {
        if p != null { free(p); }
        return;
    }
    g_tp_bytes += n;
    g_tp_drains++;
    g_tp_quiet = 0;
    if g_tp_grid {
        term_feed(g_tp_h, p, n);
    } else if g_tp_show {
        tp_show(p, n);
    }
    tp_answer_dsr(p, n);
    free(p);
    // what the pane will do: one damage per drain, coalesced into one
    // frame by the loop
    plat_damage();
}

// the screen as the emulator has it, rows between bars so the blanks
// at the end of one are visible
private void tp_grid_dump() {
    noinit u8[16384] g;
    i32 n = term_dump(g_tp_h, &g[0], 16384);
    tp_out("-- screen ");
    tp_num(cast(i64, term_cols(g_tp_h)));
    tp_out("x");
    tp_num(cast(i64, term_rows(g_tp_h)));
    tp_out(", cursor ");
    tp_num(cast(i64, term_cx(g_tp_h)));
    tp_out(",");
    tp_num(cast(i64, term_cy(g_tp_h)));
    if term_alt(g_tp_h) { tp_out(", alternate"); }
    tp_out(", title [");
    tp_out(term_title(g_tp_h));
    tp_line("]");
    i32 start = 0;
    for i32 i = 0; i <= n; i++ {
        if i == n || g[i] == 10 {
            tp_out("   |");
            tp_out(str_from(&g[start], i - start));
            tp_line("|");
            start = i + 1;
        }
    }
    str broke = term_check(g_tp_h);
    if broke.len > 0 {
        tp_out("!! ");
        tp_line(broke);
    }
}

private void tp_stage_end() {
    tp_flush();
    if g_tp_grid && g_tp_h >= 0 { tp_grid_dump(); }
    i64 us = plat_time_us() - g_tp_t0;
    i32 paints = g_tp_paint_n - g_tp_paints;
    tp_out("-- ");
    tp_num(g_tp_bytes);
    tp_out(" bytes, ");
    tp_num(cast(i64, g_tp_drains));
    tp_out(" drains, ");
    tp_num(cast(i64, paints));
    tp_out(" paints, ");
    tp_num(us / 1000);
    tp_line(" ms");
    if g_tp_stage == 7 && us > 0 {
        tp_out("-- burst: ");
        tp_num(cast(i64, paints) * 1000000 / us);
        tp_out(" paints/s, ");
        tp_num(g_tp_bytes * 1000000 / us);
        tp_line(" bytes/s");
    }
    // written at every boundary, so a run that stalls still leaves its
    // record behind
    tp_log_save();
}

private void tp_stage_begin() {
    g_tp_dwell = 0;
    g_tp_quiet = 0;
    g_tp_min = 2;
    g_tp_show = true;
    g_tp_bytes = 0;
    g_tp_drains = 0;
    g_tp_paints = g_tp_paint_n;
    g_tp_t0 = plat_time_us();
    noinit u8[8] seq;
    switch g_tp_stage {
        case 0: {
            tp_out("== stage 0: start, flags ");
            tp_num(cast(i64, win_term_flags));
            tp_line(", 80x24");
            g_tp_min = 4;
        }
        case 1: {
            tp_line("== stage 1: Get-Date");
            tp_send("Get-Date\r");
        }
        case 2: {
            tp_line("== stage 2: history recall (up arrow)");
            seq[0] = 27;
            seq[1] = '[';
            seq[2] = 'A';
            term_send(g_tp_h, &seq[0], 3);
        }
        case 3: {
            tp_line("== stage 3: abandon the line (ctrl+c)");
            seq[0] = 3;
            term_send(g_tp_h, &seq[0], 1);
        }
        case 4: {
            tp_line("== stage 4: completion (Get-Ch, tab)");
            tp_send("Get-Ch");
            seq[0] = 9;
            term_send(g_tp_h, &seq[0], 1);
        }
        case 5: {
            tp_line("== stage 5: abandon the line (ctrl+c)");
            seq[0] = 3;
            term_send(g_tp_h, &seq[0], 1);
        }
        case 6: {
            tp_line("== stage 6: resize to 100x30");
            term_resize(g_tp_h, 100, 30);
        }
        case 7: {
            // the burst: the bytes are counted, not printed, since a
            // print per byte would be the thing being measured
            tp_line("== stage 7: burst, 1..100000 (bytes not shown)");
            g_tp_show = false;
            tp_send("1..100000 | % { $_ }\r");
        }
        case 8: {
            tp_line("== stage 8: idle with a prompt waiting");
            g_tp_min = 40;   // ten seconds, the window the cpu delta wants
        }
        default: {
            tp_line("== stage 9: kill");
            i64 t0 = plat_time_us();
            term_close(g_tp_h);
            tp_out("-- kill returned in ");
            tp_num((plat_time_us() - t0) / 1000);
            tp_line(" ms");
            tp_log_save();
            g_tp_h = -1;
            plat_kill_timer(TERM_PROBE_TIMER);
            PostQuitMessage(0);
        }
    }
}

private void term_probe_tick() {
    if g_tp_h < 0 { return; }
    g_tp_dwell++;
    g_tp_quiet++;
    if term_exited(g_tp_h) && g_tp_stage < 9 {
        tp_flush();
        tp_line("!! the shell exited");
        g_tp_stage = 8;
    }
    if g_tp_dwell < g_tp_min { return; }
    if g_tp_quiet < TP_QUIET && g_tp_dwell < TP_MAX_DWELL { return; }
    tp_stage_end();
    g_tp_stage++;
    tp_stage_begin();
}

private void term_probe_start() {
    win_term_trace = true;
    g_tp_h = term_open(80, 24);
    if g_tp_h < 0 {
        print("term-probe: no pseudo-terminal (ConPTY missing, or pwsh is not installed)\n");
        PostQuitMessage(1);
        return;
    }
    tp_out("term-probe: pty ");
    tp_num(cast(i64, g_tp_h));
    tp_out(", child code ");
    tp_num(cast(i64, plat_term_code(g_tp_h)));
    tp_line("");
    g_tp_stage = 0;
    tp_stage_begin();
    plat_set_timer(TERM_PROBE_TIMER, TERM_PROBE_MS);
}

void plat_sleep_ms(u32 ms) {
    win_sleep_ms(ms);
}

i32 plat_main() {
    ignore SetProcessDpiAwarenessContext(DPI_AWARE_PER_MONITOR_V2);

    for i32 a = 1; a < get_argc(); a++ {
        str arg = str_from_cstr(get_arg(a));
        if str_equal(arg, "--term-probe") {
            g_term_probe = true;
        } else if str_equal(arg, "--term-flags") && a + 1 < get_argc() {
            a++;
            win_term_flags = hl_num(str_from_cstr(get_arg(a)), 0);
        } else if str_equal(arg, "--term-grid") {
            g_tp_grid = true;
        } else if str_equal(arg, "--term-log") && a + 1 < get_argc() {
            a++;
            hl_path(str_from_cstr(get_arg(a)), &g_tp_log[0], &g_tp_log_len);
        } else if str_equal(arg, "--dpi") && a + 1 < get_argc() {
            // what the window reports, overridden: a dump the same size
            // on any screen
            a++;
            i32 v = hl_num(str_from_cstr(get_arg(a)), 0);
            if v >= 48 && v <= 480 { g_dpi_override = v; }
        } else {
            hl_arg(&a);
        }
    }

    win_wake_init();
    WNDCLASSEXW wc;
    wc.cbSize = cast(u32, sizeof(WNDCLASSEXW));
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = ed_wndproc;
    wc.hInstance = GetModuleHandleA(null);
    wc.hIcon = win_make_icon(32);
    wc.hIconSm = win_make_icon(16);
    g_cur_arrow = LoadCursorA(null, cast(u8*, IDC_ARROW));
    g_cur_ibeam = LoadCursorA(null, cast(u8*, IDC_IBEAM));
    g_cur_sizewe = LoadCursorA(null, cast(u8*, IDC_SIZEWE));
    g_cur_sizens = LoadCursorA(null, cast(u8*, IDC_SIZENS));
    g_cur_hand = LoadCursorA(null, cast(u8*, IDC_HAND));
    wc.hCursor = g_cur_arrow;   // WM_SETCURSOR picks per region
    wc.lpszClassName = win_wide("edmincWindow");
    if RegisterClassExW(&wc) == 0 {
        print("RegisterClassExW failed: {}\n", cast(i32, GetLastError()));
        return 1;
    }

    RECT r;
    r.right = WIN_DEFAULT_W;
    r.bottom = WIN_DEFAULT_H;
    ignore AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, 0);
    g_hwnd = CreateWindowExW(0, win_wide("edmincWindow"), win_wide("edminc"),
        WS_OVERLAPPEDWINDOW, cast(i32, CW_USEDEFAULT), cast(i32, CW_USEDEFAULT),
        r.right - r.left, r.bottom - r.top, null, null, GetModuleHandleA(null), null);
    if g_hwnd == null {
        print("CreateWindowExW failed: {}\n", cast(i32, GetLastError()));
        return 1;
    }
    // register the primary window before the caption reclaim below, so
    // the wndproc routes its WM_NCCALCSIZE rather than skipping it
    g_winrec[0].hwnd = g_hwnd;
    g_winrec[0].gpu = 0;
    g_winrec[0].caption_hover = -1;
    g_winrec[0].caption_press = -1;
    g_winrec[0].used = true;
    g_cur_win = 0;

    // dark frame border; the caption itself is self-drawn (see
    // WM_NCCALCSIZE and caption_render)
    i32 dark = 1;
    ignore DwmSetWindowAttribute(g_hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, 4);

    i32 dpi = cast(i32, GetDpiForWindow(g_hwnd));
    if dpi == 0 { dpi = DPI_BASE; }
    if g_dpi_override > 0 { dpi = g_dpi_override; }
    if !font_init(dpi) {
        print("font init failed\n");
        return 1;
    }

    // adopt the self-drawn caption: the frame recalc reclaims the
    // native caption band into the client area
    g_caption_h = caption_default_h(dpi);
    ignore SetWindowPos(g_hwnd, null, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);

    RECT cr;
    ignore GetClientRect(g_hwnd, &cr);
    win_wheel_settings();
    string wv = env_get("EDMINC_WAITABLE");
    gpu_waitable = !(wv.len == 1 && wv.data[0] == '0');
    free(wv);
    if !gpu_init(g_hwnd, cr.right - cr.left, cr.bottom - cr.top) {
        return 1;
    }
    draw_init();
    g_winrec[0].caption_h = g_caption_h;

    app_resize(cr.right - cr.left, cr.bottom - cr.top - g_caption_h);
    i64 t0 = plat_time_us();
    app_init(str_from(&g_arg_path[0], g_arg_path_len), dpi);
    g_load_us = plat_time_us() - t0;

    bool restored = false;
    if g_handover_len > 0 {
        restored = app_handover_restore(str_from(&g_handover[0], g_handover_len));
    } else if g_shot_len == 0 && g_play_len == 0 && !g_smoke && !g_term_probe
        && g_dump_term_len == 0 { restored = app_session_restore(); }

    if g_shot_len > 0 || g_dump_term_len > 0 {
        // A shot keeps the default window size, so a dump is the same
        // on any screen; maximizing would make it screen-sized.
        ignore ShowWindow(g_hwnd, SW_SHOW);
        hl_inject();
        if g_dump_term_len > 0 { hl_dump_term(); }
        if g_shot_len == 0 {
            ed_term_close_all();
            return 0;
        }
        // the dump should show the finished frame, so let any
        // background work land before it is taken
        app_settle();
        gpu_request_shot(str_from(&g_shot[0], g_shot_len));
        app_render();
        return 0;
    }

    if g_play_len > 0 {
        // a recorded fuzz run in the live window, one step per tick,
        // at the size the run was recorded at when the screen has
        // room for it, maximized when it does not
        if !play_open(str_from(&g_play[0], g_play_len)) { return 2; }
        i32 pw = 0;
        i32 ph = 0;
        bool sized = false;
        if play_start_size(&pw, &ph) {
            i32 want_w = pw;
            i32 want_h = ph + g_caption_h;
            RECT wr;
            RECT cr;
            ignore GetWindowRect(g_hwnd, &wr);
            ignore GetClientRect(g_hwnd, &cr);
            i32 frame_w = (wr.right - wr.left) - (cr.right - cr.left);
            i32 frame_h = (wr.bottom - wr.top) - (cr.bottom - cr.top);
            i32 sw = GetSystemMetrics(SM_CXSCREEN);
            i32 sh = GetSystemMetrics(SM_CYSCREEN);
            if want_w + frame_w <= sw && want_h + frame_h <= sh {
                ignore SetWindowPos(g_hwnd, null, 0, 0, want_w + frame_w, want_h + frame_h,
                    SWP_NOMOVE | SWP_NOZORDER);
                sized = true;
            }
        }
        if sized {
            ignore ShowWindow(g_hwnd, SW_SHOW);
        } else {
            ignore ShowWindow(g_hwnd, SW_MAXIMIZE);
        }
        plat_set_timer(PLAY_TIMER, g_play_ms);
    } else {
        // launch maximized, like the macOS shell launches zoomed, unless
        // a restored session placed the window(s) itself
        if !restored { ignore ShowWindow(g_hwnd, SW_MAXIMIZE); }
        // a restart: the old process granted the foreground and waits
        // for this window, but may already have exited, and then the
        // show above does not activate
        if g_handover_len > 0 { ignore SetForegroundWindow(g_hwnd); }
        // a second window opens after the first is shown, so the
        // maximize above still targets window 0
        if g_newwin { ignore plat_window_open(); }
        // the same injections a shot takes, so a live window can be put
        // in a state that needs typing before it is looked at
        hl_inject();
    }
    if g_term_probe { term_probe_start(); }
    plat_damage();

    win_loop();
    // no shell outlives the process
    term_close_all();
    return 0;
}




