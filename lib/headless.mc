// headless.mc - the command line a headless run is driven by, and the
// state it fills, shared by the native drivers. --shot renders one
// frame to a PPM; --key, --char and --wait inject input in order;
// --dump-term writes the terminal pane's screen once the shell has
// stopped printing, --term-raw every byte the child sent, --dump-wait
// the settle a slow child gets; --handover names the state a restart
// left behind; --play replays a fuzz run; --smoke, --time and
// --lsp-trace are the checks; --no-detach keeps the editor in the
// shell that started it. A driver parses its own flags first and
// hands every other argument to hl_arg, calls hl_inject once its window
// is up and hl_dump_term before the shot, and its plat_exec_self
// appends hl_restart_arg's to the argv (doc/TESTING.md, "Headless runs"). The
// driver supplies plat_sleep_ms.

bool g_smoke = false;
bool g_time = false;     // print per-paint timing to stdout
bool g_newwin = false;   // --newwin: open a second window at start
u8[1024] g_play;         // --play <script>: a recorded fuzz run
i32 g_play_len = 0;
i32 g_play_ms = PLAY_MS_DEFAULT;
u8[64] g_theme_arg;      // --theme <name>: a built-in theme for this run
i32 g_theme_arg_len = 0;
u8[1024] g_shot;         // --shot <file>: one frame, offscreen, as a PPM
i32 g_shot_len = 0;
const i32 INJECT_MAX = 128;   // --key/--char injections; a typed shell command needs room
i32[INJECT_MAX * 3] g_keys;   // kind, a, b triples: 0 key+mods, 1 char, 2 wait ms
i32 g_nkeys = 0;
u8[1024] g_handover;     // --handover <file>: the previous process's state, from a restart
i32 g_handover_len = 0;
u8[1024] g_dump_term;    // --dump-term <file>: the active terminal pane's screen as text
i32 g_dump_term_len = 0;
u8[1024] g_term_raw;     // --term-raw <file>: every byte the child sent, from the first key after the pane opened
i32 g_term_raw_len = 0;
bool g_term_raw_on = false;
i64 g_dump_wait_us = 0;  // --dump-wait <ms>: the most a slow child gets before the dump; 0 = the default
u8[PATH_MAX] g_arg_path; // the file named on the command line, opened at start
i32 g_arg_path_len = 0;

// The injection being delivered, -1 outside the loop. A run that
// restarts in the middle hands the dump flags and the injections after
// the restarting one to the new process, so one command can type into
// the terminal the new process came up with and dump what it answered.
i32 g_inject_at = -1;
// what a restart's argv holds: the run's own arguments, the two dump
// flags with their values, and a flag and value per forwarded injection
const i32 RESTART_ARGV_MAX = 64 + 4 + 2 * INJECT_MAX;
private u8[16] g_dump_wait_text;
private i32 g_dump_wait_text_len = 0;
private u8[INJECT_MAX * 24] g_restart_text;   // the forwarded injections' spellings
private i32 g_restart_text_len = 0;

private const i32 HL_PATH_MAX = 1024;   // the flags' file arguments
private const i32 DUMP_TERM_CAP = 65536;
private const i64 DUMP_TERM_STEP_US = 20000;       // between pumps
private const i64 DUMP_TERM_SETTLED_US = 1000000;  // unchanged this long = done
private const i64 DUMP_TERM_WAIT_US = 5000000;     // the most a slow shell gets
private u8[DUMP_TERM_CAP] g_dump_buf;
private u8[DUMP_TERM_CAP] g_dump_prev;

// Whether this launch leaves the shell: a plain launch does, as a
// windowed program on Windows does without asking. A headless run
// stays in the foreground, because the script that started it waits
// for its exit code and its output; so does a restart, which is
// already in the session the launch it came from chose; and so does
// `--no-detach`, which the detached process is started with. A scan
// of the raw arguments, so the POSIX drivers can decide before hl_arg
// changes the directory.
bool hl_detach_launch() {
    for i32 i = 1; i < get_argc(); i++ {
        str arg = str_from_cstr(get_arg(i));
        if str_equal(arg, "--no-detach") || str_equal(arg, "--smoke")
            || str_equal(arg, "--time") || str_equal(arg, "--lsp-trace")
            || str_equal(arg, "--play") || str_equal(arg, "--shot")
            || str_equal(arg, "--handover") || str_equal(arg, "--dump-term")
            || str_equal(arg, "--term-raw") || str_equal(arg, "--key")
            || str_equal(arg, "--char") || str_equal(arg, "--wait") {
            return false;
        }
    }
    return true;
}

// a decimal argument, or `dflt` when it is not one
i32 hl_num(str d, i32 dflt) {
    if d.len == 0 { return dflt; }
    i32 v = 0;
    for i32 i = 0; i < d.len; i++ {
        if d.data[i] < '0' || d.data[i] > '9' { return dflt; }
        v = v * 10 + cast(i32, d.data[i] - '0');
    }
    return v;
}

// a path argument into a flag's buffer; one too long is dropped
void hl_path(str p, u8* dst, i32* len) {
    if p.len >= HL_PATH_MAX { return; }
    memcpy(dst, p.data, p.len);
    *len = p.len;
}

private void hl_push(i32 kind, i32 a, i32 b) {
    if g_nkeys >= INJECT_MAX { return; }
    g_keys[g_nkeys * 3] = kind;
    g_keys[g_nkeys * 3 + 1] = a;
    g_keys[g_nkeys * 3 + 2] = b;
    g_nkeys++;
}

// The argument at *a, one of the shared flags, *a moved past its value.
// Anything else is a path: a directory is the project to open, a file
// is opened in whichever project is current by then, so a folder then
// a file inside it works in that order.
void hl_arg(i32* a) {
    str arg = str_from_cstr(get_arg(*a));
    bool more = *a + 1 < get_argc();
    if str_equal(arg, "--smoke") {
        g_smoke = true;
    } else if str_equal(arg, "--no-detach") {
        // acted on by the driver before this (hl_detach_launch)
    } else if str_equal(arg, "--time") {
        g_time = true;
    } else if str_equal(arg, "--newwin") {
        g_newwin = true;
    } else if str_equal(arg, "--lsp-trace") {
        lsp_trace = true;
    } else if str_equal(arg, "--play") && more {
        *a = *a + 1;
        hl_path(str_from_cstr(get_arg(*a)), &g_play[0], &g_play_len);
    } else if str_equal(arg, "--play-ms") && more {
        *a = *a + 1;
        i32 v = hl_num(str_from_cstr(get_arg(*a)), 0);
        if v > 0 { g_play_ms = v; }
    } else if str_equal(arg, "--theme") && more {
        *a = *a + 1;
        str t = str_from_cstr(get_arg(*a));
        if t.len < 64 {
            memcpy(&g_theme_arg[0], t.data, t.len);
            g_theme_arg_len = t.len;
        }
    } else if str_equal(arg, "--shot") && more {
        *a = *a + 1;
        hl_path(str_from_cstr(get_arg(*a)), &g_shot[0], &g_shot_len);
    } else if str_equal(arg, "--handover") && more {
        // without it a restart comes up as a plain launch, and the file
        // it names is opened as a text buffer instead
        *a = *a + 1;
        hl_path(str_from_cstr(get_arg(*a)), &g_handover[0], &g_handover_len);
    } else if str_equal(arg, "--dump-term") && more {
        *a = *a + 1;
        hl_path(str_from_cstr(get_arg(*a)), &g_dump_term[0], &g_dump_term_len);
    } else if str_equal(arg, "--term-raw") && more {
        *a = *a + 1;
        hl_path(str_from_cstr(get_arg(*a)), &g_term_raw[0], &g_term_raw_len);
    } else if str_equal(arg, "--dump-wait") && more {
        *a = *a + 1;
        g_dump_wait_us = cast(i64, hl_num(str_from_cstr(get_arg(*a)), 0)) * 1000;
    } else if str_equal(arg, "--wait") && more {
        // milliseconds between injections, pumping the app meanwhile: a
        // child that takes a moment to draw has to be given it before
        // the next key lands on the drawn screen
        *a = *a + 1;
        hl_push(2, hl_num(str_from_cstr(get_arg(*a)), 0), 0);
    } else if str_equal(arg, "--char") && more {
        // a codepoint, repeatable and in order with --key: typed input
        // a key code cannot carry, such as Enter (13)
        *a = *a + 1;
        hl_push(1, hl_num(str_from_cstr(get_arg(*a)), 0), 0);
    } else if str_equal(arg, "--key") && more {
        // "<key>:<mods>", repeatable; injected through app_key after
        // init, so --shot can capture any UI state headless
        *a = *a + 1;
        str kv = str_from_cstr(get_arg(*a));
        i32 colon = 0;
        while colon < kv.len && kv.data[colon] != ':' { colon++; }
        i32 km = 0;
        if colon < kv.len { km = hl_num(str_from(kv.data + colon + 1, kv.len - colon - 1), 0); }
        hl_push(0, hl_num(str_from(kv.data, colon), 0), km);
    } else if arg.len < PATH_MAX {
        if path_is_dir(arg) {
            ignore plat_chdir(arg);
            app_folder_arg();
        } else {
            memcpy(&g_arg_path[0], arg.data, arg.len);
            g_arg_path_len = arg.len;
        }
    }
}

// The injections in order, each settled before the next, so a view a
// worker finishes (the changes list) is there before the key that
// lands on it. A wait runs real wakes meanwhile: the terminals' pump,
// the server, a restart request. The raw capture starts with the first
// terminal on screen, so what a typed command makes the child send is
// all there.
void hl_inject() {
    if g_theme_arg_len > 0 { settings_use_theme(str_from(&g_theme_arg[0], g_theme_arg_len)); }
    for i32 k = 0; k < g_nkeys; k++ {
        g_inject_at = k;
        if g_keys[k * 3] == 2 {
            i32 left = g_keys[k * 3 + 1];
            while left > 0 {
                plat_sleep_ms(cast(u32, DUMP_TERM_STEP_US / 1000));
                left -= cast(i32, DUMP_TERM_STEP_US / 1000);
                app_wake();
            }
        } else if g_keys[k * 3] == 0 {
            app_key(g_keys[k * 3 + 1], g_keys[k * 3 + 2]);
        } else {
            app_char(cast(u32, g_keys[k * 3 + 1]));
        }
        app_settle();
        if g_term_raw_len > 0 && !g_term_raw_on && ed_term_shown() >= 0 {
            term_tap(ed_term_shown(), true);
            g_term_raw_on = true;
        }
    }
}

// The terminal pane's screen as text into the --dump-term file, once
// the shell has had its say: the dump is taken when it stops changing,
// or after the wait runs out. The raw capture goes to its file too.
void hl_dump_term() {
    i64 waited = 0;
    i64 same = 0;
    i32 n = 0;
    i32 last_n = -1;
    i64 wait_max = DUMP_TERM_WAIT_US;
    if g_dump_wait_us > 0 { wait_max = g_dump_wait_us; }
    while waited < wait_max {
        plat_sleep_ms(cast(u32, DUMP_TERM_STEP_US / 1000));
        waited += DUMP_TERM_STEP_US;
        ignore term_pump();
        n = ed_term_dump(&g_dump_buf[0], DUMP_TERM_CAP);
        bool unchanged = n > 0 && n == last_n;
        for i32 i = 0; unchanged && i < n; i++ {
            if g_dump_buf[i] != g_dump_prev[i] { unchanged = false; }
        }
        if unchanged {
            same += DUMP_TERM_STEP_US;
            if same >= DUMP_TERM_SETTLED_US { break; }
        } else {
            same = 0;
        }
        memcpy(&g_dump_prev[0], &g_dump_buf[0], cast(i64, n));
        last_n = n;
    }
    ignore file_write_str(str_from(&g_dump_term[0], g_dump_term_len), str_from(&g_dump_buf[0], n));
    if g_term_raw_on {
        i64 rn = 0;
        u8* raw = term_tap_take(ed_term_shown(), &rn);
        if raw != null {
            ignore file_write_str(str_from(&g_term_raw[0], g_term_raw_len), str_from(raw, cast(i32, rn)));
            free(raw);
        }
    }
}

// --- the restart's argv ----------------------------------------------
// A headless run that restarts hands its dump flags and the injections
// it has not delivered to the process it starts, so a run can type into
// the handed-over terminal from the new process and prove the child is
// the same one.

// the first injection to forward: the one after the restarting one,
// and past the chord's own character, which the chord would have eaten
private i32 hl_restart_first() {
    i32 first = g_inject_at + 1;
    // only a key restarts through a chord; a wait that read the request
    // file has no character of its own to skip
    if g_keys[g_inject_at * 3] == 0 && first < g_nkeys && g_keys[first * 3] == 1 { first++; }
    return first;
}

private i32 hl_restart_left() {
    if g_inject_at < 0 || hl_restart_first() >= g_nkeys { return 0; }
    return g_nkeys - hl_restart_first();
}

i32 hl_restart_arg_count() {
    i32 n = 0;
    if g_dump_term_len > 0 { n += 2; }
    if g_dump_wait_us > 0 { n += 2; }
    n += 2 * hl_restart_left();
    return n;
}

// one injection as its flag and spelling: `--key k:m`, `--char c` or `--wait ms`
private str hl_restart_inject(i32 j, bool flag) {
    i32 k = hl_restart_first() + j;
    if flag {
        if g_keys[k * 3] == 0 { return "--key"; }
        if g_keys[k * 3] == 2 { return "--wait"; }
        return "--char";
    }
    u8* b = &g_restart_text[g_restart_text_len];
    i32 o = fmt_i32(b, g_keys[k * 3 + 1]);
    if g_keys[k * 3] == 0 {
        b[o] = ':';
        o++;
        o += fmt_i32(b + o, g_keys[k * 3 + 2]);
    }
    g_restart_text_len += o;
    return str_from(b, o);
}

str hl_restart_arg(i32 i) {
    i32 k = 0;
    if g_dump_term_len > 0 {
        if i == k { return "--dump-term"; }
        if i == k + 1 { return str_from(&g_dump_term[0], g_dump_term_len); }
        k += 2;
    }
    if g_dump_wait_us > 0 {
        if i == k { return "--dump-wait"; }
        if i == k + 1 {
            g_dump_wait_text_len = fmt_i32(&g_dump_wait_text[0], cast(i32, g_dump_wait_us / 1000));
            return str_from(&g_dump_wait_text[0], g_dump_wait_text_len);
        }
        k += 2;
    }
    i32 j = (i - k) / 2;
    if j >= 0 && j < hl_restart_left() { return hl_restart_inject(j, (i - k) % 2 == 0); }
    return "";
}
