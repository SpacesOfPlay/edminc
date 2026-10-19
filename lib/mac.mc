// mac.mc - macOS platform surface: Cocoa access through the
// Objective-C runtime C ABI (objc_runtime/ext_macos from the
// installed toolchain lib), shared window state, and the plat_*
// services from plat.mc. The driver is plat_mac.mc.

import thread;
import objc_runtime;
import ext_macos;

// CoreGraphics geometry, by value at the objc boundary (arm64 passes
// small float structs in FP registers).
struct CGPoint {
    f64 x;
    f64 y;
}

struct CGSize {
    f64 width;
    f64 height;
}

struct CGRect {
    CGPoint origin;
    CGSize size;
}

// Foundation aliases; ext_macos expects NSPoint from its importer.
type CGFloat = f64;
type NSPoint = CGPoint;
type NSSize = CGSize;
type NSRect = CGRect;

// The current window, its content view, and the view's CAMetalLayer.
// Portable code reaches them through the plat_* services only. Other
// windows park in g_macwin and swap in through mac_win_activate, which
// the driver calls at every callback boundary before the core sees the
// event (the wndproc routing on Windows). The driver index equals the
// core window index: ed_window_new picks the slot first.
void* g_window = null;
void* g_view = null;
void* g_layer = null;
f64 g_scale = 1.0;   // backing scale; core coordinates are pixels

const i32 MAC_WIN_MAX = 8;
struct MacWin {
    void* window;
    void* view;
    void* layer;
    f64 scale;
    i32 gpu;
    bool used;
    bool displaying;     // inside displayLayer: for this window
    bool frame_wanted;   // a frame asked for, held until the layer vends a drawable
    bool pacing;         // a fetch is out or a paced frame is in flight: marks wait
    bool fetching;       // the fetch thread is in nextDrawable
    bool fetched;        // a drawable is in gpu_pending, waiting for the main thread
    bool thr_up;
    bool thr_quit;
    void* sem;           // the fetch thread waits here between fetches
    Thread thr;
}
MacWin[MAC_WIN_MAX] g_macwin;
i32 g_cur_win = 0;

i32 mac_win_of_view(void* view) {
    for i32 i = 0; i < MAC_WIN_MAX; i++ {
        if g_macwin[i].used && g_macwin[i].view == view { return i; }
    }
    return -1;
}

i32 mac_win_of_window(void* win) {
    for i32 i = 0; i < MAC_WIN_MAX; i++ {
        if g_macwin[i].used && g_macwin[i].window == win { return i; }
    }
    return -1;
}

// point the singletons, the core and the gpu at window i; the scale is
// the one singleton that moves, so it is parked on the way out
void mac_win_activate(i32 i) {
    if i < 0 || i >= MAC_WIN_MAX || !g_macwin[i].used { return; }
    // the core switches windows on its own too (a session restore, the
    // pane move), so the driver being current is not enough to skip
    if i == g_cur_win && ed_window_active() == i { return; }
    g_macwin[g_cur_win].scale = g_scale;
    MacWin* c = &g_macwin[i];
    g_window = c.window;
    g_view = c.view;
    g_layer = c.layer;
    g_scale = c.scale;
    g_cur_win = i;
    app_use_window(i);
    gpu_bind(c.gpu);
}

private const u64 NSUTF8StringEncoding = 4;
private const i32 MAC_MAX_TIMERS = 16;

private struct MacTimer {
    i32 id;
    i32 win;        // the window that armed it; fires into that one
    void* nstimer;
}

private MacTimer[MAC_MAX_TIMERS] mac_timers;
private void* mac_timer_target = null;

// Retained NSString from UTF-8 bytes; pair with mac_release.
void* mac_nsstring(u8* bytes, i64 len) {
    void* s = objc.msg_id_v(objc_classref("NSString", "/System/Library/Frameworks/Foundation.framework/Foundation"), objc_selref("alloc"));
    return objc.msg_id_iqq(s, objc_selref("initWithBytes:length:encoding:"), cast(void*, bytes), cast(u64, len), NSUTF8StringEncoding);
}

void mac_release(void* obj) {
    if obj != null {
        objc.msg_void_v(obj, objc_selref("release"));
    }
}

// --- frame pacing: the drawable fetched ahead ----------------------------
// The core asks for the next glide frame from inside the frame build,
// through plat_damage_window. Marking the layer then makes Core
// Animation display it again at the next commit, and nextDrawable
// blocks the main thread until the layer vends a drawable, one per
// refresh with display sync on, so the run loop never reaches its
// queue and a held key's repeats arrive late. So a mark made while the
// window is being displayed, or while a paced frame is on its way, is
// held, and a fetch thread per window takes the wait instead: it
// blocks in nextDrawable, and when the layer vends the drawable it
// posts to the main thread, which renders into it at once. The layer's
// own pacing gives one frame per refresh at the vsync, so nothing
// tears, and the main thread is free between frames. A vended drawable
// that no frame wants any more goes back unpresented and the pacing
// stops, so idle stays at zero wakeups: the thread waits on its
// semaphore.

private void mac_fetch_thread(void* arg) {
    i32 win = cast(i32, cast(i64, arg));
    MacWin* w = &g_macwin[win];
    while true {
        ignore dispatch_semaphore_wait(w.sem, DISPATCH_TIME_FOREVER);
        if w.thr_quit { break; }
        void* pool = objc.msg_id_v(objc.msg_id_v(objc_classref("NSAutoreleasePool", "/System/Library/Frameworks/Foundation.framework/Foundation"), objc_selref("alloc")), objc_selref("init"));
        void* d = gpu_fetch_drawable(w.gpu);
        gpu_pending_set(w.gpu, d);
        w.fetched = true;
        mac_release(pool);
        cast(fn(void*, void*, void*, void*, bool): void, objc.raw)(mac_timer_target,
            objc_selref("performSelectorOnMainThread:withObject:waitUntilDone:"),
            objc_selref("onFrame:"), null, false);
    }
}

// a fetch out for the window, unless one is
private void mac_pace_start(i32 win) {
    MacWin* w = &g_macwin[win];
    if w.fetching || w.gpu < 0 || mac_timer_target == null { return; }
    if !w.thr_up {
        w.sem = dispatch_semaphore_create(0);
        w.thr_quit = false;
        thread_create(&w.thr, mac_fetch_thread, cast(void*, cast(i64, win)));
        w.thr_up = true;
    }
    w.fetching = true;
    w.pacing = true;
    ignore dispatch_semaphore_signal(w.sem);
}

private void mac_damage_win(i32 win) {
    MacWin* w = &g_macwin[win];
    if (w.displaying || w.pacing) && w.gpu >= 0 {
        w.frame_wanted = true;
        mac_pace_start(win);
        return;
    }
    objc.msg_void_v(w.layer, objc_selref("setNeedsDisplay"));
}

// around app_render in displayLayer:
void mac_display_begin(i32 win) {
    if win < 0 || win >= MAC_WIN_MAX { return; }
    g_macwin[win].displaying = true;
}

void mac_display_end(i32 win) {
    if win < 0 || win >= MAC_WIN_MAX { return; }
    g_macwin[win].displaying = false;
}

// a window that will not display now (covered, miniaturized) lets a
// fetched drawable go, so the pool is whole when it shows again
void mac_display_skipped(i32 win) {
    if win < 0 || win >= MAC_WIN_MAX { return; }
    MacWin* w = &g_macwin[win];
    gpu_pending_drop(w.gpu);
    w.frame_wanted = false;
    w.pacing = false;
}

// the fetch thread's post, on the main thread: the frame that wanted
// the drawable renders into it now, or the drawable goes back
void mac_frame_fired(void* self, void* _cmd, void* arg) {
    for i32 i = 0; i < MAC_WIN_MAX; i++ {
        MacWin* w = &g_macwin[i];
        if !w.used || !w.fetched { continue; }
        w.fetched = false;
        w.fetching = false;
        if w.frame_wanted && w.layer != null {
            w.frame_wanted = false;
            objc.msg_void_v(w.layer, objc_selref("setNeedsDisplay"));
        } else {
            gpu_pending_drop(w.gpu);
            w.pacing = false;
        }
    }
}

// the window's fetch thread goes with the window
void mac_pace_free(i32 win) {
    if win < 0 || win >= MAC_WIN_MAX { return; }
    MacWin* w = &g_macwin[win];
    if w.thr_up {
        w.thr_quit = true;
        ignore dispatch_semaphore_signal(w.sem);
        thread_join(&w.thr);
        w.thr_up = false;
    }
    gpu_pending_drop(w.gpu);
    w.frame_wanted = false;
    w.pacing = false;
    w.fetching = false;
    w.fetched = false;
    w.displaying = false;
}

// every live window repaints, so an edit in one shows in the others
void plat_damage() {
    for i32 i = 0; i < MAC_WIN_MAX; i++ {
        if g_macwin[i].used && g_macwin[i].layer != null { mac_damage_win(i); }
    }
}

void plat_damage_window(i32 win) {
    if win < 0 || win >= MAC_WIN_MAX || !g_macwin[win].used || g_macwin[win].layer == null { return; }
    mac_damage_win(win);
}

private mach_timebase_info_data_t mac_timebase;

i64 plat_time_us() {
    if mac_timebase.denom == 0 {
        ignore mach_timebase_info(&mac_timebase);
    }
    u64 t = mach_absolute_time();
    // ticks to ns; split to keep the multiply from overflowing
    u64 num = cast(u64, mac_timebase.numer);
    u64 den = cast(u64, mac_timebase.denom);
    u64 ns = t / den * num + t % den * num / den;
    return cast(i64, ns / 1000);
}

// NSTimer fire target; the class is registered by the driver with
// this as the onTimer: implementation.
void mac_timer_fired(void* self, void* _cmd, void* nstimer) {
    for i32 i = 0; i < MAC_MAX_TIMERS; i++ {
        if mac_timers[i].nstimer == nstimer {
            // into the window that armed it, as SetTimer(hwnd) does on
            // Windows; a window closed since falls through to the current
            mac_win_activate(mac_timers[i].win);
            if !play_timer(mac_timers[i].id) { app_timer(mac_timers[i].id); }
            return;
        }
    }
}

void mac_set_timer_target(void* target) {
    mac_timer_target = target;
}

// thread-safe main-thread wake: performSelectorOnMainThread on the
// timer target, whose onWake: calls app_wake()
void plat_wake() {
    cast(fn(void*, void*, void*, void*, bool): void, objc.raw)(mac_timer_target,
        objc_selref("performSelectorOnMainThread:withObject:waitUntilDone:"),
        objc_selref("onWake:"), null, false);
}

private extern "libSystem.B.dylib" {
    u8* getcwd(u8* buf, u64 size);
}

// working directory, UTF-8; feeds the title's project name
i32 plat_cwd(u8* buf, i32 cap) {
    if getcwd(buf, cast(u64, cap)) == null { return 0; }
    i32 n = 0;
    while n < cap && buf[n] != 0 { n++; }
    return n;
}

void plat_set_timer(i32 id, i32 ms) {
    plat_kill_timer(id);
    for i32 i = 0; i < MAC_MAX_TIMERS; i++ {
        if mac_timers[i].nstimer == null {
            void* t = cast(fn(void*, void*, f64, void*, void*, void*, bool): void*, objc.raw)(
                objc_classref("NSTimer", "/System/Library/Frameworks/Foundation.framework/Foundation"),
                objc_selref("timerWithTimeInterval:target:selector:userInfo:repeats:"),
                cast(f64, ms) / 1000.0, mac_timer_target, objc_selref("onTimer:"), null, true);
            ignore objc.msg_id_v(t, objc_selref("retain"));
            // common modes so the timer fires during window drags too
            void* rl = objc.msg_id_v(objc_classref("NSRunLoop", "/System/Library/Frameworks/Foundation.framework/Foundation"), objc_selref("mainRunLoop"));
            objc.msg_void_ii(rl, objc_selref("addTimer:forMode:"), t, NSRunLoopCommonModes);
            mac_timers[i].id = id;
            mac_timers[i].win = g_cur_win;
            mac_timers[i].nstimer = t;
            return;
        }
    }
}

void plat_kill_timer(i32 id) {
    for i32 i = 0; i < MAC_MAX_TIMERS; i++ {
        if mac_timers[i].nstimer != null && mac_timers[i].id == id {
            objc.msg_void_v(mac_timers[i].nstimer, objc_selref("invalidate"));
            mac_release(mac_timers[i].nstimer);
            mac_timers[i].nstimer = null;
        }
    }
}

void plat_set_title(str s) {
    void* ns = mac_nsstring(s.data, s.len);
    if ns == null { return; }
    objc.msg_void_i(g_window, objc_selref("setTitle:"), ns);
    mac_release(ns);
}

// Ends [NSApp run]. Takes effect when the current event finishes,
// and every caller today (key handler, close) is inside one.
void plat_quit() {
    objc.msg_void_i(NSApp, objc_selref("stop:"), null);
}

// macOS pasteboard text already uses '\n'; no ending conversion.
void plat_clipboard_set(u8* s, i64 n) {
    if n <= 0 { return; }
    void* pb = objc.msg_id_v(objc_classref("NSPasteboard", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("generalPasteboard"));
    ignore objc.msg_q_v(pb, objc_selref("clearContents"));
    void* ns = mac_nsstring(s, n);
    if ns == null { return; }
    ignore cast(fn(void*, void*, void*, void*): bool, objc.raw)(pb, objc_selref("setString:forType:"), ns, NSPasteboardTypeString);
    mac_release(ns);
}

u8* plat_clipboard_get(i64* out_len) {
    *out_len = 0;
    void* pb = objc.msg_id_v(objc_classref("NSPasteboard", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("generalPasteboard"));
    void* ns = objc.msg_id_i(pb, objc_selref("stringForType:"), NSPasteboardTypeString);
    if ns == null { return null; }
    u8* u = cast(u8*, objc.msg_id_v(ns, objc_selref("UTF8String")));
    if u == null { return null; }
    i64 n = 0;
    while u[n] != 0 { n++; }
    if n == 0 { return null; }
    // strip '\r' (CRLF content pasted from cross-platform sources)
    u8* buf = alloc<u8>(n);
    i64 m = 0;
    for i64 i = 0; i < n; i++ {
        if u[i] != 13 {
            buf[m] = u[i];
            m++;
        }
    }
    *out_len = m;
    return buf;
}

// --- child process (the LSP server) ----------------------------------
// fork + execvp with both stdio ends piped. Only async-signal-safe
// calls between fork and exec.

private extern "libSystem.B.dylib" {
    i32 mc_pipe(i32* fds) from "pipe";
    i32 mc_fork() from "fork";
    i32 mc_dup2(i32 a, i32 b) from "dup2";
    i32 mc_execvp(u8* file, u8** argv) from "execvp";
    i32 mc_close(i32 fd) from "close";
    i64 mc_read(i32 fd, void* buf, i64 n) from "read";
    i64 mc_write(i32 fd, void* buf, i64 n) from "write";
    i32 mc_kill(i32 pid, i32 sig) from "kill";
    i32 mc_waitpid(i32 pid, i32* st, i32 opts) from "waitpid";
    void mc_exit(i32 code) from "_exit";
}

// a slot is free when its pid is 0
private i32[PLAT_CHILDREN] child_pid;
private i32[PLAT_CHILDREN] child_in;    // write end: the child's stdin
private i32[PLAT_CHILDREN] child_out;   // read end: the child's stdout

bool plat_child_spawn(i32 k, str* argv, i32 argc) {
    if k < 0 || k >= PLAT_CHILDREN || child_pid[k] > 0 { return false; }
    noinit i32[2] pin;
    noinit i32[2] pout;
    if mc_pipe(&pin[0]) != 0 { return false; }
    if mc_pipe(&pout[0]) != 0 {
        ignore mc_close(pin[0]);
        ignore mc_close(pin[1]);
        return false;
    }
    // NUL-terminated argv copies for execvp
    u8** av = alloc<u8*>(argc + 1);
    for i32 i = 0; i < argc; i++ {
        u8* a = alloc<u8>(argv[i].len + 1);
        memcpy(a, argv[i].data, argv[i].len);
        a[argv[i].len] = 0;
        av[i] = a;
    }
    av[argc] = null;
    i32 pid = mc_fork();
    if pid == 0 {
        ignore mc_dup2(pin[0], 0);
        ignore mc_dup2(pout[1], 1);
        // Everything else goes, not just this pipe: a fork inherits
        // every descriptor, so the other spawn's pipe would be held
        // open by this child and its reader would never see end of
        // file. That froze the editor on Windows, where the same
        // hazard is handle inheritance.
        for i32 fd = 3; fd < 256; fd++ { ignore mc_close(fd); }
        ignore mc_execvp(av[0], av);
        mc_exit(127);
    }
    ignore mc_close(pin[0]);
    ignore mc_close(pout[1]);
    for i32 i = 0; i < argc; i++ { free(av[i]); }
    free(av);
    if pid < 0 {
        ignore mc_close(pin[1]);
        ignore mc_close(pout[0]);
        return false;
    }
    child_pid[k] = pid;
    child_in[k] = pin[1];
    child_out[k] = pout[0];
    return true;
}

// Run a program to completion and hand back its stdout. Separate from
// the children above because the language servers own those for the
// whole session; this is the one-shot git needs.
u8* plat_run_capture(str* argv, i32 argc, i64* out_len, i32* out_code) {
    *out_len = 0;
    *out_code = -1;
    noinit i32[2] pout;
    if mc_pipe(&pout[0]) != 0 { return null; }
    u8** av = alloc<u8*>(argc + 1);
    for i32 i = 0; i < argc; i++ {
        u8* a = alloc<u8>(argv[i].len + 1);
        memcpy(a, argv[i].data, argv[i].len);
        a[argv[i].len] = 0;
        av[i] = a;
    }
    av[argc] = null;
    i32 pid = mc_fork();
    if pid == 0 {
        ignore mc_dup2(pout[1], 1);
        // stderr rides the same pipe, as it does on Windows: the build
        // panel sees the compiler's diagnostics, and git's own "fatal"
        // for a path HEAD lacks lands in the discarded capture instead
        // of on the terminal
        ignore mc_dup2(pout[1], 2);
        // see plat_child_spawn: every inherited descriptor goes, or a
        // pipe belonging to another spawn stays open in this child
        for i32 fd = 3; fd < 256; fd++ { ignore mc_close(fd); }
        ignore mc_execvp(av[0], av);
        mc_exit(127);
    }
    ignore mc_close(pout[1]);
    for i32 i = 0; i < argc; i++ { free(av[i]); }
    free(av);
    if pid < 0 {
        ignore mc_close(pout[0]);
        return null;
    }
    i64 cap = 65536;
    u8* buf = alloc<u8>(cap);
    i64 n = 0;
    while true {
        if n == cap {
            i64 ncap = cap * 2;
            u8* nb = alloc<u8>(ncap);
            memcpy(nb, buf, n);
            free(buf);
            buf = nb;
            cap = ncap;
        }
        i64 got = mc_read(pout[0], buf + n, cap - n);
        if got <= 0 { break; }
        n += got;
    }
    ignore mc_close(pout[0]);
    i32 st = 0;
    ignore mc_waitpid(pid, &st, 0);
    // the low byte holds the signal, the next one the exit status
    *out_code = (st >> 8) & 0xFF;
    *out_len = n;
    return buf;
}

i64 plat_child_write(i32 k, u8* p, i64 n) {
    if k < 0 || k >= PLAT_CHILDREN || child_pid[k] <= 0 { return -1; }
    i64 done = 0;
    while done < n {
        i64 w = mc_write(child_in[k], p + done, n - done);
        if w <= 0 { return done; }
        done += w;
    }
    return done;
}

i64 plat_child_read(i32 k, u8* p, i64 cap) {
    if k < 0 || k >= PLAT_CHILDREN || child_pid[k] <= 0 { return -1; }
    return mc_read(child_out[k], p, cap);
}

void plat_child_kill(i32 k) {
    if k < 0 || k >= PLAT_CHILDREN || child_pid[k] <= 0 { return; }
    ignore mc_close(child_in[k]);
    ignore mc_close(child_out[k]);
    ignore mc_kill(child_pid[k], 15);   // SIGTERM
    i32 st = 0;
    ignore mc_waitpid(child_pid[k], &st, 0);
    child_pid[k] = 0;
    child_in[k] = -1;
    child_out[k] = -1;
}

// --- pseudo-terminal (the terminal pane) -----------------------------
// posix_openpt for the master, then a fork whose child becomes its own
// session, opens the slave (which makes it the controlling terminal),
// sizes it, and execs the user's shell as a login shell, so the profile
// sets the PATH the editor itself was not launched with. The parent
// keeps the master: read and write are the plain calls, a resize is an
// ioctl on the master, and the child sees it as SIGWINCH.

private extern "libSystem.B.dylib" {
    i32 mt_openpt(i32 flags) from "posix_openpt";
    i32 mt_grantpt(i32 fd) from "grantpt";
    i32 mt_unlockpt(i32 fd) from "unlockpt";
    u8* mt_ptsname(i32 fd) from "ptsname";
    i32 mt_open(u8* path, i32 flags, ...) from "open";
    i32 mt_setsid() from "setsid";
    i32 mt_ioctl(i32 fd, u64 req, ...) from "ioctl";
    i32 mt_setenv(u8* name, u8* value, i32 overwrite) from "setenv";
    i32 mt_unsetenv(u8* name) from "unsetenv";
    u8* mt_getenv(u8* name) from "getenv";
}

private const i32 MT_O_RDWR = 0x0002;
private const i32 MT_O_NOCTTY = 0x00020000;
// _IOW('t', 103, struct winsize) and _IO('t', 97): IOC_IN | (8 << 16) |
// ('t' << 8) | n, from sys/ioccom.h and sys/ttycom.h
private const u64 MT_TIOCSWINSZ = 0x80087467;
private const u64 MT_TIOCSCTTY = 0x20007461;
private const i32 MT_SIGHUP = 1;
private const i32 MT_WNOHANG = 1;

private struct MacWinsize {
    u16 ws_row;
    u16 ws_col;
    u16 ws_xpixel;
    u16 ws_ypixel;
}

private struct MacTerm {
    i32 master;
    i32 pid;
    i32 code;       // -1 while running; the wait's status once reaped
    bool used;
}
private MacTerm[TERM_MAX] g_mterm;

// the shell: EDMINC_SHELL, else the login shell, else zsh
private u8* mt_shell_path() {
    u8* s = mt_getenv("EDMINC_SHELL");
    if s != null && s[0] != 0 { return s; }
    s = mt_getenv("SHELL");
    if s != null && s[0] != 0 { return s; }
    return "/bin/zsh";
}

// argv as one shell command, each word in single quotes (a quote
// inside becomes '\'' ), NUL-terminated; the caller frees
private u8* mt_shell_command(str* argv, i32 argc) {
    i64 cap = 8;
    for i32 i = 0; i < argc; i++ { cap += argv[i].len * 4 + 4; }
    u8* out = alloc<u8>(cap);
    i64 o = 0;
    for i32 i = 0; i < argc; i++ {
        if i > 0 { out[o] = ' '; o++; }
        out[o] = 39;
        o++;
        for i64 k = 0; k < argv[i].len; k++ {
            u8 c = argv[i].data[k];
            if c == 39 {
                out[o] = 39; out[o + 1] = 92; out[o + 2] = 39; out[o + 3] = 39;
                o += 4;
            } else {
                out[o] = c;
                o++;
            }
        }
        out[o] = 39;
        o++;
    }
    out[o] = 0;
    return out;
}

i32 plat_term_spawn(i32 cols, i32 rows, str* cargv, i32 cargc, bool under) {
    i32 h = -1;
    for i32 i = 0; i < TERM_MAX; i++ {
        if !g_mterm[i].used {
            h = i;
            break;
        }
    }
    if h < 0 { return -1; }
    i32 master = mt_openpt(MT_O_RDWR | MT_O_NOCTTY);
    if master < 0 { return -1; }
    if mt_grantpt(master) != 0 || mt_unlockpt(master) != 0 {
        ignore mc_close(master);
        return -1;
    }
    u8* slave_name = mt_ptsname(master);
    if slave_name == null {
        ignore mc_close(master);
        return -1;
    }
    // the name is in libc's static buffer; the child needs its own copy
    // taken before the fork, since it must not allocate after it
    noinit u8[256] sname;
    i32 sn = 0;
    while sn < 255 && slave_name[sn] != 0 {
        sname[sn] = slave_name[sn];
        sn++;
    }
    sname[sn] = 0;
    MacWinsize ws;
    ws.ws_row = cast(u16, rows);
    ws.ws_col = cast(u16, cols);
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    u8* shell = mt_shell_path();
    // "-<name>" as argv[0] is the classic login-shell mark; -l says it
    // outright and every shell in the set takes it. A command runs
    // under the same login shell with -c, so the user's PATH applies.
    u8* cmd = null;
    if cargc > 0 { cmd = mt_shell_command(cargv, cargc); }
    u8*[5] argv;
    argv[0] = shell;
    argv[1] = "-l";
    argv[2] = null;
    if cmd != null {
        argv[2] = "-c";
        argv[3] = cmd;
        argv[4] = null;
    }
    i32 pid = mc_fork();
    if pid == 0 {
        // only async-signal-safe calls from here to the exec
        ignore mt_setsid();
        i32 slave = mt_open(&sname[0], MT_O_RDWR);
        if slave < 0 { mc_exit(127); }
        ignore mt_ioctl(slave, MT_TIOCSCTTY, 0);
        ignore mt_ioctl(slave, MT_TIOCSWINSZ, &ws);
        ignore mc_dup2(slave, 0);
        ignore mc_dup2(slave, 1);
        ignore mc_dup2(slave, 2);
        // everything else goes, the master above all: a child holding
        // the master's other end would keep the reader's end of file
        // from ever arriving (see plat_child_spawn)
        for i32 fd = 3; fd < 256; fd++ { ignore mc_close(fd); }
        ignore mt_setenv("TERM", "xterm-256color", 1);
        ignore mt_setenv("COLORTERM", "truecolor", 1);
        // the child is in this terminal, not the one the editor was
        // launched from: the launching terminal's session variables
        // would make the shell restore that session here
        ignore mt_setenv("TERM_PROGRAM", "edminc", 1);
        ignore mt_unsetenv("TERM_PROGRAM_VERSION");
        ignore mt_unsetenv("TERM_SESSION_ID");
        ignore mc_execvp(shell, &argv[0]);
        mc_exit(127);
    }
    if cmd != null { free(cmd); }
    if pid < 0 {
        ignore mc_close(master);
        return -1;
    }
    g_mterm[h].master = master;
    g_mterm[h].pid = pid;
    g_mterm[h].code = -1;
    g_mterm[h].used = true;
    return h;
}

private bool mt_valid(i32 h) {
    return h >= 0 && h < TERM_MAX && g_mterm[h].used;
}

i64 plat_term_read(i32 h, u8* buf, i64 cap) {
    if !mt_valid(h) || g_mterm[h].master < 0 { return -1; }
    // EIO once the slave side has closed (the child exited): that is the
    // end of file the reader thread ends on, the same as a zero read
    i64 n = mc_read(g_mterm[h].master, buf, cap);
    if n < 0 { return 0; }
    return n;
}

i64 plat_term_write(i32 h, u8* p, i64 n) {
    if !mt_valid(h) || g_mterm[h].master < 0 { return -1; }
    i64 done = 0;
    while done < n {
        i64 w = mc_write(g_mterm[h].master, p + done, n - done);
        if w <= 0 { return done; }
        done += w;
    }
    return done;
}

// the child's exit code, or -1 while it runs; reaped without waiting
i32 plat_term_code(i32 h) {
    if !mt_valid(h) { return -1; }
    if g_mterm[h].code >= 0 { return g_mterm[h].code; }
    if g_mterm[h].pid <= 0 { return -1; }
    i32 st = 0;
    i32 r = mc_waitpid(g_mterm[h].pid, &st, MT_WNOHANG);
    if r != g_mterm[h].pid { return -1; }
    g_mterm[h].pid = -1;
    // exited normally: the status's next byte; by a signal: 128 + it
    if (st & 0x7F) == 0 { g_mterm[h].code = (st >> 8) & 0xFF; }
    else { g_mterm[h].code = 128 + (st & 0x7F); }
    return g_mterm[h].code;
}

void plat_term_resize(i32 h, i32 cols, i32 rows) {
    if !mt_valid(h) || g_mterm[h].master < 0 { return; }
    MacWinsize ws;
    ws.ws_row = cast(u16, rows);
    ws.ws_col = cast(u16, cols);
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    ignore mt_ioctl(g_mterm[h].master, MT_TIOCSWINSZ, &ws);
}

// The hangup ends the shell, and closing the master ends the pty: the
// reader's blocking read then returns, which is what lets its thread go.
// The child is reaped by plat_term_code or here; the handle stays until
// plat_term_free, since the reader may still be inside its read.
void plat_term_kill(i32 h) {
    if !mt_valid(h) { return; }
    if g_mterm[h].pid > 0 { ignore mc_kill(g_mterm[h].pid, MT_SIGHUP); }
    if g_mterm[h].master >= 0 {
        ignore mc_close(g_mterm[h].master);
        g_mterm[h].master = -1;
    }
}

// after the reader has seen its end of file and gone
void plat_term_free(i32 h) {
    if h < 0 || h >= TERM_MAX { return; }
    if g_mterm[h].pid > 0 {
        i32 st = 0;
        ignore mc_waitpid(g_mterm[h].pid, &st, 0);
    }
    g_mterm[h].master = -1;
    g_mterm[h].pid = -1;
    g_mterm[h].used = false;
}

// --- the restart: this process replaced by the next build ---------------

private extern "libSystem.B.dylib" {
    i32 mc_execv(u8* path, u8** argv) from "execv";
    i32 mc_fcntl(i32 fd, i32 cmd, i32 arg) from "fcntl";
}
private const i32 MT_F_SETFD = 2;

i32 plat_exe_path(u8* out, i32 cap) {
    noinit u8[PATH_MAX] buf;
    u32 sz = cast(u32, PATH_MAX);
    if _NSGetExecutablePath(&buf[0], &sz) != 0 { return 0; }
    i32 n = 0;
    while n < PATH_MAX && buf[n] != 0 { n++; }
    if n > cap { n = cap; }
    memcpy(out, &buf[0], n);
    return n;
}

// A fork, the exec in the child, and this process gone: a plain exec
// would keep the task, and AppKit then logs "Task policy set failed"
// every time the new image sets itself up as an application again. The
// descriptors without close-on-exec cross into the child, which is
// what the handed-over ptys rely on; the shells keep their own session
// and are reparented, so the exit code of one is not seen after this.
bool plat_exec_self(str exe, str* argv, i32 argc) {
    i32 extra = hl_restart_arg_count();
    u8** av = alloc<u8*>(cast(i64, argc + extra + 2));
    av[0] = str_to_cstr(exe);
    for i32 i = 0; i < argc; i++ { av[i + 1] = str_to_cstr(argv[i]); }
    for i32 i = 0; i < extra; i++ { av[argc + 1 + i] = str_to_cstr(hl_restart_arg(i)); }
    av[argc + extra + 1] = null;
    i32 pid = mc_fork();
    if pid == 0 {
        ignore mc_execv(av[0], av);
        mc_exit(127);
    }
    if pid < 0 { return false; }
    mc_exit(0);   // straight out: no close of the terminals on the way
    return false;
}

// --- the detach: the shell gets its prompt back -------------------------

// A shell waits for any child here, where on Windows it does not wait
// for a windowed program. So a plain launch forks, the child takes a
// session of its own and execs this executable again with --no-detach
// in front of the arguments, and this process exits. The prompt
// returns, and the terminal's Ctrl+C and its close no longer reach the
// editor. The descriptors stay as they are: output still goes where
// the shell sent it. When the fork fails the launch stays in the
// foreground.
void mac_detach() {
    noinit u8[PATH_MAX] ep;
    i32 en = plat_exe_path(&ep[0], PATH_MAX);
    if en == 0 { return; }
    i32 argc = get_argc();
    u8** av = alloc<u8*>(cast(i64, argc + 2));
    av[0] = str_to_cstr(str_from(&ep[0], en));
    av[1] = str_to_cstr("--no-detach");
    for i32 i = 1; i < argc; i++ { av[i + 1] = get_arg(i); }
    av[argc + 1] = null;
    i32 pid = mc_fork();
    if pid == 0 {
        ignore mt_setsid();
        ignore mc_execv(av[0], av);
        mc_exit(127);
    }
    if pid < 0 { return; }
    mc_exit(0);
}

bool plat_term_export(i32 h, i64* fd, i32* pid) {
    if !mt_valid(h) || g_mterm[h].master < 0 { return false; }
    ignore mc_fcntl(g_mterm[h].master, MT_F_SETFD, 0);   // no close-on-exec
    *fd = cast(i64, g_mterm[h].master);
    *pid = g_mterm[h].pid;
    return true;
}

i32 plat_term_adopt(i64 fd, i32 pid) {
    if fd < 0 { return -1; }
    i32 h = -1;
    for i32 i = 0; i < TERM_MAX; i++ {
        if !g_mterm[i].used {
            h = i;
            break;
        }
    }
    if h < 0 { return -1; }
    g_mterm[h].master = cast(i32, fd);
    g_mterm[h].pid = pid;
    g_mterm[h].code = -1;
    g_mterm[h].used = true;
    return h;
}

// --- the terminal's colors, from Terminal.app --------------------------
// Terminal.app's default profile, when the user picked one other than
// the stock Basic: a profile stores only what differs from Basic, so
// most keys are absent and the pane keeps its own for those. The
// colors are archived NSColor objects in the preferences domain.

private extern "CoreFoundation" {
    void* CFPreferencesCopyAppValue(void* key, void* app);
    void* CFDictionaryGetValue(void* dict, void* key);
    u64 CFGetTypeID(void* cf);
    u64 CFStringGetTypeID();
    u64 CFDictionaryGetTypeID();
    u64 CFDataGetTypeID();
}

private const i32 MTP_KEYS = 21;

private void* mtp_cfstr(str s) { return mac_nsstring(s.data, s.len); }

// an archived NSColor to the frame's format, false when it does not decode
private bool mtp_color(void* data, u32* out, f64* alpha) {
    void* un = objc_classref("NSKeyedUnarchiver", "/System/Library/Frameworks/Foundation.framework/Foundation");
    void* ccls = objc_classref("NSColor", "/System/Library/Frameworks/AppKit.framework/AppKit");
    void* c = cast(fn(void*, void*, void*, void*, void*): void*, objc.raw)(un,
        objc_selref("unarchivedObjectOfClass:fromData:error:"), ccls, data, null);
    if c == null {
        c = cast(fn(void*, void*, void*): void*, objc.raw)(un, objc_selref("unarchiveObjectWithData:"), data);
    }
    if c == null { return false; }
    void* srgb = objc.msg_id_v(objc_classref("NSColorSpace", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("sRGBColorSpace"));
    void* cs = cast(fn(void*, void*, void*): void*, objc.raw)(c, objc_selref("colorUsingColorSpace:"), srgb);
    if cs == null { return false; }
    f64 r = cast(fn(void*, void*): f64, objc.raw)(cs, objc_selref("redComponent"));
    f64 g = cast(fn(void*, void*): f64, objc.raw)(cs, objc_selref("greenComponent"));
    f64 b = cast(fn(void*, void*): f64, objc.raw)(cs, objc_selref("blueComponent"));
    *alpha = cast(fn(void*, void*): f64, objc.raw)(cs, objc_selref("alphaComponent"));
    *out = 0xFF000000 | mtp_byte(r) | (mtp_byte(g) << 8) | (mtp_byte(b) << 16);
    return true;
}

private u32 mtp_byte(f64 v) {
    if v <= 0.0 { return 0; }
    if v >= 1.0 { return 255; }
    return cast(u32, v * 255.0 + 0.5);
}

// c over ground, by c's alpha; the selection is translucent there
private u32 mtp_over(u32 c, f64 a, u32 ground) {
    u32 r = cast(u32, cast(f64, c & 0xFF) * a + cast(f64, ground & 0xFF) * (1.0 - a) + 0.5);
    u32 g = cast(u32, cast(f64, (c >> 8) & 0xFF) * a + cast(f64, (ground >> 8) & 0xFF) * (1.0 - a) + 0.5);
    u32 b = cast(u32, cast(f64, (c >> 16) & 0xFF) * a + cast(f64, (ground >> 16) & 0xFF) * (1.0 - a) + 0.5);
    return 0xFF000000 | r | (g << 8) | (b << 16);
}

u32 plat_term_palette(u32* out, i32 n) {
    if n < MTP_KEYS { return 0; }
    void* app = mtp_cfstr("com.apple.Terminal");
    void* k_default = mtp_cfstr("Default Window Settings");
    void* k_settings = mtp_cfstr("Window Settings");
    void* basic = mtp_cfstr("Basic");
    u32 have = 0;
    void* name = CFPreferencesCopyAppValue(k_default, app);
    void* all = CFPreferencesCopyAppValue(k_settings, app);
    if name != null && all != null
        && CFGetTypeID(name) == CFStringGetTypeID()
        && CFGetTypeID(all) == CFDictionaryGetTypeID()
        && !objc.msg_bool_i(name, objc_selref("isEqualToString:"), basic) {
        void* prof = CFDictionaryGetValue(all, name);
        if prof != null && CFGetTypeID(prof) == CFDictionaryGetTypeID() {
            str[MTP_KEYS] keys = {
                "TextColor", "BackgroundColor", "TextBoldColor", "CursorColor", "SelectionColor",
                "ANSIBlackColor", "ANSIRedColor", "ANSIGreenColor", "ANSIYellowColor",
                "ANSIBlueColor", "ANSIMagentaColor", "ANSICyanColor", "ANSIWhiteColor",
                "ANSIBrightBlackColor", "ANSIBrightRedColor", "ANSIBrightGreenColor",
                "ANSIBrightYellowColor", "ANSIBrightBlueColor", "ANSIBrightMagentaColor",
                "ANSIBrightCyanColor", "ANSIBrightWhiteColor" };
            f64 sel_alpha = 1.0;
            for i32 i = 0; i < MTP_KEYS; i++ {
                void* k = mtp_cfstr(keys[i]);
                void* v = CFDictionaryGetValue(prof, k);
                mac_release(k);
                if v == null || CFGetTypeID(v) != CFDataGetTypeID() { continue; }
                u32 c = 0;
                f64 a = 1.0;
                if mtp_color(v, &c, &a) {
                    out[i] = c;
                    have |= (1 << cast(u32, i));
                    if i == TP_SEL { sel_alpha = a; }
                }
            }
            // the selection sits over the background, opaque here
            if (have & (1 << cast(u32, TP_SEL))) != 0 && sel_alpha < 1.0 {
                u32 ground = 0xFF000000;
                if (have & (1 << cast(u32, TP_BG))) != 0 { ground = out[TP_BG]; }
                out[TP_SEL] = mtp_over(out[TP_SEL], sel_alpha, ground);
            }
        }
    }
    if name != null { CFRelease(name); }
    if all != null { CFRelease(all); }
    mac_release(basic);
    mac_release(k_settings);
    mac_release(k_default);
    mac_release(app);
    return have;
}

// --- the file watcher: FSEvents ------------------------------------------
// One stream over the folder with file-level events, delivered on a
// dispatch queue of its own, so the main run loop takes no part. The
// callback turns each event into a record and writes it to a pipe.
// plat_watch_read blocks in read() on the pipe, which is where the
// contract's thread waits. plat_watch_close writes a stop record, so
// that read returns, and plat_watch_free stops the stream and closes
// the pipe. The stream's own drops (its buffer overflowed, a subtree
// must be scanned, the root moved) become a lost record, which the
// read answers with 0. The pipe's write end does not block: a full
// pipe drops the record and marks the batch lost instead of holding
// the queue's thread.

private struct MacFSContext {
    i64 version;
    void* info;
    void* retain;
    void* release;
    void* copy_desc;
}

private extern "CoreServices" {
    void* FSEventStreamCreate(void* alloc, void* callback, MacFSContext* ctx,
        void* paths, u64 since, f64 latency, u32 flags);
    void FSEventStreamSetDispatchQueue(void* stream, void* queue);
    u8 FSEventStreamStart(void* stream);
    void FSEventStreamStop(void* stream);
    void FSEventStreamInvalidate(void* stream);
    void FSEventStreamRelease(void* stream);
}

private extern "libSystem.B.dylib" {
    void* dispatch_queue_create(u8* label, void* attr);
    void dispatch_release(void* obj);
    u8* mw_realpath(u8* path, u8* resolved) from "realpath";
}

private const u64 MW_SINCE_NOW = 0xFFFFFFFFFFFFFFFF;   // kFSEventStreamEventIdSinceNow
private const u32 MW_CREATE_FLAGS = 0x02 | 0x10;      // NoDefer, FileEvents
private const f64 MW_LATENCY_S = 0.05;
// event flags
private const u32 MW_EV_LOST = 0x01 | 0x02 | 0x04 | 0x20;   // MustScanSubDirs, UserDropped, KernelDropped, RootChanged
private const u32 MW_EV_MOVED = 0x100 | 0x200 | 0x800;      // ItemCreated, ItemRemoved, ItemRenamed
private const u32 MW_EV_CHANGED = 0x1000 | 0x400;           // ItemModified, ItemInodeMetaMod
private const i32 MW_F_SETFL = 4;
private const i32 MW_O_NONBLOCK = 4;
private const i32 MW_FD_CLOEXEC = 1;
private const i32 MW_MAX = 4;
private const i32 MW_PATH_MAX = 4096;
private const i64 MW_CARRY = 131072;
private const u8 MW_KIND_STOP = 'q';
private const u8 MW_KIND_LOST = 'l';

private struct MacWatch {
    bool used;
    bool mx_ready;
    bool stopping;
    bool lost;        // a record did not fit the pipe
    void* stream;
    void* queue;
    i32 rd;
    i32 wr;
    u8* root;         // the folder's real path, no trailing '/'
    i32 root_len;
    u8* carry;        // the tail of the last read: a record cut by cap
    i64 carry_len;
    Mutex mx;
}

private MacWatch[MW_MAX] g_mwatch;

private i32 mw_cstr_len(u8* p) {
    i32 n = 0;
    while p[n] != 0 { n++; }
    return n;
}

private bool mw_prefix_eq(u8* p, u8* root, i32 n) {
    for i32 i = 0; i < n; i++ {
        if p[i] != root[i] { return false; }
    }
    return true;
}

// one record into the pipe, under the lock; a pipe that is full loses it
private void mw_emit(i32 h, u8 kind, u8* path, i32 n) {
    noinit u8[MW_PATH_MAX + 2] rec;
    if n > MW_PATH_MAX { n = MW_PATH_MAX; }
    rec[0] = kind;
    if n > 0 { memcpy(&rec[1], path, n); }
    rec[n + 1] = '\n';
    i64 w = mc_write(g_mwatch[h].wr, cast(void*, &rec[0]), n + 2);
    if w != n + 2 { g_mwatch[h].lost = true; }
}

// the stream's callback, on the queue's thread
private void mw_callback(void* stream, void* info, u64 n, void* paths, u32* flags, u64* ids) {
    i32 h = cast(i32, cast(i64, info));
    if h < 0 || h >= MW_MAX { return; }
    u8** ps = cast(u8**, paths);
    mutex_lock(&g_mwatch[h].mx);
    if g_mwatch[h].used && !g_mwatch[h].stopping {
        for u64 i = 0; i < n; i++ {
            u32 f = flags[i];
            if (f & MW_EV_LOST) != 0 {
                mw_emit(h, MW_KIND_LOST, null, 0);
                continue;
            }
            u8 kind = 0;
            if (f & MW_EV_MOVED) != 0 {
                kind = 'm';
            } else if (f & MW_EV_CHANGED) != 0 {
                kind = 'c';
            }
            if kind == 0 { continue; }
            u8* p = ps[i];
            i32 len = mw_cstr_len(p);
            i32 rl = g_mwatch[h].root_len;
            // under the root: the path relative to it; the root itself
            // is no entry of its own
            if len > rl + 1 && p[rl] == '/' && mw_prefix_eq(p, g_mwatch[h].root, rl) {
                mw_emit(h, kind, p + rl + 1, len - rl - 1);
            } else if len != rl {
                mw_emit(h, MW_KIND_LOST, null, 0);
            }
        }
    }
    mutex_unlock(&g_mwatch[h].mx);
}

i32 plat_watch_open(str dir) {
    i32 h = -1;
    for i32 i = 0; i < MW_MAX; i++ {
        if !g_mwatch[i].used { h = i; break; }
    }
    if h < 0 { return -1; }
    MacWatch* w = &g_mwatch[h];
    if !w.mx_ready {
        mutex_init(&w.mx);
        w.mx_ready = true;
    }
    w.used = true;
    w.stopping = false;
    w.lost = false;
    w.rd = -1;
    w.wr = -1;
    w.stream = null;
    w.queue = null;
    w.carry = alloc<u8>(MW_CARRY);
    w.carry_len = 0;
    // the real path: the stream reports paths with links resolved
    u8* c = str_to_cstr(dir);
    noinit u8[MW_PATH_MAX] rp;
    u8* r = mw_realpath(c, &rp[0]);
    free(c);
    if r == null {
        plat_watch_free(h);
        return -1;
    }
    i32 rl = mw_cstr_len(&rp[0]);
    while rl > 1 && rp[rl - 1] == '/' { rl--; }
    w.root = alloc<u8>(rl + 1);
    memcpy(w.root, &rp[0], rl);
    w.root[rl] = 0;
    w.root_len = rl;
    noinit i32[2] fds;
    if mc_pipe(&fds[0]) != 0 {
        plat_watch_free(h);
        return -1;
    }
    w.rd = fds[0];
    w.wr = fds[1];
    ignore mc_fcntl(w.rd, MT_F_SETFD, MW_FD_CLOEXEC);   // a shell in a pane must not inherit it
    ignore mc_fcntl(w.wr, MT_F_SETFD, MW_FD_CLOEXEC);
    ignore mc_fcntl(w.wr, MW_F_SETFL, MW_O_NONBLOCK);
    w.queue = dispatch_queue_create("edminc.watch", null);
    void* path = mac_nsstring(w.root, rl);
    void* arr = objc.msg_id_i(objc_classref("NSArray", "/System/Library/Frameworks/Foundation.framework/Foundation"),
        objc_selref("arrayWithObject:"), path);
    ignore objc.msg_id_v(arr, objc_selref("retain"));
    MacFSContext ctx = MacFSContext{ 0, cast(void*, cast(i64, h)), null, null, null };
    w.stream = FSEventStreamCreate(null, cast(void*, &mw_callback), &ctx, arr,
        MW_SINCE_NOW, MW_LATENCY_S, MW_CREATE_FLAGS);
    mac_release(arr);
    mac_release(path);
    if w.stream == null {
        plat_watch_free(h);
        return -1;
    }
    FSEventStreamSetDispatchQueue(w.stream, w.queue);
    if FSEventStreamStart(w.stream) == 0 {
        plat_watch_free(h);
        return -1;
    }
    return h;
}

// The pipe's bytes as whole records: a read may cut one, and its tail
// waits for the next call. The stop record ends the watch, a lost
// record answers 0 for the batch, and a batch with nothing left after
// those is read past.
i64 plat_watch_read(i32 h, u8* out, i64 cap) {
    if h < 0 || h >= MW_MAX || !g_mwatch[h].used { return -1; }
    MacWatch* w = &g_mwatch[h];
    while true {
        i64 n = 0;
        if w.carry_len > 0 {
            if w.carry_len > cap { return -1; }
            memcpy(out, w.carry, w.carry_len);
            n = w.carry_len;
            w.carry_len = 0;
        }
        if n < cap {
            i64 got = mc_read(w.rd, cast(void*, out + n), cap - n);
            if got <= 0 { return -1; }
            n += got;
        }
        i64 end = n;
        while end > 0 && out[end - 1] != '\n' { end--; }
        bool lost = false;
        if end == 0 {
            // a record longer than cap: it and what follows it up to a
            // newline are dropped, and the batch counts as lost
            lost = true;
        } else if n - end <= MW_CARRY {
            memcpy(w.carry, out + end, n - end);
            w.carry_len = n - end;
        } else {
            lost = true;
        }
        mutex_lock(&w.mx);
        if w.lost { lost = true; }
        w.lost = false;
        mutex_unlock(&w.mx);
        i64 keep = 0;
        i64 i = 0;
        while i < end {
            i64 e = i;
            while out[e] != '\n' { e++; }
            u8 kind = out[i];
            if kind == MW_KIND_STOP { return -1; }
            if kind == MW_KIND_LOST {
                lost = true;
            } else if !lost {
                i64 len = e + 1 - i;
                if keep != i { memmove_bytes(out + keep, out + i, len); }
                keep += len;
            }
            i = e + 1;
        }
        if lost { return 0; }
        if keep > 0 { return keep; }
    }
}

// bytes moved left within one buffer, the order an overlap needs
private void memmove_bytes(u8* dst, u8* src, i64 n) {
    for i64 k = 0; k < n; k++ { dst[k] = src[k]; }
}

void plat_watch_close(i32 h) {
    if h < 0 || h >= MW_MAX || !g_mwatch[h].used { return; }
    MacWatch* w = &g_mwatch[h];
    mutex_lock(&w.mx);
    w.stopping = true;
    mutex_unlock(&w.mx);
    // the reader is in read() only while the pipe is empty, so the stop
    // record fits; otherwise it drains what is there and finds it
    noinit u8[2] rec;
    rec[0] = MW_KIND_STOP;
    rec[1] = '\n';
    ignore mc_write(w.wr, cast(void*, &rec[0]), 2);
}

void plat_watch_free(i32 h) {
    if h < 0 || h >= MW_MAX || !g_mwatch[h].used { return; }
    MacWatch* w = &g_mwatch[h];
    if w.stream != null {
        FSEventStreamStop(w.stream);
        FSEventStreamInvalidate(w.stream);
        FSEventStreamRelease(w.stream);
        w.stream = null;
    }
    if w.queue != null {
        dispatch_release(w.queue);
        w.queue = null;
    }
    mutex_lock(&w.mx);
    w.used = false;
    if w.rd >= 0 { ignore mc_close(w.rd); }
    if w.wr >= 0 { ignore mc_close(w.wr); }
    w.rd = -1;
    w.wr = -1;
    if w.root != null { free(w.root); }
    w.root = null;
    w.root_len = 0;
    if w.carry != null { free(w.carry); }
    w.carry = null;
    w.carry_len = 0;
    mutex_unlock(&w.mx);
}

// directory listing: the stdlib's, this platform has a file system
DirList plat_dir_list(str dir, bool want_dirs) {
    return dir_list(dir, "", want_dirs);
}

private extern "libSystem.B.dylib" {
    i32 chdir(u8* path);
}

bool plat_chdir(str dir) {
    u8* c = str_to_cstr(dir);
    bool ok = chdir(c) == 0;
    free(c);
    return ok;
}

private extern "libSystem.B.dylib" {
    i32 mc_rename(u8* src, u8* dst) from "rename";
}

// a file or folder to the Trash, by its absolute path
bool plat_trash(str path) {
    void* fm = objc.msg_id_v(objc_classref("NSFileManager", "/System/Library/Frameworks/Foundation.framework/Foundation"), objc_selref("defaultManager"));
    void* ns = mac_nsstring(path.data, path.len);
    if fm == null || ns == null { return false; }
    void* url = objc.msg_id_i(objc_classref("NSURL", "/System/Library/Frameworks/Foundation.framework/Foundation"),
        objc_selref("fileURLWithPath:"), ns);
    bool ok = false;
    if url != null {
        ok = cast(fn(void*, void*, void*, void*, void*): bool, objc.raw)(fm,
            objc_selref("trashItemAtURL:resultingItemURL:error:"), url, null, null);
    }
    mac_release(ns);
    return ok;
}

// a Finder window on the folder holding path, with path selected
bool plat_reveal(str path) {
    void* ws = objc.msg_id_v(objc_classref("NSWorkspace", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("sharedWorkspace"));
    void* ns = mac_nsstring(path.data, path.len);
    void* root = mac_nsstring(path.data, 0);
    bool ok = false;
    if ws != null && ns != null && root != null {
        ok = cast(fn(void*, void*, void*, void*): bool, objc.raw)(ws,
            objc_selref("selectFile:inFileViewerRootedAtPath:"), ns, root);
    }
    if ns != null { mac_release(ns); }
    if root != null { mac_release(root); }
    return ok;
}

// the default browser on url
bool plat_open_url(str url) {
    void* ws = objc.msg_id_v(objc_classref("NSWorkspace", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("sharedWorkspace"));
    void* ns = mac_nsstring(url.data, url.len);
    bool ok = false;
    if ws != null && ns != null {
        void* u = objc.msg_id_i(objc_classref("NSURL", "/System/Library/Frameworks/Foundation.framework/Foundation"),
            objc_selref("URLWithString:"), ns);
        if u != null {
            ok = cast(fn(void*, void*, void*): bool, objc.raw)(ws, objc_selref("openURL:"), u);
        }
    }
    if ns != null { mac_release(ns); }
    return ok;
}

// a file or folder to a new name; the caller checks that the target
// does not exist, since rename(2) replaces it
bool plat_file_rename(str src, str dst) {
    u8* cf = str_to_cstr(src);
    u8* ct = str_to_cstr(dst);
    bool ok = mc_rename(cf, ct) == 0;
    free(cf);
    free(ct);
    return ok;
}

private extern "libSystem.B.dylib" {
    i32 _NSGetExecutablePath(u8* buf, u32* size);
}

// the directory holding the running executable, no trailing slash
i32 plat_exe_dir(u8* out, i32 cap) {
    noinit u8[PATH_MAX] buf;
    u32 sz = cast(u32, PATH_MAX);
    if _NSGetExecutablePath(&buf[0], &sz) != 0 { return 0; }
    i32 n = 0;
    while n < PATH_MAX && buf[n] != 0 { n++; }
    i32 last = -1;
    for i32 i = 0; i < n; i++ {
        if buf[i] == '/' { last = i; }
    }
    if last <= 0 { return 0; }
    i32 outn = last;
    if outn > cap { outn = cap; }
    memcpy(out, &buf[0], outn);
    return outn;
}

// --- windows -----------------------------------------------------------

// the Ctrl+K N command: a new window at the default size, cascaded off
// the opener, showing the active file. The source window is left as it is.
i32 plat_window_open() {
    i32 wi = mac_native_create(0, 0, 0, 0, 0, true);
    if wi < 0 { return -1; }
    plat_damage();
    return wi;
}

// restore: a window at a saved frame, no pane move (its panes come
// from the session)
i32 plat_window_open_at(i32 x, i32 y, i32 w, i32 h, i32 maxi) {
    i32 wi = mac_native_create(x, y, w, h, maxi, false);
    plat_damage();
    return wi;
}

// the window's frame in screen points (Cocoa origin, bottom-left):
// opaque to the core, read back by this platform only
bool plat_window_rect(i32 win, i32* x, i32* y, i32* w, i32* h, i32* maxi) {
    if win < 0 || win >= MAC_WIN_MAX || !g_macwin[win].used { return false; }
    void* wnd = g_macwin[win].window;
    CGRect f = cast(fn(void*, void*): CGRect, objc.raw)(wnd, objc_selref("frame"));
    *x = cast(i32, f.origin.x);
    *y = cast(i32, f.origin.y);
    *w = cast(i32, f.size.width);
    *h = cast(i32, f.size.height);
    *maxi = 0;
    if cast(fn(void*, void*): bool, objc.raw)(wnd, objc_selref("isZoomed")) { *maxi = 1; }
    return true;
}

// move/size window `win` to a saved frame (restore of the primary)
void plat_window_set_rect(i32 win, i32 x, i32 y, i32 w, i32 h, i32 maxi) {
    if win < 0 || win >= MAC_WIN_MAX || !g_macwin[win].used { return; }
    void* wnd = g_macwin[win].window;
    if maxi != 0 {
        if !cast(fn(void*, void*): bool, objc.raw)(wnd, objc_selref("isZoomed")) {
            objc.msg_void_i(wnd, objc_selref("zoom:"), null);
        }
        return;
    }
    cast(fn(void*, void*, CGRect, bool): void, objc.raw)(wnd, objc_selref("setFrame:display:"),
        CGRect{ CGPoint{ cast(f64, x), cast(f64, y) }, CGSize{ cast(f64, w), cast(f64, h) } }, true);
}

// --- folder dialog -------------------------------------------------------
// NSOpenPanel in pick-folders mode. runModal runs its own event loop, so
// the request is deferred onto the next run-loop turn through the timer
// target (onPickFolder:), and the panel opens once the event that asked
// has returned: no editor entry is on the stack while that loop runs.
// The mirror of the Windows driver's posted WM_PICK_FOLDER.
private const i64 NSModalResponseOK = 1;

bool plat_pick_folder() {
    if mac_timer_target == null { return false; }
    cast(fn(void*, void*, void*, void*, bool): void, objc.raw)(mac_timer_target,
        objc_selref("performSelectorOnMainThread:withObject:waitUntilDone:"),
        objc_selref("onPickFolder:"), null, false);
    return true;
}

// the recent folders changed; the shell's list for the app follows
// (the Windows taskbar's jump list), nothing here yet
void plat_recent_folders(str* dirs, i32 n) {}

// the deferred half: the panel, then the reply (len 0 on cancel)
void mac_pick_folder_fired(void* self, void* _cmd, void* arg) {
    void* panel = objc.msg_id_v(objc_classref("NSOpenPanel", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("openPanel"));
    if panel == null {
        app_folder_picked(null, 0);
        return;
    }
    objc.msg_void_b(panel, objc_selref("setCanChooseDirectories:"), true);
    objc.msg_void_b(panel, objc_selref("setCanChooseFiles:"), false);
    objc.msg_void_b(panel, objc_selref("setAllowsMultipleSelection:"), false);
    objc.msg_void_b(panel, objc_selref("setCanCreateDirectories:"), true);
    str t = "Open Folder";
    void* title = mac_nsstring(t.data, t.len);
    if title != null {
        objc.msg_void_i(panel, objc_selref("setTitle:"), title);
        objc.msg_void_i(panel, objc_selref("setMessage:"), title);
        mac_release(title);
    }
    str pr = "Open";
    void* prompt = mac_nsstring(pr.data, pr.len);
    if prompt != null {
        objc.msg_void_i(panel, objc_selref("setPrompt:"), prompt);
        mac_release(prompt);
    }
    i64 resp = objc.msg_q_v(panel, objc_selref("runModal"));
    u8* path = null;
    i64 len = 0;
    if resp == NSModalResponseOK {
        void* urls = objc.msg_id_v(panel, objc_selref("URLs"));
        if urls != null && objc.msg_q_v(urls, objc_selref("count")) > 0 {
            void* url = objc.msg_id_q(urls, objc_selref("objectAtIndex:"), 0);
            void* ns = null;
            if url != null { ns = objc.msg_id_v(url, objc_selref("path")); }
            if ns != null { path = cast(u8*, objc.msg_id_v(ns, objc_selref("UTF8String"))); }
        }
    }
    if path != null {
        while path[len] != 0 { len++; }
    }
    // the panel and its strings belong to this turn's autorelease pool;
    // the reply reads the path before it drains
    app_folder_picked(path, cast(i32, len));
}

// --- save dialog ---------------------------------------------------------
// NSSavePanel, deferred the same way through onPickSave:. The starting
// folder and the file name are held from the request to the panel.
private const i32 MAC_SAVE_MAX = 4096;
private u8[MAC_SAVE_MAX] mac_save_dir;
private i32 mac_save_dir_len = 0;
private u8[MAC_SAVE_MAX] mac_save_name;
private i32 mac_save_name_len = 0;

bool plat_pick_save(str dir, str name) {
    if mac_timer_target == null { return false; }
    mac_save_dir_len = 0;
    if dir.len < MAC_SAVE_MAX {
        memcpy(&mac_save_dir[0], dir.data, dir.len);
        mac_save_dir_len = dir.len;
    }
    mac_save_name_len = 0;
    if name.len < MAC_SAVE_MAX {
        memcpy(&mac_save_name[0], name.data, name.len);
        mac_save_name_len = name.len;
    }
    cast(fn(void*, void*, void*, void*, bool): void, objc.raw)(mac_timer_target,
        objc_selref("performSelectorOnMainThread:withObject:waitUntilDone:"),
        objc_selref("onPickSave:"), null, false);
    return true;
}

// the deferred half: the panel, then the reply (len 0 on cancel)
void mac_pick_save_fired(void* self, void* _cmd, void* arg) {
    void* panel = objc.msg_id_v(objc_classref("NSSavePanel", "/System/Library/Frameworks/AppKit.framework/AppKit"), objc_selref("savePanel"));
    if panel == null {
        app_save_picked(null, 0);
        return;
    }
    objc.msg_void_b(panel, objc_selref("setCanCreateDirectories:"), true);
    str t = "Save As";
    void* title = mac_nsstring(t.data, t.len);
    if title != null {
        objc.msg_void_i(panel, objc_selref("setTitle:"), title);
        mac_release(title);
    }
    if mac_save_dir_len > 0 {
        void* ds = mac_nsstring(&mac_save_dir[0], mac_save_dir_len);
        if ds != null {
            void* url = objc.msg_id_i(objc_classref("NSURL", "/System/Library/Frameworks/Foundation.framework/Foundation"),
                objc_selref("fileURLWithPath:"), ds);
            if url != null { objc.msg_void_i(panel, objc_selref("setDirectoryURL:"), url); }
            mac_release(ds);
        }
    }
    if mac_save_name_len > 0 {
        void* ns = mac_nsstring(&mac_save_name[0], mac_save_name_len);
        if ns != null {
            objc.msg_void_i(panel, objc_selref("setNameFieldStringValue:"), ns);
            mac_release(ns);
        }
    }
    i64 resp = objc.msg_q_v(panel, objc_selref("runModal"));
    u8* path = null;
    i64 len = 0;
    if resp == NSModalResponseOK {
        void* url = objc.msg_id_v(panel, objc_selref("URL"));
        void* ns = null;
        if url != null { ns = objc.msg_id_v(url, objc_selref("path")); }
        if ns != null { path = cast(u8*, objc.msg_id_v(ns, objc_selref("UTF8String"))); }
    }
    if path != null {
        while path[len] != 0 { len++; }
    }
    app_save_picked(path, cast(i32, len));
}
