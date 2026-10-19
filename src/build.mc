// build.mc - the project's build from inside the editor. Ctrl+Shift+B
// runs `minc build` when the project has a build.mc, else `minc` on
// the active .mc file. F5 runs the active .mc file with `minc run
// <file>` whatever the build.mc, which is how a sample in a folder of
// them is run. Either runs in a terminal pane of its own (the build
// pane: opened on the first run, reused after), so the output streams
// with its colors, scrolls back, and the child can read the keyboard.
// The bytes are also kept aside raw and parsed for the compiler's
// `path:line:col: error|warning: message` lines: F8 and Shift+F8 walk
// the problems and open each at its position, a click on such a row in
// the pane does the same. A C or C++ buffer compiles alone instead
// (build_c_start). Ctrl+J hides the build pane and brings it
// back, the run going on behind it; Ctrl+W on it ends the run. Nothing
// on the UI thread waits for the build.

private const i32 BUILD_PROB_MAX = 512;
private const i64 BUILD_OUT_MAX = 4 * 1024 * 1024;
private const i32 BUILD_HEADER_MAX = 256;
private const i32 BUILD_CARRY_MAX = 64;   // an escape split across two reads
private const i32 BUILD_ROW_MAX = 4096;   // a grid row as text

struct BuildProblem {
    i32 path_off;   // into build_out
    i32 path_len;
    i32 line;       // 1-based, as printed
    i32 col;
    i32 sev;        // 1 error, 2 warning
    i32 out_line;   // the output line it was parsed from
}

private bool build_running = false;
private i64 build_started_us = 0;
// A build or a run asked for while one is going: this soon after its
// start it is taken for a double press and dropped; later it stops the
// run and starts again, so a run that hangs never blocks the keys.
private const i64 BUILD_RESTART_US = 10000000;
private bool build_noticed = false;   // the notice up is the refusal's
private bool build_stopped = false;   // Ctrl+. ended the run
private bool build_run = false;    // F5: `minc run <file>`, not a build
private i32 build_t = -1;       // the build pane's terminal, or -1
private u8* build_out = null;      // the output, colors stripped
private i64 build_out_len = 0;
private i64 build_out_cap = 0;
private i32* build_line_off = null;
private i32 build_line_cap = 0;
private i32 build_nlines = 0;      // lines indexed, the last one possibly unfinished
private i32 build_parsed = 0;      // lines the parser has seen
private BuildProblem[BUILD_PROB_MAX] build_prob;
private i32 build_nprob = 0;
private i32 build_nerr = 0;
private i32 build_nwarn = 0;
private i32 build_cur = -1;        // the problem last jumped to, or none
private i32 build_code = -1;
private bool build_ran = false;
private u8[BUILD_HEADER_MAX] build_hdr;
private i32 build_hdr_len = 0;
private u8[BUILD_CARRY_MAX] build_carry;
private i32 build_carry_len = 0;
private u8[PATH_MAX] build_target;   // the file, when there is no build.mc
private i32 build_target_len = 0;
private u8[PATH_MAX] build_minc;     // the compiler: $MINC/minc, else minc on the PATH
private i32 build_minc_len = 0;
// The fuzzer sets this: whether a build.mc is in the working directory
// is not portable across its platforms (no file check in the browser),
// and the command is in the pane's banner, so both must run the same
// command for a seed to mean one frame everywhere.
bool build_file_only = false;

// --- what the view and the walk read ---------------------------------------

// the build pane's terminal, so the pane can be told from a shell's
i32 build_term() {
    return build_t;
}

bool build_is_running() {
    return build_running;
}

i32 build_line_count() {
    return build_nlines;
}

str build_line(i32 i) {
    if i < 0 || i >= build_nlines { return ""; }
    i32 a = build_line_off[i];
    i32 b = cast(i32, build_out_len);
    if i + 1 < build_nlines { b = build_line_off[i + 1] - 1; }
    if b > a && build_out[b - 1] == 10 { b--; }
    if b < a { b = a; }
    return str_from(build_out + a, b - a);
}

i32 build_problem_count() {
    return build_nprob;
}

i32 build_error_count() {
    return build_nerr;
}

i32 build_current() {
    return build_cur;
}

str build_header() {
    return str_from(&build_hdr[0], build_hdr_len);
}

private void build_set_header(str a, i32 n1, str b, i32 n2, str c) {
    i32 o = 0;
    if a.len > 0 && o + a.len < BUILD_HEADER_MAX {
        memcpy(&build_hdr[o], a.data, a.len);
        o += a.len;
    }
    if n1 >= 0 && o + 12 < BUILD_HEADER_MAX { o += fmt_i32(&build_hdr[o], n1); }
    if b.len > 0 && o + b.len < BUILD_HEADER_MAX {
        memcpy(&build_hdr[o], b.data, b.len);
        o += b.len;
    }
    if n2 >= 0 && o + 12 < BUILD_HEADER_MAX { o += fmt_i32(&build_hdr[o], n2); }
    if c.len > 0 && o + c.len < BUILD_HEADER_MAX {
        memcpy(&build_hdr[o], c.data, c.len);
        o += c.len;
    }
    build_hdr_len = o;
}

// --- the output -----------------------------------------------------------

private void build_out_reserve(i64 need) {
    if need <= build_out_cap { return; }
    i64 cap = need + 4096;
    u8* nb = alloc<u8>(cap);
    if build_out != null {
        if build_out_len > 0 { memcpy(nb, build_out, build_out_len); }
        free(build_out);
    }
    build_out = nb;
    build_out_cap = cap;
}

private void build_lines_reserve(i32 need) {
    if need <= build_line_cap { return; }
    i32 cap = need + 64;
    i32* nl = alloc<i32>(cast(i64, cap));
    if build_line_off != null {
        if build_nlines > 0 { memcpy(nl, build_line_off, cast(i64, build_nlines) * sizeof(i32)); }
        free(build_line_off);
    }
    build_line_off = nl;
    build_line_cap = cap;
}

// Append a read, with the terminal colors (ESC [ ... m) and carriage
// returns dropped, and index the lines that arrived. A color sequence
// cut by the read boundary is carried into the next call.
void build_feed(u8* raw, i64 n) {
    if n <= 0 { return; }
    // the carry first: the sequence the last call could not finish
    u8* p = raw;
    i64 pn = n;
    u8* joined = null;
    if build_carry_len > 0 {
        joined = alloc<u8>(build_carry_len + n);
        memcpy(joined, &build_carry[0], build_carry_len);
        memcpy(joined + build_carry_len, raw, n);
        p = joined;
        pn = build_carry_len + n;
        build_carry_len = 0;
    }
    i64 room = BUILD_OUT_MAX - build_out_len;
    if room <= 0 {
        if joined != null { free(joined); }
        return;
    }
    build_out_reserve(build_out_len + pn + 1);
    i64 w = build_out_len;
    i64 i = 0;
    while i < pn {
        u8 c = p[i];
        if c == 27 && i + 1 < pn && p[i + 1] == '[' {
            i64 j = i + 2;
            while j < pn && (p[j] == ';' || p[j] == '?' || (p[j] >= '0' && p[j] <= '9')) { j++; }
            if j >= pn {
                // unfinished: keep it for the next read, unless it is
                // longer than any color sequence, then it is text
                if pn - i <= BUILD_CARRY_MAX {
                    memcpy(&build_carry[0], p + i, pn - i);
                    build_carry_len = cast(i32, pn - i);
                    break;
                }
            } else if p[j] >= 64 && p[j] <= 126 {
                i = j + 1;   // any CSI final byte: colors above all
                continue;
            }
        }
        if c == 27 && i + 1 >= pn {
            build_carry[0] = 27;
            build_carry_len = 1;
            break;
        }
        if c != 13 && w - build_out_len < room {
            build_out[w] = c;
            w++;
        }
        i++;
    }
    if joined != null { free(joined); }
    i64 start = build_out_len;
    build_out_len = w;
    if w == start { return; }
    // the line index: the first line starts at 0, every newline starts
    // one, but only once a byte has followed it (a trailing newline is
    // the last line's own, not an empty line after it)
    if build_nlines == 0 {
        build_lines_reserve(1);
        build_line_off[0] = 0;
        build_nlines = 1;
    } else if start > 0 && build_out[start - 1] == 10 {
        build_lines_reserve(build_nlines + 1);
        build_line_off[build_nlines] = cast(i32, start);
        build_nlines++;
    }
    for i64 k = start; k < w; k++ {
        if build_out[k] == 10 && k + 1 < w {
            build_lines_reserve(build_nlines + 1);
            build_line_off[build_nlines] = cast(i32, k + 1);
            build_nlines++;
        }
    }
    build_parse(false);
}

// a decimal run ending at `end` (exclusive), its start in *start
private bool build_num_before(u8* s, i32 end, i32* start, i32* value) {
    i32 b = end;
    while b > 0 && s[b - 1] >= '0' && s[b - 1] <= '9' { b--; }
    if b == end || end - b > 9 { return false; }
    i32 v = 0;
    for i32 i = b; i < end; i++ { v = v * 10 + cast(i32, s[i] - '0'); }
    *start = b;
    *value = v;
    return true;
}

// `path:line:col: error: message` and `warning:` lines. The path can
// carry a drive colon, so the split runs from the right. Returns the
// path's length, 0 when the line is not one.
private i32 build_parse_line(str ln, i32* line, i32* col, i32* sev) {
    str ek = ": error: ";
    str fk = ": fatal error: ";
    str wk = ": warning: ";
    i32 s = 0;
    i32 at = -1;
    for i32 i = 0; i + ek.len <= ln.len && at < 0; i++ {
        if str_equal(str_from(ln.data + i, ek.len), ek) {
            s = 1;
            at = i;
        } else if i + fk.len <= ln.len && str_equal(str_from(ln.data + i, fk.len), fk) {
            s = 1;
            at = i;
        } else if i + wk.len <= ln.len && str_equal(str_from(ln.data + i, wk.len), wk) {
            s = 2;
            at = i;
        }
    }
    if at <= 0 { return build_parse_msvc(ln, line, col, sev); }
    i32 cs = 0;
    i32 c = 0;
    if !build_num_before(ln.data, at, &cs, &c) || cs < 2 || ln.data[cs - 1] != ':' { return 0; }
    i32 ls = 0;
    i32 l = 0;
    if !build_num_before(ln.data, cs - 1, &ls, &l) || ls < 2 || ln.data[ls - 1] != ':' { return 0; }
    i32 plen = ls - 1;
    if plen <= 0 || plen >= PATH_MAX { return 0; }
    *line = l;
    *col = c;
    *sev = s;
    return plen;
}

// `path(line,col): error C2065: message`, the MSVC form (cl with
// /diagnostics:column), or `path(line): ...` without the column.
// Returns the path's length, 0 when the line is not one.
private i32 build_parse_msvc(str ln, i32* line, i32* col, i32* sev) {
    str ek = "): error ";
    str fk = "): fatal error ";
    str wk = "): warning ";
    i32 s = 0;
    i32 at = -1;
    for i32 i = 0; i + wk.len <= ln.len && at < 0; i++ {
        if str_equal(str_from(ln.data + i, ek.len), ek) {
            s = 1;
            at = i;
        } else if i + fk.len <= ln.len && str_equal(str_from(ln.data + i, fk.len), fk) {
            s = 1;
            at = i;
        } else if str_equal(str_from(ln.data + i, wk.len), wk) {
            s = 2;
            at = i;
        }
    }
    if at <= 0 { return 0; }
    i32 c = 1;
    i32 ns = 0;
    i32 n = 0;
    if !build_num_before(ln.data, at, &ns, &n) || ns < 2 { return 0; }
    if ln.data[ns - 1] == ',' {
        c = n;
        if !build_num_before(ln.data, ns - 1, &ns, &n) || ns < 2 { return 0; }
    }
    if ln.data[ns - 1] != '(' { return 0; }
    i32 plen = ns - 1;
    if plen <= 0 || plen >= PATH_MAX { return 0; }
    *line = n;
    *col = c;
    *sev = s;
    return plen;
}

// the lines not yet parsed; a line still being written waits for its
// newline, unless the run is over (`all`) and it is the last there is
private void build_parse(bool all) {
    i32 done = build_nlines;
    if !all && build_nlines > 0 && build_out_len > 0 && build_out[build_out_len - 1] != 10 { done = build_nlines - 1; }
    for i32 l = build_parsed; l < done && build_nprob < BUILD_PROB_MAX; l++ {
        str ln = build_line(l);
        i32 line = 0;
        i32 col = 0;
        i32 sev = 0;
        i32 plen = build_parse_line(ln, &line, &col, &sev);
        if plen == 0 { continue; }
        BuildProblem* p = &build_prob[build_nprob];
        p.path_off = cast(i32, ln.data - build_out);
        p.path_len = plen;
        p.line = line;
        p.col = col;
        p.sev = sev;
        p.out_line = l;
        build_nprob++;
        if sev == 1 { build_nerr++; } else { build_nwarn++; }
    }
    if done > build_parsed { build_parsed = done; }
}

// the run is over: the last line, the header, the status
void build_finish(i32 code) {
    build_running = false;
    if build_noticed {
        build_noticed = false;
        ed_notice_close();
    }
    build_ran = true;
    build_parse(true);
    build_code = code;
    bool build_stopped_last = build_stopped;
    if build_stopped {
        build_stopped = false;
        if build_run { build_set_header("run stopped", -1, "", -1, ""); }
        else { build_set_header("build stopped", -1, "", -1, ""); }
    } else if build_nerr > 0 || build_nwarn > 0 {
        build_set_header("", build_nerr, " errors, ", build_nwarn, " warnings");
    } else if code == 0 {
        if build_run { build_set_header("done", -1, "", -1, ""); }
        else { build_set_header("build ok", -1, "", -1, ""); }
    } else if build_run {
        build_set_header("run failed (exit ", code, ")", -1, "");
    } else {
        build_set_header("build failed (exit ", code, ")", -1, "");
    }
    // a failure stays up; a success goes by itself
    if build_nerr > 0 || (code != 0 && !build_stopped_last) {
        ed_warn(build_header());
    } else {
        ed_status(build_header());
    }
    plat_damage();
}

// drop the previous run's text so the walk never lands in stale output
private void build_clear() {
    build_out_len = 0;
    build_nlines = 0;
    build_parsed = 0;
    build_nprob = 0;
    build_nerr = 0;
    build_nwarn = 0;
    build_cur = -1;
    build_carry_len = 0;
    build_ran = false;
}

// --- the run --------------------------------------------------------------

// the compiler to run: $MINC/minc when MINC names the install, else
// whatever `minc` the shell finds on the PATH (the harness's runs
// take the plain name, so the banner reads the same everywhere)
private str build_minc_path() {
    if build_minc_len > 0 { return str_from(&build_minc[0], build_minc_len); }
    string dir = env_get("MINC");
    if !build_file_only && dir.len > 0 && dir.len + 6 < PATH_MAX {
        memcpy(&build_minc[0], dir.data, dir.len);
        build_minc_len = cast(i32, dir.len);
        u8 sep = '/';
        when os(windows) { sep = 92; }
        build_minc[build_minc_len] = sep;
        build_minc_len++;
        str name = "minc";
        memcpy(&build_minc[build_minc_len], name.data, name.len);
        build_minc_len += name.len;
    } else {
        str name = "minc";
        memcpy(&build_minc[0], name.data, name.len);
        build_minc_len = name.len;
    }
    free(dir);
    return str_from(&build_minc[0], build_minc_len);
}

// True when the request is dropped. A run old enough is stopped here:
// the launch that follows closes its terminal, which ends its child and
// everything the child started (plat_term_kill).
// The refusal is a notice, which shows with the status bar hidden too,
// and the build pane comes back if Ctrl+J hid it, so the run is seen.
private bool build_busy() {
    if !build_running { return false; }
    i64 age = plat_time_us() - build_started_us;
    if age < BUILD_RESTART_US {
        i32 left = cast(i32, (BUILD_RESTART_US - age + 999999) / 1000000);
        noinit u8[128] m;
        str a = "a run is going: press again in ";
        str b = " s to stop it and start over";
        memcpy(&m[0], a.data, a.len);
        i32 n = a.len + fmt_i32(&m[a.len], left);
        memcpy(&m[n], b.data, b.len);
        n += b.len;
        ed_notice_info(str_from(&m[0], n));
        build_noticed = true;
        if build_t >= 0 && ed_build_pane() < 0 { ignore ed_build_pane_show(); }
        plat_damage();
        return true;
    }
    build_running = false;
    return false;
}

// the command in the build pane; the pane opens or is reused by ed.mc
private void build_launch() {
    noinit str[3] argv;
    argv[0] = build_minc_path();
    i32 argc = 2;
    if build_run {
        argv[1] = "run";
        if build_target_len > 0 {
            argv[2] = str_from(&build_target[0], build_target_len);
            argc = 3;
        }
    } else if build_target_len > 0 {
        argv[1] = str_from(&build_target[0], build_target_len);   // no build.mc: compile the file
    } else {
        argv[1] = "build";
    }
    build_launch_argv(&argv[0], argc);
}

// argv in the build pane, the run's state reset
private void build_launch_argv(str* argv, i32 argc) {
    build_clear();
    i32 t = ed_build_pane_open(argv, argc);
    if t < 0 {
        build_t = -1;
        build_hdr_len = 0;
        ed_warn("no terminal for the build here: the platform has no pseudo-terminal");
        plat_damage();
        return;
    }
    build_t = t;
    term_tap(t, true);
    build_running = true;
    build_stopped = false;
    build_started_us = plat_time_us();
    if build_noticed {
        build_noticed = false;
        ed_notice_close();
    }
    plat_damage();
}

void build_start() {
    if build_c_start(false) { return; }
    if build_busy() { return; }
    build_run = false;
    build_target_len = 0;
    if build_file_only || !path_exists("build.mc") {
        str p = ed_path();
        if p.len == 0 || !str_ends_with(p, ".mc") {
            ed_warn("nothing to build: no build.mc here, and the buffer is not a .mc file");
            plat_damage();
            return;
        }
        memcpy(&build_target[0], p.data, p.len);
        build_target_len = p.len;
    }
    build_set_header("building...", -1, "", -1, "");
    ed_status("building...");
    build_launch();
}

// F5: run the project, `minc run`, which is build.mc's run. Without a
// build.mc it runs the active file, as the build does.
void build_run_project_start() {
    if build_c_start(true) { return; }
    if build_file_only || !path_exists("build.mc") {
        build_run_start();
        return;
    }
    if build_busy() { return; }
    build_run = true;
    build_target_len = 0;
    build_set_header("running...", -1, "", -1, "");
    ed_status("running...");
    build_launch();
}

// Shift+F5: compile and run the active .mc file (`minc run <file>`),
// whatever the project's build.mc does, which is how a sample is run.
// The program's own output lands in the pane, and it can read what is
// typed there.
void build_run_start() {
    if build_c_start(true) { return; }
    if build_busy() { return; }
    str p = ed_path();
    if p.len == 0 || !str_ends_with(p, ".mc") {
        ed_warn("nothing to run: the buffer is not a .mc file");
        plat_damage();
        return;
    }
    build_run = true;
    memcpy(&build_target[0], p.data, p.len);
    build_target_len = p.len;
    build_set_header("running...", -1, "", -1, "");
    ed_status("running...");
    build_launch();
}

// --- C and C++ --------------------------------------------------------------
// The active .c or .cpp file alone, compiled into the project's build/
// folder and, for a run, started there. The compiler is found by a
// script that runs in the build pane, so nothing on the UI thread
// waits for a lookup. On Windows the script is a .cmd file in build/:
// it takes MSVC through vswhere and vcvars64.bat, else clang, else
// gcc. A command line cannot carry it, because cmd does not read the
// C runtime's quote escapes. On macOS and Linux it is an `sh -c`
// script that takes cc, else clang, else gcc (the C++ names for C++).

private const i32 BUILD_C = 1;
private const i32 BUILD_CPP = 2;
private const i32 BUILD_C_HEADER = 3;
private const i32 BUILD_SCRIPT_MAX = 8192;
private const str BUILD_C_SCRIPT = "build/edminc_cc.cmd";

// the C family of a path: BUILD_C, BUILD_CPP, BUILD_C_HEADER, or 0
private i32 build_c_kind(str p) {
    if str_ends_with(p, ".c") { return BUILD_C; }
    if str_ends_with(p, ".cpp") || str_ends_with(p, ".cc") || str_ends_with(p, ".cxx") { return BUILD_CPP; }
    if str_ends_with(p, ".h") || str_ends_with(p, ".hpp") || str_ends_with(p, ".hh") { return BUILD_C_HEADER; }
    return 0;
}

// True when the buffer defines main: `main` or `wmain` before a `(`,
// with only type words in front of it on the line, on a line that is
// not a comment and does not end in `;` (a declaration).
bool build_c_has_main() {
    for i32 l = 0; l < tb.nlines; l++ {
        i32 n = line_bytes(l);
        u8* s = g_linebuf;
        i32 a = 0;
        while a < n && (s[a] == ' ' || s[a] == 9) { a++; }
        if a + 1 < n && s[a] == '/' && (s[a + 1] == '/' || s[a + 1] == '*') { continue; }
        if a < n && s[a] == '*' { continue; }
        i32 e = n;
        while e > a && (s[e - 1] == ' ' || s[e - 1] == 9) { e--; }
        if e > a && s[e - 1] == ';' { continue; }
        i32 i = a;
        while i < e {
            u8 c = s[i];
            bool id0 = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
            if !id0 {
                // a type's punctuation: int* main, std::
                if c == ' ' || c == 9 || c == '*' || c == '&' || c == ':' { i++; continue; }
                break;
            }
            i32 j = i;
            while j < e && ((s[j] >= 'a' && s[j] <= 'z') || (s[j] >= 'A' && s[j] <= 'Z')
                || (s[j] >= '0' && s[j] <= '9') || s[j] == '_') { j++; }
            str w = str_from(s + i, j - i);
            if str_equal(w, "main") || str_equal(w, "wmain") {
                i32 k = j;
                while k < e && (s[k] == ' ' || s[k] == 9) { k++; }
                if k < e && s[k] == '(' { return true; }
            }
            i = j;
        }
    }
    return false;
}

private void bc_put(u8* b, i32* n, str s) {
    if *n + s.len >= BUILD_SCRIPT_MAX { return; }
    memcpy(b + *n, s.data, s.len);
    *n += s.len;
}

// s inside a cmd `set "NAME=..."`: a % doubles, or cmd expands it
private void bc_put_cmd(u8* b, i32* n, str s) {
    for i32 i = 0; i < s.len && *n + 2 < BUILD_SCRIPT_MAX; i++ {
        b[*n] = s.data[i];
        *n += 1;
        if s.data[i] == '%' {
            b[*n] = '%';
            *n += 1;
        }
    }
}

// s as one sh word in single quotes, a quote in it as '\''
private void bc_put_sh(u8* b, i32* n, str s) {
    bc_put(b, n, "'");
    for i32 i = 0; i < s.len && *n + 5 < BUILD_SCRIPT_MAX; i++ {
        if s.data[i] == 39 {
            bc_put(b, n, "'\\''");
        } else {
            b[*n] = s.data[i];
            *n += 1;
        }
    }
    bc_put(b, n, "'");
}

// the file's name without its folder and extension
private str build_c_stem(str p) {
    i32 a = 0;
    for i32 i = 0; i < p.len; i++ {
        if p.data[i] == '/' || p.data[i] == 92 { a = i + 1; }
    }
    i32 e = p.len;
    for i32 i = p.len - 1; i > a; i-- {
        if p.data[i] == '.' {
            e = i;
            break;
        }
    }
    return str_from(p.data + a, e - a);
}

// a clang or gcc arm of the Windows script, under its label
private void bc_cmd_gnu(u8* b, i32* n, str label, str cc, bool link) {
    bc_put(b, n, label);
    bc_put(b, n, "\r\ntitle ");
    bc_put(b, n, cc);
    bc_put(b, n, " %SRC%\r\necho ");
    bc_put(b, n, cc);
    bc_put(b, n, " %SRC%\r\n");
    bc_put(b, n, cc);
    if link { bc_put(b, n, " -g -Wall \"%SRC%\" -o \"%OUT%\"\r\n"); }
    else { bc_put(b, n, " -g -Wall -c \"%SRC%\" -o \"%OUT%\"\r\n"); }
    bc_put(b, n, "if errorlevel 1 exit /b 1\r\ngoto done\r\n");
}

// The Windows script: the compiler lookup, the compile, and for a run
// the program. Its exit code is the compiler's, or the program's.
private i32 build_c_script_cmd(u8* b, str src, str stem, bool cpp, bool link, bool run) {
    i32 n = 0;
    bc_put(b, &n, "@echo off\r\nsetlocal\r\nset \"SRC=");
    bc_put_cmd(b, &n, src);
    bc_put(b, &n, "\"\r\nset \"OUT=build\\");
    bc_put_cmd(b, &n, stem);
    if link { bc_put(b, &n, ".exe\"\r\n"); } else { bc_put(b, &n, ".obj\"\r\n"); }
    bc_put(b, &n, "if not exist build mkdir build\r\n");
    bc_put(b, &n, "set \"VSWHERE=%ProgramFiles(x86)%\\Microsoft Visual Studio\\Installer\\vswhere.exe\"\r\n");
    bc_put(b, &n, "set \"VSDIR=\"\r\n");
    bc_put(b, &n, "if exist \"%VSWHERE%\" for /f \"usebackq tokens=*\" %%i in (`\"%VSWHERE%\" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set \"VSDIR=%%i\"\r\n");
    bc_put(b, &n, "if defined VSDIR if exist \"%VSDIR%\\VC\\Auxiliary\\Build\\vcvars64.bat\" goto msvc\r\n");
    bc_put(b, &n, "where clang >nul 2>nul && goto clang\r\n");
    bc_put(b, &n, "if exist \"%ProgramFiles%\\LLVM\\bin\\clang.exe\" set \"PATH=%ProgramFiles%\\LLVM\\bin;%PATH%\" && goto clang\r\n");
    bc_put(b, &n, "where gcc >nul 2>nul && goto gcc\r\n");
    bc_put(b, &n, "echo no C compiler found: install Visual Studio with the C++ workload, LLVM clang, or MinGW gcc\r\nexit /b 1\r\n");
    // MSVC: vcvars64.bat sets INCLUDE, LIB and PATH for cl
    // vcvars64.bat runs vswhere by name, from the PATH
    bc_put(b, &n, ":msvc\r\nset \"PATH=%ProgramFiles(x86)%\\Microsoft Visual Studio\\Installer;%PATH%\"\r\ncall \"%VSDIR%\\VC\\Auxiliary\\Build\\vcvars64.bat\" >nul\r\ntitle cl %SRC%\r\necho cl %SRC%\r\n");
    bc_put(b, &n, "cl /nologo /Zi /W3 /FC /diagnostics:column /Fd:build\\ ");
    if cpp { bc_put(b, &n, "/EHsc "); } else { bc_put(b, &n, "/std:c17 /experimental:c11atomics "); }
    if link { bc_put(b, &n, "/Fo:build\\ \"%SRC%\" /Fe:\"%OUT%\"\r\n"); }
    else { bc_put(b, &n, "/c \"%SRC%\" /Fo:\"%OUT%\"\r\n"); }
    bc_put(b, &n, "if errorlevel 1 exit /b 1\r\ngoto done\r\n");
    if cpp {
        bc_cmd_gnu(b, &n, ":clang", "clang++", link);
        bc_cmd_gnu(b, &n, ":gcc", "g++", link);
    } else {
        bc_cmd_gnu(b, &n, ":clang", "clang", link);
        bc_cmd_gnu(b, &n, ":gcc", "gcc", link);
    }
    bc_put(b, &n, ":done\r\n");
    if run { bc_put(b, &n, "\"%OUT%\"\r\nexit /b %errorlevel%\r\n"); }
    return n;
}

// The macOS and Linux script, for `sh -c`.
private i32 build_c_script_sh(u8* b, str src, str stem, bool cpp, bool link, bool run) {
    i32 n = 0;
    bc_put(b, &n, "SRC=");
    bc_put_sh(b, &n, src);
    bc_put(b, &n, "\nOUT=build/");
    bc_put_sh(b, &n, stem);
    if !link { bc_put(b, &n, ".o"); }
    bc_put(b, &n, "\nmkdir -p build || exit 1\nCC=\nfor c in ");
    if cpp { bc_put(b, &n, "c++ clang++ g++"); } else { bc_put(b, &n, "cc clang gcc"); }
    bc_put(b, &n, "; do if command -v \"$c\" >/dev/null 2>&1; then CC=$c; break; fi; done\n");
    bc_put(b, &n, "if [ -z \"$CC\" ]; then echo 'no C compiler found: install clang or gcc (the Xcode Command Line Tools on macOS)'; exit 1; fi\n");
    bc_put(b, &n, "echo \"$CC $SRC\"\n");
    if link { bc_put(b, &n, "\"$CC\" -g -Wall \"$SRC\" -o \"$OUT\" || exit $?\n"); }
    else { bc_put(b, &n, "\"$CC\" -g -Wall -c \"$SRC\" -o \"$OUT\" || exit $?\n"); }
    if run { bc_put(b, &n, "\"./$OUT\"\n"); }
    return n;
}

// Ctrl+Shift+B, F5 and Ctrl+R on a C or C++ buffer. A file with a main
// links into build/<name>, and a run starts it; one without compiles
// to an object only. True when the buffer is in the C family, so the
// caller has nothing more to do.
private bool build_c_start(bool run) {
    str p = ed_path();
    i32 kind = build_c_kind(p);
    if kind == 0 { return false; }
    if build_busy() { return true; }
    if kind == BUILD_C_HEADER {
        ed_warn("nothing to build: a header file compiles with the file that includes it");
        plat_damage();
        return true;
    }
    bool link = build_c_has_main();
    if run && !link { ed_status("no main() in the file: compiled only"); }
    run = run && link;
    noinit u8[BUILD_SCRIPT_MAX] sb;
    noinit str[4] argv;
    i32 argc = 0;
    str stem = build_c_stem(p);
    when os(windows) {
        i32 n = build_c_script_cmd(&sb[0], p, stem, kind == BUILD_CPP, link, run);
        // the fuzzer never writes a file; its run gets the command alone
        if !build_file_only {
            ignore dir_create("build");
            if !file_write(BUILD_C_SCRIPT, FileData{ &sb[0], n }) {
                ed_warn("cannot write build/edminc_cc.cmd");
                plat_damage();
                return true;
            }
        }
        argv[0] = "cmd.exe";
        argv[1] = "/d";
        argv[2] = "/c";
        argv[3] = "build\\edminc_cc.cmd";
        argc = 4;
    }
    when !os(windows) {
        i32 n = build_c_script_sh(&sb[0], p, stem, kind == BUILD_CPP, link, run);
        argv[0] = "sh";
        argv[1] = "-c";
        argv[2] = str_from(&sb[0], n);
        argc = 3;
    }
    build_run = run;
    build_target_len = 0;
    if run {
        build_set_header("running...", -1, "", -1, "");
        ed_status("running...");
    } else {
        build_set_header("building...", -1, "", -1, "");
        ed_status("building...");
    }
    build_launch_argv(&argv[0], argc);
    return true;
}

// main thread, after the terminals were pumped: the bytes the tap kept,
// and the exit when it has come
void build_poll() {
    if build_t < 0 { return; }
    i64 n = 0;
    u8* q = term_tap_take(build_t, &n);
    if q != null {
        build_feed(q, n);
        free(q);
    }
    if build_running && term_exited(build_t) { build_finish(term_code(build_t)); }
}

// the pane went (Ctrl+W, a folder switch): the terminal is closed by
// the pane, the output stays for the walk
void build_pane_closed() {
    build_t = -1;
    if build_running {
        build_running = false;
        build_hdr_len = 0;
    }
}

// headless: wait for the run; not for the UI thread
void build_settle() {
    while build_running && build_t >= 0 {
        term_wait(build_t);
        ignore term_pump();
        build_poll();
        if !term_live(build_t) { break; }
    }
}

// --- navigation ---------------------------------------------------------

void build_jump(i32 i) {
    if i < 0 || i >= build_nprob { return; }
    build_cur = i;
    BuildProblem* p = &build_prob[i];
    str path = str_from(build_out + p.path_off, p.path_len);
    ed_goto_bytes(path, p.line - 1, cast(i64, p.col - 1));
    plat_damage();
}

// a click on a row of the build pane: a problem line opens its place
// and becomes the walk's current one, any other row does nothing
bool build_click_row(i32 row) {
    if build_t < 0 { return false; }
    noinit u8[BUILD_ROW_MAX] rb;
    i32 n = term_row_text(build_t, row, &rb[0], BUILD_ROW_MAX);
    if n <= 0 { return false; }
    str ln = str_from(&rb[0], n);
    i32 line = 0;
    i32 col = 0;
    i32 sev = 0;
    i32 plen = build_parse_line(ln, &line, &col, &sev);
    if plen == 0 { return false; }
    for i32 i = 0; i < build_nprob; i++ {
        if build_prob[i].line == line && build_prob[i].col == col
            && build_prob[i].path_len == plen
            && str_equal(str_from(build_out + build_prob[i].path_off, plen), str_from(ln.data, plen)) {
            build_jump(i);
            return true;
        }
    }
    ed_goto_bytes(str_from(ln.data, plen), line - 1, cast(i64, col - 1));
    plat_damage();
    return true;
}

// Ctrl+. (Cmd+. on macOS): the build or run ends now, with everything
// it started. The pane and the output stay, and the banner says it was
// stopped.
void build_stop() {
    if !build_running || build_t < 0 {
        ed_status("no build or run is going");
        plat_damage();
        return;
    }
    build_stopped = true;
    term_stop(build_t);
    ed_status("stopping...");
    plat_damage();
}

bool build_key(i32 key, i32 mods) {
    if key == 'B' && mods == (MOD_CTRL | MOD_SHIFT) {
        build_start();
        return true;
    }
    // F5 and the primary modifier with R (Cmd+R on macOS) run the
    // project; with Shift they run the active file. Both work with a
    // terminal pane focused too: the shell never sees Ctrl+R.
    if (key == K_F5 && mods == 0) || (key == 'R' && mods == MOD_CTRL) {
        build_run_project_start();
        return true;
    }
    if (key == K_F5 && mods == MOD_SHIFT) || (key == 'R' && mods == (MOD_CTRL | MOD_SHIFT)) {
        build_run_start();
        return true;
    }
    if key == '.' && mods == MOD_CTRL {
        build_stop();
        return true;
    }
    if key == 'J' && mods == MOD_CTRL {
        // the build pane hides and shows; the run goes on behind it
        if build_t >= 0 && ed_build_pane() >= 0 {
            ed_build_pane_hide();
        } else if build_t >= 0 && ed_build_pane_show() {
            // back on screen
        } else {
            ed_status("no build pane: ctrl+shift+b builds the project");
        }
        plat_damage();
        return true;
    }
    if key == K_F8 && (mods == 0 || mods == MOD_SHIFT) {
        if build_nprob == 0 {
            if build_ran { ed_status("no problems"); }
            plat_damage();
            return true;
        }
        i32 i = build_cur;
        if mods == MOD_SHIFT {
            i--;
            if i < 0 { i = build_nprob - 1; }
        } else {
            i++;
            if i >= build_nprob { i = 0; }
        }
        build_jump(i);
        return true;
    }
    return false;
}
