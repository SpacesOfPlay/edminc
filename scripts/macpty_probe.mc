// macpty_probe.mc - the macOS pseudo-terminal layer against a real
// shell, headless: the pty layer's check. It links the real
// lib/mac.mc and src/term.mc, opens the user's shell at 80x24, and
// walks the same stages the Windows probe recorded (prompt, a command,
// history recall, completion, a resize, a burst, idle, kill), printing
// the screen the emulator built after each. Run from the repo root:
//
//   minc scripts/macpty_probe.mc -o build/macpty_probe && build/macpty_probe
//
// Everything the reader thread posts is coalesced through plat_wake
// into one pump per turn, as the editor does; each stage waits for the
// shell to go quiet rather than for a fixed time.

import str;
import file;
import thread;
import plat;
import theme;
import mac;
import "../src/term.mc";

// the core symbols mac.mc and term.mc reach; only fmt_i32 is used
i32 font_line_h = 20;
void app_timer(i32 id) {}
bool play_timer(i32 id) { return false; }
void app_folder_picked(u8* path, i32 len) {}
void app_use_window(i32 i) {}
i32 ed_window_active() { return 0; }
void gpu_bind(i32 id) {}
i32 mac_native_create(i32 x, i32 y, i32 w, i32 h, i32 maxi, bool cascade) { return 0 - 1; }
void app_wake() {}
void app_save_picked(u8* path, i32 len) {}
void* gpu_fetch_drawable(i32 gpu) { return null; }
void gpu_pending_set(i32 gpu, void* d) {}
void gpu_pending_drop(i32 gpu) {}
i32 hl_restart_arg_count() { return 0; }
str hl_restart_arg(i32 i) { return ""; }
i32 fmt_i32(u8* dst, i32 v) {
    if v == 0 { dst[0] = '0'; return 1; }
    u8[16] tmp;
    i32 n = 0;
    while v > 0 { tmp[n] = cast(u8, '0' + v % 10); v /= 10; n++; }
    for i32 i = 0; i < n; i++ { dst[i] = tmp[n - 1 - i]; }
    return n;
}

// the reader thread posts plat_wake onto the main thread's run loop
// through the timer target, so the objc runtime and that target have
// to exist as they do under plat_main; this probe polls instead of
// running the loop, so the posted wake is never delivered and the
// pump is asked on a clock
private void mac_wake_fired(void* self, void* _cmd, void* arg) {}
private void probe_objc_setup() {
    objc_runtime_init();
    // NSObject from Foundation, not the bare runtime's: the wake is
    // performSelectorOnMainThread:, a Foundation method
    void* tt = objc_allocateClassPair(objc_classref("NSObject", "/System/Library/Frameworks/Foundation.framework/Foundation"), "ProbeTimerTarget", 0);
    ignore class_addMethod(tt, objc_selref("onWake:"), cast(void*, &mac_wake_fired), OBJC_ENC_v_i);
    ignore class_addMethod(tt, objc_selref("onTimer:"), cast(void*, &mac_wake_fired), OBJC_ENC_v_i);
    objc_registerClassPair(tt);
    mac_set_timer_target(objc.msg_id_v(objc.msg_id_v(objc_getClass("ProbeTimerTarget"), objc_selref("alloc")), objc_selref("init")));
}

private extern "libSystem.B.dylib" {
    i32 usleep(u32 us);
}

private i32 g_t = 0 - 1;

private void show(str what) {
    noinit u8[16384] g;
    i32 n = term_dump(g_t, &g[0], 16384);
    print("== {}\n-- screen {}x{}, cursor {},{}", what, term_cols(g_t), term_rows(g_t), term_cx(g_t), term_cy(g_t));
    if term_alt(g_t) { print(", alternate"); }
    print(", title [{}]\n", term_title(g_t));
    i32 start = 0;
    for i32 i = 0; i <= n; i++ {
        if i == n || g[i] == 10 {
            print("   |{}|\n", str_from(&g[start], i - start));
            start = i + 1;
        }
    }
    str broke = term_check(g_t);
    if broke.len > 0 { print("!! {}\n", broke); }
}

// pump until the shell has been quiet for `quiet_ms`, or `max_ms` passes;
// returns the bytes-arrived count of pumps
private i32 settle(i32 quiet_ms, i32 max_ms) {
    i32 waited = 0;
    i32 quiet = 0;
    i32 pumps = 0;
    while waited < max_ms {
        // the wake is posted onto the main thread's run loop, which this
        // probe does not run; the flag is polled instead
        bool got = term_pump() != 0;
        if got { pumps++; quiet = 0; } else { quiet += 10; }
        if quiet >= quiet_ms { break; }
        if term_exited(g_t) { break; }
        usleep(10000);
        waited += 10;
    }
    return pumps;
}

private void send(str s) { term_send(g_t, s.data, cast(i64, s.len)); }

i32 main() {
    probe_objc_setup();
    g_t = term_open(80, 24);
    if g_t < 0 {
        print("macpty-probe: no pseudo-terminal\n");
        return 1;
    }
    i64 t0 = plat_time_us();
    i32 p = settle(400, 5000);
    print("-- start: {} pumps, {} ms\n", p, (plat_time_us() - t0) / 1000);
    show("stage 0: the prompt");

    send("echo hello-from-$0-cols-$COLUMNS\r");
    p = settle(300, 3000);
    show("stage 1: a command");

    send("\x1b[A");   // up arrow: history recall
    p = settle(300, 2000);
    show("stage 2: history recall (up arrow)");
    send("\x03");     // ctrl+c abandons the line
    ignore settle(300, 2000);

    send("ec\t");     // completion
    p = settle(300, 2000);
    show("stage 3: completion (ec, tab)");
    send("\x03");
    ignore settle(300, 2000);

    term_resize(g_t, 100, 30);
    send("echo cols-now-$COLUMNS-rows-$LINES\r");
    p = settle(300, 3000);
    show("stage 4: resize to 100x30, the shell sees it");

    send("seq 1 20000\r");
    t0 = plat_time_us();
    p = settle(500, 20000);
    print("-- burst: {} pumps, {} ms\n", p, (plat_time_us() - t0) / 1000);
    show("stage 5: after a burst of 20000 lines");

    send("clear; vi -c q /dev/null; echo alt-done\r");
    p = settle(500, 4000);
    show("stage 6: vi entered and left the alternate screen");

    t0 = plat_time_us();
    p = settle(1500, 2000);
    print("-- idle: {} pumps in {} ms (0 = quiet)\n", p, (plat_time_us() - t0) / 1000);

    t0 = plat_time_us();
    term_close(g_t);
    print("-- kill returned in {} ms\n", (plat_time_us() - t0) / 1000);
    return 0;
}
