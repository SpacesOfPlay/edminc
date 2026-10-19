// web.mc - the browser platform: the page's imports and the plat_*
// services on them. The page (web/edminc_host.js) implements the
// "host" imports and calls the exported web_* entries in plat_web.mc.
// Single-threaded by design: no workers, no processes. The language
// server, when the page has one, is a worker the page talks to, and
// its bytes arrive through web_lsp_recv. Integers cross the boundary
// as i32 on purpose; the page sees plain numbers.

extern "host" {
    void host_damage();
    void host_set_timer(i32 id, i32 ms);
    void host_kill_timer(i32 id);
    i64 host_time_us();
    void host_set_title(u8* p, i32 n);
    void host_clipboard_set(u8* p, i32 n);
    // bytes copied, 0 when empty, -needed when cap falls short
    i32 host_clipboard_get(u8* buf, i32 cap);
    void host_quit();
    void host_open_url(u8* p, i32 n);
    void host_wake();
    i32 host_cwd(u8* buf, i32 cap);
    // "name\n" per entry directly inside dir; bytes written, or -needed
    i32 host_dir_list(u8* dir, i32 dn, i32 want_dirs, u8* buf, i32 cap);
    // 1 when the page has a language server to talk to
    i32 host_lsp_start();
    void host_lsp_send(u8* p, i32 n);
    void host_lsp_stop();
}

void plat_damage() {
    host_damage();
}

// one window here
void plat_damage_window(i32 win) {
    host_damage();
}

void plat_set_timer(i32 id, i32 ms) {
    host_set_timer(id, ms);
}

void plat_kill_timer(i32 id) {
    host_kill_timer(id);
}

i64 plat_time_us() {
    return host_time_us();
}

void plat_set_title(str s) {
    host_set_title(s.data, s.len);
}

void plat_quit() {
    host_quit();
}

// the page schedules app_wake on its own loop, which keeps the async
// shape the workers have on the native platforms
void plat_wake() {
    host_wake();
}

i32 plat_cwd(u8* buf, i32 cap) {
    return host_cwd(buf, cap);
}

void plat_clipboard_set(u8* s, i64 n) {
    host_clipboard_set(s, cast(i32, n));
}

// the page hands over the text of the last paste; a second call when
// the first guess at the size falls short
u8* plat_clipboard_get(i64* out_len) {
    i32 cap = 4096;
    u8* buf = alloc<u8>(cap);
    i32 n = host_clipboard_get(buf, cap);
    if n < 0 {
        free(buf);
        cap = -n;
        buf = alloc<u8>(cap);
        n = host_clipboard_get(buf, cap);
    }
    if n <= 0 {
        free(buf);
        *out_len = 0;
        return null;
    }
    *out_len = cast(i64, n);
    return buf;
}

// no processes in a browser, so no git: the gutter stays off
u8* plat_run_capture(str* argv, i32 argc, i64* out_len, i32* out_code) {
    *out_len = 0;
    *out_code = -1;
    return null;
}

// the language server is the page's, when it has one; slot 0 is the
// only one the page serves
bool plat_child_spawn(i32 k, str* argv, i32 argc) {
    if k != 0 { return false; }
    return host_lsp_start() != 0;
}

i64 plat_child_write(i32 k, u8* p, i64 n) {
    if k != 0 { return -1; }
    host_lsp_send(p, cast(i32, n));
    return n;
}

// never reached: there is no reader thread here, the page pushes
i64 plat_child_read(i32 k, u8* p, i64 cap) {
    return 0;
}

void plat_child_kill(i32 k) {
    if k == 0 { host_lsp_stop(); }
}

// the page has no pseudo-terminal, and will not: a terminal pane
// answers that it cannot open here
i32 plat_term_spawn(i32 cols, i32 rows, str* argv, i32 argc, bool under) { return -1; }
i64 plat_term_read(i32 h, u8* buf, i64 cap) { return -1; }
i64 plat_term_write(i32 h, u8* p, i64 n) { return -1; }
i32 plat_term_code(i32 h) { return -1; }
void plat_term_resize(i32 h, i32 cols, i32 rows) {}
void plat_term_kill(i32 h) {}
void plat_term_free(i32 h) {}
u32 plat_term_palette(u32* out, i32 n) { return 0; }

// no file watcher on this platform yet: the editor refreshes on its own
// saves only, and a save still checks the file on disk first
i32 plat_watch_open(str dir) { return -1; }
i64 plat_watch_read(i32 h, u8* buf, i64 cap) { return -1; }
void plat_watch_close(i32 h) {}
void plat_watch_free(i32 h) {}
i32 plat_exe_path(u8* out, i32 cap) { return 0; }
bool plat_exec_self(str exe, str* argv, i32 argc) { return false; }
bool plat_term_export(i32 h, i64* fd, i32* pid) { return false; }
i32 plat_term_adopt(i64 fd, i32 pid) { return -1; }

// entries directly inside `dir`, from the page's file system, in the
// stdlib's DirList shape so dir_list_free takes it
DirList plat_dir_list(str dir, bool want_dirs) {
    DirList l;
    i32 cap = 8192;
    u8* buf = alloc<u8>(cap);
    i32 wd = 0;
    if want_dirs { wd = 1; }
    i32 n = host_dir_list(dir.data, dir.len, wd, buf, cap);
    if n < 0 {
        free(buf);
        cap = -n;
        buf = alloc<u8>(cap);
        n = host_dir_list(dir.data, dir.len, wd, buf, cap);
    }
    i32 count = 0;
    for i32 i = 0; i < n; i++ {
        if buf[i] == '\n' { count++; }
    }
    if count > 0 {
        l.items = alloc<str>(count);
        i32 s = 0;
        for i32 i = 0; i < n; i++ {
            if buf[i] != '\n' { continue; }
            i32 len = i - s;
            u8* copy = alloc<u8>(len + 1);
            memcpy(copy, buf + s, len);
            copy[len] = 0;
            l.items[l.count] = str_from(copy, len);
            l.count++;
            s = i + 1;
        }
        l._cap = count;
    }
    free(buf);
    return l;
}

// the page holds one project; there is no other folder to go to
bool plat_chdir(str dir) {
    return false;
}

// the page's file map has no rename
bool plat_file_rename(str src, str dst) {
    return false;
}

// no trash and no file manager in the page
bool plat_trash(str path) {
    return false;
}

bool plat_reveal(str path) {
    return false;
}

bool plat_open_url(str url) {
    host_open_url(url.data, url.len);
    return true;
}

// no executable path in the browser; assets come from the vfs at "assets"
i32 plat_exe_dir(u8* out, i32 cap) {
    return 0;
}

// the page has one window; a no-op
i32 plat_window_open() {
    return -1;
}

bool plat_window_rect(i32 win, i32* x, i32* y, i32* w, i32* h, i32* maxi) {
    return false;
}
i32 plat_window_open_at(i32 x, i32 y, i32 w, i32 h, i32 maxi) {
    return -1;
}
void plat_window_set_rect(i32 win, i32 x, i32 y, i32 w, i32 h, i32 maxi) {
}

bool plat_pick_folder() {
    return false;
}

bool plat_pick_save(str dir, str name) {
    return false;
}

// the recent folders changed; the shell's list for the app follows
// (the Windows taskbar's jump list), nothing here yet
void plat_recent_folders(str* dirs, i32 n) {}
