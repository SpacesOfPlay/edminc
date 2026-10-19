// macwatch_probe.mc - the macOS file watcher against the real file
// system, headless: the FSEvents layer's check. It links the real
// lib/mac.mc, watches a scratch folder under build/, changes it from
// this process, and prints the records plat_watch_read returns. It
// exits 1 when a record it expects is missing. Run from the repo root:
//
//   minc scripts/macwatch_probe.mc -o build/macwatch_probe && build/macwatch_probe
//
// The stream delivers on its own queue, so no run loop is needed; the
// read blocks on the pipe until the records are in.

import str;
import file;
import thread;
import plat;
import theme;
import headless;
import mac;
import "../src/term.mc";

// the core symbols mac.mc reaches, none of which this probe needs
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
// ...and the headless module's, which mac.mc links for the restart
void app_key(i32 key, i32 mods) {}
void app_char(u32 cp) {}
void app_settle() {}
const i32 PLAY_MS_DEFAULT = 20;
bool lsp_trace = false;
i32 ed_term_shown() { return 0 - 1; }
i32 ed_term_dump(u8* buf, i32 cap) { return 0; }
void plat_sleep_ms(u32 ms) { ignore usleep(ms * 1000); }
void app_folder_arg() {}
void settings_use_theme(str name) {}

private void mac_wake_fired(void* self, void* _cmd, void* arg) {}
private void probe_objc_setup() {
    objc_runtime_init();
    void* tt = objc_allocateClassPair(objc_classref("NSObject", "/System/Library/Frameworks/Foundation.framework/Foundation"), "ProbeTimerTarget", 0);
    ignore class_addMethod(tt, objc_selref("onWake:"), cast(void*, &mac_wake_fired), OBJC_ENC_v_i);
    ignore class_addMethod(tt, objc_selref("onTimer:"), cast(void*, &mac_wake_fired), OBJC_ENC_v_i);
    objc_registerClassPair(tt);
    mac_set_timer_target(objc.msg_id_v(objc.msg_id_v(objc_getClass("ProbeTimerTarget"), objc_selref("alloc")), objc_selref("init")));
}

private extern "libSystem.B.dylib" {
    void* fopen(u8* path, u8* mode);
    u64 fwrite(void* buf, u64 size, u64 n, void* f);
    i32 fclose(void* f);
    i32 usleep(u32 us);
    i32 mkdir(u8* path, u32 mode);
    i32 rename(u8* a, u8* b);
    i32 unlink(u8* path);
    i32 rmdir(u8* path);
}

private const str ROOT = "build/watch_probe";
private const u32 READ_CAP = 65536;

// term.mc formats numbers with the core's helper; this probe drives no
// terminal, and a plain one satisfies the link
i32 fmt_i32(u8* dst, i32 v) {
    i32 n = 0;
    if v < 0 {
        dst[0] = '-';
        n = 1;
        v = 0 - v;
    }
    noinit u8[12] d;
    i32 k = 0;
    if v == 0 { d[0] = '0'; k = 1; }
    while v > 0 {
        d[k] = cast(u8, '0' + v % 10);
        v = v / 10;
        k++;
    }
    while k > 0 {
        k--;
        dst[n] = d[k];
        n++;
    }
    return n;
}

// a path under the scratch folder, in a buffer of its own per call site
private u8[2048] g_pj;
private i32 g_pj_i = 0;
private str pj(str tail) {
    u8* b = &g_pj[g_pj_i * 512];
    g_pj_i = (g_pj_i + 1) % 4;
    memcpy(b, ROOT.data, ROOT.len);
    memcpy(b + ROOT.len, tail.data, tail.len);
    return str_from(b, ROOT.len + tail.len);
}

private u8[READ_CAP] g_rec;
private i64 g_rec_n = 0;
private i32 g_fails = 0;

private void put(str path, str text) {
    FileData fd = FileData{ text.data, cast(i64, text.len) };
    if !file_write(path, fd) { print("write failed: {}\n", path); }
}

// a rewrite in place, the way a plain save writes: the stdlib's
// file_write may make the file anew, which the stream reports as
// created
private void put_inplace(str path, str text) {
    u8* c = str_to_cstr(path);
    void* f = fopen(c, "w");
    free(c);
    if f == null { print("fopen failed: {}\n", path); return; }
    ignore fwrite(cast(void*, text.data), 1, cast(u64, text.len), f);
    ignore fclose(f);
}

private void c_call_mkdir(str p) {
    u8* c = str_to_cstr(p);
    ignore mkdir(c, 0x1ED);   // 0755
    free(c);
}

private void c_call_rename(str a, str b) {
    u8* ca = str_to_cstr(a);
    u8* cb = str_to_cstr(b);
    ignore rename(ca, cb);
    free(ca);
    free(cb);
}

private void c_call_unlink(str p, bool dir) {
    u8* c = str_to_cstr(p);
    if dir { ignore rmdir(c); } else { ignore unlink(c); }
    free(c);
}

// the reader, as the editor runs it: one thread in plat_watch_read
// until the close ends it, the records appended under a lock
private Mutex g_mx;
private bool g_lost = false;
private bool g_ended = false;

private void reader_thread(void* arg) {
    i32 h = cast(i32, cast(i64, arg));
    noinit u8[READ_CAP] buf;
    while true {
        i64 n = plat_watch_read(h, &buf[0], READ_CAP);
        if n < 0 { break; }
        mutex_lock(&g_mx);
        if n == 0 { g_lost = true; }
        if n > 0 && g_rec_n + n <= READ_CAP {
            memcpy(&g_rec[g_rec_n], &buf[0], n);
            g_rec_n += n;
        }
        mutex_unlock(&g_mx);
    }
    g_ended = true;
}

private bool have(str rec) {
    i64 i = 0;
    while i < g_rec_n {
        i64 e = i;
        while e < g_rec_n && g_rec[e] != '\n' { e++; }
        if str_equal(str_from(&g_rec[i], cast(i32, e - i)), rec) { return true; }
        i = e + 1;
    }
    return false;
}

private void expect(str rec) {
    if have(rec) {
        print("ok   {}\n", rec);
    } else {
        print("FAIL missing record: {}\n", rec);
        g_fails++;
    }
}

i32 main() {
    probe_objc_setup();
    mutex_init(&g_mx);
    c_call_unlink(pj("/sub/b.txt"), false);
    c_call_unlink(pj("/sub"), true);
    c_call_unlink(pj("/a.txt"), false);
    c_call_unlink(pj("/c.txt"), false);
    c_call_mkdir("build");
    c_call_mkdir(ROOT);
    // a file from before the watch: the stream carries Created for a
    // file made recently on every later write too, so the one whose
    // rewrite must read as a plain content change is kept across runs
    // and made only when missing. The first run makes it and reports
    // that; the second run is the check.
    bool pre_is_old = file_size(pj("/pre.txt")) >= 0;
    if !pre_is_old { put(pj("/pre.txt"), "pre\n"); }
    i32 h = plat_watch_open(ROOT);
    if h < 0 {
        print("FAIL plat_watch_open returned {}\n", h);
        return 1;
    }
    Thread t;
    thread_create(&t, reader_thread, cast(void*, cast(i64, h)));
    ignore usleep(200000);
    // a file created, then rewritten after the stream's latency has
    // passed, so the two are two events
    put(pj("/a.txt"), "one\n");
    ignore usleep(300000);
    put_inplace(pj("/pre.txt"), "changed\n");
    ignore usleep(300000);
    c_call_mkdir(pj("/sub"));
    put(pj("/sub/b.txt"), "b\n");
    ignore usleep(300000);
    c_call_rename(pj("/a.txt"), pj("/c.txt"));
    ignore usleep(300000);
    c_call_unlink(pj("/c.txt"), false);
    ignore usleep(500000);
    // the close ends the blocked read, and the thread with it
    plat_watch_close(h);
    thread_join(&t);
    plat_watch_free(h);
    print("-- records ({} bytes, lost {}):\n{}", g_rec_n, g_lost, str_from(&g_rec[0], cast(i32, g_rec_n)));
    expect("ma.txt");
    if pre_is_old {
        expect("cpre.txt");
    } else {
        print("note pre.txt is new: run again for the content-change check\n");
    }
    expect("msub");
    expect("msub/b.txt");
    expect("mc.txt");
    if !g_ended {
        print("FAIL the close must end the read\n");
        g_fails++;
    }
    c_call_unlink(pj("/sub/b.txt"), false);
    c_call_unlink(pj("/sub"), true);   // pre.txt and the folder stay for the next run
    if g_fails > 0 {
        print("macwatch_probe: {} FAILED\n", g_fails);
        return 1;
    }
    print("macwatch_probe: ok\n");
    return 0;
}
