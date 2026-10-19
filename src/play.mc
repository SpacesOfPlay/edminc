// play.mc - `edmc <file> --play <script> [--play-ms N]`: a recorded
// fuzz run in the live window. The script is ed_fuzz's --dump-script
// output (evscript.mc); each timer tick plays one of its steps through
// the app_* entries the driver would call, so a run can be watched and
// recorded. Not a faithful replay: the window keeps its size, dpi and
// focus, the real server answers instead of the mock, and the fuzzer's
// settle waits are skipped (nothing on the UI thread waits for a
// worker), so clicks land where the live layout puts them.

import evscript;

// The driver's own id, which must be none of the core's: a driver
// routes every timer through play_timer first, so an id shared with
// the core is answered here and killed instead of reaching app_timer.
const i32 PLAY_TIMER = 7;
const i32 PLAY_MS_DEFAULT = 20;

private u8* play_buf = null;
private i64 play_len = 0;
private i64 play_at = 0;
private i32 play_steps = 0;
private bool play_on = false;

// a script already in memory; the caller keeps ownership
void play_load(u8* buf, i64 n) {
    play_buf = buf;
    play_len = n;
    play_at = 0;
    play_steps = 0;
    play_on = n > 0;
}

bool play_open(str path) {
    FileData fd = file_read(path);
    if fd.data == null {
        print("cannot read the script {}\n", path);
        return false;
    }
    play_load(fd.data, cast(i64, fd.len));
    return true;
}

bool play_active() {
    return play_on;
}

// the size the run was recorded at: a script begins with the run's
// resize, whose height is the editor's area under the caption. False
// when the script does not start with one.
bool play_start_size(i32* w, i32* h) {
    if !play_on || play_len < 9 || play_buf[0] != EV_RESIZE { return false; }
    *w = *cast(i32*, play_buf + 1);
    *h = *cast(i32*, play_buf + 5);
    return *w > 0 && *h > 0;
}

private i32 play_get32() {
    i32 v = *cast(i32*, play_buf + play_at);
    play_at += 4;
    return v;
}

private f32 play_getf() {
    i32 b = play_get32();
    return *cast(f32*, &b);
}

// bytes after the kind byte, or -1 for an unknown kind
private i64 play_body_size(u8 k) {
    if k == EV_CHAR || k == EV_SCALE || k == EV_FOCUS || k == EV_TIMER || k == EV_SEED { return 4; }
    if k == EV_KEY || k == EV_MOVE || k == EV_RESIZE { return 8; }
    if k == EV_MOUSE { return 20; }
    if k == EV_SCROLL || k == EV_NOTCH { return 16; }
    if k == EV_HOVER { return 12; }
    if k == EV_WAKE || k == EV_SETTLE || k == EV_STEP || k == EV_INIT || k == EV_STATUS { return 0; }
    if k == EV_TERM { return 28; }
    if k == EV_FEED || k == EV_WATCH { return 4; }
    return -1;
}

// play events up to the next step mark; false once the script is done
bool play_step() {
    if !play_on { return false; }
    while play_at < play_len {
        u8 k = play_buf[play_at];
        i64 need = play_body_size(k);
        if need < 0 || play_at + 1 + need > play_len {
            print("play: script is corrupt at byte {}\n", play_at);
            play_on = false;
            return false;
        }
        play_at++;
        if k == EV_CHAR {
            app_char(cast(u32, play_get32()));
        } else if k == EV_KEY {
            i32 key = play_get32();
            app_key(key, play_get32());
        } else if k == EV_MOUSE {
            i32 x = play_get32();
            i32 y = play_get32();
            i32 btn = play_get32();
            bool down = play_get32() != 0;
            app_mouse(x, y, btn, down, play_get32());
        } else if k == EV_MOVE {
            i32 x = play_get32();
            app_mouse_move(x, play_get32());
        } else if k == EV_SCROLL {
            f32 dx = play_getf();
            f32 dy = play_getf();
            i32 x = play_get32();
            app_scroll(dx, dy, x, play_get32());
        } else if k == EV_NOTCH {
            f32 dx = play_getf();
            f32 dy = play_getf();
            i32 x = play_get32();
            app_scroll_notch(dx, dy, x, play_get32());
        } else if k == EV_HOVER {
            i32 x = play_get32();
            i32 y = play_get32();
            app_hover(x, y, play_get32());
        } else if k == EV_TIMER {
            app_timer(play_get32());
        } else if k == EV_WAKE {
            app_wake();
        } else if k == EV_FEED {
            // the mock server's bytes: the live server answers instead
            i64 n = cast(i64, play_get32());
            if n < 0 || play_at + n > play_len {
                print("play: script is corrupt at byte {}\n", play_at);
                play_on = false;
                return false;
            }
            play_at += n;
        } else if k == EV_WATCH {
            // the recorded run's watcher records: the live window's own
            // watcher reports its folder instead
            i64 n = cast(i64, play_get32());
            if n < 0 { n = 0; }
            if play_at + n > play_len {
                print("play: script is corrupt at byte {}\n", play_at);
                play_on = false;
                return false;
            }
            play_at += n;
        } else if k == EV_TERM {
            // the fuzzer's detached terminal, which the window has no
            // counterpart for: its bytes are skipped
            play_at += 24;
            i64 n = cast(i64, play_get32());
            if n < 0 || play_at + n > play_len {
                print("play: script is corrupt at byte {}\n", play_at);
                play_on = false;
                return false;
            }
            play_at += n;
        } else if k == EV_STEP {
            play_steps++;
            return true;
        } else {
            // resize, scale, focus, settle: the window's own stand; the
            // opening resize was taken as the window's size at start
            play_at += need;
        }
    }
    play_on = false;
    print("play: done, {} steps\n", play_steps);
    return false;
}

// the drivers route their timer through here first: true when it was
// the play timer, which then played a step or, at the end, stopped
bool play_timer(i32 id) {
    if id != PLAY_TIMER { return false; }
    if !play_step() { plat_kill_timer(PLAY_TIMER); }
    plat_damage();
    return true;
}
