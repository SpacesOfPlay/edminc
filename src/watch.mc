// watch.mc - the file watcher's portable side. One thread waits in
// plat_watch_read on the project folder and queues the records it
// returns. The UI thread drains the queue on wake, drops the paths no
// view depends on, and after a short delay refreshes the rest: the git
// status, the baselines when HEAD moved, the tree, and the open buffers
// against their files.
//
// A record is one kind byte, a path relative to the folder with '/'
// separators, and '\n'. A read of zero bytes means the platform lost
// changes; everything is then refreshed.

import thread;

const u8 WATCH_CHANGED = 'c';   // a file's content changed
const u8 WATCH_MOVED = 'm';     // an entry was created, deleted or renamed

const i32 WATCH_TIMER = 10;     // 7 is the player's, 8 the terminal probe's, 9 search's
// The refresh runs this long after the first record of a burst, so a
// checkout or a build is one refresh, not one per file.
const i32 WATCH_MS = 200;

private const i64 WATCH_READ_CAP = 131072;
// A queue this long counts as lost: a refresh of everything is cheaper
// than reading the records one by one.
private const i64 WATCH_Q_MAX = 1048576;

private i32 wt_h = -1;
private Mutex wt_mx;
private bool wt_mx_ready = false;
private u8* wt_q = null;
private i64 wt_q_len = 0;
private i64 wt_q_cap = 0;
private bool wt_q_lost = false;
when !os(wasm) {
    private Thread wt_thr;
}
private bool wt_thr_up = false;

// what the next refresh does, gathered from the records since the last
private bool wt_timer_on = false;
private bool wt_all = false;
private bool wt_head = false;     // HEAD or a ref moved: the baselines
private bool wt_status = false;   // the git status
private bool wt_tree = false;     // entries came or went
private bool wt_bufs = false;     // an open buffer's file may differ

// test counters: refreshes run, and those that refetched baselines
i32 watch_refreshes = 0;
i32 watch_head_refreshes = 0;

bool watch_pending() {
    return wt_timer_on;
}

when !os(wasm) {

private void watch_reader(void* arg) {
    u8* buf = alloc<u8>(WATCH_READ_CAP);
    while true {
        i64 n = plat_watch_read(wt_h, buf, WATCH_READ_CAP);
        if n < 0 { break; }
        mutex_lock(&wt_mx);
        if n == 0 || wt_q_len + n > WATCH_Q_MAX {
            wt_q_lost = true;
        } else {
            if wt_q_len + n > wt_q_cap {
                i64 ncap = wt_q_cap * 2 + n + 4096;
                u8* nq = alloc<u8>(ncap);
                if wt_q != null {
                    memcpy(nq, wt_q, wt_q_len);
                    free(wt_q);
                }
                wt_q = nq;
                wt_q_cap = ncap;
            }
            memcpy(wt_q + wt_q_len, buf, n);
            wt_q_len += n;
        }
        mutex_unlock(&wt_mx);
        plat_wake();
    }
    free(buf);
}

}

// Watch the working directory. Does nothing where the platform has no
// watcher; the save check in ed.mc still catches a file changed on disk.
void watch_start() {
    if wt_h >= 0 { return; }
    when !os(wasm) {
        i32 h = plat_watch_open(".");
        if h < 0 { return; }
        if !wt_mx_ready {
            mutex_init(&wt_mx);
            wt_mx_ready = true;
        }
        wt_h = h;
        thread_create(&wt_thr, watch_reader, null);
        wt_thr_up = true;
    }
}

// End the watch: the platform ends the blocked read, the thread exits,
// and the handle goes. What was queued is dropped.
void watch_stop() {
    if wt_timer_on {
        plat_kill_timer(WATCH_TIMER);
        wt_timer_on = false;
    }
    wt_all = false;
    wt_head = false;
    wt_status = false;
    wt_tree = false;
    wt_bufs = false;
    if wt_h < 0 { return; }
    when !os(wasm) {
        plat_watch_close(wt_h);
        if wt_thr_up {
            thread_join(&wt_thr);
            wt_thr_up = false;
        }
        plat_watch_free(wt_h);
    }
    wt_h = -1;
    if wt_q != null { free(wt_q); }
    wt_q = null;
    wt_q_len = 0;
    wt_q_cap = 0;
    wt_q_lost = false;
}

// the records the thread queued, on wake
void watch_pump() {
    if wt_h < 0 { return; }
    when !os(wasm) {
        mutex_lock(&wt_mx);
        u8* q = wt_q;
        i64 n = wt_q_len;
        bool lost = wt_q_lost;
        wt_q = null;
        wt_q_len = 0;
        wt_q_cap = 0;
        wt_q_lost = false;
        mutex_unlock(&wt_mx);
        if q != null || lost { watch_feed(q, n, lost); }
        if q != null { free(q); }
    }
}

private bool wt_starts(str s, str prefix) {
    return s.len >= prefix.len && str_equal(str_from(s.data, prefix.len), prefix);
}

// A path in .git that the views depend on. HEAD, a ref and packed-refs
// move the baselines; the index moves only the status. Objects, logs
// and lock files are git's own business.
private void wt_git_path(str rest) {
    if str_equal(rest, "HEAD") || str_equal(rest, "packed-refs") || wt_starts(rest, "refs/") {
        wt_head = true;
        wt_status = true;
        return;
    }
    if str_equal(rest, "index") { wt_status = true; }
    // the repository's own ignore list: the rules are read again
    if str_equal(rest, "info/exclude") {
        ign_reset();
        wt_tree = true;
        wt_status = true;
    }
}

// an excluded folder anywhere on the path, or the entry itself
private bool wt_excluded(str path) {
    for i32 i = 0; i < path.len; i++ {
        if path.data[i] == '/' && ign_excluded(str_from(path.data, i)) { return true; }
    }
    return ign_excluded(path);
}

// the last part of the path
private str wt_base(str path) {
    i32 b = path.len;
    while b > 0 && path.data[b - 1] != '/' { b--; }
    return str_from(path.data + b, path.len - b);
}

private void wt_record(u8 kind, str path) {
    if path.len == 0 { return; }
    if str_equal(path, ".git") { return; }
    if wt_starts(path, ".git/") {
        wt_git_path(str_from(path.data + 5, path.len - 5));
        return;
    }
    if str_equal(path, ".edminc") || wt_starts(path, ".edminc/") { return; }
    if wt_excluded(path) { return; }
    // any .gitignore: the rules are read again, and what they cover shows
    if str_equal(wt_base(path), ".gitignore") {
        ign_reset();
        wt_tree = true;
    }
    // A gitignored entry touches neither git's status nor a buffer worth
    // a reload check; the tree shows it only when it shows ignored
    // entries, and a build's output churning in there would otherwise
    // keep the refresh busy. The record does not say whether the path
    // is a folder; a folder-only rule still covers what is inside it.
    if ign_git(path, false) {
        if kind != WATCH_CHANGED && !ign_tree_hides_now() { wt_tree = true; }
        return;
    }
    wt_status = true;
    wt_bufs = true;
    if kind != WATCH_CHANGED { wt_tree = true; }
}

// Records in, the refresh armed when any of them matters. Public so the
// harness can hand it records without a platform watcher.
void watch_feed(u8* p, i64 n, bool lost) {
    if lost { wt_all = true; }
    i64 i = 0;
    while i < n {
        i64 e = i;
        while e < n && p[e] != '\n' { e++; }
        if e > i { wt_record(p[i], str_from(p + i + 1, cast(i32, e - i - 1))); }
        i = e + 1;
    }
    if (wt_all || wt_head || wt_status || wt_tree || wt_bufs) && !wt_timer_on {
        plat_set_timer(WATCH_TIMER, WATCH_MS);
        wt_timer_on = true;
    }
}

// A refresh that is due runs now: the headless paths settle before a
// dump, and a timer never fires there.
void watch_settle() {
    if wt_timer_on { watch_timer(); }
}

// The delay has passed: refresh what the records touched.
void watch_timer() {
    plat_kill_timer(WATCH_TIMER);
    wt_timer_on = false;
    bool all = wt_all;
    bool head = wt_head || all;
    bool status = wt_status || all;
    bool tree = wt_tree || all;
    bool bufs = wt_bufs || all;
    wt_all = false;
    wt_head = false;
    wt_status = false;
    wt_tree = false;
    wt_bufs = false;
    watch_refreshes++;
    if status { git_status_touch(); }
    if head {
        watch_head_refreshes++;
        ed_git_refetch_all();
        hist_head_moved();
    }
    if tree && tree_on { tree_build(); }
    if bufs { ed_disk_check_all(); }
    plat_damage();
}
