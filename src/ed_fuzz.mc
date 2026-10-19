// ed_fuzz.mc - headless fuzzer over the editor core. Same substrate as
// ed_test: the real portable modules against stubbed platform
// services, driven through the app_* entry points. Two differences.
//
//   1. The action stream is generated, not written: a seeded PRNG
//      picks weighted user actions (typing, movement, mouse, overlays,
//      splits, and the LSP navigation chords) so long sequences reach
//      states no hand-written case does.
//   2. The language server is the adversary. plat_child_* is a mock
//      that reads what the client sent and answers with responses
//      ranging from valid to hostile - out-of-range positions, uris in
//      every shape the client might see, junk frames, split framing -
//      because that is untrusted input and where the client's bugs
//      have been.
//
// Verification after every step is both textual and graphical:
// editor state invariants (caret, line index, panes, buffers) and the
// real quad batch built by view.mc (finite coordinates, in-window,
// atlas uv in range, no batch overflow). The frame is drawn with the
// real lib/draw.mc and lib/font.mc on a synthetic raster backend, so
// the geometry checked here is the geometry that ships.
//
// Nothing is ever written to disk: Ctrl+S and the save-as path are
// not in the action table, a name typed in the tree is cancelled after
// every action that starts one, and the rename is a stub. Buffers are edited in memory only.
//
// Compile from the repo root: minc src/ed_fuzz.mc -o build/ed_fuzz
// Exit 0 = no invariant broken. A failure prints the state, an ink
// map of the frame, and the seed/step line that reproduces it.
// scripts/fuzz.mc runs seed ranges and shrinks what they find.
//
// Nothing here is platform specific: the stubs stand in for every
// plat_*/gpu_* the core would otherwise reach, so this is the same
// program on Windows, macOS and Linux.

import file;
import process;
import plat;
import evscript;
import json;
import draw;
import font;
import theme;
import icon_mc;
import icon_edmc;
import ui;
import text_buf;
import git;
import lexer;
import lsp;
import lsp_shadow;
import harness_plat;
import sem;
import build;
import term;
import watch;
import wrap;
import ed;
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
import view;

// --- platform stubs --------------------------------------------------

private bool fz_wake_pending = false;

// A clock that advances only when read, so runs are deterministic. The
// step decides whether two presses in a row read as a double click.
// The clock is input. It moves FZ_TICK_US at every recorded event and
// a read returns it unchanged, so a run and its replay see the same
// time at every event however often the code between events reads it.
// A clock that moved per read made the replay drift: the recording
// reads it in places the script does not carry (the mock, the checks,
// the actions' own queries), and a comparison against a fixed time,
// such as a double click's window, came out the other way.
private const i64 FZ_TICK_US = 50000;
private i64 g_clock_us = 0;
i64 plat_time_us() {
    return g_clock_us;
}

private void fz_tick() {
    g_clock_us += FZ_TICK_US;
}
void plat_damage() {}
void plat_damage_window(i32 win) {}
void plat_set_timer(i32 id, i32 ms) {}
// images: a handle per texture, nothing drawn
i32 g_gpu_images = 0;
i32 gpu_image_create(u8* rgba, i32 w, i32 h) {
    g_gpu_images++;
    return g_gpu_images;
}
void gpu_image_free(i32 h) {}

void plat_kill_timer(i32 id) {}
void plat_quit() {}

// the harness has no native windows; a no-op
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

// nothing is written to disk
bool plat_file_rename(str src, str dst) {
    return false;
}

bool plat_trash(str path) {
    return false;
}

bool plat_reveal(str path) {
    return false;
}

bool plat_open_url(str url) {
    return true;
}

// the recent folders changed; the shell's list for the app follows
// (the Windows taskbar's jump list), nothing here yet
void plat_recent_folders(str* dirs, i32 n) {}

void plat_wake() { fz_wake_pending = true; }

u8[2304] fz_title;
i32 fz_title_len = 0;
void plat_set_title(str t) {
    i32 n = t.len;
    if n > 2304 { n = 2304; }
    memcpy(&fz_title[0], t.data, n);
    fz_title_len = n;
}

// A Windows-shaped workspace root: the drive letter and backslashes
// are what the file-uri round trip has to survive. Paths handed to
// the core stay repo-relative, so they still open real files.
private str FZ_ROOT = "C:\\ws";

i32 plat_cwd(u8* buf, i32 cap) {
    if cap < FZ_ROOT.len { return 0; }
    memcpy(buf, FZ_ROOT.data, FZ_ROOT.len);
    return FZ_ROOT.len;
}

// clipboard lives in a fixed buffer; paste feeds back what copy took
private u8[65536] fz_clip;
private i64 fz_clip_len = 0;

void plat_clipboard_set(u8* s, i64 n) {
    if n > 65536 { n = 65536; }
    memcpy(&fz_clip[0], s, n);
    fz_clip_len = n;
}

u8* plat_clipboard_get(i64* n) {
    if fz_clip_len == 0 {
        *n = 0;
        return null;
    }
    u8* p = alloc<u8>(fz_clip_len);
    memcpy(p, &fz_clip[0], fz_clip_len);
    *n = fz_clip_len;
    return p;
}

// --- mock child: what the client wrote -------------------------------
// plat_child_write captures the request stream; the mock server below
// parses it and decides what to answer. plat_child_read returns 0 so
// the client's reader thread exits at once; responses are injected
// straight into lsp_feed, which is the same entry the reader uses.

private const i64 FZ_OUT_CAP = 8 * 1024 * 1024;
private u8* fz_out = null;
private i64 fz_out_len = 0;

// Stands in for git. `rev-parse` says yes, this is a repo rooted here;
// `show HEAD:<path>` answers with the file's own bytes minus every
// nineteenth line, so the gutter has a baseline that differs from the
// buffer in a realistic way and its marks reach a real frame. Without
// this the whole change gutter would sit unfuzzed behind a null.
// the build: output in the compiler's shape and in others, a stream
// the parser and the jump must survive
private u8* fz_build_output(i64* out_len, i32* out_code) {
    i32 shape = rnd_cap_n(&fz_cap_build, 6);
    if shape == 0 { return null; }   // minc not found
    u8* b = alloc<u8>(8192);
    i64 o = 0;
    if shape == 1 {
        str ok = "built.\r\n";   // CR LF, as the pty's line discipline sends it
        memcpy(b, ok.data, ok.len);
        o = ok.len;
        *out_code = 0;
    } else {
        i32 n = 1 + rnd_cap_n(&fz_cap_build, 12);
        for i32 i = 0; i < n && o < 7000; i++ {
            i32 k = rnd_cap_n(&fz_cap_build, 5);
            str path = "src/ed.mc";
            if k == 1 { path = "no/such/file.mc"; }
            if k == 2 { path = "C:\\w\\lib\\draw.mc"; }
            if k == 3 { path = ""; }
            memcpy(b + o, path.data, path.len);
            o += path.len;
            b[o] = ':';
            o++;
            o += fmt_i32(b + o, rnd_cap_n(&fz_cap_build, 2) == 0 ? rnd_cap_n(&fz_cap_build, 400) : rnd_cap_n(&fz_cap_build, 100000000));
            b[o] = ':';
            o++;
            o += fmt_i32(b + o, rnd_cap_n(&fz_cap_build, 2) == 0 ? rnd_cap_n(&fz_cap_build, 80) : rnd_cap_n(&fz_cap_build, 100000000));
            str sev = ": error: ";
            if rnd_cap_n(&fz_cap_build, 3) == 0 { sev = ": warning: "; }
            if k == 4 { sev = ": note "; }
            memcpy(b + o, sev.data, sev.len);
            o += sev.len;
            if rnd_cap_n(&fz_cap_build, 2) == 0 {
                b[o] = 27;
                b[o + 1] = '[';
                b[o + 2] = '1';
                b[o + 3] = 'm';
                o += 4;
            }
            str msg = "something went wrong\r\n";
            memcpy(b + o, msg.data, msg.len);
            o += msg.len;
        }
        *out_code = 1;
    }
    *out_len = o;
    return b;
}

// `git status` in every shape: a clean tree, no repo, junk with no
// NUL, paths past any limit, a rename with its old name missing, the
// final NUL missing, and plain records over paths the tree shows
private void fz_put(u8* r, i64* w, str s) {
    memcpy(r + *w, s.data, s.len);
    *w += s.len;
}

private u8* fz_status_output(i64* out_len, i32* out_code) {
    i32 shape = rnd_cap_n(&fz_cap_status, 7);
    i64 cap = 65536;
    u8* r = alloc<u8>(cap);
    i64 w = 0;
    *out_code = 0;
    *out_len = 0;
    if shape == 0 { return r; }
    if shape == 1 {
        *out_code = 128;
        return r;
    }
    if shape == 2 {
        for i64 i = 0; i < 300; i++ { r[i] = cast(u8, 1 + rnd_cap_n(&fz_cap_status, 255)); }
        *out_len = 300;
        return r;
    }
    i32 recs = 1 + rnd_cap_n(&fz_cap_status, 40);
    for i32 k = 0; k < recs && w + 2 * PATH_MAX + 64 < cap; k++ {
        i32 xy = rnd_cap_n(&fz_cap_status, 9);
        str s = " M";
        if xy == 1 { s = "??"; }
        if xy == 2 { s = "A "; }
        if xy == 3 { s = " D"; }
        if xy == 4 { s = "R "; }
        if xy == 5 { s = "UU"; }
        if xy == 6 { s = "!!"; }
        if xy == 7 { s = "MM"; }
        if xy == 8 { s = "X?"; }
        fz_put(r, &w, s);
        fz_put(r, &w, " ");
        if shape == 3 {
            for i32 i = 0; i < 2 * PATH_MAX; i++ { r[w] = 'a'; w++; }
        } else {
            i32 which = rnd_cap_n(&fz_cap_status, 6);
            if which == 0 { fz_put(r, &w, "src/ed.mc"); }
            if which == 1 { fz_put(r, &w, "src/view.mc"); }
            if which == 2 { fz_put(r, &w, "lib/plat.mc"); }
            if which == 3 { fz_put(r, &w, "doc/TESTING.md"); }
            if which == 4 { fz_put(r, &w, "src"); }
            if which == 5 { fz_put(r, &w, "a/b/c/d/e/f.mc"); }
        }
        if s.data[0] == 'R' && shape != 4 {
            r[w] = 0;
            w++;
            fz_put(r, &w, "old.mc");
        }
        r[w] = 0;
        w++;
    }
    if shape == 5 && w > 0 { w--; }
    *out_len = w;
    return r;
}

u8* plat_run_capture(str* argv, i32 argc, i64* out_len, i32* out_code) {
    *out_len = 0;
    *out_code = -1;
    if argc >= 2 && str_equal(argv[0], "git") && str_equal(argv[1], "status") { return fz_status_output(out_len, out_code); }
    return harness_git(argv, argc, 19, out_len, out_code);
}
// the mock plays the minc server only; the C server's slot stays empty
bool plat_child_spawn(i32 k, str* argv, i32 argc) { return k == 0; }

// A pseudo-terminal with no child: reads bring nothing, so the only
// bytes a screen ever sees are the ones an action generated, and
// writes are taken and dropped, which still walks the key encoder.
// One handle per open terminal. The shell answers nothing; a command
// (the build) answers the mock compiler's output, in reads of the
// caller's size, then the end of file and its exit code.
private bool[TERM_MAX] fz_th_used;
private u8*[TERM_MAX] fz_th_out;
private i64[TERM_MAX] fz_th_len;
private i64[TERM_MAX] fz_th_at;
private i32[TERM_MAX] fz_th_code;
i32 plat_term_spawn(i32 cols, i32 rows, str* argv, i32 argc, bool under) {
    term_threaded = false;   // the stub answers here; no thread to drain a queue
    i32 h = -1;
    for i32 i = 0; i < TERM_MAX; i++ {
        if !fz_th_used[i] { h = i; break; }
    }
    if h < 0 { return -1; }
    fz_th_used[h] = true;
    fz_th_out[h] = null;
    fz_th_len[h] = 0;
    fz_th_at[h] = 0;
    fz_th_code[h] = -1;
    if argc > 0 {
        i64 n = 0;
        i32 code = 127;   // the shell's "command not found"
        u8* out = fz_build_output(&n, &code);
        fz_th_out[h] = out;
        fz_th_len[h] = n;
        fz_th_code[h] = code;
    }
    return h;
}
i64 plat_term_read(i32 h, u8* buf, i64 cap) {
    if h < 0 || h >= TERM_MAX || fz_th_out[h] == null { return 0; }
    i64 n = fz_th_len[h] - fz_th_at[h];
    if n <= 0 {
        free(fz_th_out[h]);
        fz_th_out[h] = null;
        return 0;
    }
    if n > cap { n = cap; }
    memcpy(buf, fz_th_out[h] + fz_th_at[h], n);
    fz_th_at[h] += n;
    return n;
}
i64 plat_term_write(i32 h, u8* p, i64 n) { return n; }
void plat_term_resize(i32 h, i32 cols, i32 rows) {}
i32 plat_term_code(i32 h) {
    if h < 0 || h >= TERM_MAX { return -1; }
    return fz_th_code[h];
}
void plat_term_kill(i32 h) {}
void plat_term_free(i32 h) {
    if h < 0 || h >= TERM_MAX { return; }
    if fz_th_out[h] != null {
        free(fz_th_out[h]);
        fz_th_out[h] = null;
    }
    fz_th_used[h] = false;
}
u32 plat_term_palette(u32* out, i32 n) { return 0; }
i32 plat_exe_path(u8* out, i32 cap) { return 0; }
bool plat_exec_self(str exe, str* argv, i32 argc) { return false; }
bool plat_term_export(i32 h, i64* fd, i32* pid) { return false; }
i32 plat_term_adopt(i64 fd, i32 pid) { return -1; }

i64 plat_child_write(i32 k, u8* p, i64 n) {
    if k != 0 { return -1; }
    if fz_out == null { fz_out = alloc<u8>(FZ_OUT_CAP); }
    if fz_out_len + n <= FZ_OUT_CAP {
        memcpy(fz_out + fz_out_len, p, n);
        fz_out_len += n;
    }
    // checked as written: the shadow document must be compared with
    // the buffer the frame described, before the step moves it on.
    // The answers still come at the mock's own step.
    mock_scan();
    return n;
}

i64 plat_child_read(i32 k, u8* p, i64 cap) { return 0; }
void plat_child_kill(i32 k) {}

// --- font backend stub -----------------------------------------------
// Deterministic synthetic glyphs, so the real cache, atlas packing and
// UI phase machinery run without a system font. Metrics follow the
// shipped backends' shape (mono cell, proportional UI face).

private const i32 FZ_GLYPH_MAX = 64 * 64;
private i32 fz_start_w = 0;   // the run's window, for the summary line
private i32 fz_start_h = 0;
private u8* fz_raster = null;

bool plat_font_init(i32 dpi, FontMetrics* m) {
    if dpi <= 0 { return false; }
    m.cell_w = 9 * dpi / DPI_BASE;
    m.line_h = 22 * dpi / DPI_BASE;
    m.ascent = 16 * dpi / DPI_BASE;
    if m.cell_w < 2 { m.cell_w = 2; }
    if m.line_h < 4 { m.line_h = 4; }
    if m.ascent < 3 { m.ascent = 3; }
    font_ui_h = 17 * dpi / DPI_BASE;
    font_ui_ascent = 13 * dpi / DPI_BASE;
    font_ui_row = 22 * dpi / DPI_BASE;
    if font_ui_h < 4 { font_ui_h = 4; }
    if font_ui_row < 4 { font_ui_row = 4; }
    return true;
}

u32 plat_shape_cluster(u8* s, i32 n) { return 0; }
bool plat_glyph_raster(u32 cp, GlyphRaster* out) {
    u32 base = cp & 0x00FFFFFF;
    bool is_ui = (cp & FONT_UI) != 0;
    i32 phase = cast(i32, (cp & FONT_PHASE_MASK) >> FONT_PHASE_SHIFT);
    // advance-only glyphs exist on every backend; keep the path live
    if base == 32 { return false; }
    if base >= 0x10000 && (base & 7) == 0 { return false; }

    // a slice of the astral range rasters as a straight-RGBA color glyph,
    // so the color-emoji atlas/quad/shader path is exercised and checked
    // for native/wasm parity like everything else
    bool color = base >= 0x10000 && (base & 7) == 1;

    i32 adv = font_cell_w;
    i32 h = font_ascent - 3;
    if is_ui {
        adv = font_cell_w / 2 + cast(i32, base % 7);
        h = font_ui_ascent - 2;
    }
    if adv < 2 { adv = 2; }
    if h < 1 { h = 1; }
    i32 w = adv - 1;
    if cp_width(base) == 2 { w = adv * 2 - 1; }
    if w < 1 { w = 1; }
    i32 bpp = 1;
    if color { bpp = 4; }
    if w * h * bpp > FZ_GLYPH_MAX { h = FZ_GLYPH_MAX / (w * bpp); }
    if h < 1 { h = 1; }

    if fz_raster == null { fz_raster = alloc<u8>(FZ_GLYPH_MAX); }
    for i32 y = 0; y < h; y++ {
        for i32 x = 0; x < w; x++ {
            u32 v = base * 7 + cast(u32, x) * 13 + cast(u32, y) * 29 + cast(u32, phase);
            if color {
                i32 o = (y * w + x) * 4;
                fz_raster[o] = cast(u8, v & 0xFF);
                fz_raster[o + 1] = cast(u8, (v >> 3) & 0xFF);
                fz_raster[o + 2] = cast(u8, (v >> 6) & 0xFF);
                fz_raster[o + 3] = cast(u8, (v >> 1) & 0xFF);
            } else {
                fz_raster[y * w + x] = cast(u8, v & 0xFF);
            }
        }
    }
    out.pixels = fz_raster;
    out.w = w;
    out.h = h;
    out.pitch = w * bpp;
    out.channels = bpp;
    out.xoff = 1;
    out.yoff = font_ascent - h;
    out.adv = adv;
    out.advf = cast(f32, adv) + cast(f32, phase) * 0.25f;
    return true;
}

// --- gpu stubs -------------------------------------------------------

void gpu_upload_atlas(u8* pixels) {}
void gpu_frame_end(f32 r, f32 g, f32 b) {}

// --- prng ------------------------------------------------------------

private u64 fz_rng = 0;

private u64 rnd64() {
    u64 x = fz_rng;
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    fz_rng = x;
    return x;
}

// [0, n)
private i32 rnd_n(i32 n) {
    if n <= 1 { return 0; }
    i64 v = cast(i64, rnd64() >> 1);
    return cast(i32, v % cast(i64, n));
}

// Separate streams for the plat_run_capture stubs. They run on a worker
// thread on native and inline on wasm, so drawing from the action prng
// would consume it at different points and the two platforms' runs would
// diverge. One shared stream is not enough either: the build capture runs
// on the build worker and the status capture on the git worker, two
// threads that interleave in an order the wasm inline path does not have,
// so a single stream is drawn in a platform-dependent order (and raced).
// One stream per stub instead: each is consumed only by its own worker,
// one job at a time, in a count and order fixed by the action stream.
private u64 fz_cap_build = 0;
private u64 fz_cap_status = 0;

private u64 cap64(u64* s) {
    u64 x = *s;
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    *s = x;
    return x;
}

private i32 rnd_cap_n(u64* s, i32 n) {
    if n <= 1 { return 0; }
    i64 v = cast(i64, cap64(s) >> 1);
    return cast(i32, v % cast(i64, n));
}

// true with probability 1/n
private bool rnd_1in(i32 n) {
    return rnd_n(n) == 0;
}

// --- config + counters -----------------------------------------------

private i32 fz_seed = 1;
private i32 fz_steps = 2000;
private i32 fz_verify_every = 8;
private i32 fz_undo_every = 32;   // steps between undo/redo round trips
private bool fz_trace = false;
private i32 fz_show = -1;          // --show: the step whose state and frame are printed
private bool fz_vv = false;    // per-phase tracing, for localizing a crash
private bool fz_heap = false;  // exercise the allocator every step
private bool fz_cov = false;   // report what the run reached
private u8[512] fz_script_out;
private i32 fz_script_out_len = 0;
private bool fz_replay_check = false;   // --replay-check: replay the run's script, same hash
private u8[512] fz_script_in;
private i32 fz_script_in_len = 0;
private bool fz_shrink = false;
private i32 fz_budget = 6000;
private bool fz_quiet = false;
private bool fz_keep_going = false;

private i32 fz_fails = 0;
private i32 fz_step_no = 0;
private u64 fz_frame_hash = 1469598103934665603;

// the last actions, for the failure report
private const i32 FZ_HIST = 12;
private str[FZ_HIST] fz_hist;
private i32 fz_nhist = 0;

private void hist_push(str name) {
    fz_hist[fz_nhist % FZ_HIST] = name;
    fz_nhist++;
}

// Unbuffered breadcrumbs. print() is block buffered, so everything it
// holds is lost if the process faults - which is exactly the case a
// fuzzer has to report on. These go straight to the fd.
private void say(str s) {
    ignore write(stdout(), s.data, s.len);
}

// i64 all the way: fmt_i32 would truncate, and a truncated value that
// lands negative prints as nothing at all
private void say_i(i64 v) {
    noinit u8[24] b;
    i32 n = 0;
    if v < 0 {
        b[0] = '-';
        n = 1;
        v = 0 - v;
    }
    if v == 0 {
        b[n] = '0';
        n++;
    } else {
        noinit u8[24] tmp;
        i32 t = 0;
        while v > 0 {
            tmp[t] = cast(u8, '0' + cast(i32, v % 10));
            v /= 10;
            t++;
        }
        for i32 i = 0; i < t; i++ {
            b[n] = tmp[t - 1 - i];
            n++;
        }
    }
    ignore write(stdout(), &b[0], n);
}

private i32 fz_atoi(str s) {
    i32 v = 0;
    for i32 i = 0; i < s.len; i++ {
        if s.data[i] < '0' || s.data[i] > '9' { break; }
        v = v * 10 + cast(i32, s.data[i] - '0');
    }
    return v;
}

// --- reporting -------------------------------------------------------

private const i32 MAP_W = 96;
private const i32 MAP_H = 30;

// Coarse ink map of the frame: every quad's rect accumulated at cell
// resolution, weighted by its alpha. It shows layout - gutter, text
// block, sidebar, overlays, status bar - without needing a GPU.
private void dump_ink_map() {
    if draw_nverts < 6 || g_w <= 0 || g_h <= 0 { return; }
    noinit i32[MAP_W * MAP_H] acc;
    for i32 i = 0; i < MAP_W * MAP_H; i++ { acc[i] = 0; }
    i32 top = 0 - g_caption_h;
    i32 span_y = g_h - top;
    if span_y < 1 { span_y = 1; }

    for i32 v = 0; v + 5 < draw_nverts; v += 6 {
        DrawVtx* p = draw_verts + v;
        i32 a = cast(i32, (p[0].col >> 24) & 0xFF);
        if a == 0 { continue; }
        i32 x0 = cast(i32, p[0].x) * MAP_W / g_w;
        i32 x1 = cast(i32, p[4].x) * MAP_W / g_w;
        i32 y0 = (cast(i32, p[0].y) - top) * MAP_H / span_y;
        i32 y1 = (cast(i32, p[4].y) - top) * MAP_H / span_y;
        if x1 <= x0 { x1 = x0 + 1; }
        if y1 <= y0 { y1 = y0 + 1; }
        if x0 < 0 { x0 = 0; }
        if y0 < 0 { y0 = 0; }
        if x1 > MAP_W { x1 = MAP_W; }
        if y1 > MAP_H { y1 = MAP_H; }
        for i32 y = y0; y < y1; y++ {
            for i32 x = x0; x < x1; x++ { acc[y * MAP_W + x] += a; }
        }
    }

    print("  frame ink map ({}x{} px, {} verts):\n", g_w, g_h, draw_nverts);
    noinit u8[MAP_W + 1] row;
    for i32 y = 0; y < MAP_H; y++ {
        for i32 x = 0; x < MAP_W; x++ {
            i32 a = acc[y * MAP_W + x];
            u8 c = ' ';
            if a > 0 { c = '.'; }
            if a > 600 { c = ':'; }
            if a > 3000 { c = 'o'; }
            if a > 12000 { c = '#'; }
            row[x] = c;
        }
        print("  |{}|\n", str_from(&row[0], MAP_W));
    }
}

// The visible slice of the active pane, with the caret marked.
private void dump_text() {
    i32 vis = visible_lines();
    i32 last = top_line + vis - 1;
    if last > tb.nlines - 1 { last = tb.nlines - 1; }
    print("  visible text (lines {}..{} of {}):\n", top_line + 1, last + 1, tb.nlines);
    for i32 l = top_line; l <= last && l < top_line + 12; l++ {
        i32 n = line_bytes(l);
        if n > 100 { n = 100; }
        u8 mark = ' ';
        if l == cur_line { mark = '>'; }
        print("  {} {}  {}\n", str_from(&mark, 1), l + 1, str_from(g_linebuf, n));
    }
}

private void dump_state() {
    str path = "untitled";
    if g_has_path { path = str_from(&g_path[0], g_path_len); }
    print("  buffer: {} (line {} col {}, top {}, off {}, lvcol {})\n",
        path, cur_line + 1, cur_col, top_line, scroll_off, left_vcol);
    print("  bufs {} active {} | panes {} active {} term {} | dirty {} | diff {} rows {} lines {}\n",
        ed_buf_count(), ed_buf_active(), ed_pane_count(), ed_pane_active(),
        ed_term_active(), cast(i32, tb.dirty), cast(i32, ed_diff_on()), ed_row_count(), tb.nlines);
    print("  overlays: find {} pick {} tree_focus {} search {} | lsp on {} ready {}\n",
        cast(i32, find_on), cast(i32, pick_on), cast(i32, tree_focus),
        cast(i32, search_on), cast(i32, lsp_on), cast(i32, lsp_ready));
    print("  title: {}\n", str_from(&fz_title[0], fz_title_len));
    print("  window {}x{} caption {} | visible lines {} | search hits {} rows {} | tree rows {}\n",
        g_w, g_h, g_caption_h, visible_lines(),
        search_hit_count(), search_row_count(), tree_row_count());
    if g_status_len > 0 {
        print("  status: {}\n", str_from(&g_status_msg[0], g_status_len));
    }
    print("  last actions:\n");
    i32 first = fz_nhist - FZ_HIST;
    if first < 0 { first = 0; }
    for i32 i = first; i < fz_nhist; i++ {
        print("    {} {}\n", i, fz_hist[i % FZ_HIST]);
    }
}

// --show: the state, the text and the frame after one step's checks,
// for comparing a run with its replay; each quad goes out as a line
private void show_step() {
    print("\n--- step {} ---\n", fz_step_no);
    dump_state();
    dump_text();
    dump_ink_map();
    for i32 v = 0; v + 5 < draw_nverts; v += 6 {
        DrawVtx* p = draw_verts + v;
        print("  quad {} {} {} {} col {}\n", cast(i32, p[0].x), cast(i32, p[0].y),
            cast(i32, p[4].x), cast(i32, p[4].y), p[0].col);
    }
}

private void fail(str what, str detail) {
    fz_fails++;
    print("\nFAIL step {} seed {}: {}\n", fz_step_no, fz_seed, what);
    if detail.len > 0 { print("  {}\n", detail); }
    dump_state();
    dump_text();
    dump_ink_map();
    print("  repro: ed_fuzz --seed {} --steps {} --trace\n",
        fz_seed, fz_step_no + 1);
}

private void fail_i(str what, i64 got, i64 lo, i64 hi) {
    fz_fails++;
    print("\nFAIL step {} seed {}: {}\n", fz_step_no, fz_seed, what);
    print("  got {}, expected [{}, {}]\n", got, lo, hi);
    dump_state();
    dump_text();
    dump_ink_map();
    print("  repro: ed_fuzz --seed {} --steps {} --trace\n",
        fz_seed, fz_step_no + 1);
}

// --- state invariants ------------------------------------------------

private i64 line_length(i32 l) {
    return tb_line_end(l) - tb_line_start(l);
}

// Full re-scan of the buffer against the line index. O(file), so it
// runs every fz_verify_every steps rather than every step.
private bool check_line_index() {
    i64 n = tb_len();
    if n < 0 || n > 512 * 1024 * 1024 {
        fail_i("buffer length out of range", n, 0, 512 * 1024 * 1024);
        return false;
    }
    u8* buf = alloc<u8>(n + 1);
    tb_copy(0, buf, n);
    i32 want = 1;
    for i64 i = 0; i < n; i++ {
        if buf[i] == '\n' { want++; }
    }
    if want != tb.nlines {
        free(buf);
        fail_i("line count disagrees with the buffer", cast(i64, tb.nlines),
            cast(i64, want), cast(i64, want));
        return false;
    }
    i32 l = 1;
    for i64 i = 0; i < n; i++ {
        if buf[i] != '\n' { continue; }
        if l >= tb.nlines { break; }
        if tb_line_start(l) != i + 1 {
            free(buf);
            fail_i("line start disagrees with the buffer", tb_line_start(l),
                i + 1, i + 1);
            return false;
        }
        l++;
    }
    free(buf);
    return true;
}

// --- event recording and replay ---------------------------------------
// Every input the core sees goes through these, so a run can be written
// out as a flat list of primitive events and replayed without the prng
// or the mock. That is what lets a failure be shrunk by *removing*
// events rather than only by truncating the seed: a report becomes a
// handful of events instead of "seed 31, step 1483".

// the event kinds are evscript.mc's, shared with the editor's --play

private u8* ev_buf = null;
private i64 ev_len = 0;
private i64 ev_cap = 0;
private bool ev_rec = false;      // recording (generated run)
private bool ev_play = false;     // replaying a script
private i64 ev_at = 0;            // replay cursor

private void ev_room(i64 n) {
    if ev_len + n <= ev_cap { return; }
    i64 ncap = ev_cap * 2 + n + 65536;
    u8* nb = alloc<u8>(ncap);
    if ev_buf != null {
        memcpy(nb, ev_buf, ev_len);
        free(ev_buf);
    }
    ev_buf = nb;
    ev_cap = ncap;
}

private void ev_put8(u8 v) {
    ev_room(1);
    ev_buf[ev_len] = v;
    ev_len++;
}

private void ev_put32(i32 v) {
    ev_room(4);
    *cast(i32*, ev_buf + ev_len) = v;
    ev_len += 4;
}

private u8 ev_get8() {
    u8 v = ev_buf[ev_at];
    ev_at++;
    return v;
}

private i32 ev_get32() {
    i32 v = *cast(i32*, ev_buf + ev_at);
    ev_at += 4;
    return v;
}

// f32 travels as its bit pattern; the replay has to reproduce the
// scroll deltas exactly, not approximately
private void ev_putf(f32 v) {
    ev_put32(*cast(i32*, &v));
}

private f32 ev_getf() {
    i32 b = ev_get32();
    return *cast(f32*, &b);
}

// --- the wrappers every action calls ---

private void ev_char(u32 cp) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_CHAR);
        ev_put32(cast(i32, cp));
    }
    app_char(cp);
}

private void ev_key(i32 key, i32 mods) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_KEY);
        ev_put32(key);
        ev_put32(mods);
    }
    app_key(key, mods);
}

private void ev_mouse(i32 x, i32 y, i32 btn, bool down, i32 mods) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_MOUSE);
        ev_put32(x);
        ev_put32(y);
        ev_put32(btn);
        ev_put32(cast(i32, down));
        ev_put32(mods);
    }
    app_mouse(x, y, btn, down, mods);
}

private void ev_mouse_move(i32 x, i32 y) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_MOVE);
        ev_put32(x);
        ev_put32(y);
    }
    app_mouse_move(x, y);
}

private void ev_scroll(f32 dx, f32 dy, i32 x, i32 y) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_SCROLL);
        ev_putf(dx);
        ev_putf(dy);
        ev_put32(x);
        ev_put32(y);
    }
    app_scroll(dx, dy, x, y);
}

private void ev_notch(f32 dx, f32 dy, i32 x, i32 y) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_NOTCH);
        ev_putf(dx);
        ev_putf(dy);
        ev_put32(x);
        ev_put32(y);
    }
    app_scroll_notch(dx, dy, x, y);
}

private void ev_hover(i32 x, i32 y, i32 mods) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_HOVER);
        ev_put32(x);
        ev_put32(y);
        ev_put32(mods);
    }
    app_hover(x, y, mods);
}

private void ev_resize(i32 w, i32 h) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_RESIZE);
        ev_put32(w);
        ev_put32(h);
    }
    app_resize(w, h);
}

private void ev_scale(i32 dpi) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_SCALE);
        ev_put32(dpi);
    }
    app_scale(dpi);
    // the drivers re-derive the self-drawn caption from the new dpi,
    // so the wrapper does too: it is part of the scale change, not a
    // separate input
    g_caption_h = caption_default_h(dpi);
}

private void ev_focus(bool on) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_FOCUS);
        ev_put32(cast(i32, on));
    }
    app_focus(on);
}

private void ev_timer(i32 id) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_TIMER);
        ev_put32(id);
    }
    app_timer(id);
}

private void ev_wake() {
    fz_tick();
    if ev_rec { ev_put8(EV_WAKE); }
    app_wake();
}

private void ev_settle() {
    fz_tick();
    if ev_rec { ev_put8(EV_SETTLE); }
    search_settle();
}

// the mock's injections are input too, so they ride in the script
private void ev_feed(u8* p, i64 n) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_FEED);
        ev_put32(cast(i32, n));
        ev_room(n);
        memcpy(ev_buf + ev_len, p, n);
        ev_len += n;
    }
    lsp_feed(p, n);
}

// the core starts: app_init, and the picker's scan that the mock's
// file list comes from. A mark in the script, so a replay starts the
// core at the same point between the same events.
private void ev_init() {
    fz_tick();
    if ev_rec { ev_put8(EV_INIT); }
    app_init("src/ed.mc", DPI_BASE);
    pick_scan();
}

// git status asked for as a save would ask for it: the harness
// standing in for the Ctrl+S it never presses
private void ev_status() {
    fz_tick();
    if ev_rec { ev_put8(EV_STATUS); }
    git_status_touch();
}

// The seed's streams: the action stream, and the ones the stubs answer
// from (git status, the build's output). A replay has no action stream
// but the stubs still answer, so the script carries the seed.
private void fz_seed_streams(i32 seed) {
    fz_seed = seed;
    fz_rng = cast(u64, seed) * 6364136223846793005 + 1442695040888963407;
    if fz_rng == 0 { fz_rng = 1; }
    fz_cap_build = fz_rng ^ cast(u64, 0x9E3779B97F4A7C15);
    if fz_cap_build == 0 { fz_cap_build = 2; }
    fz_cap_status = fz_rng ^ cast(u64, 0xD1B54A32D192ED03);
    if fz_cap_status == 0 { fz_cap_status = 3; }
}

private void ev_seed(i32 seed) {
    if ev_rec {
        ev_put8(EV_SEED);
        ev_put32(seed);
    }
    fz_seed_streams(seed);
}

private void ev_step() {
    fz_tick();
    if ev_rec { ev_put8(EV_STEP); }
}

// watcher records are input too; n < 0 stands for changes it lost
private void ev_watch(u8* p, i64 n) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_WATCH);
        ev_put32(cast(i32, n));
        if n > 0 {
            ev_room(n);
            memcpy(ev_buf + ev_len, p, n);
            ev_len += n;
        }
    }
    if n < 0 {
        watch_feed(null, 0, true);
    } else {
        watch_feed(p, n, false);
    }
}

// --- outgoing protocol conformance ------------------------------------
// The mock answers badly on purpose, but nothing checked that what the
// client *sends* is well formed. Spawning a real server would prove it
// by acceptance; the stdlib has no streaming child, and pulling the
// platform layer into this binary would cost the portability that
// makes the harness worth having. Checking the traffic against the
// spec gets the same coverage and stays deterministic.

private bool fz_proto_bad = false;

// Documents are keyed by a hash of the uri, not the bytes: the mock
// sends deliberately enormous uris, and a fixed-width table would drop
// them and then complain that they were never opened.
private const i32 PROTO_DOCS = 256;
private u64[PROTO_DOCS] proto_key;
private i32[PROTO_DOCS] proto_version;
// the document as the server would hold it after the client's
// messages; the client pushes the active buffer, so after each push
// the two must be the same bytes
private u8*[PROTO_DOCS] proto_text;
private i64[PROTO_DOCS] proto_tlen;
private i32 proto_ndocs = 0;
private bool proto_full = false;   // stop ordering checks rather than lie
private i64 proto_last_id = 0;

private u64 proto_hash(str s) {
    u64 h = 1469598103934665603;
    for i32 i = 0; i < s.len; i++ {
        h = (h ^ cast(u64, s.data[i])) * 1099511628211;
    }
    return h;
}

private void proto_fail(str what) {
    fz_proto_bad = true;
    fail(what, "");
}

private i32 proto_doc(str uri) {
    u64 k = proto_hash(uri);
    for i32 i = 0; i < proto_ndocs; i++ {
        if proto_key[i] == k { return i; }
    }
    return -1;
}

private i32 proto_doc_add(str uri) {
    if proto_ndocs == PROTO_DOCS {
        proto_full = true;
        return -1;
    }
    i32 i = proto_ndocs;
    proto_key[i] = proto_hash(uri);
    proto_version[i] = 0;
    proto_text[i] = null;
    proto_tlen[i] = 0;
    proto_ndocs++;
    return i;
}

// the server's copy of document i against the active buffer
private void proto_verify_doc(i32 i, str what) {
    if proto_text[i] == null { return; }
    i64 n = tb_len();
    if n != proto_tlen[i] {
        proto_fail("the document the client described differs in length from the buffer");
        print("  after {}: server {} bytes, buffer {}\n", what, proto_tlen[i], n);
        return;
    }
    u8* bb = alloc<u8>(n + 1);
    if n > 0 { tb_copy(0, bb, n); }
    for i64 k = 0; k < n; k++ {
        if bb[k] != proto_text[i][k] {
            proto_fail("the document the client described differs from the buffer");
            print("  after {}: first difference at byte {} of {}\n", what, k, n);
            break;
        }
    }
    free(bb);
}

// non-negative line and character, if the node carries a position
private bool proto_pos_ok(JDoc* d, i32 node) {
    if node < 0 { return true; }
    i32 l = jd_get(d, node, "line");
    i32 c = jd_get(d, node, "character");
    if l >= 0 && jd_int(d, l) < 0 { return false; }
    if c >= 0 && jd_int(d, c) < 0 { return false; }
    return true;
}

private void proto_check(JDoc* d, i32 root) {
    if root < 0 {
        proto_fail("the client wrote a frame that is not json");
        return;
    }
    if jd_kind(d, root) != J_OBJ {
        proto_fail("the client wrote a frame that is not an object");
        return;
    }
    i32 jv = jd_get(d, root, "jsonrpc");
    if jv < 0 || !str_equal(jd_str(d, jv), "2.0") {
        proto_fail("outgoing frame without jsonrpc 2.0");
        return;
    }
    i32 jm = jd_get(d, root, "method");
    if jm < 0 {
        // the client only ever originates traffic
        proto_fail("outgoing frame without a method");
        return;
    }
    str method = jd_str(d, jm);
    i32 jid = jd_get(d, root, "id");
    if jid >= 0 {
        i64 id = jd_int(d, jid);
        if id <= proto_last_id {
            proto_fail("request id did not advance");
            return;
        }
        proto_last_id = id;
    }
    i32 params = jd_get(d, root, "params");
    if params < 0 { return; }

    // every uri the client sends is an absolute three-slash file uri
    i32 doc = jd_get(d, params, "textDocument");
    i32 juri = jd_get(d, params, "uri");
    if doc >= 0 { juri = jd_get(d, doc, "uri"); }
    i32 di = -1;
    if juri >= 0 {
        str uri = jd_str(d, juri);
        if !str_starts_with(uri, "file:///") {
            proto_fail("outgoing uri is not an absolute file uri");
            return;
        }
        di = proto_doc(uri);
    }

    if str_equal(method, "textDocument/didOpen") {
        if di >= 0 {
            proto_fail("didOpen for a document already open");
            return;
        }
        if proto_full { return; }
        i32 ni = -1;
        if juri >= 0 { ni = proto_doc_add(jd_str(d, juri)); }
        i32 jver = jd_get(d, doc, "version");
        if ni >= 0 && jver >= 0 { proto_version[ni] = cast(i32, jd_int(d, jver)); }
        i32 jtext = jd_get(d, doc, "text");
        if ni >= 0 && jtext >= 0 {
            str raw = jd_str(d, jtext);
            proto_text[ni] = alloc<u8>(raw.len + 1);
            proto_tlen[ni] = jd_str_copy(d, jtext, proto_text[ni], raw.len + 1);
            proto_verify_doc(ni, "didOpen");
        }
        return;
    }
    if str_equal(method, "textDocument/didClose") {
        if di >= 0 {
            if proto_text[di] != null { free(proto_text[di]); }
            for i32 j = di; j < proto_ndocs - 1; j++ {
                proto_key[j] = proto_key[j + 1];
                proto_version[j] = proto_version[j + 1];
                proto_text[j] = proto_text[j + 1];
                proto_tlen[j] = proto_tlen[j + 1];
            }
            proto_ndocs--;
            if proto_ndocs < PROTO_DOCS { proto_full = false; }
        }
        return;
    }
    if str_equal(method, "textDocument/didChange") {
        if di < 0 {
            if proto_full { return; }
            proto_fail("didChange for a document that was never opened");
            return;
        }
        i32 jver = jd_get(d, doc, "version");
        if jver < 0 {
            proto_fail("didChange without a version");
            return;
        }
        i32 v = cast(i32, jd_int(d, jver));
        if v <= proto_version[di] {
            proto_fail("didChange version did not advance");
            return;
        }
        proto_version[di] = v;
        if proto_text[di] != null {
            i32 ch = jd_get(d, params, "contentChanges");
            if !lsp_shadow_apply(&proto_text[di], &proto_tlen[di], d, ch) {
                proto_fail("didChange contentChanges is not the protocol's shape");
                return;
            }
            proto_verify_doc(di, "didChange");
        }
        return;
    }
    if str_equal(method, "textDocument/definition") {
        if di < 0 {
            if proto_full { return; }
            proto_fail("definition for a document that was never opened");
            return;
        }
        if !proto_pos_ok(d, jd_get(d, params, "position")) {
            proto_fail("definition at a negative position");
        }
        return;
    }
}

// --- coverage --------------------------------------------------------
// A fuzzer is only as good as what it reaches. These count the action
// families and sample the states worth reaching after every step, so a
// soak can say what it never got to rather than leaving it to faith.

private const i32 COV_FAMILIES = 24;
private const i32 COV_N = COV_FAMILIES + 38;
private i64[COV_N] cov;

private str cov_label(i32 i) {
    if i < COV_FAMILIES { return fz_family_name(i); }
    i32 k = i - COV_FAMILIES;
    if k == 0 { return "state: two panes"; }
    if k == 1 { return "state: three panes"; }
    if k == 2 { return "state: eight buffers"; }
    if k == 3 { return "state: scrolled"; }
    if k == 4 { return "state: find open"; }
    if k == 5 { return "state: quick open"; }
    if k == 6 { return "state: search view"; }
    if k == 7 { return "state: tree focus"; }
    if k == 8 { return "state: search focus"; }
    if k == 9 { return "state: selection"; }
    if k == 10 { return "state: undoable"; }
    if k == 11 { return "state: redoable"; }
    if k == 12 { return "state: dirty"; }
    if k == 13 { return "state: hover link"; }
    if k == 17 { return "state: hover popup"; }
    if k == 18 { return "state: completion popup"; }
    if k == 19 { return "state: reference results"; }
    if k == 20 { return "state: two cursors"; }
    if k == 21 { return "state: four cursors"; }
    if k == 22 { return "state: gutter marks"; }
    if k == 23 { return "state: symbol search"; }
    if k == 24 { return "state: incremental sync"; }
    if k == 25 { return "state: semantic tokens"; }
    if k == 26 { return "state: build with problems"; }
    if k == 27 { return "state: decorations"; }
    if k == 14 { return "state: diagnostics"; }
    if k == 15 { return "state: caret on last line"; }
    if k == 16 { return "state: server ready"; }
    if k == 28 { return "state: terminal open"; }
    if k == 29 { return "state: alternate screen"; }
    if k == 30 { return "state: terminal pane focused"; }
    if k == 31 { return "state: terminal in the background"; }
    if k == 32 { return "state: switcher open"; }
    if k == 33 { return "state: terminal selection"; }
    if k == 34 { return "state: diff open"; }
    if k == 35 { return "state: command palette"; }
    if k == 36 { return "state: explode view"; }
    if k == 37 { return "state: call graph"; }
    return "?";
}

private void cov_hit(i32 i) {
    if i >= 0 && i < COV_N { cov[i]++; }
}

private void cov_state(i32 k, bool on) {
    if on { cov_hit(COV_FAMILIES + k); }
}

private void cov_sample() {
    cov_state(0, ed_pane_count() == 2);
    cov_state(1, ed_pane_count() == 3);
    cov_state(2, ed_buf_count() >= 8);
    // the buffer limit is not here: a random walk never climbs BUF_MAX
    // opens deep without closing one. ed_test drives that state directly
    cov_state(3, top_line > 0);
    // the mock grants incremental sync on half the seeds; a soak must
    // reach both modes, and this is the one a zero would point at
    cov_state(24, lsp_ready && lsp_sync_incremental);
    cov_state(25, sem_active() && sem_count() > 0);
    cov_state(26, build_problem_count() > 0);
    cov_state(31, ed_term_background_count() > 0);
    cov_state(32, switcher_on);
    cov_state(33, ed_term_active() >= 0 && ed_term_sel_on(ed_term_active()));
    cov_state(34, ed_diff_on());
    cov_state(27, git_dec_have() && git_dec_count() > 0);
    cov_state(4, find_on);
    cov_state(5, pick_on);
    cov_state(6, search_on);
    cov_state(7, tree_focus);
    cov_state(8, search_focus);
    i64 sa = 0;
    i64 sb = 0;
    cov_state(9, ed_sel_range(&sa, &sb));
    cov_state(10, ed_undo_depth() > 0);
    cov_state(11, ed_undo_total() > ed_undo_depth());
    cov_state(12, tb.dirty);
    cov_state(13, hover_link_on);
    cov_state(14, g_has_path
        && lsp_diag_count(str_from(&g_path[0], g_path_len)) > 0);
    cov_state(15, cur_line == tb.nlines - 1);
    cov_state(16, lsp_ready);
    cov_state(17, hover_pop_on);
    cov_state(18, cmp_on);
    cov_state(19, search_on && search_hit_count() > 0);
    cov_state(20, ed_cur_count() > 1);
    cov_state(21, ed_cur_count() >= 4);
    cov_state(22, git_on() && git_mark_count() > 0);
    cov_state(23, sym_on);
    cov_state(28, fz_term >= 0 && term_live(fz_term));
    cov_state(29, fz_term >= 0 && term_alt(fz_term));
    cov_state(30, ed_term_active() >= 0);
}

// one line per counter, so the driver can sum them across seeds
private void cov_report() {
    for i32 i = 0; i < COV_N; i++ {
        say("cov ");
        say_i(cov[i]);
        say(" ");
        say(cov_label(i));
        say("\n");
    }
}

// --- oracles ---------------------------------------------------------
// The checks above are invariants: they say nothing is out of range.
// These say the result is right, which needs a property that holds
// whatever the action stream did.

// buffer contents as an owned copy; the caller frees it
private u8* snapshot(i64* n) {
    i64 len = tb_len();
    u8* p = alloc<u8>(len + 1);
    tb_copy(0, p, len);
    *n = len;
    return p;
}

private bool same_bytes(u8* a, i64 an, u8* b, i64 bn) {
    if an != bn { return false; }
    for i64 i = 0; i < an; i++ {
        if a[i] != b[i] { return false; }
    }
    return true;
}

// Undoing a run of edits and redoing the same run must land on the
// text we started from. The counts have to match what actually
// applied, not what was asked for: the buffer can already sit part way
// down the journal, where the extra undos are no-ops but the matching
// redos would carry it past the starting point. Bounded rather than
// exhaustive so the cost does not grow with the journal.
private const i32 UNDO_DEPTH = 24;

private bool check_undo_roundtrip() {
    // an overlay owns Ctrl+Z, and the tree/search views swallow keys
    if overlay_active() || tree_focus || search_focus { return true; }
    i32 depth0 = ed_undo_depth();
    i64 n0 = 0;
    u8* before = snapshot(&n0);
    // Presses, not journal entries: one press undoes a whole group, so
    // counting entries would press redo more times than undo ran and
    // walk into edits that were already redoable before this started.
    i32 applied = 0;
    for i32 i = 0; i < UNDO_DEPTH; i++ {
        i32 d = ed_undo_depth();
        app_key('Z', MOD_CTRL);
        if ed_undo_depth() == d { break; }
        applied++;
    }
    i64 n1 = 0;
    u8* undone = snapshot(&n1);
    for i32 i = 0; i < applied; i++ { app_key('Y', MOD_CTRL); }
    i64 n2 = 0;
    u8* after = snapshot(&n2);
    // Only the round trip is a property. "The text changed" is not:
    // a run of edits can cancel out (type a character, then delete
    // it), so undoing all of them can land on the same bytes.
    bool ok = same_bytes(before, n0, after, n2);
    if !ok {
        fail("undo then redo did not restore the text", "");
        print("  journal depth {} -> {} ({} applied), bytes {} -> {} -> {}\n",
            depth0, ed_undo_depth(), applied, n0, n1, n2);
    }
    free(before);
    free(undone);
    free(after);
    return ok;
}

// The gutter's line hashes follow the edits; a full rehash of the
// buffer must agree with them.
private bool check_git_cache() {
    if git_check_cache() { return true; }
    fail("incremental git line hashes disagree with a full rehash", "");
    return false;
}

// The highlighter caches the lex state at the start of every line and
// invalidates from the edited line down. Recomputing the same states
// from line 0 must agree with what the cache holds.
private bool check_lexer() {
    if !g_lex_on || g_lexstate == null { return true; }
    i32 n = ed_lex_valid();
    if n > tb.nlines { n = tb.nlines; }
    u8 st = 0;
    for i32 l = 0; l < n; l++ {
        if g_lexstate[l] != st {
            fail("incremental lex state disagrees with a full relex", "");
            print("  line {}: cached {}, recomputed {} (valid {} of {})\n",
                l, cast(i32, g_lexstate[l]), cast(i32, st), ed_lex_valid(),
                tb.nlines);
            return false;
        }
        i32 len = line_bytes(l);
        st = cast(u8, lex_row(g_linebuf, len, cast(i32, st), g_clsbuf));
    }
    return true;
}

private bool check_state() {
    // A diff is two panes, the baseline left and the file right, and the
    // baseline never has the focus: it has no buffer slot to take it with.
    if ed_diff_on() && (ed_pane_count() < 2 || ed_pane_active() < 1) {
        fail_i("diff layout (panes, active)", cast(i64, ed_pane_count()),
            cast(i64, ed_pane_active()), 0);
        return false;
    }
    if ed_buf_active() < 0 || ed_buf_active() >= ed_buf_count() {
        fail_i("active buffer (index, count)", cast(i64, ed_buf_active()),
            cast(i64, ed_buf_count()), 0);
        return false;
    }
    // The screen a terminal keeps: the cursor inside it, the scroll
    // region inside that, the scrollback inside the ring, and no half
    // of a two-cell glyph left without the other.
    if fz_term >= 0 {
        str broke = term_check(fz_term);
        if broke.len > 0 {
            fail("terminal invariant", broke);
            return false;
        }
    }
    // and every terminal pane's screen, which the pane keys and the
    // geometry actions resize under it
    for i32 p = 0; p < ed_pane_count(); p++ {
        // a pane is a document or a terminal and nothing else: a record
        // left half set reads as neither, and the searches for a
        // document pane then walk past it
        i32 pk = ed_pane_kind(p);
        if pk != PANE_DOC && pk != PANE_TERM {
            fail_i("pane kind", cast(i64, pk), cast(i64, PANE_DOC), cast(i64, PANE_TERM));
            return false;
        }
        i32 pt = ed_pane_term(p);
        if pt < 0 { continue; }
        str pb = term_check(pt);
        if pb.len > 0 {
            fail("terminal pane invariant", pb);
            return false;
        }
        str sb = ed_term_sel_check();
        if sb.len > 0 {
            fail("terminal selection invariant", sb);
            return false;
        }
    }
    // The gap buffer's own structure, checked first: a wild insert or
    // delete moves the gap outside the allocation, and that shows up
    // later as heap corruption rather than anything traceable.
    if tb.cap < 0 || tb.gap_start < 0 || tb.gap_start > tb.gap_end
        || tb.gap_end > tb.cap {
        fail("gap buffer bounds broken", "");
        print("  cap {} gap [{}, {}]\n", tb.cap, tb.gap_start, tb.gap_end);
        return false;
    }
    if tb.nlines < 1 {
        fail_i("nlines", cast(i64, tb.nlines), 1, 1);
        return false;
    }
    if cur_line < 0 || cur_line > tb.nlines - 1 {
        fail_i("caret line out of range", cast(i64, cur_line), 0,
            cast(i64, tb.nlines - 1));
        return false;
    }
    i64 ll = line_length(cur_line);
    if cur_col < 0 || cur_col > ll {
        fail_i("caret column out of range", cur_col, 0, ll);
        return false;
    }
    // top_line counts rows: lines outside a diff, and in a diff's panes
    // the paired rows, fillers included
    i32 nrows = ed_row_count();
    if top_line < 0 || top_line > nrows - 1 {
        fail_i("top_line out of range", cast(i64, top_line), 0,
            cast(i64, nrows - 1));
        return false;
    }
    if scroll_off < 0 || scroll_off >= font_line_h {
        fail_i("scroll_off out of range", cast(i64, scroll_off), 0,
            cast(i64, font_line_h - 1));
        return false;
    }
    if left_vcol < 0 {
        fail_i("left_vcol negative", cast(i64, left_vcol), 0, 0);
        return false;
    }
    if ed_undo_depth() < 0 || ed_undo_depth() > ed_undo_total() {
        fail_i("undo depth outside the journal", cast(i64, ed_undo_depth()),
            0, cast(i64, ed_undo_total()));
        return false;
    }
    // A selection is what the edit paths delete over, so an endpoint
    // outside the buffer is a wild tb_delete waiting to happen, and it
    // corrupts the heap rather than tripping a bounds check.
    i64 sa = 0;
    i64 sb = 0;
    if ed_sel_range(&sa, &sb) {
        i64 blen = tb_len();
        if sa < 0 || sa > blen {
            fail_i("selection start outside the buffer", sa, 0, blen);
            return false;
        }
        if sb < sa || sb > blen {
            fail_i("selection end outside the buffer", sb, sa, blen);
            return false;
        }
    }
    // with wrap, the rows kept per line are what the text gives now,
    // whatever the edits and switches between
    if ed_wrap_on() && !wrap_verify() {
        fail_i("wrap: the cached rows differ from a fresh count (rows, lines)",
            cast(i64, ed_row_count()), cast(i64, tb.nlines), 0);
        return false;
    }
    i32 nb = ed_buf_count();
    if nb < 1 || nb > BUF_MAX {
        fail_i("buffer count out of range", cast(i64, nb), 1, cast(i64, BUF_MAX));
        return false;
    }
    if ed_buf_active() < 0 || ed_buf_active() >= nb {
        fail_i("active buffer out of range", cast(i64, ed_buf_active()), 0,
            cast(i64, nb - 1));
        return false;
    }
    i32 np = ed_pane_count();
    if np < 1 || np > PANE_MAX {
        fail_i("pane count out of range", cast(i64, np), 1, cast(i64, PANE_MAX));
        return false;
    }
    if ed_pane_active() < 0 || ed_pane_active() >= np {
        fail_i("active pane out of range", cast(i64, ed_pane_active()), 0,
            cast(i64, np - 1));
        return false;
    }
    // the columns tile the editor area left to right with no gap or
    // overlap; the build's bottom pane, when there is one, is last and
    // spans the area under them
    i32 ncol = pane_cols();
    if ncol < 1 || ncol > COL_MAX || (ncol != np && !(ncol == np - 1 && pane_is_bottom(np - 1))) {
        fail_i("column count (columns, panes)", cast(i64, ncol), cast(i64, np), 0);
        return false;
    }
    if ncol != np {
        i32 bx0 = 0;
        i32 bx1 = 0;
        ed_pane_rect(np - 1, &bx0, &bx1);
        i32 by0 = ed_pane_y0(np - 1);
        i32 by1 = ed_pane_y1(np - 1);
        if bx0 != content_left() || bx1 != g_w {
            fail_i("bottom pane does not span the editor area", cast(i64, bx0), cast(i64, bx1), cast(i64, g_w));
            return false;
        }
        if by0 != ed_pane_y1(0) || by1 <= by0 || ed_pane_y1(0) <= 0 {
            fail_i("bottom pane does not start where the columns end", cast(i64, by0),
                cast(i64, ed_pane_y1(0)), cast(i64, by1));
            return false;
        }
        if ed_pane_kind(np - 1) != PANE_TERM {
            fail_i("bottom pane is not a terminal", cast(i64, ed_pane_kind(np - 1)), 0, 0);
            return false;
        }
    }
    i32 prev = content_left();
    for i32 i = 0; i < ncol; i++ {
        i32 x0 = 0;
        i32 x1 = 0;
        ed_pane_rect(i, &x0, &x1);
        if x0 != prev {
            fail_i("pane does not start where the previous one ended",
                cast(i64, x0), cast(i64, prev), cast(i64, prev));
            return false;
        }
        if x1 <= x0 {
            fail_i("pane has no width", cast(i64, x1 - x0), 1, cast(i64, g_w));
            return false;
        }
        prev = x1;
    }
    if prev != g_w {
        fail_i("panes do not fill the editor area", cast(i64, prev),
            cast(i64, g_w), cast(i64, g_w));
        return false;
    }
    // every line the frame build will touch must have a sane extent;
    // a bad one faults inside line_bytes rather than rendering wrong
    i32 last = top_line + visible_lines() + 1;
    if last > tb.nlines - 1 { last = tb.nlines - 1; }
    i64 blen = tb_len();
    for i32 l = top_line; l <= last; l++ {
        i64 s = tb_line_start(l);
        i64 e = tb_line_end(l);
        if s < 0 || s > blen {
            fail_i("line start outside the buffer", s, 0, blen);
            return false;
        }
        if e < s || e > blen {
            fail_i("line end before its start or past the buffer", e, s, blen);
            return false;
        }
    }
    if g_title_len < 0 || g_title_len > 2300 {
        fail_i("title length out of range", cast(i64, g_title_len), 0, 2300);
        return false;
    }
    if g_status_len < 0 || g_status_len > 128 {
        fail_i("status length out of range", cast(i64, g_status_len), 0, 128);
        return false;
    }
    // The caret sits where decoding the line lands. This was opt-in
    // while definition responses were read as byte columns; now that
    // they are converted from utf-16 it holds always. Decoding rather
    // than testing for a continuation byte, because a buffer can hold
    // bytes that are not valid utf-8 (a binary file, pasted bytes) and
    // movement walks those one byte at a time.
    if cur_col > 0 && cur_col < ll {
        i32 n = line_bytes(cur_line);
        i32 i = 0;
        while i < n && cast(i64, i) < cur_col {
            ignore utf8_next(g_linebuf, n, &i);
        }
        if cast(i64, i) != cur_col {
            print("  caret at byte {} of {}; decoding lands at {}\n",
                cur_col, n, i);
            fail("caret is not where decoding the line lands", "");
            return false;
        }
    }
    // No two cursors share a caret or overlap. Two that did would put
    // the same bytes through tb_delete twice, and each one's offsets
    // have to be inside the buffer for the same reason the anchor does.
    i32 nc = ed_cur_count();
    i64 blen2 = tb_len();
    for i32 i = 0; i < nc; i++ {
        i64 ci = 0;
        i64 ai = 0;
        i64 bi = 0;
        ed_cur_get(i, &ci, &ai, &bi);
        if ci < 0 || ci > blen2 || ai < 0 || bi > blen2 || ai > bi {
            print("  cursor {} of {}: {}..{} caret {}, buffer {}\n",
                i, nc, ai, bi, ci, blen2);
            fail("cursor outside the buffer", "");
            return false;
        }
        for i32 j = i + 1; j < nc; j++ {
            i64 cj = 0;
            i64 aj = 0;
            i64 bj = 0;
            ed_cur_get(j, &cj, &aj, &bj);
            // Ranges that only touch are two cursors, not one: Ctrl+D
            // on "aa" in "aaaa" gives exactly that, and their carets
            // then share the boundary. Only a real overlap, or two
            // bare carets in the same place, is a broken set.
            bool both = ai != bi && aj != bj;
            if (ai < bj && aj < bi) || (ci == cj && !both) {
                print("  cursors {} and {} of {}: {}..{} and {}..{}\n",
                    i, j, nc, ai, bi, aj, bj);
                fail("cursors overlap", "");
                return false;
            }
        }
    }
    return true;
}

// --- frame invariants ------------------------------------------------

private bool finite(f32 v) {
    if v != v { return false; }          // NaN
    if v > 1.0e9f || v < -1.0e9f { return false; }
    return true;
}

private void hash_frame() {
    for i32 i = 0; i < draw_nverts; i++ {
        u32 c = draw_verts[i].col;
        i32 x = cast(i32, draw_verts[i].x * 16.0f);
        i32 y = cast(i32, draw_verts[i].y * 16.0f);
        u64 v = cast(u64, cast(i64, x) * 131071 + cast(i64, y) * 8191) + cast(u64, c);
        fz_frame_hash = (fz_frame_hash ^ v) * 1099511628211;
    }
}

private bool check_frame() {
    if draw_nverts < 0 || draw_nverts > DRAW_MAX_VERTS {
        fail_i("vertex count out of range", cast(i64, draw_nverts), 0,
            cast(i64, DRAW_MAX_VERTS));
        return false;
    }
    if draw_nverts % 6 != 0 {
        fail_i("vertex count is not a whole number of quads",
            cast(i64, draw_nverts % 6), 0, 0);
        return false;
    }
    // draw_quad drops quads once the batch is full, so a frame that
    // reaches the cap has been silently truncated
    if draw_nverts + 6 > DRAW_MAX_VERTS {
        fail("quad batch overflowed; the frame was truncated", "");
        return false;
    }
    // One caret quad per cursor at most. Fewer is normal (the blink is
    // off, a cursor is scrolled out, an overlay owns the caret); more
    // means the render loop drew one of them twice.
    i32 carets = 0;
    for i32 i = 0; i < draw_nverts; i += 6 {
        if draw_verts[i].col == C_CARET { carets++; }
    }
    // a focused terminal pane draws its own cursor in the caret color,
    // one quad, and no editor cursor
    i32 allowed = ed_cur_count();
    if ed_term_active() >= 0 { allowed = 1; }
    if carets > allowed {
        fail_i("more caret quads than cursors", cast(i64, carets), 0,
            cast(i64, allowed));
        return false;
    }

    // a partial tree row is allowed to hang past the bottom edge
    f32 slack = cast(f32, font_line_h * 2 + 16);
    f32 xlo = 0.0f - slack;
    f32 xhi = cast(f32, g_w) + slack;
    f32 ylo = cast(f32, 0 - g_caption_h) - slack;
    f32 yhi = cast(f32, g_h) + slack;
    for i32 i = 0; i < draw_nverts; i++ {
        DrawVtx* v = draw_verts + i;
        if !finite(v.x) || !finite(v.y) {
            fail("vertex position is not finite", "");
            return false;
        }
        if !finite(v.u) || !finite(v.v) {
            fail("vertex texcoord is not finite", "");
            return false;
        }
        if v.x < xlo || v.x > xhi {
            fail_i("vertex x outside the window", cast(i64, v.x),
                cast(i64, xlo), cast(i64, xhi));
            return false;
        }
        if v.y < ylo || v.y > yhi {
            fail_i("vertex y outside the window", cast(i64, v.y),
                cast(i64, ylo), cast(i64, yhi));
            return false;
        }
        // a glyph drawn scaled carries its u as -u - 1 (draw_transform)
        f32 u = v.u;
        if u < -0.5f { u = -u - 1.0f; }
        if u < -0.001f || u > 1.001f || v.v < -0.001f || v.v > 1.001f {
            fail("vertex samples outside the atlas", "");
            return false;
        }
    }
    hash_frame();
    return true;
}

// --- mock language server --------------------------------------------
// Reads the client's request stream out of the capture buffer, then
// answers on its own schedule with responses that get progressively
// less well behaved.

private const i32 MOCK_PEND_MAX = 64;
private const i32 MOCK_KIND_INIT = 1;
private const i32 MOCK_KIND_DEF = 2;
private const i32 MOCK_KIND_HOVER = 3;
private const i32 MOCK_KIND_CMP = 4;
private const i32 MOCK_KIND_REF = 5;
private const i32 MOCK_KIND_SYM = 6;
private const i32 MOCK_KIND_SEM = 7;
private const i32 MOCK_KIND_CPREP = 8;   // prepareCallHierarchy
private const i32 MOCK_KIND_CROWS = 9;   // incomingCalls, outgoingCalls

private i32[MOCK_PEND_MAX] mock_id;
private i32[MOCK_PEND_MAX] mock_kind;
private i32 mock_npend = 0;
private i64 mock_read_pos = 0;
private bool mock_init_done = false;

private u8* mock_buf = null;          // payload under construction
private const i64 MOCK_BUF_CAP = 1024 * 1024;

// Repo files, for uris that point at something real.
private i32 mock_nfiles = 0;

private str mock_file(i32 i) {
    if mock_nfiles == 0 { return "src/ed.mc"; }
    return pick_file_path(i % mock_nfiles);
}

private void mock_pend_add(i32 id, i32 kind) {
    if mock_npend == MOCK_PEND_MAX { return; }
    mock_id[mock_npend] = id;
    mock_kind[mock_npend] = kind;
    mock_npend++;
}

private void mock_pend_drop(i32 i) {
    for i32 k = i; k + 1 < mock_npend; k++ {
        mock_id[k] = mock_id[k + 1];
        mock_kind[k] = mock_kind[k + 1];
    }
    mock_npend--;
}

// Split Content-Length frames out of what the client wrote and record
// every request that wants an answer.
private void mock_scan() {
    if fz_out == null { return; }
    while true {
        i64 he = -1;
        for i64 i = mock_read_pos; i + 3 < fz_out_len; i++ {
            if fz_out[i] == 13 && fz_out[i + 1] == 10
                && fz_out[i + 2] == 13 && fz_out[i + 3] == 10 {
                he = i;
                break;
            }
        }
        if he < 0 { return; }
        i64 clen = 0;
        str key = "Content-Length:";
        for i64 i = mock_read_pos; i + key.len < he; i++ {
            bool m = true;
            for i32 k = 0; k < key.len; k++ {
                if fz_out[i + k] != key.data[k] { m = false; break; }
            }
            if m {
                i64 j = i + key.len;
                while j < he && fz_out[j] == ' ' { j++; }
                while j < he && fz_out[j] >= '0' && fz_out[j] <= '9' {
                    clen = clen * 10 + cast(i64, fz_out[j] - '0');
                    j++;
                }
                break;
            }
        }
        i64 body = he + 4;
        if clen <= 0 {
            proto_fail("outgoing frame without a Content-Length");
            return;
        }
        if body + clen > fz_out_len { return; }
        JDoc d;
        i32 root = json_parse(&d, fz_out + body, clen);
        proto_check(&d, root);
        if root >= 0 {
            i32 jid = jd_get(&d, root, "id");
            i32 jm = jd_get(&d, root, "method");
            if jid >= 0 && jm >= 0 {
                str method = jd_str(&d, jm);
                i32 id = cast(i32, jd_int(&d, jid));
                if str_equal(method, "initialize") {
                    mock_pend_add(id, MOCK_KIND_INIT);
                } else if str_equal(method, "textDocument/definition") {
                    mock_pend_add(id, MOCK_KIND_DEF);
                } else if str_equal(method, "textDocument/hover") {
                    mock_pend_add(id, MOCK_KIND_HOVER);
                } else if str_equal(method, "textDocument/completion") {
                    mock_pend_add(id, MOCK_KIND_CMP);
                } else if str_equal(method, "textDocument/references") {
                    mock_pend_add(id, MOCK_KIND_REF);
                } else if str_equal(method, "workspace/symbol") {
                    mock_pend_add(id, MOCK_KIND_SYM);
                } else if str_equal(method, "textDocument/semanticTokens/full") {
                    mock_pend_add(id, MOCK_KIND_SEM);
                } else if str_equal(method, "textDocument/prepareCallHierarchy") {
                    mock_pend_add(id, MOCK_KIND_CPREP);
                } else if str_equal(method, "callHierarchy/incomingCalls")
                    || str_equal(method, "callHierarchy/outgoingCalls") {
                    mock_pend_add(id, MOCK_KIND_CROWS);
                }
            }
        }
        json_free(&d);
        mock_read_pos = body + clen;
    }
}

// Frame a payload and hand it to lsp_feed in one to three pieces, so
// the client's accumulator sees partial frames the way a real pipe
// delivers them.
private void mock_emit(u8* payload, i64 n, bool truncate_header) {
    noinit u8[64] hdr;
    i64 ho = 0;
    str h = "Content-Length: ";
    memcpy(&hdr[0], h.data, h.len);
    ho = h.len;
    i64 declared = n;
    if truncate_header { declared = n + 16; }   // claims more than it sends
    ho = jw_int(&hdr[0], ho, declared);
    hdr[ho] = 13; ho++;
    hdr[ho] = 10; ho++;
    hdr[ho] = 13; ho++;
    hdr[ho] = 10; ho++;

    i64 total = ho + n;
    u8* frame = alloc<u8>(total + 1);
    memcpy(frame, &hdr[0], ho);
    memcpy(frame + ho, payload, n);

    i32 pieces = 1 + rnd_n(3);
    i64 at = 0;
    for i32 p = 0; p < pieces; p++ {
        i64 rest = total - at;
        if rest <= 0 { break; }
        i64 take = rest;
        if p + 1 < pieces && rest > 1 { take = 1 + cast(i64, rnd_n(cast(i32, rest))); }
        ev_feed(frame + at, take);
        at += take;
    }
    free(frame);
}

// A uri for `path` in one of the shapes the client has to survive.
private i64 mock_uri(u8* out, str path, i32 shape) {
    i64 o = 0;
    if shape == 7 { return 0; }                       // empty
    if shape == 8 { return jw_raw(out, o, "untitled:Untitled-1"); }
    if shape == 10 {
        o = jw_raw(out, o, "file:///C:/ws/");
        for i32 i = 0; i < 400; i++ { o = jw_raw(out, o, "deep/"); }
        return jw_raw(out, o, "x.mc");
    }
    if shape == 3 { o = jw_raw(out, o, "file://C:/ws/"); }        // two slashes
    else if shape == 1 { o = jw_raw(out, o, "file:///C%3A/ws/"); }
    else if shape == 2 { o = jw_raw(out, o, "file:///c:/ws/"); }
    else if shape == 5 { o = jw_raw(out, o, "file:///C:/elsewhere/"); }
    else { o = jw_raw(out, o, "file:///C:/ws/"); }
    if shape == 6 {
        o = jw_raw(out, o, "no_such_file_");
        o = jw_int(out, o, cast(i64, rnd_n(1000)));
        return jw_raw(out, o, ".mc");
    }
    for i32 i = 0; i < path.len; i++ {
        u8 c = path.data[i];
        if shape == 4 && c == '/' { c = 92; }         // backslash separators
        out[o] = c;
        o++;
    }
    if shape == 9 { o = jw_raw(out, o, "%ZZ"); }      // bad percent escape
    return o;
}

// A position, valid or not.
private i64 mock_pos(u8* out, i64 o, i32 kind) {
    i64 line = 0;
    i64 ch = 0;
    if kind == 0 {
        line = cast(i64, rnd_n(200));
        ch = cast(i64, rnd_n(80));
    } else if kind == 1 {
        line = 0;
        ch = 0;
    } else if kind == 2 {
        line = 1073741824;
        ch = 1073741824;
    } else if kind == 3 {
        line = -1;
        ch = -1;
    } else if kind == 4 {
        line = cast(i64, tb.nlines);
        ch = cast(i64, rnd_n(4096));
    } else {
        line = cast(i64, rnd_n(4)) - 2;
        ch = cast(i64, rnd_n(100000));
    }
    o = jw_raw(out, o, "{\"line\":");
    o = jw_int(out, o, line);
    o = jw_raw(out, o, ",\"character\":");
    o = jw_int(out, o, ch);
    return jw_raw(out, o, "}");
}

private i64 mock_location(u8* out, i64 o) {
    noinit u8[4096] uri;
    i64 un = mock_uri(&uri[0], mock_file(rnd_n(64)), rnd_n(11));
    o = jw_raw(out, o, "{\"uri\":\"");
    o = jw_esc(out, o, &uri[0], un);
    o = jw_raw(out, o, "\",\"range\":{\"start\":");
    o = mock_pos(out, o, rnd_n(6));
    o = jw_raw(out, o, ",\"end\":");
    o = mock_pos(out, o, rnd_n(6));
    return jw_raw(out, o, "}}");
}

// a reply's opening into mock_buf, up to the id; the offset after it
private i64 mock_begin(i32 id) {
    if mock_buf == null { mock_buf = alloc<u8>(MOCK_BUF_CAP); }
    i64 o = jw_raw(mock_buf, 0, "{\"jsonrpc\":\"2.0\",\"id\":");
    return jw_int(mock_buf, o, cast(i64, id));
}

private void mock_answer_def(i32 id) {
    i64 o = mock_begin(id);
    u8* b = mock_buf;
    i32 shape = rnd_n(10);
    if shape == 0 {
        o = jw_raw(b, o, ",\"result\":null}");
    } else if shape == 1 {
        o = jw_raw(b, o, ",\"result\":[]}");
    } else if shape == 2 {
        o = jw_raw(b, o, ",\"result\":");
        o = mock_location(b, o);
        o = jw_raw(b, o, "}");
    } else if shape == 3 {
        o = jw_raw(b, o, ",\"result\":[");
        i32 n = 1 + rnd_n(4);
        for i32 i = 0; i < n; i++ {
            if i > 0 { o = jw_raw(b, o, ","); }
            o = mock_location(b, o);
        }
        o = jw_raw(b, o, "]}");
    } else if shape == 4 {
        o = jw_raw(b, o, ",\"result\":[{}]}");
    } else if shape == 5 {
        o = jw_raw(b, o, ",\"result\":{\"uri\":\"file:///C:/ws/src/ed.mc\"}}");
    } else if shape == 6 {
        o = jw_raw(b, o, ",\"result\":{\"range\":{\"start\":{\"line\":1,\"character\":1}}}}");
    } else if shape == 7 {
        o = jw_raw(b, o, ",\"result\":{\"uri\":\"file:///C:/ws/src/ed.mc\",\"range\":{\"start\":{}}}}");
    } else if shape == 8 {
        o = jw_raw(b, o, ",\"error\":{\"code\":-32603,\"message\":\"internal\"}}");
    } else {
        o = jw_raw(b, o, ",\"result\":\"not an object\"}");
    }
    mock_emit(b, o, false);
}

// hover contents in every shape the spec allows, plus the ones a
// server has no business sending
private void mock_answer_hover(i32 id) {
    i64 o = mock_begin(id);
    u8* b = mock_buf;
    i32 shape = rnd_n(9);
    if shape == 0 {
        o = jw_raw(b, o, ",\"result\":null}");
    } else if shape == 1 {
        o = jw_raw(b, o, ",\"result\":{\"contents\":\"a plain string\"}}");
    } else if shape == 2 {
        o = jw_raw(b, o, ",\"result\":{\"contents\":{\"kind\":\"markdown\",\"value\":\"```minc\nfn thing(i32 a) -> i32\n```\nDoes a thing.\"}}}");
    } else if shape == 3 {
        o = jw_raw(b, o, ",\"result\":{\"contents\":[{\"language\":\"minc\",\"value\":\"i32 x\"},\"and a note\"]}}");
    } else if shape == 4 {
        o = jw_raw(b, o, ",\"result\":{\"contents\":\"\"}}");
    } else if shape == 5 {
        o = jw_raw(b, o, ",\"result\":{}}");
    } else if shape == 6 {
        // longer than the popup will hold, and full of newlines
        o = jw_raw(b, o, ",\"result\":{\"contents\":\"");
        for i32 i = 0; i < 200; i++ { o = jw_raw(b, o, "a line of documentation\n"); }
        o = jw_raw(b, o, "\"}}");
    } else if shape == 7 {
        o = jw_raw(b, o, ",\"result\":{\"contents\":[]}}");
    } else {
        o = jw_raw(b, o, ",\"result\":{\"contents\":42}}");
    }
    mock_emit(b, o, false);
}

// completion in the shapes the spec allows, plus items a server has
// no business sending
private void mock_answer_cmp(i32 id) {
    i64 o = mock_begin(id);
    u8* b = mock_buf;
    i32 shape = rnd_n(7);
    if rnd_1in(2) { shape = 3; }   // often a list that can actually match
    if shape == 0 {
        o = jw_raw(b, o, ",\"result\":null}");
    } else if shape == 1 {
        o = jw_raw(b, o, ",\"result\":[]}");
    } else if shape == 2 {
        o = jw_raw(b, o, ",\"result\":{\"isIncomplete\":false,\"items\":[]}}");
    } else if shape == 3 {
        // one label per letter, so whatever single character was typed
        // has something to match; otherwise the list is filtered away
        // the moment it arrives and the popup is never seen
        o = jw_raw(b, o, ",\"result\":[");
        for i32 c = 0; c < 26; c++ {
            if c > 0 { o = jw_raw(b, o, ","); }
            o = jw_raw(b, o, "{\"label\":\"");
            b[o] = cast(u8, 'a' + c);
            o++;
            o = jw_raw(b, o, "_candidate\",\"detail\":\"i32\"");
            // sortText in every shape: a scope rank, no digits, a
            // number rather than a string, or missing
            i32 sk = rnd_n(4);
            if sk == 0 {
                o = jw_raw(b, o, ",\"sortText\":\"000_a\"");
            } else if sk == 1 {
                o = jw_raw(b, o, ",\"sortText\":\"zz\"");
            } else if sk == 2 {
                o = jw_raw(b, o, ",\"sortText\":7");
            }
            o = jw_raw(b, o, "}");
        }
        o = jw_raw(b, o, "]}");
    } else if shape == 4 {
        // a list wrapper, and a label that is not a string
        o = jw_raw(b, o, ",\"result\":{\"items\":[{\"label\":\"wrapped\",\"detail\":\"fn()\"},{\"detail\":\"no label\"},{\"label\":\"\"}]}}");
    } else if shape == 5 {
        // more than the popup will hold, with long labels
        o = jw_raw(b, o, ",\"result\":[");
        i32 n = 200 + rnd_n(600);
        for i32 i = 0; i < n && o < MOCK_BUF_CAP - 4096; i++ {
            if i > 0 { o = jw_raw(b, o, ","); }
            o = jw_raw(b, o, "{\"label\":\"item");
            o = jw_int(b, o, cast(i64, i));
            o = jw_raw(b, o, "_padding_padding_padding_padding_padding\"}");
        }
        o = jw_raw(b, o, "]}");
    } else {
        o = jw_raw(b, o, ",\"result\":[{\"label\":42},{\"label\":\"ok\"}]}");
    }
    mock_emit(b, o, false);
}

// references: the same Location array a definition uses, so the uri
// and position shapes are already hostile; the count is what is new
// workspace/symbol: SymbolInformation items, from valid to hostile,
// and more of them than the overlay keeps
private void mock_answer_syms(i32 id) {
    i64 o = mock_begin(id);
    u8* b = mock_buf;
    i32 shape = rnd_n(6);
    if shape == 0 {
        o = jw_raw(b, o, ",\"result\":null}");
    } else if shape == 1 {
        o = jw_raw(b, o, ",\"result\":[]}");
    } else if shape == 2 {
        o = jw_raw(b, o, ",\"result\":{\"not\":\"an array\"}}");
    } else {
        o = jw_raw(b, o, ",\"result\":[");
        i32 n = 1 + rnd_n(700);      // past SYM_MAX on purpose
        for i32 i = 0; i < n && o < MOCK_BUF_CAP - 8192; i++ {
            if i > 0 { o = jw_raw(b, o, ","); }
            i32 bad = rnd_n(8);
            if bad == 0 {
                o = jw_raw(b, o, "{\"name\":7,\"location\":");       // not a string
            } else if bad == 1 {
                o = jw_raw(b, o, "{\"name\":\"x\"}");                 // no location
                continue;
            } else if bad == 2 {
                o = jw_raw(b, o, "{\"name\":\"\",\"kind\":12,\"location\":");
            } else {
                o = jw_raw(b, o, "{\"name\":\"sym_");
                o = jw_int(b, o, cast(i64, rnd_n(50)));
                o = jw_raw(b, o, "\",\"kind\":");
                o = jw_int(b, o, cast(i64, rnd_n(27)));
                o = jw_raw(b, o, ",\"location\":");
            }
            o = mock_location(b, o);
            o = jw_raw(b, o, "}");
        }
        o = jw_raw(b, o, "]}");
    }
    mock_emit(b, o, false);
}

private void mock_answer_refs(i32 id) {
    i64 o = mock_begin(id);
    u8* b = mock_buf;
    i32 shape = rnd_n(5);
    if shape == 0 {
        o = jw_raw(b, o, ",\"result\":null}");
    } else if shape == 1 {
        o = jw_raw(b, o, ",\"result\":[]}");
    } else if shape == 2 {
        o = jw_raw(b, o, ",\"result\":{\"not\":\"an array\"}}");
    } else {
        o = jw_raw(b, o, ",\"result\":[");
        i32 n = 1 + rnd_n(600);      // past the buffered cap on purpose
        for i32 i = 0; i < n && o < MOCK_BUF_CAP - 8192; i++ {
            if i > 0 { o = jw_raw(b, o, ","); }
            o = mock_location(b, o);
        }
        o = jw_raw(b, o, "]}");
    }
    mock_emit(b, o, false);
}

// a CallHierarchyItem for the call graph: a name, one of the mock's
// files (or a bad uri), a range that may be backwards or past the end
private i64 mock_call_item(u8* b, i64 o) {
    noinit u8[4096] uri;
    i64 un = mock_uri(&uri[0], mock_file(rnd_n(64)), rnd_n(11));
    o = jw_raw(b, o, "{\"name\":\"fn_");
    o = jw_int(b, o, cast(i64, rnd_n(40)));
    o = jw_raw(b, o, "\",\"kind\":12,\"uri\":\"");
    o = jw_esc(b, o, &uri[0], un);
    o = jw_raw(b, o, "\",\"range\":{\"start\":");
    o = mock_pos(b, o, rnd_n(6));
    o = jw_raw(b, o, ",\"end\":");
    o = mock_pos(b, o, rnd_n(6));
    o = jw_raw(b, o, "},\"selectionRange\":{\"start\":");
    o = mock_pos(b, o, rnd_n(6));
    o = jw_raw(b, o, ",\"end\":");
    o = mock_pos(b, o, rnd_n(6));
    o = jw_raw(b, o, "}");
    if rnd_1in(2) { o = jw_raw(b, o, ",\"detail\":\"i32 fn(u8* p, i32 n)\""); }
    return jw_raw(b, o, "}");
}

// prepareCallHierarchy: null, nothing, the not-ready error, or an item
private void mock_answer_cprep(i32 id) {
    i64 o = mock_begin(id);
    u8* b = mock_buf;
    i32 shape = rnd_n(6);
    if shape == 0 {
        o = jw_raw(b, o, ",\"result\":null}");
    } else if shape == 1 {
        o = jw_raw(b, o, ",\"result\":[]}");
    } else if shape == 2 {
        o = jw_raw(b, o, ",\"error\":{\"code\":-32801,\"message\":\"workspace index not ready\"}}");
    } else {
        o = jw_raw(b, o, ",\"result\":[");
        o = mock_call_item(b, o);
        o = jw_raw(b, o, "]}");
    }
    mock_emit(b, o, false);
}

// incomingCalls or outgoingCalls: each row carries both "from" and "to",
// so one answer fits either request
private void mock_answer_crows(i32 id) {
    i64 o = mock_begin(id);
    u8* b = mock_buf;
    i32 shape = rnd_n(6);
    if shape == 0 {
        o = jw_raw(b, o, ",\"result\":null}");
    } else if shape == 1 {
        o = jw_raw(b, o, ",\"error\":{\"code\":-32801,\"message\":\"workspace index not ready\"}}");
    } else {
        o = jw_raw(b, o, ",\"result\":[");
        i32 n = rnd_n(4);
        if rnd_1in(3) { n = rnd_n(300); }    // past the row's cap at times
        for i32 i = 0; i < n && o < MOCK_BUF_CAP - 16384; i++ {
            if i > 0 { o = jw_raw(b, o, ","); }
            o = jw_raw(b, o, "{\"from\":");
            o = mock_call_item(b, o);
            o = jw_raw(b, o, ",\"to\":");
            o = mock_call_item(b, o);
            o = jw_raw(b, o, ",\"fromRanges\":[");
            i32 k = rnd_n(3);
            for i32 j = 0; j < k; j++ {
                if j > 0 { o = jw_raw(b, o, ","); }
                o = jw_raw(b, o, "{\"start\":");
                o = mock_pos(b, o, rnd_n(6));
                o = jw_raw(b, o, ",\"end\":");
                o = mock_pos(b, o, rnd_n(6));
                o = jw_raw(b, o, "}");
            }
            o = jw_raw(b, o, "]}");
        }
        o = jw_raw(b, o, "]}");
    }
    mock_emit(b, o, false);
}

private void mock_answer_init(i32 id) {
    i64 o = mock_begin(id);
    u8* b = mock_buf;
    // half the runs get incremental sync with byte columns, the other
    // half the full-text mode; the shadow document below checks both
    if rnd_n(2) == 1 {
        o = jw_raw(b, o, ",\"result\":{\"capabilities\":{\"definitionProvider\":true,\"callHierarchyProvider\":true,\"positionEncoding\":\"utf-8\",\"textDocumentSync\":{\"change\":2},\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"variable\",\"function\",\"type\",\"property\"],\"tokenModifiers\":[]},\"full\":true}}}}");
    } else {
        o = jw_raw(b, o, ",\"result\":{\"capabilities\":{\"definitionProvider\":true,\"callHierarchyProvider\":true,\"textDocumentSync\":1}}}");
    }
    mock_emit(b, o, false);
    mock_init_done = true;
}

private void mock_diagnostics() {
    if mock_buf == null { mock_buf = alloc<u8>(MOCK_BUF_CAP); }
    u8* b = mock_buf;
    noinit u8[4096] uri;
    i64 un = mock_uri(&uri[0], mock_file(rnd_n(64)), rnd_n(11));
    i64 o = jw_raw(b, 0, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
    o = jw_esc(b, o, &uri[0], un);
    o = jw_raw(b, o, "\",\"diagnostics\":[");
    // deliberately reaches past LSP_MAX_DIAGS sometimes
    i32 n = rnd_n(300);
    for i32 i = 0; i < n; i++ {
        if o > MOCK_BUF_CAP - 8192 { break; }
        if i > 0 { o = jw_raw(b, o, ","); }
        o = jw_raw(b, o, "{\"range\":{\"start\":");
        o = mock_pos(b, o, rnd_n(6));
        o = jw_raw(b, o, ",\"end\":");
        o = mock_pos(b, o, rnd_n(6));
        o = jw_raw(b, o, "},\"severity\":");
        o = jw_int(b, o, cast(i64, rnd_n(10)) - 1);
        o = jw_raw(b, o, ",\"message\":\"");
        i32 mk = rnd_n(4);
        if mk == 0 {
            o = jw_raw(b, o, "expected \\\"}\\\" here\\n  line two\\ttab");
        } else if mk == 1 {
            o = jw_raw(b, o, "caf\\u00e9 \\u00e9t\\u00e9 \\\\ back");
        } else if mk == 2 {
            for i32 k = 0; k < 200; k++ { o = jw_raw(b, o, "long "); }
        }
        o = jw_raw(b, o, "\"}");
    }
    o = jw_raw(b, o, "]}}");
    mock_emit(b, o, false);
}

// Semantic tokens: a plausible stream over the first lines, or one of
// the shapes a client must survive: nothing, junk, negative deltas,
// a span past the line, an out-of-order stream, a type past the legend.
private void mock_answer_sem(i32 id) {
    i64 o = mock_begin(id);
    u8* b = mock_buf;
    i32 shape = rnd_n(8);
    if shape == 0 {
        o = jw_raw(b, o, ",\"result\":null}");
    } else if shape == 1 {
        o = jw_raw(b, o, ",\"result\":{\"data\":[]}}");
    } else if shape == 2 {
        o = jw_raw(b, o, ",\"result\":{\"data\":\"not an array\"}}");
    } else if shape == 3 {
        o = jw_raw(b, o, ",\"result\":{\"data\":[0,4,-3,1,0,2,0,5,1,0]}}");
    } else if shape == 4 {
        o = jw_raw(b, o, ",\"result\":{\"data\":[0,0,9999999,2,0]}}");
    } else if shape == 5 {
        o = jw_raw(b, o, ",\"result\":{\"data\":[3,0,4,0,0,0,2,3,1,0,0,1,2,7,0,1,2]}}");
    } else {
        // a stream over the first lines: a few tokens per line, types
        // from the four the mock's legend would carry
        o = jw_raw(b, o, ",\"result\":{\"data\":[");
        i32 nt = rnd_n(60);
        i32 line = 0;
        for i32 i = 0; i < nt; i++ {
            if i > 0 { o = jw_raw(b, o, ","); }
            i32 dl = rnd_n(3);
            i32 dc = 1 + rnd_n(12);
            if dl > 0 { dc = rnd_n(30); }
            o = jw_int(b, o, cast(i64, dl));
            o = jw_raw(b, o, ",");
            o = jw_int(b, o, cast(i64, dc));
            o = jw_raw(b, o, ",");
            o = jw_int(b, o, cast(i64, 1 + rnd_n(9)));
            o = jw_raw(b, o, ",");
            o = jw_int(b, o, cast(i64, rnd_n(5)));
            o = jw_raw(b, o, ",0");
            line += dl;
        }
        o = jw_raw(b, o, "]}}");
    }
    mock_emit(b, o, false);
}

// Frames that are not valid traffic at all.
private void mock_junk() {
    if mock_buf == null { mock_buf = alloc<u8>(MOCK_BUF_CAP); }
    u8* b = mock_buf;
    i32 k = rnd_n(7);
    i64 o = 0;
    if k == 0 {
        o = jw_raw(b, 0, "{\"jsonrpc\":\"2.0\",\"id\":999999,\"result\":{}}");
    } else if k == 1 {
        o = jw_raw(b, 0, "{ not json at all ");
    } else if k == 2 {
        o = jw_raw(b, 0, "[1,2,3]");
    } else if k == 3 {
        o = jw_raw(b, 0, "\"just a string\"");
    } else if k == 4 {
        o = 0;                                   // Content-Length: 0
    } else if k == 5 {
        o = jw_raw(b, 0, "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":3,\"message\":\"hi\"}}");
    } else {
        // a header that promises more than it delivers, then the
        // missing bytes as filler so the stream resyncs
        o = jw_raw(b, 0, "{\"jsonrpc\":\"2.0\"}");
        mock_emit(b, o, true);
        noinit u8[16] pad;
        for i32 i = 0; i < 16; i++ { pad[i] = ' '; }
        ev_feed(&pad[0], 16);
        return;
    }
    mock_emit(b, o, false);
}

// Answer every request of one kind now. The actions that need a whole
// round trip inside a single step use this: mock_tick answers at most
// one pending request and picks at random, so the reply an action is
// waiting for usually would not arrive before the next action closed
// the thing it was going to open.
private void mock_flush_kind(i32 want) {
    mock_scan();
    i32 i = 0;
    while i < mock_npend {
        if mock_kind[i] != want {
            i++;
            continue;
        }
        i32 id = mock_id[i];
        mock_pend_drop(i);
        if want == MOCK_KIND_CMP { mock_answer_cmp(id); }
        else if want == MOCK_KIND_SYM { mock_answer_syms(id); }
        else if want == MOCK_KIND_HOVER { mock_answer_hover(id); }
        else if want == MOCK_KIND_SEM { mock_answer_sem(id); }
        else if want == MOCK_KIND_REF { mock_answer_refs(id); }
        else if want == MOCK_KIND_CPREP { mock_answer_cprep(id); }
        else if want == MOCK_KIND_CROWS { mock_answer_crows(id); }
        else { mock_answer_def(id); }
    }
}

// One server turn: answer something, or speak unprompted.
private void mock_tick() {
    mock_scan();
    // the handshake always succeeds; everything after it is fair game
    for i32 i = 0; i < mock_npend; i++ {
        if mock_kind[i] == MOCK_KIND_INIT {
            mock_answer_init(mock_id[i]);
            mock_pend_drop(i);
            return;
        }
    }
    if mock_npend > 0 && !rnd_1in(4) {
        i32 i = rnd_n(mock_npend);          // out of order on purpose
        i32 id = mock_id[i];
        i32 kind = mock_kind[i];
        mock_pend_drop(i);
        if rnd_1in(8) { return; }           // sometimes never answer
        if kind == MOCK_KIND_SEM {
            mock_answer_sem(id);
            return;
        }
        if kind == MOCK_KIND_HOVER {
            mock_answer_hover(id);
            return;
        }
        if kind == MOCK_KIND_CMP {
            mock_answer_cmp(id);
            return;
        }
        if kind == MOCK_KIND_SYM { mock_answer_syms(id); }
        if kind == MOCK_KIND_REF {
            mock_answer_refs(id);
            return;
        }
        if kind == MOCK_KIND_CPREP {
            mock_answer_cprep(id);
            return;
        }
        if kind == MOCK_KIND_CROWS {
            mock_answer_crows(id);
            return;
        }
        mock_answer_def(id);
        if rnd_1in(6) { mock_answer_def(id); }   // duplicate response
        return;
    }
    if rnd_1in(6) { mock_diagnostics(); return; }
    if rnd_1in(10) { mock_junk(); }
}

// --- actions ---------------------------------------------------------

private i32 rnd_mods() {
    i32 m = 0;
    if rnd_1in(3) { m = m | MOD_SHIFT; }
    if rnd_1in(6) { m = m | MOD_ALT; }
    if rnd_1in(8) { m = m | MOD_CTRL; }
    return m;
}

private i32 rnd_x() { return rnd_n(g_w + 40) - 20; }
private i32 rnd_y() { return rnd_n(g_h + 40) - 20; }

private void type_word() {
    i32 n = 1 + rnd_n(6);
    for i32 i = 0; i < n; i++ {
        ev_char(cast(u32, 'a' + rnd_n(26)));
    }
}

private str do_type() {
    i32 k = rnd_n(10);
    if k < 5 {
        ev_char(cast(u32, 32 + rnd_n(95)));
        return "type ascii";
    }
    if k < 7 {
        // 2, 3 and 4 byte codepoints, including a wide one
        u32[6] cps = { 0xE9, 0x3B1, 0x4E2D, 0x1F600, 0x2018, 0x00FF };
        ev_char(cps[rnd_n(6)]);
        return "type utf8";
    }
    if k == 7 { ev_char(13); return "enter"; }
    if k == 8 { ev_char(9); return "tab"; }
    ev_char(8);
    return "backspace";
}

private str do_move() {
    // word wrap on or off: the moves then walk rows
    if rnd_1in(12) {
        ev_key('Z', MOD_ALT);
        return "toggle word wrap";
    }
    i32[8] keys = { K_LEFT, K_RIGHT, K_UP, K_DOWN, K_HOME, K_END, K_PGUP, K_PGDN };
    ev_key(keys[rnd_n(8)], rnd_mods());
    return "move";
}

private str do_edit_op() {
    i32 k = rnd_n(8);
    if k == 0 { ev_key('Z', MOD_CTRL); return "undo"; }
    if k == 1 { ev_key('Z', MOD_CTRL | MOD_SHIFT); return "redo"; }
    if k == 2 { ev_key('Y', MOD_CTRL); return "redo (ctrl+y)"; }
    if k == 3 { ev_key(K_DELETE, rnd_mods() & MOD_CTRL); return "delete"; }
    if k == 4 { ev_char(127); return "delete word left"; }
    if k == 5 { ev_key('K', MOD_CTRL | MOD_SHIFT); return "delete line"; }
    if k == 6 { ev_key('/', MOD_CTRL); return "toggle comment"; }
    i32 dir = K_UP;
    if rnd_1in(2) { dir = K_DOWN; }
    i32 mods = MOD_ALT;
    if rnd_1in(2) { mods = MOD_ALT | MOD_SHIFT; }
    ev_key(dir, mods);
    return "move/copy line";
}

private str do_clipboard() {
    i32 k = rnd_n(4);
    if k == 0 { ev_key('A', MOD_CTRL); return "select all"; }
    if k == 1 { ev_key('C', MOD_CTRL); return "copy"; }
    if k == 2 { ev_key('X', MOD_CTRL); return "cut"; }
    ev_key('V', MOD_CTRL);
    return "paste";
}

private str do_mouse() {
    i32 k = rnd_n(8);
    i32 x = rnd_x();
    i32 y = rnd_y();
    if fz_vv {
        say("  mouse k=");
        say_i(cast(i64, k));
        say(" x=");
        say_i(cast(i64, x));
        say(" y=");
        say_i(cast(i64, y));
        say(" left=");
        say_i(cast(i64, content_left()));
        say("\n");
    }
    if k == 0 {
        ev_mouse(x, y, 0, true, MOD_CTRL);
        return "ctrl+click (goto definition)";
    }
    if k < 3 {
        ev_mouse(x, y, 0, true, rnd_mods() & MOD_SHIFT);
        return "click";
    }
    if k == 3 {
        if rnd_1in(3) {
            // near or past the top or bottom edge, and the autoscroll's
            // timer, which runs only while a selecting drag is there
            if rnd_1in(2) { y = doc_top() + rnd_n(3) * font_line_h - font_line_h; }
            else { y = g_h - status_h() - rnd_n(4) * font_line_h + font_line_h; }
            ev_mouse_move(x, y);
            i32 n = 1 + rnd_n(4);
            for i32 i = 0; i < n; i++ { ev_timer(DRAG_SCROLL_TIMER); }
            return "drag at an edge";
        }
        ev_mouse_move(x, y);
        return "drag";
    }
    if k == 4 {
        ev_mouse(x, y, 0, false, 0);
        return "release";
    }
    if k == 6 {
        // Resting the pointer on a word: hover, let the timer fire,
        // and take the answer. Every other action dismisses the popup,
        // so without the whole sequence in one step it is never up
        // when the state is sampled.
        aim_at_text(&x, &y);
        ev_hover(x, y, 0);
        ev_timer(HOVER_TIMER);
        mock_flush_kind(MOCK_KIND_HOVER);
        ev_wake();
        return "hover rest";
    }
    if k == 7 {
        // two presses on one spot: the harness clock steps 100 ms per
        // read, so they land inside the double-click window
        aim_at_text(&x, &y);
        ev_mouse(x, y, 0, true, 0);
        ev_mouse(x, y, 0, false, 0);
        ev_mouse(x, y, 0, true, 0);
        return "double click";
    }
    i32 hm = 0;
    if rnd_1in(2) { hm = MOD_CTRL; }
    if rnd_1in(2) {
        // aimed at a character: a uniform point over the pane misses
        // the words whatever the window, and at 4K the pane is four
        // times wider than the lines in it
        aim_at_text(&x, &y);
    }
    ev_hover(x, y, hm);
    return "hover";
}

private bool fz_word_byte(u8 c) {
    if c >= 'a' && c <= 'z' { return true; }
    if c >= 'A' && c <= 'Z' { return true; }
    if c >= '0' && c <= '9' { return true; }
    return c == '_';
}

// a point on a word: a visible line that has one, a byte inside it.
// A byte chosen uniformly lands on spaces and punctuation most of the
// time, and the files' first screens are mostly comment, which the
// link filter rejects; a few tries find an identifier.
private void aim_at_text(i32* x, i32* y) {
    i32 px0 = 0;
    i32 px1 = 0;
    ed_pane_rect(ed_pane_active(), &px0, &px1);
    i32 lo = px0 + gutter_w();
    if lo < 0 { lo = 0; }
    i32 rows = visible_lines();
    if rows < 1 { rows = 1; }
    i32 l = top_line;
    i32 c = 0;
    for i32 t = 0; t < 6; t++ {
        l = top_line + rnd_n(rows);
        if l > tb.nlines - 1 { l = tb.nlines - 1; }
        if l < 0 { l = 0; }
        i32 n = line_bytes(l);
        if n <= 0 { continue; }
        c = rnd_n(n);
        // walk right to the next identifier byte on this line
        i32 k = c;
        while k < n && !fz_word_byte(g_linebuf[k]) { k++; }
        if k < n {
            c = k;
            break;
        }
    }
    i32 v = vcol_of_col(l, c) - left_vcol;
    i32 ax = lo + v * font_cell_w + font_cell_w / 2;
    if ax < lo { ax = lo; }
    if px1 > lo && ax >= px1 { ax = px1 - 1; }
    *x = ax;
    *y = doc_top() + (l - top_line) * font_line_h - scroll_off + font_line_h / 2;
}

private str do_scroll() {
    f32 dy = cast(f32, rnd_n(400) - 200);
    i32 r = rnd_n(4);
    if r == 0 {
        // sideways, some of it diagonal like a touchpad's
        f32 dx = cast(f32, rnd_n(600) - 300);
        if rnd_n(2) == 0 { dy = 0.0f; }
        ev_scroll(dx, dy, rnd_x(), rnd_y());
        return "scroll sideways";
    }
    if r == 1 {
        // a wheel's notch, three lines either way
        f32 nd = cast(f32, 3 * font_line_h);
        if rnd_n(2) == 0 { nd = -nd; }
        ev_notch(0.0f, nd, rnd_x(), rnd_y());
        return "scroll notch";
    }
    ev_scroll(0.0f, dy, rnd_x(), rnd_y());
    return "scroll";
}

private str do_pick() {
    ev_key('P', MOD_CTRL);
    i32 n = rnd_n(4);
    for i32 i = 0; i < n; i++ { ev_char(cast(u32, 'a' + rnd_n(26))); }
    if rnd_1in(4) { ev_key(K_DOWN, 0); }
    // a third of the time it stays open, so the overlay renders into a
    // frame and the next step's events go through it
    i32 end = rnd_n(3);
    if end == 0 { ev_key(K_ESCAPE, 0); }
    else if end == 1 { ev_char(13); }
    return "quick open";
}

private str do_find() {
    ev_key('F', MOD_CTRL);
    type_word();
    i32 k = rnd_n(4);
    if k == 0 { ev_char(13); }
    if k == 1 { ev_key(K_UP, 0); }
    if k == 2 { ev_key(K_ESCAPE, 0); }
    return "find";
}

// Replace: the query, Tab, a replacement, then one replacement, all of
// them (Enter with the primary modifier held), or an undo with the
// widget open
private str do_replace() {
    ev_key('H', MOD_CTRL);
    if find_in_replace { ev_key(K_TAB, 0); }
    type_word();
    ev_key(K_TAB, 0);
    type_word();
    i32 k = rnd_n(4);
    if k == 0 { ev_char(13); }
    if k == 1 {
        ev_hover(0, 0, MOD_CTRL);
        ev_char(13);
        ev_hover(0, 0, 0);
    }
    if k == 2 { ev_key('Z', MOD_CTRL); }
    if k == 3 { ev_key(K_ESCAPE, 0); }
    return "replace";
}

// The chord, the folder line, a name the chdir stub refuses, so the
// tree stays; then the status asked for as a save would ask for it,
// which is the harness standing in for the Ctrl+S it never presses.
private str do_open_folder() {
    ev_key('K', MOD_CTRL);
    ev_key('O', MOD_CTRL);
    if ask_on {
        ev_char('n');
        ev_char('o');
        ev_char('w');
        ev_char('h');
        ev_char('e');
        ev_char('r');
        ev_char('e');
        ev_char(13);
        if ask_on { ev_key(K_ESCAPE, 0); }
    }
    ev_status();
    return "open folder, refused";
}

private str do_tree() {
    if rnd_n(12) == 0 { return do_open_folder(); }
    i32 k = rnd_n(5);
    if k == 0 { ev_key('B', MOD_CTRL); return "toggle tree"; }
    if k == 1 { ev_key('B', MOD_SUPER); return "toggle tree (super)"; }
    ev_key('E', MOD_CTRL);
    i32 n = rnd_n(6);
    for i32 i = 0; i < n; i++ {
        i32[4] keys = { K_UP, K_DOWN, K_LEFT, K_RIGHT };
        ev_key(keys[rnd_n(4)], 0);
    }
    if rnd_1in(3) { ev_char(' '); }
    if rnd_1in(4) {
        // A name typed in the tree: a new file (Ctrl+K F), a rename (F2),
        // or an entry of the context menu, which may start either or a
        // folder. Esc before Enter, since nothing is written to disk.
        i32 m = rnd_n(3);
        str what = "tree: menu";
        if m == 0 {
            ev_key('K', MOD_CTRL);
            ev_key('F', 0);
            ev_char('f');
            what = "tree: new file, abandoned";
        } else if m == 1 {
            ev_key(K_F2, 0);
            what = "tree: rename, abandoned";
        } else {
            i32 my = rnd_n(g_h);
            ev_mouse(4 + rnd_n(40), my, 1, true, 0);
            ev_mouse(4 + rnd_n(40), my, 1, false, 0);
            i32 d = rnd_n(5);
            for i32 i = 0; i < d; i++ { ev_key(K_DOWN, 0); }
            if rnd_1in(2) { ev_char(13); } else { ev_key(K_ESCAPE, 0); }
        }
        if tree_edit_on() {
            ev_char('z');
            ev_key(K_ESCAPE, 0);
        }
        return what;
    }
    if rnd_1in(2) { ev_key(K_ESCAPE, 0); }
    return "tree focus";
}

private str do_search() {
    ev_key('F', MOD_CTRL | MOD_SHIFT);
    i32 n = 2 + rnd_n(3);
    for i32 i = 0; i < n; i++ { ev_char(cast(u32, 'a' + rnd_n(26))); }
    // the workers are asynchronous in the app; the typing above already
    // started the scan with the full query, so joining it is enough and
    // rides in the script as an event
    ev_settle();
    i32 k = rnd_n(6);
    for i32 i = 0; i < k; i++ { ev_key(K_DOWN, 0); }
    if rnd_1in(3) { ev_char(13); }
    if rnd_1in(2) { ev_key('E', MOD_CTRL | MOD_SHIFT); }
    return "project search";
}

private str do_panes() {
    i32 k = rnd_n(7);
    if k == 0 { ev_key(92, MOD_CTRL); return "split"; }
    if k == 1 { ev_key('1' + rnd_n(3), MOD_CTRL); return "focus pane"; }
    if k == 2 {
        if rnd_1in(3) { ev_key('N', MOD_CTRL); return "untitled tab"; }
        ev_key('W', MOD_CTRL);
        return "close buffer/terminal";
    }
    if k == 5 { ev_key('W', MOD_CTRL | MOD_SHIFT); return "close pane"; }
    if k == 3 || k == 4 {
        // ctrl+k t: a new shell in the active pane, in place of what it
        // showed (shift is the same chord)
        ev_key('K', MOD_CTRL);
        if k == 3 { ev_key('T', 0); ev_char('t'); } else { ev_key('T', MOD_SHIFT); ev_char('T'); }
        return "terminal pane open";
    }
    i32 mods = MOD_CTRL;
    if rnd_1in(2) { mods = MOD_CTRL | MOD_SHIFT; }
    ev_key(K_TAB, mods);
    // the chord opens the switcher's list on the next row and steps on
    // from there, so the run has to end it the way a hand would
    i32 steps = rnd_n(3);
    for i32 i = 0; i < steps; i++ { ev_key(K_TAB, mods); }
    i32 end = rnd_n(5);
    if end == 0 { ev_key(K_ESCAPE, 0); return "cycle buffer: escape"; }
    if end == 4 { return "cycle buffer: left open"; }
    ev_char(13);
    return "cycle buffer";
}

private str do_lsp_nav() {
    i32 k = rnd_n(5);
    if k == 0 { ev_key(K_F12, 0); return "F12 goto definition"; }
    if k == 4 {
        ev_key(K_F12, MOD_SHIFT);
        mock_flush_kind(MOCK_KIND_REF);
        ev_wake();
        return "find references";
    }
    if k == 1 { ev_key(NAV_BACK_KEY, NAV_BACK_MODS); return "nav back"; }
    if k == 2 { ev_key(NAV_FWD_KEY, NAV_FWD_MODS); return "nav forward"; }
    ev_mouse(rnd_x(), rnd_y(), 0, true, MOD_CTRL);
    return "ctrl+click (goto definition)";
}

private str do_window() {
    i32 k = rnd_n(10);
    if k == 0 {
        // a floor a window manager would enforce anyway; below it the
        // chrome cannot fit whatever the layout does
        i32 w = 240 + rnd_n(3600);
        i32 h = 240 + rnd_n(1920);
        ev_resize(w, h - g_caption_h);
        return "resize";
    }
    if k == 1 {
        i32[4] dpis = { 96, 120, 144, 192 };
        ev_scale(dpis[rnd_n(4)]);
        return "dpi change";
    }
    if k == 2 { ev_focus(rnd_1in(2)); return "focus"; }
    if k == 3 { ev_timer(1); return "blink timer"; }
    if k == 4 { ev_timer(LSP_SYNC_TIMER); return "lsp sync timer"; }
    if k == 5 { ev_timer(HOVER_TIMER); return "hover timer"; }
    if k == 6 { ev_timer(GIT_TIMER); return "git diff timer"; }
    if k == 7 { ev_timer(SEM_TIMER); return "semantic timer"; }
    if k == 8 { ev_timer(SEARCH_TIMER); return "search timer"; }
    ev_wake();
    return "wake";
}

// The weights. LSP navigation is deliberately over-weighted: it is the
// surface this harness exists for.
private i32 fz_family_of(i32 k) {
    if k < 12 { return 0; }
    if k < 13 { return 23; }
    if k < 14 { return 22; }
    if k < 15 { return 21; }
    if k < 17 { return 20; }
    if k < 19 { return 17; }
    if k < 35 { return 1; }
    if k < 36 { return 18; }
    if k < 44 { return 2; }
    if k < 49 { return 3; }
    if k < 59 { return 4; }
    if k < 63 { return 5; }
    if k < 72 { return 6; }
    if k < 73 { return 19; }
    if k < 76 { return 13; }
    if k < 80 { return 7; }
    if k < 83 { return 8; }
    if k < 86 { return 9; }
    if k < 88 { return 10; }
    if k < 92 { return 11; }
    if k < 96 { return 14; }
    if k < 98 { return 15; }
    if k < 99 { return 16; }
    return 12;
}

str fz_family_name(i32 f) {
    if f == 0 { return "type"; }
    if f == 1 { return "move"; }
    if f == 2 { return "edit op"; }
    if f == 3 { return "clipboard"; }
    if f == 4 { return "mouse"; }
    if f == 5 { return "scroll"; }
    if f == 6 { return "lsp nav"; }
    if f == 7 { return "quick open"; }
    if f == 8 { return "find"; }
    if f == 9 { return "tree"; }
    if f == 10 { return "search"; }
    if f == 11 { return "panes"; }
    if f == 13 { return "completion"; }
    if f == 14 { return "cursors"; }
    if f == 15 { return "symbols"; }
    if f == 16 { return "build"; }
    if f == 17 { return "terminal"; }
    if f == 18 { return "switcher"; }
    if f == 19 { return "watch"; }
    if f == 20 { return "changes view"; }
    if f == 21 { return "palette"; }
    if f == 22 { return "explode"; }
    if f == 23 { return "call graph"; }
    return "window";
}

// An oracle rather than an invariant: drifted cursors stay inside the
// buffer and never overlap, so nothing about the state says they are
// wrong. What says it is the column. Cursors on distinct lines sharing
// a visual column are a rectangle, and typing one character into each
// line of a rectangle leaves a rectangle one column to the right. The
// same holds for a backspace, one column to the left.
private bool fz_multi_bad = false;

// the shared visual column, or -1 when the set is not a rectangle.
// An overlay or a focused sidebar owns typing, and then the characters
// never reach the document at all, so that is not a rectangle either.
// the bytes in [a, b) are complete, well-formed utf-8 sequences
private bool fz_utf8_ok(i64 a, i64 b) {
    i64 i = a;
    while i < b {
        u8 c = 0;
        tb_copy(i, &c, 1);
        i32 need = 0;
        if c < 0x80 { need = 0; }
        else if (c & 0xE0) == 0xC0 { need = 1; }
        else if (c & 0xF0) == 0xE0 { need = 2; }
        else if (c & 0xF8) == 0xF0 { need = 3; }
        else { return false; }
        if i + 1 + need > b { return false; }
        for i32 k = 1; k <= need; k++ {
            u8 d = 0;
            tb_copy(i + k, &d, 1);
            if (d & 0xC0) != 0x80 { return false; }
        }
        i += 1 + need;
    }
    return true;
}

private i32 cur_rect_vcol() {
    if overlay_active() || tree_focus || search_focus { return -1; }
    i32 n = ed_cur_count();
    if n < 2 { return -1; }
    i32 want = -1;
    for i32 i = 0; i < n; i++ {
        i64 cc = 0;
        i64 a = 0;
        i64 b = 0;
        ed_cur_get(i, &cc, &a, &b);
        if a != b { return -1; }         // a selection is not a column
        i32 l = tb_line_of(cc);
        // the bytes up to the caret must be well-formed utf-8: a stray
        // lead byte before it (a binary file, or a definition reply
        // that split a sequence) takes the typed letters as its
        // continuation, and the column moves by the width of that
        if !fz_utf8_ok(tb_line_start(l), cc) { return -1; }
        i32 v = vcol_of_col(l, cc - tb_line_start(l));
        if want < 0 { want = v; } else if v != want { return -1; }
        for i32 j = 0; j < i; j++ {
            i64 oc = 0;
            i64 oa = 0;
            i64 ob = 0;
            ed_cur_get(j, &oc, &oa, &ob);
            if tb_line_of(oc) == l { return -1; }   // two on one line
        }
    }
    return want;
}

private void multi_fail(str what, i32 got, i32 want) {
    fz_multi_bad = true;
    print("  column {} after the edit, wanted {}, {} cursors\n",
        got, want, ed_cur_count());
    fail(what, "");
}

// The command palette. It never stays open past the step: a later
// step's Enter (do_type sends one) would run whichever row the random
// query landed on, and the table holds Save, Quit and Restart, which
// this harness must not reach. A row is run only after its whole name
// was typed, from the rows that stay inside the editor.
// Ctrl+M: the explode view over the open buffers. A walk, a filter,
// then a pick by Enter or by a click on a tile, Escape, or left open for
// the next action to find. Every frame with it up draws the tiles.
// The call graph: Ctrl+Shift+M, the mock's answers to the prepare and the
// two row requests (or none of them), then the arrows, Enter, Backspace,
// the pointer and a click, and a close or the view left open.
private str do_calls() {
    ev_key('M', MOD_CTRL | MOD_SHIFT);
    cov_state(37, calls_on);
    if !calls_on { return "call graph: not opened"; }
    if rnd_1in(5) { return "call graph: open, unanswered"; }
    mock_flush_kind(MOCK_KIND_CPREP);
    if !rnd_1in(4) { mock_flush_kind(MOCK_KIND_CROWS); }
    i32 n = rnd_n(6);
    for i32 i = 0; i < n; i++ {
        i32 a = rnd_n(8);
        if a < 4 {
            i32[4] keys = { K_LEFT, K_RIGHT, K_UP, K_DOWN };
            ev_key(keys[a], 0);
        } else if a == 4 {
            ev_char(13);                     // recenter, open a group, or open the center
            mock_flush_kind(MOCK_KIND_CROWS);
        } else if a == 5 {
            ev_char(8);                      // back along the trail
            mock_flush_kind(MOCK_KIND_CROWS);
        } else if calls_on && calls_card_count() > 0 {
            i32 x = 0;
            i32 y = 0;
            i32 w = 0;
            i32 h = 0;
            calls_card_rect(rnd_n(calls_card_count()), &x, &y, &w, &h);
            if a == 6 {
                ev_hover(x + rnd_n(w + 1), y + rnd_n(h + 1), 0);
            } else {
                ev_mouse(x + w / 2, y + h / 2, 0, true, 0);
                ev_mouse(x + w / 2, y + h / 2, 0, false, 0);
                mock_flush_kind(MOCK_KIND_CROWS);
            }
        }
        if !calls_on { return "call graph: opened a function"; }
    }
    i32 end = rnd_n(3);
    if end == 0 { ev_key(K_ESCAPE, 0); return "call graph: escape"; }
    if end == 1 { ev_key('M', MOD_CTRL | MOD_SHIFT); return "call graph: toggle off"; }
    return "call graph: left open";
}

private str do_explode() {
    ev_key('M', MOD_CTRL);
    cov_state(36, explode_on);
    if !explode_on { return "explode: nothing open"; }
    i32 n = rnd_n(5);
    for i32 i = 0; i < n; i++ {
        i32[4] keys = { K_LEFT, K_RIGHT, K_UP, K_DOWN };
        ev_key(keys[rnd_n(4)], 0);
    }
    if rnd_1in(4) {
        i32 m = 1 + rnd_n(3);
        for i32 i = 0; i < m; i++ { ev_char(cast(u32, 'a' + rnd_n(26))); }
        if rnd_1in(2) { ev_char(8); }
    }
    if rnd_1in(2) {
        // the pointer over a tile, which selects it
        i32 hx = 0;
        i32 hy = 0;
        i32 hw = 0;
        i32 hh = 0;
        if explode_tile_rect(rnd_n(explode_count()), &hx, &hy, &hw, &hh) {
            ev_hover(hx + rnd_n(hw + 1), hy + rnd_n(hh + 1), 0);
        }
    }
    if rnd_1in(3) {
        // the wheel or the touchpad over a tile, or between them
        i32 sx = rnd_x();
        i32 sy = rnd_y();
        i32 tx = 0;
        i32 ty = 0;
        i32 tw = 0;
        i32 th = 0;
        if rnd_1in(2) && explode_tile_rect(rnd_n(explode_count()), &tx, &ty, &tw, &th) {
            sx = tx + tw / 2;
            sy = ty + th / 2;
        }
        if rnd_1in(2) {
            ev_scroll(0.0f, cast(f32, rnd_n(600) - 300), sx, sy);
        } else {
            f32 nd = cast(f32, 3 * font_line_h);
            if rnd_1in(2) { nd = -nd; }
            ev_notch(0.0f, nd, sx, sy);
        }
    }
    i32 end = rnd_n(5);
    if end == 0 { ev_char(13); return "explode: pick"; }
    if end == 1 {
        // a press where a tile is, or wherever the grid left room
        i32 tx = 0;
        i32 ty = 0;
        i32 tw = 0;
        i32 th = 0;
        if explode_tile_rect(rnd_n(explode_count() + 1), &tx, &ty, &tw, &th) {
            ev_mouse(tx + tw / 2, ty + th / 2, 0, true, 0);
            ev_mouse(tx + tw / 2, ty + th / 2, 0, false, 0);
            return "explode: click a tile";
        }
        ev_mouse(rnd_x(), rnd_y(), 0, true, 0);
        ev_mouse(rnd_x(), rnd_y(), 0, false, 0);
        return "explode: click";
    }
    if end == 2 { ev_key(K_ESCAPE, 0); return "explode: escape"; }
    if end == 3 { ev_key('M', MOD_CTRL); return "explode: toggle off"; }
    return "explode: left open";
}

private str do_palette() {
    if rnd_1in(2) { ev_key('P', MOD_CTRL | MOD_SHIFT); } else { ev_key(K_F1, 0); }
    cov_state(35, palette_on);
    if rnd_1in(3) {
        i32 n = rnd_n(4);
        for i32 i = 0; i < n; i++ { ev_char(cast(u32, 'a' + rnd_n(26))); }
        if rnd_1in(2) { ev_key(K_DOWN, 0); }
        ev_key(K_ESCAPE, 0);
        return "palette: typed, closed";
    }
    str[10] safe = {
        "View: Toggle Sidebar", "View: Split Editor", "Edit: Undo", "Edit: Redo",
        "Edit: Select All", "Edit: Toggle Line Comment", "Edit: Add Cursor Below",
        "Edit: Find", "Go to File...", "Edit: Move Line Down"
    };
    str name = safe[rnd_n(10)];
    for i32 i = 0; i < name.len; i++ { ev_char(cast(u32, name.data[i])); }
    ev_char(13);
    return "palette: ran a command";
}

// Ctrl+T, a few characters, and the reply, in one step so the overlay
// is up when the state is sampled; a third of the time it stays open.
private str do_symbols() {
    ev_key('T', MOD_CTRL);
    i32 n = rnd_n(4);
    for i32 i = 0; i < n; i++ { ev_char(cast(u32, 'a' + rnd_n(26))); }
    mock_flush_kind(MOCK_KIND_SYM);
    ev_wake();
    if rnd_1in(3) { ev_key(K_DOWN, 0); }
    i32 end = rnd_n(3);
    if end == 0 { ev_key(K_ESCAPE, 0); }
    else if end == 1 { ev_char(13); }
    return "symbol search";
}

// The multi-cursor keys. Escape is in here so a run both builds sets
// up and tears them down, rather than pinning every later action to
// whatever column it accumulated.
private str do_cursors() {
    i32 k = rnd_n(10);
    if k < 3 {
        ev_key(K_DOWN, MOD_CTRL | MOD_ALT);
        return "add cursor below";
    }
    if k < 5 {
        ev_key(K_UP, MOD_CTRL | MOD_ALT);
        return "add cursor above";
    }
    if k < 8 {
        ev_key('D', MOD_CTRL);
        return "add next match";
    }
    if k == 8 {
        // aimed into the text, like the hover-link action: a uniform
        // point over the window almost never lands in a pane
        i32 px0 = 0;
        i32 px1 = 0;
        ed_pane_rect(ed_pane_active(), &px0, &px1);
        i32 lo = px0 + gutter_w();
        i32 x = lo;
        if px1 > lo { x = lo + rnd_n(px1 - lo); }
        i32 y = 0;
        i32 hi = g_h - status_h();
        if hi > 0 { y = rnd_n(hi); }
        ev_mouse(x, y, 0, true, MOD_ALT);
        return "alt+click cursor";
    }
    if k == 9 {
        // Build the column here rather than waiting for the random
        // stream to leave one standing: the precondition is narrow
        // enough that it almost never held on its own. Two characters,
        // because one keystroke can land the text right while leaving
        // the cursors behind it.
        // the keys below are the shell's while a terminal pane has the
        // focus, so leave it first: the switcher's next row, which may
        // be another terminal, in which case the step is given up
        if ed_term_active() >= 0 {
            ev_key(K_TAB, MOD_CTRL);
            ev_char(13);
        }
        if ed_term_active() >= 0 { return "type into a column: terminal kept"; }
        ev_key(K_ESCAPE, 0);
        ev_key(K_DOWN, MOD_CTRL | MOD_ALT);
        ev_key(K_DOWN, MOD_CTRL | MOD_ALT);
        i32 v0 = cur_rect_vcol();
        i32 n0 = ed_cur_count();
        ev_char(cast(u32, 'a' + rnd_n(26)));
        ev_char(cast(u32, 'a' + rnd_n(26)));
        if v0 >= 0 && ed_cur_count() == n0 {
            i32 v1 = cur_rect_vcol();
            if v1 != v0 + 2 {
                multi_fail("typing broke the cursor column", v1, v0 + 2);
                return "type into a column";
            }
        }
        i32 v2 = cur_rect_vcol();
        i32 n2 = ed_cur_count();
        ev_char(8);
        if v2 >= 1 && ed_cur_count() == n2 {
            i32 v3 = cur_rect_vcol();
            if v3 != v2 - 1 {
                multi_fail("backspace broke the cursor column", v3, v2 - 1);
            }
        }
        return "type into a column";
    }
    ev_key(K_ESCAPE, 0);
    return "collapse cursors";
}

// Typing an identifier, letting the timer ask, and taking the list:
// the sequence a writer produces. It has to be one step, because the
// next action would close the popup before the state is sampled.
private str do_complete() {
    // a space first, so the word being completed is exactly the one
    // character typed after it, which the mock can match
    ev_char(' ');
    ev_char(cast(u32, 'a' + rnd_n(26)));
    ev_timer(CMP_TIMER);
    mock_flush_kind(MOCK_KIND_CMP);
    ev_wake();
    i32 extra = rnd_n(4);
    for i32 i = 0; i < extra; i++ {
        i32[4] keys = { K_DOWN, K_UP, K_PGDN, K_ESCAPE };
        ev_key(keys[rnd_n(4)], 0);
    }
    if rnd_1in(3) { ev_char(13); }   // commit
    return "completion";
}

// --- the terminal ----------------------------------------------------
// The emulator is a pure function from a byte stream to a screen, and
// that stream comes from the far side of a pty: untrusted in the same
// way the server's frames are. The generator leans on well-formed
// control sequences with random parameters and mixes junk in, so the
// parser is walked over its whole table rather than the handful of
// sequences a shell happens to send, and the bytes go in chunks of
// random size, so the split path is walked with them.

private const i32 FZ_TERM_CAP = 512;
private i32 fz_term = -1;

// The terminal family's operations on its own emulator. They are input
// like the rest: the emulator takes a slot in the table the editor's
// terminals use, and the switcher lists it, so a replay that skipped
// them would see another table.
private const i32 FZT_NEW = 0;      // cols, rows
private const i32 FZT_RESIZE = 1;   // cols, rows
private const i32 FZT_KEY = 2;      // key, mods
private const i32 FZT_CHAR = 3;     // cp, mods
private const i32 FZT_VIEW = 4;     // the view's line
private const i32 FZT_PASTE = 5;    // bytes
private const i32 FZT_MOUSE = 6;    // x, y, button, down, mods
private const i32 FZT_FEED = 7;     // bytes
private const i32 FZT_CLOSE = 8;

private void term_op(i32 op, i32 a, i32 b, i32 c, i32 d, i32 e, u8* p, i32 n) {
    if op == FZT_NEW {
        fz_term = term_new(a, b);
        return;
    }
    if fz_term < 0 { return; }
    if op == FZT_RESIZE { term_resize(fz_term, a, b); }
    if op == FZT_KEY { ignore term_key(fz_term, a, b); }
    if op == FZT_CHAR { term_char(fz_term, cast(u32, a), b); }
    if op == FZT_VIEW { term_view_set(fz_term, a); }
    if op == FZT_PASTE { term_paste(fz_term, p, cast(i64, n)); }
    if op == FZT_MOUSE { term_mouse(fz_term, a, b, c, d != 0, e); }
    if op == FZT_FEED { term_feed(fz_term, p, cast(i64, n)); }
    if op == FZT_CLOSE {
        term_close(fz_term);
        fz_term = -1;
    }
}

private void ev_term(i32 op, i32 a, i32 b, i32 c, i32 d, i32 e, u8* p, i32 n) {
    fz_tick();
    if ev_rec {
        ev_put8(EV_TERM);
        ev_put32(op);
        ev_put32(a);
        ev_put32(b);
        ev_put32(c);
        ev_put32(d);
        ev_put32(e);
        ev_put32(n);
        if n > 0 {
            ev_room(cast(i64, n));
            memcpy(ev_buf + ev_len, p, n);
            ev_len += cast(i64, n);
        }
    }
    term_op(op, a, b, c, d, e, p, n);
}

private i32 fz_term_num(u8* b, i32 o, i32 v) {
    if v < 0 { v = 0; }
    return o + fmt_i32(b + o, v);
}

// one generated thing at b+o; the new length
private i32 fz_term_seq(u8* b, i32 o) {
    i32 k = rnd_n(18);
    if k < 4 {
        i32 n = 1 + rnd_n(8);
        for i32 i = 0; i < n; i++ {
            if o > FZ_TERM_CAP - 8 { return o; }
            i32 w = rnd_n(10);
            if w < 7 {
                b[o] = cast(u8, 33 + rnd_n(90));
                o++;
            } else if w < 9 {
                o += utf8_encode(cast(u32, 0x4E00 + rnd_n(200)), b + o);
            } else {
                o += utf8_encode(cast(u32, 0xA0 + rnd_n(300)), b + o);
            }
        }
        return o;
    }
    if k == 4 {
        i32[8] c = { 7, 8, 9, 10, 13, 11, 12, 27 };
        b[o] = cast(u8, c[rnd_n(8)]);
        return o + 1;
    }
    if k < 9 {
        // a control sequence, with the modes the child really sets
        // among the parameters so the states behind them are reached
        b[o] = 27;
        o++;
        b[o] = '[';
        o++;
        bool priv = rnd_1in(4);
        if priv {
            b[o] = '?';
            o++;
        }
        i32 np = rnd_n(4);
        for i32 i = 0; i < np; i++ {
            if i > 0 {
                b[o] = ';';
                o++;
            }
            if priv {
                i32[13] modes = { 1, 6, 7, 12, 25, 47, 1000, 1002, 1004, 1006, 1049, 2004, 9001 };
                o = fz_term_num(b, o, modes[rnd_n(13)]);
            } else {
                o = fz_term_num(b, o, rnd_n(2100));
            }
        }
        if rnd_1in(8) {
            b[o] = ' ';
            o++;
        }
        str finals = "ABCDEFGHJKLMPSTXdfghlmnrsucq@`zZt";
        if priv { finals = "hl"; }
        b[o] = finals.data[rnd_n(finals.len)];
        o++;
        return o;
    }
    if k < 12 {
        // SGR, including the two extended color forms
        b[o] = 27;
        o++;
        b[o] = '[';
        o++;
        i32 np = 1 + rnd_n(4);
        for i32 i = 0; i < np; i++ {
            if i > 0 {
                b[o] = ';';
                o++;
            }
            i32 pick = rnd_n(10);
            if pick == 0 {
                o = fz_term_num(b, o, 38 + 10 * rnd_n(2));
                b[o] = ';';
                o++;
                o = fz_term_num(b, o, 5);
                b[o] = ';';
                o++;
                o = fz_term_num(b, o, rnd_n(300));
            } else if pick == 1 {
                o = fz_term_num(b, o, 38 + 10 * rnd_n(2));
                b[o] = ';';
                o++;
                o = fz_term_num(b, o, 2);
                for i32 c = 0; c < 3; c++ {
                    b[o] = ';';
                    o++;
                    o = fz_term_num(b, o, rnd_n(300));
                }
            } else {
                o = fz_term_num(b, o, rnd_n(120));
            }
        }
        b[o] = 'm';
        o++;
        return o;
    }
    if k == 12 {
        // an escape with no bracket: the single-byte ones and the
        // charset designators that are dropped
        b[o] = 27;
        o++;
        str esc = "MDEH78c=>()*+%#";
        b[o] = esc.data[rnd_n(esc.len)];
        o++;
        return o;
    }
    if k == 13 {
        // a string sequence, ended either way or not at all
        b[o] = 27;
        o++;
        i32 kind = rnd_n(3);
        if kind == 0 { b[o] = ']'; } else if kind == 1 { b[o] = 'P'; } else { b[o] = '_'; }
        o++;
        o = fz_term_num(b, o, rnd_n(10000));
        b[o] = ';';
        o++;
        i32 n = rnd_n(24);
        for i32 i = 0; i < n; i++ {
            if o > FZ_TERM_CAP - 8 { break; }
            b[o] = cast(u8, 32 + rnd_n(90));
            o++;
        }
        i32 end = rnd_n(3);
        if end == 0 {
            b[o] = 7;
            o++;
        } else if end == 1 {
            b[o] = 27;
            o++;
            b[o] = 92;
            o++;
        }
        return o;
    }
    if k == 14 {
        i32 n = 1 + rnd_n(6);
        for i32 i = 0; i < n; i++ {
            if o > FZ_TERM_CAP - 4 { break; }
            b[o] = cast(u8, rnd_n(256));
            o++;
        }
        return o;
    }
    if k < 17 {
        // whole sequences a program really sends: the states behind
        // them are worth reaching on purpose rather than by chance
        str[12] canned = { "~[?1049h", "~[?1049l", "~[?2004h", "~[?2004l",
            "~[?1000h", "~[?1006h", "~[?7l", "~[?25l", "~[2;5r", "~[s",
            "~[u", "~[?1h" };
        str q = canned[rnd_n(12)];
        for i32 i = 0; i < q.len; i++ {
            if o > FZ_TERM_CAP - 4 { break; }
            if q.data[i] == '~' { b[o] = 27; } else { b[o] = q.data[i]; }
            o++;
        }
        return o;
    }
    // a sequence cut off partway, which the next feed continues or not
    b[o] = 27;
    o++;
    if rnd_1in(2) {
        b[o] = '[';
        o++;
        o = fz_term_num(b, o, rnd_n(50));
    }
    return o;
}

private str do_terminal() {
    if fz_term < 0 {
        ev_term(FZT_NEW, 8 + rnd_n(100), 3 + rnd_n(40), 0, 0, 0, null, 0);
        if fz_term < 0 { return "terminal (none free)"; }
        return "terminal open";
    }
    i32 k = rnd_n(12);
    if k == 0 {
        ev_term(FZT_RESIZE, 1 + rnd_n(120), 1 + rnd_n(50), 0, 0, 0, null, 0);
        return "terminal resize";
    }
    if k == 1 {
        i32[12] keys = { K_UP, K_DOWN, K_LEFT, K_RIGHT, K_PGUP, K_DELETE, K_TAB, K_ESCAPE,
            K_F1, K_F4, K_F6, K_F11 };
        ev_term(FZT_KEY, keys[rnd_n(12)], rnd_n(8), 0, 0, 0, null, 0);
        return "terminal key";
    }
    if k == 2 {
        ev_term(FZT_CHAR, 32 + rnd_n(90), rnd_n(8), 0, 0, 0, null, 0);
        return "terminal char";
    }
    if k == 3 {
        ev_term(FZT_VIEW, rnd_n(40), 0, 0, 0, 0, null, 0);
        return "terminal scroll";
    }
    if k == 4 {
        noinit u8[64] p;
        i32 n = rnd_n(60);
        for i32 i = 0; i < n; i++ { p[i] = cast(u8, 10 + rnd_n(80)); }
        ev_term(FZT_PASTE, 0, 0, 0, 0, 0, &p[0], n);
        return "terminal paste";
    }
    if k == 5 {
        i32 mx = rnd_n(140);
        i32 my = rnd_n(60);
        i32 mb = rnd_n(3);
        i32 md = 0;
        if rnd_1in(2) { md = 1; }
        ev_term(FZT_MOUSE, mx, my, mb, md, rnd_n(8), null, 0);
        return "terminal mouse";
    }
    if k == 6 {
        // the alternate screen on purpose: a program that uses it
        // stays in it, and that is a whole second screen to reach
        noinit u8[8] a;
        a[0] = 27;
        a[1] = '[';
        a[2] = '?';
        a[3] = '1';
        a[4] = '0';
        a[5] = '4';
        a[6] = '9';
        if term_alt(fz_term) { a[7] = 'l'; } else { a[7] = 'h'; }
        ev_term(FZT_FEED, 0, 0, 0, 0, 0, &a[0], 8);
        return "terminal alt screen";
    }
    if k == 7 && rnd_1in(6) {
        ev_term(FZT_CLOSE, 0, 0, 0, 0, 0, null, 0);
        return "terminal close";
    }
    if k == 8 {
        // a cluster, whole or cut: the joiners ride on the cell before
        // them, or stand alone when there is none
        str[6] cl = {
            "\xe2\x9c\x94\xef\xb8\x8f", "\xf0\x9f\x87\xb8\xf0\x9f\x87\xaa",
            "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7",
            "1\xef\xb8\x8f\xe2\x83\xa3", "e\xcc\x81", "\xe2\x80\x8d\xef\xb8\x8f\xf0\x9f\x8f\xbd" };
        str c = cl[rnd_n(6)];
        i32 cut = c.len;
        if rnd_1in(3) { cut = 1 + rnd_n(c.len); }
        ev_term(FZT_FEED, 0, 0, 0, 0, 0, c.data, cut);
        return "terminal cluster";
    }
    noinit u8[FZ_TERM_CAP] b;
    i32 n = 0;
    i32 nseq = 1 + rnd_n(6);
    for i32 i = 0; i < nseq; i++ {
        if n > FZ_TERM_CAP - 80 { break; }
        n = fz_term_seq(&b[0], n);
    }
    i32 at = 0;
    while at < n {
        i32 take = 1 + rnd_n(n - at);
        ev_term(FZT_FEED, 0, 0, 0, 0, 0, &b[at], take);
        at += take;
    }
    return "terminal feed";
}

// One weighted action. The family is announced before it runs, so --vv
// names the action that faults rather than the last one that survived.
private str fz_action() {
    str what = fz_action_run();
    // Enter on a name typed in the tree makes a file or a folder, or
    // renames one, and nothing is written to disk: whichever action
    // opened the input, it closes here. The input box writes only on a
    // save-as, which no action opens; it closes here all the same.
    if tree_edit_on() || ask_on { ev_key(K_ESCAPE, 0); }
    return what;
}

private str fz_action_run() {
    i32 f = fz_family_of(rnd_n(100));
    cov_hit(f);
    if fz_vv {
        say("  family ");
        say(fz_family_name(f));
        say("\n");
    }
    if f == 0 { return do_type(); }
    if f == 1 { return do_move(); }
    if f == 2 { return do_edit_op(); }
    if f == 3 { return do_clipboard(); }
    if f == 4 { return do_mouse(); }
    if f == 5 { return do_scroll(); }
    if f == 6 { return do_lsp_nav(); }
    if f == 7 { return do_pick(); }
    if f == 8 {
        if rnd_1in(3) { return do_replace(); }
        return do_find();
    }
    if f == 9 { return do_tree(); }
    if f == 10 { return do_search(); }
    if f == 11 { return do_panes(); }
    if f == 13 { return do_complete(); }
    if f == 14 { return do_cursors(); }
    if f == 15 { return do_symbols(); }
    if f == 16 { return do_build(); }
    if f == 17 { return do_terminal(); }
    if f == 18 { return do_switcher(); }
    if f == 19 { return do_watch(); }
    if f == 20 { return do_changes(); }
    if f == 21 { return do_palette(); }
    if f == 22 { return do_explode(); }
    if f == 23 { return do_calls(); }
    return do_window();
}

// The changes view and the diff it opens. Each action is one step, since
// the list and the diff's second pane arrive on the gutter's worker and
// are settled at the step boundary. The pane and buffer actions are the
// ones a user reaches for with a diff up: focus, close the buffer, close
// the pane, split, move the pane's content, walk the changes, and a click
// in the editor. They do something whether or not a diff is open, so the
// family also covers them in the plain layouts it leaves behind.
private str do_changes() {
    i32 k = rnd_n(12);
    if k == 0 {
        ev_key('G', MOD_CTRL | MOD_SHIFT);
        if rnd_1in(2) { ev_char(7); }   // the chord's own control character
        return "changes: open the view";
    }
    if k == 1 {
        // walk the list and open a row: a file opens a diff, a heading folds
        i32 n = rnd_n(5);
        for i32 i = 0; i < n; i++ {
            if rnd_1in(4) { ev_key(K_UP, 0); } else { ev_key(K_DOWN, 0); }
        }
        ev_char(13);
        return "changes: enter on a row";
    }
    if k == 2 {
        // a click on a row of the sidebar, as a hand opens a file
        i32 rh = tree_row_h();
        if rh < 1 { rh = 1; }
        i32 tw = tree_w();
        if tw < 8 { tw = 8; }
        i32 x = 4 + rnd_n(tw - 8);
        i32 y = rh / 2 + rh * rnd_n(10);
        ev_mouse(x, y, 0, true, 0);
        ev_mouse(x, y, 0, false, 0);
        return "changes: click a row";
    }
    if k == 3 { ev_key('1' + rnd_n(3), MOD_CTRL); return "changes: focus a pane"; }
    if k == 4 {
        ev_key('W', MOD_CTRL);
        if rnd_1in(2) { ev_char(23); }
        return "changes: ctrl+w";
    }
    if k == 5 { ev_key('W', MOD_CTRL | MOD_SHIFT); return "changes: ctrl+shift+w"; }
    if k == 6 { ev_key(92, MOD_CTRL); return "changes: split"; }
    if k == 7 {
        if rnd_1in(2) { ev_key(K_LEFT, MOD_CTRL | MOD_ALT); } else { ev_key(K_RIGHT, MOD_CTRL | MOD_ALT); }
        return "changes: move the pane's content";
    }
    if k == 8 {
        i32 w = rnd_n(4);
        if w == 0 { ev_key(K_F7, 0); }
        else if w == 1 { ev_key(K_F7, MOD_SHIFT); }
        else if w == 2 { ev_key(K_DOWN, MOD_CTRL); }
        else { ev_key(K_UP, MOD_CTRL); }
        return "changes: walk the changes";
    }
    if k == 9 {
        // a click in the editor, right of the sidebar
        i32 x0 = tree_w() + 8;
        i32 x = x0 + rnd_n(g_w - x0 > 1 ? g_w - x0 : 1);
        i32 y = rnd_n(g_h > 1 ? g_h : 1);
        ev_mouse(x, y, 0, true, 0);
        if rnd_1in(2) {
            // a drag, and the copy chord after it: on a diff's baseline
            // side this is the selection made without the focus
            i32 y2 = y + font_line_h * (rnd_n(8) - 2);
            ev_mouse_move(x, y2);
            ev_mouse(x, y2, 0, false, 0);
            if rnd_1in(2) { ev_key('C', MOD_CTRL); }
            return "changes: drag in the editor";
        }
        ev_mouse(x, y, 0, false, 0);
        return "changes: click in the editor";
    }
    if k == 10 { ev_key('E', MOD_CTRL); return "changes: back to the files"; }
    ev_key(K_ESCAPE, 0);
    return "changes: escape";
}

// The file watcher's records: a tracked path, git's HEAD, ref and
// index, an ignored path, junk, or changes lost. The harness never
// writes to disk, so the open buffers' files are as they were loaded
// and a refresh finds nothing to reload; what this drives is the
// record parsing, the filter, the refresh and the baseline refetch
// under everything else going on. The refresh fires on most runs and
// is left pending on the rest, for a later timer or none.
private str do_watch() {
    i32 k = rnd_n(7);
    str what = "watch: junk";
    if k == 6 {
        ev_watch(null, -1);
        what = "watch: lost";
    } else {
        str recs = "cwatched.txt\n";
        if k == 1 { recs = "m.git/refs/heads/main\n"; what = "watch: ref"; }
        else if k == 2 { recs = "m.git/index\nc.git/objects/aa/bb\n"; what = "watch: index"; }
        else if k == 3 { recs = "cbuild/out.o\nm.edminc/session\n"; what = "watch: ignored"; }
        else if k == 4 { recs = "msrc/new_file.mc\ncsrc/ed.mc\n"; what = "watch: moved"; }
        else if k == 0 { what = "watch: changed"; }
        if k == 5 {
            noinit u8[24] junk;
            i32 n = 1 + rnd_n(24);
            for i32 i = 0; i < n; i++ { junk[i] = cast(u8, rnd_n(256)); }
            ev_watch(&junk[0], cast(i64, n));
        } else {
            ev_watch(recs.data, cast(i64, recs.len));
        }
    }
    if rnd_n(4) != 0 { ev_timer(WATCH_TIMER); }
    return what;
}

// Ctrl+K W: what is open. A few letters of a name, a walk, then Enter
// (the chosen buffer or terminal into the active pane, which puts a
// terminal in the background as often as not), Escape, or a click.
private str do_switcher() {
    ev_key('K', MOD_CTRL);
    ev_key('W', 0);
    ev_char('w');
    i32 n = rnd_n(3);
    for i32 i = 0; i < n; i++ {
        i32 k = rnd_n(4);
        if k == 0 { ev_char('e'); }
        else if k == 1 { ev_char('.'); }
        else if k == 2 { ev_char('t'); }
        else { ev_char(cast(u32, 'a' + rnd_n(26))); }
    }
    i32 walk = rnd_n(4);
    for i32 i = 0; i < walk; i++ { ev_key(K_DOWN, 0); }
    i32 end = rnd_n(5);
    if end == 0 { ev_key(K_ESCAPE, 0); return "switcher: escape"; }
    if end == 4 { return "switcher: left open"; }
    if end == 1 {
        i32 x = rnd_n(g_w > 0 ? g_w : 1);
        i32 y = rnd_n(g_h > 0 ? g_h : 1);
        ev_mouse(x, y, 0, true, 0);
        ev_mouse(x, y, 0, false, 0);
        return "switcher: click";
    }
    ev_char(13);
    return "switcher: enter";
}

// The build pane: a run (the stub answers in the compiler's shape or
// worse), the walk through its problems, Ctrl+J, a click in it.
private str do_build() {
    i32 k = rnd_n(5);
    if k == 0 {
        // Fire a build only with a .mc buffer: the harness builds the
        // active file on every platform (build_file_only), so a non-.mc
        // buffer would report nothing.
        str p = ed_path();
        if p.len > 0 && str_ends_with(p, ".mc") {
            ev_key('B', MOD_CTRL | MOD_SHIFT);
            return "build";
        }
        ev_key('J', MOD_CTRL);
        return "close build pane";
    }
    if k == 1 {
        ev_key(K_F8, 0);
        return "next problem";
    }
    if k == 2 {
        ev_key(K_F8, MOD_SHIFT);
        return "previous problem";
    }
    if k == 3 {
        ev_key('J', MOD_CTRL);
        return "close build pane";
    }
    // a click in the build pane, on a problem row as often as not; with
    // no pane up the click lands in the active pane instead
    i32 bp = ed_build_pane();
    if bp < 0 { bp = ed_pane_active(); }
    i32 px0 = 0;
    i32 px1 = 0;
    ed_pane_rect(bp, &px0, &px1);
    i32 x = px0 + rnd_n(px1 - px0 > 0 ? px1 - px0 : 1);
    i32 top = pane_doc_top(bp);
    i32 hi = ed_pane_y1(bp) - top;
    i32 y = top + rnd_n(hi > 0 ? hi : 1);
    if rnd_1in(2) { y = top + rnd_n(12) * font_line_h + 2; }
    // now and then the bottom pane's top edge: a drag that sizes it
    if rnd_1in(6) && pane_is_bottom(bp) {
        i32 ey = ed_pane_y0(bp);
        ev_mouse(x, ey, 0, true, 0);
        ev_mouse_move(x, ey - font_line_h * (rnd_n(20) - 10));
        ev_mouse(x, ey, 0, false, 0);
        return "drag the build pane's edge";
    }
    ev_mouse(x, y, 0, true, 0);
    ev_mouse(x, y, 0, false, 0);
    return "click in build pane";
}

// Everything verified at a step boundary, so the generated loop and
// the replay loop check identically.
private bool step_checks() {
    // The git fetch runs on a worker, so whether its result is in this
    // frame is a matter of timing. Settle it at the step boundary: the
    // harness is only useful while a seed means one thing.
    app_settle();
    // state first: a broken invariant faults inside the frame
    // build, so it has to be caught before rendering, not after
    bool ok = !fz_proto_bad && !fz_multi_bad;
    if ok { ok = check_state(); }
    if ok && fz_step_no % fz_verify_every == 0 { ok = check_line_index(); }
    if ok {
        if fz_vv { say("  render\n"); }
        app_render();
        ok = check_frame();
        // the lex cache is filled by the frame build, so it is
        // only worth comparing once the frame has run
        if ok && fz_step_no % fz_verify_every == 0 { ok = check_lexer(); }
        if ok && fz_step_no % fz_verify_every == 0 { ok = check_git_cache(); }
    }
    if ok && fz_step_no % fz_undo_every == fz_undo_every - 1 {
        ok = check_undo_roundtrip();
    }
    if fz_step_no == fz_show { show_step(); }
    cov_sample();
    return ok;
}

// Replay a recorded script: no prng, no mock, the events are the whole
// input. Whatever the generated run did to the core arrives here in
// the same order.
// Applies events through the same wrappers the generated run uses, so
// anything a wrapper does beyond the app_* call (the caption height a
// scale change implies, say) happens identically on both paths.
// the end of a --trace line: the state after the step's checks
private void trace_tail() {
    say(" -> line ");
    say_i(cast(i64, cur_line + 1));
    say(" col ");
    say_i(cur_col);
    say(" verts ");
    say_i(cast(i64, draw_nverts));
    say(" bufs ");
    say_i(cast(i64, ed_buf_count()));
    say(" panes ");
    say_i(cast(i64, ed_pane_count()));
    say(" hash ");
    say_i(cast(i64, fz_frame_hash >> 1));
    say(" clock ");
    say_i(g_clock_us);
    say("\n");
}

private i32 replay() {
    ev_at = 0;
    fz_step_no = 0;
    while ev_at < ev_len {
        u8 k = ev_get8();
        if k == EV_CHAR {
            ev_char(cast(u32, ev_get32()));
        } else if k == EV_KEY {
            i32 key = ev_get32();
            ev_key(key, ev_get32());
        } else if k == EV_MOUSE {
            i32 x = ev_get32();
            i32 y = ev_get32();
            i32 b = ev_get32();
            i32 dn = ev_get32();
            ev_mouse(x, y, b, dn != 0, ev_get32());
        } else if k == EV_MOVE {
            i32 x = ev_get32();
            ev_mouse_move(x, ev_get32());
        } else if k == EV_SCROLL {
            f32 dx = ev_getf();
            f32 dy = ev_getf();
            i32 x = ev_get32();
            ev_scroll(dx, dy, x, ev_get32());
        } else if k == EV_NOTCH {
            f32 dx = ev_getf();
            f32 dy = ev_getf();
            i32 x = ev_get32();
            ev_notch(dx, dy, x, ev_get32());
        } else if k == EV_HOVER {
            i32 x = ev_get32();
            i32 y = ev_get32();
            ev_hover(x, y, ev_get32());
        } else if k == EV_RESIZE {
            i32 w = ev_get32();
            ev_resize(w, ev_get32());
        } else if k == EV_SCALE {
            ev_scale(ev_get32());
        } else if k == EV_FOCUS {
            ev_focus(ev_get32() != 0);
        } else if k == EV_TIMER {
            ev_timer(ev_get32());
        } else if k == EV_WAKE {
            ev_wake();
        } else if k == EV_SETTLE {
            ev_settle();
        } else if k == EV_FEED {
            i32 n = ev_get32();
            if ev_at + cast(i64, n) > ev_len { return 2; }
            ev_feed(ev_buf + ev_at, cast(i64, n));
            ev_at += cast(i64, n);
        } else if k == EV_WATCH {
            i32 n = ev_get32();
            if n < 0 {
                ev_watch(null, -1);
            } else {
                if ev_at + cast(i64, n) > ev_len { return 2; }
                ev_watch(ev_buf + ev_at, cast(i64, n));
                ev_at += cast(i64, n);
            }
        } else if k == EV_INIT {
            ev_init();
        } else if k == EV_STATUS {
            ev_status();
        } else if k == EV_SEED {
            ev_seed(ev_get32());
        } else if k == EV_TERM {
            if ev_at + 28 > ev_len { return 2; }
            i32 op = ev_get32();
            i32 a = ev_get32();
            i32 b = ev_get32();
            i32 c = ev_get32();
            i32 d = ev_get32();
            i32 e = ev_get32();
            i32 n = ev_get32();
            if n < 0 || ev_at + cast(i64, n) > ev_len { return 2; }
            ev_term(op, a, b, c, d, e, ev_buf + ev_at, n);
            ev_at += cast(i64, n);
        } else if k == EV_STEP {
            hist_push("replayed step");
            bool ok = step_checks();
            if fz_trace {
                say("step ");
                say_i(cast(i64, fz_step_no));
                say(" replayed");
                trace_tail();
            }
            if !ok { return 1; }
            fz_tick();   // the generated run's ev_step, which wrote this mark
            fz_step_no++;
        } else {
            print("script is corrupt at byte {}\n", ev_at - 1);
            return 2;
        }
    }
    return 0;
}

// --- shrinking --------------------------------------------------------
// Delta debugging over the event list: drop a chunk, replay, keep the
// drop if the same failure survives. The format lives in this file, so
// the shrinker does too, and it re-runs itself as a child because the
// core's state cannot be rewound in process.

private const i32 PART_MAX = 200000;
private i32[PART_MAX] part_off;
private i32[PART_MAX] part_len;
private i32 part_n = 0;

// byte length of the event at `at`, or -1 when the kind is unknown
private i64 ev_size_at(i64 at) {
    u8 k = ev_buf[at];
    if k == EV_CHAR || k == EV_SCALE || k == EV_FOCUS || k == EV_TIMER || k == EV_SEED { return 5; }
    if k == EV_KEY || k == EV_MOVE || k == EV_RESIZE { return 9; }
    if k == EV_MOUSE { return 21; }
    if k == EV_SCROLL || k == EV_NOTCH { return 17; }
    if k == EV_HOVER { return 13; }
    if k == EV_WAKE || k == EV_SETTLE || k == EV_STEP || k == EV_INIT || k == EV_STATUS { return 1; }
    if k == EV_TERM {
        if at + 29 > ev_len { return -1; }
        i32 tn = *cast(i32*, ev_buf + at + 25);
        if tn < 0 { return -1; }
        return 29 + cast(i64, tn);
    }
    if k == EV_FEED || k == EV_WATCH {
        if at + 5 > ev_len { return -1; }
        i32 n = *cast(i32*, ev_buf + at + 1);
        if n < 0 { return 5; }
        return 5 + cast(i64, n);
    }
    return -1;
}

// One unit per event, or one per step (everything up to and including
// the next EV_STEP). Steps go first: there are far fewer of them, so
// the script collapses in a fraction of the replays, and every cut
// that lands makes the remaining replays cheaper.
private bool parts_index(bool by_step) {
    part_n = 0;
    i64 at = 0;
    i64 start = 0;
    while at < ev_len {
        i64 n = ev_size_at(at);
        if n <= 0 || at + n > ev_len { return false; }
        bool boundary = !by_step || ev_buf[at] == EV_STEP;
        at += n;
        if boundary {
            if part_n == PART_MAX { return false; }
            part_off[part_n] = cast(i32, start);
            part_len[part_n] = cast(i32, at - start);
            part_n++;
            start = at;
        }
    }
    if start < at {
        if part_n == PART_MAX { return false; }
        part_off[part_n] = cast(i32, start);
        part_len[part_n] = cast(i32, at - start);
        part_n++;
    }
    return true;
}

// the failure a candidate has to keep reproducing: the exit code, and
// for a reported one the FAIL line, so a shrink cannot drift onto a
// different bug
private u8[256] sig_text;
private i32 sig_len = 0;
private i32 sig_code = 0;

private void sig_of(str out, i32 code, u8* text, i32* len) {
    *len = 0;
    str key = "FAIL";
    for i32 i = 0; i + key.len < out.len; i++ {
        bool m = true;
        for i32 k = 0; k < key.len; k++ {
            if out.data[i + k] != key.data[k] { m = false; break; }
        }
        if !m { continue; }
        i32 e = i;
        while e < out.len && out.data[e] != '\n' { e++; }
        i32 n = e - i;
        if n > 256 { n = 256; }
        memcpy(text, out.data + i, n);
        *len = n;
        return;
    }
}

private u8[512] shrink_exe;
private i32 shrink_exe_len = 0;
private i32 shrink_trials = 0;

// proc_arg keeps the str it is handed, so argument numbers live here
private u8[64] shrink_args;
private i32 shrink_args_at = 0;

private str shrink_num(i32 v) {
    i32 s = shrink_args_at;
    if v == 0 {
        shrink_args[shrink_args_at] = '0';
        shrink_args_at++;
    } else {
        noinit u8[16] tmp;
        i32 t = 0;
        while v > 0 {
            tmp[t] = cast(u8, '0' + v % 10);
            v /= 10;
            t++;
        }
        for i32 i = 0; i < t; i++ {
            shrink_args[shrink_args_at] = tmp[t - 1 - i];
            shrink_args_at++;
        }
    }
    return str_from(&shrink_args[s], shrink_args_at - s);
}

// A candidate has to be judged by the same checks the original run
// used, so the flags that change them are forwarded to the child.
private void shrink_cmd(ProcCmd* c, str path) {
    shrink_args_at = 0;
    proc_init(c, str_from(&shrink_exe[0], shrink_exe_len));
    proc_arg(c, "--script");
    proc_arg(c, path);
    proc_arg(c, "--verify");
    proc_arg(c, shrink_num(fz_verify_every));
    if fz_heap { proc_arg(c, "--heap"); }
    proc_capture(c, true);
}

// write the kept parts and replay them in a child
private bool shrink_try(bool* keep, str tmp) {
    i64 n = 0;
    for i32 i = 0; i < part_n; i++ {
        if keep[i] { n += cast(i64, part_len[i]); }
    }
    u8* buf = alloc<u8>(n + 1);
    i64 o = 0;
    for i32 i = 0; i < part_n; i++ {
        if !keep[i] { continue; }
        memcpy(buf + o, ev_buf + part_off[i], part_len[i]);
        o += cast(i64, part_len[i]);
    }
    FileData fd = FileData{ buf, cast(i32, o) };
    bool wrote = file_write(tmp, fd);
    free(buf);
    if !wrote { return false; }

    ProcCmd c;
    shrink_cmd(&c, tmp);
    ProcResult r = proc_run(&c);
    shrink_trials++;
    bool same = false;
    if r.spawned && r.exit_code == sig_code {
        noinit u8[256] t;
        i32 tl = 0;
        sig_of(str_from(r.out.data, r.out.len), r.exit_code, &t[0], &tl);
        same = tl == sig_len;
        if same {
            for i32 i = 0; i < tl; i++ {
                if t[i] != sig_text[i] { same = false; break; }
            }
        }
    }
    proc_result_free(&r);
    return same;
}

// ddmin over the current parts; rewrites ev_buf to the survivor and
// returns how many units are left
private i32 shrink_pass(i32 budget, str tmp) {
    bool* keep = alloc<bool>(part_n);
    for i32 i = 0; i < part_n; i++ { keep[i] = true; }
    i32 live = part_n;
    // Sweep removing runs of units, longest first, halving the run
    // length when a whole sweep lands nothing. Granularity doubling
    // the other way never reaches single units on a long trace inside
    // any sane budget, and single units are what actually come out.
    i32 run = live / 2;
    if run < 1 { run = 1; }
    while run >= 1 && shrink_trials < budget {
        bool cut = false;
        i32 i = part_n - 1;
        while i >= 0 && shrink_trials < budget {
            if !keep[i] {
                i--;
                continue;
            }
            // the run of live units ending at i
            i32 lo = i;
            i32 got = 0;
            while lo >= 0 && got < run {
                if keep[lo] { got++; }
                if got < run { lo--; }
            }
            if got < run { break; }
            for i32 j = lo; j <= i; j++ { keep[j] = false; }
            if shrink_try(keep, tmp) {
                live -= got;
                cut = true;
                say("  ");
                say_i(cast(i64, live));
                say(" units left after ");
                say_i(cast(i64, shrink_trials));
                say(" replays\n");
            } else {
                for i32 j = lo; j <= i; j++ { keep[j] = true; }
            }
            i = lo - 1;
        }
        if !cut { run = run / 2; }
    }
    // the survivor replaces the script in memory
    i64 o = 0;
    u8* out = alloc<u8>(ev_len + 1);
    for i32 i = 0; i < part_n; i++ {
        if !keep[i] { continue; }
        memcpy(out + o, ev_buf + part_off[i], part_len[i]);
        o += cast(i64, part_len[i]);
    }
    free(keep);
    free(ev_buf);
    ev_buf = out;
    ev_len = o;
    ev_cap = o;
    return live;
}

// --replay-check: the generated run's script replayed in a child must
// end on the same frame hash. The replay has no prng and no mock, so a
// mismatch is input the script does not carry.
private i32 replay_check() {
    str exe = str_from_cstr(get_arg(0));
    if exe.len >= 512 {
        say("cannot find my own path to re-run\n");
        return 2;
    }
    memcpy(&shrink_exe[0], exe.data, exe.len);
    shrink_exe_len = exe.len;
    ProcCmd c;
    shrink_cmd(&c, str_from(&fz_script_out[0], fz_script_out_len));
    ProcResult r = proc_run(&c);
    str out = str_from(r.out.data, r.out.len);
    str key = "frame hash ";
    i64 got = -1;
    for i32 i = 0; i + key.len < out.len; i++ {
        if !str_equal(str_from(out.data + i, key.len), key) { continue; }
        got = 0;
        i32 k = i + key.len;
        while k < out.len && out.data[k] >= '0' && out.data[k] <= '9' {
            got = got * 10 + cast(i64, out.data[k] - '0');
            k++;
        }
        break;
    }
    bool ok = r.spawned && r.exit_code == 0 && got == cast(i64, fz_frame_hash >> 1);
    proc_result_free(&r);
    if !ok {
        print("ed_fuzz: seed {} replay ends on frame hash {}, the run on {}\n",
            fz_seed, got, cast(i64, fz_frame_hash >> 1));
        return 1;
    }
    return 0;
}

private i32 shrink_run(str path, i32 budget) {
    str exe = str_from_cstr(get_arg(0));
    if exe.len >= 512 {
        say("cannot find my own path to re-run\n");
        return 2;
    }
    memcpy(&shrink_exe[0], exe.data, exe.len);
    shrink_exe_len = exe.len;

    FileData sf = file_read(path);
    if sf.data == null {
        say("cannot read the script\n");
        return 2;
    }
    ev_buf = sf.data;
    ev_len = cast(i64, sf.len);
    ev_cap = ev_len;

    // baseline: it has to fail, or there is nothing to shrink
    str tmp = "build/ed_fuzz_shrink.tmp";
    ProcCmd c;
    shrink_cmd(&c, path);
    ProcResult r = proc_run(&c);
    sig_code = r.exit_code;
    sig_of(str_from(r.out.data, r.out.len), r.exit_code, &sig_text[0], &sig_len);
    proc_result_free(&r);
    if sig_code == 0 {
        say("the script replays clean; nothing to shrink\n");
        return 2;
    }
    say("shrinking ");
    say_i(ev_len);
    say(" bytes; the failure to keep is exit ");
    say_i(cast(i64, sig_code));
    say("\n");
    if sig_len > 0 {
        say("  ");
        say(str_from(&sig_text[0], sig_len));
        say("\n");
    }

    i64 was = ev_len;
    for i32 pass = 0; pass < 2; pass++ {
        if !parts_index(pass == 0) {
            say("the script is not a valid event list\n");
            return 2;
        }
        say("pass ");
        say_i(cast(i64, pass + 1));
        say(": ");
        say_i(cast(i64, part_n));
        say(" units\n");
        ignore shrink_pass(budget, tmp);
        if shrink_trials >= budget { break; }
    }

    FileData fd = FileData{ ev_buf, cast(i32, ev_len) };
    ignore file_write(path, fd);
    ignore parts_index(false);
    say("shrank ");
    say_i(was);
    say(" bytes to ");
    say_i(ev_len);
    say(" (");
    say_i(cast(i64, part_n));
    say(" events) in ");
    say_i(cast(i64, shrink_trials));
    say(" replays\n");
    return 0;
}

private void script_dump() {
    if fz_script_out_len == 0 || ev_buf == null { return; }
    FileData fd = FileData{ ev_buf, cast(i32, ev_len) };
    if !file_write(str_from(&fz_script_out[0], fz_script_out_len), fd) {
        print("could not write the script\n");
    }
}

// --- main ------------------------------------------------------------

i32 main() {
    for i32 a = 1; a < get_argc(); a++ {
        str arg = str_from_cstr(get_arg(a));
        if str_equal(arg, "--seed") && a + 1 < get_argc() {
            a++;
            fz_seed = fz_atoi(str_from_cstr(get_arg(a)));
        } else if str_equal(arg, "--steps") && a + 1 < get_argc() {
            a++;
            fz_steps = fz_atoi(str_from_cstr(get_arg(a)));
        } else if str_equal(arg, "--verify") && a + 1 < get_argc() {
            a++;
            fz_verify_every = fz_atoi(str_from_cstr(get_arg(a)));
            if fz_verify_every < 1 { fz_verify_every = 1; }
        } else if str_equal(arg, "--lsp-trace") {
            lsp_trace = true;   // each push's form and count, as the editor prints them
        } else if str_equal(arg, "--replay-check") {
            fz_replay_check = true;
        } else if str_equal(arg, "--show") && a + 1 < get_argc() {
            a++;
            fz_show = fz_atoi(str_from_cstr(get_arg(a)));
        } else if str_equal(arg, "--trace") {
            fz_trace = true;
        } else if str_equal(arg, "--vv") {
            fz_trace = true;
            fz_vv = true;
        } else if str_equal(arg, "--heap") {
            fz_heap = true;
        } else if str_equal(arg, "--coverage") {
            fz_cov = true;
        } else if str_equal(arg, "--dump-script") && a + 1 < get_argc() {
            a++;
            str v = str_from_cstr(get_arg(a));
            if v.len < 512 {
                memcpy(&fz_script_out[0], v.data, v.len);
                fz_script_out_len = v.len;
            }
        } else if str_equal(arg, "--shrink") && a + 1 < get_argc() {
            a++;
            fz_shrink = true;
            str v = str_from_cstr(get_arg(a));
            if v.len < 512 {
                memcpy(&fz_script_in[0], v.data, v.len);
                fz_script_in_len = v.len;
            }
        } else if str_equal(arg, "--budget") && a + 1 < get_argc() {
            a++;
            fz_budget = fz_atoi(str_from_cstr(get_arg(a)));
        } else if str_equal(arg, "--script") && a + 1 < get_argc() {
            a++;
            str v = str_from_cstr(get_arg(a));
            if v.len < 512 {
                memcpy(&fz_script_in[0], v.data, v.len);
                fz_script_in_len = v.len;
            }
        } else if str_equal(arg, "--quiet") {
            fz_quiet = true;
        } else if str_equal(arg, "--keep-going") {
            fz_keep_going = true;
        } else {
            print("usage: ed_fuzz [--seed N] [--steps N] [--verify N]\n");
            print("               [--trace] [--vv] [--quiet] [--keep-going]\n");
            print("  --trace   one unbuffered line per step (survives a fault)\n");
            print("  --vv      also mark each phase within a step\n");
            return 2;
        }
    }
    fz_seed_streams(fz_seed);

    if !font_init(DPI_BASE) {
        print("font init failed\n");
        return 1;
    }
    draw_init();
    g_caption_h = caption_default_h(DPI_BASE);
    // the window's size for the run: one of the screen classes an editor
    // meets, from a laptop pane to a 4K display, chosen by the seed. A
    // run at one size never sees the tall rulers and long lines of the
    // others, and the frame's cost scales with it.
    // Recording starts here, so a script begins with the run's size
    // and a replay, which has no prng, takes it from the script rather
    // than choosing one; the player reads it the same way.
    if fz_replay_check && fz_script_out_len == 0 {
        str dflt = "build/ed_fuzz_replay.evs";
        memcpy(&fz_script_out[0], dflt.data, dflt.len);
        fz_script_out_len = dflt.len;
    }
    ev_rec = fz_script_out_len > 0;
    // the child is stubbed here, so sends stay on this thread
    // where the checks below can see them as they are written
    lsp_threaded = false;
    image_threaded = false;   // decoded where the file opens
    hist_threaded = false;   // git runs where it is asked, as image decodes do
    // The tree hides gitignored entries, as it did before they could be
    // dimmed: the build folder holds whatever the last builds left, and
    // a run that expands it would draw differently from one build to
    // the next.
    ignore ign_settings(true, true, "");
    // and git's jobs run inline, so a result lands at the same wake in
    // every run: a thread that finished early or late moved it by a
    // step, and an action in between saw a different tree
    git_threaded = false;
    build_file_only = true;   // the same build command on every platform (see build.mc)
    // A replay's script carries the start as well (the resize, a wake,
    // EV_INIT and the focus), so only a generated run makes it here.
    if fz_script_in_len == 0 {
        i32[4] start_w = { 1200, 1920, 2560, 3840 };
        i32[4] start_h = { 800, 1080, 1440, 2160 };
        ev_seed(fz_seed);
        i32 sc = rnd_n(4);
        fz_start_w = start_w[sc];
        fz_start_h = start_h[sc];
        ev_resize(start_w[sc], start_h[sc] - g_caption_h);
        // a wake can arrive before any search has run (the lsp reader
        // posts one), so app_wake must survive an uninitialized search
        ev_wake();
        ev_init();
        ev_focus(true);
        mock_nfiles = pick_file_count();
    }

    if fz_shrink {
        return shrink_run(str_from(&fz_script_in[0], fz_script_in_len), fz_budget);
    }

    // replay: the script is the whole input, so neither the prng nor
    // the mock runs
    if fz_script_in_len > 0 {
        FileData sf = file_read(str_from(&fz_script_in[0], fz_script_in_len));
        if sf.data == null {
            print("cannot read the script\n");
            return 2;
        }
        ev_buf = sf.data;
        ev_len = cast(i64, sf.len);
        ev_cap = ev_len;
        i32 rc = replay();
        if rc == 0 && !fz_quiet {
            print("ed_fuzz: script ok, {} steps, frame hash {}\n",
                fz_step_no, cast(i64, fz_frame_hash >> 1));
        }
        return rc;
    }

    for fz_step_no = 0; fz_step_no < fz_steps; fz_step_no++ {
        if fz_vv {
            say("step ");
            say_i(cast(i64, fz_step_no));
            say(": server\n");
        }
        mock_tick();
        // Drained on a fixed schedule, not on fz_wake_pending: the
        // search workers post that flag from their own threads, so
        // whether the main loop sees it this step or the next depends
        // on scheduling, and the LSP dispatch would move with it. The
        // mock already varies when responses arrive, from the seed.
        fz_wake_pending = false;
        if fz_vv { say("  wake\n"); }
        ev_wake();
        if fz_vv { say("  action\n"); }
        str name = fz_action();
        hist_push(name);
        if fz_trace {
            say("step ");
            say_i(cast(i64, fz_step_no));
            say(" ");
            say(name);
        }
        // Typing in the search view starts a scan on worker threads,
        // and any step can leave one in flight. Settle it here: while
        // it runs the hit count and the "searching" line advance on
        // their own, so the frame would not be a function of the input.
        ev_settle();
        // the platform pumps wakes between events, so do the same
        fz_wake_pending = false;
        if fz_vv { say("  wake (post action)\n"); }
        ev_wake();
        // --heap: a round trip through the allocator each step, so a
        // heap overflow trips near the step that caused it instead of
        // hundreds of steps later
        if fz_heap {
            u8* probe = alloc<u8>(4096);
            memset(probe, 0xAB, 4096);
            free(probe);
        }
        bool ok = step_checks();
        if fz_trace { trace_tail(); }
        cov_sample();
        ev_step();
        if !ok && !fz_keep_going {
            script_dump();
            return 1;
        }
    }
    script_dump();
    if fz_cov { cov_report(); }

    lsp_stop();
    if fz_fails > 0 {
        print("ed_fuzz: seed {} FAILED {} checks in {} steps\n",
            fz_seed, fz_fails, fz_steps);
        return 1;
    }
    if !fz_quiet {
        print("ed_fuzz: seed {} ok, {} steps at {}x{}, frame hash {}\n",
            fz_seed, fz_steps, fz_start_w, fz_start_h, cast(i64, fz_frame_hash >> 1));
    }
    if fz_replay_check { return replay_check(); }
    return 0;
}
