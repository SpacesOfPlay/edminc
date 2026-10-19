// hist.mc - the history graph: HEAD's commits in the changes view's
// lower panel, with the lanes that join each commit to its parents. A
// commit opens to the files it changed, and a file opens the diff of
// that file in that commit (ed_rev_diff). git runs on a worker, one job
// at a time; the UI thread takes each result at a wake (hist_pump).
// tree.mc places the panel and routes the mouse and the keys to it.

import file;

const i32 HIST_PAGE = 200;               // commits one log job asks for
private const i32 HIST_LANES = 24;       // lanes drawn; a graph wider than this shares the last
private const i32 HIST_COLORS = 5;
private const i32 HIST_FILES_MAX = 4096;
private const i32 HIST_SHA = 40;
private const i32 HIST_SHORT = 7;
private const i32 HIST_NAME_MAX = 300;
private const i32 HIST_MORE_ROWS = 40;   // rows from the end at which the next page is asked for
private const i32 HIST_BIN_PROBE = 8000; // bytes looked at for a NUL, as git does
private const u8 HIST_NO_LANE = 0xFF;

// where a segment of a row's graph starts or ends: the row's top, the
// dot's height, the row's bottom
private const u8 HIST_TOP = 0;
private const u8 HIST_MID = 1;
private const u8 HIST_BOT = 2;

private const i32 HIST_SCROLL_W = 6;    // the scrollbar, as the tree's
private const i32 HIST_SCROLL_PAD = 4;
private const i32 HIST_SCROLL_MIN = 24;

struct HistCommit {
    u8[HIST_SHA] sha;
    u8[HIST_SHA] par;      // the first parent, which a file's diff is against
    i32 npar;              // 0 for a root commit
    i64 time;
    i32 subj_off;
    i32 subj_len;
    i32 auth_off;
    i32 auth_len;
    i32 refs_off;          // git's decoration: "HEAD -> main, origin/main, tag: v1"
    i32 refs_len;
    u8 col;                // the lane of its dot
    u8 color;              // the dot's color
    i32 seg_off;
    i32 seg_n;
    u8[HIST_LANES] outc;   // each lane's color below the row, HIST_NO_LANE where none runs
}

// one line of a row's graph: lane x0 at height p0 to lane x1 at p1
struct HistSeg {
    u8 x0;
    u8 p0;
    u8 x1;
    u8 p1;
    u8 color;
}

// a file the open commit changed: its status letter, its path, and the
// path it had before a rename
struct HistFile {
    u8 st;
    i32 path_off;
    i32 path_len;
    i32 old_off;
    i32 old_len;
}

private HistCommit* hist_c = null;
private i32 hist_n = 0;
private i32 hist_cap = 0;
private HistSeg* hist_seg = null;
private i32 hist_nseg = 0;
private i32 hist_segcap = 0;
private u8* hist_txt = null;        // the commits' strings
private i32 hist_txtlen = 0;
private i32 hist_txtcap = 0;
private i32 hist_maxlane = 0;       // the widest lane used, for where the text starts

// the lanes as they stand below the last commit laid out
private u8[HIST_LANES * HIST_SHA] hist_lane_sha;
private bool[HIST_LANES] hist_lane_used;
private u8[HIST_LANES] hist_lane_color;
private i32 hist_color_next = 0;

// the commit whose files are shown under it, and the files
private i32 hist_open = -1;
private HistFile[HIST_FILES_MAX] hist_files;
private i32 hist_nfiles = 0;
private bool hist_files_wait = false;
private u8* hist_ftxt = null;
private i32 hist_ftxtlen = 0;
private i32 hist_ftxtcap = 0;

// the panel
bool hist_focus = false;            // the keys go to the graph, not the changes above it
bool hist_folded = false;           // the panel is a heading only
private i32 hist_sel = -1;
private i32 hist_scroll = 0;        // pixels
private f32 hist_scroll_accum = 0.0f;
private i32 hist_view_h = 0;        // the rows' height on screen, from the last render
private bool hist_more = true;      // a page came back full: there may be more
private bool hist_loading = false;  // a log job is out
private bool hist_loaded = false;   // the first page has been asked for since the last reset
private bool hist_failed = false;   // git gave no log: no repository, or no commit yet
private i32 hist_gen = 0;           // a reset drops what jobs from before it bring back

// --- strings --------------------------------------------------------------

private i32 hist_put(u8** arena, i32* len, i32* cap, u8* p, i32 n) {
    if *len + n > *cap {
        i32 nc = *cap * 2 + n + 4096;
        u8* na = alloc<u8>(nc);
        if *arena != null {
            memcpy(na, *arena, *len);
            free(*arena);
        }
        *arena = na;
        *cap = nc;
    }
    i32 off = *len;
    if n > 0 { memcpy(*arena + off, p, n); }
    *len = *len + n;
    return off;
}

private str hist_str(i32 off, i32 n) {
    return str_from(hist_txt + off, n);
}

private str hist_fstr(i32 off, i32 n) {
    return str_from(hist_ftxt + off, n);
}

// --- the lanes ------------------------------------------------------------

private bool hist_sha_eq(u8* a, u8* b) {
    for i32 k = 0; k < HIST_SHA; k++ {
        if a[k] != b[k] { return false; }
    }
    return true;
}

private u8* hist_lane(i32 i) {
    return &hist_lane_sha[i * HIST_SHA];
}

private i32 hist_lane_of(u8* sha) {
    for i32 i = 0; i < HIST_LANES; i++ {
        if hist_lane_used[i] && hist_sha_eq(hist_lane(i), sha) { return i; }
    }
    return -1;
}

private i32 hist_lane_free() {
    for i32 i = 0; i < HIST_LANES; i++ {
        if !hist_lane_used[i] { return i; }
    }
    return -1;
}

private u8 hist_color_new() {
    u8 c = cast(u8, hist_color_next % HIST_COLORS);
    hist_color_next++;
    return c;
}

private void hist_seg_add(i32 x0, u8 p0, i32 x1, u8 p1, u8 color) {
    if hist_nseg == hist_segcap {
        i32 nc = hist_segcap * 2 + 1024;
        HistSeg* ns = alloc<HistSeg>(nc);
        if hist_seg != null {
            memcpy(ns, hist_seg, hist_nseg * sizeof(HistSeg));
            free(hist_seg);
        }
        hist_seg = ns;
        hist_segcap = nc;
    }
    hist_seg[hist_nseg] = HistSeg{ cast(u8, x0), p0, cast(u8, x1), p1, color };
    hist_nseg++;
    if x0 > hist_maxlane { hist_maxlane = x0; }
    if x1 > hist_maxlane { hist_maxlane = x1; }
}

// Commit c's place in the lanes, in log order. A lane holds the commit
// it waits for. The lanes waiting for c join its dot from above, and the
// rest pass by. Below the dot, its lane goes on to the first parent, and
// each further parent takes the lane already waiting for it or a free
// one. `pars` holds npar parents, HIST_SHA bytes each.
private void hist_lay(HistCommit* c, u8* pars, i32 npar) {
    i32 col = hist_lane_of(&c.sha[0]);
    u8 color = 0;
    if col < 0 {
        // a tip: nothing below waits for it yet
        col = hist_lane_free();
        if col < 0 { col = HIST_LANES - 1; }
        color = hist_color_new();
    } else {
        color = hist_lane_color[col];
    }
    c.col = cast(u8, col);
    c.color = color;
    c.seg_off = hist_nseg;
    for i32 i = 0; i < HIST_LANES; i++ {
        if !hist_lane_used[i] { continue; }
        if hist_sha_eq(hist_lane(i), &c.sha[0]) {
            hist_seg_add(i, HIST_TOP, col, HIST_MID, hist_lane_color[i]);
            hist_lane_used[i] = false;
        } else {
            hist_seg_add(i, HIST_TOP, i, HIST_BOT, hist_lane_color[i]);
        }
    }
    if col > hist_maxlane { hist_maxlane = col; }
    if npar > 0 {
        hist_lane_used[col] = true;
        memcpy(hist_lane(col), pars, HIST_SHA);
        hist_lane_color[col] = color;
        hist_seg_add(col, HIST_MID, col, HIST_BOT, color);
    }
    for i32 k = 1; k < npar; k++ {
        u8* p = pars + k * HIST_SHA;
        i32 j = hist_lane_of(p);
        if j < 0 {
            j = hist_lane_free();
            if j < 0 { continue; }
            hist_lane_used[j] = true;
            memcpy(hist_lane(j), p, HIST_SHA);
            hist_lane_color[j] = hist_color_new();
        }
        hist_seg_add(col, HIST_MID, j, HIST_BOT, hist_lane_color[j]);
    }
    for i32 i = 0; i < HIST_LANES; i++ {
        c.outc[i] = HIST_NO_LANE;
        if hist_lane_used[i] { c.outc[i] = hist_lane_color[i]; }
    }
    c.seg_n = hist_nseg - c.seg_off;
}

// --- parsing --------------------------------------------------------------

private bool hist_is_hex(u8 c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
}

// the next field of a record, up to `sep` or the record's end
private str hist_field(u8* p, i32 n, i32* at, u8 sep) {
    i32 s = *at;
    i32 e = s;
    while e < n && p[e] != sep { e++; }
    *at = e + 1;
    return str_from(p + s, e - s);
}

// One record of the log: hash, parents, author, time, decoration and
// subject, separated by 0x1F. False for one that does not parse.
private bool hist_add_record(u8* p, i32 n) {
    i32 at = 0;
    str sha = hist_field(p, n, &at, 0x1F);
    str pars = hist_field(p, n, &at, 0x1F);
    str auth = hist_field(p, n, &at, 0x1F);
    str tm = hist_field(p, n, &at, 0x1F);
    str refs = hist_field(p, n, &at, 0x1F);
    str subj = hist_field(p, n, &at, 0x1F);
    if sha.len != HIST_SHA { return false; }
    for i32 k = 0; k < HIST_SHA; k++ {
        if !hist_is_hex(sha.data[k]) { return false; }
    }
    if hist_n == hist_cap {
        i32 nc = hist_cap * 2 + HIST_PAGE;
        HistCommit* na = alloc<HistCommit>(nc);
        if hist_c != null {
            memcpy(na, hist_c, hist_n * sizeof(HistCommit));
            free(hist_c);
        }
        hist_c = na;
        hist_cap = nc;
    }
    HistCommit* c = &hist_c[hist_n];
    HistCommit z;
    *c = z;
    memcpy(&c.sha[0], sha.data, HIST_SHA);
    // the parents, space separated
    noinit u8[4 * HIST_SHA] pb;
    i32 np = 0;
    i32 total = 0;
    i32 i = 0;
    while i < pars.len {
        while i < pars.len && pars.data[i] == ' ' { i++; }
        i32 s = i;
        while i < pars.len && pars.data[i] != ' ' { i++; }
        if i - s != HIST_SHA { continue; }
        total++;
        if np < 4 {
            memcpy(&pb[np * HIST_SHA], pars.data + s, HIST_SHA);
            np++;
        }
    }
    c.npar = total;
    if np > 0 { memcpy(&c.par[0], &pb[0], HIST_SHA); }
    i64 t = 0;
    for i32 k = 0; k < tm.len; k++ {
        if tm.data[k] >= '0' && tm.data[k] <= '9' { t = t * 10 + cast(i64, tm.data[k] - '0'); }
    }
    c.time = t;
    i32 sl = subj.len;
    // the record's own line break, when the format ended it with one
    while sl > 0 && (subj.data[sl - 1] == '\n' || subj.data[sl - 1] == '\r') { sl--; }
    c.subj_off = hist_put(&hist_txt, &hist_txtlen, &hist_txtcap, subj.data, sl);
    c.subj_len = sl;
    c.auth_off = hist_put(&hist_txt, &hist_txtlen, &hist_txtcap, auth.data, auth.len);
    c.auth_len = auth.len;
    c.refs_off = hist_put(&hist_txt, &hist_txtlen, &hist_txtcap, refs.data, refs.len);
    c.refs_len = refs.len;
    hist_lay(c, &pb[0], np);
    hist_n++;
    return true;
}

// a page of the log: records end with 0x1E, each after a line break
private i32 hist_add_log(u8* p, i64 n) {
    i32 added = 0;
    i64 s = 0;
    for i64 i = 0; i < n; i++ {
        if p[i] != 0x1E { continue; }
        i64 b = s;
        while b < i && (p[b] == '\n' || p[b] == '\r') { b++; }
        if i > b && hist_add_record(p + b, cast(i32, i - b)) { added++; }
        s = i + 1;
    }
    return added;
}

// diff-tree's -z output: a status, then one path, or two for a rename
// or a copy
private void hist_add_files(u8* p, i64 n) {
    hist_nfiles = 0;
    hist_ftxtlen = 0;
    i64 i = 0;
    while i < n && hist_nfiles < HIST_FILES_MAX {
        i64 s = i;
        while i < n && p[i] != 0 { i++; }
        if i >= n || i == s { break; }
        u8 st = p[s];
        i++;
        i64 a = i;
        while i < n && p[i] != 0 { i++; }
        if i > n { break; }
        str pa = str_from(p + a, cast(i32, i - a));
        i++;
        str pb = pa;
        if st == 'R' || st == 'C' {
            i64 b = i;
            while i < n && p[i] != 0 { i++; }
            pb = str_from(p + b, cast(i32, i - b));
            i++;
        }
        if pa.len == 0 || pb.len == 0 || pb.len > PATH_MAX || pa.len > PATH_MAX { continue; }
        HistFile* f = &hist_files[hist_nfiles];
        f.st = st;
        f.path_off = hist_put(&hist_ftxt, &hist_ftxtlen, &hist_ftxtcap, pb.data, pb.len);
        f.path_len = pb.len;
        f.old_off = hist_put(&hist_ftxt, &hist_ftxtlen, &hist_ftxtcap, pa.data, pa.len);
        f.old_len = pa.len;
        hist_nfiles++;
    }
}

// --- the worker -----------------------------------------------------------

private const i32 HJ_LOG = 0;
private const i32 HJ_FILES = 1;
private const i32 HJ_BLOBS = 2;
private const i32 HJ_KINDS = 3;

struct HistJob {
    i32 kind;
    i32 gen;
    i32 skip;                 // log: commits already held
    u8[HIST_SHA] sha;         // files, blobs: the commit
    u8[HIST_SHA] par;         // its first parent
    i32 npar;
    u8 st;                    // blobs: the file's status letter
    u8[PATH_MAX] path;
    i32 path_len;
    u8[PATH_MAX] old;         // the path in the parent
    i32 old_len;
    u8* out;                  // the log, the files, or the file in the commit
    i64 out_len;
    u8* out2;                 // blobs: the file in the parent
    i64 out2_len;
    bool ok;
}

private Thread hist_thr;
private bool hist_thr_on = false;
private bool hist_thr_done = false;
private HistJob hist_run;
private HistJob[HJ_KINDS] hist_pend;
private bool[HJ_KINDS] hist_pend_on;

// false: a job runs on the caller's thread, as in a browser. The
// harnesses set it, so a result is there at the next wake in every run.
bool hist_threaded = true;

private u8* hist_git(str* argv, i32 argc, i64* n, bool* ok) {
    i32 code = 0;
    *n = 0;
    u8* out = plat_run_capture(argv, argc, n, &code);
    *ok = out != null && code == 0;
    if out != null && code != 0 {
        free(out);
        *n = 0;
        return null;
    }
    return out;
}

// `git show <rev>:<path>`
private u8* hist_show(u8* rev, u8* path, i32 plen, i64* n) {
    noinit u8[PATH_MAX + HIST_SHA + 2] spec;
    memcpy(&spec[0], rev, HIST_SHA);
    spec[HIST_SHA] = ':';
    memcpy(&spec[HIST_SHA + 1], path, plen);
    noinit str[3] argv;
    argv[0] = "git";
    argv[1] = "show";
    argv[2] = str_from(&spec[0], HIST_SHA + 1 + plen);
    bool ok = false;
    return hist_git(&argv[0], 3, n, &ok);
}

private void hist_worker(void* arg) {
    HistJob* j = &hist_run;
    j.out = null;
    j.out2 = null;
    j.out_len = 0;
    j.out2_len = 0;
    j.ok = false;
    if j.kind == HJ_LOG {
        noinit u8[32] skip;
        str pre = "--skip=";
        memcpy(&skip[0], pre.data, pre.len);
        i32 sn = pre.len + fmt_i32(&skip[pre.len], j.skip);
        noinit u8[16] cnt;
        str pre2 = "-n";
        memcpy(&cnt[0], pre2.data, pre2.len);
        i32 cn = pre2.len + fmt_i32(&cnt[pre2.len], HIST_PAGE);
        noinit str[7] argv;
        argv[0] = "git";
        argv[1] = "log";
        argv[2] = "--topo-order";
        argv[3] = "--format=%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s%x1e";
        argv[4] = str_from(&skip[0], sn);
        argv[5] = str_from(&cnt[0], cn);
        argv[6] = "HEAD";
        j.out = hist_git(&argv[0], 7, &j.out_len, &j.ok);
    } else if j.kind == HJ_FILES {
        noinit str[9] argv;
        argv[0] = "git";
        argv[1] = "diff-tree";
        argv[2] = "-r";
        argv[3] = "-M";
        argv[4] = "--name-status";
        argv[5] = "-z";
        i32 argc = 6;
        if j.npar > 0 {
            argv[argc] = str_from(&j.par[0], HIST_SHA);
            argc++;
        } else {
            argv[argc] = "--root";
            argc++;
            argv[argc] = "--no-commit-id";
            argc++;
        }
        argv[argc] = str_from(&j.sha[0], HIST_SHA);
        argc++;
        j.out = hist_git(&argv[0], argc, &j.out_len, &j.ok);
    } else if j.kind == HJ_BLOBS {
        // a deleted file has nothing in the commit, an added one nothing
        // in the parent, and a root commit has no parent
        if j.st != 'D' { j.out = hist_show(&j.sha[0], &j.path[0], j.path_len, &j.out_len); }
        if j.st != 'A' && j.npar > 0 { j.out2 = hist_show(&j.par[0], &j.old[0], j.old_len, &j.out2_len); }
        j.ok = true;
    }
    hist_thr_done = true;
    plat_wake();
}

// the next job: what was asked for last goes first, a diff before a
// commit's files before more of the log
private void hist_next() {
    if hist_thr_on { return; }
    i32 k = -1;
    if hist_pend_on[HJ_BLOBS] { k = HJ_BLOBS; }
    else if hist_pend_on[HJ_FILES] { k = HJ_FILES; }
    else if hist_pend_on[HJ_LOG] { k = HJ_LOG; }
    if k < 0 { return; }
    hist_pend_on[k] = false;
    hist_run = hist_pend[k];
    hist_thr_done = false;
    hist_thr_on = true;
    when os(wasm) {
        hist_worker(null);
    } else {
        if hist_threaded {
            thread_create(&hist_thr, hist_worker, null);
        } else {
            hist_worker(null);
        }
    }
}

private void hist_ask(HistJob* j) {
    j.gen = hist_gen;
    hist_pend[j.kind] = *j;
    hist_pend_on[j.kind] = true;
    hist_next();
}

// strip the CR of each CRLF, as the baseline does, so the two sides of
// a diff split into the same lines
private i64 hist_lf(u8* p, i64 n) {
    i64 w = 0;
    for i64 i = 0; i < n; i++ {
        if p[i] == '\r' && i + 1 < n && p[i + 1] == '\n' { continue; }
        p[w] = p[i];
        w++;
    }
    return w;
}

private bool hist_binary(u8* p, i64 n) {
    if p == null { return false; }
    i64 m = n;
    if m > HIST_BIN_PROBE { m = HIST_BIN_PROBE; }
    for i64 i = 0; i < m; i++ {
        if p[i] == 0 { return true; }
    }
    return false;
}

// "name @ 1a2b3c4": a side of a commit's diff
private str hist_label(u8* buf, str path, u8* rev) {
    i32 b = path_base_off(path.data, path.len);
    i32 n = path.len - b;
    if n > HIST_NAME_MAX - 16 { n = HIST_NAME_MAX - 16; }
    memcpy(buf, path.data + b, n);
    str at = " @ ";
    memcpy(buf + n, at.data, at.len);
    n += at.len;
    memcpy(buf + n, rev, HIST_SHORT);
    return str_from(buf, n + HIST_SHORT);
}

private void hist_apply(HistJob* j) {
    if j.gen != hist_gen { return; }
    if j.kind == HJ_LOG {
        hist_loading = false;
        if !j.ok {
            hist_more = false;
            if hist_n == 0 { hist_failed = true; }
            return;
        }
        i32 got = hist_add_log(j.out, j.out_len);
        if got < HIST_PAGE { hist_more = false; }
        if hist_focus && hist_sel < 0 && hist_n > 0 { hist_sel = 0; }
        return;
    }
    if j.kind == HJ_FILES {
        if hist_open < 0 || !hist_sha_eq(&hist_c[hist_open].sha[0], &j.sha[0]) { return; }
        hist_files_wait = false;
        if j.ok { hist_add_files(j.out, j.out_len); }
        return;
    }
    if j.kind == HJ_BLOBS {
        if hist_binary(j.out, j.out_len) || hist_binary(j.out2, j.out2_len) {
            ed_notice("binary file: no diff to show");
            return;
        }
        i64 rn = 0;
        i64 ln = 0;
        if j.out != null { rn = hist_lf(j.out, j.out_len); }
        if j.out2 != null { ln = hist_lf(j.out2, j.out2_len); }
        str path = str_from(&j.path[0], j.path_len);
        str old = str_from(&j.old[0], j.old_len);
        noinit u8[HIST_NAME_MAX] rb;
        noinit u8[HIST_NAME_MAX] lb;
        str rname = hist_label(&rb[0], path, &j.sha[0]);
        str lname = "";
        if j.npar > 0 {
            lname = hist_label(&lb[0], old, &j.par[0]);
        } else {
            // a root commit: the left side is empty and says so
            i32 b = path_base_off(old.data, old.len);
            i32 n = old.len - b;
            if n > HIST_NAME_MAX - 16 { n = HIST_NAME_MAX - 16; }
            memcpy(&lb[0], old.data + b, n);
            str none = " (none)";
            memcpy(&lb[n], none.data, none.len);
            lname = str_from(&lb[0], n + none.len);
        }
        ed_rev_diff(path, rname, lname, j.out, rn, j.out2, ln);
        return;
    }
}

// the job that finished, taken on the UI thread at a wake
void hist_pump() {
    if !hist_thr_on || !hist_thr_done { return; }
    hist_take();
}

// the running job's result; the join waits for a worker still going
private void hist_take() {
    when !os(wasm) {
        if hist_threaded { thread_join(&hist_thr); }
    }
    hist_thr_on = false;
    hist_thr_done = false;
    hist_apply(&hist_run);
    if hist_run.out != null { free(hist_run.out); }
    if hist_run.out2 != null { free(hist_run.out2); }
    hist_run.out = null;
    hist_run.out2 = null;
    plat_damage();
    hist_next();
}

// every job to the end, for a headless frame and the checks
void hist_settle() {
    while hist_thr_on { hist_take(); }
}

// --- the log's lifetime ---------------------------------------------------

// Everything goes: another folder, or HEAD moved. A job still out
// brings back a result for the old generation, which is dropped.
void hist_reset() {
    hist_gen++;
    hist_n = 0;
    hist_nseg = 0;
    hist_txtlen = 0;
    hist_maxlane = 0;
    for i32 i = 0; i < HIST_LANES; i++ { hist_lane_used[i] = false; }
    hist_color_next = 0;
    hist_open = -1;
    hist_nfiles = 0;
    hist_files_wait = false;
    hist_sel = -1;
    hist_scroll = 0;
    hist_more = true;
    hist_loading = false;
    hist_loaded = false;
    hist_failed = false;
    for i32 k = 0; k < HJ_KINDS; k++ { hist_pend_on[k] = false; }
    plat_damage();
}

// the next page of the log, unless one is out or the last came back short
private void hist_load_more() {
    if hist_loading || !hist_more { return; }
    HistJob j;
    j.kind = HJ_LOG;
    j.skip = hist_n;
    hist_loading = true;
    hist_ask(&j);
}

// the panel is about to show: the first page, once per reset
void hist_ensure() {
    if hist_loaded { return; }
    hist_loaded = true;
    hist_load_more();
}

// HEAD moved: the log is read again from the top. The selected commit
// is lost, as the rows under it are.
void hist_head_moved() {
    bool was = hist_loaded;
    hist_reset();
    if was { hist_ensure(); }
}

i32 hist_count() { return hist_n; }
bool hist_busy() { return hist_thr_on; }
bool hist_more_left() { return hist_more; }

str hist_sha(i32 i) {
    if i < 0 || i >= hist_n { return ""; }
    return str_from(&hist_c[i].sha[0], HIST_SHA);
}

str hist_subject(i32 i) {
    if i < 0 || i >= hist_n { return ""; }
    return hist_str(hist_c[i].subj_off, hist_c[i].subj_len);
}

i32 hist_lane_col(i32 i) {
    if i < 0 || i >= hist_n { return -1; }
    return cast(i32, hist_c[i].col);
}

i32 hist_open_commit() { return hist_open; }
i32 hist_file_count() { return hist_nfiles; }

str hist_file_path(i32 k) {
    if k < 0 || k >= hist_nfiles { return ""; }
    return hist_fstr(hist_files[k].path_off, hist_files[k].path_len);
}

// --- the rows -------------------------------------------------------------
// The panel's rows are the commits, with the open commit's files after
// it, and a last row while a page is out.

i32 hist_row_count() {
    i32 n = hist_n;
    if hist_open >= 0 { n += hist_nfiles; }
    if hist_loading || hist_failed || (hist_n == 0 && !hist_loaded) { n++; }
    return n;
}

// row r as a commit (*file -1) or as file *file of the open commit; -1
// for the status row at the end
private i32 hist_row_at(i32 r, i32* file) {
    *file = -1;
    if r < 0 { return -1; }
    if hist_open >= 0 && r > hist_open {
        if r <= hist_open + hist_nfiles {
            *file = r - hist_open - 1;
            return hist_open;
        }
        r -= hist_nfiles;
    }
    if r >= hist_n { return -1; }
    return r;
}

private i32 hist_row_of(i32 commit) {
    if hist_open >= 0 && commit > hist_open { return commit + hist_nfiles; }
    return commit;
}

private i32 hist_rh() {
    return tree_row_h();
}

private i32 hist_pad() {
    return font_line_h / 4;
}

private void hist_scroll_clamp() {
    i32 maxs = 2 * hist_pad() + hist_row_count() * hist_rh() - hist_view_h;
    if maxs < 0 { maxs = 0; }
    if hist_scroll > maxs { hist_scroll = maxs; }
    if hist_scroll < 0 { hist_scroll = 0; }
}

private void hist_sel_visible() {
    if hist_sel < 0 || hist_view_h <= 0 { return; }
    i32 rh = hist_rh();
    i32 top = hist_pad() + hist_sel * rh - hist_scroll;
    if top < 0 { hist_scroll += top; }
    i32 bot = top + rh - hist_view_h;
    if bot > 0 { hist_scroll += bot; }
    hist_scroll_clamp();
}

// near the end of what is held: the next page
private void hist_near_end() {
    i32 rh = hist_rh();
    if rh <= 0 { return; }
    i32 last = (hist_scroll + hist_view_h) / rh;
    if last >= hist_row_count() - HIST_MORE_ROWS { hist_load_more(); }
}

void hist_scroll_by(f32 dy) {
    hist_scroll_accum += dy;
    i32 step = cast(i32, hist_scroll_accum);
    if step == 0 { return; }
    hist_scroll_accum -= cast(f32, step);
    hist_scroll += step;
    hist_scroll_clamp();
    hist_near_end();
    ed_damage();
}

void hist_select(i32 r) {
    i32 n = hist_row_count();
    if r >= n { r = n - 1; }
    if r < 0 { r = -1; }
    hist_sel = r;
    hist_sel_visible();
    hist_near_end();
    ed_damage();
}

i32 hist_sel_row() { return hist_sel; }

// a commit's files under it, or folded away again; one commit is open
// at a time
private void hist_toggle(i32 ci) {
    if ci < 0 || ci >= hist_n { return; }
    if hist_open == ci {
        hist_open = -1;
        hist_nfiles = 0;
        hist_sel = ci;
        hist_sel_visible();
        ed_damage();
        return;
    }
    hist_open = ci;
    hist_nfiles = 0;
    hist_files_wait = true;
    hist_sel = ci;
    HistJob j;
    j.kind = HJ_FILES;
    memcpy(&j.sha[0], &hist_c[ci].sha[0], HIST_SHA);
    memcpy(&j.par[0], &hist_c[ci].par[0], HIST_SHA);
    j.npar = hist_c[ci].npar;
    hist_ask(&j);
    hist_sel_visible();
    ed_damage();
}

// file k of the open commit, against the commit's first parent
private void hist_open_file(i32 k) {
    if hist_open < 0 || k < 0 || k >= hist_nfiles { return; }
    HistCommit* c = &hist_c[hist_open];
    HistFile* f = &hist_files[k];
    HistJob j;
    j.kind = HJ_BLOBS;
    memcpy(&j.sha[0], &c.sha[0], HIST_SHA);
    memcpy(&j.par[0], &c.par[0], HIST_SHA);
    j.npar = c.npar;
    j.st = f.st;
    memcpy(&j.path[0], hist_ftxt + f.path_off, f.path_len);
    j.path_len = f.path_len;
    memcpy(&j.old[0], hist_ftxt + f.old_off, f.old_len);
    j.old_len = f.old_len;
    hist_ask(&j);
}

// Enter, Space or a click on row r: a commit opens or folds, a file
// shows its diff
void hist_activate(i32 r) {
    i32 file = -1;
    i32 ci = hist_row_at(r, &file);
    if ci < 0 { return; }
    if file >= 0 {
        hist_open_file(file);
        return;
    }
    hist_toggle(ci);
}

// keys while the graph has the keyboard; false for one it leaves
bool hist_key(i32 key, i32 mods) {
    if mods != 0 { return false; }
    i32 n = hist_row_count();
    if key == K_UP || key == K_DOWN {
        if n == 0 { return true; }
        i32 d = 1;
        if key == K_UP { d = -1; }
        i32 ns = hist_sel + d;
        if ns < 0 { ns = 0; }
        hist_select(ns);
        return true;
    }
    if key == K_PGUP || key == K_PGDN {
        i32 page = hist_view_h / hist_rh();
        if page < 1 { page = 1; }
        if key == K_PGUP { page = -page; }
        i32 ns = hist_sel + page;
        if ns < 0 { ns = 0; }
        hist_select(ns);
        return true;
    }
    if key == K_HOME { hist_select(0); return true; }
    if key == K_END { hist_select(n - 1); return true; }
    i32 file = -1;
    i32 ci = hist_row_at(hist_sel, &file);
    if key == K_RIGHT {
        if ci >= 0 && file < 0 && hist_open != ci { hist_toggle(ci); }
        else if ci >= 0 && file < 0 && hist_nfiles > 0 { hist_select(hist_sel + 1); }
        return true;
    }
    if key == K_LEFT {
        if ci >= 0 && file >= 0 { hist_select(hist_row_of(ci)); }
        else if ci >= 0 && hist_open == ci { hist_toggle(ci); }
        return true;
    }
    return false;
}

// Enter opens and leaves the keyboard here for a commit, and gives it
// to the editor after a file's diff; Space opens and stays
bool hist_char(u32 cp) {
    if cp == 13 || cp == 32 {
        i32 file = -1;
        i32 ci = hist_row_at(hist_sel, &file);
        hist_activate(hist_sel);
        if cp == 13 && ci >= 0 && file >= 0 {
            tree_focus = false;
            hist_focus = false;
        }
        plat_damage();
        return true;
    }
    return false;
}

private i32 hist_click_row = -1;
private i64 hist_click_us = 0;

// a press at y inside the rows
void hist_mouse(i32 x, i32 y) {
    hist_focus = true;
    i32 r = (y - hist_pad() + hist_scroll) / hist_rh();
    if r < 0 || r >= hist_row_count() {
        hist_select(-1);
        return;
    }
    i64 now = plat_time_us();
    bool dbl = r == hist_click_row && now - hist_click_us < DBLCLICK_US;
    hist_click_row = r;
    hist_click_us = now;
    hist_select(r);
    i32 file = -1;
    ignore hist_row_at(r, &file);
    // the second press of a double click on a commit would fold it again
    if dbl && file < 0 { return; }
    hist_activate(r);
    if dbl && file >= 0 { ed_buf_keep(); }
}

// --- drawing --------------------------------------------------------------

private const i32 HIST_CURVE_STEPS = 12;

// a vertical S from (x0, y0) to (x1, y1), its ends upright
private void hist_curve(f32 x0, f32 y0, f32 x1, f32 y1, f32 w, u32 col) {
    f32 my = (y0 + y1) * 0.5f;
    f32 px = x0;
    f32 py = y0;
    for i32 i = 1; i <= HIST_CURVE_STEPS; i++ {
        f32 t = cast(f32, i) / cast(f32, HIST_CURVE_STEPS);
        f32 u = 1.0f - t;
        f32 x = u * u * u * x0 + 3.0f * u * u * t * x0 + 3.0f * u * t * t * x1 + t * t * t * x1;
        f32 y = u * u * u * y0 + 3.0f * u * u * t * my + 3.0f * u * t * t * my + t * t * t * y1;
        draw_segment(px, py, x, y, w, col);
        px = x;
        py = y;
    }
}

private i32 hist_lane_w() {
    i32 w = hist_rh() * 11 / 20;
    if w < 6 { w = 6; }
    return w;
}

// the lanes drawn left of the text, so many that the text keeps room
private i32 hist_lanes_shown(i32 w) {
    i32 n = hist_maxlane + 1;
    i32 most = (w / 2) / hist_lane_w();
    if most < 1 { most = 1; }
    if n > most { n = most; }
    return n;
}

private f32 hist_part_y(i32 y, i32 rh, u8 p) {
    if p == HIST_TOP { return cast(f32, y); }
    // on a whole pixel: the dot is a rounded rect, which shows a seam
    // across its middle when it straddles one
    if p == HIST_MID { return cast(f32, y + rh / 2); }
    return cast(f32, y + rh);
}

// the lanes' colors, the reference's five
private u32 hist_color(u8 c) {
    i32 k = cast(i32, c) % HIST_COLORS;
    if k == 0 { return 0xFF00B0FF; }
    if k == 1 { return 0xFF7F26DC; }
    if k == 2 { return 0xFF004F99; }
    if k == 3 { return 0xFFA6B040; }
    return 0xFFFF6DB6;
}

private u32 hist_status_color(u8 st) {
    if st == 'A' { return T_DEC_ADD; }
    if st == 'D' { return T_DEC_DEL; }
    if st == 'R' || st == 'C' { return T_DEC_UNTRACKED; }
    return T_DEC_MOD;
}

// the decoration's names, each in a pill: "HEAD -> main" is "main"
private f32 hist_draw_refs(str refs, f32 x, i32 y, i32 rh, f32 xmax, u32 col) {
    i32 i = 0;
    i32 pad = hist_pad();
    while i < refs.len && x < xmax {
        while i < refs.len && (refs.data[i] == ',' || refs.data[i] == ' ') { i++; }
        i32 s = i;
        while i < refs.len && refs.data[i] != ',' { i++; }
        str name = str_from(refs.data + s, i - s);
        str head = "HEAD -> ";
        if name.len > head.len && str_equal(str_from(name.data, head.len), head) {
            name = str_from(name.data + head.len, name.len - head.len);
        }
        str tag = "tag: ";
        if name.len > tag.len && str_equal(str_from(name.data, tag.len), tag) {
            name = str_from(name.data + tag.len, name.len - tag.len);
        }
        if name.len == 0 { continue; }
        i32 tw = font_ui_text_w(name);
        f32 pw = cast(f32, tw + pad * 2);
        if x + pw > xmax { break; }
        f32 py = cast(f32, y + rh / 8);
        f32 ph = cast(f32, rh - rh / 4);
        draw_rect_rounded(x, py, pw, ph, cast(i32, ph) / 2, theme_alpha(col, 0x55));
        f32 ty = cast(f32, y + (rh - font_line_h) / 2 + font_ascent + 1 - font_ui_ascent);
        ignore font_draw_ui_text(name, x + cast(f32, pad), ty, xmax, T_FG);
        x += pw + cast(f32, pad / 2);
    }
    return x;
}

// The panel's rows in 0..w by y0..y1, over the sidebar's background.
// `focus` is whether the keyboard is in the panel.
void hist_render(i32 w, i32 y0, i32 y1, bool focus) {
    hist_view_h = y1 - y0;
    if hist_view_h <= 0 { return; }
    hist_scroll_clamp();
    i32 lh = font_line_h;
    i32 rh = hist_rh();
    i32 pad = hist_pad();
    i32 lw = hist_lane_w();
    i32 nl = hist_lanes_shown(w);
    f32 line_w = cast(f32, rh) / 12.0f;
    if line_w < 1.0f { line_w = 1.0f; }
    i32 gx = pad;
    i32 tx = gx + nl * lw + pad / 2;
    draw_clip_y(cast(f32, y0), cast(f32, y1));
    i32 n = hist_row_count();
    for i32 r = 0; r < n; r++ {
        i32 y = y0 + pad + r * rh - hist_scroll;
        if y + rh <= y0 { continue; }
        if y >= y1 { break; }
        f32 ty = cast(f32, y + (rh - lh) / 2 + font_ascent + 1 - font_ui_ascent);
        i32 file = -1;
        i32 ci = hist_row_at(r, &file);
        if r == hist_sel {
            if focus {
                draw_rect(0.0f, cast(f32, y), cast(f32, w), cast(f32, rh), T_LIST_SEL);
            } else {
                draw_rect(0.0f, cast(f32, y), cast(f32, w), cast(f32, rh), T_LIST_SEL_INACTIVE);
            }
        }
        if ci < 0 {
            // the status row
            str m = "Loading\xE2\x80\xA6";
            if hist_failed { m = "No history"; }
            ignore font_draw_ui_text(m, cast(f32, tx), ty, cast(f32, w - pad), T_DIM);
            continue;
        }
        HistCommit* c = &hist_c[ci];
        if file >= 0 {
            // the lanes running past the open commit's files
            for i32 i = 0; i < nl; i++ {
                if c.outc[i] == HIST_NO_LANE { continue; }
                f32 lx = cast(f32, gx + i * lw + lw / 2);
                draw_rect(lx - line_w * 0.5f, cast(f32, y), line_w, cast(f32, rh), hist_color(c.outc[i]));
            }
            HistFile* f = &hist_files[file];
            str path = hist_fstr(f.path_off, f.path_len);
            i32 b = path_base_off(path.data, path.len);
            str name = str_from(path.data + b, path.len - b);
            i32 fx = tx + lw;
            u32 icol = 0;
            u32 ico = theme_file_icon(name, &icol);
            font_draw(ico, cast(f32, fx), cast(f32, y + (rh - lh) / 2), icol);
            fx += font_cell_w * 2;
            noinit u8[1] sb;
            sb[0] = f.st;
            str badge = str_from(&sb[0], 1);
            i32 bw = font_ui_text_w(badge);
            f32 bx = cast(f32, w - pad - bw);
            u32 scol = hist_status_color(f.st);
            ignore font_draw_ui_text(badge, bx, ty, cast(f32, w), scol);
            f32 nx = font_draw_ui_text(name, cast(f32, fx), ty, bx - cast(f32, pad / 2), scol);
            if b > 1 {
                ignore font_draw_ui_text(str_from(path.data, b - 1), nx + cast(f32, pad), ty,
                    bx - cast(f32, pad / 2), T_DIM);
            }
            continue;
        }
        // the graph
        for i32 k = 0; k < c.seg_n; k++ {
            HistSeg* s = &hist_seg[c.seg_off + k];
            if cast(i32, s.x0) >= nl || cast(i32, s.x1) >= nl { continue; }
            f32 xa = cast(f32, gx + cast(i32, s.x0) * lw + lw / 2);
            f32 xb = cast(f32, gx + cast(i32, s.x1) * lw + lw / 2);
            f32 ya = hist_part_y(y, rh, s.p0);
            f32 yb = hist_part_y(y, rh, s.p1);
            u32 col = hist_color(s.color);
            if s.x0 == s.x1 {
                draw_rect(xa - line_w * 0.5f, ya, line_w, yb - ya, col);
            } else {
                hist_curve(xa, ya, xb, yb, line_w, col);
            }
        }
        i32 dc = cast(i32, c.col);
        if dc >= nl { dc = nl - 1; }
        f32 cx = cast(f32, gx + dc * lw + lw / 2);
        f32 cy = hist_part_y(y, rh, HIST_MID);
        i32 rr = rh / 5;
        if rr < 3 { rr = 3; }
        if c.npar > 1 { rr = rr * 3 / 4; }
        draw_rect_rounded(cx - cast(f32, rr), cy - cast(f32, rr), cast(f32, 2 * rr), cast(f32, 2 * rr), rr,
            hist_color(c.color));
        // the names, the subject, the author
        f32 x = cast(f32, tx);
        f32 xmax = cast(f32, w - pad);
        if c.refs_len > 0 {
            x = hist_draw_refs(hist_str(c.refs_off, c.refs_len), x, y, rh, xmax, hist_color(c.color));
        }
        x = font_draw_ui_text(hist_str(c.subj_off, c.subj_len), x, ty, xmax, T_FG);
        if x + cast(f32, pad) < xmax {
            ignore font_draw_ui_text(hist_str(c.auth_off, c.auth_len), x + cast(f32, pad), ty, xmax, T_DIM);
        }
    }
    draw_clip_y_off();
    // the scrollbar, as the tree draws its own
    i32 content = 2 * pad + n * rh;
    if content > hist_view_h {
        i32 vh = hist_view_h;
        i32 th = vh * vh / content;
        if th < HIST_SCROLL_MIN { th = HIST_SCROLL_MIN; }
        if th > vh { th = vh; }
        i32 maxs = content - vh;
        i32 sy = y0;
        if maxs > 0 { sy = y0 + (vh - th) * hist_scroll / maxs; }
        draw_rect_rounded(cast(f32, w - HIST_SCROLL_W - HIST_SCROLL_PAD), cast(f32, sy),
            cast(f32, HIST_SCROLL_W), cast(f32, th), HIST_SCROLL_W / 2, C_SCROLL);
    }
    hist_near_end();
}
