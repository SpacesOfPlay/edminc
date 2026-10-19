// ed_test.mc - headless test of the portable editor core: real
// text_buf/lexer/ed/pick/find with stubbed platform
// services, driven through the app_* entry points. No window, so it
// runs anywhere, including a session without an interactive desktop.
//
// Compile from the repo root: minc scripts/ed_test.mc -o build/ed_test
// Exit 0 = all checks pass.

import file;
import plat;
import theme;
import ui;
import text_buf;
import git;
import lexer;
import json;
import lsp;
import lsp_shadow;
import harness_plat;
import sem;
import build;
import term;
import watch;
import wrap;
import ed;
import evscript;
import play;
import gitignore;
import pick;
import tree;
import menu;
import search;
import find;
import complete;
import symbols;
import switcher;
import palette;
import settings;
import recent;
import explode;
import calls;
import image;
import hist;

// --- platform + renderer stubs ---------------------------------------

i32 font_line_h = 22;
i32 font_cell_w = 9;
i32 font_ascent = 16;

// A clock that advances only when read, so runs are deterministic. The
// step decides whether two presses in a row read as a double click.
i64 g_clock_step = 500000;
private i64 g_clock_us = 0;
i64 plat_time_us() {
    g_clock_us += g_clock_step;
    return g_clock_us;
}
i32 g_damage_calls = 0;
void plat_damage() { g_damage_calls++; }
i32 g_damage_window_calls = 0;
i32 g_damage_window_last = -1;
void plat_damage_window(i32 win) {
    g_damage_window_calls++;
    g_damage_window_last = win;
}
// images: a handle per texture, nothing drawn
i32 g_gpu_images = 0;
i32 gpu_image_create(u8* rgba, i32 w, i32 h) {
    g_gpu_images++;
    return g_gpu_images;
}
void gpu_image_free(i32 h) {}

// the notice's one-shot timer, so a check can see it armed and fire it
bool g_notice_timer = false;
bool g_drag_timer = false;
void plat_set_timer(i32 id, i32 ms) {
    if id == NOTICE_TIMER { g_notice_timer = true; }
    if id == DRAG_SCROLL_TIMER { g_drag_timer = true; }
}
void plat_kill_timer(i32 id) {
    if id == NOTICE_TIMER { g_notice_timer = false; }
    if id == DRAG_SCROLL_TIMER { g_drag_timer = false; }
}
u8[300] g_test_title;
i32 g_test_title_len = 0;
void plat_set_title(str t) {
    i32 n = t.len;
    if n > 300 { n = 300; }
    memcpy(&g_test_title[0], t.data, n);
    g_test_title_len = n;
}
// build/no_such_file_<n>.mc: a path that does not exist, which opens
// as an empty new-file buffer without touching the disk
private u8[64] nofile_buf;
private str nofile(i32 n) {
    str pre = "build/no_such_file_";
    i32 bn = 0;
    for i32 k = 0; k < pre.len; k++ {
        nofile_buf[bn] = pre.data[k];
        bn++;
    }
    bn += fmt_i32(&nofile_buf[bn], n);
    str sfx = ".mc";
    for i32 k = 0; k < sfx.len; k++ {
        nofile_buf[bn] = sfx.data[k];
        bn++;
    }
    return str_from(&nofile_buf[0], bn);
}

// the tree's row for a path, -1 when it is not listed
private i32 tree_row_of(str path) {
    i32 row = -1;
    for i32 i = 0; i < tree_row_count(); i++ {
        if str_equal(tree_row_path(i), path) { row = i; }
    }
    return row;
}

// one pane and one clean untitled buffer, whatever came before: a
// dirty close arms, the second press discards
private void close_all() {
    while ed_pane_count() > 1 {
        ignore ed_pane_close();
    }
    while ed_buf_count() > 1 {
        app_key('W', MOD_CTRL);
        app_key('W', MOD_CTRL);
    }
    app_key('W', MOD_CTRL);
    app_key('W', MOD_CTRL);
}

// little-endian i32 into a hand-made event script
private i32 sc_put32(u8* p, i32 at, i32 v) {
    p[at] = cast(u8, v & 0xFF);
    p[at + 1] = cast(u8, (v >> 8) & 0xFF);
    p[at + 2] = cast(u8, (v >> 16) & 0xFF);
    p[at + 3] = cast(u8, (v >> 24) & 0xFF);
    return at + 4;
}

void plat_quit() {}

// the dialog is a stub with a switch: the test plays the platform
// with one, counts the asks, and feeds the reply itself
bool g_pick_native = false;
i32 g_pick_asks = 0;
// the harness has no native windows; do the core half the real driver
// does, so the ctrl+k n chord can be checked end to end
// the harness records each window's rect so the session round trip can
// be checked without native windows
i32[8] g_wr_x;
i32[8] g_wr_y;
i32[8] g_wr_w;
i32[8] g_wr_h;
i32[8] g_wr_maxi;
bool plat_window_rect(i32 win, i32* x, i32* y, i32* w, i32* h, i32* maxi) {
    if win < 0 || win >= 8 { return false; }
    *x = g_wr_x[win];
    *y = g_wr_y[win];
    *w = g_wr_w[win];
    *h = g_wr_h[win];
    *maxi = g_wr_maxi[win];
    return true;
}
i32 plat_window_open_at(i32 x, i32 y, i32 w, i32 h, i32 maxi) {
    i32 wi = ed_window_new(ed_buf_active());
    if wi < 0 { return -1; }
    g_wr_x[wi] = x;
    g_wr_y[wi] = y;
    g_wr_w[wi] = w;
    g_wr_h[wi] = h;
    g_wr_maxi[wi] = maxi;
    return wi;
}
void plat_window_set_rect(i32 win, i32 x, i32 y, i32 w, i32 h, i32 maxi) {
    if win < 0 || win >= 8 { return; }
    g_wr_x[win] = x;
    g_wr_y[win] = y;
    g_wr_w[win] = w;
    g_wr_h[win] = h;
    g_wr_maxi[win] = maxi;
}

i32 g_winopen_calls = 0;
i32 plat_window_open() {
    g_winopen_calls++;
    i32 wi = ed_window_new(ed_buf_active());
    if wi < 0 { return -1; }
    return wi;
}

bool plat_pick_folder() {
    g_pick_asks++;
    return g_pick_native;
}

// the save dialog: the same switch; the request's folder is recorded
bool g_save_native = false;
i32 g_save_asks = 0;
u8[512] g_save_dir;
i32 g_save_dir_len = 0;

// the rename as a copy and a delete, which the stdlib can do on every
// host: the drivers' own rename is one system call
bool plat_file_rename(str src, str dst) {
    if path_exists(dst) { return false; }
    if !path_is_dir(src) {
        FileData fd = file_read(src);
        if fd.data == null { return false; }
        bool ok = file_write(dst, fd);
        free(fd.data);
        if ok { test_remove(src); }
        return ok;
    }
    if !dir_create(dst) { return false; }
    for i32 pass = 0; pass < 2; pass++ {
        DirList dl = dir_list(src, "", pass == 1);
        for i32 i = 0; i < dl.count; i++ {
            string a = path_join(src, dl.items[i]);
            string b = path_join(dst, dl.items[i]);
            ignore plat_file_rename(str_from(a.data, a.len), str_from(b.data, b.len));
            free(a);
            free(b);
        }
        dir_list_free(&dl);
    }
    return dir_remove(src);
}

// the trash deletes here, and records the path it was given; the
// reveal only records
u8[512] g_trash_last;
i32 g_trash_last_len = 0;
u8[512] g_reveal_last;
i32 g_reveal_last_len = 0;

bool plat_trash(str path) {
    if path.len >= 512 { return false; }
    memcpy(&g_trash_last[0], path.data, path.len);
    g_trash_last_len = path.len;
    // the absolute path is under the stub's working directory; the file
    // is at the rest of it, from where the harness runs
    noinit u8[PATH_MAX] cwd;
    i32 cn = plat_cwd(&cwd[0], PATH_MAX);
    if path.len <= cn + 1 { return false; }
    for i32 i = 0; i < cn; i++ {
        u8 a = path.data[i];
        u8 b = cwd[i];
        if a == 92 { a = '/'; }
        if b == 92 { b = '/'; }
        if a != b { return false; }
    }
    noinit u8[512] rel;
    i32 rn = path.len - cn - 1;
    for i32 i = 0; i < rn; i++ {
        u8 c = path.data[cn + 1 + i];
        if c == 92 { c = '/'; }
        rel[i] = c;
    }
    str rp = str_from(&rel[0], rn);
    if path_is_dir(rp) { return dir_remove(rp); }
    test_remove(rp);
    return !path_exists(rp);
}

u8[512] g_url_last;
i32 g_url_last_len = 0;

bool plat_open_url(str url) {
    if url.len >= 512 { return false; }
    memcpy(&g_url_last[0], url.data, url.len);
    g_url_last_len = url.len;
    return true;
}

bool plat_reveal(str path) {
    if path.len >= 512 { return false; }
    memcpy(&g_reveal_last[0], path.data, path.len);
    g_reveal_last_len = path.len;
    return true;
}

bool plat_pick_save(str dir, str name) {
    g_save_asks++;
    g_save_dir_len = 0;
    if dir.len < 512 {
        memcpy(&g_save_dir[0], dir.data, dir.len);
        g_save_dir_len = dir.len;
    }
    return g_save_native;
}

// the recent folders as the shell's list would get them
i32 g_recent_pushes = 0;
void plat_recent_folders(str* dirs, i32 n) { g_recent_pushes++; }

// a Windows-shaped workspace root: backslashes and a drive letter are
// what the LSP uri round-trip has to survive
// after a recorded plat_chdir the last component is the folder asked for
i32 plat_cwd(u8* buf, i32 cap) {
    str cwd = "C:\\w";
    if cap < cwd.len + 1 + g_chdir_last_len { return 0; }
    memcpy(buf, cwd.data, cwd.len);
    i32 n = cwd.len;
    if g_chdir_last_len > 0 {
        buf[n] = 92;
        n++;
        memcpy(buf + n, &g_chdir_last[0], g_chdir_last_len);
        n += g_chdir_last_len;
    }
    return n;
}
void plat_wake() {}

// captured child stdin, for asserting outgoing LSP traffic
u8[65536] tc_child;
i64 tc_child_len = 0;
u8[65536] tc_child1;   // what went to the C server's slot
i64 tc_child1_len = 0;

// Stands in for git so the gutter is live in the leak check and in
// every check that opens a file: `rev-parse` says this is a repo,
// `show` answers with the file's own bytes minus every ninth line.
i32 g_run_calls = 0;
// the build: a canned run with two errors and a warning, one of them
// in a file that is not there
// as a pty delivers it: the line discipline turns the compiler's
// newlines into CR LF on the way out
private str TEST_BUILD_OUT = "src/pick.mc:3:5: error: boom one\r\n    something\r\n    ^\r\nC:\\w\\lib\\nowhere.mc:10:2: warning: mild\r\nsrc/find.mc:7:1: error: boom two\r\n2 error(s) found\r\n";
// the tree's status, as `git status --porcelain -z` prints it: two
// letters, a space, the path, NUL; a rename's old name in a field of its
// own. With an ignored entry, a record with no space, and an empty one
// mixed in, all of which the parser must pass over.
i32 g_status_calls = 0;
i32 g_probe_calls = 0;
// the last `minc ...` command a build pane was opened with
i32 g_minc_calls = 0;
// the last command the build pane spawned, its words joined by spaces
u8[8192] g_spawn_cmd;
i32 g_spawn_cmd_len = 0;
bool g_minc_run = false;
u8[256] g_minc_target;
i32 g_minc_target_len = 0;
// a clean working tree, for the view that has to say so
bool g_status_empty = false;
private u8* test_status_reply(i64* out_len) {
    if g_status_empty {
        *out_len = 0;
        return alloc<u8>(1);
    }
    noinit str[11] recs;
    recs[0] = " M src/pick.mc";
    recs[1] = "?? src/new.mc";
    recs[2] = "A  lib/added.mc";
    recs[3] = " D gone.mc";
    recs[4] = "R  new2.mc";
    recs[5] = "old.mc";
    recs[6] = "UU merge.mc";
    recs[7] = "!! build/x";
    recs[8] = "junk";
    // both columns at once: staged, and changed again since
    recs[9] = "MM both.mc";
    recs[10] = "";
    u8* r = alloc<u8>(1024);
    i64 w = 0;
    for i32 i = 0; i < 11; i++ {
        memcpy(r + w, recs[i].data, recs[i].len);
        w += recs[i].len;
        r[w] = 0;
        w++;
    }
    *out_len = w;
    return r;
}

u8* plat_run_capture(str* argv, i32 argc, i64* out_len, i32* out_code) {
    g_run_calls++;
    *out_len = 0;
    *out_code = -1;
    if argc >= 2 && str_equal(argv[0], "git") && str_equal(argv[1], "status") {
        g_status_calls++;
        u8* r = test_status_reply(out_len);
        *out_code = 0;
        return r;
    }
    if argc >= 2 && str_equal(argv[0], "git") && str_equal(argv[1], "rev-parse") { g_probe_calls++; }
    return harness_git(argv, argc, 9, out_len, out_code);
}
bool plat_child_spawn(i32 k, str* argv, i32 argc) { return false; }
i64 plat_child_write(i32 k, u8* p, i64 n) {
    if k == 0 && tc_child_len + n <= 65536 {
        memcpy(&tc_child[tc_child_len], p, n);
        tc_child_len += n;
    }
    if k == 1 && tc_child1_len + n <= 65536 {
        memcpy(&tc_child1[tc_child1_len], p, n);
        tc_child1_len += n;
    }
    return n;
}
i64 plat_child_read(i32 k, u8* p, i64 cap) { return 0; }
void plat_child_kill(i32 k) {}

// The pseudo-terminal: a handle with no child behind it. Reads come
// back empty, so nothing arrives that a case did not feed, and writes
// are captured, so a check can assert the exact bytes a key produced.
private u8[4096] tc_term_out;
private i32 tc_term_len = 0;
// one handle per open terminal; a command handle answers the test's
// compiler output once, then the end of file, and exits with 1
private bool[TERM_MAX] tc_used;
private bool[TERM_MAX] tc_cmd;
private i64[TERM_MAX] tc_pending;   // bytes of TEST_BUILD_OUT still to read
// a case arming a shell with something to say
void tt_term_arm(i32 h) {
    if h >= 0 && h < TERM_MAX { tc_pending[h] = TEST_BUILD_OUT.len; }
}
i32 plat_term_spawn(i32 cols, i32 rows, str* argv, i32 argc, bool under) {
    i32 h = -1;
    for i32 i = 0; i < TERM_MAX; i++ {
        if !tc_used[i] { h = i; break; }
    }
    if h < 0 { return -1; }
    tc_used[h] = true;
    tc_cmd[h] = argc > 0;
    tc_pending[h] = 0;
    if argc > 0 {
        g_spawn_cmd_len = 0;
        for i32 i = 0; i < argc; i++ {
            if g_spawn_cmd_len + argv[i].len + 1 > 8192 { break; }
            if i > 0 {
                g_spawn_cmd[g_spawn_cmd_len] = ' ';
                g_spawn_cmd_len++;
            }
            memcpy(&g_spawn_cmd[g_spawn_cmd_len], argv[i].data, argv[i].len);
            g_spawn_cmd_len += argv[i].len;
        }
        g_minc_calls++;
        g_minc_run = argc >= 2 && str_equal(argv[1], "run");
        g_minc_target_len = 0;
        if argc >= 3 && argv[2].len < 256 {
            memcpy(&g_minc_target[0], argv[2].data, argv[2].len);
            g_minc_target_len = argv[2].len;
        }
        tc_pending[h] = TEST_BUILD_OUT.len;
    }
    return h;
}
i64 plat_term_read(i32 h, u8* buf, i64 cap) {
    if h < 0 || h >= TERM_MAX || tc_pending[h] <= 0 { return 0; }
    i64 n = tc_pending[h];
    if n > cap { n = cap; }
    i64 start = TEST_BUILD_OUT.len - tc_pending[h];
    memcpy(buf, TEST_BUILD_OUT.data + start, n);
    tc_pending[h] -= n;
    return n;
}
i64 plat_term_write(i32 h, u8* p, i64 n) {
    if tc_term_len + cast(i32, n) <= 4096 {
        memcpy(&tc_term_out[tc_term_len], p, n);
        tc_term_len += cast(i32, n);
    }
    return n;
}
void plat_term_resize(i32 h, i32 cols, i32 rows) {}
i32 plat_term_code(i32 h) {
    if h >= 0 && h < TERM_MAX && tc_cmd[h] { return 1; }
    return -1;
}
i32 g_term_kills = 0;
// the kill ends the stub's output, which the reader takes as the exit
void plat_term_kill(i32 h) {
    g_term_kills++;
    if h >= 0 && h < TERM_MAX { tc_pending[h] = 0; }
}
void plat_term_free(i32 h) { if h >= 0 && h < TERM_MAX { tc_used[h] = false; } }
// A platform with colors of its own, when a case asks for one: the
// rest read the built-in palette, which is what this machine has.
const u32 TT_PAL_FG = 0xFF010203;
const u32 TT_PAL_BG = 0xFF040506;
bool tt_pal_on = false;
i32 plat_exe_path(u8* out, i32 cap) { return 0; }
bool plat_exec_self(str exe, str* argv, i32 argc) { return false; }
// the handover: a handle's pty end is a number the adopt gives back to a
// fresh slot, so a round trip in one process can be checked
private i64[TERM_MAX] tc_adopted_fd;
// false is Windows: a ConPTY cannot be handed to another process, so
// the handover carries the terminal's text and nothing else
bool tt_export_ok = true;
bool plat_term_export(i32 h, i64* fd, i32* pid) {
    if !tt_export_ok { return false; }
    if h < 0 || h >= TERM_MAX || !tc_used[h] { return false; }
    *fd = 100 + cast(i64, h);
    *pid = 1000 + h;
    return true;
}
i32 plat_term_adopt(i64 fd, i32 pid) {
    i32 h = -1;
    for i32 i = 0; i < TERM_MAX; i++ {
        if !tc_used[i] { h = i; break; }
    }
    if h < 0 { return -1; }
    tc_used[h] = true;
    tc_cmd[h] = false;
    tc_pending[h] = 0;
    tc_adopted_fd[h] = fd;
    return h;
}
u32 plat_term_palette(u32* out, i32 n) {
    if !tt_pal_on || n < TP_N { return 0; }
    out[TP_FG] = TT_PAL_FG;
    out[TP_BG] = TT_PAL_BG;
    return (1 << cast(u32, TP_FG)) | (1 << cast(u32, TP_BG));
}

// the body of the last frame in the capture that carries `method`
private bool tc_last_body(str method, u8** body, i64* n) {
    bool found = false;
    str h = "Content-Length: ";
    i64 at = 0;
    while at + h.len < tc_child_len {
        bool hm = true;
        for i32 k = 0; k < h.len; k++ {
            if tc_child[at + k] != h.data[k] { hm = false; break; }
        }
        if !hm {
            at++;
            continue;
        }
        i64 j = at + cast(i64, h.len);
        i64 clen = 0;
        while j < tc_child_len && tc_child[j] >= '0' && tc_child[j] <= '9' {
            clen = clen * 10 + cast(i64, tc_child[j] - '0');
            j++;
        }
        while j + 3 < tc_child_len
            && !(tc_child[j] == 13 && tc_child[j + 1] == 10 && tc_child[j + 2] == 13 && tc_child[j + 3] == 10) {
            j++;
        }
        j += 4;
        if j + clen > tc_child_len { break; }
        for i64 i = j; i + method.len <= j + clen; i++ {
            bool m = true;
            for i32 k = 0; k < method.len; k++ {
                if tc_child[i + k] != method.data[k] { m = false; break; }
            }
            if m {
                *body = &tc_child[j];
                *n = clen;
                found = true;
                break;
            }
        }
        at = j + clen;
    }
    return found;
}

private bool tc_child1_has(str needle) {
    for i64 i = 0; i + needle.len <= tc_child1_len; i++ {
        if str_equal(str_from(&tc_child1[i], needle.len), needle) { return true; }
    }
    return false;
}

// the id of the last request that went to the C server
private i32 tc_child1_last_id() {
    str key = "\"id\":";
    i32 id = -1;
    for i64 i = 0; i + key.len <= tc_child1_len; i++ {
        if !str_equal(str_from(&tc_child1[i], key.len), key) { continue; }
        i64 j = i + key.len;
        i32 v = 0;
        while j < tc_child1_len && tc_child1[j] >= '0' && tc_child1[j] <= '9' {
            v = v * 10 + cast(i32, tc_child1[j] - '0');
            j++;
        }
        id = v;
    }
    return id;
}

// a frame from the C server
private void tc_lsp_frame_c(str payload) {
    noinit u8[2048] f;
    i64 o = 0;
    str h = "Content-Length: ";
    memcpy(&f[0], h.data, h.len);
    o = h.len;
    o = jw_int(&f[0], o, payload.len);
    f[o] = 13; o++;
    f[o] = 10; o++;
    f[o] = 13; o++;
    f[o] = 10; o++;
    memcpy(&f[o], payload.data, payload.len);
    o += payload.len;
    lsp_feed_from(LSP_C, &f[0], o);
}

// A C file goes to the C server, whose state is its own: the minc
// server's stays as it was, and switching back finds it. Its
// completion items show the declaration and insert the name.
private void check_lsp_c() {
    i64 minc_sent = tc_child_len;
    bool m_ready = lsp_ready;
    bool m_utf16 = lsp_pos_utf16;
    bool m_inc = lsp_sync_incremental;
    i32 m_open = lsp_opened_count();
    str ctxt = "int main(void) {\n    atomic_lo\n}\n";
    FileData cfd = FileData{ ctxt.data, ctxt.len };
    ignore file_write("build/ed_test_two.c", cfd);
    ignore ed_open_file("build/ed_test_two.c");
    g_checks++;
    if lsp_cur != LSP_C || lsp_ready || lsp_opened_count() != 0 {
        print("FAIL a C file must make the C server current, with nothing of the minc server's (cur {} ready {} open {})\n",
            lsp_cur, lsp_ready, lsp_opened_count());
        g_fails++;
    }
    lsp_on = true;   // pretend the child is up; writes go to tc_child1
    tc_child1_len = 0;
    // the encoding as clangd before 3.17 gives it, beside the capabilities
    tc_lsp_frame_c("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"offsetEncoding\":\"utf-8\",\"capabilities\":{\"textDocumentSync\":{\"change\":2},\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"variable\"],\"tokenModifiers\":[]},\"full\":true}}}}");
    lsp_pump();
    g_checks++;
    if lsp_cur != LSP_C || !lsp_ready || lsp_pos_utf16 || !lsp_sync_incremental {
        print("FAIL the C server's initialize reply must make it ready with utf-8 incremental sync (cur {} ready {} utf16 {} inc {})\n",
            lsp_cur, lsp_ready, lsp_pos_utf16, lsp_sync_incremental);
        g_fails++;
    }
    g_checks++;
    if !tc_child1_has("\"languageId\":\"c\"") || tc_child_len != minc_sent || sem_legend_n() == 1 {
        print("FAIL the C file must open on the C server only, the minc legend kept ({} legend)\n", sem_legend_n());
        g_fails++;
    }
    cur_line = 1;
    cur_col = 13;
    ed_complete_now();
    i32 cid = tc_child1_last_id();
    noinit u8[1024] rb;
    i64 rn = 0;
    rn = jw_raw(&rb[0], rn, "{\"jsonrpc\":\"2.0\",\"id\":");
    rn = jw_int(&rb[0], rn, cast(i64, cid));
    rn = jw_raw(&rb[0], rn, ",\"result\":{\"isIncomplete\":true,\"items\":[{\"label\":\" atomic_load(object)\",\"filterText\":\"atomic_load\",\"sortText\":\"3f2e0000atomic_load\",\"textEdit\":{\"newText\":\"atomic_load\",\"range\":{\"start\":{\"line\":1,\"character\":4},\"end\":{\"line\":1,\"character\":13}}}},{\"label\":\" atomic_long\",\"insertText\":\"atomic_long\",\"detail\":\"_Atomic(long)\",\"sortText\":\"3f1e0000atomic_long\"}]}}");
    tc_lsp_frame_c(str_from(&rb[0], cast(i32, rn)));
    lsp_pump();
    g_checks++;
    if !cmp_on || cmp_hit_count() != 2 || !str_equal(cmp_hit_label(0), "atomic_load") || !cmp_incomplete {
        print("FAIL a C completion must list the server's items in its order, no builtin types (on {} hits {} first {} incomplete {})\n",
            cmp_on, cmp_hit_count(), cmp_hit_label(0), cmp_incomplete);
        g_fails++;
    }
    app_char(13);
    tt_text_check("a C completion inserts the name, not the label", "int main(void) {\n    atomic_load\n}\n");
    // the minc server is current again for a minc buffer, as it was left
    ignore ed_open_file("src/pick.mc");
    g_checks++;
    if lsp_cur != LSP_MINC || lsp_ready != m_ready || lsp_pos_utf16 != m_utf16
        || lsp_sync_incremental != m_inc || lsp_opened_count() < m_open {
        print("FAIL a minc buffer must make the minc server current again, its state as it was\n");
        g_fails++;
    }
    // a close from a minc buffer still reaches the C server
    lsp_did_close("build/ed_test_two.c");
    g_checks++;
    if !tc_child1_has("textDocument/didClose") {
        print("FAIL closing a C file must tell the C server whichever buffer is active\n");
        g_fails++;
    }
    ignore ed_open_file("build/ed_test_two.c");
    lsp_on = false;
    lsp_ready = false;
    tb.dirty = false;
    app_key('W', MOD_CTRL);
    ignore ed_open_file("src/pick.mc");
}

private bool tc_child_has(str needle) {
    for i64 i = 0; i + needle.len <= tc_child_len; i++ {
        bool m = true;
        for i32 k = 0; k < needle.len; k++ {
            if tc_child[i + k] != needle.data[k] { m = false; break; }
        }
        if m { return true; }
    }
    return false;
}

// how many times needle appears in the captured child traffic
private i32 tc_child_count(str needle) {
    i32 n = 0;
    for i64 i = 0; i + needle.len <= tc_child_len; i++ {
        bool m = true;
        for i32 k = 0; k < needle.len; k++ {
            if tc_child[i + k] != needle.data[k] { m = false; break; }
        }
        if m { n++; }
    }
    return n;
}

// the id of the last request written, so a test can answer whatever
// the client actually asked without counting the requests before it
private i32 tc_last_id() {
    str key = "\"id\":";
    i32 id = 0;
    for i64 i = 0; i + key.len < tc_child_len; i++ {
        bool m = true;
        for i32 k = 0; k < key.len; k++ {
            if tc_child[i + k] != key.data[k] { m = false; break; }
        }
        if !m { continue; }
        i64 j = i + cast(i64, key.len);
        i32 v = 0;
        while j < tc_child_len && tc_child[j] >= '0' && tc_child[j] <= '9' {
            v = v * 10 + cast(i32, tc_child[j] - '0');
            j++;
        }
        id = v;
    }
    return id;
}

// one framed LSP message into the feed, split at `cut` to exercise
// partial delivery
// every pending semantic-token request answered with null, at most
// `rounds` of them: the client asks once more when a reply lands
// while a push is owed, so the next push asks afresh
private void tc_drain_sem(i32 rounds) {
    i32 n = 0;
    while lsp_sem_id_pending() != 0 && n < rounds {
        tc_reply(lsp_sem_id_pending(), ",\"result\":null}", 30);
        lsp_pump();
        n++;
    }
}

// a reply to request `id` with `tail` after the id, framed and fed to
// the client in pieces of `cut` bytes
private u8[8192] tc_reply_buf;
private void tc_reply(i32 id, str tail, i32 cut) {
    i64 n = 0;
    n = jw_raw(&tc_reply_buf[0], n, "{\"jsonrpc\":\"2.0\",\"id\":");
    n = jw_int(&tc_reply_buf[0], n, cast(i64, id));
    n = jw_raw(&tc_reply_buf[0], n, tail);
    tc_lsp_frame(str_from(&tc_reply_buf[0], cast(i32, n)), cut);
}

private void tc_lsp_frame(str payload, i32 cut) {
    noinit u8[2048] f;
    i64 o = 0;
    str h = "Content-Length: ";
    memcpy(&f[0], h.data, h.len);
    o = h.len;
    o = jw_int(&f[0], o, payload.len);
    f[o] = 13; o++;
    f[o] = 10; o++;
    f[o] = 13; o++;
    f[o] = 10; o++;
    memcpy(&f[o], payload.data, payload.len);
    o += payload.len;
    i64 c = cast(i64, cut);
    if c > o { c = o; }
    lsp_feed(&f[0], c);
    lsp_feed(&f[0] + c, o - c);
}
// a real in-memory clipboard, so copy/cut/paste can be asserted
private u8* g_clip = null;
private i64 g_clip_len = 0;
u8* plat_clipboard_get(i64* n) {
    *n = g_clip_len;
    if g_clip_len == 0 { return null; }
    u8* r = alloc<u8>(g_clip_len);
    memcpy(r, g_clip, g_clip_len);
    return r;
}
void plat_clipboard_set(u8* s, i64 n) {
    if g_clip != null { free(g_clip); }
    g_clip = null;
    g_clip_len = 0;
    if n <= 0 { return; }
    g_clip = alloc<u8>(n);
    memcpy(g_clip, s, n);
    g_clip_len = n;
}
private str clip_text() {
    return str_from(g_clip, cast(i32, g_clip_len));
}
void font_use(i32 dpi) {}
void draw_rect(f32 x, f32 y, f32 w, f32 h, u32 c) {}
void draw_rect_rounded(f32 x, f32 y, f32 w, f32 h, i32 r, u32 c) {}
void draw_clip(f32 x0, f32 x1) {}
void draw_clip_off() {}
void draw_clip_y(f32 y0, f32 y1) {}
void draw_clip_y_off() {}
void draw_segment(f32 x0, f32 y0, f32 x1, f32 y1, f32 w, u32 col) {}
void font_draw(u32 cp, f32 x, f32 y, u32 c) {}
void font_glyph_box(u32 cp, i32* w, i32* h, i32* xoff, i32* yoff) {}
f32 font_draw_text(str s, f32 x, f32 y, u32 c) {
    return x;
}
f32 font_draw_ui_text(str s, f32 x, f32 y, f32 max_x, u32 c) {
    return x;
}
i32 font_ui_h = 18;   // the notice box is laid out from it
i32 font_ui_text_w(str s) {
    return 0;
}
f32 font_draw_ui_cp(u32 cp, f32 x, f32 y, u32 c) {
    return x;
}

// --- harness ---------------------------------------------------------

private i32 g_fails = 0;
private i32 g_checks = 0;

private void type_text(str s) {
    for i32 i = 0; i < s.len; i++ {
        u8 c = s.data[i];
        if c == '\n' {
            app_char(13);
        } else {
            app_char(cast(u32, c));
        }
    }
}

private void expect(str want, str label) {
    g_checks++;
    i64 n = tb_len();
    u8* buf = alloc<u8>(n + 1);
    tb_copy(0, buf, n);
    if !str_equal(str_from(buf, cast(i32, n)), want) {
        print("FAIL {}\n  want [{}]\n  got  [{}]\n", label, want, str_from(buf, cast(i32, n)));
        g_fails++;
    }
    free(buf);
}

// Two cursors may never share a caret or overlap: the edit paths would
// then delete the same bytes twice. Checked pairwise, since the primary
// is not necessarily first in document order.
private void check_cursors(str label) {
    g_checks++;
    i32 n = ed_cur_count();
    i64 len = tb_len();
    for i32 i = 0; i < n; i++ {
        i64 ci = 0;
        i64 ai = 0;
        i64 bi = 0;
        ed_cur_get(i, &ci, &ai, &bi);
        if ci < 0 || ci > len || ai < 0 || bi > len || ai > bi {
            print("FAIL {}: cursor {} out of range {}..{} caret {} len {}\n",
                label, i, ai, bi, ci, len);
            g_fails++;
            return;
        }
        for i32 j = i + 1; j < n; j++ {
            i64 cj = 0;
            i64 aj = 0;
            i64 bj = 0;
            ed_cur_get(j, &cj, &aj, &bj);
            // touching ranges are two cursors, not one; only a real
            // overlap or two bare carets in one place is broken
            bool both = ai != bi && aj != bj;
            if (ai < bj && aj < bi) || (ci == cj && !both) {
                print("FAIL {}: cursors {} and {} overlap, {}..{} and {}..{}\n",
                    label, i, j, ai, bi, aj, bj);
                g_fails++;
                return;
            }
        }
    }
}

// The change gutter, as one character per buffer line:
// '.' unchanged, 'A' added, 'M' modified, 'D' deleted above.
private void check_git(str base, str cur, str want, str label) {
    g_checks++;
    tb_free();
    tb_init_empty();
    if cur.len > 0 { tb_insert(0, cur.data, cur.len); }
    git_set_baseline(base.data, base.len);
    i32 n = git_mark_count();
    noinit u8[256] got;
    i32 gn = n;
    if gn > 256 { gn = 256; }
    for i32 i = 0; i < gn; i++ {
        i32 m = git_mark(i);
        got[i] = '.';
        if m == GIT_ADD { got[i] = 'A'; }
        if m == GIT_MOD { got[i] = 'M'; }
        if m == GIT_DEL { got[i] = 'D'; }
    }
    if !str_equal(str_from(&got[0], gn), want) {
        print("FAIL {}\n  want [{}]\n  got  [{}]\n", label, want,
            str_from(&got[0], gn));
        g_fails++;
    }
    git_clear();
}

// The diff rows as one character per row: '.' a line both sides share,
// 'M' a changed pair, 'A' a line only the buffer has, 'D' one only the
// baseline has. The helper holds the alignment's own invariant as well,
// which the shape alone would not catch: each side's lines appear once
// each, in order, and a buffer line's row is the one it was put in.
private void check_rows(str base, str cur, str want, str label) {
    g_checks++;
    tb_free();
    tb_init_empty();
    if cur.len > 0 { tb_insert(0, cur.data, cur.len); }
    git_rows_enable(true);
    git_set_baseline(base.data, base.len);
    i32 n = git_row_count();
    noinit u8[256] got;
    i32 gn = n;
    if gn > 256 { gn = 256; }
    i32 next_a = 0;
    i32 next_b = 0;
    bool order_ok = true;
    bool pair_ok = true;
    bool lrow_ok = true;
    for i32 i = 0; i < gn; i++ {
        i32 a = git_row_a(i);
        i32 b = git_row_b(i);
        i32 k = git_row_kind(i);
        got[i] = '?';
        if k == GIT_NONE && a >= 0 && b >= 0 { got[i] = '.'; }
        if k == GIT_MOD && a >= 0 && b >= 0 { got[i] = 'M'; }
        if k == GIT_ADD && a < 0 && b >= 0 { got[i] = 'A'; }
        if k == GIT_DEL && a >= 0 && b < 0 { got[i] = 'D'; }
        if got[i] == '?' { pair_ok = false; }
        if a >= 0 {
            if a != next_a { order_ok = false; }
            next_a = a + 1;
        }
        if b >= 0 {
            if b != next_b { order_ok = false; }
            next_b = b + 1;
            if git_row_of_line(b) != i { lrow_ok = false; }
        }
    }
    if !str_equal(str_from(&got[0], gn), want) {
        print("FAIL {}\n  want [{}]\n  got  [{}]\n", label, want,
            str_from(&got[0], gn));
        g_fails++;
    } else if !pair_ok || !order_ok || !lrow_ok {
        print("FAIL {}: rows pair {} order {} line-to-row {}\n",
            label, pair_ok, order_ok, lrow_ok);
        g_fails++;
    }
    git_rows_enable(false);
    git_clear();
}

// One edit against a baseline of distinct lines has exactly one right
// answer, and a random one lands anywhere in the file. This is what
// catches a diff that is correct in shape but off by a line.
private void check_git_model(i32 rounds) {
    for i32 r = 0; r < rounds; r++ {
        i32 n = 3 + tm_rnd(40);
        i32 hit = tm_rnd(n);
        i32 kind = tm_rnd(3);
        noinit u8[4096] base;
        noinit u8[4096] cur;
        i32 bn = 0;
        i32 cn = 0;
        for i32 i = 0; i < n; i++ {
            // "L<i>." is distinct per line, so no two lines match
            i32 blen = 0;
            noinit u8[32] ln;
            ln[blen] = 'L';
            blen++;
            blen += fmt_i32(&ln[blen], i);
            ln[blen] = '.';
            blen++;
            ln[blen] = '\n';
            blen++;
            memcpy(&base[bn], &ln[0], blen);
            bn += blen;
            if i == hit {
                if kind == 0 {
                    str ch = "CHANGED\n";
                    memcpy(&cur[cn], ch.data, ch.len);
                    cn += ch.len;
                    continue;
                }
                if kind == 1 {
                    // a line inserted before this one
                    str ad = "ADDED\n";
                    memcpy(&cur[cn], ad.data, ad.len);
                    cn += ad.len;
                    memcpy(&cur[cn], &ln[0], blen);
                    cn += blen;
                    continue;
                }
                continue;   // kind 2: deleted, emit nothing
            }
            memcpy(&cur[cn], &ln[0], blen);
            cn += blen;
        }
        tb_free();
        tb_init_empty();
        if cn > 0 { tb_insert(0, &cur[0], cn); }
        git_set_baseline(&base[0], bn);
        i32 want_mark = GIT_MOD;
        if kind == 1 { want_mark = GIT_ADD; }
        if kind == 2 { want_mark = GIT_DEL; }
        g_checks++;
        bool bad = false;
        for i32 i = 0; i < git_mark_count(); i++ {
            i32 m = git_mark(i);
            if i == hit {
                if m != want_mark { bad = true; }
            } else if m != GIT_NONE {
                bad = true;
            }
        }
        if bad {
            print("FAIL git model: n={} hit={} kind={} marks [", n, hit, kind);
            for i32 i = 0; i < git_mark_count(); i++ {
                i32 m = git_mark(i);
                u8[4] c = { '.', 'A', 'M', 'D' };
                print("{}", str_from(&c[m], 1));
            }
            print("]\n");
            g_fails++;
            git_clear();
            return;
        }
        git_clear();
    }
}

private void expect_caret(i32 line, i64 col, str label) {
    g_checks++;
    if cur_line != line || cur_col != col {
        print("FAIL {}: want {}:{} got {}:{}\n", label, line, col, cur_line, cur_col);
        g_fails++;
    }
}

// --- text_buf against a model ----------------------------------------
// The gap buffer is what everything else sits on, so it gets a model
// check rather than invariants: the same edits applied to a plain byte
// array, compared content for content and line for line.

private u64 tm_rng = 0x2545F4914F6CDD1D;

private i32 tm_rnd(i32 n) {
    u64 x = tm_rng;
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    tm_rng = x;
    if n <= 1 { return 0; }
    return cast(i32, cast(i64, x >> 1) % cast(i64, n));
}

private const i64 TM_CAP = 262144;

// tb and the model agree on bytes, line count and every line start
private bool tm_agrees(u8* m, i64 mlen) {
    if tb_len() != mlen { return false; }
    u8* got = alloc<u8>(mlen + 1);
    tb_copy(0, got, mlen);
    bool ok = true;
    for i64 i = 0; i < mlen; i++ {
        if got[i] != m[i] { ok = false; break; }
    }
    free(got);
    if !ok { return false; }
    i32 want_lines = 1;
    for i64 i = 0; i < mlen; i++ {
        if m[i] == '\n' { want_lines++; }
    }
    if tb.nlines != want_lines { return false; }
    i32 l = 1;
    for i64 i = 0; i < mlen; i++ {
        if m[i] != '\n' { continue; }
        if l >= tb.nlines { break; }
        if tb_line_start(l) != i + 1 { return false; }
        l++;
    }
    return true;
}

private void check_text_buf_model(i32 ops) {
    tb_free();
    tb_init_empty();
    u8* m = alloc<u8>(TM_CAP + 64);
    i64 mlen = 0;
    noinit u8[64] chunk;

    for i32 op = 0; op < ops; op++ {
        bool insert = mlen < 1024 || tm_rnd(3) != 0;
        if insert && mlen < TM_CAP {
            i32 n = 1 + tm_rnd(48);
            for i32 i = 0; i < n; i++ {
                i32 k = tm_rnd(16);
                if k == 0 { chunk[i] = '\n'; }
                else if k == 1 { chunk[i] = '\t'; }
                else { chunk[i] = cast(u8, 32 + tm_rnd(95)); }
            }
            i64 at = cast(i64, tm_rnd(cast(i32, mlen) + 1));
            tb_insert(at, &chunk[0], n);
            // the model: shift the tail right, then drop the chunk in
            for i64 i = mlen - 1; i >= at; i-- { m[i + n] = m[i]; }
            for i32 i = 0; i < n; i++ { m[at + i] = chunk[i]; }
            mlen += n;
        } else if mlen > 0 {
            i64 at = cast(i64, tm_rnd(cast(i32, mlen)));
            i64 n = cast(i64, 1 + tm_rnd(48));
            if at + n > mlen { n = mlen - at; }
            tb_delete(at, n);
            for i64 i = at; i + n < mlen; i++ { m[i] = m[i + n]; }
            mlen -= n;
        }
        if op % 64 == 0 || op == ops - 1 {
            g_checks++;
            if !tm_agrees(m, mlen) {
                print("FAIL text_buf disagrees with the model at op {} ({} vs {} bytes)\n",
                    op, tb_len(), mlen);
                g_fails++;
                break;
            }
        }
    }
    free(m);
    tb_free();
    tb_init_empty();
}

// --- files changed on disk ------------------------------------------
// The harness has no platform watcher, so these hand watch_feed the
// records a watcher would send, then fire the refresh the way its
// timer would.

private void wt_write(str path, str text) {
    FileData fd = FileData{ text.data, text.len };
    ignore file_write(path, fd);
}

private void wt_feed(str recs) {
    watch_feed(recs.data, cast(i64, recs.len), false);
}

private bool wt_status_has(str part) {
    str s = str_from(&g_status_msg[0], g_status_len);
    for i32 i = 0; i + part.len <= s.len; i++ {
        if str_equal(str_from(s.data + i, part.len), part) { return true; }
    }
    return false;
}

private bool wt_disk_is(str path, str want) {
    FileData fd = file_read(path);
    if fd.data == null { return false; }
    bool same = str_equal(str_from(fd.data, cast(i32, fd.len)), want);
    free(fd.data);
    return same;
}

private str wt_text() {
    i64 n = tb_len();
    u8* buf = alloc<u8>(n + 1);
    tb_copy(0, buf, n);
    return str_from(buf, cast(i32, n));
}

private i32 wt_buf_titled(str title) {
    for i32 i = 0; i < ed_buf_count(); i++ {
        if str_equal(ed_buf_title(i), title) { return i; }
    }
    return -1;
}

private void wt_check(bool ok, str what) {
    g_checks++;
    if !ok {
        print("FAIL {}\n", what);
        g_fails++;
    }
}

private void check_watch() {
    str pa = "build/ed_test_watch_a.txt";
    str pb = "build/ed_test_watch_b.txt";
    wt_write(pa, "one\ntwo\nthree\n");
    wt_write(pb, "alpha\nbeta\n");
    ignore ed_open_file(pb);
    ignore ed_open_file(pa);   // a is loaded, b parked

    // a clean buffer takes the file's new bytes as one undoable edit
    wt_write(pa, "one\nTWO\nthree\nfour\n");
    wt_feed("cwatched.txt\n");
    wt_check(watch_pending(), "a record for a tracked path must arm the refresh");
    app_timer(WATCH_TIMER);
    wt_check(!watch_pending(), "the refresh must disarm itself");
    expect("one\nTWO\nthree\nfour\n", "a clean buffer must reload from disk");
    wt_check(!tb.dirty, "a reloaded buffer must be clean");
    app_key('Z', MOD_CTRL);
    expect("one\ntwo\nthree\n", "undo must take a reload back");
    wt_check(tb.dirty, "a reload taken back must be dirty: it differs from the file");
    app_key('Y', MOD_CTRL);
    expect("one\nTWO\nthree\nfour\n", "redo must restore the reload");
    wt_check(!tb.dirty, "a reload redone must be clean again");

    // ignored folders, the editor's own folder and git's internals
    // refresh nothing
    wt_feed("cbuild/x.o\nc.edminc/session\nc.git/objects/ab/cd\nm.git/index.lock\nm.git\n");
    wt_check(!watch_pending(), "ignored and private paths must not arm the refresh");

    // the index moves the status only; HEAD and the refs move the baselines
    i32 heads = watch_head_refreshes;
    wt_feed("m.git/index\n");
    wt_check(watch_pending(), "the index must arm the refresh");
    app_timer(WATCH_TIMER);
    wt_check(watch_head_refreshes == heads, "the index must not refetch the baselines");
    wt_feed("m.git/refs/heads/main\n");
    app_timer(WATCH_TIMER);
    wt_check(watch_head_refreshes == heads + 1, "a moved ref must refetch the baselines");
    for i32 k = 0; k < 64 && (ed_git_sweeping() || git_busy()); k++ {
        app_settle();
        app_wake();
    }
    wt_check(!ed_git_sweeping(), "the baseline refetch must finish");

    // a parked buffer reloads too
    wt_write(pb, "alpha\nBETA\n");
    wt_feed("cwatched.txt\n");
    app_timer(WATCH_TIMER);
    i32 ib = wt_buf_titled("ed_test_watch_b.txt");
    wt_check(ib >= 0, "the parked buffer must still be open");
    ed_buf_switch(ib);
    expect("alpha\nBETA\n", "a parked clean buffer must reload from disk");
    wt_check(!tb.dirty, "a reloaded parked buffer must be clean");

    // unsaved changes stay, and the save asks before it overwrites
    ed_buf_switch(wt_buf_titled("ed_test_watch_a.txt"));
    app_char('X');
    str mine = wt_text();
    wt_write(pa, "external\n");
    wt_feed("cwatched.txt\n");
    app_timer(WATCH_TIMER);
    str now = wt_text();
    wt_check(str_equal(now, mine), "a dirty buffer must keep its text when the file changes");
    free(now.data);
    wt_check(tb.dirty, "a dirty buffer must stay dirty");
    wt_check(wt_status_has("changed on disk"), "the status must say the file changed on disk");
    app_key('S', MOD_CTRL);
    wt_check(wt_disk_is(pa, "external\n"), "the first save must not overwrite a file changed on disk");
    wt_check(wt_status_has("save again"), "the first save must say how to overwrite");
    app_key('S', MOD_CTRL);
    wt_check(wt_disk_is(pa, mine), "the second save must overwrite");
    wt_check(!tb.dirty, "the buffer must be clean after the save");

    // the editor's own save changes nothing on the refresh
    i32 depth = ed_undo_depth();
    wt_feed("cwatched.txt\n");
    app_timer(WATCH_TIMER);
    now = wt_text();
    wt_check(ed_undo_depth() == depth && str_equal(now, mine),
        "the refresh after an own save must leave the buffer alone");
    free(now.data);

    // without a watcher, the save still checks the file first
    wt_write(pa, "behind its back\n");
    app_char('Y');
    app_key('S', MOD_CTRL);
    wt_check(wt_disk_is(pa, "behind its back\n"), "a save must check the file even with no record for it");
    app_key('S', MOD_CTRL);

    // a deleted file leaves the buffer as it is
    now = wt_text();
    test_remove(pa);
    wt_feed("mwatched.txt\n");
    app_timer(WATCH_TIMER);
    str after = wt_text();
    wt_check(str_equal(after, now), "a deleted file must leave the buffer");
    wt_check(wt_status_has("deleted on disk"), "the status must say the file was deleted");
    free(after.data);
    free(now.data);

    // lost changes refresh everything
    i32 refreshes = watch_refreshes;
    watch_feed(null, 0, true);
    wt_check(watch_pending(), "lost changes must arm the refresh");
    app_timer(WATCH_TIMER);
    wt_check(watch_refreshes == refreshes + 1 && watch_head_refreshes == heads + 2,
        "lost changes must refresh everything, the baselines included");
    for i32 k = 0; k < 64 && (ed_git_sweeping() || git_busy()); k++ {
        app_settle();
        app_wake();
    }

    free(mine.data);
    ed_buf_switch(wt_buf_titled("ed_test_watch_a.txt"));
    ed_buf_close();
    ib = wt_buf_titled("ed_test_watch_b.txt");
    if ib >= 0 {
        ed_buf_switch(ib);
        ed_buf_close();
    }
    test_remove(pb);
}


// A buffer closed in one window renumbers the table the windows share:
// the other windows' panes follow it. Left alone, a second window showed
// a slot past the end of the table, which drew as garbage.
private void test_window_buf_close() {
    close_all();
    ignore ed_open_file("src/pick.mc");     // pane 0
    app_key(92, MOD_CTRL);                  // pane 1, focused
    ignore ed_open_file("src/find.mc");
    i32 w0 = ed_window_active();
    i32 w1 = ed_window_new(ed_buf_active());   // shows find.mc
    app_use_window(w0);
    app_key('1', MOD_CTRL);
    app_key('W', MOD_CTRL);                 // pick.mc goes; find.mc moves down a slot
    app_use_window(w1);
    g_checks++;
    if ed_pane_buf(0) < 0 || ed_pane_buf(0) >= ed_buf_count()
        || !str_equal(ed_buf_title(ed_pane_buf(0)), "find.mc") {
        print("FAIL a buffer closed in one window must leave the other's panes on their buffers (slot {} of {})\n",
            ed_pane_buf(0), ed_buf_count());
        g_fails++;
    }
    // the buffer the other window shows, closed here: it moves to the one
    // that takes its place
    app_use_window(w0);
    ignore ed_open_file("src/pick.mc");
    app_key('2', MOD_CTRL);
    app_key('W', MOD_CTRL);                 // find.mc goes, shown in w1
    app_use_window(w1);
    g_checks++;
    if ed_pane_buf(0) < 0 || ed_pane_buf(0) >= ed_buf_count() {
        print("FAIL a window showing a closed buffer must move to one that is open (slot {} of {})\n",
            ed_pane_buf(0), ed_buf_count());
        g_fails++;
    }
    ignore ed_window_close();
    close_all();
}

// Ctrl+W closes a view, not a buffer another pane or window still shows:
// the pane moves to the buffer seen before it, the buffer stays open
private void test_close_shared_view() {
    close_all();
    ignore ed_open_file("src/pick.mc");
    ignore ed_open_file("src/find.mc");
    app_key(92, MOD_CTRL);                  // pane 1 shows find.mc too
    i32 nb = ed_buf_count();
    app_key('W', MOD_CTRL);
    g_checks++;
    if ed_buf_count() != nb || wt_buf_titled("find.mc") < 0
        || !str_equal(ed_path(), "src/pick.mc") || ed_pane_buf(0) != wt_buf_titled("find.mc") {
        print("FAIL ctrl+w on a buffer another pane shows must keep it open ({} of {} buffers, pane shows {})\n",
            ed_buf_count(), nb, ed_path());
        g_fails++;
    }
    // and one another window shows
    close_all();
    ignore ed_open_file("src/pick.mc");
    ignore ed_open_file("src/find.mc");
    i32 w0 = ed_window_active();
    i32 w1 = ed_window_new(ed_buf_active());   // find.mc there as well
    app_use_window(w0);
    nb = ed_buf_count();
    app_key('W', MOD_CTRL);
    g_checks++;
    if ed_buf_count() != nb || !str_equal(ed_path(), "src/pick.mc") {
        print("FAIL ctrl+w on a buffer another window shows must keep it open ({} of {} buffers, pane shows {})\n",
            ed_buf_count(), nb, ed_path());
        g_fails++;
    }
    app_use_window(w1);
    g_checks++;
    if !str_equal(ed_path(), "src/find.mc") {
        print("FAIL the other window must still show its buffer ({})\n", ed_path());
        g_fails++;
    }
    ignore ed_window_close();
    close_all();
}
// --- save/load round trip --------------------------------------------
// The fuzzer never writes to disk, so this is the only cover on the
// load/save path and on CRLF, which is stripped on load and restored
// on save.

private void check_save_roundtrip(str raw, bool want_crlf, str want_text, str label) {
    str path = "build/ed_test_roundtrip.tmp";
    FileData in = FileData{ raw.data, raw.len };
    g_checks++;
    if !file_write(path, in) {
        print("FAIL {}: could not write the fixture\n", label);
        g_fails++;
        return;
    }
    tb_free();
    ignore tb_load(path);
    g_checks++;
    if tb.crlf != want_crlf {
        print("FAIL {}: crlf detected as {}\n", label, cast(i32, tb.crlf));
        g_fails++;
    }
    expect(want_text, label);
    // saving must reproduce the bytes that were on disk
    ignore tb_save(path);
    FileData back = file_read(path);
    g_checks++;
    bool same = back.data != null && back.len == raw.len;
    if same {
        for i32 i = 0; i < raw.len; i++ {
            if back.data[i] != raw.data[i] { same = false; break; }
        }
    }
    if !same {
        print("FAIL {}: save did not reproduce the file ({} bytes vs {})\n",
            label, back.len, raw.len);
        g_fails++;
    }
    if back.data != null { free(back.data); }
    test_remove(path);
    tb_free();
    tb_init_empty();
}

// a selection is the range the edit paths delete over, so both ends
// have to stay inside the buffer
private bool sel_in_buffer() {
    i64 a = 0;
    i64 b = 0;
    if !ed_sel_range(&a, &b) { return true; }
    i64 n = tb_len();
    return a >= 0 && a <= b && b <= n;
}

// panes tile [content_left(), w) left to right, each with width > 0
private bool panes_tile(i32 w) {
    i32 prev = content_left();
    for i32 p = 0; p < ed_pane_count(); p++ {
        i32 x0 = 0;
        i32 x1 = 0;
        ed_pane_rect(p, &x0, &x1);
        if x0 != prev || x1 <= x0 { return false; }
        prev = x1;
    }
    return prev == w;
}

private void reset(str content) {
    // fresh buffer through the untitled path, then type the content
    tb_free();
    tb_init_empty();
    app_key(K_HOME, MOD_CTRL);
    // drop journal state from earlier cases: select-all + delete
    app_key('A', MOD_CTRL);
    app_char(8);
    type_text(content);
    app_key(K_HOME, MOD_CTRL);
}

// --- the terminal ----------------------------------------------------
// The emulator is a pure function from a byte stream to a screen, so
// every case here is bytes in and the screen as text out (term_dump,
// which is what --dump-term writes). Two characters stand in for bytes
// a literal cannot carry: ^ is escape, ` is bell, which is one of
// the two ways an OSC string ends, and | is backspace.

private u8[16384] tt_in;
private u8[8192] tt_got;
private u8[8192] tt_want;

private i32 tt_expand(str s, u8* out, i32 cap) {
    i32 n = 0;
    for i32 i = 0; i < s.len && n < cap; i++ {
        u8 c = s.data[i];
        if c == '^' { out[n] = 27; }
        else if c == '`' { out[n] = 7; }
        else if c == '|' { out[n] = 8; }
        else { out[n] = c; }
        n++;
    }
    return n;
}

private void tt_feed(i32 t, str s) {
    i32 n = tt_expand(s, &tt_in[0], 16384);
    term_feed(t, &tt_in[0], cast(i64, n));
}

private bool tt_is(i32 t, str want, str what) {
    g_checks++;
    str broke = term_check(t);
    if broke.len > 0 {
        print("FAIL {}: {}\n", what, broke);
        g_fails++;
        return false;
    }
    i32 n = term_dump(t, &tt_got[0], 8192);
    if !str_equal(str_from(&tt_got[0], n), want) {
        print("FAIL {}\n  want [{}]\n  got  [{}]\n", what, want, str_from(&tt_got[0], n));
        g_fails++;
        return false;
    }
    return true;
}

// one case: a fresh screen of that size, the bytes, the screen as text
private void tt_case(i32 cols, i32 rows, str in, str want, str what) {
    i32 t = term_new(cols, rows);
    if t < 0 {
        g_checks++;
        g_fails++;
        print("FAIL {}: no free terminal\n", what);
        return;
    }
    tt_feed(t, in);
    ignore tt_is(t, want, what);
    term_close(t);
}

// The same bytes split at every offset must leave the same screen:
// that is what makes a sequence arriving in two reads safe, and the
// reader hands over whatever the pipe gave it.
private void tt_split(i32 cols, i32 rows, str in, str what) {
    i32 n = tt_expand(in, &tt_in[0], 16384);
    noinit u8[1024] bytes;
    if n > 1024 { return; }
    memcpy(&bytes[0], &tt_in[0], n);
    i32 t = term_new(cols, rows);
    term_feed(t, &bytes[0], cast(i64, n));
    i32 wn = term_dump(t, &tt_want[0], 8192);
    term_close(t);
    for i32 k = 1; k < n; k++ {
        i32 t2 = term_new(cols, rows);
        term_feed(t2, &bytes[0], cast(i64, k));
        term_feed(t2, &bytes[k], cast(i64, n - k));
        i32 gn = term_dump(t2, &tt_got[0], 8192);
        term_close(t2);
        g_checks++;
        if gn != wn || !str_equal(str_from(&tt_got[0], gn), str_from(&tt_want[0], wn)) {
            print("FAIL {}: split at {} of {}\n  want [{}]\n  got  [{}]\n",
                what, k, n, str_from(&tt_want[0], wn), str_from(&tt_got[0], gn));
            g_fails++;
            return;
        }
    }
}

private void tt_sent_clear() {
    tc_term_len = 0;
}

private bool tt_sent_is(str want, str what) {
    g_checks++;
    i32 n = tt_expand(want, &tt_want[0], 8192);
    bool ok = tc_term_len == n
        && str_equal(str_from(&tc_term_out[0], tc_term_len), str_from(&tt_want[0], n));
    if !ok {
        print("FAIL {}: sent {} bytes [{}], want [{}]\n", what, tc_term_len,
            str_from(&tc_term_out[0], tc_term_len), str_from(&tt_want[0], n));
        g_fails++;
    }
    tc_term_len = 0;
    return ok;
}

private bool tt_sent_byte(u8 b, str what) {
    g_checks++;
    bool ok = tc_term_len == 1 && tc_term_out[0] == b;
    if !ok {
        print("FAIL {}: sent {} bytes, first {}\n", what, tc_term_len,
            cast(i32, tc_term_out[0]));
        g_fails++;
    }
    tc_term_len = 0;
    return ok;
}

// Leave a pattern on the stack for the next call to sit on. A field
// a function forgets to set reads as zero on a clean stack and as
// rubbish on a dirty one, which is how an uninitialized pane kind
// passed on one machine and failed on another; after this the
// check does not depend on which machine it runs on.
private void tt_dirty_stack() {
    noinit i32[4096] junk;
    for i32 i = 0; i < 4096; i++ { junk[i] = 4; }
    if junk[7] != 4 { print("stack scribble lost\n"); }
}

private void tt_num(i32 got, i32 want, str what) {
    g_checks++;
    if got != want {
        print("FAIL {}: got {}, want {}\n", what, got, want);
        g_fails++;
    }
}

// Ctrl+K T: a new shell in the active pane. The chord's own character
// follows it, as a real keyboard sends it and the chord swallows it.
private void tt_open_term() {
    app_key('K', MOD_CTRL);
    app_key('T', 0);
    app_char('t');
}

// the switcher typed at: "term" narrows it to the terminals (a shell
// with no title is listed as "terminal"), and Enter takes the first
private void tt_switch_to_term() {
    app_key('K', MOD_CTRL);
    app_key('W', 0);
    app_char('w');
    app_char('t');
    app_char('e');
    app_char('r');
    app_char('m');
    app_char(13);
}

private void test_terminal() {
    // no reader or writer thread: the cases feed the emulator and read
    // the writes back on the same thread, as lsp_threaded does
    term_threaded = false;

    // text, wrapping, and the wrap that waits
    tt_case(8, 2, "hello", "hello", "text lands on the first row");
    tt_case(4, 2, "abcdef", "abcd\nef", "a line wraps at the last column");
    tt_case(4, 2, "^[?7labcdef", "abcf", "with wrap off the last cell is overwritten");
    i32 t = term_new(4, 2);
    tt_feed(t, "abcd");
    tt_num(term_cy(t), 0, "a filled line does not wrap until there is more");
    tt_num(term_cx(t), 3, "the cursor waits in the last column");
    tt_feed(t, "e");
    tt_num(term_cy(t), 1, "the next character is what wraps");
    term_close(t);

    // the C0 controls
    tt_case(8, 2, "ab\r\ncd", "ab\ncd", "carriage return and line feed");
    tt_case(8, 1, "abc|X", "abX", "backspace steps back a cell");
    tt_case(16, 1, "a\tb", "a       b", "tab goes to the next stop");
    tt_case(6, 1, "abcde\tX", "abcdeX", "a tab at the last column stays in it");
    tt_case(6, 1, "abcdef\tX", "abcdeX", "a tab after the last cell stays in it");
    tt_case(1, 2, "\xe4\xb8\x9a", "\xe4\xb8\x9a", "a wide glyph on a one-column screen takes the cell it has");
    // clusters: a variation selector, a flag, a ZWJ family, a keycap, a
    // combining mark ride on the cell before them and the dump keeps
    // the bytes; an emoji presentation makes the cell wide
    t = term_new(12, 1);
    tt_feed(t, "\xe2\x9c\x94\xef\xb8\x8fX");   // heavy check mark + VS16, X
    tt_num(cast(i32, term_cell_attr(t, 0, 0)) & cast(i32, TA_WIDE), cast(i32, TA_WIDE), "VS16 makes the check mark a wide cell");
    tt_num(cast(i32, term_cell_cp(t, 0, 2)), cast(i32, 'X'), "and the next character lands after its tail");
    ignore tt_is(t, "\xe2\x9c\x94\xef\xb8\x8fX", "the dump keeps the selector");
    term_close(t);
    t = term_new(12, 1);
    tt_feed(t, "\xe2\x9c\x94\xef\xb8\x8eX");   // heavy check mark + VS15, X
    tt_num(cast(i32, term_cell_attr(t, 0, 0)) & cast(i32, TA_WIDE), 0, "VS15 keeps the text presentation narrow");
    tt_num(cast(i32, term_cell_cp(t, 0, 1)), cast(i32, 'X'), "and the next character is beside it");
    ignore tt_is(t, "\xe2\x9c\x94\xef\xb8\x8eX", "the dump keeps VS15");
    term_close(t);
    t = term_new(12, 1);
    tt_feed(t, "\xf0\x9f\x87\xb8\xf0\x9f\x87\xaaX");   // regional indicators S E, X
    tt_num(cast(i32, term_cell_attr(t, 0, 0)) & cast(i32, TA_WIDE), cast(i32, TA_WIDE), "a flag is one wide cell");
    tt_num(cast(i32, term_cell_cp(t, 0, 2)), cast(i32, 'X'), "with the next character after its tail");
    ignore tt_is(t, "\xf0\x9f\x87\xb8\xf0\x9f\x87\xaaX", "the dump keeps both indicators");
    term_close(t);
    t = term_new(12, 1);
    tt_feed(t, "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7X");   // man ZWJ woman ZWJ girl, X
    tt_num(cast(i32, term_cell_cp(t, 0, 2)), cast(i32, 'X'), "a ZWJ family is one wide cell");
    ignore tt_is(t, "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7X", "the dump keeps the whole family");
    term_close(t);
    t = term_new(12, 1);
    tt_feed(t, "1\xef\xb8\x8f\xe2\x83\xa3X");   // 1 VS16 keycap, X
    tt_num(cast(i32, term_cell_cp(t, 0, 2)), cast(i32, 'X'), "a keycap is one wide cell");
    term_close(t);
    t = term_new(12, 1);
    tt_feed(t, "e\xcc\x81X");   // e + combining acute, X
    tt_num(cast(i32, term_cell_cp(t, 0, 1)), cast(i32, 'X'), "a combining mark rides on its letter");
    ignore tt_is(t, "e\xcc\x81X", "and the dump keeps it");
    term_close(t);
    t = term_new(12, 1);
    tt_feed(t, "\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbdX");   // thumbs up + skin tone, X
    tt_num(cast(i32, term_cell_cp(t, 0, 2)), cast(i32, 'X'), "a skin tone rides on its emoji");
    term_close(t);
    // two emoji in a row are two cells, and a lone selector is nothing
    t = term_new(12, 1);
    tt_feed(t, "\xf0\x9f\x98\x80\xf0\x9f\x8e\x89X");
    tt_num(cast(i32, term_cell_cp(t, 0, 4)), cast(i32, 'X'), "two emoji are two wide cells");
    term_close(t);

    // moving the cursor
    tt_case(6, 2, "^[2;3HX", "\n  X", "CUP puts the cursor where it says");
    tt_case(6, 1, "abc^[2DX", "aXc", "CUB steps back");
    tt_case(6, 1, "abc^[2C^[2DX", "abcX", "CUF and CUB cancel out");
    tt_case(6, 1, "abc^[3GX", "abX", "CHA takes a column");
    tt_case(6, 2, "a^[BX", "a\n X", "CUD moves down a row");
    tt_case(6, 3, "a\r\nb\r\nc^[2AX", "aX\nb\nc", "CUU moves up rows");
    tt_case(6, 2, "abc^[EX", "abc\nX", "CNL is down and to the left margin");
    tt_case(6, 2, "\r\nabc^[FX", "X\nabc", "CPL is up and to the left margin");
    tt_case(6, 2, "ab^[2dX", "ab\n  X", "VPA takes a row, not a column");
    tt_case(6, 2, "ab^[s^[2;1Hcd^[uX", "abX\ncd", "the cursor is saved and restored");
    tt_case(6, 2, "ab^7^[2;1Hcd^8X", "abX\ncd", "DECSC and DECRC do the same");
    // the kitty keyboard protocol's push, pop and query share the final
    // byte with DECRC, and a private marker is what tells them apart
    tt_case(6, 2, "^[2;1Hab^[<uX", "\nabX", "CSI < u is not a cursor restore");
    tt_case(6, 2, "^[2;1Hab^[>5uX", "\nabX", "CSI > Pm u is not a cursor restore");
    tt_case(6, 2, "^[2;1Hab^[?uX", "\nabX", "CSI ? u is not a cursor restore");
    tt_case(6, 2, "^[1;1H^[s^[2;1Hab^[?1049s^[uX", "X\nab",
        "CSI ? Pm s is not a cursor save");
    tt_case(6, 3, "^[?1;2ra\r\nb\r\nc\r\nd", "b\nc\nd",
        "CSI ? Pm r is not a scroll region");

    // erasing
    tt_case(6, 1, "abcdef^[3G^[K", "ab", "EL 0 clears to the end of the line");
    tt_case(6, 1, "abcdef^[3G^[1K", "   def", "EL 1 clears back to the start");
    tt_case(6, 1, "abcdef^[2K", "", "EL 2 clears the line");
    tt_case(6, 1, "abcdef^[3G^[2X", "ab  ef", "ECH blanks cells in place");
    tt_case(6, 2, "ab\r\ncd^[2J", "", "ED 2 clears the screen");
    tt_case(6, 2, "ab\r\ncd^[1;2H^[J", "a", "ED 0 clears from the cursor down");
    tt_case(6, 2, "abc\r\ndef^[2;2H^[1J", "\n  f", "ED 1 clears down to the cursor");

    // inserting and deleting
    tt_case(6, 1, "abcdef^[3G^[2@", "ab  cd", "ICH opens cells");
    tt_case(6, 1, "abcdef^[3G^[2P", "abef", "DCH closes cells");
    tt_case(6, 3, "a\r\nb\r\nc^[2;1H^[L", "a\n\nb", "IL pushes the rows down");
    tt_case(6, 3, "a\r\nb\r\nc^[2;1H^[M", "a\nc", "DL pulls the rows up");
    tt_case(6, 3, "a\r\nb\r\nc^[S", "b\nc", "SU scrolls the screen up");
    tt_case(6, 3, "a\r\nb\r\nc^[T", "\na\nb", "SD scrolls the screen down");
    t = term_new(6, 4);
    tt_feed(t, "X^[2;3r^[2;1Hp\r\nq\r\nr");
    ignore tt_is(t, "X\nq\nr", "a scroll region scrolls without touching the rest");
    tt_num(term_scrollback(t), 0, "what scrolls inside a region is animation, not history");
    term_close(t);
    tt_case(6, 3, "a\r\nb\r\nc^[2;1H^M", "a\nb\nc",
        "reverse index off the top row only moves the cursor");
    tt_case(6, 3, "a\r\nb\r\nc^[1;1H^M", "\na\nb",
        "and on the top row it scrolls the screen down");

    // colors and attributes
    t = term_new(8, 1);
    tt_feed(t, "^[31mR^[m^[38;5;196mS^[38;2;10;20;30mT^[42mU");
    tt_num(cast(i32, term_cell_fg(t, 0, 0)), cast(i32, term_palette(TP_ANSI + 1)), "SGR 31 is the palette red");
    tt_num(cast(i32, term_cell_fg(t, 0, 1)), cast(i32, 0xFF0000FF), "38;5;196 is the cube's red");
    tt_num(cast(i32, term_cell_fg(t, 0, 2)), cast(i32, 0xFF1E140A), "38;2 takes the color as given");
    // the palette: defaults with the harness answering nothing, an
    // overlay the emulator's SGR mapping follows, and the reset
    tt_num(cast(i32, term_palette(TP_ANSI + 1)), cast(i32, theme_ansi(1)), "the palette's ANSI set is the theme's");
    tt_num(cast(i32, term_palette(TP_BG)), cast(i32, 0xFF000000), "the default background is black");
    g_checks++;
    if term_palette(TP_FG) == term_palette(TP_BG) || term_palette(TP_FG) == TERM_DEFAULT {
        print("FAIL the default text color must be a color\n");
        g_fails++;
    }
    term_palette_set(TP_ANSI + 1, 0x00112233);   // alpha zero in: opaque out
    tt_feed(t, "^[31mR");
    tt_num(cast(i32, term_cell_fg(t, 0, 4)), cast(i32, 0xFF112233), "SGR 31 follows a palette overlay");
    term_palette_reset();
    tt_num(cast(i32, term_palette(TP_ANSI + 1)), cast(i32, theme_ansi(1)), "the reset restores the theme's red");
    tt_num(cast(i32, term_cell_bg(t, 0, 3)), cast(i32, theme_ansi(2)), "SGR 42 is a background");
    tt_num(cast(i32, term_cell_fg(t, 0, 3)), cast(i32, 0xFF1E140A), "a background leaves the foreground");
    term_close(t);
    // private SGR is not SGR, and colon sub-parameters belong to the
    // parameter before them (a real program's stream had all of these)
    t = term_new(8, 1);
    tt_feed(t, "^[>4mA^[4:3mB^[4:0mC^[58;5;1mD^[38:2::10:20:30mE^[4mF^[58:2::1:2:3mG^[24;38:5:196mH");
    tt_num(cast(i32, term_cell_attr(t, 0, 0)) & cast(i32, TA_UNDER), 0, "CSI > 4 m is a key setting, not an underline");
    tt_num(cast(i32, term_cell_attr(t, 0, 1)) & cast(i32, TA_UNDER), cast(i32, TA_UNDER), "4:3 is an underline");
    tt_num(cast(i32, term_cell_attr(t, 0, 2)) & cast(i32, TA_UNDER), 0, "4:0 is no underline");
    tt_num(cast(i32, term_cell_attr(t, 0, 2)) & cast(i32, TA_ITALIC), 0, "4:3's style is not an italic");
    tt_num(cast(i32, term_cell_attr(t, 0, 3)) & cast(i32, TA_UNDER | TA_BLINK), 0, "58;5;n is stepped over");
    tt_num(cast(i32, term_cell_fg(t, 0, 4)), cast(i32, 0xFF1E140A), "38:2::r:g:b takes the color");
    tt_num(cast(i32, term_cell_attr(t, 0, 5)) & cast(i32, TA_UNDER), cast(i32, TA_UNDER), "a plain 4 still underlines");
    tt_num(cast(i32, term_cell_fg(t, 0, 6)), cast(i32, 0xFF1E140A), "58:2::r:g:b changes nothing else");
    tt_num(cast(i32, term_cell_attr(t, 0, 6)) & cast(i32, TA_UNDER), cast(i32, TA_UNDER), "and keeps the underline");
    tt_num(cast(i32, term_cell_fg(t, 0, 7)), cast(i32, 0xFF0000FF), "38:5:196 after a 24 is the cube's red");
    tt_num(cast(i32, term_cell_attr(t, 0, 7)) & cast(i32, TA_UNDER), 0, "and the 24 took the underline off");
    term_close(t);
    t = term_new(8, 1);
    tt_feed(t, "^[1;4mB^[22mC^[24mD^[7mE");
    tt_num(term_cell_attr(t, 0, 0), cast(i32, TA_BOLD | TA_UNDER), "bold and underline together");
    tt_num(term_cell_attr(t, 0, 1), cast(i32, TA_UNDER), "SGR 22 drops the bold only");
    tt_num(term_cell_attr(t, 0, 2), 0, "SGR 24 drops the underline");
    tt_num(term_cell_attr(t, 0, 3), cast(i32, TA_INVERSE), "SGR 7 is inverse");
    tt_num(cast(i32, term_cell_fg(t, 0, 4)), cast(i32, TERM_DEFAULT),
        "an untouched cell keeps the default color");
    term_close(t);

    // the alternate screen
    t = term_new(6, 2);
    tt_feed(t, "keep");
    tt_feed(t, "^[?1049h");
    g_checks++;
    if !term_alt(t) { print("FAIL 1049 must switch to the alternate screen\n"); g_fails++; }
    ignore tt_is(t, "", "the alternate screen starts empty");
    tt_feed(t, "over");
    ignore tt_is(t, "over", "the alternate screen takes its own text");
    tt_feed(t, "^[?1049l");
    g_checks++;
    if term_alt(t) { print("FAIL 1049 low must come back to the primary\n"); g_fails++; }
    ignore tt_is(t, "keep", "leaving the alternate screen restores the primary");
    term_close(t);

    // the modes that are state, not drawing
    t = term_new(6, 2);
    g_checks++;
    if !term_cursor_vis(t) { print("FAIL the cursor starts visible\n"); g_fails++; }
    tt_feed(t, "^[?25l");
    g_checks++;
    if term_cursor_vis(t) { print("FAIL 25 low must hide the cursor\n"); g_fails++; }
    tt_feed(t, "^[?25h^[ 4q");
    tt_num(term_cursor_shape(t), TERM_CUR_UNDER, "DECSCUSR picks the cursor shape");
    tt_feed(t, "^[?2004h");
    g_checks++;
    if !term_bracketed(t) { print("FAIL 2004 must turn on bracketed paste\n"); g_fails++; }
    tt_feed(t, "^[?1000h");
    tt_num(term_mouse_mode(t), 1000, "1000 turns the mouse on");
    tt_feed(t, "^[?9001h^[?1004h");
    tt_num(term_mouse_mode(t), 1000, "the modes the host sets itself change nothing");
    term_close(t);

    // the title, either way an OSC ends
    t = term_new(6, 2);
    tt_feed(t, "^]0;hello`");
    g_checks++;
    if !str_equal(term_title(t), "hello") {
        print("FAIL an OSC ending in bell must set the title: [{}]\n", term_title(t));
        g_fails++;
    }
    tt_feed(t, "^]2;bye^\\");
    g_checks++;
    if !str_equal(term_title(t), "bye") {
        print("FAIL an OSC ending in ST must set the title: [{}]\n", term_title(t));
        g_fails++;
    }
    tt_feed(t, "^]9001;CmdNotFound;x^\\");
    g_checks++;
    if !str_equal(term_title(t), "bye") {
        print("FAIL an OSC we do not answer must leave the title: [{}]\n", term_title(t));
        g_fails++;
    }
    ignore tt_is(t, "", "an OSC string never reaches the screen");
    term_close(t);

    // unknown sequences are consumed, not left to corrupt the next one
    tt_case(8, 1, "a^[?7;9;99zb^[999~c", "abc", "an unknown sequence is dropped whole");
    tt_case(8, 1, "a^(Bb", "ab", "a charset designator is dropped whole");
    tt_case(8, 1, "a^Pq;;junk^\\b", "ab", "a device control string is swallowed");
    tt_case(8, 1, "a^[8;30;100tb", "ab", "the host's own window report is dropped");

    // utf-8, whole and split
    tt_case(8, 1, "a\u{e9}b", "a\u{e9}b", "utf-8 decodes in the ground state");
    t = term_new(8, 1);
    noinit u8[4] two;
    two[0] = 0xC3;
    two[1] = 0xA9;
    term_feed(t, &two[0], 1);
    term_feed(t, &two[1], 1);
    ignore tt_is(t, "\u{e9}", "a codepoint split across two reads");
    term_close(t);
    t = term_new(8, 1);
    tt_feed(t, "\u{4e16}");
    tt_num(term_cx(t), 2, "a wide glyph takes two cells");
    tt_num(term_cell_attr(t, 0, 0) & cast(i32, TA_WIDE), cast(i32, TA_WIDE), "its left half is marked");
    tt_num(term_cell_attr(t, 0, 1) & cast(i32, TA_TAIL), cast(i32, TA_TAIL), "and its right half too");
    ignore tt_is(t, "\u{4e16}", "a wide glyph dumps once");
    term_close(t);
    t = term_new(8, 1);
    noinit u8[2] bad;
    bad[0] = 0xFF;
    term_feed(t, &bad[0], 1);
    tt_num(cast(i32, term_cell_cp(t, 0, 0)), 0xFFFD, "a byte that is not utf-8 becomes the replacement");
    term_close(t);

    // the scrollback ring
    t = term_new(6, 3);
    tt_feed(t, "1\r\n2\r\n3\r\n4\r\n5");
    ignore tt_is(t, "3\n4\n5", "the screen holds the last rows");
    tt_num(term_scrollback(t), 2, "the rows that left went to the scrollback");
    term_view_set(t, 1);
    ignore tt_is(t, "2\n3\n4", "the view scrolls back into the history");
    g_checks++;
    if term_cursor_vis(t) { print("FAIL the cursor is not drawn in the history\n"); g_fails++; }
    tt_feed(t, "\r\n6");
    tt_num(term_view(t), 2, "output leaves the view on its lines");
    ignore tt_is(t, "2\n3\n4", "and the text stays under the reader");
    term_char(t, 'x', 0);
    tt_num(term_view(t), 0, "a key snaps the view back to the live screen");
    term_close(t);
    t = term_new(6, 2);
    for i32 i = 0; i < TERM_SCROLLBACK + 10; i++ { tt_feed(t, "y\r\n"); }
    tt_num(term_scrollback(t), TERM_SCROLLBACK, "the ring is bounded");
    term_close(t);
    t = term_new(6, 3);
    tt_feed(t, "1\r\n2\r\n3\r\n4^[3J");
    tt_num(term_scrollback(t), 0, "ED 3 drops the scrollback");
    term_close(t);

    // the alternate screen keeps no history
    t = term_new(6, 2);
    tt_feed(t, "^[?1049h1\r\n2\r\n3\r\n4");
    tt_num(term_scrollback(t), 0, "the alternate screen writes no history");
    term_close(t);

    // resize
    t = term_new(6, 3);
    tt_feed(t, "a\r\nb\r\nc");
    term_resize(t, 6, 2);
    ignore tt_is(t, "b\nc", "shrinking keeps the rows the child wrote last");
    tt_num(term_scrollback(t), 1, "and the row that went is history");
    term_resize(t, 6, 4);
    ignore tt_is(t, "a\nb\nc", "growing takes the row back out of the history");
    tt_num(term_scrollback(t), 0, "which is empty again");
    tt_num(term_rows(t), 4, "the screen is the size it was given");
    term_resize(t, 3, 4);
    ignore tt_is(t, "a\nb\nc", "a narrower screen keeps the short lines");
    tt_num(term_cols(t), 3, "and is the width it was given");
    g_checks++;
    if term_cx(t) >= term_cols(t) || term_cy(t) >= term_rows(t) {
        print("FAIL the cursor must stay inside a resized screen ({},{})\n",
            term_cx(t), term_cy(t));
        g_fails++;
    }
    term_close(t);

    // soft reflow: a wrapped line is one line at every width
    t = term_new(6, 3);
    tt_feed(t, "abcdefgh");
    ignore tt_is(t, "abcdef\ngh", "a long line wraps");
    term_resize(t, 8, 3);
    ignore tt_is(t, "abcdefgh", "widening joins the rows the line was wrapped into");
    tt_feed(t, "i");
    ignore tt_is(t, "abcdefgh\ni", "and the cursor is after its last character");
    term_resize(t, 4, 3);
    ignore tt_is(t, "abcd\nefgh\ni", "narrowing cuts it at the new edge");
    tt_num(term_cy(t), 2, "the cursor follows its cell down");
    tt_num(term_cx(t), 1, "and across");
    term_close(t);
    t = term_new(6, 3);
    tt_feed(t, "abcdef\r\ngh");
    term_resize(t, 8, 3);
    ignore tt_is(t, "abcdef\ngh", "a line that ended at the edge is not joined");
    term_close(t);
    t = term_new(6, 2);
    tt_feed(t, "abcdefgh\r\n1\r\n2");
    ignore tt_is(t, "1\n2", "the wrapped line has left the screen");
    tt_num(term_scrollback(t), 2, "as two rows of history");
    term_resize(t, 8, 2);
    tt_num(term_scrollback(t), 1, "widening joins them in the history too");
    term_resize(t, 8, 4);
    ignore tt_is(t, "abcdefgh\n1\n2", "a taller screen takes the history back");
    tt_num(term_scrollback(t), 0, "and the ring is empty");
    term_close(t);
    t = term_new(8, 4);
    tt_feed(t, "1\r\n2\r\n3\r\n4\r\n5^[2J^[H$ ");
    term_resize(t, 6, 4);
    ignore tt_is(t, "$", "a narrower screen keeps a cleared screen clear");
    tt_num(term_cy(t), 0, "with the prompt where it was");
    tt_num(term_cx(t), 2, "and the cursor after it");
    tt_num(term_scrollback(t), 1, "and the history as it was");
    term_resize(t, 6, 2);
    ignore tt_is(t, "$", "a shorter screen keeps the prompt on it");
    tt_num(term_scrollback(t), 1, "rather than pushing it into the history");
    term_close(t);
    t = term_new(4, 2);
    tt_feed(t, "ab\xe6\x97\xa5c");
    ignore tt_is(t, "ab\xe6\x97\xa5\nc", "a wide glyph fills the row");
    term_resize(t, 3, 2);
    ignore tt_is(t, "ab\n\xe6\x97\xa5c", "and moves whole to the next row when it does not fit");
    term_resize(t, 5, 2);
    ignore tt_is(t, "ab\xe6\x97\xa5c", "and back into one row");
    term_close(t);
    t = term_new(6, 3);
    tt_feed(t, "1\r\n2\r\n3\r\n4\r\n5");
    term_view_set(t, 2);
    ignore tt_is(t, "1\n2\n3", "the view is at the top of the history");
    term_resize(t, 6, 2);
    tt_num(term_view(t), 0, "a resize brings the view back to the live screen");
    ignore tt_is(t, "4\n5", "which the child repaints on the size change");
    term_close(t);

    // a sequence split at every offset is the same sequence
    tt_split(8, 3, "^[31mab^[2;2Hcd^[K^[1;1Hx", "a split feed is the same screen");
    tt_split(8, 3, "^[?1049h^[2Jab\r\ncd^[?1049l", "a split feed over the alternate screen");
    tt_split(8, 2, "^]0;title`ab^[3;1Hc", "a split feed over an osc string");

    // what the emulator answers by itself
    t = term_open(8, 3);
    tt_sent_clear();
    tt_feed(t, "^[2;3H^[6n");
    ignore tt_sent_is("^[2;3R", "the cursor position report says where it is");
    tt_feed(t, "^[c");
    ignore tt_sent_is("^[?6c", "the device attributes answer is fixed");

    // keys to the child
    ignore term_key(t, K_UP, 0);
    ignore tt_sent_is("^[A", "the up arrow");
    ignore term_key(t, K_LEFT, MOD_CTRL);
    ignore tt_sent_is("^[1;5D", "ctrl and the left arrow carry the modifier");
    tt_feed(t, "^[?1h");
    ignore term_key(t, K_UP, 0);
    ignore tt_sent_is("^OA", "application cursor keys use the other form");
    ignore term_key(t, K_UP, MOD_SHIFT);
    ignore tt_sent_is("^[1;2A", "a modifier goes back to the first form");
    tt_feed(t, "^[?1l");
    ignore term_key(t, K_PGUP, 0);
    ignore tt_sent_is("^[5~", "page up is numbered");
    ignore term_key(t, K_PGDN, MOD_SHIFT);
    ignore tt_sent_is("^[6;2~", "and takes a modifier too");
    ignore term_key(t, K_DELETE, 0);
    ignore tt_sent_is("^[3~", "delete is numbered");
    ignore term_key(t, K_HOME, 0);
    ignore tt_sent_is("^[H", "home is a letter");
    ignore term_key(t, K_F12, 0);
    ignore tt_sent_is("^[24~", "the function keys are xterm's numbers");
    ignore term_key(t, K_F6, 0);
    ignore tt_sent_is("^[17~", "with the gaps xterm has");
    ignore term_key(t, K_F11, MOD_CTRL);
    ignore tt_sent_is("^[23;5~", "and a modifier");
    ignore term_key(t, K_F1, 0);
    ignore tt_sent_is("^OP", "f1 to f4 are ss3");
    ignore term_key(t, K_F4, MOD_SHIFT);
    ignore tt_sent_is("^[1;2S", "in the csi form to carry a modifier");
    ignore term_key(t, K_TAB, MOD_SHIFT);
    ignore tt_sent_is("^[Z", "shift and tab is back-tab");
    ignore term_key(t, K_TAB, 0);
    ignore tt_sent_byte(9, "tab is a tab");
    ignore term_key(t, K_ESCAPE, 0);
    ignore tt_sent_byte(27, "escape is escape");
    ignore term_key(t, 'C', MOD_CTRL);
    ignore tt_sent_byte(3, "ctrl+c is the control code, not a key name");
    ignore term_key(t, ' ', MOD_CTRL);
    ignore tt_sent_byte(0, "ctrl+space is nul");
    g_checks++;
    if term_key(t, 'A', 0) {
        print("FAIL a plain letter is text, not a key the terminal takes\n");
        g_fails++;
        tt_sent_clear();
    }
    term_char(t, 'x', 0);
    ignore tt_sent_byte('x', "a character goes as itself");
    term_char(t, 13, 0);
    ignore tt_sent_byte(13, "enter is a carriage return");
    term_char(t, 8, 0);
    ignore tt_sent_byte(127, "backspace is delete");
    term_char(t, 'b', MOD_ALT);
    ignore tt_sent_is("^b", "alt is the escape prefix");
    tt_feed(t, "1\r\n2\r\n3\r\n4\r\n5");
    term_view_set(t, 1);
    ignore term_key(t, 'A', 0);
    tt_num(term_view(t), 1, "a key the terminal leaves alone keeps the view");
    ignore term_key(t, K_UP, 0);
    tt_sent_clear();
    tt_num(term_view(t), 0, "a key for the child snaps the view back");

    // pasting, and the mouse
    noinit u8[8] pb;
    pb[0] = 'a';
    pb[1] = 10;
    pb[2] = 'b';
    term_paste(t, &pb[0], 3);
    ignore tt_sent_is("a\rb", "a paste ends its lines the way a shell reads them");
    tt_feed(t, "^[?2004h");
    term_paste(t, &pb[0], 3);
    ignore tt_sent_is("^[200~a\rb^[201~", "bracketed paste wraps it");
    term_mouse(t, 3, 4, 0, true, 0);
    ignore tt_sent_is("", "a mouse report needs the child to have asked");
    tt_feed(t, "^[?1000h");
    term_mouse(t, 3, 4, 0, true, 0);
    ignore tt_sent_is("^[<0;4;5M", "a press is reported in the sgr encoding");
    term_mouse(t, 3, 4, 0, false, 0);
    ignore tt_sent_is("^[<0;4;5m", "and a release is the lower case one");
    term_close(t);

    // the prompt the prototype recorded, played back through the
    // emulator: the stream that made this step worth taking
    tt_case(40, 3,
        "^[?9001h^[?1004h^[?25l^[2J^[m^[HPS C:\\x>^[1C^]0;pwsh.exe`^[?25h",
        "PS C:\\x>", "the recorded pwsh prompt lands on the screen");
    tt_case(40, 4,
        "^[?25l^[93mGet-Date^[K^[m\r\n^[30X^[?25h\r\n^[?25lFriday^[4;1HPS>^[?25h",
        "Get-Date\n\nFriday\nPS>", "and the command that follows it");

    // the pane's colors: what the platform gave, the built-in ones,
    // and back. A pane shows one or the other whole.
    tt_pal_on = true;
    term_palette_init();
    g_checks++;
    if !term_palette_have() || !term_palette_theirs()
        || term_palette(TP_FG) != TT_PAL_FG || term_palette(TP_BG) != TT_PAL_BG {
        print("FAIL the pane takes the colors the platform gave ({} {})\n",
            cast(i64, term_palette(TP_FG)), cast(i64, term_palette(TP_BG)));
        g_fails++;
    }
    term_palette_toggle();
    g_checks++;
    if term_palette_theirs() || term_palette(TP_FG) == TT_PAL_FG {
        print("FAIL the toggle goes back to the built-in colors ({})\n",
            cast(i64, term_palette(TP_FG)));
        g_fails++;
    }
    term_palette_toggle();
    g_checks++;
    if !term_palette_theirs() || term_palette(TP_FG) != TT_PAL_FG {
        print("FAIL and the toggle brings the platform's back ({})\n",
            cast(i64, term_palette(TP_FG)));
        g_fails++;
    }
    // and a platform with nothing to say leaves the built-in ones
    tt_pal_on = false;
    term_palette_init();
    g_checks++;
    if term_palette_have() || term_palette_theirs()
        || term_palette(TP_BG) != 0xFF000000 {
        print("FAIL a platform that names no color leaves the built-in ones ({})\n",
            cast(i64, term_palette(TP_BG)));
        g_fails++;
    }

    term_threaded = true;
}

// --- the input lines' editing ----------------------------------------
// The search box, the find widget and the input box share one
// field (lib/ui.mc), so the arrows, Home/End, the word chords, the
// selection chords and the clipboard all work in them the way they do
// in the editor. The search box is checked through its bytes, the
// prompt through its own, the find widget through the match it lands.
private void expect_sq(str want, str label) {
    g_checks++;
    str got = str_from(&sq[0], sq_len);
    if !str_equal(got, want) {
        print("FAIL {}: search query is '{}' not '{}'\n", label, got, want);
        g_fails++;
    }
}

private void test_input_fields() {
    reset("one two\nxacbx\n");
    search_open_view();
    sq_len = 0;
    type_text("abc");
    app_key(K_LEFT, 0);
    app_key(K_LEFT, 0);
    type_text("X");
    expect_sq("aXbc", "left moves the caret");
    app_key(K_HOME, 0);
    type_text("0");
    app_key(K_END, 0);
    type_text("9");
    expect_sq("0aXbc9", "home and end");
    app_key(K_LEFT, MOD_SHIFT);
    app_key(K_LEFT, MOD_SHIFT);
    type_text("Z");
    expect_sq("0aXbZ", "typing replaces a shift selection");
    app_char(8);
    app_char(8);
    expect_sq("0aX", "backspace at the end");
    app_key(K_HOME, 0);
    app_key(K_DELETE, 0);
    expect_sq("aX", "delete takes the character after the caret");
    app_key(K_RIGHT, 0);
    app_key(K_RIGHT, 0);
    app_key(K_RIGHT, 0);   // past the end stays put
    app_char(8);
    expect_sq("a", "right stops at the end");
    app_key('A', MOD_CTRL);
    app_char(8);
    expect_sq("", "select all then backspace clears");
    g_checks++;
    if !search_focus || !search_on {
        print("FAIL the selection chords must stay in the search box\n");
        g_fails++;
    }
    type_text("foo bar.baz");
    app_key(K_LEFT, MOD_WORD);
    type_text("_");
    expect_sq("foo bar._baz", "word left stops at punctuation");
    app_key(K_LEFT, MOD_WORD);
    app_key(K_LEFT, MOD_WORD);
    type_text("|");
    expect_sq("foo bar|._baz", "a run of punctuation is one word step");
    app_key(K_END, 0);
    app_char(127);
    expect_sq("foo bar|.", "ctrl+backspace takes a word");
    app_key(K_HOME, 0);
    app_key(K_DELETE, MOD_CTRL);
    expect_sq(" bar|.", "the primary's delete takes the word right");
    app_key(K_RIGHT, MOD_WORD);
    app_key(K_END, MOD_SHIFT);
    app_key('C', MOD_CTRL);
    g_checks++;
    if !str_equal(clip_text(), "|.") {
        print("FAIL copy must put the selection on the clipboard ('{}')\n", clip_text());
        g_fails++;
    }
    app_key('X', MOD_CTRL);
    expect_sq(" bar", "cut removes the selection");
    str pasted = "xy\nz";
    plat_clipboard_set(pasted.data, pasted.len);
    app_key(K_HOME, 0);
    app_key('V', MOD_CTRL);
    expect_sq("xy bar", "paste takes the clipboard's first line");
    when os(macos) {
        // Cmd+arrows is line start and end on the platform
        app_key(K_RIGHT, MOD_CTRL);
        type_text("$");
        app_key(K_LEFT, MOD_CTRL);
        type_text("^");
        expect_sq("^xy bar$", "cmd+arrows are home and end");
    }
    // a multi-byte character is one caret step
    sq_len = 0;
    type_text("a");
    app_char(0xE9);   // é
    type_text("b");
    app_key(K_LEFT, 0);
    app_key(K_LEFT, 0);
    type_text("-");
    expect_sq("a-\xC3\xA9b", "the caret steps over a whole character");
    app_key(K_RIGHT, 0);
    app_char(8);
    expect_sq("a-b", "backspace takes a whole character");
    // typing arms the search; the timer runs it, and an emptied query
    // empties the list
    sq_len = 0;
    type_text("ui_field_bind");
    g_checks++;
    if !search_pending() {
        print("FAIL typing in the search box must arm the search\n");
        g_fails++;
    }
    app_timer(SEARCH_TIMER);
    search_settle();
    g_checks++;
    if search_pending() || search_hit_count() == 0 {
        print("FAIL the timer must run the search ({} hits)\n", search_hit_count());
        g_fails++;
    }
    app_key('A', MOD_CTRL);
    app_char(8);
    app_timer(SEARCH_TIMER);
    g_checks++;
    if search_hit_count() != 0 || search_pending() {
        print("FAIL an emptied query must empty the list ({} hits)\n", search_hit_count());
        g_fails++;
    }
    // one line has the keyboard: ctrl+f takes it from the search box,
    // and a click in the search box closes the find widget
    app_key('F', MOD_CTRL);
    g_checks++;
    if !find_on || search_focus {
        print("FAIL the find widget must take the focus from the search box\n");
        g_fails++;
    }
    search_mouse(10, 10);
    g_checks++;
    if find_on || !search_focus {
        print("FAIL a click in the search box must close the find widget\n");
        g_fails++;
    }
    // the search box keeps its own keys: Esc closes, Down enters the list
    app_key(K_ESCAPE, 0);
    g_checks++;
    if search_on {
        print("FAIL esc must still close the search view\n");
        g_fails++;
    }
    sq_len = 0;

    // the find widget: the arrows edit the query instead of closing
    // the widget, and the query found is the edited one
    app_key('F', MOD_CTRL);
    type_text("ab");
    app_key(K_LEFT, 0);
    type_text("c");
    g_checks++;
    if !find_on {
        print("FAIL an arrow must not close the find widget\n");
        g_fails++;
    }
    i64 a = 0;
    i64 b = 0;
    g_checks++;
    if !ed_sel_range(&a, &b) || a != 9 || b != 12 {
        print("FAIL find must match the edited query 'acb' ({}..{})\n", a, b);
        g_fails++;
    }
    app_key(K_PGDN, 0);
    g_checks++;
    if find_on {
        print("FAIL a page key must still close the find widget\n");
        g_fails++;
    }

    // the input box: the same editing
    g_has_path = false;
    g_path_len = 0;
    app_key('S', MOD_CTRL);
    type_text("ab");
    app_key(K_LEFT, 0);
    type_text("c");
    app_key(K_HOME, MOD_SHIFT);
    app_key('X', MOD_CTRL);
    type_text("d");
    app_key(K_END, 0);
    app_key('V', MOD_CTRL);
    g_checks++;
    if !ask_on || !str_equal(str_from(&ask_buf[0], ask_len), "dbac") {
        print("FAIL the prompt must edit like a field ('{}')\n", str_from(&ask_buf[0], ask_len));
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    g_checks++;
    if ask_on {
        print("FAIL esc must close the prompt\n");
        g_fails++;
    }
    plat_clipboard_set(null, 0);   // the leak count reads flat after
    close_all();
}

// --- the command palette ----------------------------------------------
// A row runs its chord through the key path, so what a row does is what
// the chord does. The checks press a few and read the same state the
// chord's own checks read.
private void test_palette() {
    reset("one\ntwo\n");
    tree_on = false;
    app_key('P', MOD_CTRL | MOD_SHIFT);
    g_checks++;
    // every command but the themes, which only the theme picker lists
    if !palette_on || palette_hit_count() != palette_count() - theme_count() || palette_count() < 40 {
        print("FAIL ctrl+shift+p must open the palette on every command ({} of {})\n",
            palette_hit_count(), palette_count());
        g_fails++;
    }
    // every name is distinct
    g_checks++;
    for i32 i = 0; i < palette_count(); i++ {
        for i32 j = i + 1; j < palette_count(); j++ {
            if str_equal(palette_name(i), palette_name(j)) {
                print("FAIL two commands share a name: {}\n", palette_name(i));
                g_fails++;
            }
        }
    }
    type_text("togsid");
    g_checks++;
    if palette_hit_count() < 1 || !str_equal(palette_hit_name(0), "View: Toggle Sidebar") {
        print("FAIL 'togsid' must put Toggle Sidebar first ({} hits, first '{}')\n",
            palette_hit_count(), palette_hit_name(0));
        g_fails++;
    }
    app_char(13);
    g_checks++;
    if palette_on || !tree_on {
        print("FAIL running Toggle Sidebar must close the palette and show the sidebar\n");
        g_fails++;
    }
    tree_on = false;
    // a Ctrl+K chord runs through the prefix, and the next typed
    // character still lands in the buffer
    bool sb = g_statusbar_on;
    app_key(K_F1, 0);
    g_checks++;
    if !palette_on {
        print("FAIL f1 must open the palette\n");
        g_fails++;
    }
    type_text("toggle status bar");
    app_char(13);
    g_checks++;
    if palette_on || g_statusbar_on == sb {
        print("FAIL running Toggle Status Bar must flip the status bar\n");
        g_fails++;
    }
    g_statusbar_on = sb;
    i64 before = tb_len();
    type_text("x");
    g_checks++;
    if tb_len() != before + 1 {
        print("FAIL the character after a palette chord must reach the buffer\n");
        g_fails++;
    }
    // Report Issue opens the issue tracker
    app_key('P', MOD_CTRL | MOD_SHIFT);
    type_text("report issue");
    app_char(13);
    g_checks++;
    if palette_on || !str_equal(str_from(&g_url_last[0], g_url_last_len), EDMINC_ISSUES_URL) {
        print("FAIL Report Issue must open the issue tracker (opened '{}')\n",
            str_from(&g_url_last[0], g_url_last_len));
        g_fails++;
    }
    // Ctrl+K Enter is a chord whose second key is text
    ignore ed_open_file("README.md");
    ignore ed_view_file("TESTING.md");
    app_key('P', MOD_CTRL | MOD_SHIFT);
    type_text("keep editor");
    app_char(13);
    g_checks++;
    if palette_on || ed_buf_preview(ed_buf_active()) {
        print("FAIL Keep Editor must keep the previewed buffer\n");
        g_fails++;
    }
    // a split and its close, through the palette
    app_key('P', MOD_CTRL | MOD_SHIFT);
    type_text("split editor");
    app_char(13);
    g_checks++;
    if ed_pane_count() != 2 {
        print("FAIL Split Editor must split ({} panes)\n", ed_pane_count());
        g_fails++;
    }
    app_key('P', MOD_CTRL | MOD_SHIFT);
    type_text("close editor group");
    app_char(13);
    g_checks++;
    if ed_pane_count() != 1 {
        print("FAIL Close Editor Group must close the pane ({} panes)\n", ed_pane_count());
        g_fails++;
    }
    // Esc closes, and the chord that opened it closes it too
    app_key('P', MOD_CTRL | MOD_SHIFT);
    app_key(K_ESCAPE, 0);
    g_checks++;
    if palette_on {
        print("FAIL esc must close the palette\n");
        g_fails++;
    }
    app_key('P', MOD_CTRL | MOD_SHIFT);
    app_key('P', MOD_CTRL | MOD_SHIFT);
    g_checks++;
    if palette_on {
        print("FAIL ctrl+shift+p again must close the palette\n");
        g_fails++;
    }
    // a query nothing matches: Enter closes and runs nothing
    app_key('P', MOD_CTRL | MOD_SHIFT);
    type_text("zzqx");
    g_checks++;
    if palette_hit_count() != 0 {
        print("FAIL 'zzqx' must match nothing ({} hits)\n", palette_hit_count());
        g_fails++;
    }
    app_char(13);
    g_checks++;
    if palette_on || ed_pane_count() != 1 {
        print("FAIL enter on no match must close and run nothing\n");
        g_fails++;
    }
    close_all();
}

// --- the overlays and the window with the keyboard -----------------------
// The overlays are globals, and every window's frame is built from
// them. They draw in the window the platform last reported focused,
// which is the one the keys reach; a closed key window hands that to
// the survivor.
private void test_overlay_window() {
    reset("one\n");
    i32 w0 = ed_window_active();
    i32 w1 = ed_window_new(ed_buf_active());
    app_focus(true);   // the driver routes the new window, then reports it key
    g_checks++;
    if w1 < 0 || !ed_overlay_here() {
        print("FAIL the focused window must draw the overlays\n");
        g_fails++;
    }
    // the caret blinks in the key window only, so a tick redraws that
    // window and leaves the other alone
    g_damage_calls = 0;
    g_damage_window_calls = 0;
    app_timer(BLINK_TIMER);
    g_checks++;
    if g_damage_calls != 0 || g_damage_window_calls != 1 || g_damage_window_last != w1 {
        print("FAIL a blink must redraw the key window only (all {} one {} window {})\n",
            g_damage_calls, g_damage_window_calls, g_damage_window_last);
        g_fails++;
    }
    // scrolling and moving the caret change this window only; a text
    // change reaches every window, since both show the buffer
    for i32 ln = 0; ln < 200; ln++ { app_char('x'); app_char(13); }
    app_key(K_HOME, MOD_CTRL);
    g_damage_calls = 0;
    g_damage_window_calls = 0;
    app_scroll(0.0f, cast(f32, 5 * font_line_h), gutter_w() + 40, doc_top() + 40);
    app_key(K_DOWN, 0);
    g_checks++;
    if g_damage_calls != 0 || g_damage_window_calls < 2 || g_damage_window_last != w1 {
        print("FAIL scrolling and a caret key must redraw their window only (all {} one {} window {})\n",
            g_damage_calls, g_damage_window_calls, g_damage_window_last);
        g_fails++;
    }
    app_char('y');
    g_checks++;
    if g_damage_calls == 0 {
        print("FAIL a text change must redraw every window\n");
        g_fails++;
    }
    app_key('P', MOD_CTRL | MOD_SHIFT);
    app_use_window(w0);
    g_checks++;
    if !palette_on || ed_overlay_here() {
        print("FAIL the other window must not draw the overlays\n");
        g_fails++;
    }
    app_use_window(w1);
    g_checks++;
    if !ed_overlay_here() {
        print("FAIL back in the key window the overlays draw again\n");
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    ignore ed_window_close();   // the key window goes; window 0 has the keyboard
    g_checks++;
    if ed_window_active() != w0 || !ed_overlay_here() {
        print("FAIL closing the key window must hand the keyboard to the survivor\n");
        g_fails++;
    }
    close_all();
}

// Smooth scrolling: a held caret key glides the drawn view a line per
// repeat. The logical scroll moves at once; the drawn one trails by up
// to two lines, keeps half a line of trail in reserve when the next
// repeat is due, and runs out once the key is released. A lone step
// snaps.
private void test_glide() {
    close_all();
    ignore ed_open_file("build/ed_test_glide.mc");
    app_key('A', MOD_CTRL);
    app_char(8);
    for i32 ln = 0; ln < 300; ln++ { app_char('x'); app_char(13); }
    app_key(K_HOME, MOD_CTRL);
    i64 step_was = g_clock_step;
    g_clock_step = 0;
    g_clock_us += 1000000;
    i32 lh = font_line_h;
    // down to the bottom edge: the first scroll is a lone step and snaps
    i32 top0 = top_line;
    i32 guard = 0;
    while top_line == top0 && guard < 500 {
        app_key(K_DOWN, 0);
        guard++;
    }
    g_checks++;
    if top_line != top0 + 1 || ed_glide_offset() != 0 {
        print("FAIL a lone caret scroll must snap (top {} -> {}, trail {})\n", top0, top_line, ed_glide_offset());
        g_fails++;
    }
    // the next repeat, 33 ms on: the logical scroll moves at once and
    // the drawn view starts a line behind
    g_clock_us += 33000;
    i32 top1 = top_line;
    app_key(K_DOWN, 0);
    g_checks++;
    if top_line != top1 + 1 || ed_glide_offset() != lh {
        print("FAIL a held caret key must scroll at once and glide the drawn view (top {} -> {}, trail {} of {})\n",
            top1, top_line, ed_glide_offset(), lh);
        g_fails++;
    }
    // halfway to the next repeat the view is on its way; when the
    // repeat is due, half a line of trail is left in reserve
    g_clock_us += 16500;
    i32 mid = ed_glide_offset();
    g_clock_us += 16500;
    i32 due = ed_glide_offset();
    g_checks++;
    if mid <= lh / 2 || mid >= lh || due < lh / 2 - 1 || due > lh / 2 + 1 {
        print("FAIL the glide must keep half a line in reserve at the next repeat (halfway {}, due {}, line {})\n", mid, due, lh);
        g_fails++;
    }
    // a steady hold: the view never arrives between repeats, and never
    // trails by more than two lines
    bool moving = true;
    bool bounded = true;
    i32 after = 0;
    for i32 k = 0; k < 8; k++ {
        if ed_glide_offset() <= 0 { moving = false; }
        app_key(K_DOWN, 0);
        after = ed_glide_offset();
        if after > 2 * lh { bounded = false; }
        g_clock_us += 33000;
    }
    g_checks++;
    if !moving || !bounded || after < lh + lh / 2 - 2 || after > lh + lh / 2 + 2 {
        print("FAIL a steady hold must keep the view moving within two lines (moving {} bounded {} after {} of {})\n",
            moving, bounded, after, lh);
        g_fails++;
    }
    // a repeat 12 ms late still finds the view moving
    g_clock_us += 12000;
    g_checks++;
    if ed_glide_offset() <= 0 {
        print("FAIL a late repeat must find the view still moving\n");
        g_fails++;
    }
    app_key(K_DOWN, 0);
    // released: the trail runs out within a few periods
    g_clock_us += 100000;
    g_checks++;
    if ed_glide_offset() != 0 {
        print("FAIL the trail must run out after the key is released ({})\n", ed_glide_offset());
        g_fails++;
    }
    // repeats faster than the glide never leave it more than two lines behind
    g_clock_us += 33000;
    app_key(K_DOWN, 0);
    for i32 k = 0; k < 5; k++ {
        g_clock_us += 2000;
        app_key(K_DOWN, 0);
    }
    g_checks++;
    if ed_glide_offset() > 2 * lh {
        print("FAIL the drawn view must trail by at most two lines ({} of {})\n", ed_glide_offset(), lh);
        g_fails++;
    }
    // a wheel's notch: three lines at once in the logical scroll, the
    // drawn view gliding after them, even alone
    i32 wx = gutter_w() + 40;
    i32 wy = doc_top() + 40;
    g_clock_us += 1000000;
    i32 top2 = top_line;
    app_scroll_notch(0.0f, cast(f32, 3 * lh), wx, wy);
    g_checks++;
    if top_line != top2 + 3 || ed_glide_offset() != 3 * lh {
        print("FAIL a wheel notch must scroll at once and glide (top {} -> {}, trail {} of {})\n",
            top2, top_line, ed_glide_offset(), 3 * lh);
        g_fails++;
    }
    g_clock_us += 31000;
    g_checks++;
    if ed_glide_offset() != 0 {
        print("FAIL a lone notch's glide must end within 30 ms (trail {})\n", ed_glide_offset());
        g_fails++;
    }
    // a touchpad's fine deltas never glide
    g_clock_us += 10000;
    app_scroll(0.0f, cast(f32, 2 * lh), wx, wy);
    g_checks++;
    if ed_glide_offset() != 0 {
        print("FAIL a touchpad scroll must not glide (trail {})\n", ed_glide_offset());
        g_fails++;
    }
    // sideways: whole columns, clamped to the widest line in view (the
    // 400 typed ahead of the line's x make it 401 wide)
    app_key(K_HOME, MOD_CTRL);
    for i32 k = 0; k < 400; k++ { app_char('w'); }
    app_key(K_HOME, 0);
    i32 lv0 = left_vcol;
    app_scroll(cast(f32, 10 * font_cell_w), 0.0f, wx, wy);
    i32 lv1 = left_vcol;
    app_scroll(cast(f32, -20 * font_cell_w), 0.0f, wx, wy);
    i32 lv2 = left_vcol;
    app_scroll(cast(f32, 5000 * font_cell_w), 0.0f, wx, wy);
    i32 lv3 = left_vcol;
    g_checks++;
    if lv0 != 0 || lv1 != 10 || lv2 != 0 || lv3 != 401 - text_cols() + 2 {
        print("FAIL sideways scrolling must move by columns and stop at the widest line ({} {} {} {}, cols {})\n",
            lv0, lv1, lv2, lv3, text_cols());
        g_fails++;
    }
    // Ctrl+K M turns it off: held keys and notches snap
    g_clock_us += 1000000;
    app_key('K', MOD_CTRL);
    app_key('M', 0);
    g_clock_us += 33000;
    app_key(K_DOWN, 0);
    g_clock_us += 33000;
    app_key(K_DOWN, 0);
    app_scroll_notch(0.0f, cast(f32, 3 * lh), wx, wy);
    g_checks++;
    if g_smooth_scroll || ed_glide_offset() != 0 {
        print("FAIL smooth scrolling off must snap (on {} trail {})\n", g_smooth_scroll, ed_glide_offset());
        g_fails++;
    }
    app_key('K', MOD_CTRL);
    app_key('M', 0);
    // a diff's notch glides too, and its two sides draw the same trail:
    // the base side follows the file's pane, which owns the scroll
    close_all();
    ed_diff_open("src/ed.mc");
    app_settle();
    i32 dx0 = 0;
    i32 dx1 = 0;
    ed_pane_rect(1, &dx0, &dx1);
    g_clock_us += 1000000;
    app_scroll_notch(0.0f, cast(f32, 3 * lh), (dx0 + dx1) / 2, doc_top() + 40);
    i32 dtrail = ed_glide_offset();
    i32[2] dy;
    ed_glide_frame();
    for i32 pi = 0; pi < 2; pi++ {
        ed_pane_swap_view(pi);
        ed_glide_begin(pi);
        dy[pi] = top_line * lh + scroll_off;
        ed_glide_end();
    }
    ed_pane_swap_view(ed_pane_active());
    i32 dlog = top_line * lh + scroll_off;
    g_checks++;
    if !ed_diff_on() || dtrail != 3 * lh || dy[0] != dy[1] || dy[1] != dlog - dtrail {
        print("FAIL a notch in a diff must glide both sides alike (diff {} trail {}, drawn {} {}, scroll {})\n",
            ed_diff_on(), dtrail, dy[0], dy[1], dlog);
        g_fails++;
    }
    // and a held arrow key at the bottom of the view, as in a file
    g_clock_us += 1000000;
    i32 dvis = visible_lines();
    while ed_row_of_line(cur_line) < top_line + dvis - 1 { app_key(K_DOWN, 0); }
    g_clock_us += 1000000;
    app_key(K_DOWN, 0);
    g_clock_us += 33000;
    app_key(K_DOWN, 0);
    g_checks++;
    if ed_glide_offset() != lh {
        print("FAIL a held arrow key in a diff must glide (trail {} of {})\n", ed_glide_offset(), lh);
        g_fails++;
    }
    g_clock_step = step_was;
    close_all();
}

// a typed closer on the last line of `body` in a file named `name`;
// the column of the marked opener on `line`, or -1
private i64 tt_brace(str name, str body, u32 closer, i32 line) {
    ignore file_write_str(name, body);
    close_all();
    ignore ed_open_file(name);
    app_key(K_END, MOD_CTRL);
    app_char(closer);
    i64 c = -1;
    bool fl = false;
    if !ed_brace_mark(line, &c, &fl) { return -1; }
    return c;
}

// tt_brace's mark on a line of the buffer as it is, or -1
private i64 tt_brace_at(i32 line) {
    i64 c = -1;
    bool fl = false;
    if !ed_brace_mark(line, &c, &fl) { return -1; }
    return c;
}

// the buffer holds exactly `want`
private bool tt_text_is(str want) {
    i64 n = tb_len();
    if n != cast(i64, want.len) { return false; }
    u8* b = alloc<u8>(n + 1);
    if n > 0 { tb_copy(0, b, n); }
    bool same = true;
    for i64 i = 0; i < n; i++ {
        if b[i] != want.data[i] {
            same = false;
            break;
        }
    }
    free(b);
    return same;
}

private void tt_text_check(str what, str want) {
    g_checks++;
    if !tt_text_is(want) {
        i64 n = tb_len();
        if n > 200 { n = 200; }
        noinit u8[200] got;
        if n > 0 { tb_copy(0, &got[0], n); }
        print("FAIL {}: [{}] want [{}]\n", what, str_from(&got[0], cast(i32, n)), want);
        g_fails++;
    }
}

// the query and the replacement typed over whatever they held, the
// replacement left with the keyboard
private void tt_find_fields(str q, str r) {
    if find_in_replace { app_key(K_TAB, 0); }
    // each chord's Ctrl is let go, which the platforms report as a
    // modifier-only change: Enter reads the modifiers held
    app_key('A', MOD_CTRL);
    app_hover(0, 0, 0);
    app_char(8);
    for i32 i = 0; i < q.len; i++ { app_char(cast(u32, q.data[i])); }
    app_key(K_TAB, 0);
    app_key('A', MOD_CTRL);
    app_hover(0, 0, 0);
    app_char(8);
    for i32 i = 0; i < r.len; i++ { app_char(cast(u32, r.data[i])); }
}

// Find and replace: Ctrl+H opens the replace row, Tab moves between
// the fields, Enter in the replacement replaces the selected match and
// selects the next, and Ctrl+Enter replaces every match as one
// undo step. Matching ignores case, as find does.
private void test_find_replace() {
    ignore dir_create("build/find");
    ignore file_write_str("build/find/r.txt", "Foo bar foo\nfoo baz\n");
    close_all();
    ignore ed_open_file("build/find/r.txt");
    app_key('H', MOD_CTRL);
    // the query persists from earlier finds: the replacement has the
    // keyboard when there is one
    g_checks++;
    if !find_on || !find_replace_on || find_in_replace != (find_qlen() > 0) {
        print("FAIL ctrl+h must open find with the replace row, the replacement first with a query (on {} replace {} in {})\n",
            find_on, find_replace_on, find_in_replace);
        g_fails++;
    }
    tt_find_fields("foo", "qux");
    g_checks++;
    if !find_in_replace || find_qlen() != 3 {
        print("FAIL tab must move to the replacement, the query kept (in {} qlen {})\n",
            find_in_replace, find_qlen());
        g_fails++;
    }
    tt_text_check("typing into the replacement must not edit the buffer", "Foo bar foo\nfoo baz\n");
    app_char(13);
    tt_text_check("enter must replace the selected match", "qux bar foo\nfoo baz\n");
    app_char(13);
    tt_text_check("a second enter must replace the next match", "qux bar qux\nfoo baz\n");
    app_key('Z', MOD_CTRL);
    tt_text_check("undo must take one replacement back", "qux bar foo\nfoo baz\n");
    // Enter brings no modifiers; the held ones come from the last key
    // or pointer report, as a modifier-only change sends them
    app_hover(0, 0, MOD_CTRL);
    app_char(13);
    app_hover(0, 0, 0);
    tt_text_check("ctrl+enter must replace every match", "qux bar qux\nqux baz\n");
    app_key('Z', MOD_CTRL);
    tt_text_check("one undo must take the whole replace-all back", "qux bar foo\nfoo baz\n");
    // a replacement that contains the query is not matched again
    ignore file_write_str("build/find/s.txt", "a a\n");
    close_all();
    ignore ed_open_file("build/find/s.txt");
    app_key('H', MOD_CTRL);
    tt_find_fields("a", "aa");
    app_char(13);
    app_char(13);
    tt_text_check("replacing a with aa must not replace its own output", "aa aa\n");
    // the widget stays through an undo, as the reference keeps it
    g_checks++;
    app_key('Z', MOD_CTRL);
    if !find_on {
        print("FAIL an undo must leave find and replace open\n");
        g_fails++;
    }
    app_key('Z', MOD_CTRL);
    tt_text_check("two undos must take both replacements back", "a a\n");
    // Windows sends Ctrl+Enter as a line feed
    app_char(10);
    tt_text_check("replace-all of a with aa", "aa aa\n");
    // Esc closes, and Ctrl+F opens without the replace row
    app_key(K_ESCAPE, 0);
    g_checks++;
    if find_on {
        print("FAIL esc must close find and replace\n");
        g_fails++;
    }
    app_key('F', MOD_CTRL);
    g_checks++;
    if !find_on || find_replace_on {
        print("FAIL ctrl+f must open find without the replace row (replace {})\n", find_replace_on);
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    close_all();
}

// the buffer holds exactly the baseline's bytes
private bool tt_buf_is_base() {
    i64 n = tb_len();
    if n != git_base_size() { return false; }
    u8* b = alloc<u8>(n + 1);
    if n > 0 { tb_copy(0, b, n); }
    u8* g = git_base_bytes();
    bool same = true;
    for i64 i = 0; i < n; i++ {
        if b[i] != g[i] {
            same = false;
            break;
        }
    }
    free(b);
    return same;
}

// revert every changed block, top first; the count it took, -1 when the
// changes do not run out
private i32 tt_revert_all() {
    for i32 k = 0; k < 400; k++ {
        i32 r = git_row_next_change(-1);
        if r < 0 { return k; }
        ed_diff_revert(r);
    }
    return -1;
}

// --- the diff's revert arrows: a block's baseline lines back in place
private void test_diff_revert() {
    close_all();
    ed_diff_open("src/pick.mc");
    app_settle();
    // the stub's baseline lacks every ninth line: each is an added block
    i32 nadd = tt_revert_all();
    g_checks++;
    if nadd <= 0 || !tt_buf_is_base() || git_row_next_change(-1) >= 0 {
        print("FAIL reverting every added block must give the baseline ({} blocks, {} bytes, base {})\n",
            nadd, tb_len(), git_base_size());
        g_fails++;
    }
    // a deleted line, the last line changed and a line added after it,
    // the first line deleted, a changed line
    cur_line = 30;
    cur_col = 0;
    app_key('K', MOD_CTRL | MOD_SHIFT);
    app_key(K_END, MOD_CTRL);
    app_char('t');
    app_char(13);
    app_char('u');
    app_key(K_HOME, MOD_CTRL);
    app_key('K', MOD_CTRL | MOD_SHIFT);
    app_key(K_DOWN, 0);
    app_key(K_DOWN, 0);
    app_char('x');
    // the first block is the deleted first line: a filler on this side
    i32 r0 = git_row_next_change(-1);
    // the arrow sits left of the numbers on the block's first row; the
    // pointer lights it and shows the hand
    i32 ax = ed_diff_revert_x() + 2;
    i32 ay = pane_doc_top(1) + (r0 - top_line) * font_line_h - scroll_off + font_line_h / 2;
    app_hover(ax, ay, 0);
    g_checks++;
    if r0 < 0 || ed_diff_revert_hover() != r0 || app_cursor_kind(ax, ay) != CURSOR_HAND
        || ed_diff_margin_w() <= 0 {
        print("FAIL a block's revert arrow must light under the pointer (row {}, hover {}, cursor {})\n",
            r0, ed_diff_revert_hover(), app_cursor_kind(ax, ay));
        g_fails++;
    }
    // a click on it reverts that block, as one undo step
    i32 nb = tb.nlines;
    app_mouse(ax, ay, 0, true, 0);
    app_mouse(ax, ay, 0, false, 0);
    g_checks++;
    if git_row_next_change(-1) == r0 || tb.nlines != nb + 1 {
        print("FAIL a click on the arrow must revert its block (first change {} was {}, {} lines was {})\n",
            git_row_next_change(-1), r0, tb.nlines, nb);
        g_fails++;
    }
    app_key('Z', MOD_CTRL);
    g_checks++;
    if git_row_next_change(-1) != r0 || tb.nlines != nb {
        print("FAIL undo must bring the reverted block back (first change {}, {} lines)\n",
            git_row_next_change(-1), tb.nlines);
        g_fails++;
    }
    // a row inside a block has no arrow
    g_checks++;
    if ed_diff_revert_row(r0 + 1) && git_row_kind(r0) != GIT_NONE && git_row_kind(r0 + 1) != GIT_NONE {
        print("FAIL only a block's first row carries an arrow\n");
        g_fails++;
    }
    i32 nmix = tt_revert_all();
    g_checks++;
    if nmix < 4 || !tt_buf_is_base() {
        print("FAIL reverting changed, deleted and added blocks must give the baseline ({} blocks, {} bytes, base {})\n",
            nmix, tb_len(), git_base_size());
        g_fails++;
    }
    // the base side has no arrows, and neither has a pane beside the diff
    g_checks++;
    if ed_diff_revert_hit(ed_diff_revert_x() - 2, ay) >= 0 {
        print("FAIL the baseline's pane must not take a revert click\n");
        g_fails++;
    }
    close_all();
}

// A typed ), ] or } marks the bracket it closes: past nested pairs and
// lines, not into strings or comments, not across a bracket of the
// wrong kind, and not in markdown. Typing after the closer keeps the
// mark, an edit before it ends it, and so does the timer.
private void test_brace() {
    ignore dir_create("build/brace");
    i64 m1 = tt_brace("build/brace/a.mc", "// ( c\nf(a[1], g(b), \"(\"", ')', 1);
    g_checks++;
    if m1 != 1 {
        print("FAIL a typed ) must mark its ( past nested pairs, a string and a comment ({})\n", m1);
        g_fails++;
    }
    i64 m2 = tt_brace("build/brace/b.c", "int f() {\n    x();\n", '}', 0);
    g_checks++;
    if m2 != 8 || tt_brace_at(2) != -1 {
        print("FAIL a typed } must mark its { lines above, and not itself ({})\n", m2);
        g_fails++;
    }
    // typing after the closer keeps the mark; an edit before it ends it
    app_char(';');
    i64 kept = tt_brace_at(0);
    app_key(K_HOME, 0);
    app_char(' ');
    i64 gone = tt_brace_at(0);
    g_checks++;
    if kept != 8 || gone != -1 {
        print("FAIL typing after the closer must keep the mark and an edit before it end it ({} {})\n", kept, gone);
        g_fails++;
    }
    i64 m3 = tt_brace("build/brace/c.mc", "f[a(", ']', 0);
    i64 m4 = tt_brace("build/brace/d.md", "a (b", ')', 0);
    i64 m5 = tt_brace("build/brace/e.mc", "x = \"(", ')', 0);
    g_checks++;
    if m3 != -1 || m4 != -1 || m5 != -1 {
        print("FAIL no mark across the wrong kind, in markdown or in a string ({} {} {})\n", m3, m4, m5);
        g_fails++;
    }
    i64 m6 = tt_brace("build/brace/f.mc", "g(", ')', 0);
    i64 bc6 = -1;
    bool fl0 = false;
    bool fl1 = true;
    ignore ed_brace_mark(0, &bc6, &fl0);
    app_timer(BRACE_TIMER);
    bool after_flash = ed_brace_mark(0, &bc6, &fl1);
    app_timer(BRACE_TIMER);
    g_checks++;
    if m6 != 1 || !fl0 || !after_flash || fl1 || tt_brace_at(0) != -1 {
        print("FAIL the mark must flash, keep its color, then end on the timer ({})\n", m6);
        g_fails++;
    }
    close_all();
}

// the command the last C build spawned: on Windows the script it
// wrote, elsewhere the `sh -c` words
private str tt_c_cmd() {
    when os(windows) {
        FileData fd = file_read("build/edminc_cc.cmd");
        if fd.data == null { return ""; }
        i32 n = cast(i32, fd.len);
        if n > 8192 { n = 8192; }
        memcpy(&g_spawn_cmd[0], fd.data, n);
        free(fd.data);
        g_spawn_cmd_len = n;
    }
    return str_from(&g_spawn_cmd[0], g_spawn_cmd_len);
}

// C and C++ buffers build and run themselves: a file with a main links
// into build/ and a run starts it, one without compiles to an object,
// a header is refused, and C++ takes the C++ compilers
private void test_build_c() {
    ignore dir_create("build/ctest");
    ignore file_write_str("build/ctest/hello.c", "#include <stdio.h>\nint main(void) {\n    return 0;\n}\n");
    ignore file_write_str("build/ctest/lib.c", "// main( is not here\nint main(void);\nint add(int a, int b) { return a + b; }\n");
    ignore file_write_str("build/ctest/ring.cpp", "auto main() -> int { return 0; }\n");
    ignore file_write_str("build/ctest/x.h", "int add(int a, int b);\n");
    str run_mark = "\"./$OUT\"";
    str exe_mark = "OUT=build/'hello'";
    str obj_mark = "-c \"$SRC\"";
    str cpp_mark = "c++ clang++ g++";
    str c17_mark = "";
    when os(windows) {
        c17_mark = "/std:c17 /experimental:c11atomics";
        run_mark = "\"%OUT%\"\r\nexit /b";
        exe_mark = "set \"OUT=build\\hello.exe\"";
        obj_mark = "/c \"%SRC%\"";
        cpp_mark = "/EHsc";
    }

    close_all();
    ignore ed_open_file("build/ctest/hello.c");
    app_key('R', MOD_CTRL);
    app_settle();
    str c1 = tt_c_cmd();
    bool run_ok = str_contains(c1, exe_mark) && str_contains(c1, run_mark);
    app_key('J', MOD_CTRL);
    app_key('B', MOD_CTRL | MOD_SHIFT);
    app_settle();
    str c2 = tt_c_cmd();
    g_checks++;
    if !run_ok || !str_contains(c2, exe_mark) || str_contains(c2, run_mark) || str_contains(c2, obj_mark)
        || !str_contains(c2, c17_mark) {
        print("FAIL a C file with a main must link into build/, ctrl+r running it and ctrl+shift+b not\n");
        g_fails++;
    }
    app_key('J', MOD_CTRL);

    close_all();
    ignore ed_open_file("build/ctest/lib.c");
    app_key(K_F5, 0);
    app_settle();
    str c3 = tt_c_cmd();
    g_checks++;
    if build_c_has_main() || !str_contains(c3, obj_mark) || str_contains(c3, run_mark) {
        print("FAIL a C file without a main (a declaration and a comment do not count) must compile only\n");
        g_fails++;
    }
    app_key('J', MOD_CTRL);

    close_all();
    ignore ed_open_file("build/ctest/ring.cpp");
    app_key('B', MOD_CTRL | MOD_SHIFT);
    app_settle();
    str c4 = tt_c_cmd();
    g_checks++;
    if !str_contains(c4, cpp_mark) || str_contains(c4, obj_mark)
        || (c17_mark.len > 0 && str_contains(c4, c17_mark)) {
        print("FAIL a C++ file must take the C++ compilers and link its main\n");
        g_fails++;
    }
    app_key('J', MOD_CTRL);

    close_all();
    ignore ed_open_file("build/ctest/x.h");
    i32 hc = g_minc_calls;
    app_key('B', MOD_CTRL | MOD_SHIFT);
    app_settle();
    g_checks++;
    if g_minc_calls != hc || build_is_running() {
        print("FAIL a header must not build\n");
        g_fails++;
    }
    close_all();
    g_status_len = 0;
}

private void test_settings() {
    // lenient JSON: comments and trailing commas, which the strict
    // parse (the LSP's) still refuses
    str lj = "// top\n{ \"a\": 1, /* mid */ \"b\": [1, 2,], }\n";
    JDoc d1;
    i32 r1 = json_parse_lenient(&d1, lj.data, cast(i64, lj.len));
    g_checks++;
    if r1 < 0 || jd_int(&d1, jd_get(&d1, r1, "a")) != 1 || jd_len(&d1, jd_get(&d1, r1, "b")) != 2 {
        print("FAIL a lenient parse must take comments and trailing commas\n");
        g_fails++;
    }
    json_free(&d1);
    JDoc d2;
    g_checks++;
    if json_parse(&d2, lj.data, cast(i64, lj.len)) >= 0 {
        print("FAIL the strict parse must refuse comments\n");
        g_fails++;
    }
    json_free(&d2);
    str bad = "{\n  \"a\": 1\n  \"b\": 2\n}";
    JDoc d3;
    i32 r3 = json_parse_lenient(&d3, bad.data, cast(i64, bad.len));
    g_checks++;
    if r3 >= 0 || json_fail_line(&d3) != 3 {
        print("FAIL a missing comma must fail on its line (line {})\n", json_fail_line(&d3));
        g_fails++;
    }
    json_free(&d3);

    // colors
    u32 c = 0;
    g_checks++;
    if !theme_parse_color("#1f2937", &c) || c != 0xFF37291F {
        print("FAIL #RRGGBB must parse\n");
        g_fails++;
    }
    g_checks++;
    if !theme_parse_color("#abc8", &c) || c != 0x88CCBBAA || theme_parse_color("1f2937", &c)
        || theme_parse_color("#12345", &c) || theme_parse_color("#12345g", &c) {
        print("FAIL color forms: #RGBA takes, a missing # or a wrong length refuses\n");
        g_fails++;
    }

    // a theme by name, and one slot over it
    g_checks++;
    if theme_find("dark modern") != 1 || theme_find("Nope") != -1 {
        print("FAIL themes must be found by name, ignoring case\n");
        g_fails++;
    }
    theme_load(theme_find("Monokai"));
    bool known = theme_override("editorCursor.foreground", 0xFF00CCFF);
    bool unknown = theme_override("editor.nothing", 0xFF000000);
    theme_commit();
    g_checks++;
    if C_BG != 0xFF222827 || C_CARET != 0xFF00CCFF || !known || unknown {
        print("FAIL a theme and an override must reach the palette (bg {} caret {})\n", C_BG, C_CARET);
        g_fails++;
    }

    // the file: a theme, overrides, one bad color and one unknown name,
    // which are skipped and reported while the rest apply
    str path = TT_SETTINGS;
    str body = "// mine\n{\n  \"workbench.colorTheme\": \"Light Modern\",\n  \"workbench.colorCustomizations\": {\n    \"editor.background\": \"#fafafa\", \"statusBar.background\": \"red\",\n  },\n  \"editor.tokenColorCustomizations\": { \"comments\": \"#00ff00\", \"textMateRules\": [] },\n  \"editor.smoothScrolling\": false,\n}\n";
    ignore file_write(path, FileData{ body.data, cast(i32, body.len) });
    g_status_len = 0;
    settings_load();
    g_checks++;
    if theme_current() != theme_find("Light Modern") || C_BG != 0xFFFAFAFA || C_COM != 0xFF00FF00
        || C_STATUS != 0xFFF8F8F8 || g_smooth_scroll {
        print("FAIL the settings file must apply its theme and overrides (theme {} bg {} com {} status {})\n",
            theme_current(), C_BG, C_COM, C_STATUS);
        g_fails++;
    }
    g_checks++;
    if g_status_len == 0 || !str_contains(str_from(&g_status_msg[0], g_status_len), "statusBar.background") {
        print("FAIL a bad color must be reported by its name ({})\n", str_from(&g_status_msg[0], g_status_len));
        g_fails++;
    }
    // the theme command: the value replaced, the comment and the rest kept
    settings_set_theme(theme_find("Dark Modern"));
    FileData fd = file_read(path);
    str after = str_from(fd.data, cast(i32, fd.len));
    g_checks++;
    if !str_contains(after, "\"workbench.colorTheme\": \"Dark Modern\"") || !str_contains(after, "// mine")
        || !str_contains(after, "#fafafa") || theme_current() != 1 || C_BG != 0xFFFAFAFA {
        print("FAIL a theme choice must rewrite only the theme's value and apply it\n");
        g_fails++;
    }
    free(fd.data);
    // a file without the key gets it
    str bare = "{ \"editor.smoothScrolling\": true }";
    ignore file_write(path, FileData{ bare.data, cast(i32, bare.len) });
    settings_set_theme(theme_find("Monokai"));
    FileData fd2 = file_read(path);
    str after2 = str_from(fd2.data, cast(i32, fd2.len));
    g_checks++;
    if !str_contains(after2, "\"workbench.colorTheme\": \"Monokai\"") || theme_current() != theme_find("Monokai") {
        print("FAIL a theme choice must add the key to a file without it ({})\n", after2);
        g_fails++;
    }
    free(fd2.data);
    // Zoom: Ctrl+= and Ctrl+- write window.zoomLevel in place and apply
    // it, Ctrl+0 resets it, and the file's own value is read at load
    app_key('=', MOD_CTRL);
    app_key('=', MOD_CTRL | MOD_SHIFT);
    FileData fz = file_read(path);
    str zs = str_from(fz.data, cast(i32, fz.len));
    i32 zn = 0;
    for i32 i = 0; i + 16 <= zs.len; i++ {
        if str_equal(str_from(zs.data + i, 16), "window.zoomLevel") { zn++; }
    }
    g_checks++;
    if ed_zoom() != 2 || zn != 1 || !str_contains(zs, "\"window.zoomLevel\": 2") || !str_contains(zs, "Monokai") {
        print("FAIL ctrl+= must write the zoom level once and apply it (zoom {}, {} keys: {})\n", ed_zoom(), zn, zs);
        g_fails++;
    }
    free(fz.data);
    for i32 i = 0; i < 3; i++ { app_key('-', MOD_CTRL); }
    FileData fz2 = file_read(path);
    g_checks++;
    if ed_zoom() != -1 || !str_contains(str_from(fz2.data, cast(i32, fz2.len)), "\"window.zoomLevel\": -1") {
        print("FAIL ctrl+- must zoom out past the default (zoom {})\n", ed_zoom());
        g_fails++;
    }
    free(fz2.data);
    app_key('0', MOD_CTRL);
    g_checks++;
    if ed_zoom() != 0 {
        print("FAIL ctrl+0 must reset the zoom ({})\n", ed_zoom());
        g_fails++;
    }
    for i32 i = 0; i < 20; i++ { app_key('=', MOD_CTRL); }
    g_checks++;
    if ed_zoom() != ZOOM_MAX {
        print("FAIL the zoom must stop at its largest level ({})\n", ed_zoom());
        g_fails++;
    }
    str zfile = "{ \"window.zoomLevel\": 1.6 }";
    ignore file_write(path, FileData{ zfile.data, cast(i32, zfile.len) });
    settings_load();
    g_checks++;
    if ed_zoom() != 2 {
        print("FAIL a fractional zoom level must round ({})\n", ed_zoom());
        g_fails++;
    }
    // and a file that is not JSON leaves the defaults and names the line
    str broken = "{\n  \"workbench.colorTheme\": \"Monokai\"\n  \"x\": 1\n}";
    ignore file_write(path, FileData{ broken.data, cast(i32, broken.len) });
    settings_load();
    g_checks++;
    if theme_current() != theme_find("Dark Modern") || !str_contains(str_from(&g_status_msg[0], g_status_len), "line 3") {
        print("FAIL a broken file must leave the defaults and name its line ({})\n",
            str_from(&g_status_msg[0], g_status_len));
        g_fails++;
    }
    // The theme picker: it opens on the theme in use, the selection is
    // previewed with the file's overrides on top, Escape puts the theme
    // back, and Enter keeps the selection and writes it.
    str picked = "{ \"workbench.colorTheme\": \"Monokai\", \"workbench.colorCustomizations\": { \"editor.background\": \"#101010\" } }";
    ignore file_write(path, FileData{ picked.data, cast(i32, picked.len) });
    settings_load();
    palette_open_themes();
    g_checks++;
    if !palette_on || palette_hit_count() != theme_count() || theme_current() != theme_find("Monokai") {
        print("FAIL the theme picker must list the themes and open on the one in use ({} rows, theme {})\n",
            palette_hit_count(), theme_current());
        g_fails++;
    }
    app_key(K_UP, 0);
    g_checks++;
    if theme_current() != theme_find("Monokai") - 1 || C_BG != 0xFF101010 {
        print("FAIL moving the picker must preview the theme under the overrides (theme {} bg {})\n",
            theme_current(), C_BG);
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    FileData pf = file_read(path);
    g_checks++;
    if palette_on || theme_current() != theme_find("Monokai")
        || !str_contains(str_from(pf.data, cast(i32, pf.len)), "Monokai") {
        print("FAIL Escape must close the picker and put the theme back, the file untouched\n");
        g_fails++;
    }
    free(pf.data);
    palette_open_themes();
    str dm = "dark m";
    for i32 i = 0; i < dm.len; i++ { app_char(cast(u32, dm.data[i])); }
    g_checks++;
    if theme_current() != theme_find("Dark Modern") {
        print("FAIL typing in the picker must preview the best match (theme {})\n", theme_current());
        g_fails++;
    }
    app_char(13);
    FileData pf2 = file_read(path);
    g_checks++;
    if palette_on || theme_current() != theme_find("Dark Modern")
        || !str_contains(str_from(pf2.data, cast(i32, pf2.len)), "\"Dark Modern\"") {
        print("FAIL Enter must keep the previewed theme and write it\n");
        g_fails++;
    }
    free(pf2.data);
    // the command row opens the picker
    app_key('P', MOD_CTRL | MOD_SHIFT);
    str ct = "color theme";
    for i32 i = 0; i < ct.len; i++ { app_char(cast(u32, ct.data[i])); }
    app_char(13);
    g_checks++;
    if !palette_on || palette_hit_count() != theme_count() {
        print("FAIL Preferences: Color Theme must open the picker ({} rows)\n", palette_hit_count());
        g_fails++;
    }
    app_key(K_ESCAPE, 0);

    // the drivers' entry on the interactive path reads the file, with a
    // file argument as with a folder
    str mono = "{ \"workbench.colorTheme\": \"Monokai\" }";
    ignore file_write(path, FileData{ mono.data, cast(i32, mono.len) });
    settings_set_enabled(false);
    ignore ed_open_file("src/pick.mc");
    ignore app_session_restore();
    g_checks++;
    if theme_current() != theme_find("Monokai") {
        print("FAIL app_session_restore must read the settings file\n");
        g_fails++;
    }
    ignore file_remove(path);
    // back to the defaults, then to Dark+ and off again as in any
    // harness run, for everything after this
    settings_load();
    g_checks++;
    if theme_current() != theme_find("Dark Modern") {
        print("FAIL a missing settings file must give Dark Modern ({})\n", theme_current());
        g_fails++;
    }
    settings_use_theme("Dark+");
    settings_set_enabled(false);
    g_smooth_scroll = true;
    g_status_len = 0;
    g_checks++;
    settings_set_theme(theme_find("Monokai"));
    if theme_current() != theme_find("Dark+") || path_exists(path) {
        print("FAIL settings off must not switch the theme or write the file\n");
        g_fails++;
    }
    g_status_len = 0;
}

// The image viewer (image.mc): a .png or .jpg opens as a buffer with an
// image and no text, decoded where it opens in this harness. It takes
// no typing and no save; + zooms and 0 fills the pane; a smaller image than the
// pane stays centered however it is panned; a file that is not an image
// says why; a change on disk decodes it again; closing frees it.
private u8* tt_rgba(i32 w, i32 h, u8 alpha) {
    u8* px = alloc<u8>(w * h * 4);
    for i32 i = 0; i < w * h; i++ {
        px[i * 4] = cast(u8, i % 251);
        px[i * 4 + 1] = cast(u8, (i * 7) % 253);
        px[i * 4 + 2] = cast(u8, (i * 13) % 255);
        px[i * 4 + 3] = 255;
    }
    px[3] = alpha;   // one texel, for the checkerboard
    return px;
}

// The history graph (hist.mc), on the harness's five commits: the log
// reads in with its lanes, the keys walk from the changes into the
// graph, a commit opens to its files, and a file opens its diff in that
// commit, read-only, against the first parent. A deleted file has an
// empty right side and the root's file an empty left one. The heading
// folds the panel, and HEAD moving reads the log again.
// Word wrap (Alt+Z): a long line takes more rows, broken after a space,
// a continuation row is indented as its line, the caret walks rows,
// Home and End go to a row's edge first, a click lands on the row under
// it, and the cached counts follow edits. Off again, a row is a line.
private void test_wrap() {
    close_all();
    i32 cols = wrap_cols();
    // three lines: words over three widths, a short one, and an indented
    // long one
    noinit u8[4096] t;
    i32 n = 0;
    i32 w = 0;
    while n < cols * 3 {
        str word = "word";
        memcpy(&t[n], word.data, word.len);
        n += word.len;
        t[n] = cast(u8, '0' + w % 10);
        n++;
        t[n] = ' ';
        n++;
        w++;
    }
    i32 len0 = n - 1;   // without the last space
    n = len0;
    str mid = "\nshort\n    ";
    memcpy(&t[n], mid.data, mid.len);
    n += mid.len;
    for i32 k = 0; k < cols / 4 + 4; k++ {
        str word = "abc ";
        memcpy(&t[n], word.data, word.len);
        n += word.len;
    }
    reset(str_from(&t[0], n));
    app_key('Z', MOD_ALT);
    i32 rows0 = wrap_line(0);
    bool breaks_ok = rows0 >= 3;
    for i32 k = 1; k < rows0; k++ {
        i32 b = wrap_row_start(k);
        if b <= 0 || t[b - 1] != ' ' { breaks_ok = false; }
        if wrap_row_v0(k) - wrap_row_v0(k - 1) > cols + 1 { breaks_ok = false; }
    }
    i32 rows2 = wrap_line(2);
    g_checks++;
    if !g_wrap || !breaks_ok || rows2 < 2 || wrap_row_lead(1) != 4
        || ed_row_count() != rows0 + 1 + rows2 || !wrap_verify() {
        print("FAIL wrap: rows, breaks after spaces, the indent ({} {} {} lead {} total {})\n",
            g_wrap, rows0, rows2, wrap_row_lead(1), ed_row_count());
        g_fails++;
    }
    // the caret walks rows; End goes to the row's end, then the line's
    ignore wrap_line(0);
    i32 b1 = wrap_row_start(1);
    cur_line = 0;
    cur_col = 0;
    app_key(K_DOWN, 0);
    bool down_ok = cur_line == 0 && ed_row_of_pos(cur_line, cur_col) == 1 && cur_col == b1;
    app_key(K_UP, 0);
    app_key(K_END, 0);
    bool end_row = cur_line == 0 && cur_col == b1 - 1;
    app_key(K_END, 0);
    bool end_line = cur_col == len0;
    app_key(K_HOME, 0);
    bool home_row = cur_col == wrap_row_start(rows0 - 1);
    app_key(K_HOME, 0);
    bool home_line = cur_col == 0;
    g_checks++;
    if !down_ok || !end_row || !end_line || !home_row || !home_line {
        print("FAIL wrap: the keys walk rows ({} {} {} {} {})\n", down_ok, end_row, end_line, home_row, home_line);
        g_fails++;
    }
    // a click on a continuation row's first cell, and past a row's end
    i32 px0 = 0;
    i32 px1 = 0;
    ed_pane_rect(ed_pane_active(), &px0, &px1);
    i32 x = px0 + gutter_w();
    i32 y = ed_line_y(0) + font_line_h + font_line_h / 2;
    app_mouse(x + 1, y, 0, true, 0);
    app_mouse(x + 1, y, 0, false, 0);
    bool click_ok = cur_line == 0 && cur_col == b1;
    app_mouse(px1 - 30, ed_line_y(0) + font_line_h / 2, 0, true, 0);
    app_mouse(px1 - 30, ed_line_y(0) + font_line_h / 2, 0, false, 0);
    bool past_ok = cur_line == 0 && cur_col < b1;
    g_checks++;
    if !click_ok || !past_ok {
        print("FAIL wrap: a click lands on the row under it ({} {} col {})\n", click_ok, past_ok, cur_col);
        g_fails++;
    }
    // edits move the counts with their lines
    cur_line = 0;
    cur_col = 0;
    type_text("extra words here ");
    app_char(13);
    app_char(13);
    cur_line = 3;
    cur_col = 0;
    type_text("x");
    app_key('Z', MOD_CTRL);
    app_key('Z', MOD_CTRL);
    app_key('Y', MOD_CTRL);
    g_checks++;
    if !wrap_verify() {
        print("FAIL wrap: the row counts must follow the edits\n");
        g_fails++;
    }
    // each pane wraps at its own width: two splits leave the first pane
    // half the area and the last a quarter
    app_key(92, MOD_CTRL);
    app_key(92, MOD_CTRL);
    i32 act = ed_pane_active();
    ed_pane_swap_view(0);
    i32 cols_wide = wrap_cols();
    i32 rows_wide = wrap_line(2);   // the long line, moved down by the edits
    ed_pane_swap_view(act);
    i32 cols_narrow = wrap_cols();
    i32 rows_narrow = wrap_line(2);
    g_checks++;
    if ed_pane_count() != 3 || cols_wide <= cols_narrow || rows_wide >= rows_narrow {
        print("FAIL wrap: each pane must wrap at its own width (cols {} {}, rows {} {})\n",
            cols_wide, cols_narrow, rows_wide, rows_narrow);
        g_fails++;
    }
    while ed_pane_count() > 1 { ignore ed_pane_close(); }
    // off again: rows are lines, and the caret's line stays in view
    app_key('Z', MOD_ALT);
    g_checks++;
    if g_wrap || ed_row_count() != tb.nlines {
        print("FAIL wrap: off again, a row must be a line\n");
        g_fails++;
    }
    close_all();
}

// Tab over a selection across lines indents each line, empty ones
// excepted, as one undo step, and keeps the lines selected; Shift+Tab
// takes an indent off, with or without a selection, and the Tab
// character Windows sends after it is not typed.
private void test_indent() {
    close_all();
    reset("a\nb\n\nc\nd");
    app_key(K_HOME, MOD_CTRL);
    app_key(K_DOWN, MOD_SHIFT);
    app_key(K_DOWN, MOD_SHIFT);
    app_key(K_DOWN, MOD_SHIFT);
    app_char(9);
    expect("    a\n    b\n\nc\nd", "tab must indent the selected lines, not the one the selection ends at the start of");
    i64 sa = 0;
    i64 sb = 0;
    bool kept = ed_sel_range(&sa, &sb) && sa == 0 && sb == 13;
    app_char(9);
    expect("        a\n        b\n\nc\nd", "tab again must indent again");
    app_key(K_TAB, MOD_SHIFT);
    app_char(9);   // the character Windows sends after the key
    expect("    a\n    b\n\nc\nd", "shift+tab must outdent the selected lines and type nothing");
    app_key('Z', MOD_CTRL);
    expect("        a\n        b\n\nc\nd", "one undo must take back the outdent of every line");
    g_checks++;
    if !kept {
        print("FAIL tab must keep the indented lines selected ({} {})\n", sa, sb);
        g_fails++;
    }
    // no selection: the caret's line, a tab or up to four spaces. Typed,
    // the tab would be spaces and the second line indented as the first.
    reset("");
    str raw = "\tx\n      y";
    plat_clipboard_set(raw.data, raw.len);
    app_key('V', MOD_CTRL);
    app_key(K_HOME, MOD_CTRL);
    app_key(K_TAB, MOD_SHIFT);
    app_key(K_DOWN, 0);
    app_key(K_TAB, MOD_SHIFT);
    expect("x\n  y", "shift+tab must take a tab or four spaces off the caret's line");
    // a selection inside one line is still replaced by the indent
    reset("abc");
    app_key(K_HOME, 0);
    app_key(K_RIGHT, MOD_SHIFT);
    app_char(9);
    expect("    bc", "tab over a selection in one line must replace it");
    close_all();
}

// Ctrl+K F, the new-file box
private void key_new_file() {
    app_key('K', MOD_CTRL);
    app_key('F', 0);
    app_char('f');
}

// Ctrl+N opens an untitled tab, also with the tree focused. Ctrl+K F
// asks for a file in the folder selected in the tree; Enter creates it,
// its directories with it, and opens it with its row selected. Ctrl+S
// on an untitled buffer opens the platform's save dialog in the project
// folder, and its answer is saved to as a project-relative path.
private void test_new_file() {
    close_all();
    bool tree_was = tree_on;
    tree_on = true;
    tree_mode = SIDE_FILES;
    tree_build();
    type_text("x");
    app_key('N', MOD_CTRL);
    i32 nb = ed_buf_count();
    app_key('N', MOD_CTRL);   // the active tab is untitled and empty: no other
    g_checks++;
    if nb != 2 || ed_buf_count() != 2 || ed_buf_dirty(ed_buf_active()) || g_has_path {
        print("FAIL ctrl+n must open one empty untitled tab ({} {})\n", nb, ed_buf_count());
        g_fails++;
    }
    type_text("y");
    tree_focus = true;
    app_key('N', MOD_CTRL);
    g_checks++;
    if ed_buf_count() != 3 || ask_on || tree_focus {
        print("FAIL ctrl+n with the tree focused must open an untitled tab too ({})\n", ed_buf_count());
        g_fails++;
    }
    // ctrl+s: the dialog in the project folder, then the save to its answer
    str saved = "build/ed_test_dialog.tmp";
    test_remove(saved);
    type_text("body");
    g_save_native = true;
    g_save_asks = 0;
    app_key('S', MOD_CTRL);
    noinit u8[PATH_MAX] cwd;
    i32 cn = plat_cwd(&cwd[0], PATH_MAX);
    bool asked_os = g_save_asks == 1 && !ask_on
        && str_equal(str_from(&g_save_dir[0], g_save_dir_len), str_from(&cwd[0], cn));
    noinit u8[PATH_MAX] abs;
    memcpy(&abs[0], &cwd[0], cn);
    abs[cn] = '/';
    memcpy(&abs[cn + 1], saved.data, saved.len);
    app_save_picked(&abs[0], cn + 1 + saved.len);
    FileData sfd = file_read(saved);
    g_checks++;
    if !asked_os || !g_has_path || !str_equal(str_from(&g_path[0], g_path_len), saved) || tb.dirty
        || sfd.data == null || !str_equal(str_from(sfd.data, cast(i32, sfd.len)), "body") {
        print("FAIL ctrl+s must save an untitled buffer where the dialog says ({} {})\n",
            asked_os, str_from(&g_path[0], g_path_len));
        g_fails++;
    }
    if sfd.data != null { free(sfd.data); }
    // a cancelled dialog leaves the buffer untitled
    app_key('N', MOD_CTRL);
    type_text("z");
    app_key('S', MOD_CTRL);
    app_save_picked(null, 0);
    g_checks++;
    if g_has_path || !tb.dirty || ask_on {
        print("FAIL a cancelled save dialog must leave the buffer as it was\n");
        g_fails++;
    }
    g_save_native = false;
    test_remove(saved);
    ignore dir_remove("build/ed_test_nf");
    ignore dir_remove("build/ed_test_nf2");
    // ctrl+k f: an input row at the top of the selected folder
    str made = "build/ed_test_nf/a.gml";
    i32 brow = tree_row_of("build");
    tree_select(brow);
    tree_focus = true;
    key_new_file();
    bool asked = tree_edit_kind() == TREE_EDIT_FILE && tree_sel() == brow + 1 && !ask_on;
    type_text("ed_test_nf/a.gml");
    app_char(13);
    i32 row = tree_row_of(made);
    g_checks++;
    if !asked || tree_edit_on() || file_size(made) < 0 || !str_equal(ed_buf_title(ed_buf_active()), "a.gml")
        || row < 0 || tree_sel() != row || tree_focus {
        print("FAIL a new file must be named in the tree's folder and opened (asked {} row {} sel {})\n",
            asked, row, tree_sel());
        g_fails++;
    }
    // a file row's folder is its parent; an existing name keeps the input
    i32 frow = tree_row_of("build/ed_test_nf");
    tree_focus = true;
    key_new_file();
    asked = tree_sel() == frow + 1;
    type_text("a.gml");
    app_char(13);
    g_checks++;
    if !asked || !tree_edit_on() {
        print("FAIL the input must start in a file's folder and refuse an existing name\n");
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    g_checks++;
    if tree_edit_on() || tree_row_count() == 0 || file_size("build/ed_test_nf/a.gmla.gml") >= 0 {
        print("FAIL esc must cancel the name\n");
        g_fails++;
    }
    // the right button on a folder: its menu; New Folder makes one in it
    tree_select(frow);
    app_mouse(4, font_line_h / 4 + frow * tree_row_h() - tr_scroll + 2, 1, true, 0);
    app_mouse(4, font_line_h / 4 + frow * tree_row_h() - tr_scroll + 2, 1, false, 0);
    g_checks++;
    bool has_rename = false;
    for i32 i = 0; i < menu_count(); i++ {
        if str_equal(menu_entry(i), "Rename...") { has_rename = true; }
    }
    if !menu_on || !str_equal(menu_entry(0), "New File...") || !str_equal(menu_entry(1), "New Folder...")
        || !has_rename || tree_sel() != frow {
        print("FAIL a right click on a folder must open its menu ({} {})\n", menu_on, menu_count());
        g_fails++;
    }
    app_key(K_DOWN, 0);
    app_key(K_DOWN, 0);
    app_char(13);
    bool folder_asked = !menu_on && tree_edit_kind() == TREE_EDIT_FOLDER;
    type_text("sub");
    app_char(13);
    g_checks++;
    if !folder_asked || !path_is_dir("build/ed_test_nf/sub") || tree_sel() != tree_row_of("build/ed_test_nf/sub") {
        print("FAIL the menu's New Folder must make the folder ({})\n", folder_asked);
        g_fails++;
    }
    // f2 on the open file: its stem is selected, so typing replaces it,
    // and the buffer follows the file
    tree_select(tree_row_of(made));
    tree_focus = true;
    app_key(K_F2, 0);
    bool stem = tree_edit_kind() == TREE_EDIT_RENAME && str_equal(tree_edit_text(), "a.gml");
    type_text("b");
    app_char(13);
    g_checks++;
    if !stem || tree_edit_on() || file_size(made) >= 0 || file_size("build/ed_test_nf/b.gml") < 0
        || !str_equal(str_from(&g_path[0], g_path_len), "build/ed_test_nf/b.gml") {
        print("FAIL f2 must rename the file, and its buffer with it ({} {})\n", stem, str_from(&g_path[0], g_path_len));
        g_fails++;
    }
    // a folder's rename takes the buffers under it and its open state
    tree_select(tree_row_of("build/ed_test_nf"));
    app_key(K_F2, 0);
    type_text("ed_test_nf2");
    app_char(13);
    g_checks++;
    if tree_edit_on() || !path_is_dir("build/ed_test_nf2")
        || !str_equal(str_from(&g_path[0], g_path_len), "build/ed_test_nf2/b.gml")
        || tree_row_of("build/ed_test_nf2/b.gml") < 0 {
        print("FAIL a folder's rename must move its buffers and stay open ({})\n", str_from(&g_path[0], g_path_len));
        g_fails++;
    }
    // a file's menu: Copy Relative Path
    i32 brw = tree_row_of("build/ed_test_nf2/b.gml");
    tree_select(brw);
    app_mouse(4, font_line_h / 4 + brw * tree_row_h() - tr_scroll + 2, 1, true, 0);
    i32 crel = -1;
    for i32 i = 0; i < menu_count(); i++ {
        if str_equal(menu_entry(i), "Copy Relative Path") { crel = i; }
    }
    i32 mx = 0;
    i32 my = 0;
    menu_entry_point(crel, &mx, &my);
    app_mouse(mx, my, 0, true, 0);
    g_checks++;
    if crel < 0 || menu_on || g_clip == null || !str_equal(str_from(g_clip, cast(i32, g_clip_len)), "build/ed_test_nf2/b.gml") {
        print("FAIL the menu's Copy Relative Path must copy the row's path\n");
        g_fails++;
    }
    // a press elsewhere commits a name being typed
    tree_select(tree_row_of("build/ed_test_nf2"));
    key_new_file();
    type_text("c.txt");
    app_mouse(content_left() + 40, 200, 0, true, 0);
    app_mouse(content_left() + 40, 200, 0, false, 0);
    g_checks++;
    if tree_edit_on() || file_size("build/ed_test_nf2/c.txt") < 0 {
        print("FAIL a press outside the input must commit the name\n");
        g_fails++;
    }
    // Delete in the tree: the selected file to the trash, by its
    // absolute path
    i32 crow = tree_row_of("build/ed_test_nf2/c.txt");
    tree_select(crow);
    tree_focus = true;
    g_trash_last_len = 0;
    app_key(K_DELETE, 0);
    str trashed = str_from(&g_trash_last[0], g_trash_last_len);
    g_checks++;
    if file_size("build/ed_test_nf2/c.txt") >= 0 || tree_row_of("build/ed_test_nf2/c.txt") >= 0
        || trashed.len <= 5 || !str_equal(str_from(trashed.data + trashed.len - 5, 5), "c.txt") {
        print("FAIL delete must move the file to the trash ({})\n", trashed);
        g_fails++;
    }
    g_checks++;
    if ed_buf_open("build/ed_test_nf2/c.txt") || !ed_buf_open("build/ed_test_nf2/b.gml") || !tree_focus {
        print("FAIL delete must close the file's buffer and no other\n");
        g_fails++;
    }
    // the menu key, and Shift+F10, open the selected row's menu on its
    // first entry
    tree_select(tree_row_of("build/ed_test_nf2/b.gml"));
    app_key(K_MENU, 0);
    bool by_key = menu_on && str_equal(menu_entry(0), "Open to the Side");
    app_key(K_ESCAPE, 0);
    app_key(K_F10, MOD_SHIFT);
    bool by_f10 = menu_on;
    app_char(13);   // its first entry: Open to the Side
    g_checks++;
    if !by_key || !by_f10 || menu_on || ed_pane_count() != 2
        || !str_equal(str_from(&g_path[0], g_path_len), "build/ed_test_nf2/b.gml") {
        print("FAIL the menu key must open the row's menu ({} {} panes {})\n", by_key, by_f10, ed_pane_count());
        g_fails++;
    }
    // from the right column, Open to the Side is the left one: two
    // columns stay two, whichever has the focus
    i32 side_from = ed_pane_active();
    tree_select(tree_row_of("README.md"));
    tree_focus = true;
    app_key(K_MENU, 0);
    app_char(13);
    g_checks++;
    if side_from != 1 || ed_pane_count() != 2 || ed_pane_active() != 0
        || !str_equal(str_from(&g_path[0], g_path_len), "README.md") {
        print("FAIL open to the side from the right column must use the left one ({} -> {}, panes {})\n",
            side_from, ed_pane_active(), ed_pane_count());
        g_fails++;
    }
    while ed_pane_count() > 1 { ignore ed_pane_close(); }
    tree_focus = true;
    // the menu's Reveal hands the file manager the absolute path
    brw = tree_row_of("build/ed_test_nf2/b.gml");
    tree_select(brw);
    app_mouse(4, font_line_h / 4 + brw * tree_row_h() - tr_scroll + 2, 1, true, 0);
    i32 rv = -1;
    for i32 i = 0; i < menu_count(); i++ {
        if menu_entry(i).len > 7 && str_equal(str_from(menu_entry(i).data, 7), "Reveal ") { rv = i; }
        if str_equal(menu_entry(i), "Open Containing Folder") { rv = i; }
    }
    if rv >= 0 {
        g_reveal_last_len = 0;
        menu_entry_point(rv, &mx, &my);
        app_mouse(mx, my, 0, true, 0);
        str shown = str_from(&g_reveal_last[0], g_reveal_last_len);
        g_checks++;
        if shown.len <= cn || !str_equal(str_from(shown.data + shown.len - 5, 5), "b.gml") {
            print("FAIL reveal must name the file by its absolute path ({})\n", shown);
            g_fails++;
        }
    } else {
        when os(wasm) {
        } else {
            g_checks++;
            print("FAIL the file's menu must offer Reveal (menu {} entries {} row {})\n", menu_on, menu_count(), brw);
            g_fails++;
        }
        menu_close();
    }
    ignore dir_remove("build/ed_test_nf2");
    close_all();
    tree_open_clear();
    tree_build();
    tree_focus = false;
    tree_on = tree_was;
}

private void test_history() {
    close_all();
    bool tree_was = tree_on;
    tree_on = true;
    tree_build();
    app_key('G', MOD_CTRL | MOD_SHIFT);
    app_settle();
    g_checks++;
    if hist_count() != 5 || !str_equal(hist_subject(0), "merge the side branch")
        || hist_lane_col(0) != 0 || hist_lane_col(1) != 0 || hist_lane_col(2) != 1
        || hist_lane_col(3) != 0 || hist_lane_col(4) != 0 || hist_more_left() {
        print("FAIL the log must read in with its lanes ({} commits, lanes {} {} {} {} {})\n", hist_count(),
            hist_lane_col(0), hist_lane_col(1), hist_lane_col(2), hist_lane_col(3), hist_lane_col(4));
        g_fails++;
    }
    // past the last change the keys go into the graph; Space opens the
    // commit and keeps them there
    app_key(K_END, 0);
    app_key(K_DOWN, 0);
    bool in_graph = hist_focus && hist_sel_row() == 0;
    app_key(K_DOWN, 0);
    app_char(32);
    app_settle();
    g_checks++;
    if !in_graph || hist_open_commit() != 1 || hist_file_count() != 2
        || !str_equal(hist_file_path(0), "src/pick.mc") || !hist_focus {
        print("FAIL the keys must reach the graph and Space must open a commit (graph {} open {} files {})\n",
            in_graph, hist_open_commit(), hist_file_count());
        g_fails++;
    }
    // Enter on its first file: the diff, read-only, against the parent
    app_key(K_DOWN, 0);
    app_char(13);
    app_settle();
    i64 len = tb_len();
    app_char('x');
    bool same = tb_len() == len && !tb.dirty;
    g_checks++;
    if !ed_diff_on() || !ed_diff_rev() || !ed_rev_on() || !str_equal(ed_buf_title(ed_buf_active()), "pick.mc @ 2222222")
        || !str_equal(ed_diff_name(), "pick.mc @ 4444444") || git_row_next_change(-1) < 0 || !same || tree_focus {
        print("FAIL a commit's file must open its diff, read-only (diff {} rev {} title [{}] left [{}] same {})\n",
            ed_diff_on(), ed_rev_on(), ed_buf_title(ed_buf_active()), ed_diff_name(), same);
        g_fails++;
    }
    // the deleted file: nothing on the right
    hist_activate(3);
    app_settle();
    g_checks++;
    if !ed_diff_on() || !ed_rev_on() || tb_len() != 0 || git_row_count() == 0 {
        print("FAIL a deleted file's diff must have an empty right side (diff {} len {})\n", ed_diff_on(), tb_len());
        g_fails++;
    }
    // the root commit's file: nothing on the left
    hist_activate(1);
    i32 root_row = 4;
    hist_activate(root_row);
    app_settle();
    hist_activate(root_row + 1);
    app_settle();
    g_checks++;
    if hist_open_commit() != 4 || !ed_diff_on() || !str_equal(ed_diff_name(), "pick.mc (none)") || tb_len() == 0 {
        print("FAIL the root's file must open against nothing (open {} diff {} left [{}])\n",
            hist_open_commit(), ed_diff_on(), ed_diff_name());
        g_fails++;
    }
    // the heading folds the panel and unfolds it
    i32 x = 20;
    i32 hy = tree_graph_head() + 2;
    tree_mouse(x, hy);
    bool folded = hist_folded;
    // folded, the changes take the height and the heading moves down
    i32 hy2 = tree_graph_head() + 2;
    tree_mouse(x, hy2);
    g_checks++;
    if !folded || hist_folded || hy2 <= hy {
        print("FAIL a click on the graph's heading must fold it and open it again (heading at {} then {})\n", hy, hy2);
        g_fails++;
    }
    // HEAD moved: the log is read again
    hist_head_moved();
    bool cleared = hist_count() == 0;
    app_settle();
    g_checks++;
    if !cleared || hist_count() != 5 || hist_open_commit() != -1 {
        print("FAIL HEAD moving must read the log again ({} commits)\n", hist_count());
        g_fails++;
    }
    ed_diff_close();
    close_all();
    app_key('E', MOD_CTRL | MOD_SHIFT);
    tree_focus = false;
    hist_focus = false;
    tree_on = tree_was;
}

// A drag selection scrolls the view while the pointer is near or past
// the top or bottom of the text, with the pointer at rest, on a timer
// that runs only in that zone: in a document, and into a terminal's
// history.
private void test_drag_scroll() {
    close_all();
    i64 step_was = g_clock_step;
    g_clock_step = 0;
    ignore ed_open_file("src/ed.mc");
    i32 lh = font_line_h;
    i32 x = content_left() + gutter_w() + 40;
    i32 vis = visible_lines();
    i32 bot = doc_top() + vis * lh;
    app_mouse(x, doc_top() + 5 * lh + 2, 0, true, 0);
    i64 anchor = tb_line_start(cur_line) + cur_col;
    i32 top0 = top_line;
    // the last row's lower half is the zone: the timer starts there
    app_mouse_move(x, bot - 2);
    bool armed = g_drag_timer;
    g_clock_us += 500000;
    app_timer(DRAG_SCROLL_TIMER);
    i32 top1 = top_line;
    // at rest it keeps going, and the head stays on the last row
    g_clock_us += 500000;
    app_timer(DRAG_SCROLL_TIMER);
    i32 top2 = top_line;
    i64 sa = 0;
    i64 sb = 0;
    bool has = ed_sel_range(&sa, &sb);
    g_checks++;
    if !armed || top1 <= top0 || top2 <= top1 || cur_line != top_line + vis - 1
        || !has || sa != anchor {
        print("FAIL a drag at the bottom edge must scroll on the timer and extend the selection (armed {} top {} {} {}, caret {} of {})\n",
            armed, top0, top1, top2, cur_line, top_line + vis - 1);
        g_fails++;
    }
    // further past the edge is faster; back in the middle it stops
    i32 slow = top2 - top1;
    app_mouse_move(x, bot + 4 * lh);
    g_clock_us += 500000;
    app_timer(DRAG_SCROLL_TIMER);
    i32 fast = top_line - top2;
    app_mouse_move(x, doc_top() + 5 * lh);
    bool stopped = !g_drag_timer;
    g_checks++;
    if fast <= slow || !stopped {
        print("FAIL the autoscroll must speed up past the edge and stop inside the text (lines {} then {}, stopped {})\n",
            slow, fast, stopped);
        g_fails++;
    }
    // upwards past the top, and the release ends it
    app_mouse_move(x, doc_top() - 2 * lh);
    i32 top3 = top_line;
    g_clock_us += 300000;
    app_timer(DRAG_SCROLL_TIMER);
    // the head is on the first row that shows whole
    i32 first_whole = top_line;
    if scroll_off > 0 { first_whole++; }
    bool up = top_line < top3 && cur_line == first_whole;
    app_mouse(x, doc_top() - 2 * lh, 0, false, 0);
    g_checks++;
    if !up || g_drag_timer {
        print("FAIL a drag above the text must scroll up, and the release must stop it (top {} -> {}, caret {}, timer {})\n",
            top3, top_line, cur_line, g_drag_timer);
        g_fails++;
    }
    close_all();

    // a terminal: a drag above the grid scrolls into the history, and
    // the selection's head follows to the top row
    ignore ed_open_file("doc/TESTING.md");
    term_threaded = false;
    tt_open_term();
    i32 t = ed_term_active();
    for i32 k = 0; k < 200; k++ { tt_feed(t, "a line of output\r\n"); }
    i32 tx0 = 0;
    i32 tx1 = 0;
    ed_pane_rect(ed_pane_active(), &tx0, &tx1);
    // clear of the tree's divider, which a press at the pane's edge takes
    i32 tx = tx0 + TERM_PAD_PX + 4 * font_cell_w + font_cell_w / 2;
    app_mouse(tx, doc_top() + 5 * lh + 2, 0, true, 0);
    app_mouse_move(tx + 3 * font_cell_w, doc_top() - lh);
    bool tarmed = g_drag_timer;
    g_clock_us += 500000;
    app_timer(DRAG_SCROLL_TIMER);
    i64 l0 = 0;
    i64 l1 = 0;
    i32 c0 = 0;
    i32 c1 = 0;
    bool tsel = ed_term_sel_get(t, &l0, &c0, &l1, &c1);
    i32 view = term_view(t);
    i64 abs_top = term_abs_top(t);
    app_mouse(tx, doc_top() - lh, 0, false, 0);
    g_checks++;
    if !tarmed || view <= 0 || !tsel || l0 != abs_top || g_drag_timer {
        print("FAIL a terminal drag above the grid must scroll into the history and select to the top row (armed {} view {} sel {} head {} top {})\n",
            tarmed, view, tsel, l0, abs_top);
        g_fails++;
    }
    app_key('W', MOD_CTRL);
    close_all();
    g_clock_step = step_was;
}

private void test_images() {
    close_all();
    u8* px = tt_rgba(40, 30, 128);
    ignore png_save("build/t_img.png", px, 40, 30);
    free(px);
    px = tt_rgba(64, 48, 255);
    ignore jpeg_save("build/t_img.jpg", px, 64, 48, 90);
    free(px);
    ignore file_write_str("build/t_bad.png", "not an image at all");

    ignore ed_open_file("build/t_img.png");
    i32 im = ed_buf_img(ed_buf_active());
    g_checks++;
    if im < 0 || image_state(im) != IMG_READY || image_w(im) != 40 || image_h(im) != 30
        || !image_alpha(im) || tb_len() != 0 {
        print("FAIL a PNG must open as an image buffer, decoded (img {} state {})\n", im, image_state(im));
        g_fails++;
        close_all();
        return;
    }
    // no text goes in, and a save leaves the file as it is
    FileData before = file_read("build/t_img.png");
    app_char('x');
    app_key('V', MOD_CTRL);
    app_key('S', MOD_CTRL);
    FileData after = file_read("build/t_img.png");
    bool same = before.len == after.len && before.len > 0
        && tb_hash(before.data, cast(i64, before.len)) == tb_hash(after.data, cast(i64, after.len));
    free(before.data);
    free(after.data);
    g_checks++;
    if tb_len() != 0 || tb.dirty || !same {
        print("FAIL an image buffer must take no text and never be saved (len {} dirty {} same {})\n",
            tb_len(), tb.dirty, same);
        g_fails++;
    }
    // the view: fitted in a 400 by 300 pane it shows at its own size
    f32 ox = 0.0f;
    f32 oy = 0.0f;
    f32 s0 = image_scale(im, 400, 300);
    image_place(im, 0, 0, 400, 300, s0, &ox, &oy);
    app_char('+');
    bool zoomed = !image_fitted(im) && image_scale(im, 400, 300) > s0;
    // smaller than the pane: panning leaves it centered
    image_pan(im, 500.0f, 0.0f);
    f32 s1 = image_scale(im, 400, 300);
    image_place(im, 0, 0, 400, 300, s1, &ox, &oy);
    bool centered = ox + cast(f32, 40) * s1 * 0.5f > 199.0f && ox + cast(f32, 40) * s1 * 0.5f < 201.0f;
    // 0 fits it to the pane, scaled up past its own size
    app_char('0');
    f32 s2 = image_scale(im, 400, 300);
    g_checks++;
    if s0 != 1.0f || !zoomed || !centered || !image_fitted(im) || s2 != 10.0f {
        print("FAIL the zoom keys and the pan must keep the image in the pane (fit {} zoomed {} centered {} filled {})\n",
            s0, zoomed, centered, s2);
        g_fails++;
    }
    // a JPEG, and a file that is not an image at all
    ignore ed_open_file("build/t_img.jpg");
    i32 jm = ed_buf_img(ed_buf_active());
    ignore ed_open_file("build/t_bad.png");
    i32 bm = ed_buf_img(ed_buf_active());
    g_checks++;
    if jm < 0 || image_state(jm) != IMG_READY || image_w(jm) != 64 || image_alpha(jm)
        || bm < 0 || image_state(bm) != IMG_FAILED || !str_contains(image_error(bm), "not a PNG or JPEG") {
        print("FAIL a JPEG must decode, and a file that is not an image must say so (jpeg {} bad [{}])\n",
            image_state(jm), image_error(bm));
        g_fails++;
    }
    // the file changed on disk: decoded again at its new size
    px = tt_rgba(20, 10, 255);
    ignore png_save("build/t_img.png", px, 20, 10);
    free(px);
    image_disk_check(im);
    g_checks++;
    if image_w(im) != 20 || image_h(im) != 10 || image_alpha(im) {
        print("FAIL a changed image file must be decoded again ({} x {})\n", image_w(im), image_h(im));
        g_fails++;
    }
    // closing frees the image; the slot takes the next one
    close_all();
    g_checks++;
    if image_state(im) != IMG_FAILED || ed_buf_img(ed_buf_active()) != -1 {
        print("FAIL closing an image buffer must free its image\n");
        g_fails++;
    }
    ignore file_remove("build/t_img.png");
    ignore file_remove("build/t_img.jpg");
    ignore file_remove("build/t_bad.png");
}

// The gitignore rules (gitignore.mc): git's wildcards, a pattern with a
// slash tied to its file's folder, "!" and folder-only patterns, the
// .gitignore of a folder below the root, and the settings: the tree
// dims ignored entries or hides them, files.exclude hides everywhere.
private bool tt_wild(str p, str s) {
    return ign_wild(p.data, p.len, s.data, s.len);
}

private void test_gitignore() {
    g_checks++;
    if !tt_wild("*.log", "a.log") || tt_wild("*.log", "dir/a.log")
        || !tt_wild("**/x", "x") || !tt_wild("**/x", "a/b/x")
        || !tt_wild("a/**", "a/b/c") || tt_wild("a/**", "a")
        || !tt_wild("a/**/b", "a/b") || !tt_wild("a/**/b", "a/x/y/b")
        || !tt_wild("f?o", "foo") || tt_wild("f?o", "f/o")
        || !tt_wild("[a-c]x", "bx") || tt_wild("[a-c]x", "dx") || tt_wild("[!a]x", "ax")
        || !tt_wild("\\*x", "*x") || tt_wild("\\*x", "ax") {
        print("FAIL the ignore patterns must follow git's wildcards\n");
        g_fails++;
    }
    // the repository's own .gitignore: build/, __pycache__/, a path
    ign_reset();
    g_checks++;
    if !ign_match("build", true) || ign_match("build", false)
        || !ign_match("scripts/__pycache__", true)
        || !ign_match("assets/NotoColorEmoji.ttf", false)
        || ign_match("x/assets/NotoColorEmoji.ttf", false)
        || !ign_match("CLAUDE.local.md", false) || ign_match("src/ed.mc", false) {
        print("FAIL the root .gitignore must match as git does\n");
        g_fails++;
    }
    // a folder's own .gitignore, with a negation and an anchored pattern
    ignore dir_create("build/igt");
    ignore file_write_str("build/igt/.gitignore", "*.tmp\n!keep.tmp\n/root_only\n");
    ign_reset();
    g_checks++;
    if !ign_match("build/igt/a.tmp", false) || ign_match("build/igt/keep.tmp", false)
        || !ign_match("build/igt/sub/b.tmp", false)
        || !ign_match("build/igt/root_only", false) || ign_match("build/igt/sub/root_only", false)
        || !ign_git("build/igt/keep.tmp", false) {
        print("FAIL a folder's .gitignore must apply below it, with negation and anchoring\n");
        g_fails++;
    }
    ignore file_remove("build/igt/.gitignore");
    ign_reset();

    // the tree: the ignored build folder dimmed by default, hidden with
    // explorer.excludeGitIgnore; files.exclude hides everywhere
    tree_build();
    i32 row = -1;
    for i32 i = 0; i < tree_row_count(); i++ {
        if str_equal(tree_row_path(i), "build") { row = i; }
    }
    bool dimmed = row >= 0 && tree_row_ign(row);
    ignore ign_settings(true, true, "");
    tree_build();
    bool hidden = true;
    for i32 i = 0; i < tree_row_count(); i++ {
        if str_equal(tree_row_path(i), "build") { hidden = false; }
    }
    ignore ign_settings(false, true, "doc\n**/*.bak\n");
    tree_build();
    bool doc_gone = true;
    for i32 i = 0; i < tree_row_count(); i++ {
        if str_equal(tree_row_path(i), "doc") { doc_gone = false; }
    }
    g_checks++;
    if !dimmed || !hidden || !doc_gone || !ign_excluded("a/b.bak") || !ign_excluded(".git")
        || ign_excluded("src") {
        print("FAIL the tree must dim ignored entries, hide them on request, and hide files.exclude (dim {} hide {} doc {})\n",
            dimmed, hidden, doc_gone);
        g_fails++;
    }
    ignore ign_settings(false, true, "");

    // the settings file's keys reach the rules
    str body = "{ \"explorer.excludeGitIgnore\": true, \"search.useIgnoreFiles\": false, \"files.exclude\": { \"**/*.tmp\": true, \"doc\": false } }";
    ignore file_write_str(TT_SETTINGS, body);
    settings_set_enabled(true);
    settings_load();
    bool read = ign_tree_hides_now() && ign_excluded("x/y.tmp") && !ign_excluded("doc")
        && !ign_lists_skip("build", true);
    ignore file_remove(TT_SETTINGS);
    settings_load();
    settings_use_theme("Dark+");
    settings_set_enabled(false);
    g_checks++;
    if !read || ign_tree_hides_now() || !ign_lists_skip("build", true) {
        print("FAIL the settings file's ignore keys must apply, and their absence restore the defaults\n");
        g_fails++;
    }
    tree_build();
}

// The call graph without a server: the rows come in as the replies'
// parse hands them over. The layout puts the callers above the center
// and the callees below, a row with more than fit is a card per file,
// Up and Enter make a caller the center, Backspace goes back, Enter on
// the center opens it, Escape closes.
private void tt_call_item(CallItem* it, str name, str path, i32 line) {
    memcpy(&it.name[0], name.data, name.len);
    it.name_len = name.len;
    memcpy(&it.path[0], path.data, path.len);
    it.path_len = path.len;
    it.detail_len = 0;
    it.l0 = line;
    it.c0 = 0;
    it.l1 = line + 3;
    it.c1 = 1;
    it.sl0 = line;
    it.sc0 = 5;
    it.sl1 = line;
    it.sc1 = 5 + name.len;
}

private void test_calls() {
    close_all();
    app_resize(1200, 800);
    CallItem c;
    tt_call_item(&c, "pick_open", "src/pick.mc", 10);
    calls_show_for_test();
    calls_center_found(&c);
    CallItem it;
    calls_rows_begin(true);
    tt_call_item(&it, "a_one", "src/a.mc", 1);
    calls_row_add(true, &it, 1, 2);
    tt_call_item(&it, "b_one", "src/b.mc", 1);
    calls_row_add(true, &it, 2, 2);
    tt_call_item(&it, "a_two", "src/a.mc", 9);
    calls_row_add(true, &it, 1, 10);
    calls_rows_done(true);
    calls_rows_begin(false);
    tt_call_item(&it, "c_one", "src/c.mc", 4);
    calls_row_add(false, &it, 1, 5);
    calls_rows_done(false);
    calls_relayout();
    // the rows are grouped by file: a, a, b
    CallItem* second = calls_item(0, 1);
    g_checks++;
    if !calls_on || calls_phase_now() != CALLS_READY || calls_card_count() != 5
        || !str_equal(str_from(&second.name[0], second.name_len), "a_two") {
        print("FAIL the call graph must show the center, three callers and a callee ({} cards, second [{}])\n",
            calls_card_count(), str_from(&second.name[0], second.name_len));
        g_fails++;
    }
    // the callers above the center, the callee below
    i32 x = 0;
    i32 y = 0;
    i32 w = 0;
    i32 h = 0;
    i32 cy = 0;
    calls_card_rect(0, &x, &cy, &w, &h);
    bool above = true;
    bool below = true;
    for i32 i = 1; i < calls_card_count(); i++ {
        calls_card_rect(i, &x, &y, &w, &h);
        if calls_card_row(i) == 0 && y >= cy { above = false; }
        if calls_card_row(i) == 1 && y <= cy { below = false; }
    }
    g_checks++;
    if !above || !below {
        print("FAIL callers must sit above the center and callees below it\n");
        g_fails++;
    }
    // the center is sized to its function and sits in the middle: four
    // short lines fit whole at full size
    i32 ax = 0;
    i32 ay = 0;
    i32 aw = 0;
    i32 ah = 0;
    calls_band(0, &ax, &ay, &aw, &ah);
    calls_card_rect(0, &x, &cy, &w, &h);
    g_checks++;
    if calls_center_cols() != 1 || calls_center_more() != 0 || calls_center_scale() != 1.0f
        || w >= aw || (x + w / 2) - (ax + aw / 2) > 1 || (ax + aw / 2) - (x + w / 2) > 1 {
        print("FAIL a short function must fit whole, centered (cols {} more {} x {} w {} area {} {})\n",
            calls_center_cols(), calls_center_more(), x, w, ax, aw);
        g_fails++;
    }
    // a long narrow function takes two columns; a long wide one is cut
    // in one, the rest counted
    str nl = "    i++;\n";
    str wl = "wide_name wide_name wide_name wide_name wide_name wide_name wide_name wide_name wide_name wide_name wide_name wide_name\n";
    u8* nb2 = alloc<u8>(400 * nl.len);
    u8* wb2 = alloc<u8>(400 * wl.len);
    for i32 i = 0; i < 400; i++ {
        memcpy(nb2 + i * nl.len, nl.data, nl.len);
        memcpy(wb2 + i * wl.len, wl.data, wl.len);
    }
    ignore file_write_str("build/calls_narrow.mc", str_from(nb2, 400 * nl.len));
    ignore file_write_str("build/calls_wide.mc", str_from(wb2, 400 * wl.len));
    free(nb2);
    free(wb2);
    CallItem longf;
    tt_call_item(&longf, "long_narrow", "build/calls_narrow.mc", 0);
    longf.l1 = 399;
    calls_center_found(&longf);
    calls_files_drop();
    calls_relayout();
    bool two = calls_center_cols() == 2 && calls_center_more() > 0;
    tt_call_item(&longf, "long_wide", "build/calls_wide.mc", 0);
    longf.l1 = 399;
    calls_center_found(&longf);
    calls_relayout();
    g_checks++;
    if !two || calls_center_cols() != 1 || calls_center_more() <= 0 {
        print("FAIL a long function must take two columns when narrow, one cut when wide (two {} cols {} more {})\n",
            two, calls_center_cols(), calls_center_more());
        g_fails++;
    }
    ignore file_remove("build/calls_narrow.mc");
    ignore file_remove("build/calls_wide.mc");
    // back to the first center and its rows
    calls_center_found(&c);
    calls_rows_begin(true);
    tt_call_item(&it, "a_one", "src/a.mc", 1);
    calls_row_add(true, &it, 1, 2);
    tt_call_item(&it, "b_one", "src/b.mc", 1);
    calls_row_add(true, &it, 2, 2);
    tt_call_item(&it, "a_two", "src/a.mc", 9);
    calls_row_add(true, &it, 1, 10);
    calls_rows_done(true);
    calls_rows_begin(false);
    tt_call_item(&it, "c_one", "src/c.mc", 4);
    calls_row_add(false, &it, 2, 11);
    calls_row_site(false, 11, 4, 9);
    calls_row_site(false, 12, 8, 13);
    calls_rows_done(false);
    calls_relayout();
    // a callee keeps its sites in the center, and the selection on its
    // card makes it the one the center marks
    i32 sl = 0;
    i32 s0 = 0;
    i32 s1 = 0;
    calls_row_site_at(1, 0, 1, &sl, &s0, &s1);
    bool before_sel = calls_callee_selected(0);
    app_key(K_DOWN, 0);
    g_checks++;
    if calls_row_nsite(1, 0) != 2 || sl != 12 || s0 != 8 || s1 != 13 || before_sel || !calls_callee_selected(0) {
        print("FAIL a callee must keep its sites and be marked when its card is selected (sites {} line {} sel {} {})\n",
            calls_row_nsite(1, 0), sl, before_sel, calls_callee_selected(0));
        g_fails++;
    }
    app_key(K_UP, 0);   // back to the center
    // Up picks the nearest caller; Enter makes it the center
    app_key(K_UP, 0);
    i32 sel = calls_selected();
    i32 picked = calls_card_idx(sel);
    CallItem* want = calls_item(0, picked);
    noinit u8[64] wn;
    memcpy(&wn[0], &want.name[0], want.name_len);
    str wname = str_from(&wn[0], want.name_len);
    app_char(13);
    CallItem* now = calls_center_item();
    g_checks++;
    if calls_card_row(sel) != 0 || calls_trail_len() != 1
        || !str_equal(str_from(&now.name[0], now.name_len), wname) || !calls_row_loading(0) {
        print("FAIL Up and Enter must make a caller the center (trail {} center [{}] want [{}])\n",
            calls_trail_len(), str_from(&now.name[0], now.name_len), wname);
        g_fails++;
    }
    // Backspace goes back along the trail
    app_char(8);
    now = calls_center_item();
    g_checks++;
    if calls_trail_len() != 0 || !str_equal(str_from(&now.name[0], now.name_len), "pick_open") {
        print("FAIL Backspace must go back to the previous center ([{}])\n", str_from(&now.name[0], now.name_len));
        g_fails++;
    }
    // more callers than fit: a card per file, and Enter on one opens it
    calls_rows_begin(true);
    noinit u8[32] nb;
    for i32 i = 0; i < 30; i++ {
        str f = "src/a.mc";
        if i % 3 == 1 { f = "src/b.mc"; }
        if i % 3 == 2 { f = "src/c.mc"; }
        str pre = "fn_";
        memcpy(&nb[0], pre.data, pre.len);
        i32 n = pre.len + fmt_i32(&nb[pre.len], i);
        tt_call_item(&it, str_from(&nb[0], n), f, i);
        calls_row_add(true, &it, 1, i);
    }
    calls_rows_done(true);
    calls_relayout();
    i32 groups = 0;
    i32 g0 = -1;
    for i32 i = 0; i < calls_card_count(); i++ {
        if calls_card_kind(i) == CARD_GROUP {
            groups++;
            if g0 < 0 { g0 = i; }
        }
    }
    bool grouped = groups == 3 && calls_card_count_of(g0) == 10;
    calls_card_rect(g0, &x, &y, &w, &h);
    app_mouse(x + w / 2, y + h / 2, 0, true, 0);
    app_mouse(x + w / 2, y + h / 2, 0, false, 0);
    calls_relayout();
    i32 fns = 0;
    bool back = false;
    for i32 i = 0; i < calls_card_count(); i++ {
        if calls_card_row(i) == 0 && calls_card_kind(i) == CARD_FN { fns++; }
        if calls_card_kind(i) == CARD_BACK { back = true; }
    }
    g_checks++;
    if !grouped || !back || fns == 0 {
        print("FAIL a full row must group by file and a click open the group (groups {} back {} fns {})\n",
            groups, back, fns);
        g_fails++;
    }
    // more files than fit even as file cards: "more" shows the next page
    // and keeps the selection on itself, "before" goes back
    calls_rows_begin(true);
    for i32 i = 0; i < 40; i++ {
        str pre = "src/f_";
        memcpy(&nb[0], pre.data, pre.len);
        i32 n = pre.len + fmt_i32(&nb[pre.len], i);
        tt_call_item(&it, "caller", str_from(&nb[0], n), i);
        calls_row_add(true, &it, 1, i);
    }
    calls_rows_done(true);
    calls_relayout();
    i32 more = -1;
    for i32 i = 0; i < calls_card_count(); i++ {
        if calls_card_row(i) == 0 && calls_card_kind(i) == CARD_MORE { more = i; }
    }
    i32 first_before = -1;
    for i32 i = 0; i < calls_card_count(); i++ {
        if calls_card_row(i) == 0 && calls_card_kind(i) == CARD_FN && first_before < 0 { first_before = calls_card_idx(i); }
    }
    if more >= 0 { calls_card_rect(more, &x, &y, &w, &h); }
    app_mouse(x + w / 2, y + h / 2, 0, true, 0);
    app_mouse(x + w / 2, y + h / 2, 0, false, 0);
    calls_relayout();
    i32 first_after = -1;
    bool prev = false;
    for i32 i = 0; i < calls_card_count(); i++ {
        if calls_card_row(i) != 0 { continue; }
        if calls_card_kind(i) == CARD_PREV { prev = true; }
        if calls_card_kind(i) == CARD_FN && first_after < 0 { first_after = calls_card_idx(i); }
    }
    bool on_more = calls_card_kind(calls_selected()) == CARD_MORE;
    g_checks++;
    if more < 0 || !prev || first_after <= first_before || !on_more {
        print("FAIL \"more\" must show the next page and keep the selection (more {} prev {} first {} then {} on more {})\n",
            more, prev, first_before, first_after, on_more);
        g_fails++;
    }
    // Left to "before", Enter goes back to the first page
    while calls_card_kind(calls_selected()) != CARD_PREV && calls_card_row(calls_selected()) == 0 {
        i32 was = calls_selected();
        app_key(K_LEFT, 0);
        if calls_selected() == was { break; }
    }
    app_char(13);
    calls_relayout();
    i32 first_back = -1;
    bool prev_back = false;
    for i32 i = 0; i < calls_card_count(); i++ {
        if calls_card_row(i) != 0 { continue; }
        if calls_card_kind(i) == CARD_PREV { prev_back = true; }
        if calls_card_kind(i) == CARD_FN && first_back < 0 { first_back = calls_card_idx(i); }
    }
    g_checks++;
    if prev_back || first_back != first_before {
        print("FAIL \"before\" must go back to the first page (first {} want {})\n", first_back, first_before);
        g_fails++;
    }
    // Enter on the center opens it in the editor and closes the view
    calls_relayout();
    app_key(K_DOWN, 0);   // from the caller row to the center
    app_char(13);
    g_checks++;
    if calls_on || !str_equal(ed_path(), "src/pick.mc") {
        print("FAIL Enter on the center must open it and close the view (on {} path [{}])\n", calls_on, ed_path());
        g_fails++;
    }
    // Escape closes, and Ctrl+Shift+M with no server says so
    // as Windows sends it: the key, then its character 13, which must
    // not reach the buffer or the view
    i64 lines0 = tb.nlines;
    app_key('M', MOD_CTRL | MOD_SHIFT);
    app_char(13);
    g_checks++;
    if !calls_on || calls_phase_now() != CALLS_NO_SERVER || tb.nlines != lines0 {
        print("FAIL Ctrl+Shift+M without a server must open the view and say why ({} phase {})\n",
            calls_on, calls_phase_now());
        g_fails++;
    }
    app_key('M', MOD_CTRL | MOD_SHIFT);
    app_char(13);
    g_checks++;
    if calls_on || tb.nlines != lines0 {
        print("FAIL Ctrl+Shift+M again must close the view, with no newline in the buffer\n");
        g_fails++;
    }
    app_key('M', MOD_CTRL | MOD_SHIFT);
    app_key(K_ESCAPE, 0);
    g_checks++;
    if calls_on {
        print("FAIL Escape must close the call graph\n");
        g_fails++;
    }
    close_all();
}

// The explode view: every open buffer as a tile. It opens on the active
// buffer, the arrows move, typing filters by name, Enter or a click on a
// tile opens it, and Escape or a click elsewhere leaves the editor as it
// was. The grid's layout is plain arithmetic, checked here; the frame
// build that draws it runs in the fuzzer.
// Messages are notices, not a status line. Information goes by itself
// on its timer; a warning stays for Esc, which still reaches what has
// the focus. The Ctrl+K hint goes when the chord ends. A prompt keeps
// its messages beside its field.
private void test_notices() {
    close_all();
    ed_notice_close();
    ed_status("copied");
    bool info = notice_on && notice_kind == NOTICE_INFO && !notice_sticky && g_notice_timer;
    app_timer(NOTICE_TIMER);
    g_checks++;
    if !info || notice_on {
        print("FAIL information must be a notice that its timer closes (info {} on {})\n", info, notice_on);
        g_fails++;
    }
    ed_warn("save failed");
    bool warn = notice_on && notice_kind == NOTICE_WARN && notice_sticky && !g_notice_timer;
    app_timer(NOTICE_TIMER);
    bool stays = notice_on;
    app_key('F', MOD_CTRL);
    ed_warn("save failed");
    app_key(K_ESCAPE, 0);
    g_checks++;
    if !warn || !stays || notice_on || find_on {
        print("FAIL a warning must stay, and Esc close it and the find widget (warn {} stays {} on {} find {})\n",
            warn, stays, notice_on, find_on);
        g_fails++;
    }
    app_key('K', MOD_CTRL);
    bool hint = notice_on && str_contains(str_from(&notice_msg[0], notice_len), "(ctrl+k)");
    app_key('Q', 0);
    app_char('q');
    g_checks++;
    if !hint || !notice_on || !str_equal(str_from(&notice_msg[0], notice_len), "no such chord") {
        print("FAIL the chord hint must show, and give way to the chord's own message ([{}])\n",
            str_from(&notice_msg[0], notice_len));
        g_fails++;
    }
    ed_notice_close();
    app_key('K', MOD_CTRL);
    app_key('S', 0);
    app_char('s');
    app_key('K', MOD_CTRL);
    app_key('S', 0);
    app_char('s');
    g_checks++;
    if notice_on {
        print("FAIL the chord hint must close when the chord ends ([{}])\n", str_from(&notice_msg[0], notice_len));
        g_fails++;
    }
    // a prompt: the message stays beside the field
    app_key('K', MOD_CTRL);
    app_key('O', 0);
    app_char('o');
    type_text("build/nowhere");
    app_char(13);
    g_checks++;
    if !ask_on || notice_on || !str_equal(str_from(&g_status_msg[0], g_status_len), "not a folder") {
        print("FAIL a prompt's message must stay beside it, not in a notice (ask {} notice {} [{}])\n",
            ask_on, notice_on, str_from(&g_status_msg[0], g_status_len));
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    ed_notice_close();
    close_all();
}

// The recent folders: newest first, one entry per folder whatever the
// separators, at most twenty, in a file beside the settings. Open
// Recent lists the ones that exist, except the one open, and Enter
// opens one. A launch that names no folder and starts in the
// executable's folder, the system folder or the root chose none.
private void test_recent() {
    close_all();
    str rf = "build/recent";
    ignore file_remove(rf);
    // off, as in any harness run: nothing is written
    recent_add("build/rc_a");
    g_checks++;
    if path_exists(rf) {
        print("FAIL the recent list must not be written with the settings off\n");
        g_fails++;
    }
    settings_set_enabled(true);
    recent_add("build/rc_a");
    recent_add("build/rc_b");
    recent_add("build\\rc_a\\");
    recent_load();
    g_checks++;
    if recent_count() != 2 || !str_equal(recent_at(0), "build\\rc_a\\") || !str_equal(recent_at(1), "build/rc_b") {
        print("FAIL a folder added again must move to the front, once ({} entries, first [{}])\n",
            recent_count(), recent_at(0));
        g_fails++;
    }
    noinit u8[32] nb;
    str pre = "build/rc_n";
    memcpy(&nb[0], pre.data, pre.len);
    for i32 i = 0; i < 25; i++ {
        i32 n = pre.len + fmt_i32(&nb[pre.len], i);
        recent_add(str_from(&nb[0], n));
    }
    recent_load();
    g_checks++;
    if recent_count() != 20 || !str_equal(recent_at(0), "build/rc_n24") {
        print("FAIL the list must keep the twenty newest ({} entries, first [{}])\n", recent_count(), recent_at(0));
        g_fails++;
    }

    // every write goes to the shell's list; a folder removed there leaves
    // this list, and one that is not on it changes nothing
    i32 pushes = g_recent_pushes;
    app_recent_forget("build/rc_n20");
    recent_load();
    bool forgot = recent_count() == 19 && g_recent_pushes == pushes + 1;
    for i32 i = 0; i < recent_count(); i++ {
        if str_equal(recent_at(i), "build/rc_n20") { forgot = false; }
    }
    app_recent_forget("build/rc_n20");
    g_checks++;
    if !forgot || g_recent_pushes != pushes + 1 || !str_equal(recent_at(4), "build/rc_n19") {
        print("FAIL a folder removed from the shell's list must leave the recent list once ({} entries, {} pushes)\n",
            recent_count(), g_recent_pushes - pushes);
        g_fails++;
    }
    recent_add("build/rc_n30");
    recent_load();
    g_checks++;
    if recent_count() != 20 || !str_equal(recent_at(0), "build/rc_n30") || !str_equal(recent_at(5), "build/rc_n19") {
        print("FAIL a folder added after a removal must keep the others intact (first [{}] sixth [{}])\n",
            recent_at(0), recent_at(5));
        g_fails++;
    }

    // Open Recent: the folders that exist, newest first, without the one open
    ignore file_remove(rf);
    ignore dir_create("build/rc_a");
    ignore dir_create("build/rc_b");
    noinit u8[PATH_MAX] cwd;
    str here = str_from(&cwd[0], plat_cwd(&cwd[0], PATH_MAX));
    recent_add("build/rc_gone");
    recent_add(here);
    recent_add("build/rc_a");
    recent_add("build/rc_b");
    i32 fixed = palette_count();
    // Ctrl+K R opens the list, and so does the palette's row
    app_key('K', MOD_CTRL);
    app_key('R', 0);
    app_char('r');   // the key's character follows it, and is the chord's
    bool by_chord = palette_on && palette_hit_count() == 2;
    app_key(K_ESCAPE, 0);
    app_key('P', MOD_CTRL | MOD_SHIFT);
    str orr = "open recent";
    for i32 i = 0; i < orr.len; i++ { app_char(cast(u32, orr.data[i])); }
    app_char(13);
    g_checks++;
    if !by_chord {
        print("FAIL Ctrl+K R must open the recent folders\n");
        g_fails++;
    }
    g_checks++;
    if !palette_on || palette_hit_count() != 2 || !str_equal(palette_hit_name(0), "build/rc_b")
        || !str_equal(palette_hit_name(1), "build/rc_a") {
        print("FAIL Open Recent must list the recent folders that exist, without the one open ({} rows, first [{}])\n",
            palette_hit_count(), palette_hit_name(0));
        g_fails++;
    }
    app_key(K_DOWN, 0);
    g_chdir_last_len = 0;
    app_char(13);
    g_checks++;
    if palette_on || !str_equal(str_from(&g_chdir_last[0], g_chdir_last_len), "build/rc_a") || palette_count() != fixed {
        print("FAIL Enter must open the folder and close the list (chdir [{}])\n",
            str_from(&g_chdir_last[0], g_chdir_last_len));
        g_fails++;
    }
    // with nothing to list, the list opens empty
    ignore file_remove(rf);
    palette_open_recent();
    g_checks++;
    if !palette_on || palette_hit_count() != 0 {
        print("FAIL an empty recent list must open with no rows ({} rows)\n", palette_hit_count());
        g_fails++;
    }
    app_key(K_ESCAPE, 0);

    // a launch that names no folder opens the newest one that exists;
    // one that is already the working directory stays, and so does a
    // launch that names a folder
    ignore file_remove(rf);
    recent_add("build/rc_b");
    recent_add("build/rc_gone");
    g_chdir_last_len = 0;
    g_checks++;
    if !recent_launch() || !str_equal(str_from(&g_chdir_last[0], g_chdir_last_len), "build/rc_b") {
        print("FAIL a launch without a folder must open the newest folder that exists (chdir [{}])\n",
            str_from(&g_chdir_last[0], g_chdir_last_len));
        g_fails++;
    }
    recent_add(here);
    g_chdir_last_len = 0;
    bool stayed = !recent_launch() && g_chdir_last_len == 0;
    recent_add("build/rc_b");
    app_folder_arg();
    stayed = stayed && !recent_launch() && g_chdir_last_len == 0;
    g_checks++;
    if !stayed {
        print("FAIL a launch must stay where it is when the newest folder is the working directory or a folder is named\n");
        g_fails++;
    }
    settings_set_enabled(false);
    ignore file_remove(rf);
    close_all();
}

private void test_explode() {
    close_all();
    ignore ed_open_file("src/pick.mc");
    ignore ed_open_file("src/tree.mc");
    ignore ed_open_file("build.mc");
    i32 active = ed_buf_active();
    // Ctrl+M as Windows delivers it: the key, then its character 13,
    // which must neither pick a tile nor reach the buffer as a newline
    i64 lines0 = tb.nlines;
    app_key('M', MOD_CTRL);
    app_char(13);
    g_checks++;
    if !explode_on {
        print("FAIL the character 13 after Ctrl+M must not close the explode view\n");
        g_fails++;
    }
    app_key('M', MOD_CTRL);
    app_char(13);
    g_checks++;
    if explode_on || tb.nlines != lines0 {
        print("FAIL Ctrl+M must close the view without a newline in the buffer ({} lines, was {})\n",
            tb.nlines, lines0);
        g_fails++;
    }
    app_key('M', MOD_CTRL);
    g_checks++;
    if !explode_on || explode_count() != ed_buf_count() || explode_selected() != active || !overlay_active() {
        print("FAIL Ctrl+M must open the explode view on the active buffer ({} of {}, sel {} active {})\n",
            explode_count(), ed_buf_count(), explode_selected(), active);
        g_fails++;
    }
    // the grid: inside the area, no two tiles overlapping, one scale
    f32 sc = explode_layout(0, 0, 1200, 800, 600, 700, 20, 10);
    bool inside = sc > 0.0f;
    for i32 i = 0; i < explode_count(); i++ {
        i32 x = 0;
        i32 y = 0;
        i32 w = 0;
        i32 h = 0;
        ignore explode_tile_rect(i, &x, &y, &w, &h);
        if x < 0 || y < 0 || x + w > 1200 || y + h > 800 || w < 1 || h < 21 { inside = false; }
        for i32 j = 0; j < i; j++ {
            i32 x2 = 0;
            i32 y2 = 0;
            i32 w2 = 0;
            i32 h2 = 0;
            ignore explode_tile_rect(j, &x2, &y2, &w2, &h2);
            if x < x2 + w2 && x2 < x + w && y < y2 + h2 && y2 < y + h { inside = false; }
        }
    }
    g_checks++;
    if !inside {
        print("FAIL the explode grid must fit its area without overlap (scale {})\n", sc);
        g_fails++;
    }
    // an area too small for any tile gets none, rather than tiles
    // placed outside it
    i32 zx = 0;
    i32 zy = 0;
    i32 zw = 0;
    i32 zh = 0;
    f32 zs = explode_layout(0, 0, 300, 15, 600, 700, 20, 10);
    ignore explode_tile_rect(0, &zx, &zy, &zw, &zh);
    g_checks++;
    if zs != 0.0f || zw != 0 || zh != 0 {
        print("FAIL a window too small for tiles must lay out none (scale {} tile {}x{})\n", zs, zw, zh);
        g_fails++;
    }
    // Escape leaves the buffer as it was
    app_key(K_RIGHT, 0);
    app_key(K_ESCAPE, 0);
    g_checks++;
    if explode_on || ed_buf_active() != active {
        print("FAIL Escape must close the explode view and keep the buffer\n");
        g_fails++;
    }
    // a click on a tile opens it
    explode_open();
    ignore explode_layout(0, 0, 1200, 800, 600, 700, 20, 10);
    i32 want = explode_buf(0);
    i32 x = 0;
    i32 y = 0;
    i32 w = 0;
    i32 h = 0;
    ignore explode_tile_rect(0, &x, &y, &w, &h);
    app_mouse(x + w / 2, y + h / 2, 0, true, 0);
    app_mouse(x + w / 2, y + h / 2, 0, false, 0);
    g_checks++;
    if explode_on || ed_buf_active() != want {
        print("FAIL a click on a tile must open its buffer (active {} want {})\n", ed_buf_active(), want);
        g_fails++;
    }
    // a click between the tiles returns
    explode_open();
    ignore explode_layout(0, 0, 1200, 800, 600, 700, 20, 10);
    i32 before = ed_buf_active();
    app_mouse(1, 1, 0, true, 0);
    app_mouse(1, 1, 0, false, 0);
    g_checks++;
    if explode_on || ed_buf_active() != before {
        print("FAIL a click outside the tiles must close the explode view\n");
        g_fails++;
    }
    // typing filters by name; Enter opens the one left
    explode_open();
    str q = "TREE";
    for i32 i = 0; i < q.len; i++ { app_char(cast(u32, q.data[i])); }
    i32 left = explode_count();
    app_char(13);
    g_checks++;
    if left != 1 || explode_on || !str_equal(ed_path(), "src/tree.mc") {
        print("FAIL the filter must match names ignoring case, and Enter open it ({} left, {})\n",
            left, ed_path());
        g_fails++;
    }
    // the arrows move the selection along the grid
    explode_open();
    ignore explode_layout(0, 0, 1200, 800, 600, 700, 20, 10);
    i32 s0 = explode_selected();
    app_key(K_HOME, 0);
    i32 first = explode_selected();
    app_key(K_RIGHT, 0);
    g_checks++;
    if first != explode_buf(0) || explode_selected() != explode_buf(1) {
        print("FAIL Home and Right must move the explode selection (from {} to {} then {})\n",
            s0, first, explode_selected());
        g_fails++;
    }
    // the wheel over a tile scrolls that buffer and selects the tile;
    // Enter opens it where it was scrolled to
    app_key(K_ESCAPE, 0);
    ignore ed_open_file("src/tree.mc");
    i32 act = ed_buf_active();
    explode_open();
    ignore explode_layout(0, 0, 1200, 800, 600, 700, 20, 10);
    i32 other = -1;
    for i32 i = 0; i < explode_count(); i++ {
        if explode_buf(i) != act && str_equal(ed_buf_title(explode_buf(i)), "pick.mc") { other = i; }
    }
    i32 ox = 0;
    i32 oy = 0;
    i32 ow = 0;
    i32 oh = 0;
    ignore explode_tile_rect(other, &ox, &oy, &ow, &oh);
    app_scroll(0.0f, cast(f32, 10 * font_line_h), ox + ow / 2, oy + oh / 2);
    i32 picked = explode_selected();
    app_char(13);
    g_checks++;
    if other < 0 || picked != explode_buf(other) || explode_on || top_line != 10 {
        print("FAIL the wheel over a tile must scroll its buffer and select it (sel {} top {})\n",
            picked, top_line);
        g_fails++;
    }
    // the active buffer's tile scrolls its live view
    explode_open();
    ignore explode_layout(0, 0, 1200, 800, 600, 700, 20, 10);
    i32 mine = -1;
    for i32 i = 0; i < explode_count(); i++ {
        if explode_buf(i) == ed_buf_active() { mine = i; }
    }
    ignore explode_tile_rect(mine, &ox, &oy, &ow, &oh);
    i32 top_was = top_line;
    app_scroll(0.0f, cast(f32, -4 * font_line_h), ox + ow / 2, oy + oh / 2);
    g_checks++;
    if top_line != top_was - 4 || !explode_on {
        print("FAIL the wheel over the active buffer's tile must scroll its view ({} from {})\n",
            top_line, top_was);
        g_fails++;
    }
    ignore explode_layout(0, 0, 1200, 800, 600, 700, 20, 10);

    // the pointer over a tile selects it; between the tiles it stays
    i32 hx = 0;
    i32 hy = 0;
    i32 hw = 0;
    i32 hh = 0;
    ignore explode_tile_rect(2, &hx, &hy, &hw, &hh);
    app_hover(hx + hw / 2, hy + hh / 2, 0);
    i32 hovered = explode_selected();
    app_hover(1, 1, 0);
    g_checks++;
    if hovered != explode_buf(2) || explode_selected() != explode_buf(2) || !explode_on {
        print("FAIL hovering a tile must select it and keep it between tiles ({} want {})\n",
            hovered, explode_buf(2));
        g_fails++;
    }
    app_key('M', MOD_CTRL);
    g_checks++;
    if explode_on {
        print("FAIL Ctrl+M again must close the explode view\n");
        g_fails++;
    }

    // terminals: a live one has a tile after the buffers, the view opens
    // on it when its pane is active, and picking it brings it back
    tt_open_term();
    i32 tt = ed_term_active();
    explode_open();
    i32 tiles = explode_count();
    i32 on_term = explode_selected_term();
    i32 last = explode_count() - 1;
    str tlabel = explode_title(last);
    g_checks++;
    if tt < 0 || tiles != ed_buf_count() + 1 || on_term != tt || explode_term(last) != tt
        || explode_buf(last) != -1 || tlabel.len == 0 {
        print("FAIL a terminal must have a tile, and the view open on it (tiles {} bufs {} sel {} term {})\n",
            tiles, ed_buf_count(), on_term, tt);
        g_fails++;
    }
    app_key(K_HOME, 0);
    app_char(13);
    g_checks++;
    if ed_term_active() >= 0 || explode_on {
        print("FAIL picking a buffer's tile from a terminal pane must show the buffer\n");
        g_fails++;
    }
    explode_open();
    app_key(K_END, 0);
    app_char(13);
    g_checks++;
    if ed_term_active() != tt {
        print("FAIL picking the terminal's tile must bring it back ({} want {})\n", ed_term_active(), tt);
        g_fails++;
    }
    close_all();
}

private str TT_SETTINGS = "build/ed_test_settings.json";

// --- the explode view from a terminal pane -------------------------------
// The chord is the editor's whatever the pane shows: a focused terminal
// must not get the M.
private void test_explode_from_term() {
    reset("one\ntwo\n");
    tt_open_term();
    tc_term_len = 0;
    app_key('M', MOD_CTRL);
    app_char('m');   // the chord's own character, as a real keyboard sends it
    g_checks++;
    if !explode_on || tc_term_len != 0 {
        print("FAIL the explode chord must reach the editor from a terminal pane (on {}, {} bytes to the shell)\n",
            explode_on, tc_term_len);
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    g_checks++;
    if explode_on {
        print("FAIL esc must close the explode view\n");
        g_fails++;
    }
    ed_term_close_all();
    close_all();
}

i32 main() {
    tree_on = false;   // editor geometry tests assume no sidebar
    // the child is stubbed here, so sends stay on this thread
    // where the checks below can see them as they are written
    lsp_threaded = false;
    image_threaded = false;   // decoded where the file opens
    hist_threaded = false;   // git runs where it is asked, as image decodes do
    // the session tests take the interactive path, which reads the
    // settings file: never the user's
    settings_set_path(TT_SETTINGS);
    ignore file_remove(TT_SETTINGS);
    ignore file_remove("build/recent");
    app_init("", DPI_BASE);
    // the caption follows the reference at this dpi: a 30 px bar and
    // 46 px per window button (css px; DPI_BASE here, so 1:1)
    g_checks++;
    if caption_default_h(DPI_BASE) != 30 || caption_btn_w() != 46 {
        print("FAIL caption metrics: bar {} button {}\n", caption_default_h(DPI_BASE), caption_btn_w());
        g_fails++;
    }
    app_resize(1200, 800);
    app_focus(true);

    // A wake can arrive before any search has run (the lsp reader
    // posts one), so search_wake must not touch its uninitialized
    // mutex. Must stay ahead of the first search_run_blocking below.
    app_wake();
    g_checks++;

    // --- word movement + deletion ---
    reset("alpha beta gamma\none two three");
    app_key(K_RIGHT, MOD_WORD);
    expect_caret(0, 5, "word right to word end");
    app_key(K_RIGHT, MOD_WORD);
    expect_caret(0, 10, "word right again");
    app_char(127);   // ctrl+backspace arrives as char 127
    expect("alpha  gamma\none two three", "ctrl+backspace deletes word");
    app_key(K_HOME, 0);
    app_key(K_DELETE, MOD_CTRL);
    expect("  gamma\none two three", "ctrl+delete deletes word right");
    app_key(K_END, MOD_CTRL);
    app_key(K_LEFT, MOD_WORD);
    expect_caret(1, 8, "word left to word start");
    app_char(127);
    expect("  gamma\none three", "ctrl+backspace at word start eats previous word");
    // The literal keys, per platform. The checks above press MOD_WORD,
    // which is what the code uses too, so they would follow a swap in
    // it; these would not.
    reset("alpha beta");
    when !os(macos) {
        app_key(K_RIGHT, MOD_CTRL);
        expect_caret(0, 5, "windows/linux: ctrl+right must walk a word");
        app_key(K_LEFT, MOD_CTRL | MOD_SHIFT);
        i64 wsa = 0;
        i64 wsb = 0;
        g_checks++;
        if !ed_sel_range(&wsa, &wsb) || wsa != 0 || wsb != 5 {
            print("FAIL windows/linux: ctrl+shift+left must select the word\n");
            g_fails++;
        }
    }
    when os(macos) {
        app_key(K_RIGHT, MOD_ALT);
        expect_caret(0, 5, "macos: option+right must walk a word");
        app_key(K_RIGHT, MOD_CTRL);
        expect_caret(0, 10, "macos: cmd+right must be line end");
        app_key(K_LEFT, MOD_CTRL | MOD_SHIFT);
        i64 msa = 0;
        i64 msb = 0;
        g_checks++;
        if !ed_sel_range(&msa, &msb) || msa != 0 || msb != 10 {
            print("FAIL macos: cmd+shift+left must select to line start\n");
            g_fails++;
        }
    }

    // --- grapheme clusters: a multi-codepoint emoji is one edit/display
    // unit -- the caret skips it, backspace deletes it whole, it is two
    // cells wide. Built with app_char so the codepoints encode as real
    // UTF-8 (a, U+1F44D thumbs up + U+1F3FD skin tone, b) ---
    reset("");
    app_char('a');
    app_char(0x1F44D);
    app_char(0x1F3FD);
    app_char('b');
    app_key(K_HOME, MOD_CTRL);
    cur_line = 0;
    cur_col = 0;
    app_key(K_RIGHT, 0);
    expect_caret(0, 1, "right moves over the ascii a");
    app_key(K_RIGHT, 0);
    expect_caret(0, 9, "right skips the whole skin-tone emoji cluster");
    g_checks++;
    if vcol_of_col(0, 9) != 3 {
        print("FAIL an emoji cluster is two cells wide (vcol {})\n", vcol_of_col(0, 9));
        g_fails++;
    }
    app_key(K_RIGHT, 0);
    expect_caret(0, 10, "right moves over the ascii b");
    app_key(K_LEFT, 0);
    expect_caret(0, 9, "left moves back over b");
    app_key(K_LEFT, 0);
    expect_caret(0, 1, "left skips the whole cluster back");
    cur_col = 9;
    app_char(8);
    expect("ab", "backspace deletes the whole emoji cluster");
    expect_caret(0, 1, "caret lands before b after deleting the cluster");
    close_all();

    // an emoji-presentation symbol outside the main block (✅ U+2705) is
    // two cells, so it does not overlap the next glyph
    g_checks++;
    if cp_width(0x2705) != 2 || cp_width(0x2728) != 2 {
        print("FAIL an emoji-presentation symbol must be two cells (2705={} 2728={})\n",
            cp_width(0x2705), cp_width(0x2728));
        g_fails++;
    }
    g_checks++;
    if cp_width(0x2611) != 1 {
        print("FAIL a text-presentation symbol stays one cell (2611={})\n", cp_width(0x2611));
        g_fails++;
    }
    // 🎉🎉✅☑️🎈🎈: each is two cells, so twelve columns with no overlap
    reset("");
    app_char(0x1F389);
    app_char(0x1F389);
    app_char(0x2705);
    app_char(0x2611);
    app_char(0xFE0F);
    app_char(0x1F388);
    app_char(0x1F388);
    g_checks++;
    if vcol_of_col(0, tb_len()) != 12 {
        print("FAIL a row of emoji advances two cells each (vcol {})\n", vcol_of_col(0, tb_len()));
        g_fails++;
    }
    close_all();

    // --- line move / copy / delete ---
    reset("aa\nbb\ncc");
    app_key(K_DOWN, 0);
    app_key(K_DOWN, MOD_ALT);
    expect("aa\ncc\nbb", "alt+down moves line down (last line swap)");
    expect_caret(2, 0, "caret followed the moved line");
    app_key(K_UP, MOD_ALT);
    expect("aa\nbb\ncc", "alt+up moves it back");
    app_key(K_UP, MOD_ALT);
    expect("bb\naa\ncc", "alt+up again");
    app_key(K_DOWN, MOD_ALT | MOD_SHIFT);
    expect("bb\nbb\naa\ncc", "shift+alt+down copies line");
    expect_caret(1, 0, "caret on the lower copy");
    app_key('K', MOD_CTRL | MOD_SHIFT);
    expect("bb\naa\ncc", "ctrl+shift+k deletes line");
    app_key(K_END, MOD_CTRL);
    app_key('K', MOD_CTRL | MOD_SHIFT);
    expect("bb\naa", "delete last line eats preceding newline");

    // --- multi-line selection ops ---
    reset("aa\nbb\ncc\ndd");
    app_key(K_DOWN, MOD_SHIFT);   // select lines 0..1 (end at col 0 of 1)
    app_key(K_DOWN, MOD_ALT);
    expect("bb\naa\ncc\ndd", "move with selection ending at col 0 moves one line");
    reset("aa\nbb\ncc\ndd");
    app_key(K_DOWN, MOD_SHIFT);
    app_key(K_RIGHT, MOD_SHIFT);  // selection now touches line 1
    app_key(K_DOWN, MOD_ALT);
    expect("cc\naa\nbb\ndd", "alt+down moves both selected lines");

    // --- selection stays inside the buffer across the line ops ---
    // Each of these shifts the anchor by the amount the text moved,
    // and the last-line cases exchange a newline, so the arithmetic
    // can land one past the end. set_caret_abs clamps the caret; the
    // anchor needs the same.
    str[3] shapes = { "aa\nbb\ncc", "aa\nbb\ncc\n", "solo" };
    i32[4] ops = { K_UP, K_DOWN, K_UP, K_DOWN };
    i32[4] opmods = { MOD_ALT, MOD_ALT, MOD_ALT | MOD_SHIFT, MOD_ALT | MOD_SHIFT };
    for i32 si = 0; si < 3; si++ {
        for i32 oi = 0; oi < 4; oi++ {
            for i32 up = 1; up <= 3; up++ {
                reset(shapes[si]);
                app_key(K_END, MOD_CTRL);
                for i32 u = 0; u < up; u++ { app_key(K_UP, MOD_SHIFT); }
                app_key(ops[oi], opmods[oi]);
                g_checks++;
                if !sel_in_buffer() {
                    i64 sa = 0;
                    i64 sb = 0;
                    ignore ed_sel_range(&sa, &sb);
                    print("FAIL line op left the selection outside the buffer (shape {} op {} up {}: {}..{} of {})\n",
                        si, oi, up, sa, sb, tb_len());
                    g_fails++;
                }
            }
        }
    }

    // --- comment toggle ---
    reset("one\n\n  two");
    app_key('A', MOD_CTRL);
    app_key('7', MOD_CTRL);       // the ctrl+7 binding
    expect("// one\n\n//   two", "comment aligns // at min indent, skips blanks");
    app_key('/', MOD_CTRL);       // the ctrl+/ binding
    expect("one\n\n  two", "uncomment restores the original indent");
    // auto-indent on Enter supplies the first two spaces of line 2
    reset("  aa\n  bb");
    expect("  aa\n    bb", "typing reproduces the indented block");
    app_key('A', MOD_CTRL);
    app_key('/', MOD_CTRL);
    expect("  // aa\n  //   bb", "indented block: // at the block's indent");
    app_key('/', MOD_CTRL);
    expect("  aa\n    bb", "and uncomments back");
    reset("// aa\nbb");
    app_key('A', MOD_CTRL);
    app_key('/', MOD_CTRL);
    expect("// // aa\n// bb", "mixed lines get commented, not stripped");

    // --- undo grouping: each op is one step ---
    reset("aa\nbb\ncc");
    app_key(K_DOWN, MOD_ALT);
    app_key('7', MOD_CTRL);
    app_key('K', MOD_CTRL | MOD_SHIFT);
    app_key('Z', MOD_CTRL);
    expect("bb\n// aa\ncc", "undo restores deleted line");
    app_key('Z', MOD_CTRL);
    expect("bb\naa\ncc", "undo removes comment");
    app_key('Z', MOD_CTRL);
    expect("aa\nbb\ncc", "undo restores line order");

    // --- wide characters on the mono grid ---
    reset("");
    app_char(0x4E2D);   // 中, 3 bytes, 2 cells
    app_char('a');
    app_char(13);
    type_text("xyz");
    g_checks++;
    if vcol_of_col(0, 3) != 2 || vcol_of_col(0, 4) != 3 {
        print("FAIL wide char must occupy two columns (vcol {} {})\n",
            vcol_of_col(0, 3), vcol_of_col(0, 4));
        g_fails++;
    }
    // vertical movement keeps the visual column across the wide char
    app_key(K_HOME, MOD_CTRL);
    app_key(K_DOWN, 0);
    app_key(K_RIGHT, 0);
    app_key(K_RIGHT, 0);   // line 1, vcol 2
    app_key(K_UP, 0);
    expect_caret(0, 3, "up at vcol 2 lands after the wide char");
    app_key(K_DOWN, 0);
    app_key(K_LEFT, 0);    // line 1, vcol 1: middle of the wide char above
    app_key(K_UP, 0);
    expect_caret(0, 3, "up into the middle of a wide char steps past it");

    // --- dirty-close prompt ---
    reset("dirty");
    if app_close() {
        print("FAIL first close of a dirty buffer must refuse\n");
        g_fails++;
    }
    g_checks++;
    if !app_close() {
        print("FAIL second close must be allowed\n");
        g_fails++;
    }
    g_checks++;
    type_text("x");   // an edit disarms the close
    if app_close() {
        print("FAIL close after an edit must refuse again\n");
        g_fails++;
    }
    g_checks++;

    // --- save-as through the input box ---
    reset("saved body");
    g_has_path = false;
    g_path_len = 0;
    str target = "build/ed_test_saveas.tmp";
    test_remove(target);
    app_key('S', MOD_CTRL);
    if !ask_on {
        print("FAIL ctrl+s without a path must open the prompt\n");
        g_fails++;
    }
    g_checks++;
    type_text(target);
    app_char(13);
    FileData fd = file_read(target);
    g_checks++;
    if fd.data == null || !str_equal(str_from(fd.data, cast(i32, fd.len)), "saved body") {
        print("FAIL save-as wrote wrong content\n");
        g_fails++;
    }
    if fd.data != null { free(fd.data); }
    g_checks++;
    if ask_on || !g_has_path || tb.dirty {
        print("FAIL save-as end state: prompt open or path/dirty wrong\n");
        g_fails++;
    }

    // overwrite protection: a second untitled save to the same path
    // must ask twice
    reset("second body");
    g_has_path = false;
    g_path_len = 0;
    app_key('S', MOD_CTRL);
    type_text(target);
    app_char(13);   // path exists now: arms, stays open
    g_checks++;
    if !ask_on {
        print("FAIL existing path must keep the prompt open\n");
        g_fails++;
    }
    app_char(13);   // armed: overwrite
    fd = file_read(target);
    g_checks++;
    if fd.data == null || !str_equal(str_from(fd.data, cast(i32, fd.len)), "second body") {
        print("FAIL armed enter must overwrite\n");
        g_fails++;
    }
    if fd.data != null { free(fd.data); }
    test_remove(target);

    // --- multiple buffers ---
    str b2 = "build/ed_test_b2.tmp";
    test_remove(b2);
    reset("alpha");
    g_has_path = false;
    g_path_len = 0;
    app_key('S', MOD_CTRL);
    type_text(b2);
    app_char(13);              // saved: active buffer now has path b2
    type_text("A");            // and is dirty again
    g_checks++;
    if ed_buf_count() != 1 {
        print("FAIL expected a single buffer, got {}\n", ed_buf_count());
        g_fails++;
    }
    ignore ed_open_file("doc/TESTING.md");
    g_checks++;
    if ed_buf_count() != 2 || !str_equal(ed_buf_title(ed_buf_active()), "TESTING.md") {
        print("FAIL open must add a tab (count {} title {})\n",
            ed_buf_count(), ed_buf_title(ed_buf_active()));
        g_fails++;
    }
    ed_buf_switch(0);
    expect("Aalpha", "switching back restores content");
    g_checks++;
    // buffer 0 dirty, buffer 1 (TESTING.md) clean
    if !tb.dirty || ed_buf_dirty(1) {
        print("FAIL dirty flags must be per buffer\n");
        g_fails++;
    }
    app_key('S', MOD_CTRL);    // has a path: plain save, now clean
    ignore ed_open_file("doc/TESTING.md");   // already open: activates, no new tab
    g_checks++;
    if ed_buf_count() != 2 || !str_equal(ed_buf_title(ed_buf_active()), "TESTING.md") {
        print("FAIL reopening must activate the existing tab\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL);    // close TESTING.md, back to b2
    g_checks++;
    if ed_buf_count() != 1 {
        print("FAIL close must drop the tab\n");
        g_fails++;
    }
    expect("Aalpha", "close returns to the remaining buffer");
    type_text("B");
    app_key('W', MOD_CTRL);    // dirty: refuses once
    g_checks++;
    if ed_buf_count() != 1 || tb_len() == 0 {
        print("FAIL dirty close must refuse first\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL);    // armed: closes; last tab resets untitled
    expect("", "closing the last tab leaves an empty untitled buffer");
    g_checks++;
    if g_has_path || tb.dirty {
        print("FAIL untitled reset state wrong\n");
        g_fails++;
    }
    test_remove(b2);

    // --- title format + buffer cycling ---
    // state here: one clean empty untitled buffer
    g_checks++;
    if g_test_title_len < 8 || g_test_title[0] != 'u' {
        print("FAIL clean title should start with the name (got len {})\n", g_test_title_len);
        g_fails++;
    }
    type_text("z");
    g_checks++;
    if g_test_title[0] != '*' {
        print("FAIL dirty title must lead with *\n");
        g_fails++;
    }
    ignore ed_open_file("doc/TESTING.md");   // dirty untitled stays; new tab
    g_checks++;
    if ed_buf_count() != 2 {
        print("FAIL dirty untitled must not be reused\n");
        g_fails++;
    }
    // the cycle is the switcher's list, opened one step along: the
    // chord shows what is open, Enter accepts the row it opened on
    app_key(K_TAB, MOD_CTRL);
    g_checks++;
    if !switcher_on {
        print("FAIL ctrl+tab must open the switcher\n");
        g_fails++;
    }
    app_char(13);                     // wraps to the untitled buffer
    expect("z", "ctrl+tab cycles buffers");
    app_key(K_TAB, MOD_CTRL | MOD_SHIFT);
    app_char(13);
    g_checks++;
    if !str_equal(ed_buf_title(ed_buf_active()), "TESTING.md") {
        print("FAIL shift+ctrl+tab cycles back\n");
        g_fails++;
    }
    app_key(K_TAB, MOD_SUPER);        // macOS real-Ctrl arrives as SUPER
    app_char(13);
    expect("z", "super+tab cycles too");
    app_key(96, MOD_CTRL);            // primary+backtick cycles as well
    app_char(13);
    g_checks++;
    if !str_equal(ed_buf_title(ed_buf_active()), "TESTING.md") {
        print("FAIL cmd+backtick must cycle\n");
        g_fails++;
    }
    app_key(96, MOD_CTRL);
    app_char(13);
    expect("z", "backtick cycle wraps");
    // Alt+` is the same chord for a Mac hand (Cmd sits where Alt does),
    // held by Alt: its release accepts, so a tap toggles to the last one
    when !os(macos) {
        app_key(96, MOD_ALT);
        app_hover(0, 0, MOD_ALT);     // still held
        g_checks++;
        if !switcher_on {
            print("FAIL alt+backtick must open the switcher and hold it while alt is down\n");
            g_fails++;
        }
        app_hover(0, 0, 0);           // alt released: accepts
        g_checks++;
        if switcher_on || !str_equal(ed_buf_title(ed_buf_active()), "TESTING.md") {
            print("FAIL releasing alt must accept the row, as ctrl does (on {}, {})\n",
                switcher_on, ed_buf_title(ed_buf_active()));
            g_fails++;
        }
        app_key(96, MOD_ALT);
        app_hover(0, 0, 0);
        expect("z", "alt+backtick toggles back");
    }
    // the chord repeats inside the open list, and escape leaves the
    // buffer on screen alone
    app_key(K_TAB, MOD_CTRL);
    i32 cyc_sel = switcher_sel();
    app_key(K_TAB, MOD_CTRL);
    g_checks++;
    if !switcher_on || switcher_sel() == cyc_sel {
        print("FAIL a repeated ctrl+tab must step the list ({} then {})\n",
            cyc_sel, switcher_sel());
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    g_checks++;
    if switcher_on {
        print("FAIL escape must close the cycle list\n");
        g_fails++;
    }
    expect("z", "escape leaves the buffer alone");

    // letting the chord's modifier go accepts the row it is on, the way
    // a window switcher does: the platforms report the release through
    // app_hover, and Enter is not needed
    app_key(K_TAB, MOD_CTRL);
    g_checks++;
    if !switcher_on {
        print("FAIL ctrl+tab must open the list\n");
        g_fails++;
    }
    app_hover(0, 0, MOD_CTRL);        // still held: nothing happens
    g_checks++;
    if !switcher_on {
        print("FAIL the list must stay while the chord is held\n");
        g_fails++;
    }
    // the row the list is on is in the pane already, while the chord is
    // held: the result is seen before the chord is let go
    g_checks++;
    if ed_buf_active() != switcher_item_id(switcher_sel()) {
        print("FAIL a held chord must show the row it is on (on {})\n",
            ed_buf_title(ed_buf_active()));
        g_fails++;
    }
    app_hover(0, 0, 0);               // let go
    g_checks++;
    if switcher_on {
        print("FAIL releasing the chord must close the list\n");
        g_fails++;
    }
    g_checks++;
    if !str_equal(ed_buf_title(ed_buf_active()), "TESTING.md") {
        print("FAIL releasing ctrl must accept without enter (on {})\n",
            ed_buf_title(ed_buf_active()));
        g_fails++;
    }
    // and back, so what follows sees the buffer it expects
    app_key(K_TAB, MOD_CTRL);
    app_hover(0, 0, 0);
    expect("z", "the release cycles again");
    // Esc after a preview puts back what the pane showed, and the walk
    // did not count as looks: the list opens in the same order after
    i32[8] order_before;
    i32 orig = ed_buf_active();
    app_key(K_TAB, MOD_CTRL);
    i32 n_before = switcher_count();
    for i32 i = 0; i < n_before && i < 8; i++ { order_before[i] = switcher_item_id(i); }
    g_checks++;
    if ed_buf_active() == orig {
        print("FAIL the held chord must preview the next row\n");
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    g_checks++;
    if switcher_on || ed_buf_active() != orig {
        print("FAIL esc must put back what the pane showed (on {})\n", ed_buf_title(ed_buf_active()));
        g_fails++;
    }
    app_key(K_TAB, MOD_CTRL);
    app_key(K_TAB, MOD_CTRL);         // two steps of preview
    app_key(K_ESCAPE, 0);
    app_key(K_TAB, MOD_CTRL);
    g_checks++;
    bool same = switcher_count() == n_before;
    for i32 i = 0; same && i < n_before && i < 8; i++ {
        if switcher_item_id(i) != order_before[i] { same = false; }
    }
    if !same {
        print("FAIL a cancelled preview must leave the list's order alone\n");
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    // a list opened to type at has no held chord: a stray modifier
    // report must not accept it
    app_key('K', MOD_CTRL);
    app_key('W', 0);
    app_char('w');
    app_hover(0, 0, 0);
    g_checks++;
    if !switcher_on {
        print("FAIL ctrl+k w must not accept on a modifier report\n");
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    // cleanup: discard both extra buffers
    app_key('W', MOD_CTRL);
    app_key('W', MOD_CTRL);           // dirty: arm + close
    app_key('W', MOD_CTRL);
    expect("", "cleanup leaves the empty untitled buffer");

    // --- file tree ---
    tree_on = true;
    tree_build();
    i32 src_row = -1;
    for i32 i = 0; i < tree_row_count(); i++ {
        if str_equal(tree_row_path(i), "src") && tree_row_is_dir(i) { src_row = i; }
    }
    g_checks++;
    if src_row < 0 {
        print("FAIL tree must list the src directory\n");
        g_fails++;
    }
    tree_row_activate(src_row);       // expand
    i32 ed_row = tree_row_of("src/ed.mc");
    g_checks++;
    if ed_row < 0 {
        print("FAIL expanding src must reveal src/ed.mc\n");
        g_fails++;
    }
    tree_row_activate(ed_row);        // open the file
    g_checks++;
    if !str_equal(ed_buf_title(ed_buf_active()), "ed.mc") {
        print("FAIL activating a file row must open it\n");
        g_fails++;
    }
    src_row = tree_row_of("src");
    tree_row_activate(src_row);       // collapse
    g_checks++;
    for i32 i = 0; i < tree_row_count(); i++ {
        if str_equal(tree_row_path(i), "src/ed.mc") {
            print("FAIL collapse must hide children\n");
            g_fails++;
            break;
        }
    }
    // A rebuild that drops rows under a standing scroll: the scroll is
    // pixels into the old rows, and past the new content it draws rows
    // and the scrollbar thumb below the window (the fuzzer found the
    // thumb 195 px past the bottom at 4K once one more file was in the
    // tree). The rebuild has to clamp it.
    tree_row_activate(src_row);       // expand again, the tree is tall
    tr_scroll = 2 * tree_row_count() * font_line_h;   // far past the end
    tree_build();
    g_checks++;
    i32 tree_max = 2 * (font_line_h / 4) + tree_row_count() * tree_row_h() - (g_h - status_h());
    if tree_max < 0 { tree_max = 0; }
    if tr_scroll > tree_max || tr_scroll < 0 {
        print("FAIL a rebuild must clamp the tree scroll ({} > {})\n", tr_scroll, tree_max);
        g_fails++;
    }
    tree_row_activate(src_row);       // collapse again for the close below
    app_key('W', MOD_CTRL);           // close the opened clean buffer

    // keyboard navigation while the tree has focus
    tree_focus = true;
    ignore tree_key(K_HOME, 0);
    g_checks++;
    if tree_sel() != 0 {
        print("FAIL home must select the first row\n");
        g_fails++;
    }
    ignore tree_key(K_DOWN, 0);
    g_checks++;
    if tree_sel() != 1 {
        print("FAIL down must advance the selection\n");
        g_fails++;
    }
    // enter on a file row opens it and passes the focus to the editor
    i32 plan_row = tree_row_of("README.md");
    tree_select(plan_row);
    ignore tree_char(13);
    g_checks++;
    if !str_equal(ed_buf_title(ed_buf_active()), "README.md") || tree_focus {
        print("FAIL enter on a file must open it and pass the focus (title {} tree {})\n",
            ed_buf_title(ed_buf_active()), tree_focus);
        g_fails++;
    }
    // space opens and keeps the focus in the tree
    app_key('W', MOD_CTRL);   // close it, so space has something to open
    tree_focus = true;
    ignore tree_char(32);
    g_checks++;
    if !str_equal(ed_buf_title(ed_buf_active()), "README.md") || !tree_focus {
        print("FAIL space must open the selected file and keep the focus (title {} tree {})\n",
            ed_buf_title(ed_buf_active()), tree_focus);
        g_fails++;
    }
    // arrows go to the tree while focused, to the editor after esc
    i32 line_before = cur_line;
    app_key(K_DOWN, 0);
    g_checks++;
    if cur_line != line_before {
        print("FAIL arrows must not move the caret while the tree has focus\n");
        g_fails++;
    }
    ignore tree_key(K_ESCAPE, 0);
    app_key(K_DOWN, 0);
    g_checks++;
    if cur_line != line_before + 1 {
        print("FAIL esc must return arrows to the editor\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL);           // close TESTING.md again
    tree_on = false;
    tree_focus = false;

    // --- project search ---
    str q = "EdmincTimerTarget";
    memcpy(&sq[0], q.data, q.len);
    sq_len = q.len;
    search_run_blocking();
    g_checks++;
    if search_hit_count() < 2 {
        print("FAIL search must find EdmincTimerTarget (got {})\n", search_hit_count());
        g_fails++;
    }
    bool in_plat = false;
    for i32 i = 0; i < search_hit_count(); i++ {
        if str_equal(search_hit_path(i), "lib/plat_mac.mc") { in_plat = true; }
    }
    g_checks++;
    if !in_plat {
        print("FAIL search must hit lib/plat_mac.mc\n");
        g_fails++;
    }
    // previews start at the code (indent stripped) and keep the
    // match visible: mcol points at the query, cropped previews
    // are flagged for the ellipsis
    for i32 i = 0; i < search_hit_count(); i++ {
        str pv = search_hit_preview(i);
        i32 mc = search_hit_mcol(i);
        g_checks++;
        if pv.len > 0 && (pv.data[0] == ' ' || pv.data[0] == 9) {
            print("FAIL preview keeps indent: '{}'\n", pv);
            g_fails++;
        }
        bool m_ok = mc + q.len <= pv.len;
        if m_ok {
            for i32 k = 0; k < q.len; k++ {
                u8 c = pv.data[mc + k];
                if c >= 'A' && c <= 'Z' { c += 32; }
                u8 d = q.data[k];
                if d >= 'A' && d <= 'Z' { d += 32; }
                if c != d { m_ok = false; }
            }
        }
        g_checks++;
        if !m_ok {
            print("FAIL preview mcol misses the match: '{}' mcol {}\n", pv, mc);
            g_fails++;
        }
        g_checks++;
        if mc > 12 && !search_hit_ell(i) {
            print("FAIL cropped preview lacks ellipsis flag\n");
            g_fails++;
        }
    }
    // case-insensitive
    str q2 = "edminctimertarget";
    memcpy(&sq[0], q2.data, q2.len);
    sq_len = q2.len;
    search_run_blocking();
    g_checks++;
    if search_hit_count() < 2 {
        print("FAIL search must be case-insensitive\n");
        g_fails++;
    }
    // arrow navigation previews: entering the list and stepping to
    // the first hit row opens that hit in the editor immediately
    search_on = true;
    search_focus = true;
    app_key(K_DOWN, 0);   // into the list (row 0 = file header)
    app_key(K_DOWN, 0);   // row 1 = first hit, should open it
    g_checks++;
    str want = search_hit_path(0);
    str got = str_from(&g_path[0], g_path_len);
    if !str_equal(got, want) {
        print("FAIL arrow nav must open the hit (want {} got {})\n", want, got);
        g_fails++;
    }
    g_checks++;
    if cur_line != search_hit_line(0) {
        print("FAIL arrow nav must move the caret to the hit line\n");
        g_fails++;
    }
    g_checks++;
    if !search_focus {
        print("FAIL arrow nav must keep focus in the search list\n");
        g_fails++;
    }
    // folds: Left from a hit row selects its header, Left again
    // folds the file (its hits leave the row model), Right unfolds
    i32 rows_open = search_row_count();
    app_key(K_LEFT, 0);
    app_key(K_LEFT, 0);
    g_checks++;
    if search_row_count() >= rows_open {
        print("FAIL folding a header must hide its hits\n");
        g_fails++;
    }
    app_key(K_RIGHT, 0);
    g_checks++;
    if search_row_count() != rows_open {
        print("FAIL unfolding must restore the rows\n");
        g_fails++;
    }
    search_close_view();
    app_key('W', MOD_CTRL);
    sq_len = 0;

    // --- splits ---
    // ctrl+\ splits; the new pane shows the same buffer with its own
    // caret; ctrl+1/2 switch panes; ctrl+w closes the buffer and the
    // panes stay, ctrl+shift+w closes the pane and the buffer stays
    ignore ed_open_file("CLAUDE.md");
    ignore ed_open_file("doc/TESTING.md");
    i32 bufs_before = ed_buf_count();   // >= 2, so a close is countable
    i32 line_a = cur_line;
    app_key(92, MOD_CTRL);
    g_checks++;
    if ed_pane_count() != 2 || ed_pane_active() != 1 {
        print("FAIL ctrl+backslash must split and focus the new pane\n");
        g_fails++;
    }
    app_key(K_DOWN, 0);
    app_key(K_DOWN, 0);
    i32 line_b = cur_line;
    app_key('1', MOD_CTRL);
    g_checks++;
    if cur_line != line_a {
        print("FAIL pane 1 caret must be untouched by pane 2 movement\n");
        g_fails++;
    }
    app_key('2', MOD_CTRL);
    g_checks++;
    if cur_line != line_b {
        print("FAIL pane 2 caret must survive the focus round trip\n");
        g_fails++;
    }
    // edits are shared: type in pane 2, read in pane 1
    app_key(K_HOME, MOD_CTRL);
    app_char('Q');
    app_key('1', MOD_CTRL);
    u8 qb = 0;
    tb_copy(0, &qb, 1);
    g_checks++;
    if qb != 'Q' {
        print("FAIL edit in pane 2 must be visible from pane 1\n");
        g_fails++;
    }
    app_key('Z', MOD_CTRL);   // undo pane 2's edit from pane 1
    app_key(K_END, MOD_CTRL);
    // both panes show the buffer: ctrl+w closes this pane's view of it,
    // the buffer staying open for the other
    app_key('W', MOD_CTRL);
    g_checks++;
    if ed_pane_count() != 2 || ed_buf_count() != bufs_before
        || ed_pane_active() != 0 || str_equal(str_from(&g_path[0], g_path_len), "doc/TESTING.md")
        || !str_equal(ed_buf_title(ed_pane_buf(1)), "TESTING.md") {
        print("FAIL ctrl+w on a buffer both panes show must close only this view ({} panes, {} bufs, {})\n",
            ed_pane_count(), ed_buf_count(), str_from(&g_path[0], g_path_len));
        g_fails++;
    }
    app_key('W', MOD_CTRL | MOD_SHIFT);   // closes the pane; the buffer stays
    g_checks++;
    if ed_pane_count() != 1 || ed_buf_count() != bufs_before {
        print("FAIL ctrl+shift+w must close the pane and keep the buffer ({} panes, {} bufs)\n",
            ed_pane_count(), ed_buf_count());
        g_fails++;
    }
    app_key('W', MOD_CTRL | MOD_SHIFT);   // the last pane stays
    g_checks++;
    if ed_pane_count() != 1 || ed_buf_count() != bufs_before {
        print("FAIL ctrl+shift+w on the last pane must do nothing\n");
        g_fails++;
    }
    // panes can show different buffers; focus swaps the whole state
    ignore ed_open_file("doc/TESTING.md");
    app_key(92, MOD_CTRL);
    ignore ed_open_file("CLAUDE.md");
    app_key('1', MOD_CTRL);
    g_checks++;
    if !str_equal(str_from(&g_path[0], g_path_len), "doc/TESTING.md") {
        print("FAIL pane 1 must keep its own buffer\n");
        g_fails++;
    }
    app_key('2', MOD_CTRL);
    g_checks++;
    if !str_equal(str_from(&g_path[0], g_path_len), "CLAUDE.md") {
        print("FAIL pane 2 must show its own buffer\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL | MOD_SHIFT);   // close pane 2; both buffers stay open
    g_checks++;
    if ed_pane_count() != 1
        || !str_equal(str_from(&g_path[0], g_path_len), "doc/TESTING.md") {
        print("FAIL closing pane 2 must land on pane 1's buffer\n");
        g_fails++;
    }

    // --- the terminal pane ---
    // Ctrl+K T puts a new terminal in the active pane, in place of the
    // document it showed, focused; the stub spawn answers a handle and no
    // output, so the screen is empty and everything typed is captured as
    // what went to the shell.
    ignore ed_open_file("doc/TESTING.md");
    i32 tp_bufs = ed_buf_count();
    term_threaded = false;   // the stub answers on this thread; no writer to drain a queue
    tc_term_len = 0;
    tt_open_term();   // the chord's own character, eaten
    g_checks++;
    if ed_pane_count() != 1 || ed_pane_kind(0) != PANE_TERM || ed_term_active() < 0 {
        print("FAIL ctrl+k t must put a terminal in the pane and focus it ({} panes, kind {})\n",
            ed_pane_count(), ed_pane_kind(0));
        g_fails++;
    }
    g_checks++;
    if tc_term_len != 0 {
        print("FAIL the chord's character must not reach the shell ({} bytes)\n", tc_term_len);
        g_fails++;
    }
    // the grid is the pane's size in cells: at least two columns, and the
    // rows under the banner
    i32 tp_t = ed_term_active();
    g_checks++;
    if term_cols(tp_t) < 2 || term_rows(tp_t) < 1 {
        print("FAIL the terminal's grid must be sized from the pane ({}x{})\n", term_cols(tp_t), term_rows(tp_t));
        g_fails++;
    }
    // typed text goes to the shell, not the buffer; enter is a return
    tc_term_len = 0;
    app_char('l');
    app_char('s');
    app_char(13);
    g_checks++;
    if tc_term_len != 3 || tc_term_out[0] != 'l' || tc_term_out[1] != 's' || tc_term_out[2] != 13 {
        print("FAIL typing in a terminal pane must go to the shell ({} bytes)\n", tc_term_len);
        g_fails++;
    }
    g_checks++;
    if tb.dirty {
        print("FAIL typing in a terminal pane must not touch the buffer\n");
        g_fails++;
    }
    // ctrl+c is the shell's while the terminal has the focus. The
    // chord's own control character follows it from a real keyboard,
    // and must not reach the shell a second time.
    tc_term_len = 0;
    when os(macos) { app_key('C', MOD_SUPER); }
    when !os(macos) { app_key('C', MOD_CTRL); }
    app_char(3);
    g_checks++;
    if tc_term_len != 1 || tc_term_out[0] != 3 {
        print("FAIL ctrl+c must reach the shell as 0x03, once ({} bytes, first {})\n", tc_term_len, cast(i32, tc_term_out[0]));
        g_fails++;
    }
    // tab and escape arrive as keys, and their characters follow
    tc_term_len = 0;
    app_key(K_TAB, 0);
    app_char(9);
    g_checks++;
    if tc_term_len != 1 || tc_term_out[0] != 9 {
        print("FAIL tab must reach the shell once ({} bytes)\n", tc_term_len);
        g_fails++;
    }
    tc_term_len = 0;
    app_key(K_ESCAPE, 0);
    app_char(27);
    g_checks++;
    if tc_term_len != 1 || tc_term_out[0] != 27 {
        print("FAIL escape must reach the shell once ({} bytes)\n", tc_term_len);
        g_fails++;
    }
    // the paste chord pastes what is on the clipboard, once
    g_clip_len = 0;
    str tclip = "hi";
    plat_clipboard_set(tclip.data, cast(i64, tclip.len));
    tc_term_len = 0;
    app_key('V', MOD_CTRL);
    app_char(22);
    g_checks++;
    if tc_term_len != 2 || tc_term_out[0] != 'h' || tc_term_out[1] != 'i' {
        print("FAIL the paste chord must paste once ({} bytes)\n", tc_term_len);
        g_fails++;
    }
    // the arrows are the shell's too
    tc_term_len = 0;
    app_key(K_UP, 0);
    g_checks++;
    if tc_term_len != 3 || tc_term_out[0] != 27 || tc_term_out[2] != 'A' {
        print("FAIL an arrow must reach the shell as its escape\n");
        g_fails++;
    }
    // the editor keeps its own: the picker opens rather than typing
    tc_term_len = 0;
    app_key('P', MOD_CTRL);
    app_char(16);
    g_checks++;
    if !pick_on || tc_term_len != 0 {
        print("FAIL ctrl+p must stay the editor's over a terminal pane ({} bytes)\n",
            tc_term_len);
        g_fails++;
    }
    app_key(K_ESCAPE, 0);   // the picker takes the escape
    // the title names the terminal, never starred
    g_checks++;
    if g_test_title_len == 0 || g_test_title[0] == '*' {
        print("FAIL the title must name the terminal pane\n");
        g_fails++;
    }
    // ctrl+k t again opens a second shell in the same pane, the first
    // dropping to the background, as a file opened there would
    tt_open_term();
    i32 tp_t2 = ed_term_active();
    g_checks++;
    if term_num(tp_t2) != term_num(tp_t) + 1 || term_num(tp_t) < 1 {
        print("FAIL shells are numbered in the order they open ({} then {})\n", term_num(tp_t), term_num(tp_t2));
        g_fails++;
    }
    // the label is "terminal N", and the title the program sets follows
    noinit u8[64] tp_lb;
    str tp_pre = "terminal ";
    memcpy(&tp_lb[0], tp_pre.data, tp_pre.len);
    i32 tp_ln = tp_pre.len + fmt_i32(&tp_lb[tp_pre.len], term_num(tp_t));
    g_checks++;
    if !str_equal(term_label(tp_t), str_from(&tp_lb[0], tp_ln)) {
        print("FAIL a shell with no title is labelled by its number: [{}]\n", term_label(tp_t));
        g_fails++;
    }
    tt_feed(tp_t2, "^]0;work`");
    memcpy(&tp_lb[0], tp_pre.data, tp_pre.len);
    tp_ln = tp_pre.len + fmt_i32(&tp_lb[tp_pre.len], term_num(tp_t2));
    str tp_suf = ": work";
    memcpy(&tp_lb[tp_ln], tp_suf.data, tp_suf.len);
    tp_ln += tp_suf.len;
    g_checks++;
    if !str_equal(term_label(tp_t2), str_from(&tp_lb[0], tp_ln)) {
        print("FAIL a shell's title follows its number: [{}]\n", term_label(tp_t2));
        g_fails++;
    }
    if tp_t2 < 0 || tp_t2 == tp_t || ed_pane_count() != 1
        || !term_has_child(tp_t) || ed_term_background_count() != 1 {
        print("FAIL ctrl+k t on a focused terminal must open another in place and keep the first ({} panes, bg {})\n",
            ed_pane_count(), ed_term_background_count());
        g_fails++;
    }
    // the screen holds its invariants after the routing above (the
    // frame itself is the fuzzer's, which links the view)
    g_checks++;
    if term_check(tp_t).len > 0 {
        print("FAIL the terminal pane's screen must hold its invariants: {}\n", term_check(tp_t));
        g_fails++;
    }
    // ctrl+w closes the shown terminal and its shell; the pane goes back
    // to its document, the buffers stay, the background shell runs on
    app_key('W', MOD_CTRL);
    g_checks++;
    if ed_pane_count() != 1 || ed_term_active() >= 0 || ed_buf_count() != tp_bufs || term_live(tp_t2)
        || !term_has_child(tp_t) || ed_term_background_count() != 1
        || !str_equal(ed_path(), "doc/TESTING.md") {
        print("FAIL ctrl+w must close the shown terminal and give the pane back to the document ({} panes, {} bufs, bg {})\n",
            ed_pane_count(), ed_buf_count(), ed_term_background_count());
        g_fails++;
    }
    // the background shell comes back through the switcher, as a
    // buffer does, and ctrl+w on it ends it
    tt_switch_to_term();
    g_checks++;
    if ed_term_active() != tp_t || ed_term_background_count() != 0 {
        print("FAIL the switcher must bring the background shell back (term {})\n", ed_term_active());
        g_fails++;
    }
    app_key('W', MOD_CTRL);
    g_checks++;
    if ed_pane_count() != 1 || ed_term_active() >= 0 || term_live(tp_t) || !str_equal(ed_path(), "doc/TESTING.md") {
        print("FAIL ctrl+w must close the terminal brought back ({} panes)\n", ed_pane_count());
        g_fails++;
    }
    // ctrl+k shift+t is the same chord: two presses make two shells,
    // the first in the background, the pane showing the second
    app_key('K', MOD_CTRL);
    app_key('T', MOD_SHIFT);
    app_char('T');
    i32 tp_a = ed_term_active();
    app_key('K', MOD_CTRL);
    app_key('T', MOD_SHIFT);
    app_char('T');
    g_checks++;
    if ed_pane_count() != 1 || ed_term_active() < 0 || ed_term_active() == tp_a
        || !term_has_child(tp_a) || ed_term_background_count() != 1 {
        print("FAIL ctrl+k shift+t must open another terminal in place ({} panes, bg {})\n",
            ed_pane_count(), ed_term_background_count());
        g_fails++;
    }
    // Output from a terminal nobody shows is no reason for a frame: its
    // screen keeps up either way, and asking for one on every read
    // repainted the window at a background build's own rate. Measured
    // against what a wake costs with nothing to read, since it does
    // more than the terminals.
    i32 fr_shown = ed_term_active();
    // the first wakes do work of their own (a fetch landing, the
    // server); let them settle so what is left is the terminals'
    for i32 i = 0; i < 6; i++ {
        app_settle();
        app_wake();
    }
    g_damage_calls = 0;
    app_wake();
    i32 fr_base = g_damage_calls;
    tt_term_arm(tp_a);        // the one in the background
    g_damage_calls = 0;
    app_wake();
    g_checks++;
    if g_damage_calls > fr_base || !term_has_child(tp_a) {
        print("FAIL a terminal nobody shows must not ask for a frame ({} against {})\n",
            g_damage_calls, fr_base);
        g_fails++;
    }
    tt_term_arm(fr_shown);    // and the one the pane shows
    g_damage_calls = 0;
    app_wake();
    g_checks++;
    if g_damage_calls <= fr_base {
        print("FAIL a terminal on screen must ask for one ({} against {})\n",
            g_damage_calls, fr_base);
        g_fails++;
    }
    app_key('W', MOD_CTRL);   // the shown one goes, the pane back to the document
    tt_switch_to_term();      // the first comes back from the background
    g_checks++;
    if ed_term_active() != tp_a || ed_term_background_count() != 0 {
        print("FAIL after a close, the switcher must bring the other terminal back (term {})\n", ed_term_active());
        g_fails++;
    }
    app_key('W', MOD_CTRL);
    g_checks++;
    if ed_pane_count() != 1 || ed_term_active() >= 0 || term_has_child(tp_a) {
        print("FAIL both terminals must be closed\n");
        g_fails++;
    }
    // two panes stay two panes: the terminal takes the active one, and
    // with a terminal on screen in another pane the chord focuses it
    app_key(92, MOD_CTRL);   // split
    g_checks++;
    if ed_pane_count() != 2 || ed_pane_active() != 1 {
        print("FAIL the split must make two panes with the second active\n");
        g_fails++;
    }
    tt_open_term();
    i32 tp_b = ed_term_active();
    g_checks++;
    if ed_pane_count() != 2 || ed_pane_kind(1) != PANE_TERM || ed_pane_kind(0) != PANE_DOC || tp_b < 0 {
        print("FAIL a terminal must replace the active pane's document, not split ({} panes)\n",
            ed_pane_count());
        g_fails++;
    }
    // a buffer switch from the terminal pane takes the pane, as it
    // would a document pane: the terminal drops to the background
    i32 sw_active = ed_buf_active();
    ed_buf_switch((sw_active + 1) % ed_buf_count());
    g_checks++;
    if ed_term_active() >= 0 || ed_pane_active() != 1 || ed_pane_kind(1) != PANE_DOC
        || ed_buf_active() == sw_active || ed_term_background_count() != 1 || !term_has_child(tp_b) {
        print("FAIL a buffer switch over a terminal pane must take the pane, the terminal going to the background\n");
        g_fails++;
    }
    tt_switch_to_term();   // the terminal back into its pane
    g_checks++;
    if ed_term_active() != tp_b || ed_pane_active() != 1 {
        print("FAIL the switcher must bring the terminal back into its pane\n");
        g_fails++;
    }
    // ctrl+k t in the document pane opens a new shell there, even with
    // a terminal on screen beside it: the chord never switches to one
    app_key('1', MOD_CTRL);
    tt_open_term();
    i32 tp_c = ed_term_active();
    g_checks++;
    if ed_pane_active() != 0 || tp_c < 0 || tp_c == tp_b || ed_pane_count() != 2
        || ed_pane_kind(1) != PANE_TERM || ed_pane_term(1) != tp_b {
        print("FAIL ctrl+k t with a terminal on screen must open another in the active pane (pane {}, term {})\n",
            ed_pane_active(), ed_term_active());
        g_fails++;
    }
    app_key('W', MOD_CTRL);   // the new shell goes; its pane stays, on its document
    g_checks++;
    if ed_pane_count() != 2 || term_has_child(tp_c) || ed_pane_kind(0) != PANE_DOC
        || ed_pane_active() != 0 || ed_pane_term(1) != tp_b {
        print("FAIL ctrl+w on a terminal pane beside another must close the shell and keep the pane ({} panes, kind {})\n",
            ed_pane_count(), ed_pane_kind(0));
        g_fails++;
    }
    app_key('W', MOD_CTRL | MOD_SHIFT);   // the document pane goes; the terminal pane is alone
    g_checks++;
    if ed_pane_count() != 1 || ed_term_active() != tp_b {
        print("FAIL ctrl+shift+w must close the document pane and land on the terminal ({} panes, term {})\n",
            ed_pane_count(), ed_term_active());
        g_fails++;
    }
    app_key('W', MOD_CTRL);   // the lone terminal pane: back to its document
    g_checks++;
    if ed_pane_count() != 1 || term_has_child(tp_b) || ed_term_active() >= 0 {
        print("FAIL ctrl+w on the lone terminal pane must close the shell and show the document\n");
        g_fails++;
    }
    // a file opened over a lone terminal pane takes the pane, the
    // terminal dropping to the background
    tt_open_term();
    i32 lone_t = ed_term_active();
    ignore ed_open_file("CLAUDE.md");
    g_checks++;
    if ed_pane_count() != 1 || ed_term_active() >= 0 || ed_pane_kind(0) != PANE_DOC
        || !term_has_child(lone_t) || !str_equal(ed_path(), "CLAUDE.md") || ed_term_background_count() != 1 {
        print("FAIL a file opened over a lone terminal pane must take the pane ({} panes, term {})\n",
            ed_pane_count(), ed_term_active());
        g_fails++;
    }
    // ctrl+w on the lone terminal pane gives it back to its document
    // and ends the shell
    tt_switch_to_term();
    g_checks++;
    if ed_term_active() != lone_t {
        print("FAIL the background shell must come back into the lone pane\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL);
    g_checks++;
    if ed_pane_count() != 1 || ed_term_active() >= 0 || ed_pane_kind(0) != PANE_DOC
        || term_live(lone_t) || ed_buf_count() < tp_bufs || ed_term_background_count() != 0 {
        print("FAIL ctrl+w on a lone terminal pane must give the pane back to the document ({} panes, {} bufs)\n",
            ed_pane_count(), ed_buf_count());
        g_fails++;
    }

    // A file opened from a terminal pane takes that pane wherever it
    // is, the terminal dropping to the background: two document panes
    // and a terminal on the right put the file in the right pane.
    ignore ed_open_file("doc/TESTING.md");
    app_key(92, MOD_CTRL);   // [doc|doc], the second active
    app_key(92, MOD_CTRL);   // [doc|doc|doc], the third active
    tt_open_term();
    i32 right_t = ed_term_active();
    ignore ed_open_file("CLAUDE.md");
    g_checks++;
    if ed_pane_count() != 3 || ed_pane_active() != 2 || ed_pane_kind(2) != PANE_DOC
        || ed_term_background_count() != 1 || !term_has_child(right_t)
        || !str_equal(ed_path(), "CLAUDE.md") {
        print("FAIL a file opened from a terminal pane on the right must take that pane (pane {} of {})\n",
            ed_pane_active(), ed_pane_count());
        g_fails++;
    }
    tt_switch_to_term();      // the terminal back into the pane
    app_key('W', MOD_CTRL);   // the shell goes, the pane stays on its document
    app_key('W', MOD_CTRL | MOD_SHIFT);
    app_key('W', MOD_CTRL | MOD_SHIFT);
    g_checks++;
    if ed_pane_count() != 1 || ed_term_active() >= 0 || ed_term_background_count() != 0 {
        print("FAIL the right-pane check must leave one document pane ({} panes)\n", ed_pane_count());
        g_fails++;
    }

    // The picker's matcher: after the first character, a query character
    // continues a run or starts a word, so a query's letters scattered
    // through a path are no match. "vw" no longer finds view.mc; "ev"
    // still finds the run at the start of evscript.mc; a file name
    // typed whole is on top with few others under it.
    app_key('P', MOD_CTRL);
    app_char('v');
    app_char('w');
    bool pk_scatter = false;
    for i32 i = 0; i < pick_hit_count(); i++ {
        if str_equal(pick_hit_path(i), "src/view.mc") { pk_scatter = true; }
    }
    g_checks++;
    if pk_scatter {
        print("FAIL the picker must not match letters scattered through a path (vw found view.mc)\n");
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    app_key('P', MOD_CTRL);
    app_char('e');
    app_char('v');
    bool pk_run = false;
    for i32 i = 0; i < pick_hit_count() && i < 3; i++ {
        if str_equal(pick_hit_path(i), "src/evscript.mc") { pk_run = true; }
    }
    g_checks++;
    if !pk_run {
        print("FAIL the picker must match a run inside a word (ev, evscript.mc; {} hits, first {})\n",
            pick_hit_count(), pick_hit_path(0));
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    app_key('P', MOD_CTRL);
    str pk_q = "view.mc";
    for i32 i = 0; i < pk_q.len; i++ { app_char(cast(u32, pk_q.data[i])); }
    g_checks++;
    if !str_equal(pick_hit_path(0), "src/view.mc") || pick_hit_count() > 4 {
        print("FAIL a file name typed whole must be on top with few others ({} hits, first {})\n",
            pick_hit_count(), pick_hit_path(0));
        g_fails++;
    }
    app_key(K_ESCAPE, 0);

    check_watch();

    // carets inside one character snap to its start before they merge:
    // snapped after, two carets a byte apart in a character became two
    // cursors on one place
    reset("x");
    app_key(K_END, MOD_CTRL);
    app_char(0x20AC);                   // the euro sign: three bytes, 1..3
    app_char('y');
    i64[2] mid = { 2, 3 };
    ed_cursors_set(&mid[0], 2);
    i64 sc = 0;
    i64 sa = 0;
    i64 sb = 0;
    ed_cur_get(0, &sc, &sa, &sb);
    g_checks++;
    if ed_cur_count() != 1 || sc != 1 {
        i64 sc1 = 0;
        i64 sa1 = 0;
        i64 sb1 = 0;
        if ed_cur_count() > 1 { ed_cur_get(1, &sc1, &sa1, &sb1); }
        print("FAIL carets inside one character must snap to its start and merge ({} cursors, caret {}, second {} {}..{}, len {})\n",
            ed_cur_count(), sc, sc1, sa1, sb1, tb_len());
        g_fails++;
    }

    // the palette's quick toggle: the buffer shown before, at once
    close_all();
    ignore ed_open_file("src/pick.mc");
    ignore ed_open_file("src/find.mc");
    app_key('P', MOD_CTRL | MOD_SHIFT);
    str qt = "previous editor";
    for i32 i = 0; i < qt.len; i++ { app_char(cast(u32, qt.data[i])); }
    app_char(13);
    g_checks++;
    if switcher_on || palette_on || !str_equal(ed_path(), "src/pick.mc") {
        print("FAIL the palette's switch to the previous editor must land on it ({}, switcher {})\n",
            ed_path(), switcher_on);
        g_fails++;
    }

    // the picker and the palette hand over to each other on their chords,
    // and each chord again closes its own
    close_all();
    app_key('P', MOD_CTRL);
    app_key('P', MOD_CTRL | MOD_SHIFT);
    g_checks++;
    if pick_on || !palette_on {
        print("FAIL ctrl+shift+p in the picker must open the palette (pick {}, palette {})\n", pick_on, palette_on);
        g_fails++;
    }
    app_key('P', MOD_CTRL);
    g_checks++;
    if !pick_on || palette_on {
        print("FAIL ctrl+p in the palette must open the picker (pick {}, palette {})\n", pick_on, palette_on);
        g_fails++;
    }
    app_key('P', MOD_CTRL);
    g_checks++;
    if pick_on || palette_on {
        print("FAIL ctrl+p in the picker must close it (pick {}, palette {})\n", pick_on, palette_on);
        g_fails++;
    }
    app_key('P', MOD_CTRL | MOD_SHIFT);
    app_key('P', MOD_CTRL | MOD_SHIFT);
    g_checks++;
    if pick_on || palette_on {
        print("FAIL ctrl+shift+p in the palette must close it (pick {}, palette {})\n", pick_on, palette_on);
        g_fails++;
    }

    // Ctrl+Alt+Left and Right move what the active pane shows to the
    // pane on that side, the focus with it; the pane it left shows the
    // buffer last seen apart from it, and a terminal pane its document
    ignore ed_open_file("src/pick.mc");
    ignore ed_open_file("src/find.mc");
    app_key(92, MOD_CTRL);                // pane 1, on find.mc too
    ignore ed_open_file("src/view.mc");   // pane 1 shows view.mc
    app_key(K_LEFT, MOD_CTRL | MOD_ALT);
    g_checks++;
    if ed_pane_active() != 0 || !str_equal(ed_path(), "src/view.mc") || ed_pane_count() != 2 {
        print("FAIL ctrl+alt+left must move the buffer to the left pane and follow it (pane {}, {})\n",
            ed_pane_active(), ed_path());
        g_fails++;
    }
    app_key('2', MOD_CTRL);
    g_checks++;
    if !str_equal(ed_path(), "src/find.mc") {
        print("FAIL the pane the buffer left must show the buffer last seen apart from it ({})\n", ed_path());
        g_fails++;
    }
    app_key('1', MOD_CTRL);
    app_key(K_RIGHT, MOD_CTRL | MOD_ALT);
    g_checks++;
    if ed_pane_active() != 1 || !str_equal(ed_path(), "src/view.mc") {
        print("FAIL ctrl+alt+right must move the buffer back to the right pane (pane {}, {})\n",
            ed_pane_active(), ed_path());
        g_fails++;
    }
    app_key(K_RIGHT, MOD_CTRL | MOD_ALT);   // at the edge: nothing moves
    g_checks++;
    if ed_pane_active() != 1 || !str_equal(ed_path(), "src/view.mc") || ed_pane_count() != 2 {
        print("FAIL a move past the last pane must do nothing\n");
        g_fails++;
    }
    app_key('1', MOD_CTRL);
    tt_open_term();
    i32 mv_t = ed_term_active();
    app_key(K_RIGHT, MOD_CTRL | MOD_ALT);
    g_checks++;
    if ed_pane_active() != 1 || ed_term_active() != mv_t || ed_pane_kind(0) != PANE_DOC {
        print("FAIL a terminal pane must move too, its pane going back to its document (pane {}, term {}, kind {})\n",
            ed_pane_active(), ed_term_active(), ed_pane_kind(0));
        g_fails++;
    }
    app_key('W', MOD_CTRL);               // the shell goes, the pane back to its document
    app_key('W', MOD_CTRL | MOD_SHIFT);   // and the pane
    g_checks++;
    if ed_pane_count() != 1 || ed_term_active() >= 0 {
        print("FAIL the move checks must leave one document pane ({} panes)\n", ed_pane_count());
        g_fails++;
    }

    // a selection ends with its terminal: the slot is reused by the next
    // one opened, and a selection left behind would sit on its text
    ignore ed_open_file("doc/TESTING.md");
    tt_open_term();
    i32 sx_t = ed_term_active();
    tt_feed(sx_t, "hello world\r\n");
    i32 sx_x0 = 0;
    i32 sx_x1 = 0;
    ed_pane_rect(0, &sx_x0, &sx_x1);
    i32 sx_ox = sx_x0 + TERM_PAD_PX + font_cell_w / 2;
    i32 sx_oy = doc_top() + font_line_h / 2;
    app_mouse(sx_ox, sx_oy, 0, true, 0);
    app_mouse_move(sx_ox + 4 * font_cell_w, sx_oy);
    app_mouse(sx_ox + 4 * font_cell_w, sx_oy, 0, false, 0);
    bool sx_had = ed_term_sel_on(sx_t);
    app_key('W', MOD_CTRL);               // the shell goes, with its selection
    tt_open_term();                       // the next terminal, likely in the same slot
    g_checks++;
    if !sx_had || ed_term_sel_check().len > 0 || ed_term_sel_on(ed_term_active()) {
        print("FAIL a selection must end with its terminal (had {}, check [{}])\n",
            sx_had, ed_term_sel_check());
        g_fails++;
    }
    app_key('W', MOD_CTRL);
    close_all();

    // --- cell selection and copy in a terminal pane: a drag selects,
    // the primary's copy chord takes it, a click or a key clears it, the
    // child with the mouse gets the drag unless Shift is held, and the
    // selection stays on its text while output scrolls under it ---
    ignore ed_open_file("doc/TESTING.md");
    tt_open_term();
    i32 cs_t = ed_term_active();
    tt_feed(cs_t, "hello world\r\nsecond line\r\n");
    i32 cs_x0 = 0;
    i32 cs_x1 = 0;
    ed_pane_rect(0, &cs_x0, &cs_x1);
    i32 cs_ox = cs_x0 + TERM_PAD_PX + font_cell_w / 2;
    i32 cs_oy = doc_top() + font_line_h / 2;
    app_mouse(cs_ox, cs_oy, 0, true, 0);
    app_mouse_move(cs_ox + 4 * font_cell_w, cs_oy + font_line_h);
    app_mouse(cs_ox + 4 * font_cell_w, cs_oy + font_line_h, 0, false, 0);
    i64 cs_n = 0;
    u8* cs_s = ed_term_sel_text(&cs_n);
    g_checks++;
    if cs_s == null || !str_equal(str_from(cs_s, cast(i32, cs_n)), "hello world\nsecon") || !ed_term_sel_on(cs_t) {
        print("FAIL a drag must select the cells from the anchor to the head ([{}])\n",
            cs_s == null ? "" : str_from(cs_s, cast(i32, cs_n)));
        g_fails++;
    }
    if cs_s != null { free(cs_s); }
    // the copy chord takes it, and nothing goes to the shell
    tc_term_len = 0;
    g_clip_len = 0;
    app_key('C', MOD_CTRL);
    g_checks++;
    if g_clip_len != 17 || !str_equal(str_from(g_clip, cast(i32, g_clip_len)), "hello world\nsecon") || tc_term_len != 0 {
        print("FAIL the copy chord must put the selection on the clipboard ({} bytes, {} to the shell)\n",
            g_clip_len, tc_term_len);
        g_fails++;
    }
    // a click clears it; then the chord is the shell's interrupt again
    app_mouse(cs_ox, cs_oy, 0, true, 0);
    app_mouse(cs_ox, cs_oy, 0, false, 0);
    g_checks++;
    if ed_term_sel_on(cs_t) {
        print("FAIL a click without a drag must clear the selection\n");
        g_fails++;
    }
    tc_term_len = 0;
    when os(macos) { app_key('C', MOD_SUPER); }
    when !os(macos) { app_key('C', MOD_CTRL); }
    g_checks++;
    if tc_term_len != 1 || tc_term_out[0] != 3 {
        print("FAIL without a selection ctrl+c must reach the shell ({} bytes)\n", tc_term_len);
        g_fails++;
    }

    // the right button is the console's: it copies a selection and
    // clears it, and pastes when there is none
    app_mouse(cs_ox, cs_oy, 0, true, 0);
    app_mouse_move(cs_ox + 4 * font_cell_w, cs_oy);
    app_mouse(cs_ox + 4 * font_cell_w, cs_oy, 0, false, 0);
    g_clip_len = 0;
    tc_term_len = 0;
    app_mouse(cs_ox, cs_oy, 1, true, 0);
    app_mouse(cs_ox, cs_oy, 1, false, 0);
    g_checks++;
    if g_clip_len != 5 || !str_equal(str_from(g_clip, cast(i32, g_clip_len)), "hello")
        || ed_term_sel_on(cs_t) || tc_term_len != 0 {
        print("FAIL the right button must copy the selection and clear it ([{}], {} to the shell)\n",
            str_from(g_clip, cast(i32, g_clip_len)), tc_term_len);
        g_fails++;
    }
    // and again, with nothing selected, it pastes what it took
    tc_term_len = 0;
    app_mouse(cs_ox, cs_oy, 1, true, 0);
    app_mouse(cs_ox, cs_oy, 1, false, 0);
    g_checks++;
    if tc_term_len != 5 || !str_equal(str_from(&tc_term_out[0], tc_term_len), "hello") {
        print("FAIL the right button must paste when nothing is selected ({} bytes [{}])\n",
            tc_term_len, str_from(&tc_term_out[0], tc_term_len));
        g_fails++;
    }
    // a child that asked for the mouse gets the click instead
    tt_feed(cs_t, "^[?1000h");
    tc_term_len = 0;
    app_mouse(cs_ox, cs_oy, 1, true, 0);
    g_checks++;
    if tc_term_len == 0 || tc_term_out[0] != 27 {
        print("FAIL a child with the mouse must get the right click ({} bytes)\n",
            tc_term_len);
        g_fails++;
    }
    // unless Shift is held, which is the drag's rule too
    tc_term_len = 0;
    app_mouse(cs_ox, cs_oy, 1, true, MOD_SHIFT);
    g_checks++;
    if tc_term_len != 5 {
        print("FAIL shift must keep the right click for the editor ({} bytes)\n",
            tc_term_len);
        g_fails++;
    }
    tt_feed(cs_t, "^[?1000l");
    // a key to the shell clears a selection
    app_mouse(cs_ox, cs_oy, 0, true, 0);
    app_mouse_move(cs_ox + 2 * font_cell_w, cs_oy);
    app_mouse(cs_ox + 2 * font_cell_w, cs_oy, 0, false, 0);
    app_char('x');
    g_checks++;
    if ed_term_sel_on(cs_t) {
        print("FAIL typing must clear the selection\n");
        g_fails++;
    }
    // the selection follows its text when output scrolls under it
    app_mouse(cs_ox, cs_oy, 0, true, 0);
    app_mouse_move(cs_ox + 4 * font_cell_w, cs_oy + font_line_h);
    app_mouse(cs_ox + 4 * font_cell_w, cs_oy + font_line_h, 0, false, 0);
    for i32 i = 0; i < term_rows(cs_t) + 2; i++ { tt_feed(cs_t, "more\r\n"); }
    cs_s = ed_term_sel_text(&cs_n);
    g_checks++;
    if cs_s == null || !str_equal(str_from(cs_s, cast(i32, cs_n)), "hello world\nsecon") {
        print("FAIL the selection must stay on its text after a scroll ([{}])\n",
            cs_s == null ? "" : str_from(cs_s, cast(i32, cs_n)));
        g_fails++;
    }
    if cs_s != null { free(cs_s); }
    g_checks++;
    if ed_term_sel_check().len > 0 {
        print("FAIL the selection must hold its invariants: {}\n", ed_term_sel_check());
        g_fails++;
    }
    // a child that asked for the mouse gets the drag; Shift selects anyway
    app_char('x');   // clears
    tt_feed(cs_t, "^[?1000h");
    tc_term_len = 0;
    app_mouse(cs_ox, cs_oy, 0, true, 0);
    app_mouse_move(cs_ox + 3 * font_cell_w, cs_oy);
    app_mouse(cs_ox + 3 * font_cell_w, cs_oy, 0, false, 0);
    g_checks++;
    if ed_term_sel_on(cs_t) || tc_term_len == 0 {
        print("FAIL with the child on the mouse a drag is the child's ({} bytes)\n", tc_term_len);
        g_fails++;
    }
    app_mouse(cs_ox, cs_oy, 0, true, MOD_SHIFT);
    app_mouse_move(cs_ox + 3 * font_cell_w, cs_oy);
    app_mouse(cs_ox + 3 * font_cell_w, cs_oy, 0, false, MOD_SHIFT);
    g_checks++;
    if !ed_term_sel_on(cs_t) {
        print("FAIL shift+drag must select even when the child has the mouse\n");
        g_fails++;
    }
    // the paste chord puts the clipboard into the shell: newlines as
    // returns, and wrapped once the child asked for bracketed paste
    str cs_clip = "ls -la\necho x\n";
    plat_clipboard_set(cs_clip.data, cs_clip.len);
    tc_term_len = 0;
    app_key('V', MOD_CTRL);
    g_checks++;
    if tc_term_len != 14 || !str_equal(str_from(&tc_term_out[0], tc_term_len), "ls -la\recho x\r") {
        print("FAIL the paste chord must send the clipboard to the shell ({} bytes)\n", tc_term_len);
        g_fails++;
    }
    tt_feed(cs_t, "^[?2004h");
    tc_term_len = 0;
    app_key('V', MOD_CTRL);
    g_checks++;
    if tc_term_len != 26 || tc_term_out[0] != 27 || tc_term_out[5] != '~' || tc_term_out[tc_term_len - 1] != '~' {
        print("FAIL a paste under bracketed mode must be wrapped ({} bytes)\n", tc_term_len);
        g_fails++;
    }
    app_key('W', MOD_CTRL);
    g_checks++;
    if ed_term_sel_on(cs_t) || ed_term_active() >= 0 {
        print("FAIL closing the terminal must drop its selection\n");
        g_fails++;
    }

    // --- ctrl+k w: the switcher. A terminal put aside keeps running in
    // the background and comes back through the list ---
    ignore ed_open_file("doc/TESTING.md");
    ignore ed_open_file("CLAUDE.md");
    tt_open_term();
    i32 sw_t = ed_term_active();
    app_key('K', MOD_CTRL);
    app_key('W', 0);
    app_char('w');
    g_checks++;
    if !switcher_on || switcher_count() != ed_buf_count() + 1
        || switcher_item_kind(switcher_count() - 1) != SW_TERM
        || switcher_item_id(switcher_count() - 1) != sw_t {
        print("FAIL ctrl+k w must list the buffers and the terminal ({} rows, {} bufs, on {})\n",
            switcher_count(), ed_buf_count(), switcher_on);
        g_fails++;
    }
    // the list opens on the item after the one on screen: the terminal
    // is last, so the first buffer
    g_checks++;
    if switcher_sel() != 0 {
        print("FAIL the switcher must open on the next item ({})\n", switcher_sel());
        g_fails++;
    }
    app_char('T');
    app_char('E');
    app_char('S');
    app_char('T');
    g_checks++;
    if switcher_count() != 1 || switcher_item_kind(0) != SW_BUF
        || !str_equal(ed_buf_title(switcher_item_id(0)), "TESTING.md") {
        print("FAIL typing must narrow the list to the match ({} rows)\n", switcher_count());
        g_fails++;
    }
    app_char(13);
    g_checks++;
    if switcher_on || ed_term_active() >= 0 || ed_pane_count() != 1
        || !str_equal(ed_path(), "doc/TESTING.md") || !term_has_child(sw_t)
        || ed_term_background_count() != 1 {
        print("FAIL enter must put the buffer in the pane and keep the terminal behind ({} {} bg {})\n",
            ed_path(), cast(i32, term_has_child(sw_t)), ed_term_background_count());
        g_fails++;
    }
    // and the terminal comes back into the same pane through the list
    app_key('K', MOD_CTRL);
    app_key('W', 0);
    app_char('w');
    app_char('t');
    app_char('e');
    app_char('r');
    app_char('m');
    g_checks++;
    if switcher_count() < 1 || switcher_item_kind(0) != SW_TERM {
        print("FAIL 'term' must find the terminal ({} rows)\n", switcher_count());
        g_fails++;
    }
    app_char(13);
    g_checks++;
    if ed_term_active() != sw_t || ed_pane_count() != 1 || ed_term_background_count() != 0 {
        print("FAIL enter on the terminal must show it again in the pane (term {}, {} panes)\n",
            ed_term_active(), ed_pane_count());
        g_fails++;
    }
    // escape closes without a change; a click outside does too
    app_key('K', MOD_CTRL);
    app_key('W', 0);
    app_char('w');
    app_key(K_ESCAPE, 0);
    g_checks++;
    if switcher_on || ed_term_active() != sw_t {
        print("FAIL escape must close the switcher and change nothing\n");
        g_fails++;
    }
    // ctrl+tab opens the same list from a focused terminal, and accepts
    // into that pane: the chord acts on the pane it was pressed in
    app_key(K_TAB, MOD_CTRL);
    g_checks++;
    if !switcher_on {
        print("FAIL ctrl+tab on a terminal pane must open the switcher\n");
        g_fails++;
    }
    app_char(13);
    g_checks++;
    if ed_pane_count() != 1 || ed_term_active() >= 0
        || ed_term_background_count() != 1 {
        print("FAIL ctrl+tab must land in the terminal's own pane ({} panes, term {}, bg {})\n",
            ed_pane_count(), ed_term_active(), ed_term_background_count());
        g_fails++;
    }
    // and back to the terminal for what follows
    tt_switch_to_term();
    g_checks++;
    if ed_term_active() != sw_t {
        print("FAIL the switcher must bring the same shell back (term {})\n", ed_term_active());
        g_fails++;
    }
    // aside again, then ctrl+k t opens a second shell rather than
    // bringing the background one back: that is the switcher's job
    app_key('K', MOD_CTRL);
    app_key('W', 0);
    app_char('w');
    app_char('P');
    app_char('L');
    app_char('A');
    app_char('N');
    app_char(13);
    tt_open_term();
    g_checks++;
    if ed_term_active() < 0 || ed_term_active() == sw_t || ed_pane_count() != 1
        || ed_term_background_count() != 1 {
        print("FAIL ctrl+k t must open a second shell in the pane (term {}, {} panes, bg {})\n",
            ed_term_active(), ed_pane_count(), ed_term_background_count());
        g_fails++;
    }
    app_key('W', MOD_CTRL);   // the second goes
    tt_switch_to_term();      // the first comes back
    g_checks++;
    if ed_term_active() != sw_t || ed_pane_count() != 1 || ed_term_background_count() != 0 {
        print("FAIL the switcher must bring the background terminal back into the pane (term {}, {} panes)\n",
            ed_term_active(), ed_pane_count());
        g_fails++;
    }
    // ctrl+w on it ends it for good, and the pane with it
    app_key('W', MOD_CTRL);
    g_checks++;
    if term_has_child(sw_t) || ed_pane_count() != 1 || ed_term_background_count() != 0 {
        print("FAIL ctrl+w must close the terminal itself ({} panes)\n", ed_pane_count());
        g_fails++;
    }
    ignore term_check(sw_t);

    // divider drag: grab the pane border, drag right, panes resize;
    // the caret must not move
    ignore ed_open_file("doc/TESTING.md");
    app_key(92, MOD_CTRL);
    i32 dx0 = 0;
    i32 dx1 = 0;
    ed_pane_rect(1, &dx0, &dx1);
    i32 div_before = dx0;
    i32 dcl = cur_line;
    g_checks++;
    if app_cursor_kind(div_before, 100) != CURSOR_RESIZE_H {
        print("FAIL divider must show the resize cursor\n");
        g_fails++;
    }
    app_mouse(div_before, 100, 0, true, 0);
    app_mouse_move(div_before + 40, 100);
    app_mouse(div_before + 40, 100, 0, false, 0);
    ed_pane_rect(1, &dx0, &dx1);
    g_checks++;
    if dx0 < div_before + 38 || dx0 > div_before + 42 {
        print("FAIL divider drag must move the border (was {}, now {})\n", div_before, dx0);
        g_fails++;
    }
    g_checks++;
    if cur_line != dcl {
        print("FAIL divider drag must not move the caret\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL | MOD_SHIFT);   // close the pane again

    // ctrl+e focuses the tree; tab hands focus back to the editor
    tree_on = false;
    app_key('E', MOD_CTRL);
    g_checks++;
    if !tree_on || !tree_focus || tree_sel_row() < 0 {
        print("FAIL ctrl+e must show and focus the tree at the top row\n");
        g_fails++;
    }
    i64 tab_before = tb_len();
    app_key(K_TAB, 0);   // the chord half of a Tab press: a no-op
    app_char(9);         // the char half: hands focus back, no insert
    g_checks++;
    if tree_focus || tb_len() != tab_before {
        print("FAIL tab must return focus without touching the buffer\n");
        g_fails++;
    }
    tree_on = false;
    // sidebar edge drag resizes the tree; ctrl+b toggles it from
    // either modifier (the platform's real ctrl arrives as super)
    if !tree_on { tree_toggle(); }
    i32 cl0 = content_left();
    app_mouse(cl0, 100, 0, true, 0);
    app_mouse_move(cl0 + 30, 100);
    app_mouse(cl0 + 30, 100, 0, false, 0);
    g_checks++;
    if content_left() != cl0 + 30 {
        print("FAIL sidebar drag must resize the tree (was {}, now {})\n", cl0, content_left());
        g_fails++;
    }
    app_key('B', MOD_SUPER);
    g_checks++;
    if tree_on {
        print("FAIL ctrl+b (super) must hide the tree\n");
        g_fails++;
    }
    app_key('B', MOD_CTRL);
    g_checks++;
    if !tree_on {
        print("FAIL ctrl+b (primary) must show the tree\n");
        g_fails++;
    }
    tree_on = false;

    // markdown lexing: heading class, fence state carry, code
    // spans, list markers; .md selects the markdown lexer
    noinit u8[64] mcls;
    str mh = "# Title";
    ignore lex_md_line(mh.data, mh.len, 0, &mcls[0]);
    g_checks++;
    if mcls[0] != LEX_DECL || mcls[6] != LEX_DECL {
        print("FAIL md heading must lex LEX_DECL\n");
        g_fails++;
    }
    str mf = "```";
    i32 mst = lex_md_line(mf.data, mf.len, 0, &mcls[0]);
    g_checks++;
    if mst == 0 {
        print("FAIL md fence must carry state\n");
        g_fails++;
    }
    str mb = "plain code";
    mst = lex_md_line(mb.data, mb.len, mst, &mcls[0]);
    g_checks++;
    if mcls[0] != LEX_STR || mst == 0 {
        print("FAIL md fenced line must lex LEX_STR and stay in fence\n");
        g_fails++;
    }
    mst = lex_md_line(mf.data, mf.len, mst, &mcls[0]);
    g_checks++;
    if mst != 0 {
        print("FAIL md closing fence must clear the state\n");
        g_fails++;
    }
    str ml = "- item with `code`";
    ignore lex_md_line(ml.data, ml.len, 0, &mcls[0]);
    g_checks++;
    if mcls[0] != LEX_LIST || mcls[2] != LEX_DEF || mcls[12] != LEX_STR || mcls[17] != LEX_STR {
        print("FAIL md list marker / code span classes\n");
        g_fails++;
    }
    str mu = "gpu_metal, font_coretext and *em*";
    ignore lex_md_line(mu.data, mu.len, 0, &mcls[0]);
    g_checks++;
    if mcls[4] != LEX_DEF || mcls[16] != LEX_DEF || mcls[29] != LEX_DECL {
        print("FAIL intra-word underscores must stay literal\n");
        g_fails++;
    }
    // the vector builtins take the struct color, the scalars stay blue
    str vt = "float4 v = int4{1,2,3,4}; i32 n = 0;";
    noinit u8[64] vcls;
    ignore lex_line(vt.data, vt.len, 0, &vcls[0]);
    g_checks++;
    if vcls[0] != LEX_TYPE || vcls[11] != LEX_TYPE || vcls[26] != LEX_DECL {
        print("FAIL vector builtins must lex as types ({} {} {})\n",
            cast(i32, vcls[0]), cast(i32, vcls[11]), cast(i32, vcls[26]));
        g_fails++;
    }

    // the basic language lexers: a keyword/name/comment probe each, plus
    // one carried-state round trip where a construct spans lines
    noinit u8[64] lcls;
    str js = "const x = foo(1);";
    i32 lst = lex_js_line(js.data, js.len, 0, &lcls[0]);
    g_checks++;
    if lcls[0] != LEX_DECL || lcls[10] != LEX_FN || lst != 0 {
        print("FAIL js: const/call classes ({} {})\n", cast(i32, lcls[0]), cast(i32, lcls[10]));
        g_fails++;
    }
    str jc = "a /* c";
    lst = lex_js_line(jc.data, jc.len, 0, &lcls[0]);
    str jc2 = "c */ b";
    i32 lst2 = lex_js_line(jc2.data, jc2.len, lst, &lcls[0]);
    g_checks++;
    if lst == 0 || lcls[0] != LEX_COM || lst2 != 0 {
        print("FAIL js: block comment must carry and close\n");
        g_fails++;
    }
    str py = "def foo(): # c";
    ignore lex_py_line(py.data, py.len, 0, &lcls[0]);
    g_checks++;
    if lcls[0] != LEX_DECL || lcls[4] != LEX_FN || lcls[11] != LEX_COM {
        print("FAIL py: def/call/comment classes\n");
        g_fails++;
    }
    str pt = "x = '''a";
    lst = lex_py_line(pt.data, pt.len, 0, &lcls[0]);
    str pt2 = "still '''";
    lst2 = lex_py_line(pt2.data, pt2.len, lst, &lcls[0]);
    g_checks++;
    if lst == 0 || lcls[4] != LEX_STR || lst2 != 0 {
        print("FAIL py: triple string must carry and close\n");
        g_fails++;
    }
    str sh = "$x = 1  # c";
    ignore lex_sh_line(sh.data, sh.len, 0, &lcls[0]);
    g_checks++;
    if lcls[0] != LEX_VAR || lcls[5] != LEX_NUM || lcls[8] != LEX_COM {
        print("FAIL sh: variable/number/comment classes\n");
        g_fails++;
    }
    str sb3 = "a <# c";
    lst = lex_sh_line(sb3.data, sb3.len, 0, &lcls[0]);
    str sb2 = "c #> b";
    lst2 = lex_sh_line(sb2.data, sb2.len, lst, &lcls[0]);
    g_checks++;
    if lst == 0 || lcls[0] != LEX_COM || lst2 != 0 {
        print("FAIL sh: block comment must carry and close\n");
        g_fails++;
    }
    str ht = "<div class=\"a\">x</div>";
    ignore lex_html_line(ht.data, ht.len, 0, &lcls[0]);
    g_checks++;
    if lcls[1] != LEX_TYPE || lcls[5] != LEX_VAR || lcls[11] != LEX_STR {
        print("FAIL html: tag/attr/value classes\n");
        g_fails++;
    }
    str hc = "a <!-- c";
    lst = lex_html_line(hc.data, hc.len, 0, &lcls[0]);
    str hc2 = "c --> b";
    lst2 = lex_html_line(hc2.data, hc2.len, lst, &lcls[0]);
    g_checks++;
    if lst == 0 || lcls[0] != LEX_COM || lst2 != 0 {
        print("FAIL html: comment must carry and close\n");
        g_fails++;
    }
    // a script body lexes as JavaScript and a style body as CSS, up to
    // the closing tag, across lines and through a multi-line opening tag
    str hs = "<script>if (x) f();</script><p>";
    lst = lex_html_line(hs.data, hs.len, 0, &lcls[0]);
    g_checks++;
    if lcls[8] != LEX_CTRL || lcls[15] != LEX_FN || lcls[21] != LEX_TYPE || lcls[29] != LEX_TYPE || lst != 0 {
        print("FAIL html: a script body must lex as js and end at its closing tag ({} {} {})\n",
            cast(i32, lcls[8]), cast(i32, lcls[15]), lst);
        g_fails++;
    }
    str hy = "<style>";
    lst = lex_html_line(hy.data, hy.len, 0, &lcls[0]);
    str hy2 = "a { color: red; }";
    lst2 = lex_html_line(hy2.data, hy2.len, lst, &lcls[0]);
    bool css_in = lcls[0] == LEX_TYPE && lcls[4] == LEX_VAR && lcls[11] == LEX_STR;
    str hy3 = "</style> x";
    i32 lst3 = lex_html_line(hy3.data, hy3.len, lst2, &lcls[0]);
    g_checks++;
    if lst == 0 || !css_in || lcls[2] != LEX_TYPE || lst3 != 0 {
        print("FAIL html: a style body must lex as css and end at its closing tag ({} {})\n", lst, lst3);
        g_fails++;
    }
    str hj = "<script";
    lst = lex_html_line(hj.data, hj.len, 0, &lcls[0]);
    str hj2 = "  type=\"module\">/* a";
    lst2 = lex_html_line(hj2.data, hj2.len, lst, &lcls[0]);
    str hj3 = "b */ let x";
    lst3 = lex_html_line(hj3.data, hj3.len, lst2, &lcls[0]);
    g_checks++;
    if lcls[0] != LEX_COM || lcls[5] != LEX_DECL || lst3 == 0 {
        print("FAIL html: a script comment must carry past a multi-line opening tag ({} {})\n",
            cast(i32, lcls[0]), cast(i32, lcls[5]));
        g_fails++;
    }
    str cs = "a.b:hover { color: #fff; margin: -2px auto !important; }";
    lst = lex_css_line(cs.data, cs.len, 0, &lcls[0]);
    g_checks++;
    if lcls[0] != LEX_TYPE || lcls[1] != LEX_TYPE || lcls[4] != LEX_TYPE || lcls[12] != LEX_VAR
        || lcls[19] != LEX_NUM || lcls[33] != LEX_NUM || lcls[38] != LEX_STR || lcls[43] != LEX_CTRL || lst != 0 {
        print("FAIL css: selector/property/value classes\n");
        g_fails++;
    }
    str cm = "a {";
    lst = lex_css_line(cm.data, cm.len, 0, &lcls[0]);
    str cm2 = "  --gap: calc(1px";
    lst2 = lex_css_line(cm2.data, cm2.len, lst, &lcls[0]);
    bool cm_ok = lcls[2] == LEX_VAR && lcls[9] == LEX_FN && lcls[14] == LEX_NUM;
    str cm3 = "    + 2px); } /* c";
    lst3 = lex_css_line(cm3.data, cm3.len, lst2, &lcls[0]);
    g_checks++;
    if !cm_ok || lcls[6] != LEX_NUM || lst3 != 1 {
        print("FAIL css: a value and a comment must carry across lines ({} {})\n", lst2, lst3);
        g_fails++;
    }
    str gm = "var c = $FF + #00ff00; with (other) draw_self(); // x";
    lst = lex_gml_line(gm.data, gm.len, 0, &lcls[0]);
    g_checks++;
    if lcls[0] != LEX_DECL || lcls[4] != LEX_VAR || lcls[8] != LEX_NUM || lcls[14] != LEX_NUM
        || lcls[19] != LEX_NUM || lcls[23] != LEX_CTRL || lcls[29] != LEX_DECL || lcls[36] != LEX_FN
        || lcls[50] != LEX_COM || lst != 0 {
        print("FAIL gml: keyword/number/function/comment classes\n");
        g_fails++;
    }
    str gt = "s = $\"hp {hp} \\n\"; #region Setup";
    ignore lex_gml_line(gt.data, gt.len, 0, &lcls[0]);
    g_checks++;
    if lcls[4] != LEX_STR || lcls[9] != LEX_ESC || lcls[10] != LEX_VAR || lcls[12] != LEX_ESC
        || lcls[14] != LEX_ESC || lcls[19] != LEX_PRE || lcls[27] != LEX_COM {
        print("FAIL gml: template string and region classes\n");
        g_fails++;
    }
    str gv = "t = @'a \\";
    lst = lex_gml_line(gv.data, gv.len, 0, &lcls[0]);
    str gv2 = "b' + x; /* c";
    lst2 = lex_gml_line(gv2.data, gv2.len, lst, &lcls[0]);
    bool gv_ok = lcls[0] == LEX_STR && lcls[1] == LEX_STR && lcls[5] == LEX_VAR;
    str gv3 = "d */ /// @param x";
    lst3 = lex_gml_line(gv3.data, gv3.len, lst2, &lcls[0]);
    g_checks++;
    if lst == 0 || !gv_ok || lst2 != 1 || lcls[0] != LEX_COM || lcls[9] != LEX_DECL
        || lcls[16] != LEX_COM || lst3 != 0 {
        print("FAIL gml: a verbatim string and a comment must carry across lines ({} {} {})\n",
            lst, lst2, lst3);
        g_fails++;
    }
    str cxi = "#include <stdio.h>";
    lst = lex_c_line(cxi.data, cxi.len, 0, &lcls[0]);
    str cxf = "static uint32_t f(int n) { return n * 10u; } // x";
    ignore lex_c_line(cxf.data, cxf.len, 0, &lcls[0]);
    g_checks++;
    if lst != 0 || lcls[0] != LEX_DECL || lcls[7] != LEX_TYPE || lcls[16] != LEX_FN
        || lcls[18] != LEX_DECL || lcls[22] != LEX_VAR || lcls[27] != LEX_CTRL
        || lcls[40] != LEX_NUM || lcls[45] != LEX_COM {
        print("FAIL c: keyword/type/function/number/comment classes\n");
        g_fails++;
    }
    ignore lex_c_line(cxi.data, cxi.len, 0, &lcls[0]);
    g_checks++;
    if lcls[0] != LEX_PRE || lcls[7] != LEX_PRE || lcls[9] != LEX_STR || lcls[17] != LEX_STR {
        print("FAIL c: a directive and its include path\n");
        g_fails++;
    }
    str cxb = "int a; /* c";
    lst = lex_c_line(cxb.data, cxb.len, 0, &lcls[0]);
    str cxb2 = " x */ class B { w = L\"hi\"; }";
    lst2 = lex_c_line(cxb2.data, cxb2.len, lst, &lcls[0]);
    g_checks++;
    if lst == 0 || lcls[1] != LEX_COM || lcls[6] != LEX_DECL || lcls[20] != LEX_STR
        || lcls[22] != LEX_STR || lst2 != 0 {
        print("FAIL c: a block comment must carry and close; L\"..\" is a string ({} {})\n", lst, lst2);
        g_fails++;
    }
    str jsn = "{\"key\": 12, \"v\": true}";
    ignore lex_json_line(jsn.data, jsn.len, 0, &lcls[0]);
    g_checks++;
    if lcls[1] != LEX_DECL || lcls[8] != LEX_NUM || lcls[17] != LEX_DECL {
        print("FAIL json: key/number/literal classes\n");
        g_fails++;
    }
    str ya = "key: value  # c";
    ignore lex_yaml_line(ya.data, ya.len, 0, &lcls[0]);
    g_checks++;
    if lcls[0] != LEX_DECL || lcls[12] != LEX_COM {
        print("FAIL yaml: key/comment classes\n");
        g_fails++;
    }
    str yl = "- true";
    ignore lex_yaml_line(yl.data, yl.len, 0, &lcls[0]);
    g_checks++;
    if lcls[0] != LEX_LIST || lcls[2] != LEX_DECL {
        print("FAIL yaml: list marker / literal classes\n");
        g_fails++;
    }

    // file-type icons resolve to a glyph, and .mc keeps its own mark
    u32 ficol = 0;
    g_checks++;
    if theme_file_icon("x.py", &ficol) == 0 || theme_file_icon("x.md", &ficol) == 0
        || theme_file_icon("noext.xyz", &ficol) == 0 {
        print("FAIL every file must map to an icon glyph\n");
        g_fails++;
    }
    g_checks++;
    if theme_file_icon("foo.mc", &ficol) != ICON_MC {
        print("FAIL a .mc file must keep its own icon\n");
        g_fails++;
    }

    // the status bar hides on the toggle; status_h is then 0
    bool sb_was = g_statusbar_on;
    g_statusbar_on = true;
    i32 sb_on = status_h();
    g_statusbar_on = false;
    i32 sb_off = status_h();
    g_statusbar_on = sb_was;
    g_checks++;
    if sb_on <= 0 || sb_off != 0 {
        print("FAIL status bar toggle: on {} off {}\n", sb_on, sb_off);
        g_fails++;
    }

    // a definition answer naming a file that is not on disk must not
    // invent a buffer for it; the editor stays where it was
    ignore ed_open_file("doc/TESTING.md");
    // the other direction: a file that IS there must still be jumped
    // to. path_exists answers false for everything on wasm, so a guard
    // written with it refuses every jump on that target and only this
    // check notices.
    ed_lsp_goto("src/ed.mc", 3, 0);
    g_checks++;
    if !str_equal(str_from(&g_path[0], g_path_len), "src/ed.mc") || cur_line != 3 {
        print("FAIL goto to an existing file did not land: {} line {}\n",
            str_from(&g_path[0], g_path_len), cur_line);
        g_fails++;
    }
    ignore ed_open_file("doc/TESTING.md");
    i32 gt_line = cur_line;
    ed_lsp_goto("no_such_dir/no_such_file.mc", 40, 0);
    g_checks++;
    if cur_line != gt_line
        || !str_equal(str_from(&g_path[0], g_path_len), "doc/TESTING.md") {
        print("FAIL goto to a missing file left {} at line {}\n",
            str_from(&g_path[0], g_path_len), cur_line);
        g_fails++;
    }

    ignore ed_open_file("doc/TESTING.md");
    g_checks++;
    if !g_lex_on || g_lex_lang != LANG_MD {
        print("FAIL .md must select the markdown lexer\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL);

    // --- lsp client: framing, handshake, diagnostics ---
    lsp_on = true;   // pretend the child is up; writes are captured
    tc_lsp_frame("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"positionEncoding\":\"utf-8\",\"textDocumentSync\":{\"change\":2},\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"variable\",\"function\",\"type\",\"property\"],\"tokenModifiers\":[]},\"full\":true}}}}", 10);
    lsp_pump();
    g_checks++;
    if sem_legend_n() != 4 {
        print("FAIL the token legend must be taken from the initialize reply ({} types)\n", sem_legend_n());
        g_fails++;
    }
    g_checks++;
    if !lsp_ready {
        print("FAIL lsp initialize response must set ready\n");
        g_fails++;
    }
    g_checks++;
    if !tc_child_has("\"method\":\"initialized\"") {
        print("FAIL lsp must answer initialize with the initialized notification\n");
        g_fails++;
    }
    // --- incremental sync: a burst goes out as ranges that rebuild the
    // buffer on the server's side; after a buffer switch the whole text
    // goes instead ---
    g_checks++;
    if !lsp_sync_incremental {
        print("FAIL the server granted incremental sync, the client must take it\n");
        g_fails++;
    }
    str stxt = "i32 a = 1;\nvoid f() {\n}\n";
    FileData sfd = FileData{ stxt.data, stxt.len };
    ignore file_write("build/ed_test_sync.mc", sfd);
    ignore ed_open_file("build/ed_test_sync.mc");
    tc_child_len = 0;
    cur_line = 0;
    cur_col = 4;
    app_char('x');
    app_char('y');
    app_char(13);     // a split line
    app_char(8);      // joined back
    app_char(8);
    app_key(K_DOWN, 0);
    app_key(K_END, 0);
    app_char('!');
    app_timer(LSP_SYNC_TIMER);
    u8* sbody = null;
    i64 sbn = 0;
    g_checks++;
    if !tc_last_body("textDocument/didChange", &sbody, &sbn) {
        print("FAIL the burst must go out as one didChange\n");
        g_fails++;
    } else {
        JDoc sd;
        i32 sroot = json_parse(&sd, sbody, sbn);
        i32 schanges = jd_get(&sd, jd_get(&sd, sroot, "params"), "contentChanges");
        g_checks++;
        if schanges < 0 || jd_len(&sd, schanges) < 6 || jd_get(&sd, jd_at(&sd, schanges, 0), "range") < 0 {
            print("FAIL the burst must go out as ranged entries, one per edit\n");
            g_fails++;
        }
        u8* sh = alloc<u8>(stxt.len + 1);
        memcpy(sh, stxt.data, stxt.len);
        i64 shn = stxt.len;
        bool applied = lsp_shadow_apply(&sh, &shn, &sd, schanges);
        i64 bl = tb_len();
        u8* bb = alloc<u8>(bl + 1);
        tb_copy(0, bb, bl);
        g_checks++;
        if !applied || shn != bl || !str_equal(str_from(sh, cast(i32, shn)), str_from(bb, cast(i32, bl))) {
            print("FAIL applying the ranges to the opened text must rebuild the buffer\n  server [{}]\n  buffer [{}]\n",
                str_from(sh, cast(i32, shn)), str_from(bb, cast(i32, bl)));
            g_fails++;
        }
        free(bb);
        json_free(&sd);
        // an undo is an edit the server is owed too: it goes out as
        // ranges that take the shadow back with it
        tc_child_len = 0;
        app_key('Z', MOD_CTRL);
        app_timer(LSP_SYNC_TIMER);
        g_checks++;
        if !tc_last_body("textDocument/didChange", &sbody, &sbn) {
            print("FAIL an undo must push to the server\n");
            g_fails++;
        } else {
            JDoc ud;
            i32 uroot = json_parse(&ud, sbody, sbn);
            i32 uchanges = jd_get(&ud, jd_get(&ud, uroot, "params"), "contentChanges");
            bool uapplied = lsp_shadow_apply(&sh, &shn, &ud, uchanges);
            i64 ul = tb_len();
            u8* ub = alloc<u8>(ul + 1);
            tb_copy(0, ub, ul);
            g_checks++;
            if !uapplied || shn != ul || !str_equal(str_from(sh, cast(i32, shn)), str_from(ub, cast(i32, ul))) {
                print("FAIL the undo's ranges must take the shadow back to the buffer\n  server [{}]\n  buffer [{}]\n",
                    str_from(sh, cast(i32, shn)), str_from(ub, cast(i32, ul)));
                g_fails++;
            }
            free(ub);
            json_free(&ud);
        }
        free(sh);
    }
    // a switch away and back: the record cannot stand for the buffer
    ignore ed_open_file("src/pick.mc");
    ignore ed_open_file("build/ed_test_sync.mc");
    tc_child_len = 0;
    app_char('z');
    app_timer(LSP_SYNC_TIMER);
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/didChange\"") || tc_child_has("\"range\":") {
        print("FAIL after a buffer switch the push must carry the whole text\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL);   // dirty: arms, then discards
    app_key('W', MOD_CTRL);

    // --- semantic tokens: asked for after a push, laid over the lexer
    // for the lines they name, following edits by line ---
    ignore ed_open_file("build/ed_test_sync.mc");
    // the pushes above asked already and got no answer; answer with
    // nothing until none is pending (a push during a request asks
    // once more when the reply lands), so the next push asks afresh
    tc_drain_sem(4);
    tc_child_len = 0;
    app_char(' ');
    app_char(8);
    app_timer(LSP_SYNC_TIMER);
    // the push alone must not fetch tokens: on a big file that is O(file)
    // per keystroke. They wait for the semantic debounce.
    g_checks++;
    if tc_child_has("\"method\":\"textDocument/semanticTokens/full\"") {
        print("FAIL a push alone must not request semantic tokens\n");
        g_fails++;
    }
    app_timer(SEM_TIMER);
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/semanticTokens/full\"") {
        print("FAIL the semantic debounce must ask for the document's tokens\n");
        g_fails++;
    }
    // "void f() {" on line 1: the server calls f a type, which the
    // lexer, seeing the call, would not
    tc_reply(tc_last_id(), ",\"result\":{\"data\":[1,5,1,2,0]}}", 30);
    lsp_pump();
    noinit u8[64] scls;
    i32 sln = line_bytes(1);
    ignore lex_line(g_linebuf, sln, 0, &scls[0]);
    sem_overlay(1, &scls[0], sln);
    g_checks++;
    if !sem_active() || scls[5] != LEX_TYPE || scls[0] != LEX_DECL {
        print("FAIL the token must refine the lexer's class (active {} cls {} {})\n",
            sem_active(), cast(i32, scls[5]), cast(i32, scls[0]));
        g_fails++;
    }
    // a line inserted above moves the token down a line
    cur_line = 0;
    cur_col = 0;
    app_char(13);
    sln = line_bytes(2);
    ignore lex_line(g_linebuf, sln, 0, &scls[0]);
    sem_overlay(2, &scls[0], sln);
    g_checks++;
    if scls[5] != LEX_TYPE {
        print("FAIL a token must follow an insert above it\n");
        g_fails++;
    }
    // an edit on its own line drops it: the lexer's class shows again
    cur_line = 2;
    cur_col = 0;
    app_char(' ');
    sln = line_bytes(2);
    ignore lex_line(g_linebuf, sln, 0, &scls[0]);
    sem_overlay(2, &scls[0], sln);
    g_checks++;
    if scls[6] != LEX_FN {
        print("FAIL an edited line must fall back to the lexer ({})\n", cast(i32, scls[6]));
        g_fails++;
    }

    // --- typing latency shape: a burst of keystrokes, each with a push,
    // must issue no full-document semantic requests (they are O(file) to
    // fetch and parse); one fires only after typing pauses. This is the
    // guard for the large-file typing lag. ---
    tc_drain_sem(6);
    str semreq = "\"method\":\"textDocument/semanticTokens/full\"";
    tc_child_len = 0;
    for i32 bi = 0; bi < 25; bi++ {
        app_char('q');
        app_timer(LSP_SYNC_TIMER);   // a push mid-burst, as debounced typing does
    }
    g_checks++;
    if tc_child_count(semreq) != 0 {
        print("FAIL a typing burst must not fetch semantic tokens ({} requests)\n",
            tc_child_count(semreq));
        g_fails++;
    }
    tc_child_len = 0;
    app_timer(SEM_TIMER);            // typing paused: exactly one fetch
    g_checks++;
    if tc_child_count(semreq) != 1 {
        print("FAIL a pause must fetch semantic tokens exactly once ({})\n",
            tc_child_count(semreq));
        g_fails++;
    }

    // --- a switch back to a file the server already has must still ask
    // for its tokens: the switch drops the list, and only this ask
    // brings it back ---
    tc_drain_sem(6);
    ignore ed_open_file("src/pick.mc");
    tc_drain_sem(6);
    tc_child_len = 0;
    ignore ed_open_file("build/ed_test_sync.mc");   // the server has it already
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/semanticTokens/full\"")
        || !tc_child_has("ed_test_sync.mc") {
        print("FAIL a switch back must ask for the restored buffer's tokens\n");
        g_fails++;
    }

    // --- an ask held back while a reply is out is for the buffer that
    // was switched to, not the one answering: asking again for the
    // answered path left the buffer on screen with no tokens ---
    tc_drain_sem(6);
    app_timer(SEM_TIMER);            // one out for this buffer
    i32 hb_id = lsp_sem_id_pending();
    g_checks++;
    if hb_id == 0 {
        print("FAIL a token request must be in flight to hold the next one back\n");
        g_fails++;
    }
    ignore ed_open_file("src/pick.mc");   // asks for pick.mc, held back
    tc_child_len = 0;
    noinit u8[128] hb;
    i64 hbn = 0;
    hbn = jw_raw(&hb[0], hbn, "{\"jsonrpc\":\"2.0\",\"id\":");
    hbn = jw_int(&hb[0], hbn, cast(i64, hb_id));
    hbn = jw_raw(&hb[0], hbn, ",\"result\":{\"data\":[0,0,1,0,0]}}");
    tc_lsp_frame(str_from(&hb[0], cast(i32, hbn)), 30);
    lsp_pump();
    g_checks++;
    if !tc_child_has("pick.mc") {
        print("FAIL the held-back token ask must name the buffer on screen\n");
        g_fails++;
    }
    ignore ed_open_file("build/ed_test_sync.mc");

    app_key('W', MOD_CTRL);
    app_key('W', MOD_CTRL);

    tc_lsp_frame("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///tmp/x.mc\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":4,\"character\":2},\"end\":{\"line\":4,\"character\":9}},\"severity\":1,\"message\":\"bad \\\"x\\\" here\"},{\"range\":{\"start\":{\"line\":7,\"character\":0},\"end\":{\"line\":7,\"character\":1}},\"severity\":2,\"message\":\"warn\"}]}}", 60);
    lsp_pump();
    g_checks++;
    if lsp_diag_count("/tmp/x.mc") != 2 {
        print("FAIL lsp must store published diagnostics (got {})\n", lsp_diag_count("/tmp/x.mc"));
        g_fails++;
    }
    LspDiag* td = lsp_diag("/tmp/x.mc", 0);
    g_checks++;
    if td == null || td.line != 4 || td.col0 != 2 || td.col1 != 9 || td.severity != 1 {
        print("FAIL lsp diagnostic range/severity\n");
        g_fails++;
    }
    g_checks++;
    if !str_equal(lsp_diag_msg("/tmp/x.mc", 0), "bad \"x\" here") {
        print("FAIL lsp diagnostic message must unescape\n");
        g_fails++;
    }
    // uri round-trip against the drive-letter workspace root: the
    // server percent-encodes the drive colon and carries the file:///
    // root slash, and both have to come back off before the path is
    // workspace-relative again
    tc_lsp_frame("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///C%3A/w/lib/gpu_metal.mc\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":3}},\"severity\":1,\"message\":\"m\"}]}}", 40);
    lsp_pump();
    g_checks++;
    if lsp_diag_count("lib/gpu_metal.mc") != 1 {
        print("FAIL lsp uri must decode %3A and strip the workspace root (got {})\n",
            lsp_diag_count("lib/gpu_metal.mc"));
        g_fails++;
    }
    // an absolute uri outside the workspace keeps its full path
    tc_lsp_frame("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///D%3A/other/z.mc\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"severity\":1,\"message\":\"m\"}]}}", 40);
    lsp_pump();
    g_checks++;
    if lsp_diag_count("D:/other/z.mc") != 1 {
        print("FAIL lsp uri outside the workspace must keep its absolute path\n");
        g_fails++;
    }

    // the server publishes after every change, most often the same set
    // again; only a set that differs repaints
    g_damage_calls = 0;
    tc_lsp_frame("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///D%3A/other/z.mc\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"severity\":1,\"message\":\"m\"}]}}", 40);
    lsp_pump();
    g_checks++;
    if g_damage_calls != 0 {
        print("FAIL an unchanged diagnostic set must not repaint ({} damages)\n", g_damage_calls);
        g_fails++;
    }
    tc_lsp_frame("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///D%3A/other/z.mc\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"severity\":1,\"message\":\"n\"}]}}", 40);
    lsp_pump();
    g_checks++;
    if g_damage_calls == 0 {
        print("FAIL a diagnostic set with a new message must repaint\n");
        g_fails++;
    }

    // a fresh publish replaces the set
    tc_lsp_frame("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///tmp/x.mc\",\"diagnostics\":[]}}", 5);
    lsp_pump();
    g_checks++;
    if lsp_diag_count("/tmp/x.mc") != 0 {
        print("FAIL lsp publish must replace prior diagnostics\n");
        g_fails++;
    }
    // goto definition: request captured, response navigates
    ignore ed_open_file("src/pick.mc");
    app_key(K_DOWN, 0);
    // an edit the server has not seen yet: the question is asked about
    // a position in the live text, so the push has to come first. The
    // undo leaves the text as it was and the edit still unpushed.
    app_char('x');
    app_key('Z', MOD_CTRL);
    tc_child_len = 0;   // isolate the capture from the open's traffic
    ed_goto_def();
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/definition\"") {
        print("FAIL goto-def must send a definition request\n");
        g_fails++;
    }
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/didChange\"") {
        print("FAIL goto-def must push the live text first\n");
        g_fails++;
    }
    // outgoing uris are absolute and three-slash, with '/' separators
    g_checks++;
    if !tc_child_has("\"uri\":\"file:///C:/w/src/pick.mc\"") {
        print("FAIL outgoing uri must be file:///<root>/<path>\n");
        g_fails++;
    }
    tc_reply(tc_last_id(), ",\"result\":[{\"uri\":\"file://CLAUDE.md\",\"range\":{\"start\":{\"line\":3,\"character\":2},\"end\":{\"line\":3,\"character\":6}}}]}", 30);
    lsp_pump();
    g_checks++;
    if !str_equal(str_from(&g_path[0], g_path_len), "CLAUDE.md")
        || cur_line != 3 || cur_col != 2 {
        print("FAIL definition response must open the target at the range ({} {}:{})\n",
            str_from(&g_path[0], g_path_len), cur_line, cur_col);
        g_fails++;
    }
    // the history modifier + left returns from the jump; + right redoes
    app_key(NAV_BACK_KEY, NAV_BACK_MODS);
    g_checks++;
    if !str_equal(str_from(&g_path[0], g_path_len), "src/pick.mc") || cur_line != 1 {
        print("FAIL nav back must return to the departure point ({} {})\n",
            str_from(&g_path[0], g_path_len), cur_line);
        g_fails++;
    }
    app_key(NAV_FWD_KEY, NAV_FWD_MODS);
    g_checks++;
    if !str_equal(str_from(&g_path[0], g_path_len), "CLAUDE.md") || cur_line != 3 {
        print("FAIL nav forward must redo the jump\n");
        g_fails++;
    }

    // two definitions means the file is in two programs, each with its
    // own; the editor lists them instead of picking one silently
    search_close_view();
    ignore ed_open_file("src/pick.mc");
    app_key(K_F12, 0);
    tc_reply(tc_last_id(), ",\"result\":[{\"uri\":\"file://CLAUDE.md\",\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":4}}},{\"uri\":\"file://doc/TESTING.md\",\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":4}}}]}", 30);
    lsp_pump();
    g_checks++;
    if !search_on || search_hit_count() != 2
        || !str_equal(str_from(&g_path[0], g_path_len), "src/pick.mc") {
        print("FAIL two definitions must be listed, not jumped to ({} hits {} on {})\n",
            str_from(&g_path[0], g_path_len), search_hit_count(), cast(i32, search_on));
        g_fails++;
    }
    search_close_view();
    // The concrete keys, per platform. The constants above are what the
    // code uses too, so those checks would follow a swap in them; these
    // would not. The list above landed nowhere, so a real jump seeds the
    // history first: back must return here, forward must redo it.
    ed_lsp_goto("CLAUDE.md", 3, 0);
    when !os(macos) {
        app_key(K_LEFT, MOD_ALT);
        g_checks++;
        if !str_equal(str_from(&g_path[0], g_path_len), "src/pick.mc") {
            print("FAIL windows/linux: alt+left must walk the history back\n");
            g_fails++;
        }
        app_key(K_RIGHT, MOD_ALT);
        g_checks++;
        if !str_equal(str_from(&g_path[0], g_path_len), "CLAUDE.md") {
            print("FAIL windows/linux: alt+right must walk the history forward\n");
            g_fails++;
        }
    }
    when os(macos) {
        app_key('-', MOD_SUPER);            // the Ctrl key on macOS
        g_checks++;
        if !str_equal(str_from(&g_path[0], g_path_len), "src/pick.mc") {
            print("FAIL macos: ctrl+- must walk the history back\n");
            g_fails++;
        }
        app_key('-', MOD_SUPER | MOD_SHIFT);
        g_checks++;
        if !str_equal(str_from(&g_path[0], g_path_len), "CLAUDE.md") {
            print("FAIL macos: ctrl+shift+- must walk the history forward\n");
            g_fails++;
        }
    }
    app_key('W', MOD_CTRL);   // close CLAUDE.md, back on the .mc buffer
    // An out-of-range character offset from the server must not put
    // the caret before the line start; cur_abs() feeds the edit paths
    // from there. Markdown buffers never ask, so this needs the .mc one.
    ed_goto_def();
    tc_reply(tc_last_id(), ",\"result\":[{\"uri\":\"file://src/find.mc\",\"range\":{\"start\":{\"line\":2,\"character\":-1},\"end\":{\"line\":2,\"character\":0}}}]}", 40);
    lsp_pump();
    g_checks++;
    if !str_equal(str_from(&g_path[0], g_path_len), "src/find.mc") || cur_col != 0 {
        print("FAIL negative lsp character must clamp to 0 ({} col {})\n",
            str_from(&g_path[0], g_path_len), cur_col);
        g_fails++;
    }
    // A control byte becomes six characters (\u00xx) on the way out,
    // so the buffer the client sizes for a didChange has to allow for
    // that. Two per byte overruns it and corrupts the heap; a document
    // picks these up from a form feed or from pasted binary.
    noinit u8[8] ctl;
    for i32 i = 0; i < 8; i++ { ctl[i] = cast(u8, i + 1); }
    for i32 i = 0; i < 400; i++ { tb_insert(0, &ctl[0], 8); }
    // tb_insert bypasses the one write path, so mark the buffer stale
    // the way an edit would; otherwise no didChange is sent at all
    app_key(K_HOME, MOD_CTRL);
    app_char('x');
    app_char(8);
    tc_child_len = 0;
    ed_goto_def();
    g_checks++;
    if !tc_child_has("\\u0001") {
        print("FAIL didChange must escape control bytes\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL);   // close src/find.mc, dirty: arms first
    app_key('W', MOD_CTRL);

    // --- an edit debounces onto a didChange ---
    // The push is on a timer, so nothing goes out until it fires and a
    // burst of typing coalesces into one push. This has to sit inside
    // the section where the server is live: the hover checks below
    // clear lsp_ready on purpose.
    ignore ed_open_file("src/find.mc");
    ed_goto_def();               // clears the stale flag for this buffer
    tc_child_len = 0;
    i64 sync_len = tb_len();
    app_char('z');
    app_char('z');
    g_checks++;
    if tb_len() != sync_len + 2 {
        print("FAIL the edit did not reach the buffer\n");
        g_fails++;
    }
    g_checks++;
    if tc_child_has("didChange") {
        print("FAIL an edit must not push before the timer fires\n");
        g_fails++;
    }
    app_timer(LSP_SYNC_TIMER);
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/didChange\"") {
        print("FAIL the sync timer must push the edited buffer\n");
        g_fails++;
    }
    // one shot: firing again with nothing new sends nothing new
    tc_child_len = 0;
    app_timer(LSP_SYNC_TIMER);
    g_checks++;
    if tc_child_has("didChange") {
        print("FAIL an unchanged buffer must not push again\n");
        g_fails++;
    }

    // --- closing a file tells the server, reopening re-announces it ---
    // The opened set was append-only, so a reopen skipped didOpen and
    // later ranged edits desynced against the server's stale copy.
    ignore ed_open_file("src/lexer.mc");
    ed_goto_def();            // clears the stale flag; a didOpen has gone out
    tc_child_len = 0;
    app_key('W', MOD_CTRL);   // a clean buffer closes at once
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/didClose\"") {
        print("FAIL closing a file must send didClose\n");
        g_fails++;
    }
    tc_child_len = 0;
    ignore ed_open_file("src/lexer.mc");
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/didOpen\"") {
        print("FAIL reopening a closed file must send didOpen again\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL);   // close it again, clean

    app_key('W', MOD_CTRL);   // dirty: arms, then discards
    app_key('W', MOD_CTRL);

    // --- ctrl+t: workspace symbols ---
    tree_focus = false;
    search_focus = false;
    ignore ed_open_file("src/pick.mc");
    tc_child_len = 0;
    app_key('T', MOD_CTRL);
    g_checks++;
    if !sym_on || !tc_child_has("\"method\":\"workspace/symbol\"") {
        print("FAIL ctrl+t must open the symbol search and ask the server\n");
        g_fails++;
    }
    tc_child_len = 0;
    app_char('h');
    app_char('e');
    g_checks++;
    if !tc_child_has("\"query\":\"he\"") {
        print("FAIL each keystroke must ask again with the query so far\n");
        g_fails++;
    }
    noinit u8[768] sr;
    i64 sn = 0;
    sn = jw_raw(&sr[0], sn, "{\"jsonrpc\":\"2.0\",\"id\":");
    sn = jw_int(&sr[0], sn, cast(i64, tc_last_id()));
    sn = jw_raw(&sr[0], sn, ",\"result\":[");
    sn = jw_raw(&sr[0], sn, "{\"name\":\"helper\",\"kind\":12,\"location\":{\"uri\":\"file:///C%3A/w/src/pick.mc\",\"range\":{\"start\":{\"line\":5,\"character\":4},\"end\":{\"line\":5,\"character\":10}}}},");
    sn = jw_raw(&sr[0], sn, "{\"name\":\"hello\",\"kind\":13,\"location\":{\"uri\":\"file:///C%3A/w/src/find.mc\",\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":5}}}}");
    sn = jw_raw(&sr[0], sn, "]}");
    tc_lsp_frame(str_from(&sr[0], cast(i32, sn)), 40);
    lsp_pump();
    g_checks++;
    if sym_hit_count() != 2 || !str_equal(sym_hit_path(1), "src/find.mc")
        || sym_hit_line(1) != 2 {
        print("FAIL the reply must fill the list: {} hits, second {}:{}\n",
            sym_hit_count(), sym_hit_path(1), sym_hit_line(1));
        g_fails++;
    }
    app_key(K_DOWN, 0);
    app_char(13);
    g_checks++;
    if sym_on || !str_equal(str_from(&g_path[0], g_path_len), "src/find.mc")
        || cur_line != 2 {
        print("FAIL enter must open the chosen symbol: on={} {} line {}\n",
            cast(i32, sym_on), str_from(&g_path[0], g_path_len), cur_line);
        g_fails++;
    }
    app_key('T', MOD_CTRL);
    app_key(K_ESCAPE, 0);
    g_checks++;
    if sym_on {
        print("FAIL escape must close the symbol search\n");
        g_fails++;
    }
    // Enter while the reply is still out waits for it, then takes the
    // top hit of what was typed, not of the shorter query on screen
    app_key('T', MOD_CTRL);
    app_char('z');
    app_char(13);
    g_checks++;
    if !sym_on || !str_equal(str_from(&g_path[0], g_path_len), "src/find.mc") {
        print("FAIL enter before the reply must wait for it: on={} {}\n",
            cast(i32, sym_on), str_from(&g_path[0], g_path_len));
        g_fails++;
    }
    tc_reply(tc_last_id(), ",\"result\":[{\"name\":\"zap\",\"kind\":12,\"location\":{\"uri\":\"file:///C%3A/w/src/tree.mc\",\"range\":{\"start\":{\"line\":4,\"character\":0},\"end\":{\"line\":4,\"character\":3}}}}]}", 40);
    lsp_pump();
    g_checks++;
    if sym_on || !str_equal(str_from(&g_path[0], g_path_len), "src/tree.mc")
        || cur_line != 4 {
        print("FAIL the deferred enter must take the reply's top hit: on={} {} line {}\n",
            cast(i32, sym_on), str_from(&g_path[0], g_path_len), cur_line);
        g_fails++;
    }

    // --- completion ranks by the server's sortText, builtins first ---
    // The server labels scope in sortText (000 innermost, 100 this file,
    // 200 elsewhere) but returns the items unordered; the popup sorts.
    ignore ed_open_file("build.mc");
    app_key(K_END, MOD_CTRL);
    app_char(13);
    tc_child_len = 0;
    app_char('z');
    app_char('q');
    app_timer(CMP_TIMER);
    tc_reply(tc_last_id(), ",\"result\":[{\"label\":\"zqfar\",\"sortText\":\"200_zqfar\"},{\"label\":\"zqlocal\",\"sortText\":\"000_zqlocal\"},{\"label\":\"zqfile\",\"sortText\":\"100_zqfile\"},{\"label\":\"zqnone\"}]}", 40);
    lsp_pump();
    g_checks++;
    if !cmp_on || cmp_hit_count() != 4 || !str_equal(cmp_hit_label(0), "zqlocal")
        || !str_equal(cmp_hit_label(1), "zqfile") || !str_equal(cmp_hit_label(2), "zqfar")
        || !str_equal(cmp_hit_label(3), "zqnone") {
        print("FAIL completion must rank by sortText: {} hits [{} {} {} {}]\n",
            cmp_hit_count(), cmp_hit_label(0), cmp_hit_label(1), cmp_hit_label(2),
            cmp_hit_label(3));
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    // typing "i" offers the builtin types first, the most written first,
    // and the server's own items after all of them
    app_char(' ');
    app_char('i');
    app_timer(CMP_TIMER);
    tc_reply(tc_last_id(), ",\"result\":[{\"label\":\"ifoo\",\"sortText\":\"000_ifoo\"}]}", 40);
    lsp_pump();
    g_checks++;
    if !cmp_on || !str_equal(cmp_hit_label(0), "i32") || !str_equal(cmp_hit_label(1), "i64")
        || !str_equal(cmp_hit_label(2), "i16") || !str_equal(cmp_hit_label(3), "i8")
        || !str_equal(cmp_hit_label(cmp_hit_count() - 1), "ifoo") {
        print("FAIL typing i must offer i32, i64, i16, i8 first and the server's items last: [{} {} {} {} .. {}]\n",
            cmp_hit_label(0), cmp_hit_label(1), cmp_hit_label(2), cmp_hit_label(3),
            cmp_hit_label(cmp_hit_count() - 1));
        g_fails++;
    }
    // narrowing to "i3" keeps i32 and i32x8 and drops the rest
    app_char('3');
    g_checks++;
    if !cmp_on || cmp_hit_count() != 2 || !str_equal(cmp_hit_label(0), "i32") {
        print("FAIL narrowing to i3 must leave i32 first of {}\n", cmp_hit_count());
        g_fails++;
    }
    app_key(K_ESCAPE, 0);

    // Ctrl+Space asks for a completion at once, without the settle timer
    app_key(K_END, MOD_CTRL);
    app_char(13);
    app_char('z');
    tc_child_len = 0;
    app_key(' ', MOD_CTRL);
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/completion\"") {
        print("FAIL ctrl+space must request a completion immediately\n");
        g_fails++;
    }
    app_key(K_ESCAPE, 0);

    // typing '(' after a function name asks for its signature, and each
    // ',' asks again so the active argument moves on. Ctrl+Space inside
    // the call asks once more.
    app_key(K_END, MOD_CTRL);
    app_char(13);
    type_text("write");
    tc_child_len = 0;
    app_char('(');
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/signatureHelp\"") {
        print("FAIL '(' after a call must ask for its signature\n");
        g_fails++;
    }
    tc_child_len = 0;
    app_char('a');
    app_char(',');
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/signatureHelp\"") {
        print("FAIL ',' must ask again, for the next argument\n");
        g_fails++;
    }
    tc_child_len = 0;
    app_key(' ', MOD_CTRL);
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/signatureHelp\"") {
        print("FAIL ctrl+space inside a call must ask for the signature\n");
        g_fails++;
    }
    // the reply marks the argument being typed, and the panel opens
    ed_sig_show("void write(i32 fd, u8* p)", 11, 18);
    g_checks++;
    if !sig_on || sig_p0 != 11 || sig_p1 != 18 {
        print("FAIL the active argument must be marked (on {} span {}..{})\n",
            cast(i32, sig_on), sig_p0, sig_p1);
        g_fails++;
    }
    // Escape dismisses it, and a late reply does not bring it back
    app_key(K_ESCAPE, 0);
    ed_sig_show("void write(i32 fd, u8* p)", 11, 18);
    g_checks++;
    if sig_on {
        print("FAIL escape must dismiss signature help\n");
        g_fails++;
    }
    app_key(' ', MOD_CTRL);
    ed_sig_show("void write(i32 fd, u8* p)", 11, 18);
    // moving the caret out of the call dismisses it
    g_checks++;
    if !sig_on {
        print("FAIL ctrl+space must reopen signature help after escape\n");
        g_fails++;
    }
    app_key(K_UP, 0);
    g_checks++;
    if sig_on {
        print("FAIL signature help must dismiss when the caret leaves the call\n");
        g_fails++;
    }


    // typing an identifier inside a comment must not ask for or open a
    // completion: the caret is in a // line, not code
    app_key(K_END, MOD_CTRL);
    app_char(13);
    app_char('/');
    app_char('/');
    app_char(' ');
    tc_child_len = 0;
    type_text("file_");
    app_timer(CMP_TIMER);
    lsp_pump();
    g_checks++;
    if cmp_on || tc_child_has("\"method\":\"textDocument/completion\"") {
        print("FAIL a comment must suppress completion (on={} asked={})\n",
            cast(i32, cmp_on),
            cast(i32, tc_child_has("\"method\":\"textDocument/completion\"")));
        g_fails++;
    }

    app_key('W', MOD_CTRL);   // dirty: arms, then discards
    app_key('W', MOD_CTRL);

    // --- double click selects the word; ctrl+shift+f takes the selection ---
    ignore ed_open_file("build.mc");
    app_key(K_END, MOD_CTRL);
    app_char(13);
    type_text("alpha beta");
    tree_on = false;
    i32 dx = gutter_w() + 7 * font_cell_w + 1;      // inside "beta"
    i32 dy = doc_top() + (cur_line - top_line) * font_line_h - scroll_off + font_line_h / 2;
    g_clock_step = 100000;                            // presses 100 ms apart
    app_mouse(dx, dy, 0, true, 0);
    app_mouse(dx, dy, 0, false, 0);
    app_mouse(dx, dy, 0, true, 0);
    g_clock_step = 500000;
    i64 wa = 0;
    i64 wb = 0;
    g_checks++;
    if !ed_sel_range(&wa, &wb) || wb - wa != 4 {
        print("FAIL a double click must select the word: {}..{}\n", wa, wb);
        g_fails++;
    } else {
        noinit u8[8] wbuf;
        tb_copy(wa, &wbuf[0], 4);
        g_checks++;
        if !str_equal(str_from(&wbuf[0], 4), "beta") {
            print("FAIL the double-clicked word must be the one under the pointer: [{}]\n",
                str_from(&wbuf[0], 4));
            g_fails++;
        }
    }
    app_key('F', MOD_CTRL | MOD_SHIFT);
    g_checks++;
    if !search_on || sq_len != 4 || !str_equal(str_from(&sq[0], sq_len), "beta") {
        print("FAIL ctrl+shift+f must take the selection as the query: [{}]\n",
            str_from(&sq[0], sq_len));
        g_fails++;
    }
    search_close_view();
    tree_on = false;   // the search view opened the sidebar; dx assumes none
    ignore plat_time_us();   // the earlier run is over: half a second passes
    // a third press in the run selects the line (the last one here, so
    // to its end), and a fourth starts over with a plain caret
    g_clock_step = 100000;
    app_mouse(dx, dy, 0, true, 0);
    app_mouse(dx, dy, 0, false, 0);
    app_mouse(dx, dy, 0, true, 0);
    app_mouse(dx, dy, 0, false, 0);
    app_mouse(dx, dy, 0, true, 0);
    g_checks++;
    if !ed_sel_range(&wa, &wb) || wa != tb_line_start(cur_line) || wb - wa != 10 {
        print("FAIL a triple click must select the line: {}..{}\n", wa, wb);
        g_fails++;
    }
    app_mouse(dx, dy, 0, false, 0);
    app_mouse(dx, dy, 0, true, 0);
    app_mouse(dx, dy, 0, false, 0);
    g_checks++;
    if ed_sel_range(&wa, &wb) && wb != wa {
        print("FAIL a fourth press must start over: {}..{}\n", wa, wb);
        g_fails++;
    }
    // on a line above the last, the line's break goes with it and the
    // caret lands on the next line
    app_key(K_UP, 0);
    i32 ly = doc_top() + (cur_line - top_line) * font_line_h - scroll_off + font_line_h / 2;
    i32 above = cur_line;
    g_clock_step = 500000;
    app_mouse(dx, ly, 0, true, 0);
    g_clock_step = 100000;
    app_mouse(dx, ly, 0, false, 0);
    app_mouse(dx, ly, 0, true, 0);
    app_mouse(dx, ly, 0, false, 0);
    app_mouse(dx, ly, 0, true, 0);
    app_mouse(dx, ly, 0, false, 0);
    g_clock_step = 500000;
    g_checks++;
    if !ed_sel_range(&wa, &wb) || wa != tb_line_start(above)
        || wb != tb_line_start(above + 1) || cur_line != above + 1 || cur_col != 0 {
        print("FAIL a triple click above the last line must take its break ({}..{}, caret {}:{})\n",
            wa, wb, cur_line, cur_col);
        g_fails++;
    }
    search_settle();
    search_close_view();
    tree_on = false;
    app_key('W', MOD_CTRL);   // dirty: arms, then discards
    app_key('W', MOD_CTRL);

    // --- references land in the results view ---
    tree_focus = false;
    search_focus = false;
    // a scratch buffer with a symbol the caret can sit inside, rather
    // than depending on what happens to be at a line of real source
    ignore ed_open_file("build.mc");
    app_key(K_END, MOD_CTRL);
    app_char(13);
    type_text("symbolname");
    tc_child_len = 0;
    app_key(K_F12, MOD_SHIFT);
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/references\"")
        || !tc_child_has("\"includeDeclaration\":true") {
        print("FAIL shift+f12 must ask for references\n");
        g_fails++;
    }
    noinit u8[768] rr;
    i64 rn = 0;
    rn = jw_raw(&rr[0], rn, "{\"jsonrpc\":\"2.0\",\"id\":");
    rn = jw_int(&rr[0], rn, cast(i64, tc_last_id()));
    // two files, deliberately out of order, to check the grouping
    rn = jw_raw(&rr[0], rn, ",\"result\":[");
    rn = jw_raw(&rr[0], rn, "{\"uri\":\"file:///C%3A/w/src/pick.mc\",\"range\":{\"start\":{\"line\":5,\"character\":0},\"end\":{\"line\":5,\"character\":3}}},");
    rn = jw_raw(&rr[0], rn, "{\"uri\":\"file:///C%3A/w/src/find.mc\",\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":3}}},");
    rn = jw_raw(&rr[0], rn, "{\"uri\":\"file:///C%3A/w/src/pick.mc\",\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":3}}}");
    rn = jw_raw(&rr[0], rn, "]}");
    tc_lsp_frame(str_from(&rr[0], cast(i32, rn)), 40);
    lsp_pump();
    g_checks++;
    if search_hit_count() != 3 || !search_on {
        print("FAIL references must fill the results view (got {} on {})\n",
            search_hit_count(), cast(i32, search_on));
        g_fails++;
    }
    // sorted by path then line, so a file's hits are one group
    g_checks++;
    if !str_equal(search_hit_path(0), "src/find.mc")
        || !str_equal(search_hit_path(1), "src/pick.mc")
        || !str_equal(search_hit_path(2), "src/pick.mc")
        || search_hit_line(1) != 1 || search_hit_line(2) != 5 {
        print("FAIL references must group by file and sort by line ({} {} {})\n",
            search_hit_path(0), search_hit_path(1), search_hit_path(2));
        g_fails++;
    }
    // previews come from the files themselves
    g_checks++;
    if search_hit_preview(0).len == 0 {
        print("FAIL a reference row must carry a preview\n");
        g_fails++;
    }
    // an empty reply says so rather than opening an empty panel
    search_close_view();
    tc_child_len = 0;
    app_key(K_F12, MOD_SHIFT);
    tc_reply(tc_last_id(), ",\"result\":[]}", 20);
    lsp_pump();
    g_checks++;
    if search_on {
        print("FAIL an empty reference reply must not open the view\n");
        g_fails++;
    }
    search_close_view();
    tree_on = false;          // the view opened the sidebar; the
                              // geometry checks below assume none
    app_key('W', MOD_CTRL);   // dirty: arms, then discards
    app_key('W', MOD_CTRL);

    // --- completion: type, ask, narrow, commit ---
    tree_focus = false;
    search_focus = false;
    // a scratch buffer of its own, so the checks after this one keep
    // whatever was open before
    ignore ed_open_file("build.mc");
    app_key(K_END, MOD_CTRL);
    app_char(13);                // a fresh last line to type on
    app_char('z');
    tc_child_len = 0;
    app_timer(CMP_TIMER);
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/completion\"") {
        print("FAIL typing an identifier must ask for completion\n");
        g_fails++;
    }
    tc_reply(tc_last_id(), ",\"result\":[{\"label\":\"zebra\",\"detail\":\"i32\"},{\"label\":\"zither\"},{\"label\":\"other\"}]}", 25);
    lsp_pump();
    g_checks++;
    if !cmp_on {
        print("FAIL a completion reply must open the popup\n");
        g_fails++;
    }
    // "z" keeps the two z items and drops the third
    g_checks++;
    if cmp_hit_count() != 2 {
        print("FAIL prefix must narrow the list (got {})\n", cmp_hit_count());
        g_fails++;
    }
    // typing on narrows further without asking again
    tc_child_len = 0;
    app_char('i');
    g_checks++;
    if cmp_hit_count() != 1 || tc_child_has("textDocument/completion") {
        print("FAIL typing must narrow locally, not re-ask ({})\n",
            cmp_hit_count());
        g_fails++;
    }
    // enter commits the selection over the typed prefix
    app_char(13);
    g_checks++;
    if cmp_on {
        print("FAIL committing must close the popup\n");
        g_fails++;
    }
    i32 cl = line_bytes(cur_line);
    g_checks++;
    if !str_equal(str_from(g_linebuf, cl), "zither") {
        print("FAIL commit must replace the typed prefix: [{}]\n",
            str_from(g_linebuf, cl));
        g_fails++;
    }
    // escape closes without changing the buffer
    app_char('z');
    app_timer(CMP_TIMER);
    tc_reply(tc_last_id(), ",\"result\":[{\"label\":\"zebra\"}]}", 20);
    lsp_pump();
    app_key(K_ESCAPE, 0);
    g_checks++;
    cl = line_bytes(cur_line);
    if cmp_on || !str_equal(str_from(g_linebuf, cl), "zitherz") {
        print("FAIL escape must close and leave the text: [{}]\n",
            str_from(g_linebuf, cl));
        g_fails++;
    }
    app_key('W', MOD_CTRL);   // dirty: arms, then discards
    app_key('W', MOD_CTRL);

    // --- hover: rest on a word, the reply becomes a popup ---
    // the checks below this one read line 0 of the picker source, so
    // say so rather than depending on what the last block left open
    ignore ed_open_file("src/pick.mc");
    tree_on = false;
    tree_focus = false;
    search_focus = false;
    i32 hvx = gutter_w() + 3 * font_cell_w + 1;
    app_hover(hvx, doc_top() + font_line_h / 2, 0);
    tc_child_len = 0;
    app_timer(HOVER_TIMER);
    g_checks++;
    if !tc_child_has("\"method\":\"textDocument/hover\"") {
        print("FAIL resting on a word must ask for hover\n");
        g_fails++;
    }
    // markdown with a fenced signature: the fence lines are dropped,
    // since nothing here would render them
    tc_reply(tc_last_id(), ",\"result\":{\"contents\":{\"kind\":\"markdown\",\"value\":\"```minc\ni32 thing()\n```\nDoes a thing.\"}}}", 30);
    lsp_pump();
    g_checks++;
    if !hover_pop_on {
        print("FAIL a hover reply must open the popup\n");
        g_fails++;
    }
    g_checks++;
    if !str_equal(str_from(&hover_pop_text[0], hover_pop_len),
        "i32 thing()\nDoes a thing.") {
        print("FAIL hover text: [{}]\n",
            str_from(&hover_pop_text[0], hover_pop_len));
        g_fails++;
    }
    // the fenced line is code, the prose after it is not
    g_checks++;
    if hover_pop_code[0] != 1 || hover_pop_code[1] != 0 {
        print("FAIL fenced hover lines must be flagged as code ({} {})\n",
            cast(i32, hover_pop_code[0]), cast(i32, hover_pop_code[1]));
        g_fails++;
    }
    // any other input dismisses it
    app_key(K_ESCAPE, 0);
    g_checks++;
    if hover_pop_on {
        print("FAIL a key must dismiss the hover popup\n");
        g_fails++;
    }
    // an empty reply leaves it closed rather than opening a blank panel
    app_hover(hvx, doc_top() + font_line_h / 2, 0);
    tc_child_len = 0;
    app_timer(HOVER_TIMER);
    tc_reply(tc_last_id(), ",\"result\":null}", 20);
    lsp_pump();
    g_checks++;
    if hover_pop_on {
        print("FAIL an empty hover reply must leave the popup closed\n");
        g_fails++;
    }
    ed_hover_hide();

    // --- hover on a diagnostic: its message opens the panel with no
    // server reply, over a word or not, and a reply about the word
    // joins it below ---
    str dtxt = "i32 careful(i32 x) {\n    return x;\n}\n";
    FileData dfd = FileData{ dtxt.data, dtxt.len };
    ignore file_write("build/ed_test_diag.mc", dfd);
    ignore ed_open_file("build/ed_test_diag.mc");
    tree_on = false;
    tree_focus = false;
    search_focus = false;
    tc_lsp_frame("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///C%3A/w/build/ed_test_diag.mc\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":0,\"character\":2},\"end\":{\"line\":0,\"character\":11}},\"severity\":1,\"message\":\"unused\"}]}}", 40);
    lsp_pump();
    // column 3 is the space after i32: in the range, not a word
    app_hover(gutter_w() + 3 * font_cell_w + 1, doc_top() + font_line_h / 2, 0);
    tc_child_len = 0;
    app_timer(HOVER_TIMER);
    g_checks++;
    if !hover_pop_on || !str_equal(str_from(&hover_pop_text[0], hover_pop_len), "unused")
        || tc_child_has("\"method\":\"textDocument/hover\"") {
        print("FAIL resting on a diagnostic must show its message at once, with no request (on {} text [{}])\n",
            hover_pop_on, str_from(&hover_pop_text[0], hover_pop_len));
        g_fails++;
    }
    // column 6 is inside `careful`: the message shows, the word is asked
    // about, and the answer joins below a blank line
    app_hover(gutter_w() + 6 * font_cell_w + 1, doc_top() + font_line_h / 2, 0);
    tc_child_len = 0;
    app_timer(HOVER_TIMER);
    g_checks++;
    if !hover_pop_on || !str_equal(str_from(&hover_pop_text[0], hover_pop_len), "unused")
        || !tc_child_has("\"method\":\"textDocument/hover\"") {
        print("FAIL a diagnostic over a word must show at once and ask about the word\n");
        g_fails++;
    }
    tc_reply(tc_last_id(), ",\"result\":{\"contents\":{\"kind\":\"markdown\",\"value\":\"```minc\\ni32 careful(i32 x)\\n```\"}}}", 30);
    lsp_pump();
    g_checks++;
    if !str_equal(str_from(&hover_pop_text[0], hover_pop_len), "unused\n\ni32 careful(i32 x)") {
        print("FAIL the reply must join below the diagnostic: [{}]\n",
            str_from(&hover_pop_text[0], hover_pop_len));
        g_fails++;
    }
    // the code flag follows the reply to its place below the message
    g_checks++;
    if hover_pop_code[0] != 0 || hover_pop_code[1] != 0 || hover_pop_code[2] != 1 {
        print("FAIL the code flag must land on the reply line ({} {} {})\n",
            cast(i32, hover_pop_code[0]), cast(i32, hover_pop_code[1]), cast(i32, hover_pop_code[2]));
        g_fails++;
    }
    // Ctrl+K D: the underline goes from the text and comes back; the
    // diagnostic itself stays
    app_key(K_ESCAPE, 0);
    app_key('K', MOD_CTRL);
    app_key('D', 0);
    app_char('d');
    bool sq_off = !g_squiggles && tb_len() > 0 && ed_diag_count() == 1;
    app_key('K', MOD_CTRL);
    app_key('D', 0);
    app_char('d');
    g_checks++;
    if !sq_off || !g_squiggles {
        print("FAIL ctrl+k d must turn the problem underlines off and on, the diagnostic kept\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL);
    ignore ed_open_file("src/pick.mc");   // what the next check reads

    // cmd+hover: a comment word is never a link (class filter)
    i32 hx = gutter_w() + 3 * font_cell_w + 1;
    app_hover(hx, doc_top() + font_line_h / 2, MOD_CTRL);
    g_checks++;
    if hover_link_on {
        print("FAIL a comment word must not be a link\n");
        g_fails++;
    }
    check_lsp_c();
    app_key('W', MOD_CTRL);   // close src/pick.mc
    lsp_on = false;
    lsp_ready = false;
    // a known empty .mc buffer to type into, rather than whichever
    // buffer the blocks above happened to leave under pick.mc
    ignore ed_open_file("build/ed_test_link.mc");
    // identifiers link (immediately, with no server), keywords not
    for i32 tc = 0; tc < 14; tc++ {
        str tw = "one return zap";
        app_char(cast(u32, tw.data[tc]));
    }
    i32 gx = gutter_w();
    app_hover(gx + 1 * font_cell_w + 1, doc_top() + font_line_h / 2, MOD_CTRL);
    g_checks++;
    if !hover_link_on || !hover_link_ok || hover_link_c0 != 0 || hover_link_c1 != 3 {
        print("FAIL identifier must link without a server (on={} ok={} {}..{})\n",
            hover_link_on, hover_link_ok, hover_link_c0, hover_link_c1);
        g_fails++;
    }
    app_hover(gx + 6 * font_cell_w + 1, doc_top() + font_line_h / 2, MOD_CTRL);
    g_checks++;
    if hover_link_on {
        print("FAIL a keyword must not be a link\n");
        g_fails++;
    }
    app_hover(gx + 12 * font_cell_w + 1, doc_top() + font_line_h / 2, MOD_CTRL);
    g_checks++;
    if !hover_link_on || hover_link_c0 != 11 || hover_link_c1 != 14 {
        print("FAIL identifier after keyword must link ({}..{})\n",
            hover_link_c0, hover_link_c1);
        g_fails++;
    }
    app_hover(gx + 12 * font_cell_w + 1, doc_top() + font_line_h / 2, 0);
    g_checks++;
    if hover_link_on {
        print("FAIL releasing the modifier must clear the hover link\n");
        g_fails++;
    }
    // without the modifier, moving from word to word shows nothing new
    // and must not repaint
    g_damage_calls = 0;
    app_hover(gx + 1 * font_cell_w + 1, doc_top() + font_line_h / 2, 0);
    app_hover(gx + 6 * font_cell_w + 1, doc_top() + font_line_h / 2, 0);
    app_hover(gx + 12 * font_cell_w + 1, doc_top() + font_line_h / 2, 0);
    g_checks++;
    if g_damage_calls != 0 {
        print("FAIL a pointer crossing words without the modifier must not repaint ({} damages)\n",
            g_damage_calls);
        g_fails++;
    }
    for i32 tc = 0; tc < 14; tc++ { app_char(8); }   // clean the buffer

    // --- narrow window: panes must stay positive and keep tiling ---
    // The sidebar is wider than this window at its default width, and
    // the editor area cannot hold three minimum-width panes.
    tree_on = true;
    app_resize(240, 800);
    app_key(92, MOD_CTRL);
    app_key(92, MOD_CTRL);
    g_checks++;
    if !panes_tile(240) {
        print("FAIL narrow window must keep panes positive and tiling\n");
        g_fails++;
    }
    // drag the first pane border past the left edge: the minimum-width
    // clamps disagree at this size and must not invert the divider
    i32 dx02 = 0;
    i32 dx12 = 0;
    ed_pane_rect(1, &dx02, &dx12);
    app_mouse(dx02, font_line_h, 0, true, 0);
    app_mouse_move(0, font_line_h);
    g_checks++;
    if !panes_tile(240) {
        print("FAIL divider drag must not invert a pane\n");
        g_fails++;
    }
    app_mouse(0, font_line_h, 0, false, 0);
    app_resize(1200, 800);

    // A drag whose divider goes away under it (the pane count changed
    // mid-drag) must not keep moving one: g_pane_div[g_npanes] is the
    // terminator and has to stay at the right edge.
    ed_pane_rect(2, &dx02, &dx12);
    app_mouse(dx02, font_line_h, 0, true, 0);
    app_key('W', MOD_CTRL | MOD_SHIFT);   // closes the pane under the grab
    app_mouse_move(content_left(), font_line_h);
    g_checks++;
    if !panes_tile(1200) {
        print("FAIL a drag must not outlive its divider\n");
        g_fails++;
    }
    app_mouse(0, font_line_h, 0, false, 0);

    // --- open/edit/close must not leak ---
    // alloc_live counts live allocations and reads 0 unless the binary
    // was built with --track-alloc, so this skips itself otherwise.
    // The first cycles warm one-time caches (the picker's arena, the
    // server's opened-path list); the steady state after that has to
    // be flat, whatever a cycle allocates internally.
    if alloc_total() > 0 {
        for i32 i = 0; i < 3; i++ {
            ignore ed_open_file("src/find.mc");
            app_char('x');                 // one edit, so the journal exists
            app_key('W', MOD_CTRL);        // dirty: the first close arms
            app_key('W', MOD_CTRL);
        }
        i64 base = alloc_live();
        for i32 i = 0; i < 20; i++ {
            ignore ed_open_file("src/find.mc");
            app_char('x');
            app_key('W', MOD_CTRL);
            app_key('W', MOD_CTRL);
        }
        i64 grew = alloc_live() - base;
        g_checks++;
        if grew > 2 {
            print("FAIL open/edit/close leaks: {} live allocations over 20 cycles\n",
                grew);
            g_fails++;
        }
    }

    // --- diagnostics reach the buffer they name ---
    ignore ed_open_file("src/find.mc");
    tc_lsp_frame("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///C%3A/w/src/find.mc\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":4,\"character\":2},\"end\":{\"line\":4,\"character\":9}},\"severity\":2,\"message\":\"careful\"}]}}", 40);
    lsp_pump();
    g_checks++;
    if ed_diag_count() != 1 || ed_diag_on_line(4) != 0 || ed_diag_on_line(3) >= 0 {
        print("FAIL diagnostics must attach to the named buffer (count {} on4 {} on3 {})\n",
            ed_diag_count(), ed_diag_on_line(4), ed_diag_on_line(3));
        g_fails++;
    }
    g_checks++;
    if !str_equal(ed_diag_msg(0), "careful") {
        print("FAIL diagnostic message: {}\n", ed_diag_msg(0));
        g_fails++;
    }
    // the span clamps to the line it is drawn on, and never to nothing
    LspDiag* dg = ed_diag(0);
    i32 dc0 = 0;
    i32 dc1 = 0;
    ed_diag_span(dg, 4, 5, &dc0, &dc1);
    g_checks++;
    if dc0 != 2 || dc1 != 5 {
        print("FAIL diagnostic span must clamp to the line ({}..{})\n", dc0, dc1);
        g_fails++;
    }
    dg.col0 = 3;
    dg.col1 = 3;
    ed_diag_span(dg, 4, 40, &dc0, &dc1);
    g_checks++;
    if dc1 != dc0 + 1 {
        print("FAIL an empty range must still mark one cell ({}..{})\n", dc0, dc1);
        g_fails++;
    }
    app_key('W', MOD_CTRL);

    // --- lsp positions are utf-16 code units ---
    // "a", e-acute (2 bytes, 1 unit), a G-clef (4 bytes, 2 units), "b":
    // byte column and wire column part company after the first
    // non-ascii codepoint, and again after the astral one.
    reset("");
    app_char('a');
    app_char(0xE9);
    app_char(0x1D11E);
    app_char('b');
    g_checks++;
    if tb_len() != 8 {
        print("FAIL fixture should be 8 bytes, got {}\n", tb_len());
        g_fails++;
    }
    lsp_pos_utf16 = true;
    g_checks++;
    if lsp_col_of_byte(0, 0) != 0 || lsp_col_of_byte(0, 1) != 1
        || lsp_col_of_byte(0, 3) != 2 || lsp_col_of_byte(0, 7) != 4
        || lsp_col_of_byte(0, 8) != 5 {
        print("FAIL byte to utf-16: {} {} {} {} {}\n",
            lsp_col_of_byte(0, 0), lsp_col_of_byte(0, 1),
            lsp_col_of_byte(0, 3), lsp_col_of_byte(0, 7),
            lsp_col_of_byte(0, 8));
        g_fails++;
    }
    g_checks++;
    if lsp_byte_of_col(0, 0) != 0 || lsp_byte_of_col(0, 1) != 1
        || lsp_byte_of_col(0, 2) != 3 || lsp_byte_of_col(0, 4) != 7
        || lsp_byte_of_col(0, 5) != 8 {
        print("FAIL utf-16 to byte: {} {} {} {} {}\n",
            lsp_byte_of_col(0, 0), lsp_byte_of_col(0, 1),
            lsp_byte_of_col(0, 2), lsp_byte_of_col(0, 4),
            lsp_byte_of_col(0, 5));
        g_fails++;
    }
    // a column landing inside the surrogate pair cannot split the
    // codepoint: it resolves past it
    g_checks++;
    if lsp_byte_of_col(0, 3) != 7 {
        print("FAIL a column inside a surrogate pair must not split it ({})\n",
            lsp_byte_of_col(0, 3));
        g_fails++;
    }
    g_checks++;
    if lsp_byte_of_col(0, 99) != 8 || lsp_col_of_byte(0, 99) != 5 {
        print("FAIL positions past the line must clamp ({} {})\n",
            lsp_byte_of_col(0, 99), lsp_col_of_byte(0, 99));
        g_fails++;
    }
    // with utf-8 negotiated both are byte offsets and pass through
    lsp_pos_utf16 = false;
    g_checks++;
    if lsp_col_of_byte(0, 3) != 3 || lsp_byte_of_col(0, 3) != 3
        || lsp_byte_of_col(0, 99) != 8 {
        print("FAIL utf-8 encoding must pass byte offsets through\n");
        g_fails++;
    }
    lsp_pos_utf16 = true;

    // --- the caret stays where decoding lands ---
    // A line op keeps the byte column across a delete, so with a
    // multibyte character before the caret the kept column can fall
    // inside one. after_move snaps it back.
    reset("");
    app_char('x');
    app_char(0x4E2D);            // 3 bytes
    app_char('y');
    app_char(13);
    app_char('a');
    app_char('b');
    app_char('c');
    app_char('d');
    app_char('e');               // line 1 is "abcde"
    app_key(K_LEFT, 0);
    app_key(K_LEFT, 0);          // caret at byte 3, inside the 3-byte
                                 // character once line 0 is what is left
    app_key('K', MOD_CTRL | MOD_SHIFT);   // delete it; column 3 is kept
    g_checks++;
    i32 cn = line_bytes(cur_line);
    i32 ci = 0;
    while ci < cn && cast(i64, ci) < cur_col {
        ignore utf8_next(g_linebuf, cn, &ci);
    }
    if cast(i64, ci) != cur_col {
        print("FAIL caret at byte {} but decoding lands at {}\n", cur_col, ci);
        g_fails++;
    }

    // --- multiple cursors ---
    // A scratch buffer with three identical lines: enough for a column
    // of cursors, a merge, and repeated occurrences for Ctrl+D.
    ignore ed_open_file("build.mc");
    app_key('A', MOD_CTRL);
    type_text("aa bb\naa bb\naa bb\n");
    app_key(K_HOME, MOD_CTRL);
    app_key(K_DOWN, MOD_CTRL | MOD_ALT);
    app_key(K_DOWN, MOD_CTRL | MOD_ALT);
    g_checks++;
    if ed_cur_count() != 3 {
        print("FAIL ctrl+alt+down must add a cursor per press: {}\n", ed_cur_count());
        g_fails++;
    }
    check_cursors("a column of cursors");
    app_char('X');
    expect("Xaa bb\nXaa bb\nXaa bb\n", "typing goes in at every cursor");
    check_cursors("after typing at every cursor");
    // one keystroke at three cursors is one undo step
    i32 mc_depth = ed_undo_depth();
    app_key('Z', MOD_CTRL);
    expect("aa bb\naa bb\naa bb\n", "one undo reverts the whole multi-edit");
    g_checks++;
    if ed_undo_depth() != mc_depth - 3 {
        print("FAIL a 3-cursor edit must be 3 journal entries: {} -> {}\n",
            mc_depth, ed_undo_depth());
        g_fails++;
    }
    app_key('Z', MOD_CTRL | MOD_SHIFT);
    expect("Xaa bb\nXaa bb\nXaa bb\n", "one redo replays the whole multi-edit");

    // the cursor set comes back with the edit, so the next key hits all
    app_char(8);
    expect("aa bb\naa bb\naa bb\n", "backspace at every cursor");

    // colliding cursors merge into one
    app_key(K_ESCAPE, 0);
    g_checks++;
    if ed_cur_count() != 1 {
        print("FAIL escape must drop the extra cursors: {}\n", ed_cur_count());
        g_fails++;
    }
    app_key(K_HOME, MOD_CTRL);
    app_key(K_DOWN, MOD_CTRL | MOD_ALT);
    app_key(K_UP, 0);      // both land on line 0, column 0
    g_checks++;
    if ed_cur_count() != 1 {
        print("FAIL cursors that collide must merge: {}\n", ed_cur_count());
        g_fails++;
    }

    // Ctrl+D: the word, then the next occurrence of it
    app_key(K_HOME, MOD_CTRL);
    app_key('D', MOD_CTRL);
    i64 da = 0;
    i64 db = 0;
    g_checks++;
    if !ed_sel_range(&da, &db) || db - da != 2 || ed_cur_count() != 1 {
        print("FAIL ctrl+d with no selection must take the word: {}..{} n={}\n",
            da, db, ed_cur_count());
        g_fails++;
    }
    app_key('D', MOD_CTRL);
    app_key('D', MOD_CTRL);
    g_checks++;
    if ed_cur_count() != 3 {
        print("FAIL ctrl+d must add a cursor per occurrence: {}\n", ed_cur_count());
        g_fails++;
    }
    check_cursors("after ctrl+d");
    // every occurrence is taken, so the next press adds nothing
    app_key('D', MOD_CTRL);
    g_checks++;
    if ed_cur_count() != 3 {
        print("FAIL ctrl+d past the last occurrence must not add: {}\n", ed_cur_count());
        g_fails++;
    }
    app_char('Z');
    expect("Z bb\nZ bb\nZ bb\n", "typing over three selections");

    // copy joins the selections in document order
    app_key('A', MOD_CTRL);
    type_text("aa\nbb\ncc\n");
    app_key(K_HOME, MOD_CTRL);
    app_key(K_DOWN, MOD_CTRL | MOD_ALT);
    app_key(K_DOWN, MOD_CTRL | MOD_ALT);
    app_key(K_RIGHT, MOD_SHIFT);
    app_key(K_RIGHT, MOD_SHIFT);
    app_key('C', MOD_CTRL);
    g_checks++;
    if !str_equal(clip_text(), "aa\nbb\ncc") {
        print("FAIL multi-cursor copy joins with newlines: [{}]\n", clip_text());
        g_fails++;
    }
    app_key('X', MOD_CTRL);
    expect("\n\n\n", "multi-cursor cut removes every selection");

    // the set survives leaving the buffer and coming back
    app_key('A', MOD_CTRL);
    type_text("one\ntwo\n");
    app_key(K_HOME, MOD_CTRL);
    app_key(K_DOWN, MOD_CTRL | MOD_ALT);
    ignore ed_open_file("src/pick.mc");
    ignore ed_open_file("build.mc");
    g_checks++;
    if ed_cur_count() != 2 {
        print("FAIL cursors must survive a buffer switch: {}\n", ed_cur_count());
        g_fails++;
    }
    check_cursors("after a buffer switch");
    // an op with no multi-cursor meaning drops them rather than
    // pretending it applied to all of them
    app_key('A', MOD_CTRL);
    g_checks++;
    if ed_cur_count() != 1 {
        print("FAIL select-all must collapse the cursors: {}\n", ed_cur_count());
        g_fails++;
    }
    app_key('W', MOD_CTRL);   // dirty: arms, then discards
    app_key('W', MOD_CTRL);
    ignore ed_open_file("src/pick.mc");

    // --- multi-cursor edits keep the cursors aligned ---
    // Typing more than one character in a row is what shows drift: the
    // text after one keystroke can be right while the cursors are not.
    ignore ed_open_file("build.mc");
    app_key('A', MOD_CTRL);
    type_text("aaaa\nbbbb\ncccc\n");
    app_key(K_HOME, MOD_CTRL);
    app_key(K_RIGHT, 0);
    app_key(K_RIGHT, 0);
    app_key(K_RIGHT, 0);
    app_key(K_DOWN, MOD_CTRL | MOD_ALT);
    app_key(K_DOWN, MOD_CTRL | MOD_ALT);
    app_char('X');
    app_char('Y');
    expect("aaaXYa\nbbbXYb\ncccXYc\n", "two characters typed at three cursors");
    app_char(8);
    app_char(8);
    expect("aaaa\nbbbb\ncccc\n", "two backspaces at three cursors");
    app_key('W', MOD_CTRL);
    app_key('W', MOD_CTRL);
    ignore ed_open_file("src/pick.mc");

    // --- looks: a file opened by a look is a preview, and only the last
    // PREVIEW_MAX looks stay; an edit, a keep or a kept open makes one
    // stay for good ---
    close_all();
    ed_buf_cap_set(BUF_SOFT_MAX);
    ignore ed_open_file("src/pick.mc");
    i32 pv_base = ed_buf_count();
    ignore ed_view_file("src/find.mc");
    g_checks++;
    if !ed_buf_preview(ed_buf_active()) || ed_buf_count() != pv_base + 1
        || !str_equal(ed_path(), "src/find.mc") {
        print("FAIL a look must open a preview in a new slot ({} bufs, preview {})\n",
            ed_buf_count(), ed_buf_preview(ed_buf_active()));
        g_fails++;
    }
    ignore ed_view_file("src/view.mc");
    g_checks++;
    if ed_buf_count() != pv_base + 2 || !ed_buf_open("src/find.mc") {
        print("FAIL a second look must keep the first around ({} bufs)\n", ed_buf_count());
        g_fails++;
    }
    app_char('x');   // an edit keeps view.mc: it is no look any more
    g_checks++;
    if ed_buf_preview(ed_buf_active()) {
        print("FAIL an edit must keep a preview\n");
        g_fails++;
    }
    ignore ed_view_file("src/tree.mc");
    ignore ed_view_file("src/sem.mc");
    ignore ed_view_file("src/git.mc");   // find, tree, sem, git: PREVIEW_MAX looks
    g_checks++;
    if ed_buf_count() != pv_base + 5 || !ed_buf_open("src/find.mc") {
        print("FAIL the last {} looks must all stay ({} bufs)\n", PREVIEW_MAX, ed_buf_count());
        g_fails++;
    }
    ignore ed_view_file("src/lsp.mc");   // one more: the oldest look goes
    g_checks++;
    if ed_buf_count() != pv_base + 5 || ed_buf_open("src/find.mc") || !ed_buf_open("src/tree.mc")
        || !ed_buf_open("src/view.mc") {
        print("FAIL a look past the limit must drop the oldest look, nothing else ({} bufs, find {}, tree {})\n",
            ed_buf_count(), ed_buf_open("src/find.mc"), ed_buf_open("src/tree.mc"));
        g_fails++;
    }
    app_key('K', MOD_CTRL);   // ctrl+k enter keeps lsp.mc
    app_char(13);
    g_checks++;
    if ed_buf_preview(ed_buf_active()) || !str_equal(ed_path(), "src/lsp.mc") {
        print("FAIL ctrl+k enter must keep the preview\n");
        g_fails++;
    }
    ignore ed_view_file("src/term.mc");   // tree, sem, git, term: no look goes
    g_checks++;
    if ed_buf_count() != pv_base + 6 || !ed_buf_open("src/tree.mc") {
        print("FAIL a kept buffer must not count as a look ({} bufs)\n", ed_buf_count());
        g_fails++;
    }
    ignore ed_view_file("src/complete.mc");
    ignore ed_open_file("src/complete.mc");   // a kept open of a look keeps it
    g_checks++;
    if ed_buf_preview(ed_buf_active()) || ed_buf_open("src/tree.mc") || !ed_buf_open("src/sem.mc") {
        print("FAIL a kept open must keep the look it names (preview {}, tree {})\n",
            ed_buf_preview(ed_buf_active()), ed_buf_open("src/tree.mc"));
        g_fails++;
    }
    ignore ed_view_file("src/pick.mc");   // a look at a kept buffer leaves it kept
    g_checks++;
    if ed_buf_preview(ed_buf_active()) {
        print("FAIL a look at a kept buffer must not make it a look\n");
        g_fails++;
    }
    // a look another pane shows is never the one dropped
    app_key(92, MOD_CTRL);                // pane 1, on pick.mc too
    ignore ed_view_file("src/symbols.mc");   // pane 1 looks at symbols.mc
    app_key('1', MOD_CTRL);
    ignore ed_view_file("src/switcher.mc");
    ignore ed_view_file("src/play.mc");
    ignore ed_view_file("src/build.mc");
    ignore ed_view_file("src/lexer.mc");
    ignore ed_view_file("src/text_buf.mc");
    g_checks++;
    if !ed_buf_open("src/symbols.mc") || ed_buf_open("src/switcher.mc") {
        print("FAIL a look shown in another pane must stay while unshown ones go (symbols {}, switcher {})\n",
            ed_buf_open("src/symbols.mc"), ed_buf_open("src/switcher.mc"));
        g_fails++;
    }
    close_all();

    // the switcher lists the buffers by the last look: after the active
    // one comes the one the eye just left, whatever the open order
    ignore ed_open_file("src/pick.mc");
    ignore ed_open_file("src/find.mc");
    ignore ed_open_file("src/view.mc");
    ignore ed_open_file("src/pick.mc");
    i32 shown_before = ed_buf_active();
    app_key(K_TAB, MOD_CTRL);   // the pane previews row 1 while the chord is held
    g_checks++;
    if !switcher_on || switcher_count() < 3 || switcher_item_id(0) != shown_before
        || !str_equal(ed_buf_title(switcher_item_id(1)), "view.mc")
        || !str_equal(ed_buf_title(switcher_item_id(2)), "find.mc") || switcher_sel() != 1 {
        print("FAIL the switcher must list buffers most recent first ({} rows, sel {})\n",
            switcher_count(), switcher_sel());
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    close_all();

    // --- the cap: past BUF_SOFT_MAX buffers the oldest clean one goes,
    // a preview before a kept one; unsaved ones never count ---
    for i32 bi = 0; bi < BUF_SOFT_MAX + 3; bi++ {
        ignore ed_open_file(nofile(bi));
    }
    g_checks++;
    if ed_buf_count() != BUF_SOFT_MAX || ed_buf_open(nofile(2)) || !ed_buf_open(nofile(3)) {
        print("FAIL the cap must evict the oldest clean buffers ({} bufs, 2 open {}, 3 open {})\n",
            ed_buf_count(), ed_buf_open(nofile(2)), ed_buf_open(nofile(3)));
        g_fails++;
    }
    ignore ed_view_file(nofile(100));   // a look; the active buffer is never the victim
    ignore ed_open_file(nofile(101));   // so this one takes the oldest kept, 4
    ignore ed_open_file(nofile(102));   // and this one the look, before the older 5
    g_checks++;
    if ed_buf_count() != BUF_SOFT_MAX || ed_buf_open(nofile(100)) || !ed_buf_open(nofile(5)) {
        print("FAIL a look must go before an older kept buffer ({} bufs, 100 open {}, 5 open {})\n",
            ed_buf_count(), ed_buf_open(nofile(100)), ed_buf_open(nofile(5)));
        g_fails++;
    }
    for i32 bi = 0; bi < ed_buf_count(); bi++ {
        ed_buf_switch(bi);
        app_char('x');
    }
    ignore ed_open_file(nofile(200));
    ignore ed_open_file(nofile(201));
    g_checks++;
    if ed_buf_count() != BUF_SOFT_MAX + 2 {
        print("FAIL unsaved buffers must not count against the cap ({} bufs)\n", ed_buf_count());
        g_fails++;
    }
    close_all();

    // --- a full table evicts, it does not refuse ---
    // A random walk never climbs BUF_MAX opens deep, so this state is
    // driven directly. nofile(n) names a path that does not exist, and
    // opening one gives an empty new-file buffer, so the table fills
    // without touching the disk. From an empty table, so the order of
    // the victims is the order of the opens. The cap is lifted to the
    // table's size for it and stays lifted.
    close_all();
    ed_buf_cap_set(BUF_MAX);
    i32 opened = 0;
    for i32 bi = 0; bi < BUF_MAX + 8; bi++ {
        if ed_open_file(nofile(bi)) { opened++; }
    }
    g_checks++;
    if ed_buf_count() != BUF_MAX {
        print("FAIL buffer table overflows: {} slots, want {}\n", ed_buf_count(), BUF_MAX);
        g_fails++;
    }
    g_checks++;
    if opened != BUF_MAX + 8 {
        print("FAIL opening past a full table must evict, not refuse: {} of {} opened\n",
            opened, BUF_MAX + 8);
        g_fails++;
    }
    // the victims were the least recently shown: the first eight
    g_checks++;
    if ed_buf_open(nofile(7)) || !ed_buf_open(nofile(8)) {
        print("FAIL eviction order: file 7 should be gone and file 8 kept\n");
        g_fails++;
    }
    // showing a buffer again moves it to the back of the line: 8 is
    // the oldest now, but after a look at it 9 goes first
    ignore ed_open_file(nofile(8));
    ignore ed_open_file(nofile(BUF_MAX + 8));
    g_checks++;
    if !ed_buf_open(nofile(8)) || ed_buf_open(nofile(9)) {
        print("FAIL eviction order after a revisit: 8 was shown again, 9 should go\n");
        g_fails++;
    }
    // a buffer on another pane is never the victim, however old: show
    // 10 (the oldest now), split so the new pane shows it too, then
    // open something else in the new pane
    ignore ed_open_file(nofile(10));
    app_key(92, MOD_CTRL);
    ignore ed_open_file(nofile(BUF_MAX + 9));
    g_checks++;
    if !ed_buf_open(nofile(10)) || ed_buf_open(nofile(11)) {
        print("FAIL a buffer shown on another pane was evicted\n");
        g_fails++;
    }
    g_checks++;
    if ed_pane_count() != 2 {
        print("FAIL split for the eviction check: {} panes, want 2\n", ed_pane_count());
        g_fails++;
    }
    // eviction frees what the buffer owned: twenty more opens past a
    // full table leave the live allocation count flat
    if alloc_total() > 0 {
        i64 base = alloc_live();
        for i32 bi = 0; bi < 20; bi++ {
            ignore ed_open_file(nofile(BUF_MAX + 20 + bi));
        }
        i64 grew = alloc_live() - base;
        g_checks++;
        if grew > 4 {
            print("FAIL eviction leaks: {} live allocations over 20 opens\n", grew);
            g_fails++;
        }
    }
    // when every buffer is unsaved or on screen the open fails, and the
    // notice says so until Esc or a click on it; a plain key leaves it
    for i32 bi = 0; bi < ed_buf_count(); bi++ {
        ed_buf_switch(bi);
        app_char('x');
    }
    i32 nb_full = ed_buf_count();
    bool got2 = ed_open_file(nofile(999));
    g_checks++;
    if got2 || ed_buf_count() != nb_full || !notice_on {
        print("FAIL all-unsaved table: opened {} count {} notice {}\n", got2, ed_buf_count(), notice_on);
        g_fails++;
    }
    app_key(K_RIGHT, 0);
    g_checks++;
    if !notice_on {
        print("FAIL the notice must survive a plain key\n");
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    g_checks++;
    if notice_on {
        print("FAIL Esc must dismiss the notice\n");
        g_fails++;
    }
    ignore ed_open_file(nofile(998));
    i32 nx0 = 0;
    i32 ny0 = 0;
    i32 nx1 = 0;
    i32 ny1 = 0;
    ed_notice_rect(&nx0, &ny0, &nx1, &ny1);
    app_mouse((nx0 + nx1) / 2, (ny0 + ny1) / 2, 0, true, 0);
    app_mouse((nx0 + nx1) / 2, (ny0 + ny1) / 2, 0, false, 0);
    g_checks++;
    if notice_on {
        print("FAIL a click on the notice must dismiss it (box {},{}-{},{})\n", nx0, ny0, nx1, ny1);
        g_fails++;
    }
    close_all();
    // --- open folder: ctrl+k o prompts for a folder; the switch closes the
    // buffers, moves the working directory and rescans; an unsaved buffer
    // refuses it ---
    close_all();
    app_key('K', MOD_CTRL);
    app_key('O', 0);
    app_char('o');   // the key's character follows it, and is the chord's
    g_checks++;
    if !ask_on || !str_equal(ask_label(), "Open Folder") || ask_len != 0 {
        print("FAIL ctrl+k o must open the folder prompt, empty (on {} label {} len {})\n", ask_on, ask_label(), ask_len);
        g_fails++;
    }
    type_text("build/nowhere");
    app_char(13);
    g_checks++;
    if !ask_on || !str_equal(ask_message(), "not a folder") {
        print("FAIL a path that is not a folder must keep the box open, with the reason ({})\n", ask_message());
        g_fails++;
    }
    // a press inside the box keeps it; one outside closes it
    i32 abx = 0;
    i32 aby = 0;
    i32 abw = 0;
    i32 abh = 0;
    ask_box(&abx, &aby, &abw, &abh);
    app_mouse(abx + 4, aby + 4, 0, true, 0);
    bool kept = ask_on;
    app_mouse(abx + 4, aby + abh + 20, 0, true, 0);
    g_checks++;
    if !kept || ask_on {
        print("FAIL a press must close the box only outside it ({} {})\n", kept, ask_on);
        g_fails++;
    }
    app_key('K', MOD_CTRL);
    app_key('O', 0);
    app_char('o');
    app_key(K_ESCAPE, 0);
    g_checks++;
    if ask_on {
        print("FAIL esc must close the folder prompt\n");
        g_fails++;
    }
    // a chord that ends elsewhere is swallowed, not typed
    app_key('K', MOD_CTRL);
    app_key('Q', 0);
    app_char('q');
    g_checks++;
    if tb_len() != 0 || ask_on {
        print("FAIL an unknown chord must be swallowed\n");
        g_fails++;
    }
    // unsaved: refused, and the directory does not move
    ignore ed_open_file("src/pick.mc");
    app_char('x');
    g_chdir_last_len = 0;
    g_checks++;
    if ed_open_folder("build") || g_chdir_last_len != 0 || ed_buf_count() != 1 {
        print("FAIL an unsaved buffer must refuse the folder switch\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL);
    app_key('W', MOD_CTRL);
    // clean: the buffers close, the directory moves, the tree shows
    ignore ed_open_file("src/pick.mc");
    ignore ed_open_file("src/find.mc");
    tree_on = false;
    g_checks++;
    if !ed_open_folder("build") || !str_equal(str_from(&g_chdir_last[0], g_chdir_last_len), "build")
        || ed_buf_count() != 1 || g_has_path || !tree_on {
        print("FAIL a clean switch must move the directory, close the buffers and show the tree (chdir [{}] bufs {} path {} tree {})\n",
            str_from(&g_chdir_last[0], g_chdir_last_len), ed_buf_count(), g_has_path, tree_on);
        g_fails++;
    }
    g_checks++;
    if !str_equal(ed_title(), "untitled \xE2\x80\x94 build") {
        print("FAIL the title must carry the new project (title [{}])\n", ed_title());
        g_fails++;
    }
    g_chdir_last_len = 0;   // the stub's working directory is the root again
    close_all();

    when !os(wasm) {   // session restore checks path_exists per file, which has no wasm arm
        // --- session: the open files, panes and carets survive a save then a
        // restore, stored under a per-folder base (build/, not the repo root).
        // pick.mc and find.mc sit in the two panes; view.mc is a background
        // buffer, so its caret comes from the buffer record, not a pane ---
        close_all();
        session_set_base("build/edminc_sess_test");
        test_remove("build/edminc_sess_test/session");
        ignore ed_view_file("src/pick.mc");   // a preview, shown in pane 0 throughout
        cur_line = 5;
        cur_col = 0;
        app_key(92, MOD_CTRL);   // split: both panes on pick.mc
        ignore ed_open_file("src/find.mc");   // the active pane moves to find.mc
        cur_line = 3;
        cur_col = 0;
        ignore ed_open_file("src/view.mc");   // becomes background once we switch away
        cur_line = 7;
        cur_col = 0;
        ignore ed_open_file("src/find.mc");   // the active pane holds find.mc again
        cur_line = 3;
        cur_col = 0;
        // a third pane with a shell in it: the session keeps the pane as
        // a terminal pane, and the restore opens a fresh shell there
        app_key(92, MOD_CTRL);
        tt_open_term();
        app_key('2', MOD_CTRL);   // the active pane is recorded too
        // the sidebar's dragged width and a moved divider come back too
        tree_set_w(font_line_h * 8);
        i32 dv_x0 = 0;
        i32 dv_x1 = 0;
        ed_pane_rect(0, &dv_x0, &dv_x1);
        app_mouse(dv_x1, doc_top() + 5, 0, true, 0);
        app_mouse_move(dv_x1 - 40, doc_top() + 5);
        app_mouse(dv_x1 - 40, doc_top() + 5, 0, false, 0);
        ed_pane_rect(0, &dv_x0, &dv_x1);
        i32 sess_pane0_w = dv_x1 - dv_x0;
        session_set_enabled(true);
        app_session_save();
        session_set_enabled(false);   // so the teardown does not overwrite it
        close_all();
        g_checks++;
        if session_enabled() || g_has_path {
            print("FAIL the session teardown must leave a clean empty editor\n    ");
            g_fails++;
        }
        tree_set_w(font_line_h * 10);   // something else, so the restore is seen to set it
        ignore app_session_restore();
        g_checks++;
        if tree_w_px() != font_line_h * 8 {
            print("FAIL the sidebar width must come back from the session ({} vs {})\n    ",
                tree_w_px(), font_line_h * 8);
            g_fails++;
        }
        ed_pane_rect(0, &dv_x0, &dv_x1);
        g_checks++;
        if dv_x1 - dv_x0 > sess_pane0_w + 2 || dv_x1 - dv_x0 < sess_pane0_w - 2 {
            print("FAIL a moved divider must come back from the session (pane 0 is {} wide, was {})\n    ",
                dv_x1 - dv_x0, sess_pane0_w);
            g_fails++;
        }
        g_checks++;
        if ed_pane_count() != 3 || ed_pane_active() != 1 || ed_buf_count() < 3 {
            print("FAIL restore must rebuild three panes and three buffers (panes {} active {} bufs {})\n    ",
                ed_pane_count(), ed_pane_active(), ed_buf_count());
            g_fails++;
        }
        g_checks++;
        // (the handle may be the old one's number again: the stub hands
        // out the first free slot)
        if ed_pane_kind(2) != PANE_TERM || !term_has_child(ed_pane_term(2)) || ed_term_active() >= 0 {
            print("FAIL the terminal pane must come back with a fresh shell (kind {}, term {})\n    ",
                ed_pane_kind(2), ed_pane_term(2));
            g_fails++;
        }
        // and a terminal pane's document pane beside it is untouched
        app_key('3', MOD_CTRL);
        app_key('W', MOD_CTRL);                // the shell goes, the pane on its document
        app_key('W', MOD_CTRL | MOD_SHIFT);    // then the pane
        g_checks++;
        if ed_pane_count() != 2 || ed_term_background_count() != 0 {
            print("FAIL closing the restored terminal pane must leave the two document panes ({} panes)\n    ",
                ed_pane_count());
            g_fails++;
        }
        app_key('2', MOD_CTRL);
        g_checks++;
        if !str_equal(str_from(&g_path[0], g_path_len), "src/find.mc") || cur_line != 3 {
            print("FAIL the active pane must restore its file and caret (path {} line {})\n    ",
                str_from(&g_path[0], g_path_len), cur_line);
            g_fails++;
        }
        // The restore opens the files in a burst that keeps only one
        // pending git fetch, so the one left on screen (find.mc, opened
        // mid-burst) has no baseline yet. The wake must ask for it again.
        i32 gtries = 0;
        while !git_fetched() && gtries < 4 {
            git_settle(str_from(&g_path[0], g_path_len));
            app_wake();
            gtries++;
        }
        git_settle(str_from(&g_path[0], g_path_len));
        g_checks++;
        if !git_on() {
            print("FAIL the restored active buffer must get its git baseline (tries {})\n", gtries);
            g_fails++;
        }
        i32 sess_other = 0;
        if ed_pane_active() == 0 { sess_other = 1; }
        ed_pane_swap_view(sess_other);
        g_checks++;
        if !str_equal(str_from(&g_path[0], g_path_len), "src/pick.mc") || cur_line != 5 {
            print("FAIL the other pane must restore its file and caret (path {} line {})\n    ",
                str_from(&g_path[0], g_path_len), cur_line);
            g_fails++;
        }
        ed_pane_swap_view(ed_pane_active());
        bool sess_prev = false;
        for i32 b = 0; b < ed_buf_count(); b++ {
            if str_equal(ed_buf_title(b), "pick.mc") && ed_buf_preview(b) { sess_prev = true; }
        }
        g_checks++;
        if !sess_prev {
            print("FAIL a preview must come back from the session as a preview\n    ");
            g_fails++;
        }
        ignore ed_open_file("src/view.mc");   // the background buffer, caret from its record
        g_checks++;
        if !str_equal(str_from(&g_path[0], g_path_len), "src/view.mc") || cur_line != 7 {
            print("FAIL a background buffer must restore its caret (path {} line {})\n    ",
                str_from(&g_path[0], g_path_len), cur_line);
            g_fails++;
        }
        // --- the restart's handover: the next process takes the dirty
        // text, the terminals with their children and screens, and the
        // layout; the harness round-trips it in one process ---
        close_all();
        ed_term_close_all();
        test_remove("build/edminc_sess_test/handover");
        ignore ed_open_file("src/pick.mc");
        cur_line = 0;
        cur_col = 0;
        app_char('Z');   // dirty, unsaved
        app_key(92, MOD_CTRL);   // a second pane, then a terminal in it
        tt_open_term();
        i32 ho_t1 = ed_term_active();
        tt_feed(ho_t1, "one");
        app_key('K', MOD_CTRL);
        app_key('T', MOD_SHIFT);
        app_char('T');   // a second shell in place; the first drops to the background
        i32 ho_t2 = ed_term_active();
        tt_feed(ho_t2, "two\r\nthree");
        app_key('1', MOD_CTRL);   // the focus on the document pane
        app_handover_write();
        g_checks++;
        if !path_exists("build/edminc_sess_test/handover") {
            print("FAIL the handover file must be written\n");
            g_fails++;
        }
        session_set_enabled(false);
        close_all();
        ed_term_close_all();
        ignore app_handover_restore("build/edminc_sess_test/handover");
        g_checks++;
        if path_exists("build/edminc_sess_test/handover") {
            print("FAIL the handover file must go once taken\n");
            g_fails++;
        }
        g_checks++;
        if ed_pane_count() != 2 || ed_pane_kind(1) != PANE_TERM || ed_pane_active() != 0
            || ed_term_active() >= 0 || ed_term_background_count() != 1 {
            print("FAIL the handover must bring the panes, the shown terminal and the background one back ({} panes, kind {}, bg {})\n",
                ed_pane_count(), ed_pane_kind(1), ed_term_background_count());
            g_fails++;
        }
        i32 ho_shown = ed_pane_term(1);
        noinit u8[256] hob;
        i32 hon = term_dump(ho_shown, &hob[0], 256);
        g_checks++;
        if !str_equal(str_from(&hob[0], hon), "two\nthree") || term_cy(ho_shown) != 1 || term_cx(ho_shown) != 5 {
            print("FAIL the shown terminal must have its screen and cursor back ([{}] at {},{})\n",
                str_from(&hob[0], hon), term_cx(ho_shown), term_cy(ho_shown));
            g_fails++;
        }
        i32 ho_bg = -1;
        for i32 k = 0; k < TERM_MAX; k++ {
            if term_has_child(k) && k != ho_shown { ho_bg = k; }
        }
        hon = term_dump(ho_bg, &hob[0], 256);
        g_checks++;
        if ho_bg < 0 || !str_equal(str_from(&hob[0], hon), "one") {
            print("FAIL the background terminal must have its screen back ([{}])\n", str_from(&hob[0], hon));
            g_fails++;
        }
        // The same, on a platform that cannot pass a pty on: the shells
        // are gone, so every one of them comes back as a new shell under
        // the text the old one had, the way a terminal that reopens
        // shows what was on it. The background ones come back too, so
        // the switcher still lists them with what they said.
        session_set_enabled(true);
        close_all();
        ed_term_close_all();
        ignore ed_open_file("src/pick.mc");
        app_key(92, MOD_CTRL);
        tt_open_term();
        tt_feed(ed_term_active(), "put aside");
        tt_open_term();   // a second shell in place; the first goes behind
        i32 np_t = ed_term_active();
        tt_feed(np_t, "old output here");
        tt_export_ok = false;
        app_handover_write();
        session_set_enabled(false);
        close_all();
        ed_term_close_all();
        ignore app_handover_restore("build/edminc_sess_test/handover");
        tt_export_ok = true;
        g_checks++;
        if ed_pane_count() != 2 || ed_pane_kind(1) != PANE_TERM {
            print("FAIL a pane whose shell could not cross must come back with a new one ({} panes, kind {})\n",
                ed_pane_count(), ed_pane_kind(1));
            g_fails++;
        }
        i32 np_new = ed_pane_term(1);
        noinit u8[256] npb;
        i32 npn = term_dump(np_new, &npb[0], 256);
        g_checks++;
        if np_new < 0 || !str_equal(str_from(&npb[0], npn), "old output here") {
            print("FAIL the new shell must come up under what the old one said ([{}])\n",
                str_from(&npb[0], npn));
            g_fails++;
        }
        i32 np_bg = -1;
        for i32 k = 0; k < TERM_MAX; k++ {
            if term_has_child(k) && k != np_new { np_bg = k; }
        }
        npn = term_dump(np_bg, &npb[0], 256);
        g_checks++;
        if np_bg < 0 || !str_equal(str_from(&npb[0], npn), "put aside") {
            print("FAIL a background shell that could not cross must come back too ([{}])\n",
                str_from(&npb[0], npn));
            g_fails++;
        }
        // and the cursor is on a fresh line, so the prompt prints under
        // the text rather than over its last line
        g_checks++;
        if term_cy(np_new) != 1 || term_cx(np_new) != 0 {
            print("FAIL the new shell must start on the line after ({},{})\n",
                term_cx(np_new), term_cy(np_new));
            g_fails++;
        }

        g_checks++;
        if !str_equal(ed_path(), "src/pick.mc") || !tb.dirty || tb_len() < 1 {
            print("FAIL the dirty buffer must come back dirty ({} dirty {})\n", ed_path(), cast(i32, tb.dirty));
            g_fails++;
        } else {
            u8 hz = 0;
            tb_copy(0, &hz, 1);
            g_checks++;
            if hz != 'Z' {
                print("FAIL the dirty buffer must carry its unsaved text (first byte {})\n", cast(i32, hz));
                g_fails++;
            }
        }
        // A folder where nothing is open but a shell: the handover names
        // no file at all. The load wanted one, since a session with no
        // file has nothing to restore, and that lost the terminal too.
        session_set_enabled(true);
        close_all();
        ed_term_close_all();
        tt_open_term();
        tt_feed(ed_term_active(), "no file here");
        tt_export_ok = false;
        app_handover_write();
        session_set_enabled(false);
        close_all();
        ed_term_close_all();
        ignore app_handover_restore("build/edminc_sess_test/handover");
        tt_export_ok = true;
        i32 nf_new = ed_pane_term(0);
        noinit u8[64] nfb;
        i32 nfn = term_dump(nf_new, &nfb[0], 64);
        g_checks++;
        if ed_pane_kind(0) != PANE_TERM || !str_equal(str_from(&nfb[0], nfn), "no file here") {
            print("FAIL a handover with no file must still bring the terminal back (kind {} [{}])\n",
                ed_pane_kind(0), str_from(&nfb[0], nfn));
            g_fails++;
        }
        session_set_enabled(false);
        close_all();
        ed_term_close_all();

        // a file argument means the session is left untouched
        session_set_enabled(false);
        close_all();
        ignore ed_open_file("src/lexer.mc");
        ignore app_session_restore();
        g_checks++;
        if session_enabled() || ed_pane_count() != 1 || !str_equal(str_from(&g_path[0], g_path_len), "src/lexer.mc") {
            print("FAIL a file argument must leave the session untouched (enabled {} panes {} path {})\n    ",
                session_enabled(), ed_pane_count(), str_from(&g_path[0], g_path_len));
            g_fails++;
        }
        // a folder with no session opens its README.md in one pane, and
        // reports that nothing placed the windows
        session_set_base("build/edminc_sess_none");
        test_remove("build/edminc_sess_none/session");
        close_all();
        bool none_placed = app_session_restore();
        g_checks++;
        if none_placed || ed_pane_count() != 1 || !str_equal(ed_buf_title(ed_buf_active()), "README.md") {
            print("FAIL restoring a folder with no session must open README.md (placed {} panes {} title {})\n    ",
                none_placed, ed_pane_count(), ed_buf_title(ed_buf_active()));
            g_fails++;
        }
        session_set_enabled(false);
        session_set_base(".edminc");
        test_remove("build/edminc_sess_test/session");
        close_all();

        // --- multi-window session: two windows with their files, sidebar and
        // geometry survive a save and restore ---
        close_all();
        while ed_window_count() > 1 { ignore ed_window_close(); }
        tree_on = false;
        session_set_base("build/edminc_sess_mw");
        test_remove("build/edminc_sess_mw/session");
        ignore ed_open_file("src/pick.mc");
        tree_on = true;                          // window 0: pick.mc, sidebar on
        i32 mw0 = ed_window_active();
        g_wr_x[mw0] = 10; g_wr_y[mw0] = 20; g_wr_w[mw0] = 800; g_wr_h[mw0] = 600; g_wr_maxi[mw0] = 0;
        i32 mw1 = ed_window_new(ed_buf_active());  // window 1: find.mc, sidebar off
        ignore ed_open_file("src/find.mc");
        cur_line = 7;
        cur_col = 0;
        g_wr_x[mw1] = 900; g_wr_y[mw1] = 50; g_wr_w[mw1] = 700; g_wr_h[mw1] = 500; g_wr_maxi[mw1] = 0;
        tree_open_add_path("lib");   // an expanded directory, shared by the windows
        session_set_enabled(true);
        app_session_save();
        session_set_enabled(false);
        while ed_window_count() > 1 { ignore ed_window_close(); }
        close_all();
        for i32 z = 0; z < 8; z++ { g_wr_x[z] = 0; g_wr_y[z] = 0; g_wr_w[z] = 0; g_wr_h[z] = 0; }
        i32 mw_base = ed_window_active();
        tree_open_clear();                       // prove the restore repopulates it
        ignore app_session_restore();
        g_checks++;
        if ed_window_count() != 2 {
            print("FAIL restore must recreate two windows (count {})\n", ed_window_count());
            g_fails++;
        }
        g_checks++;
        bool lib_open = false;
        for i32 to = 0; to < tree_open_count(); to++ {
            if str_equal(tree_open_at(to), "lib") { lib_open = true; }
        }
        if !lib_open {
            print("FAIL the tree's expanded dirs must restore (open {})\n", tree_open_count());
            g_fails++;
        }
        i32 mw_cur = ed_window_active();
        g_checks++;
        if !str_equal(str_from(&g_path[0], g_path_len), "src/find.mc") || cur_line != 7 {
            print("FAIL the active window must restore its file/caret (path {} line {})\n",
                str_from(&g_path[0], g_path_len), cur_line);
            g_fails++;
        }
        g_checks++;
        if g_wr_x[mw_cur] != 900 || g_wr_w[mw_cur] != 700 || g_wr_x[mw_base] != 10 || g_wr_w[mw_base] != 800 {
            print("FAIL window geometry must restore (cur {} {} base {} {})\n",
                g_wr_x[mw_cur], g_wr_w[mw_cur], g_wr_x[mw_base], g_wr_w[mw_base]);
            g_fails++;
        }
        g_checks++;
        if tree_on {
            print("FAIL the active (find.mc) window must have no sidebar\n");
            g_fails++;
        }
        app_use_window(mw_base);
        g_checks++;
        if !tree_on || !str_equal(str_from(&g_path[0], g_path_len), "src/pick.mc") {
            print("FAIL the other window must restore pick.mc with the sidebar (on {} path {})\n",
                tree_on, str_from(&g_path[0], g_path_len));
            g_fails++;
        }
        // close down standing on the non-primary, so the low slot survives
        // and later tests start from a single window there
        if ed_window_active() == mw_base { app_use_window(mw_cur); }
        while ed_window_count() > 1 { ignore ed_window_close(); }
        // a minimized window's stub rect is not restored: the window
        // opens maximized, as at launch
        test_remove("build/edminc_sess_mw/session");
        close_all();
        ignore ed_open_file("src/pick.mc");
        i32 mwm = ed_window_active();
        g_wr_x[mwm] = -32000; g_wr_y[mwm] = -32000; g_wr_w[mwm] = 237; g_wr_h[mwm] = 56;
        session_set_enabled(true);
        app_session_save();
        session_set_enabled(false);
        close_all();
        g_wr_x[mwm] = 5; g_wr_y[mwm] = 6; g_wr_w[mwm] = 999; g_wr_h[mwm] = 700;
        ignore app_session_restore();
        g_checks++;
        if g_wr_maxi[mwm] != 1 || g_wr_w[mwm] == 237 || ed_window_count() != 1 {
            print("FAIL a minimized window's rect must not restore (maxi {} w {} windows {})\n",
                g_wr_maxi[mwm], g_wr_w[mwm], ed_window_count());
            g_fails++;
        }
        session_set_enabled(false);
        session_set_base(".edminc");
        test_remove("build/edminc_sess_mw/session");
        tree_on = true;
        close_all();
        // the restores read the settings, which have no file here and
        // give the default theme; later checks expect a harness run's
        settings_use_theme("Dark+");
        settings_set_enabled(false);
    }

    // --- opening a file after a fresh split fills only the active pane,
    // not both: the empty untitled buffer both panes share is not reused
    // in place ---
    close_all();
    app_key(92, MOD_CTRL);   // split: both panes on the one untitled buffer
    g_checks++;
    if ed_pane_count() != 2 || ed_buf_count() != 1 {
        print("FAIL a split of the untitled buffer must give two panes on one buffer (panes {} bufs {})\n",
            ed_pane_count(), ed_buf_count());
        g_fails++;
    }
    ignore ed_open_file("src/pick.mc");
    g_checks++;
    if !str_equal(str_from(&g_path[0], g_path_len), "src/pick.mc") || ed_buf_count() != 2 {
        print("FAIL the active pane must open the file into a new buffer (path {} bufs {})\n",
            str_from(&g_path[0], g_path_len), ed_buf_count());
        g_fails++;
    }
    i32 other = 1;
    if ed_pane_active() == 1 { other = 0; }
    ed_pane_swap_view(other);
    g_checks++;
    if g_has_path {
        print("FAIL the other pane must stay on the untitled buffer (path {})\n",
            str_from(&g_path[0], g_path_len));
        g_fails++;
    }
    ed_pane_swap_view(ed_pane_active());
    while ed_pane_count() > 1 { ignore ed_pane_close(); }
    close_all();

    // Ctrl+Shift+E is Ctrl+E, as in VS Code: the file tree, focused, from
    // the changes view and from the project search view
    close_all();
    app_key('G', MOD_CTRL | MOD_SHIFT);
    app_key(K_ESCAPE, 0);
    app_key('E', MOD_CTRL | MOD_SHIFT);
    g_checks++;
    if tree_mode != SIDE_FILES || !tree_on || !tree_focus {
        print("FAIL ctrl+shift+e must show the file tree and focus it (mode {}, on {}, focus {})\n",
            tree_mode, tree_on, tree_focus);
        g_fails++;
    }
    app_key('F', MOD_CTRL | MOD_SHIFT);
    app_key('E', MOD_CTRL | MOD_SHIFT);
    g_checks++;
    if search_on || tree_mode != SIDE_FILES || !tree_focus {
        print("FAIL ctrl+shift+e must close the search view for the file tree (search {}, focus {})\n",
            search_on, tree_focus);
        g_fails++;
    }
    app_key(K_ESCAPE, 0);

    // --- a file opened from the tree lands in the focused pane: split,
    // ctrl+1, ctrl+2, ctrl+e, space on a row ---
    close_all();
    ignore ed_open_file("src/pick.mc");
    app_key(92, MOD_CTRL);   // split: the new pane is the right one, focused
    ignore ed_open_file("src/ed.mc");
    app_key('1', MOD_CTRL);
    app_key('2', MOD_CTRL);
    app_key('E', MOD_CTRL);
    i32 find_row = tree_row_of("src/find.mc");
    if find_row < 0 {
        // the tree lists top-level rows only until src is expanded
        for i32 i = 0; i < tree_row_count(); i++ {
            if str_equal(tree_row_path(i), "src") { tree_select(i); }
        }
        app_char(32);   // expand src
        for i32 i = 0; i < tree_row_count(); i++ {
            if str_equal(tree_row_path(i), "src/find.mc") { find_row = i; }
        }
    }
    tree_select(find_row);
    app_char(32);
    g_checks++;
    if ed_pane_active() != 1 || !str_equal(str_from(&g_path[0], g_path_len), "src/find.mc") {
        print("FAIL space in the tree must open the file in the focused pane (active {} path {})\n",
            ed_pane_active(), str_from(&g_path[0], g_path_len));
        g_fails++;
    }
    ed_pane_swap_view(0);
    noinit u8[PATH_MAX] leftbuf;   // a copy: the path buffer is reloaded by the swap back
    memcpy(&leftbuf[0], &g_path[0], g_path_len);
    i32 left_len = g_path_len;
    ed_pane_swap_view(1);
    g_checks++;
    if !str_equal(str_from(&leftbuf[0], left_len), "src/pick.mc") {
        print("FAIL the other pane must keep its file (left {})\n", str_from(&leftbuf[0], left_len));
        g_fails++;
    }
    // collapse src again so later tree checks see the tree they expect
    for i32 i = 0; i < tree_row_count(); i++ {
        if str_equal(tree_row_path(i), "src") { tree_select(i); }
    }
    app_char(32);
    app_key(K_ESCAPE, 0);
    while ed_pane_count() > 1 { ignore ed_pane_close(); }
    close_all();

    // --- the keyboard comes back to the editor on ctrl+digit and on
    // the split, even for the pane already active; Enter in the tree
    // opens and passes the focus, Space opens and keeps it ---
    close_all();
    ignore ed_open_file("src/pick.mc");
    app_key('E', MOD_CTRL);
    g_checks++;
    if !tree_focus {
        print("FAIL ctrl+e must focus the tree\n");
        g_fails++;
    }
    app_key(92, MOD_CTRL);
    g_checks++;
    if tree_focus || ed_pane_count() != 2 || ed_pane_active() != 1 {
        print("FAIL the split must take the focus from the tree (tree {} panes {} active {})\n",
            tree_focus, ed_pane_count(), ed_pane_active());
        g_fails++;
    }
    app_key('E', MOD_CTRL);
    app_key('2', MOD_CTRL);   // already the active pane
    g_checks++;
    if tree_focus || ed_pane_active() != 1 {
        print("FAIL ctrl+2 on the active pane must still take the focus from the tree (tree {} active {})\n",
            tree_focus, ed_pane_active());
        g_fails++;
    }
    app_key('E', MOD_CTRL);
    app_key('1', MOD_CTRL);
    g_checks++;
    if tree_focus || ed_pane_active() != 0 {
        print("FAIL ctrl+1 must switch the pane and take the focus (tree {} active {})\n",
            tree_focus, ed_pane_active());
        g_fails++;
    }
    app_key('E', MOD_CTRL);
    i32 enter_row = tree_row_of("src/find.mc");
    if enter_row < 0 {
        for i32 i = 0; i < tree_row_count(); i++ {
            if str_equal(tree_row_path(i), "src") { tree_select(i); }
        }
        app_char(32);
        for i32 i = 0; i < tree_row_count(); i++ {
            if str_equal(tree_row_path(i), "src/find.mc") { enter_row = i; }
        }
    }
    tree_select(enter_row);
    app_char(13);
    g_checks++;
    if tree_focus || !str_equal(str_from(&g_path[0], g_path_len), "src/find.mc") || ed_pane_active() != 0 {
        print("FAIL enter on a file must open it in the focused pane and pass the focus (tree {} path {} active {})\n",
            tree_focus, str_from(&g_path[0], g_path_len), ed_pane_active());
        g_fails++;
    }
    app_key('E', MOD_CTRL);
    i32 space_row = tree_row_of("src/pick.mc");
    tree_select(space_row);
    app_char(32);
    g_checks++;
    if !tree_focus || !str_equal(str_from(&g_path[0], g_path_len), "src/pick.mc") {
        print("FAIL space on a file must open it and keep the focus in the tree (tree {} path {})\n",
            tree_focus, str_from(&g_path[0], g_path_len));
        g_fails++;
    }
    app_key(K_ESCAPE, 0);
    for i32 i = 0; i < tree_row_count(); i++ {
        if str_equal(tree_row_path(i), "src") { tree_select(i); }
    }
    app_key('E', MOD_CTRL);
    app_char(32);   // collapse src again
    app_key(K_ESCAPE, 0);
    while ed_pane_count() > 1 { ignore ed_pane_close(); }
    close_all();

    // --- the title lists the files shown in the panes; a lone pane keeps
    // the bare name, a split lists both, closing the split drops one ---
    close_all();
    tree_on = false;
    ignore ed_open_file("build.mc");
    str t1 = ed_title();
    g_checks++;
    if t1.len < 8 || !str_equal(str_from(t1.data, 8), "build.mc") || (t1.len > 8 && t1.data[8] == ',') {
        print("FAIL a lone pane keeps the bare title (title [{}])\n", t1);
        g_fails++;
    }
    // a background buffer (same pane) does not appear in the title
    ignore ed_open_file("src/pick.mc");
    str tb1 = ed_title();
    g_checks++;
    if tb1.len < 7 || !str_equal(str_from(tb1.data, 7), "pick.mc") || (tb1.len > 7 && tb1.data[7] == ',') {
        print("FAIL a single pane shows only its own file (title [{}])\n", tb1);
        g_fails++;
    }
    // split and show a second file: both names, in pane order
    ignore ed_open_file("build.mc");   // pane 0 back to build.mc
    app_key(92, MOD_CTRL);             // split; pane 1 active, both build.mc
    ignore ed_open_file("src/pick.mc"); // pane 1 -> pick.mc
    str t2 = ed_title();
    str want2 = "build.mc, pick.mc";
    g_checks++;
    if t2.len < want2.len || !str_equal(str_from(t2.data, want2.len), want2) {
        print("FAIL a split lists both pane files (title [{}])\n", t2);
        g_fails++;
    }
    ignore ed_pane_close();            // close pane 1; pane 0 (build.mc) stays
    str t3 = ed_title();
    g_checks++;
    if ed_pane_count() != 1 || t3.len < 8 || !str_equal(str_from(t3.data, 8), "build.mc") || (t3.len > 8 && t3.data[8] == ',') {
        print("FAIL closing the split must drop the other name (panes {} title [{}])\n", ed_pane_count(), t3);
        g_fails++;
    }
    g_checks++;
    if doc_top() != 0 {
        print("FAIL a lone pane must have no banner (doc_top {})\n", doc_top());
        g_fails++;
    }
    // --- a click lands on the pointed line, below the banner ---
    close_all();
    tree_on = false;
    ignore ed_open_file("build.mc");
    i32 clx = gutter_w() + 2 * font_cell_w + 1;
    i32 cly = doc_top() + 3 * font_line_h + font_line_h / 2;   // line 3, not the last
    app_mouse(clx, cly, 0, true, 0);
    app_mouse(clx, cly, 0, false, 0);
    g_checks++;
    if cur_line != 3 {
        print("FAIL a click must land on the pointed line, below the banner (line {})\n", cur_line);
        g_fails++;
    }
    close_all();

    // --- a click in a pane's banner focuses it but does not move the caret ---
    close_all();
    tree_on = false;
    ignore ed_open_file("build.mc");
    app_key(92, MOD_CTRL);            // split; both panes on build.mc
    ignore ed_open_file("src/pick.mc");   // the active pane (1) moves to pick.mc
    cur_line = 5;
    cur_col = 0;
    i32 bp0 = 0;
    i32 bp1 = 0;
    ed_pane_rect(1, &bp0, &bp1);
    i32 bmx = (bp0 + bp1) / 2;
    app_mouse(bmx, doc_top() / 2, 0, true, 0);   // pane 1's banner
    app_mouse(bmx, doc_top() / 2, 0, false, 0);
    g_checks++;
    if ed_pane_active() != 1 || cur_line != 5 {
        print("FAIL a banner click must focus its pane without moving the caret (active {} line {})\n",
            ed_pane_active(), cur_line);
        g_fails++;
    }
    while ed_pane_count() > 1 { ignore ed_pane_close(); }
    close_all();

    // --- multi-window: a second window shares the buffer set but keeps
    // its own pane layout and caret; app_use_window swaps between them ---
    close_all();
    tree_on = false;
    ignore ed_open_file("src/pick.mc");
    i32 wbuf = ed_buf_active();
    cur_line = 4;
    cur_col = 0;
    tt_dirty_stack();
    i32 w1 = ed_window_new(wbuf);
    g_checks++;
    // its pane is a document pane, and every pane is one kind or
    // the other: a record left half set is a pane the searches for
    // a document pane walk past, which cost the build pane its own
    if ed_pane_kind(0) != PANE_DOC {
        print("FAIL a new window opens on a document pane (kind {})\n",
            ed_pane_kind(0));
        g_fails++;
    }
    g_checks++;
    if w1 != 1 || ed_window_count() != 2 || ed_window_active() != 1 {
        print("FAIL a new window must open and become current (idx {} count {} active {})\n",
            w1, ed_window_count(), ed_window_active());
        g_fails++;
    }
    g_checks++;
    if !str_equal(str_from(&g_path[0], g_path_len), "src/pick.mc") || cur_line != 0 {
        print("FAIL the new window shows the given buffer at its own caret (path {} line {})\n",
            str_from(&g_path[0], g_path_len), cur_line);
        g_fails++;
    }
    cur_line = 9;
    cur_col = 0;
    i64 len_before = tb_len();
    app_char('X');   // an edit in window 1, into the shared buffer
    i64 len_after = tb_len();
    app_use_window(0);
    g_checks++;
    if ed_window_active() != 0 {
        print("FAIL app_use_window must switch back (active {})\n", ed_window_active());
        g_fails++;
    }
    g_checks++;
    if !str_equal(str_from(&g_path[0], g_path_len), "src/pick.mc") || cur_line != 4 {
        print("FAIL window 0 must keep its own file and caret (path {} line {})\n",
            str_from(&g_path[0], g_path_len), cur_line);
        g_fails++;
    }
    g_checks++;
    if tb_len() != len_after || len_after == len_before {
        print("FAIL the buffer edit must be shared across windows (before {} after {} now {})\n",
            len_before, len_after, tb_len());
        g_fails++;
    }
    // a split in window 0 must not appear in window 1
    app_key(92, MOD_CTRL);
    g_checks++;
    if ed_pane_count() != 2 {
        print("FAIL window 0 split (panes {})\n", ed_pane_count());
        g_fails++;
    }
    app_use_window(1);
    g_checks++;
    if ed_pane_count() != 1 {
        print("FAIL each window keeps its own pane layout (window 1 panes {})\n", ed_pane_count());
        g_fails++;
    }
    ignore ed_window_close();   // close window 1, back to window 0
    g_checks++;
    if ed_window_count() != 1 || ed_window_active() != 0 || ed_pane_count() != 2 {
        print("FAIL closing a window returns to the other with its layout (count {} active {} panes {})\n",
            ed_window_count(), ed_window_active(), ed_pane_count());
        g_fails++;
    }
    while ed_pane_count() > 1 { ignore ed_pane_close(); }
    close_all();

    // ctrl+k n opens a new window through the platform
    g_winopen_calls = 0;
    app_key('K', MOD_CTRL);
    app_key('N', 0);
    g_checks++;
    if g_winopen_calls != 1 || ed_window_count() != 2 {
        print("FAIL ctrl+k n must open a new window (calls {} count {})\n",
            g_winopen_calls, ed_window_count());
        g_fails++;
    }
    // the chord's letter is swallowed, not typed
    app_char('n');
    g_checks++;
    if tb_len() != 0 {
        print("FAIL the chord letter must not reach the buffer\n");
        g_fails++;
    }
    while ed_window_count() > 1 { ignore ed_window_close(); }
    close_all();

    // ctrl+k n with a split opens a new one-pane window showing the
    // active file and leaves the source window's panes untouched
    ignore ed_open_file("src/pick.mc");
    app_key(92, MOD_CTRL);            // split: 2 panes in window 0
    ignore ed_open_file("src/find.mc"); // active pane -> find.mc
    app_key('K', MOD_CTRL);
    app_key('N', 0);
    g_checks++;
    if ed_window_count() != 2 || ed_window_active() != 1 || ed_pane_count() != 1 {
        print("FAIL a split + ctrl+k n must open a one-pane window (count {} active {} panes {})\n",
            ed_window_count(), ed_window_active(), ed_pane_count());
        g_fails++;
    }
    g_checks++;
    if !str_equal(str_from(&g_path[0], g_path_len), "src/find.mc") {
        print("FAIL the new window must show the active file (path {})\n", str_from(&g_path[0], g_path_len));
        g_fails++;
    }
    app_use_window(0);
    g_checks++;
    if ed_pane_count() != 2 {
        print("FAIL the source window must keep its two panes (panes {})\n", ed_pane_count());
        g_fails++;
    }
    while ed_window_count() > 1 { ignore ed_window_close(); }
    while ed_pane_count() > 1 { ignore ed_pane_close(); }
    close_all();

    // --- the sidebar is per window: a new window opens without it and
    // each toggles independently (slots are index-agnostic) ---
    while ed_window_count() > 1 { ignore ed_window_close(); }
    ignore ed_open_file("src/pick.mc");
    tree_on = true;
    tree_focus = false;
    i32 tw_src = ed_window_active();
    i32 tw_new = ed_window_new(ed_buf_active());
    g_checks++;
    if tw_new == tw_src || tree_on {
        print("FAIL a new window must open without the sidebar (src {} new {} on {})\n",
            tw_src, tw_new, tree_on);
        g_fails++;
    }
    tree_toggle();   // on in the new window
    g_checks++;
    if !tree_on {
        print("FAIL toggling must show the sidebar in this window\n");
        g_fails++;
    }
    app_use_window(tw_src);
    g_checks++;
    if !tree_on {
        print("FAIL the source window must keep its own sidebar state\n");
        g_fails++;
    }
    tree_toggle();   // off in the source window only
    app_use_window(tw_new);
    g_checks++;
    if !tree_on {
        print("FAIL a toggle in one window must not change the other (new window stays on)\n");
        g_fails++;
    }
    app_use_window(tw_src);
    g_checks++;
    if tree_on {
        print("FAIL the source window's sidebar should be off after its own toggle\n");
        g_fails++;
    }
    // the tree's selection and scroll are per window as well
    tr_scroll = 90;
    tr_sel = 2;
    app_use_window(tw_new);
    g_checks++;
    if tr_scroll == 90 || tr_sel == 2 {
        print("FAIL tree scroll/selection must be per window (got {} {})\n", tr_scroll, tr_sel);
        g_fails++;
    }
    tr_scroll = 300;
    tr_sel = 5;
    app_use_window(tw_src);
    g_checks++;
    if tr_scroll != 90 || tr_sel != 2 {
        print("FAIL the source window must keep its own tree scroll/selection ({} {})\n", tr_scroll, tr_sel);
        g_fails++;
    }
    // a reused window slot must not carry an old window's sidebar on.
    // wa gets its sidebar toggled on and parked (via the switch to wb),
    // then both close, freeing wa's slot with tree_on saved true; the
    // next new window reuses the lowest free slot (wa's) and must be off.
    while ed_window_count() > 1 { ignore ed_window_close(); }
    i32 wa2 = ed_window_new(ed_buf_active());
    tree_toggle();                            // sidebar on in wa (live)
    i32 wb3 = ed_window_new(ed_buf_active());   // win_save parks wa on=true
    ignore wb3;
    ignore ed_window_close();                 // close wb
    app_use_window(wa2);
    ignore ed_window_close();                 // close wa (slot free, on=true stale)
    ignore ed_window_new(ed_buf_active());     // reuses wa's slot
    g_checks++;
    if tree_on {
        print("FAIL a reused window slot must open without the sidebar\n");
        g_fails++;
    }
    while ed_window_count() > 1 { ignore ed_window_close(); }
    tree_on = true;
    tree_focus = false;
    close_all();

    // --- git decorations: the tree's status from the worker, one state
    // per path, a folder holding the strongest of what is under it ---
    close_all();
    g_status_calls = 0;
    git_status_touch();
    app_settle();
    g_checks++;
    if g_status_calls != 1 || !git_dec_have() || git_dec_count() == 0 {
        print("FAIL a status touch must run git once and land (calls {} have {} n {})\n",
            g_status_calls, git_dec_have(), git_dec_count());
        g_fails++;
    }
    g_checks++;
    if git_dec_state("src/pick.mc") != DEC_MOD || git_dec_state("src/new.mc") != DEC_UNTRACKED
        || git_dec_state("lib/added.mc") != DEC_ADD || git_dec_state("gone.mc") != DEC_DEL
        || git_dec_state("new2.mc") != DEC_RENAME || git_dec_state("merge.mc") != DEC_CONFLICT {
        print("FAIL each status record must map to its state ({} {} {} {} {} {})\n",
            git_dec_state("src/pick.mc"), git_dec_state("src/new.mc"), git_dec_state("lib/added.mc"),
            git_dec_state("gone.mc"), git_dec_state("new2.mc"), git_dec_state("merge.mc"));
        g_fails++;
    }
    g_checks++;
    if git_dec_state("old.mc") != DEC_NONE || git_dec_state("build/x") != DEC_NONE
        || git_dec_state("junk") != DEC_NONE || git_dec_state("README.md") != DEC_NONE
        || git_dec_state("src/pick.m") != DEC_NONE {
        print("FAIL a rename's old name, an ignored entry, junk and a clean file must have no state\n");
        g_fails++;
    }
    g_checks++;
    if git_dec_state("src") != DEC_UNTRACKED || git_dec_state("lib") != DEC_ADD
        || git_dec_state("src\\pick.mc") != DEC_MOD {
        print("FAIL a folder must take the strongest state under it, and a backslash path must match ({} {} {})\n",
            git_dec_state("src"), git_dec_state("lib"), git_dec_state("src\\pick.mc"));
        g_fails++;
    }
    // the same records as a list: what the changes view shows. The
    // table answers for a path, which cannot be enumerated.
    g_checks++;
    if git_changed_count() != 8 || !git_changed_ready() {
        print("FAIL every changed record must reach the list ({} of 8)\n", git_changed_count());
        g_fails++;
    } else if !str_equal(git_changed_path(0), "src/pick.mc")
        || git_changed_state(0) != DEC_MOD
        || !str_equal(git_changed_path(1), "src/new.mc")
        || git_changed_state(1) != DEC_UNTRACKED
        || !str_equal(git_changed_path(2), "lib/added.mc")
        || git_changed_state(2) != DEC_ADD
        || !str_equal(git_changed_path(5), "merge.mc")
        || git_changed_state(5) != DEC_CONFLICT {
        print("FAIL the list must keep each path with its state ([{}] [{}] [{}] [{}])\n",
            git_changed_path(0), git_changed_path(1), git_changed_path(2), git_changed_path(5));
        g_fails++;
    }
    // a rename's old name, an ignored entry and junk are not files in it
    g_checks++;
    if !str_equal(git_changed_path(3), "gone.mc") || !str_equal(git_changed_path(4), "new2.mc")
        || git_changed_path(8).len != 0 || git_changed_path(-1).len != 0 {
        print("FAIL the list must hold only real records ([{}] [{}] [{}])\n",
            git_changed_path(3), git_changed_path(4), git_changed_path(8));
        g_fails++;
    }
    // The two porcelain columns say different things: what is staged
    // for the next commit, and what is changed since. A record with
    // both is in the list twice, once under each.
    g_checks++;
    if git_changed_staged(0) || !git_changed_staged(2) || git_changed_staged(1)
        || !git_changed_staged(4) || git_changed_staged(5) {
        print("FAIL each entry must carry the column it came from\n");
        g_fails++;
    }
    g_checks++;
    if !str_equal(git_changed_path(6), "both.mc") || !git_changed_staged(6)
        || git_changed_state(6) != DEC_MOD
        || !str_equal(git_changed_path(7), "both.mc") || git_changed_staged(7)
        || git_changed_state(7) != DEC_MOD {
        print("FAIL a record in both columns must be in the list twice ([{}] {} [{}] {})\n",
            git_changed_path(6), git_changed_staged(6),
            git_changed_path(7), git_changed_staged(7));
        g_fails++;
    }
    g_checks++;
    if !str_equal(git_dec_badge(DEC_MOD), "M") || !str_equal(git_dec_badge(DEC_UNTRACKED), "U")
        || !str_equal(git_dec_badge(DEC_ADD), "A") || !str_equal(git_dec_badge(DEC_DEL), "D")
        || !str_equal(git_dec_badge(DEC_RENAME), "R") || !str_equal(git_dec_badge(DEC_CONFLICT), "C")
        || git_dec_badge(DEC_NONE).len != 0 {
        print("FAIL the badges must be the reference's letters\n");
        g_fails++;
    }
    // a save asks again; asks while one runs coalesce into one more
    test_remove("build/dec_tmp.mc");
    ignore ed_open_file("build/dec_tmp.mc");
    app_settle();   // the open's baseline fetch, out of the way
    app_char('x');
    g_status_calls = 0;
    app_key('S', MOD_CTRL);
    app_settle();
    g_checks++;
    if g_status_calls != 1 {
        print("FAIL a save must refresh the status once (calls {})\n", g_status_calls);
        g_fails++;
    }
    // asks while one runs coalesce into one more run
    g_status_calls = 0;
    git_status_touch();
    git_status_touch();
    git_status_touch();
    app_settle();
    g_checks++;
    if g_status_calls != 2 {
        print("FAIL asks made while a run is in flight must coalesce into one more (calls {})\n", g_status_calls);
        g_fails++;
    }
    app_key('W', MOD_CTRL);
    test_remove("build/dec_tmp.mc");
    // a folder switch finds the repo again and starts from no decorations
    g_probe_calls = 0;
    ignore ed_open_folder("build");
    g_checks++;
    if git_dec_have() && git_dec_count() != 0 {
        print("FAIL the old tree's decorations must go on a switch\n");
        g_fails++;
    }
    app_settle();
    g_checks++;
    if g_probe_calls < 1 || git_dec_count() == 0 {
        print("FAIL the switch must probe the repo again and decorate the new tree (probes {} n {})\n",
            g_probe_calls, git_dec_count());
        g_fails++;
    }
    g_chdir_last_len = 0;
    close_all();

    // --- the platform's folder dialog: asked for on the chord when the
    // platform has one, the choice delivered through app_folder_picked,
    // an unsaved buffer refuses before the dialog opens ---
    g_pick_native = true;
    g_pick_asks = 0;
    app_key('K', MOD_CTRL);
    app_key('O', MOD_CTRL);
    g_checks++;
    if g_pick_asks != 1 || ask_on {
        print("FAIL the chord must ask the platform for its dialog (asks {} line {})\n", g_pick_asks, ask_on);
        g_fails++;
    }
    ignore ed_open_file("src/pick.mc");
    g_chdir_last_len = 0;
    str none = "";
    app_folder_picked(none.data, 0);
    g_checks++;
    if g_chdir_last_len != 0 || ed_buf_count() != 1 || !g_has_path {
        print("FAIL a cancelled dialog must change nothing\n");
        g_fails++;
    }
    tree_on = false;
    str picked = "build";
    app_folder_picked(picked.data, picked.len);
    g_checks++;
    if !str_equal(str_from(&g_chdir_last[0], g_chdir_last_len), "build")
        || ed_buf_count() != 1 || g_has_path || !tree_on
        || !str_equal(ed_title(), "untitled \xE2\x80\x94 build") {
        print("FAIL the dialog's choice must open the folder (chdir [{}] bufs {} path {} tree {} title [{}])\n",
            str_from(&g_chdir_last[0], g_chdir_last_len), ed_buf_count(), g_has_path, tree_on, ed_title());
        g_fails++;
    }
    ignore ed_open_file("src/pick.mc");
    str bad = "build/nowhere";
    app_folder_picked(bad.data, bad.len);
    g_checks++;
    if ed_buf_count() != 1 || !g_has_path {
        print("FAIL a choice that is not a folder must leave the buffers alone\n");
        g_fails++;
    }
    // unsaved: the dialog is not asked for at all
    app_char('x');
    g_pick_asks = 0;
    app_key('K', MOD_CTRL);
    app_key('O', MOD_CTRL);
    g_checks++;
    if g_pick_asks != 0 || ask_on {
        print("FAIL an unsaved buffer must refuse before the dialog opens\n");
        g_fails++;
    }
    app_key('W', MOD_CTRL);
    app_key('W', MOD_CTRL);
    g_pick_native = false;
    g_chdir_last_len = 0;
    close_all();

    when !os(wasm) {   // the build runs a subprocess and needs build.mc; path_exists has no wasm arm
        // --- build: ctrl+shift+b runs the project's build in a terminal
        // pane of its own, the focus stays with the work, the problems
        // are parsed as the bytes arrive, and F8 walks them ---
        close_all();
        term_threaded = false;
        app_key('B', MOD_CTRL | MOD_SHIFT);
        g_checks++;
        if ed_pane_count() != 2 || ed_build_pane() != 1 || ed_term_active() >= 0
            || ed_pane_active() != 0 || !build_is_running() {
            print("FAIL a build must open its pane beside the work and leave the focus ({} panes, build pane {}, active {})\n",
                ed_pane_count(), ed_build_pane(), ed_pane_active());
            g_fails++;
        }
        app_settle();
        g_checks++;
        if build_is_running() || build_problem_count() != 3 || build_error_count() != 2
            || !str_equal(build_header(), "2 errors, 1 warnings") {
            print("FAIL a build must land in the pane ({} problems, {} errors, header [{}])\n",
                build_problem_count(), build_error_count(), build_header());
            g_fails++;
        }
        // the pane's grid holds the output as the compiler printed it
        u8[256] rowb;
        i32 rn = term_row_text(build_term(), 0, &rowb[0], 256);
        g_checks++;
        if !str_equal(str_from(&rowb[0], rn), "src/pick.mc:3:5: error: boom one") {
            print("FAIL the build pane must show the compiler's first line: [{}]\n", str_from(&rowb[0], rn));
            g_fails++;
        }
        app_key(K_F8, 0);
        g_checks++;
        if !str_equal(ed_path(), "src/pick.mc") || cur_line != 2 || cur_col != 4 {
            print("FAIL F8 must open the first problem at its position ({} {}:{})\n",
                ed_path(), cur_line, cur_col);
            g_fails++;
        }
        app_key(K_F8, 0);   // the warning names a file that is not there
        app_key(K_F8, 0);
        g_checks++;
        if !str_equal(ed_path(), "src/find.mc") || cur_line != 6 || cur_col != 0 || build_current() != 2 {
            print("FAIL F8 must walk on to the third problem ({} {}:{} cur {})\n",
                ed_path(), cur_line, cur_col, build_current());
            g_fails++;
        }
        app_key(K_F8, MOD_SHIFT);
        g_checks++;
        if build_current() != 1 {
            print("FAIL shift+F8 must walk back ({})\n", build_current());
            g_fails++;
        }
        // the build pane is under the column, across the editor, and not
        // one of the columns Ctrl+1..3 address
        i32 bpx0 = 0;
        i32 bpx1 = 0;
        ed_pane_rect(ed_build_pane(), &bpx0, &bpx1);
        g_checks++;
        if !pane_is_bottom(ed_build_pane()) || pane_cols() != 1 || bpx0 != content_left() || bpx1 != g_w
            || ed_pane_y0(ed_build_pane()) <= 0 || ed_pane_y1(0) != ed_pane_y0(ed_build_pane()) {
            print("FAIL the build pane must lie under the columns, across the editor (x {}..{}, top {}, column bottom {})\n",
                bpx0, bpx1, ed_pane_y0(ed_build_pane()), ed_pane_y1(0));
            g_fails++;
        }
        app_key('2', MOD_CTRL);
        g_checks++;
        if ed_pane_active() != 0 {
            print("FAIL ctrl+2 must not focus the build pane under a lone column (pane {})\n", ed_pane_active());
            g_fails++;
        }
        // a window too short for both minimums still gives the column a
        // height of its own
        i32 bw_w = g_w;
        i32 bw_h = g_h;
        app_resize(bw_w, font_line_h * 6);
        g_checks++;
        if ed_pane_y1(0) <= 0 || ed_pane_y0(ed_build_pane()) != ed_pane_y1(0)
            || ed_pane_y1(ed_build_pane()) <= ed_pane_y0(ed_build_pane()) {
            print("FAIL a short window must keep height for the column and the build pane (column to {}, build {}..{})\n",
                ed_pane_y1(0), ed_pane_y0(ed_build_pane()), ed_pane_y1(ed_build_pane()));
            g_fails++;
        }
        app_resize(bw_w, bw_h);
        // the walk from the build pane itself lands in the column above
        // it, the output staying on screen
        ed_pane_focus(ed_build_pane());
        app_key(K_F8, MOD_SHIFT);
        g_checks++;
        if ed_pane_active() != 0 || ed_build_pane() != 1 || ed_pane_count() != 2
            || !str_equal(ed_path(), "src/pick.mc") || build_current() != 0 {
            print("FAIL F8 from the build pane must open in the document pane beside it (pane {} of {}, build pane {})\n",
                ed_pane_active(), ed_pane_count(), ed_build_pane());
            g_fails++;
        }
        // a click on a problem row of the build pane opens its place too:
        // the row that starts with the third problem's path (the grid may
        // wrap the longer lines above it)
        i32 bx0 = 0;
        i32 bx1 = 0;
        ed_pane_rect(ed_build_pane(), &bx0, &bx1);
        i32 crow = -1;
        for i32 r = 0; r < term_rows(build_term()) && crow < 0; r++ {
            i32 tn = term_row_text(build_term(), r, &rowb[0], 256);
            if tn > 12 && str_equal(str_from(&rowb[0], 12), "src/find.mc:") { crow = r; }
        }
        if crow < 0 { crow = 4; }
        if notice_on { ed_notice_close(); }   // the missing file's notice would take the click
        i32 by0 = pane_doc_top(ed_build_pane());
        app_mouse(bx0 + (bx1 - bx0) / 2, by0 + crow * font_line_h + 2, 0, true, 0);
        app_mouse(bx0 + (bx1 - bx0) / 2, by0 + crow * font_line_h + 2, 0, false, 0);
        g_checks++;
        if !str_equal(ed_path(), "src/find.mc") || cur_line != 6 || build_current() != 2 || ed_term_active() >= 0 {
            print("FAIL a click on a problem row must open it ({} {} cur {}; row {} of a {}x{} grid)\n",
                ed_path(), cur_line, build_current(), crow, term_cols(build_term()), term_rows(build_term()));
            for i32 r = 0; r < term_rows(build_term()); r++ {
                i32 tn = term_row_text(build_term(), r, &rowb[0], 256);
                print("  row {}: [{}]\n", r, str_from(&rowb[0], tn));
            }
            g_fails++;
        }
        // a second build reuses the pane and clears the old output first
        i32 bt0 = build_term();
        app_key('B', MOD_CTRL | MOD_SHIFT);
        g_checks++;
        if ed_pane_count() != 2 || ed_build_pane() != 1 || build_line_count() != 0 || build_problem_count() != 0 {
            print("FAIL a new build must reuse the pane and clear the old output ({} panes, {} lines)\n",
                ed_pane_count(), build_line_count());
            g_fails++;
        }
        app_settle();
        g_checks++;
        if build_problem_count() != 3 || build_term() < 0 {
            print("FAIL the second build must land like the first ({} problems)\n", build_problem_count());
            g_fails++;
        }
        ignore bt0;
        // ctrl+j hides the build pane, the build kept behind it; the
        // problems stay for the walk, and ctrl+j brings the pane back
        i32 bt1 = build_term();
        app_key('J', MOD_CTRL);
        g_checks++;
        if ed_pane_count() != 1 || ed_build_pane() >= 0 || build_term() != bt1 || !term_has_child(bt1)
            || build_problem_count() != 3 || ed_term_background_count() != 1 {
            print("FAIL ctrl+j must hide the build pane and keep the build ({} panes, term {}, {} problems)\n",
                ed_pane_count(), build_term(), build_problem_count());
            g_fails++;
        }
        app_key(K_F8, 0);
        g_checks++;
        if !str_equal(ed_path(), "src/pick.mc") {
            print("FAIL F8 must still walk with the pane hidden ({})\n", ed_path());
            g_fails++;
        }
        app_key('J', MOD_CTRL);
        g_checks++;
        if ed_pane_count() != 2 || ed_build_pane() != 1 || build_term() != bt1 || ed_term_active() >= 0 {
            print("FAIL ctrl+j must bring the build pane back beside the work ({} panes, build pane {})\n",
                ed_pane_count(), ed_build_pane());
            g_fails++;
        }
        // a build started while the pane is hidden opens it again
        app_key('J', MOD_CTRL);
        app_key('B', MOD_CTRL | MOD_SHIFT);
        app_settle();
        g_checks++;
        // (the handle may be the old one's number again: the stub hands
        // out the first free slot)
        if ed_pane_count() != 2 || ed_build_pane() != 1 || build_is_running()
            || build_problem_count() != 3 || ed_term_background_count() != 0 {
            print("FAIL a build with the pane hidden must open it with the new run ({} panes, term {})\n",
                ed_pane_count(), build_term());
            g_fails++;
        }
        // ctrl+w on the build pane lets the build go, and the pane with it:
        // it holds the run and nothing else
        app_key('B', MOD_CTRL | MOD_SHIFT);
        app_settle();
        ed_pane_focus(ed_build_pane());
        app_key('W', MOD_CTRL);
        g_checks++;
        if ed_pane_count() != 1 || build_term() >= 0 || ed_pane_active() != 0 {
            print("FAIL ctrl+w on the build pane must let the build go with its pane ({} panes, term {}, active {})\n",
                ed_pane_count(), build_term(), ed_pane_active());
            g_fails++;
        }
        // ctrl+shift+w on the last column closes the build pane under it,
        // the column staying
        app_key('B', MOD_CTRL | MOD_SHIFT);
        app_settle();
        app_key('W', MOD_CTRL | MOD_SHIFT);
        g_checks++;
        if ed_pane_count() != 1 || ed_build_pane() >= 0 {
            print("FAIL ctrl+shift+w on the last column must close the build pane under it ({} panes)\n", ed_pane_count());
            g_fails++;
        }

        // F5 runs the project, `minc run`, which is build.mc's run: the
        // working directory here has a build.mc. Any buffer will do.
        close_all();
        ignore ed_open_file("doc/TESTING.md");
        g_minc_run = false;
        g_minc_target_len = 99;
        app_key(K_F5, 0);
        app_settle();
        g_checks++;
        if !g_minc_run || g_minc_target_len != 0 {
            print("FAIL F5 must run the project (run {} target len {})\n",
                cast(i32, g_minc_run), g_minc_target_len);
            g_fails++;
        }
        app_key('J', MOD_CTRL);
        // Ctrl+R (Cmd+R on macOS) is the same command
        close_all();
        ignore ed_open_file("src/find.mc");
        g_minc_run = false;
        g_minc_target_len = 99;
        app_key('R', MOD_CTRL);
        app_settle();
        g_checks++;
        if !g_minc_run || g_minc_target_len != 0 {
            print("FAIL ctrl+r must run the project as F5 does (run {} target len {})\n",
                cast(i32, g_minc_run), g_minc_target_len);
            g_fails++;
        }
        app_key('J', MOD_CTRL);
        // ...and from a focused terminal pane too: Ctrl+R is the run
        // there, not the shell's history search
        close_all();
        ignore ed_open_file("src/find.mc");
        tt_open_term();
        i32 rt = ed_term_active();
        g_minc_run = false;
        g_minc_target_len = 99;
        app_key('R', MOD_CTRL);
        app_settle();
        g_checks++;
        if rt < 0 || !g_minc_run || g_minc_target_len != 0 {
            print("FAIL ctrl+r on a focused terminal must run the project (term {} run {} target len {})\n",
                rt, cast(i32, g_minc_run), g_minc_target_len);
            g_fails++;
        }
        app_key('J', MOD_CTRL);
        // the terminal opened above goes with the rest
        if rt >= 0 && ed_pane_of_term(rt) >= 0 { ed_pane_focus(ed_pane_of_term(rt)); }
        if ed_term_active() == rt { app_key('W', MOD_CTRL); }
        // Shift+F5 and Ctrl+Shift+R run the active .mc file with
        // `minc run <file>`, whatever the build.mc, which is how a sample
        // is run
        close_all();
        ignore ed_open_file("src/pick.mc");
        g_minc_run = false;
        g_minc_target_len = 0;
        app_key(K_F5, MOD_SHIFT);
        app_settle();
        bool f5_file = g_minc_run
            && str_equal(str_from(&g_minc_target[0], g_minc_target_len), "src/pick.mc");
        app_key('J', MOD_CTRL);
        close_all();
        ignore ed_open_file("src/find.mc");
        g_minc_run = false;
        g_minc_target_len = 0;
        app_key('R', MOD_CTRL | MOD_SHIFT);
        app_settle();
        g_checks++;
        if !f5_file || !g_minc_run
            || !str_equal(str_from(&g_minc_target[0], g_minc_target_len), "src/find.mc") {
            print("FAIL shift+f5 and ctrl+shift+r must run the active file (shift+f5 {} target [{}])\n",
                f5_file, str_from(&g_minc_target[0], g_minc_target_len));
            g_fails++;
        }
        app_key('J', MOD_CTRL);
        // A run asked for while one goes: within 10 s of its start it is
        // a double press and dropped; after that the run is stopped and
        // started again. The clock stands still, then jumps. The refusal
        // is a notice, seen with the status bar hidden, and the build
        // pane comes back if it was hidden.
        close_all();
        ignore ed_open_file("src/pick.mc");
        i64 step_run = g_clock_step;
        g_clock_step = 0;
        bool sb_run = g_statusbar_on;
        g_statusbar_on = false;
        i32 mc1 = g_minc_calls;
        app_key(K_F5, MOD_SHIFT);
        app_key('J', MOD_CTRL);   // the run goes on behind the hidden pane
        app_key(K_F5, MOD_SHIFT);
        bool dropped = g_minc_calls == mc1 + 1 && notice_on && notice_kind == NOTICE_INFO && notice_sticky
            && str_contains(str_from(&notice_msg[0], notice_len), "press again in 10 s")
            && ed_build_pane() >= 0;
        g_clock_step = 11000000;
        app_key(K_F5, MOD_SHIFT);
        g_clock_step = step_run;
        g_statusbar_on = sb_run;
        g_checks++;
        // the refusal went; the new run's own message goes by itself
        if !dropped || g_minc_calls != mc1 + 2 || (notice_on && notice_sticky) {
            print("FAIL a second run must be dropped with a notice and restart after 10 s (dropped {} runs {} notice [{}])\n",
                dropped, g_minc_calls - mc1, str_from(&notice_msg[0], notice_len));
            g_fails++;
        }
        app_settle();
        app_key('J', MOD_CTRL);
        // Ctrl+. stops the run at once: the kill ends it, the pane and
        // its output stay, the banner says so. With nothing going it
        // kills nothing.
        close_all();
        ignore ed_open_file("src/pick.mc");
        app_key(K_F5, MOD_SHIFT);
        i32 kills0 = g_term_kills;
        app_key('.', MOD_CTRL);
        app_settle();
        bool stopped = g_term_kills == kills0 + 1 && ed_build_pane() >= 0
            && str_equal(build_header(), "run stopped");
        i32 kills1 = g_term_kills;
        app_key('.', MOD_CTRL);
        g_checks++;
        if !stopped || g_term_kills != kills1 {
            print("FAIL ctrl+. must stop the run and keep its pane (stopped {} header [{}] kills {})\n",
                stopped, build_header(), g_term_kills - kills0);
            g_fails++;
        }
        app_key('J', MOD_CTRL);
        // Shift+F5 on a buffer that is not a .mc file runs nothing
        close_all();
        ignore ed_open_file("doc/TESTING.md");
        i32 mc0 = g_minc_calls;
        app_key(K_F5, MOD_SHIFT);
        app_settle();
        g_checks++;
        if g_minc_calls != mc0 {
            print("FAIL shift+f5 on a non-.mc buffer must not run anything\n");
            g_fails++;
        }
        app_key('J', MOD_CTRL);
        close_all();
    }
    // the compiler colors its output; the parser keeps the text only,
    // and a color sequence cut by a read boundary still goes
    u8[64] cb;
    i32 cn2 = 0;
    str c1 = "src/x.mc:1:1: ";
    memcpy(&cb[cn2], c1.data, c1.len);
    cn2 += c1.len;
    cb[cn2] = 27;
    cb[cn2 + 1] = '[';
    cb[cn2 + 2] = '1';
    cb[cn2 + 3] = ';';
    cb[cn2 + 4] = '3';
    cb[cn2 + 5] = '1';
    cb[cn2 + 6] = 'm';
    cn2 += 7;
    str c2 = "error: e";
    memcpy(&cb[cn2], c2.data, c2.len);
    cn2 += c2.len;
    cb[cn2] = 27;
    cb[cn2 + 1] = '[';
    cb[cn2 + 2] = '0';
    cb[cn2 + 3] = 'm';
    cn2 += 4;
    cb[cn2] = 10;
    cn2++;
    i32 cut = c1.len + 3;   // inside the first color sequence
    i32 l0 = build_line_count();
    i32 p0 = build_problem_count();
    build_feed(&cb[0], cut);
    build_feed(&cb[cut], cn2 - cut);
    build_finish(1);
    g_checks++;
    if !str_equal(build_line(l0), "src/x.mc:1:1: error: e") || build_problem_count() != p0 + 1 {
        print("FAIL colors must be stripped from the output: [{}] ({} problems, had {})\n",
            build_line(l0), build_problem_count(), p0);
        g_fails++;
    }
    // MSVC's form, with and without the column, and a fatal error;
    // a command-line warning has no place and is not one
    str ms = "C:\\w\\src\\pick.mc(3,5): error C2065: 'x': undeclared identifier\nsrc/find.mc(7): warning C4244: conversion\nsrc/x.c:2:1: fatal error: 'nope.h' file not found\ncl : Command line warning D9002: ignoring\n";
    i32 mp0 = build_problem_count();
    i32 me0 = build_error_count();
    build_feed(ms.data, cast(i64, ms.len));
    build_finish(1);
    g_checks++;
    if build_problem_count() != mp0 + 3 || build_error_count() != me0 + 2 {
        print("FAIL msvc and fatal errors must parse ({} problems, had {})\n",
            build_problem_count(), mp0);
        g_fails++;
    }
    close_all();
    test_build_c();

    // --- the script player feeds a recorded run through the entries ---
    // A hand-made script: q typed, a step mark, Left, a step mark. Each
    // play_step plays one step; the third finds the end.
    close_all();
    u8[32] sc2;
    i32 sn2 = 0;
    sc2[sn2] = EV_CHAR;
    sn2++;
    sn2 = sc_put32(&sc2[0], sn2, 'q');
    sc2[sn2] = EV_STEP;
    sn2++;
    sc2[sn2] = EV_KEY;
    sn2++;
    sn2 = sc_put32(&sc2[0], sn2, K_LEFT);
    sn2 = sc_put32(&sc2[0], sn2, 0);
    sc2[sn2] = EV_STEP;
    sn2++;
    play_load(&sc2[0], sn2);
    bool s1 = play_step();
    g_checks++;
    if !s1 || tb_len() != 1 || cur_col != 1 {
        print("FAIL play step 1: ran {} len {} col {}\n", s1, tb_len(), cur_col);
        g_fails++;
    }
    bool s2 = play_step();
    g_checks++;
    if !s2 || cur_col != 0 {
        print("FAIL play step 2: ran {} col {}\n", s2, cur_col);
        g_fails++;
    }
    g_checks++;
    if play_step() || play_active() {
        print("FAIL the player must stop at the end of the script\n");
        g_fails++;
    }
    // a script that opens with the run's resize tells the driver its
    // size; one that does not, does not
    g_checks++;
    i32 pw = 0;
    i32 ph = 0;
    if play_start_size(&pw, &ph) {
        print("FAIL a script without an opening resize has no start size\n");
        g_fails++;
    }
    u8[16] rs;
    i32 rn2 = 0;
    rs[rn2] = EV_RESIZE;
    rn2++;
    rn2 = sc_put32(&rs[0], rn2, 1920);
    rn2 = sc_put32(&rs[0], rn2, 1050);
    rs[rn2] = EV_STEP;
    rn2++;
    play_load(&rs[0], rn2);
    g_checks++;
    if !play_start_size(&pw, &ph) || pw != 1920 || ph != 1050 {
        print("FAIL the opening resize must be the start size ({}x{})\n", pw, ph);
        g_fails++;
    }
    // the play timer is the driver's: it plays a step and reports
    // itself handled; any other id is not its business
    play_load(&sc2[0], sn2);
    g_checks++;
    if !play_timer(PLAY_TIMER) || tb_len() != 2 || play_timer(GIT_TIMER) {
        print("FAIL play_timer: len {}\n", tb_len());
        g_fails++;
    }
    // and none of the core timers is: a driver routes every timer
    // through play_timer first, so an id it claimed would be killed
    // there instead of reaching app_timer. An id shared with
    // SEM_TIMER is what kept the semantic tokens from arriving.
    g_checks++;
    if play_timer(LSP_SYNC_TIMER) || play_timer(HOVER_TIMER) || play_timer(CMP_TIMER)
        || play_timer(GIT_TIMER) || play_timer(SEM_TIMER) {
        print("FAIL play_timer must claim none of the core timer ids\n");
        g_fails++;
    }
    close_all();

    // and the editor still edits after all that. Measured as
    // a delta: which buffer is active here depends on what the blocks
    // above left open, and the point is that typing still lands.
    i32 was = line_bytes(cur_line);
    app_char('x');
    g_checks++;
    if !tb.dirty || line_bytes(cur_line) != was + 1 {
        print("FAIL editing at the buffer limit: dirty={} bytes {} -> {}\n", tb.dirty, was, line_bytes(cur_line));
        g_fails++;
    }

    // --- a second open while the first fetch is in flight ---
    // Opening a file must never wait for git, so a request made while a
    // worker is running is queued rather than joined. The queued one
    // still has to happen: the file being looked at is the one that
    // needs the baseline.
    ignore ed_open_file("src/find.mc");
    ignore ed_open_file("src/tree.mc");
    app_settle();
    g_checks++;
    if !git_on() || git_mark_count() != tb.nlines {
        print("FAIL the file opened last must end up with the baseline: on={} marks={} lines={}\n",
            cast(i32, git_on()), git_mark_count(), tb.nlines);
        g_fails++;
    }
    // give the slots back: the blocks below need room in the table
    app_key('W', MOD_CTRL);   // both clean, so one close each
    app_key('W', MOD_CTRL);

    // --- saving runs no subprocess ---
    // HEAD does not move when a file is saved, so the gutter needs
    // nothing from git here. Fetching on save would put a process
    // spawn, and a wait on the one already in flight, on every Ctrl+S.
    // Ctrl+S writes to disk, so this must be certain of what it is
    // about to overwrite: if the scratch file could not be opened the
    // active buffer is somebody else's source, and pressing save then
    // destroys it. It did once.
    bool save_ok = ed_open_file("build/ed_test_save.tmp");
    app_settle();          // the open's fetch runs on a worker: count it first
    str save_path = "build/ed_test_save.tmp";
    g_checks++;
    if !save_ok || !g_has_path
        || !str_equal(str_from(&g_path[0], g_path_len), save_path) {
        print("FAIL the save check could not open its scratch file; not saving\n");
        g_fails++;
    } else {
        app_key('A', MOD_CTRL);
        app_char('q');     // whatever a previous run left, the file is "q"
        i32 runs_before = g_run_calls - g_status_calls;
        app_key('S', MOD_CTRL);
        app_settle();      // a fetch the save started would run on a worker
        g_checks++;
        // the tree's status is the one run a save is allowed: the file's
        // baseline is not fetched again
        if g_run_calls - g_status_calls != runs_before {
            print("FAIL saving must not fetch the baseline: {} extra call(s)\n",
                g_run_calls - g_status_calls - runs_before);
            g_fails++;
        }
        app_key('W', MOD_CTRL);   // saved, so clean: one close, not two
    }
    ignore ed_open_file("src/pick.mc");

    // --- a completion list outliving its buffer ---
    // The list is anchored to a line of the buffer it was asked for.
    // Switching to a shorter buffer used to leave the anchor past the
    // end, and rendering indexed the line table with it.
    ignore ed_open_file("build.mc");
    app_key('A', MOD_CTRL);
    type_text("one\ntwo\nthree\nfour\nfive");   // caret on line 4
    cmp_begin(4, 0, true);
    cmp_add("fivefold", "", 100);
    cmp_end();
    g_checks++;
    if !cmp_on {
        print("FAIL a completion list must open on the caret's line\n");
        g_fails++;
    }
    // Switching away leaves the anchor naming a line of the buffer that
    // is no longer loaded, and rendering indexes the line table with it.
    ignore ed_open_file("src/pick.mc");
    g_checks++;
    if cmp_on {
        print("FAIL a buffer switch must close the completion popup\n");
        g_fails++;
    }
    ignore ed_open_file("build.mc");
    // a reply that matches nothing of the typed prefix never shows the
    // popup, so it must not repaint either
    g_damage_calls = 0;
    cmp_begin(4, 0, true);
    cmp_add("zzz", "", 100);
    cmp_end();
    g_checks++;
    if cmp_on || g_damage_calls != 0 {
        print("FAIL a completion reply that matches nothing must not open or repaint (on {} damages {})\n",
            cmp_on, g_damage_calls);
        g_fails++;
    }
    app_key('W', MOD_CTRL);
    app_key('W', MOD_CTRL);
    ignore ed_open_file("src/pick.mc");

    // --- the change gutter ---
    // These replace the buffer wholesale, so they sit with the other
    // checks that do. One character per line, see check_git.
    check_git("a\nb\nc\n", "a\nb\nc\n", "....", "unchanged file has no marks");
    check_git("a\nb\nc\n", "a\nX\nc\n", ".M..", "one line modified");
    check_git("a\nb\nc\n", "a\nb\nX\nc\n", "..A..", "one line inserted");
    check_git("a\nb\nc\n", "a\nc\n", ".D.", "one line deleted");
    check_git("a\nb\nc\n", "a\n", ".D", "two lines deleted at the end");
    check_git("a\n", "a\nb\nc\n", ".AA.", "two lines appended");
    check_git("", "a\n", "A.", "content added to an empty baseline");
    check_git("a\n", "", "D", "everything deleted");
    check_git("a\nb\nc\n", "X\nb\nY\n", "M.M.", "two separate modifications");
    check_git("a\nb\nc\nd\n", "a\nX\nY\nd\n", ".MM..",
        "a two-line block modified");
    check_git("a\nb\nc\n", "a\nX\nY\nb\nc\n", ".AA...",
        "an insert that keeps both sides");
    // a modification next to a deletion: the shorter side is the
    // modified run, the surplus is what went away
    check_git("a\nb\nc\nd\ne\n", "a\nX\ne\n", ".MD.",
        "three lines replaced by one");
    // A swap has two equally short edit scripts and the walk picks one:
    // 'a' left the top and came back below 'b'. Asserted so a change in
    // the diff shows up here rather than in someone's gutter.
    check_git("a\nb\n", "b\na\n", "DA.", "two lines swapped");
    check_git_model(400);

    // --- the same diffs paired for a side-by-side view ---
    // The gutter collapses both sides onto the buffer's lines; these
    // keep the pairing, so a deleted line has a row of its own.
    check_rows("a\nb\nc\n", "a\nb\nc\n", "....", "rows: unchanged file pairs one to one");
    check_rows("a\nb\nc\n", "a\nX\nc\n", ".M..", "rows: one line modified");
    check_rows("a\nb\nc\n", "a\nb\nX\nc\n", "..A..", "rows: one line inserted");
    check_rows("a\nb\nc\n", "a\nc\n", ".D..", "rows: a deleted line keeps a row");
    check_rows("a\nb\nc\n", "a\n", ".DD.", "rows: two lines deleted at the end");
    check_rows("a\n", "a\nb\nc\n", ".AA.", "rows: two lines appended");
    check_rows("", "a\n", "A.", "rows: content added to an empty baseline");
    check_rows("a\n", "", "D.", "rows: everything deleted");
    check_rows("a\nb\nc\n", "X\nb\nY\n", "M.M.", "rows: two separate modifications");
    check_rows("a\nb\nc\nd\n", "a\nX\nY\nd\n", ".MM..", "rows: a two-line block modified");
    check_rows("a\nb\nc\n", "a\nX\nY\nb\nc\n", ".AA...",
        "rows: an insert that keeps both sides");
    // the shorter side pairs as a modification, the surplus gets rows
    // of its own on the side that has them
    check_rows("a\nb\nc\nd\ne\n", "a\nX\ne\n", ".MDD..",
        "rows: three lines replaced by one");
    // the same script the gutter's swap case describes: 'a' left the
    // top and came back below 'b', so the two sides of it are separate
    // blocks with the matched 'b' between them
    check_rows("a\nb\n", "b\na\n", "D.A.", "rows: two lines swapped");

    // --- the gutter follows an edit on the edit itself ---
    // The buffer's line hashes follow each insert and delete, so the
    // recompute runs synchronously and the marks are right before any
    // timer fires; the harness compares the hashes with a full rehash.
    close_all();
    reset("one\ntwo\nthree\nfour\n");
    str gb = "one\ntwo\nthree\nfour\n";
    git_set_baseline(gb.data, gb.len);
    cur_line = 1;
    cur_col = 0;
    app_char('x');
    g_checks++;
    if git_mark(1) != GIT_MOD || !git_check_cache() {
        print("FAIL typing must mark the line at once (mark {})\n", git_mark(1));
        g_fails++;
    }
    app_char(13);   // "x" alone on line 1, "two" pushed to line 2
    g_checks++;
    if git_mark(1) != GIT_ADD || git_mark(2) != GIT_NONE || !git_check_cache() {
        print("FAIL a split line must mark the new line at once (marks {} {})\n", git_mark(1), git_mark(2));
        g_fails++;
    }
    app_char(8);
    app_char(8);    // back to the baseline
    g_checks++;
    if git_mark(1) != GIT_NONE || git_mark_count() != 5 || !git_check_cache() {
        print("FAIL undoing the edit by hand must clear the marks at once (mark {} count {})\n", git_mark(1), git_mark_count());
        g_fails++;
    }
    // The pairing follows the same edit, which is what lets a diff be
    // typed into: the row the caret is on has to stay the row it is on.
    git_rows_enable(true);
    g_checks++;
    if git_row_count() != 5 || git_row_kind(1) != GIT_NONE {
        print("FAIL an unchanged buffer must pair one to one ({} rows)\n", git_row_count());
        g_fails++;
    }
    cur_line = 1;
    cur_col = 0;
    app_char('x');
    g_checks++;
    if git_row_count() != 5 || git_row_kind(1) != GIT_MOD
        || git_row_a(1) != 1 || git_row_b(1) != 1 || git_row_of_line(1) != 1 {
        print("FAIL typing must pair the changed line at once (rows {} kind {} a {} b {})\n",
            git_row_count(), git_row_kind(1), git_row_a(1), git_row_b(1));
        g_fails++;
    }
    app_char(13);   // the line splits: the new one has nothing to pair with
    g_checks++;
    if git_row_count() != 6 || git_row_kind(1) != GIT_ADD
        || git_row_a(1) != -1 || git_row_b(1) != 1 || git_row_of_line(3) != 3 {
        print("FAIL a split line must take a row of its own (rows {} kind {} a {} b {})\n",
            git_row_count(), git_row_kind(1), git_row_a(1), git_row_b(1));
        g_fails++;
    }
    // the first change is what the view opens on, and there is one
    g_checks++;
    if git_row_next_change(-1) != 1 || git_row_prev_change(git_row_count()) != 1 {
        print("FAIL the changed block must be found from either end ({} {})\n",
            git_row_next_change(-1), git_row_prev_change(git_row_count()));
        g_fails++;
    }
    app_char(8);
    app_char(8);    // back to the baseline again
    g_checks++;
    if git_row_count() != 5 || git_row_next_change(-1) != -1 {
        print("FAIL pairing must go back one to one with the text ({} rows, change at {})\n",
            git_row_count(), git_row_next_change(-1));
        g_fails++;
    }
    git_rows_enable(false);
    close_all();

    // --- the gutter reaches a file shown in a second window ---
    // A baseline fetch lands on whichever window is active when the
    // worker wakes the main thread, which need not be the one that asked:
    // a repaint switches the active window under the worker. The baseline
    // must still reach the buffer that asked, so its gutter appears and
    // an edit there marks the line.
    close_all();
    tree_on = false;
    ignore ed_open_file("src/find.mc");
    app_settle();                              // window 0's baseline lands
    i32 gw0 = ed_window_active();
    i32 gw1 = ed_window_new(ed_buf_active());  // a second window
    ignore ed_open_file("src/pick.mc");        // shown in window 1; fetch starts
    app_use_window(gw0);                        // window 0 is active again when
    app_settle();                              // the fetch for window 1's file lands
    app_use_window(gw1);
    g_checks++;
    if !git_on() || git_mark_count() != tb.nlines {
        print("FAIL a baseline fetched while another window was active must still reach its file (on={} marks={} lines={})\n",
            cast(i32, git_on()), git_mark_count(), tb.nlines);
        g_fails++;
    }
    cur_line = 0;
    cur_col = 0;
    app_char('Z');   // an edit in the second window marks its line at once
    g_checks++;
    if git_mark(0) == GIT_NONE || !git_check_cache() {
        print("FAIL an edit in a second window must mark its line (mark {})\n", git_mark(0));
        g_fails++;
    }
    app_char(8);
    while ed_window_count() > 1 { ignore ed_window_close(); }
    close_all();

    // --- a second view of the same file keeps the gutter in both windows ---
    // The gutter belongs to the buffer, and the buffer is shared, so
    // opening a second window on the same file must not drop it in either.
    close_all();
    tree_on = false;
    ignore ed_open_file("src/find.mc");
    str v2base = "only one line\n";
    git_set_baseline(v2base.data, v2base.len);   // the file differs from this
    g_checks++;
    if !git_on() || git_mark_count() != tb.nlines {
        print("FAIL setup: the file must have a gutter before the second view (on={} marks={} lines={})\n",
            cast(i32, git_on()), git_mark_count(), tb.nlines);
        g_fails++;
    }
    i32 v2buf = ed_buf_active();
    i32 v2w = ed_window_new(v2buf);   // ctrl+k n: a second view of the same file
    g_checks++;
    if !git_on() || git_mark_count() != tb.nlines {
        print("FAIL the second view must keep the gutter (new window on={} marks={} lines={})\n",
            cast(i32, git_on()), git_mark_count(), tb.nlines);
        g_fails++;
    }
    app_use_window(0);
    g_checks++;
    if !git_on() || git_mark_count() != tb.nlines {
        print("FAIL the original window must keep the gutter after a second view (on={} marks={} lines={})\n",
            cast(i32, git_on()), git_mark_count(), tb.nlines);
        g_fails++;
    }
    // close the second view: the first must keep the gutter (git state is
    // parked back into the shared buffer, not freed with the window)
    app_use_window(v2w);
    ignore ed_window_close();
    g_checks++;
    if !git_on() || git_mark_count() != tb.nlines {
        print("FAIL closing a second view must not drop the shared gutter (on={} marks={} lines={})\n",
            cast(i32, git_on()), git_mark_count(), tb.nlines);
        g_fails++;
    }
    while ed_window_count() > 1 { ignore ed_window_close(); }
    close_all();

    // The live sequence Ctrl+K N runs when the session is on (a folder
    // launch): the new window takes focus, so the old one gets a focus-out
    // that saves the session, and the new one a focus-in. The save must not
    // leave the buffer's gutter detached for the focus-in to null out.
    session_set_base("build/edminc_sess_view");
    close_all();
    tree_on = false;
    ignore ed_open_file("src/find.mc");
    str v3base = "only one line\n";
    git_set_baseline(v3base.data, v3base.len);
    session_set_enabled(true);
    i32 v3new = ed_window_new(ed_buf_active());   // ctrl+k n
    app_use_window(0);
    app_focus(false);                              // old window loses focus: session save
    app_use_window(v3new);
    app_focus(true);                               // new window gains focus
    g_checks++;
    if !git_on() || git_mark_count() != tb.nlines {
        print("FAIL a focus-out session save must not drop the shared gutter (on={} marks={} lines={})\n",
            cast(i32, git_on()), git_mark_count(), tb.nlines);
        g_fails++;
    }
    app_use_window(0);
    g_checks++;
    if !git_on() || git_mark_count() != tb.nlines {
        print("FAIL the original window must keep the gutter after the focus dance (on={} marks={} lines={})\n",
            cast(i32, git_on()), git_mark_count(), tb.nlines);
        g_fails++;
    }
    session_set_enabled(false);
    session_set_base(".edminc");
    while ed_window_count() > 1 { ignore ed_window_close(); }
    close_all();

    // --- text_buf model + save/load round trip ---
    // These trash the buffer, so they come after everything that
    // drives the editor.
    check_save_roundtrip("one\ntwo\nthree\n", false, "one\ntwo\nthree\n",
        "lf round trip");
    check_save_roundtrip("one\r\ntwo\r\nthree\r\n", true, "one\ntwo\nthree\n",
        "crlf round trip");
    check_save_roundtrip("no trailing newline", false, "no trailing newline",
        "round trip without a trailing newline");
    check_save_roundtrip("a\r\nbbb", true, "a\nbbb",
        "crlf round trip without a trailing newline");
    check_save_roundtrip("", false, "", "empty file round trip");
    check_text_buf_model(20000);

    // --- stopping the server clears the opened set (a folder switch
    // restarts it, and a stale set would skip the new server's didOpen).
    // Self-contained and last: it stops the captured server. ---
    close_all();
    lsp_on = true;
    tc_lsp_frame("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"positionEncoding\":\"utf-8\",\"textDocumentSync\":{\"change\":2},\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"variable\",\"function\",\"type\",\"property\"],\"tokenModifiers\":[]},\"full\":true}}}}", 10);
    lsp_pump();
    ignore ed_open_file("src/lexer.mc");
    g_checks++;
    if lsp_opened_count() == 0 {
        print("FAIL a fresh open must be in the opened set\n");
        g_fails++;
    }
    lsp_stop();
    g_checks++;
    if lsp_opened_count() != 0 {
        print("FAIL stopping the server must clear the opened set ({} left)\n", lsp_opened_count());
        g_fails++;
    }
    close_all();

    // --- the changes view: the two columns as two foldable groups ---
    close_all();
    tree_on = true;
    git_status_touch();
    app_settle();
    tree_show_changes();
    g_checks++;
    if tree_row_count() != 10 || !tree_row_is_hdr(0) || !tree_row_is_hdr(4)
        || !str_equal(tree_row_path(0), "Staged Changes")
        || !str_equal(tree_row_path(4), "Changes") {
        print("FAIL the changes view must group the two columns ({} rows, [{}] [{}])\n",
            tree_row_count(), tree_row_path(0), tree_row_path(4));
        g_fails++;
    }
    g_checks++;
    if !str_equal(tree_row_path(1), "lib/added.mc")
        || !str_equal(tree_row_path(3), "both.mc")
        || !str_equal(tree_row_path(5), "src/pick.mc")
        || !str_equal(tree_row_path(9), "both.mc") {
        print("FAIL each file must sit under the column it came from ([{}] [{}] [{}] [{}])\n",
            tree_row_path(1), tree_row_path(3), tree_row_path(5), tree_row_path(9));
        g_fails++;
    }
    // a heading folds what is under it, and says so while folded
    tree_row_activate(0);
    g_checks++;
    if tree_row_count() != 7 || !tree_row_is_hdr(0)
        || !str_equal(tree_row_path(1), "Changes") {
        print("FAIL folding a group must leave its heading ({} rows, [{}])\n",
            tree_row_count(), tree_row_path(1));
        g_fails++;
    }
    tree_row_activate(0);
    g_checks++;
    if tree_row_count() != 10 {
        print("FAIL unfolding must bring the group back ({} rows)\n", tree_row_count());
        g_fails++;
    }

    // nothing changed: the columns are still named, so the view says
    // the tree is clean rather than saying nothing at all
    g_status_empty = true;
    git_status_touch();
    app_settle();
    tree_show_changes();
    g_checks++;
    if tree_row_count() != 2 || !tree_row_is_hdr(0) || !tree_row_is_hdr(1)
        || !str_equal(tree_row_path(0), "Staged Changes")
        || !str_equal(tree_row_path(1), "Changes") {
        print("FAIL a clean tree must still show both headings ({} rows, [{}] [{}])\n",
            tree_row_count(), tree_row_path(0), tree_row_path(1));
        g_fails++;
    }
    g_status_empty = false;
    git_status_touch();
    app_settle();
    tree_show_files();
    close_all();

    // --- the diff view: one file in two panes over a shared row space ---
    // The stub's `git show` answers with the file minus every ninth
    // line, so an opened file always has a baseline that differs.
    close_all();
    ignore ed_open_file("src/pick.mc");
    app_settle();                       // the baseline lands
    // the server's tokens for this buffer, before the diff is built:
    // the baseline is filled by inserting a whole file, and that insert
    // must not move them (it did, and the file's colors slid down it)
    sem_begin("src/pick.mc");
    sem_add(5, 0, 3, 2);     // a type on line 5, whatever the lexer says
    ignore sem_end();
    // the same tokens again change nothing on screen; the lsp reply
    // repaints on what sem_end reports
    sem_begin("src/pick.mc");
    sem_add(5, 0, 3, 2);
    bool sem_again = sem_end();
    sem_begin("src/pick.mc");
    sem_add(5, 0, 4, 2);
    bool sem_other = sem_end();
    sem_begin("src/pick.mc");
    sem_add(5, 0, 3, 2);
    ignore sem_end();
    g_checks++;
    if sem_again || !sem_other {
        print("FAIL semantic tokens must report a change only when they differ (same {} other {})\n",
            sem_again, sem_other);
        g_fails++;
    }
    ed_diff_open("src/pick.mc");
    app_settle();                       // and arms the view if it had not
    g_checks++;
    if !ed_diff_on() || ed_pane_count() != 2 || ed_pane_active() != 1 {
        print("FAIL a diff must open as two panes with the file active (on {} panes {} active {})\n",
            ed_diff_on(), ed_pane_count(), ed_pane_active());
        g_fails++;
    }
    g_checks++;
    noinit u8[128] dcls;
    i32 dcn = line_bytes(5);
    if dcn > 3 { dcn = 3; }
    for i32 i = 0; i < dcn; i++ { dcls[i] = LEX_DEF; }
    sem_overlay(5, &dcls[0], dcn);
    if !sem_is_for("src/pick.mc") || dcn < 1 || dcls[0] != LEX_TYPE {
        print("FAIL building the baseline must not move the buffer's tokens (for {} cls {})\n",
            sem_is_for("src/pick.mc"), cast(i32, dcls[0]));
        g_fails++;
    }
    // the rows cover both sides, and every line of each has one
    g_checks++;
    if ed_row_count() != git_row_count() || git_row_count() < tb.nlines
        || git_row_count() < git_base_lines() {
        print("FAIL the row space must hold both sides ({} rows, {} lines, {} baseline)\n",
            git_row_count(), tb.nlines, git_base_lines());
        g_fails++;
    }
    // it opens on the first change rather than at the top
    g_checks++;
    i32 first = git_row_next_change(-1);
    if first <= 0 || ed_row_of_line(cur_line) < first {
        print("FAIL a diff must open on the first change (row {}, caret row {})\n",
            first, ed_row_of_line(cur_line));
        g_fails++;
    }
    // the baseline side's text selects and copies, the focus staying on
    // the file: a drag across two rows, then the copy chord
    {
        i32 bx0 = 0;
        i32 bx1 = 0;
        ed_pane_rect(0, &bx0, &bx1);
        i32 bxm = bx0 + (bx1 - bx0) / 2;
        i32 by = pane_doc_top(0) + font_line_h / 2;
        app_mouse(bxm, by, 0, true, 0);
        app_mouse_move(bxm, by + 2 * font_line_h);
        app_mouse(bxm, by + 2 * font_line_h, 0, false, 0);
        str bs = ed_diff_base_selection();
        g_checks++;
        if bs.len == 0 || ed_pane_active() != 1 || ed_buf_active() < 0 || !ed_diff_on() {
            print("FAIL a drag on the diff's baseline side must select there, the file keeping the focus ([{}], active {})\n",
                bs, ed_pane_active());
            g_fails++;
        }
        app_key('C', MOD_CTRL);
        g_checks++;
        if g_clip == null || !str_equal(str_from(g_clip, cast(i32, g_clip_len)), bs) {
            print("FAIL the copy chord must take the baseline side's selection ([{}])\n", bs);
            g_fails++;
        }
        // a key to the file clears it; the copy chord then copies the file
        app_key(K_RIGHT, 0);
        g_checks++;
        if ed_diff_base_selection().len != 0 {
            print("FAIL a key to the file must clear the baseline side's selection\n");
            g_fails++;
        }
        // three presses select the whole line there, close together and
        // well after the drag's press, so they start a run of their own
        g_clock_us += 1000000;
        g_clock_step = 10000;
        app_mouse(bxm, by, 0, true, 0);
        app_mouse(bxm, by, 0, false, 0);
        app_mouse(bxm, by, 0, true, 0);
        app_mouse(bxm, by, 0, false, 0);
        app_mouse(bxm, by, 0, true, 0);
        app_mouse(bxm, by, 0, false, 0);
        g_clock_step = 500000;
        str bl = ed_diff_base_selection();
        g_checks++;
        if bl.len == 0 || bl.data[bl.len - 1] != 10 {
            print("FAIL a triple click on the baseline side must select its line ([{}])\n", bl);
            g_fails++;
        }
        // a click on the file's side clears it too
        i32 fx0 = 0;
        i32 fx1 = 0;
        ed_pane_rect(1, &fx0, &fx1);
        app_mouse(fx0 + (fx1 - fx0) / 2, by, 0, true, 0);
        app_mouse(fx0 + (fx1 - fx0) / 2, by, 0, false, 0);
        g_checks++;
        if ed_diff_base_selection().len != 0 || ed_pane_active() != 1 {
            print("FAIL a click on the file must clear the baseline side's selection\n");
            g_fails++;
        }
    }
    // the left pane holds the baseline as its own document, and says so
    ed_pane_swap_view(0);
    g_checks++;
    if !ed_diff_base_side() || tb.nlines != git_base_lines() || g_has_path {
        print("FAIL the left pane must be the baseline, with no path ({} lines of {}, path {})\n",
            tb.nlines, git_base_lines(), g_has_path);
        g_fails++;
    }
    // a line on either side sits at the row it was paired into
    i32 probe_a = git_row_a(first);
    i32 probe_b = git_row_b(first);
    ed_pane_swap_view(1);
    g_checks++;
    if (probe_a >= 0 && git_row_of_base(probe_a) != first)
        || (probe_b >= 0 && git_row_of_line(probe_b) != first) {
        print("FAIL both sides must map back to their row\n");
        g_fails++;
    }
    // a click on the baseline leaves the focus on the file
    ed_pane_focus(0);
    g_checks++;
    if ed_pane_active() != 1 {
        print("FAIL the baseline pane must not take the focus (active {})\n", ed_pane_active());
        g_fails++;
    }
    // typing still reaches the file, and the pairing follows it
    i32 rows_before = git_row_count();
    cur_line = 0;
    cur_col = 0;
    app_char('q');
    g_checks++;
    if !ed_diff_on() || git_row_count() < rows_before || git_row_kind(git_row_of_line(0)) == GIT_NONE {
        print("FAIL typing in a diff must re-pair the sides ({} rows, kind {})\n",
            git_row_count(), git_row_kind(git_row_of_line(0)));
        g_fails++;
    }
    // the banner's arrows walk the changes, as F7 does from the keyboard
    i32 nrow = git_row_next_change(ed_row_of_line(cur_line));
    i32 apx0 = 0;
    i32 apx1 = 0;
    ed_pane_rect(1, &apx0, &apx1);
    i32 ahit = -1;
    i32 ax = apx0;
    while ax < apx1 && ahit < 0 {
        ahit = ed_diff_arrow_hit(ax, 0);
        if ahit != 1 { ahit = -1; }
        ax++;
    }
    g_checks++;
    if ahit != 1 {
        print("FAIL the diff banner must carry a next-change arrow\n");
        g_fails++;
    } else {
        // The pointer lights it: through app_hover, which is what a
        // moving pointer reaches. app_mouse_move only runs while a
        // button is held, so tracking a hover there never fired.
        // The banner is chrome, so the cursor stays the plain arrow.
        app_hover(ax - 1, 0, 0);
        g_checks++;
        if ed_diff_arrow_hover() != 1 || app_cursor_kind(ax - 1, 0) != CURSOR_ARROW {
            print("FAIL an arrow must light under the pointer, cursor plain ({} {})\n",
                ed_diff_arrow_hover(), app_cursor_kind(ax - 1, 0));
            g_fails++;
        }
        app_hover(apx0 + 5, 0, 0);
        g_checks++;
        if ed_diff_arrow_hover() >= 0 {
            print("FAIL an arrow must go dark when the pointer leaves it ({})\n",
                ed_diff_arrow_hover());
            g_fails++;
        }
        app_mouse(ax - 1, 0, 0, true, 0);
        app_mouse(ax - 1, 0, 0, false, 0);
        g_checks++;
        if nrow < 0 || ed_row_of_line(cur_line) != nrow {
            print("FAIL the next-change arrow must jump a change (row {} of {})\n",
                ed_row_of_line(cur_line), nrow);
            g_fails++;
        }
        // and it lands in the middle of the view, not merely on screen.
        // Far enough down that the middle is not the top: a change in
        // the first half-screen is centred by being where it already is.
        i32 vis = visible_lines();
        i32 guard = 0;
        while ed_row_of_line(cur_line) < vis && guard < 400 {
            ed_diff_jump(false);
            guard++;
        }
        i32 crow = ed_row_of_line(cur_line);
        i32 want2 = crow - vis / 2;
        if want2 < 0 { want2 = 0; }
        if want2 > ed_row_count() - 1 { want2 = ed_row_count() - 1; }
        g_checks++;
        if top_line != want2 {
            print("FAIL a change must be centred (row {} top {} want {} of {})\n",
                crow, top_line, want2, vis);
            g_fails++;
        }
    }
    // the primary modifier with the arrows walks the changes too
    i32 kb_at = ed_row_of_line(cur_line);
    i32 kb_next = git_row_next_change(kb_at);
    if kb_next >= 0 {
        app_key(K_DOWN, MOD_CTRL);
        g_checks++;
        if ed_row_of_line(cur_line) != kb_next {
            print("FAIL ctrl+down must walk to the next change (row {} of {})\n",
                ed_row_of_line(cur_line), kb_next);
            g_fails++;
        }
        app_key(K_UP, MOD_CTRL);
        g_checks++;
        if ed_row_of_line(cur_line) > kb_next {
            print("FAIL ctrl+up must walk back (row {}, from {})\n",
                ed_row_of_line(cur_line), kb_next);
            g_fails++;
        }
    }

    // Scrolling moves the view and leaves the caret behind. The next
    // change is then the next one from what is on screen, not from a
    // caret far above it.
    i32 sc_from = git_row_count() / 2;
    i32 sc_want = git_row_next_change(sc_from);
    if sc_want >= 0 {
        cur_line = 0;
        cur_col = 0;
        // the wheel is relative, and the view is already somewhere
        i32 sc_now = top_line * font_line_h + scroll_off;
        app_scroll(0.0f, cast(f32, sc_from * font_line_h - sc_now), apx0 + 5, doc_top() + 5);
        g_checks++;
        if top_line != sc_from {
            print("FAIL the wheel must land the view where asked ({} of {})\n",
                top_line, sc_from);
            g_fails++;
        }
        ed_diff_jump(false);
        g_checks++;
        if ed_row_of_line(cur_line) != sc_want {
            print("FAIL a jump must start from the view, not the caret (row {} of {})\n",
                ed_row_of_line(cur_line), sc_want);
            g_fails++;
        }
    }
    app_char(8);
    // another buffer on screen ends it: the pairing is this file's
    ignore ed_open_file("src/find.mc");
    // and with no diff the chord is not the editor's: the caret stays
    cur_line = 3;
    cur_col = 0;
    app_key(K_DOWN, MOD_CTRL);
    g_checks++;
    if cur_line != 3 {
        print("FAIL ctrl+down outside a diff must not move the caret (line {})\n", cur_line);
        g_fails++;
    }
    g_checks++;
    if ed_diff_on() || ed_pane_count() != 1 {
        print("FAIL opening another buffer must end the diff ({} panes)\n", ed_pane_count());
        g_fails++;
    }
    ed_diff_close();
    // and again: a second open must not hold anything the first did
    ed_diff_open("src/pick.mc");
    app_settle();
    g_checks++;
    if !ed_diff_on() || ed_pane_count() != 2 {
        print("FAIL a diff must open again after it was closed ({} panes)\n", ed_pane_count());
        g_fails++;
    }
    ed_diff_close();
    g_checks++;
    if ed_diff_on() || ed_pane_count() != 1 || git_row_count() != 0 {
        print("FAIL closing a diff must leave one pane and no rows ({} panes, {} rows)\n",
            ed_pane_count(), git_row_count());
        g_fails++;
    }
    // A wide edit recomputes the rows on the gutter's timer, so until it
    // fires the rows can name lines the edit removed. No row may map to a
    // line the buffer does not have: the view drew such a row past the end.
    // src/ed.mc is large enough that its diff spans past the size the
    // gutter recomputes on the edit, so the rows wait for the timer.
    close_all();
    ed_diff_open("src/ed.mc");
    app_settle();
    app_key(K_END, MOD_CTRL);
    for i32 k = 0; k < 3; k++ { app_key('K', MOD_CTRL | MOD_SHIFT); }
    i32 st_bad = -1;
    for i32 r = 0; r < ed_row_count(); r++ {
        if ed_line_of_row(r) >= tb.nlines { st_bad = r; break; }
    }
    g_checks++;
    if !ed_diff_on() || st_bad >= 0 {
        print("FAIL a row must not map past the buffer before the rows are recomputed (row {}, {} lines, diff {})\n",
            st_bad, tb.nlines, ed_diff_on());
        g_fails++;
    }
    close_all();
    test_diff_revert();
    // Ctrl+W in the file's pane closes the file: the diff ends first,
    // while the buffer is still loaded, and its pane goes with it. The
    // checks above typed into the file, so it starts from a clean open.
    close_all();
    ed_diff_open("src/pick.mc");
    app_settle();
    app_key('W', MOD_CTRL);
    g_checks++;
    if ed_diff_on() || ed_pane_count() != 1 || wt_buf_titled("pick.mc") >= 0 {
        print("FAIL ctrl+w in the diff's file pane must end the diff and close the file ({} panes, diff {})\n",
            ed_pane_count(), ed_diff_on());
        g_fails++;
    }
    // the same file split into a third pane and closed from there: the
    // diff's pane still shows it, so only the third pane's view goes
    ed_diff_open("src/pick.mc");
    app_settle();
    app_key(92, MOD_CTRL);
    app_key('W', MOD_CTRL);
    g_checks++;
    if !ed_diff_on() || wt_buf_titled("pick.mc") < 0
        || ed_pane_active() < 0 || ed_pane_active() >= ed_pane_count() {
        print("FAIL closing the diff's file from a third pane must leave the diff (diff {}, {} panes, active {})\n",
            ed_diff_on(), ed_pane_count(), ed_pane_active());
        g_fails++;
    }
    close_all();
    // Ctrl+Shift+W in the file's pane: the pane to its left is the
    // baseline, which has no buffer slot to take the focus with. The
    // diff ends and its pane goes; the file stays open.
    ed_diff_open("src/pick.mc");
    app_settle();
    app_key('W', MOD_CTRL | MOD_SHIFT);
    g_checks++;
    if ed_diff_on() || ed_pane_count() != 1 || !str_equal(ed_path(), "src/pick.mc") {
        print("FAIL closing the diff's file pane must end the diff and keep the file ({} panes, {})\n",
            ed_pane_count(), ed_path());
        g_fails++;
    }
    close_all();

    // --- the diff borrows the panes that are there: two are used as
    // they stand, a third is left alone, and the left one comes back ---
    close_all();
    ignore ed_open_file("doc/TESTING.md");
    app_key(92, MOD_CTRL);          // two panes, the file in the second
    ignore ed_open_file("README.md");
    i32 dp_x0 = 0;
    i32 dp_x1 = 0;
    ed_pane_rect(0, &dp_x0, &dp_x1);
    i32 dp_left = ed_pane_buf(0);
    ed_diff_open("src/pick.mc");
    app_settle();
    i32 dp_ax0 = 0;
    i32 dp_ax1 = 0;
    ed_pane_rect(0, &dp_ax0, &dp_ax1);
    g_checks++;
    if !ed_diff_on() || ed_pane_count() != 2 || ed_pane_active() != 1
        || dp_ax1 != dp_x1 {
        print("FAIL a diff must take the two panes that are there ({} panes, active {}, edge {} was {})\n",
            ed_pane_count(), ed_pane_active(), dp_ax1, dp_x1);
        g_fails++;
    }
    ed_diff_close();
    g_checks++;
    if ed_diff_on() || ed_pane_count() != 2 || ed_pane_buf(0) != dp_left {
        print("FAIL closing must give the left pane back ({} panes, buf {} was {})\n",
            ed_pane_count(), ed_pane_buf(0), dp_left);
        g_fails++;
    }
    // Ctrl+Shift+W in a borrowed diff pane: the diff ends, the left pane
    // gets back what it showed, and the file's pane closes as asked
    ed_diff_open("src/pick.mc");
    app_settle();
    app_key('W', MOD_CTRL | MOD_SHIFT);
    g_checks++;
    if ed_diff_on() || ed_pane_count() != 1 || ed_pane_buf(0) != dp_left {
        print("FAIL closing a borrowed diff pane must end the diff and close that pane ({} panes, buf {} was {})\n",
            ed_pane_count(), ed_pane_buf(0), dp_left);
        g_fails++;
    }
    app_key(92, MOD_CTRL);          // two panes again for the checks below
    ignore ed_open_file("README.md");

    // a third pane is not part of the picture: the diff takes the two
    // on the left and leaves it showing what it showed
    app_key(92, MOD_CTRL);
    ignore ed_open_file("doc/TECH_DOC.md");
    i32 dp_third = ed_pane_buf(2);
    ed_diff_open("src/pick.mc");
    app_settle();
    g_checks++;
    if !ed_diff_on() || ed_pane_count() != 3 || ed_pane_active() != 1
        || ed_pane_buf(2) != dp_third {
        print("FAIL a diff must use the two left panes of three ({} panes, active {}, third {} was {})\n",
            ed_pane_count(), ed_pane_active(), ed_pane_buf(2), dp_third);
        g_fails++;
    }
    // and a buffer switched in that third pane leaves the diff alone
    ed_pane_focus(2);
    ignore ed_open_file("doc/TESTING.md");
    g_checks++;
    if !ed_diff_on() || ed_pane_count() != 3 {
        print("FAIL a file opened beside the diff must not end it ({} panes)\n",
            ed_pane_count());
        g_fails++;
    }
    // that pane reads its own buffer line by line: the diff's rows are
    // another file's, and drawing through them read past this one's end
    g_checks++;
    if ed_row_count() != tb.nlines || ed_line_of_row(tb.nlines - 1) != tb.nlines - 1 {
        print("FAIL a pane beside the diff must not use the diff's rows ({} rows, {} lines)\n",
            ed_row_count(), tb.nlines);
        g_fails++;
    }
    i32 dp_line = cur_line;
    app_key(K_F7, 0);
    g_checks++;
    if cur_line != dp_line {
        print("FAIL F7 beside the diff must not walk the diff's changes (line {} was {})\n",
            cur_line, dp_line);
        g_fails++;
    }
    // the diff's rows are its file's: an edit beside it recomputes that
    // buffer's gutter and leaves the rows alone
    ed_pane_focus(1);
    i32 dp_rows = git_row_count();
    ed_pane_focus(2);
    app_char('x');
    app_key('Z', MOD_CTRL);
    ed_pane_focus(1);
    g_checks++;
    if git_row_count() != dp_rows {
        print("FAIL an edit beside the diff must not re-pair the diff's rows ({} rows, was {})\n",
            git_row_count(), dp_rows);
        g_fails++;
    }
    ed_pane_focus(2);
    // switching one of the diff's own panes ends it, and both stop
    // being a diff
    ed_pane_focus(1);
    ignore ed_open_file("README.md");
    g_checks++;
    if ed_diff_on() || ed_pane_count() != 3 || git_row_count() != 0 {
        print("FAIL a file in the diff's pane must end it ({} panes, {} rows)\n",
            ed_pane_count(), git_row_count());
        g_fails++;
    }
    close_all();


    test_terminal();
    test_input_fields();
    test_palette();
    test_glide();
    test_settings();
    test_brace();
    test_find_replace();
    test_recent();
    test_notices();
    test_gitignore();
    test_images();
    test_drag_scroll();
    test_history();
    test_new_file();
    test_wrap();
    test_indent();
    test_calls();
    test_explode();
    test_overlay_window();
    test_window_buf_close();
    test_close_shared_view();
    test_explode_from_term();

    if g_fails > 0 {
        print("ed_test: {} of {} checks FAILED\n", g_fails, g_checks);
        return 1;
    }
    print("ed_test: {} checks passed\n", g_checks);
    return 0;
}
