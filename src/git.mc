// git.mc - the change gutter. The baseline is the file's content at
// HEAD, fetched on a worker when a file is opened; the marks are a
// line diff of that against the buffer, computed here.
//
// Nothing on the UI thread ever waits for the worker. git can hang,
// and did: joining it when the next file was opened froze the editor
// with no way out.
//
// The diff is in-process rather than parsed out of `git diff` for one
// reason: the gutter has to follow the buffer as it is typed in, and a
// child process per keystroke is not that. git is asked only for the
// baseline bytes, which change when the file is saved or the branch
// moves, not when a character is typed.

import thread;

const i32 GIT_NONE = 0;
const i32 GIT_ADD = 1;
const i32 GIT_MOD = 2;

// Lines were deleted between the marked line and the one above it.
// Drawn as a wedge on the boundary rather than a bar, since the lines
// it stands for are not there to mark.
const i32 GIT_DEL = 3;

// A file that has diverged from HEAD by more than this many line edits
// is reported as one modified block instead. The cost of the diff is
// what this bounds: the trace it walks back is O(d^2).
private const i32 GIT_DMAX = 512;

private bool g_git_on = false;      // a baseline exists for this buffer
// A fetch for this buffer has come back, with or without a baseline. A
// reply that lands while another buffer is loaded is discarded, and
// this is how the buffer gets asked for again when it is next shown.
private bool g_git_fetched = false;
private u8* git_base = null;        // HEAD's bytes
private i64 git_base_len = 0;

// line hashes, baseline and buffer. The baseline's are computed once
// per baseline. The buffer's follow the edits: text_buf reports each
// insert and delete through git_note_edit, which shifts the array and
// rehashes the lines the edit touched, so a recompute never rehashes
// the file. Either cache is rebuilt once when it is not trusted (after
// a buffer switch or a reload), and the harness checks the buffer's
// against a full rehash.
private u64* git_ah = null;
private i32 git_an = 0;
private i32 git_acap = 0;
private bool git_ah_ok = false;
private u64* git_bh = null;
private i32 git_bn = 0;
private i32 git_bcap = 0;
private bool git_bh_ok = false;
// lines the last diff walked after trimming: the sync policy reads it
private i32 git_span = 0;

private u8* git_marks = null;       // one per buffer line
private i32 git_mcap = 0;
private i32 git_mn = 0;

// scratch: the buffer's bytes, and the matched flags the diff fills
private u8* git_buf = null;
private i64 git_bufcap = 0;
private u8* git_amatch = null;
private u8* git_bmatch = null;
private i32 git_matchcap = 0;

bool git_on() {
    return g_git_on;
}

bool git_fetched() {
    return g_git_fetched;
}

// a fetch (or the probe) is in flight; a new request would only be pended
bool git_busy() {
    return git_thr_on;
}

// the loaded buffer's baseline answer has come back, with or without a
// baseline; either way it is not asked for again
void git_note_fetched() {
    g_git_fetched = true;
}

i32 git_mark(i32 line) {
    if !g_git_on || line < 0 || line >= git_mn { return GIT_NONE; }
    return git_marks[line];
}

// tests read this back
i32 git_mark_count() {
    if !g_git_on { return 0; }
    return git_mn;
}

// FNV-1a; the basis does not fit a decimal literal, so it is two halves
private const u64 FNV_BASIS = (cast(u64, 0xCBF29CE4) << 32) | cast(u64, 0x84222325);
private const u64 FNV_PRIME = 1099511628211;

// git_buf with room for n bytes and a terminator
private void git_buf_reserve(i64 n) {
    if n + 1 > git_bufcap {
        if git_buf != null { free(git_buf); }
        git_bufcap = n + 1024;
        git_buf = alloc<u8>(git_bufcap);
    }
}

private u64 git_hash(u8* p, i64 n) {
    u64 h = FNV_BASIS;
    for i64 i = 0; i < n; i++ {
        h = (h ^ cast(u64, p[i])) * FNV_PRIME;
    }
    return h;
}

private u64* git_grow_h(u64* p, i32* cap, i32 need) {
    if need <= *cap { return p; }
    i32 n = *cap * 2 + 256;
    if n < need { n = need; }
    if p != null { free(p); }
    *cap = n;
    return alloc<u64>(n);
}

// Hash every line of `p`. One line plus one per newline, which is what
// text_buf counts: a trailing newline leaves a final empty line, and
// the marks are indexed by buffer line, so the two have to agree.
// the hash of buffer line l, through the scratch copy
private u64 git_hash_tb_line(i32 l) {
    i64 s = tb_line_start(l);
    i64 e = tb_line_end(l);
    i64 n = e - s;
    git_buf_reserve(n);
    if n > 0 { tb_copy(s, git_buf, n); }
    return git_hash(git_buf, n);
}

// Line `at` changed; `removed` lines after it are gone and `added`
// lines after it are new. text_buf calls this after every insert and
// delete, so the cached hashes stay the buffer's without a rehash of
// the file. Anything out of step drops the cache instead, and the
// next recompute rebuilds it.
void git_note_edit(i32 at, i32 removed, i32 added) {
    if !g_git_on || !git_bh_ok { return; }
    i32 nn = git_bn - removed + added;
    if at < 0 || at >= git_bn || at + removed >= git_bn + 1 || nn != tb.nlines {
        git_bh_ok = false;
        return;
    }
    if nn > git_bcap {
        i32 ncap = nn + nn / 2 + 256;
        u64* nh = alloc<u64>(ncap);
        memcpy(nh, git_bh, git_bn * sizeof(u64));
        free(git_bh);
        git_bh = nh;
        git_bcap = ncap;
    }
    i32 old_i = at + 1 + removed;   // first untouched line after the edit, old index
    i32 new_i = at + 1 + added;     // where it lands
    i32 tail = git_bn - old_i;
    if new_i > old_i {
        for i32 i = tail - 1; i >= 0; i-- { git_bh[new_i + i] = git_bh[old_i + i]; }
    } else if new_i < old_i {
        for i32 i = 0; i < tail; i++ { git_bh[new_i + i] = git_bh[old_i + i]; }
    }
    git_bn = nn;
    for i32 l = at; l <= at + added; l++ { git_bh[l] = git_hash_tb_line(l); }
}

// A recompute on the edit itself is affordable while the diff walks a
// short span; many edits far apart in a big file widen it, and then
// the timer takes over.
private const i32 GIT_SYNC_SPAN = 4000;

bool git_sync_ok() {
    return g_git_on && git_span <= GIT_SYNC_SPAN;
}

// for the harness: the incremental hashes against a full rehash
bool git_check_cache() {
    if !g_git_on || !git_bh_ok { return true; }
    i64 n = tb_len();
    git_buf_reserve(n);
    if n > 0 { tb_copy(0, git_buf, n); }
    u64* full = null;
    i32 fcap = 0;
    i32 full_n = git_hash_lines(git_buf, n, &full, &fcap);
    bool ok = full_n == git_bn;
    if !ok {
        print("git cache: {} lines cached, {} in the buffer\n", git_bn, full_n);
    }
    for i32 i = 0; ok && i < full_n; i++ {
        if full[i] != git_bh[i] {
            print("git cache: line {} hash is stale\n", i);
            ok = false;
        }
    }
    free(full);
    return ok;
}

private i32 git_hash_lines(u8* p, i64 n, u64** out, i32* cap) {
    i32 count = 1;
    for i64 i = 0; i < n; i++ {
        if p[i] == '\n' { count++; }
    }
    *out = git_grow_h(*out, cap, count);
    u64* h = *out;
    i32 k = 0;
    i64 s = 0;
    for i64 i = 0; i < n; i++ {
        if p[i] == '\n' {
            h[k] = git_hash(p + s, i - s);
            k++;
            s = i + 1;
        }
    }
    h[k] = git_hash(p + s, n - s);
    k++;
    return k;
}

// --- Myers ------------------------------------------------------------
// The greedy O(ND) walk. Its cost is in the number of differences, not
// the size of the file, which is what a gutter recomputed on a timer
// needs: a few edited lines in a large file is a few steps.

private i32* git_v = null;          // the working diagonal
private i32 git_vcap = 0;
private i32* git_trace = null;      // v after each step, packed
private i32 git_tracecap = 0;

private i32* git_grow_i(i32* p, i32* cap, i32 need) {
    if need <= *cap { return p; }
    i32 n = *cap * 2 + 1024;
    if n < need { n = need; }
    if p != null { free(p); }
    *cap = n;
    return alloc<i32>(n);
}

// Fills amatch/bmatch with 1 where a line survives unchanged. False
// when the two sides differ by more than GIT_DMAX edits.
private bool git_myers(u64* a, i32 na, u64* b, i32 nb, u8* am, u8* bm) {
    i32 dmax = na + nb;
    if dmax > GIT_DMAX { dmax = GIT_DMAX; }
    i32 vw = 2 * dmax + 3;
    git_v = git_grow_i(git_v, &git_vcap, vw);
    // step d needs 2d+1 entries; the whole trace is that summed
    i32 need = (dmax + 1) * (dmax + 1) + 4 * (dmax + 1);
    git_trace = git_grow_i(git_trace, &git_tracecap, need);
    i32 off = dmax + 1;
    for i32 i = 0; i < vw; i++ { git_v[i] = 0; }
    i32 tw = 0;
    i32 found = -1;
    for i32 d = 0; d <= dmax; d++ {
        for i32 k = 0 - d; k <= d; k += 2 {
            i32 x = 0;
            if k == 0 - d {
                x = git_v[off + k + 1];
            } else if k != d && git_v[off + k - 1] < git_v[off + k + 1] {
                x = git_v[off + k + 1];
            } else {
                x = git_v[off + k - 1] + 1;
            }
            i32 y = x - k;
            while x < na && y < nb && a[x] == b[y] {
                x++;
                y++;
            }
            git_v[off + k] = x;
            if x >= na && y >= nb { found = d; }
        }
        // snapshot the band this step could reach
        for i32 k = 0 - d; k <= d; k += 2 {
            git_trace[tw] = git_v[off + k];
            tw++;
        }
        if found >= 0 { break; }
    }
    if found < 0 { return false; }

    for i32 i = 0; i < na; i++ { am[i] = 0; }
    for i32 i = 0; i < nb; i++ { bm[i] = 0; }

    // Walk the trace back. Step d holds the band k = -d..d by 2, which
    // is d+1 entries, so step d starts at d*(d+1)/2 and entry k sits at
    // (k + d) / 2 within it. Stepping back from d reads step d-1: that
    // is where the predecessor of this position was recorded.
    i32 x = na;
    i32 y = nb;
    for i32 d = found; d > 0; d-- {
        i32 pd = d - 1;
        i32 pb = pd * (pd + 1) / 2;
        i32 k = x - y;
        i32 prev_k = 0;
        if k == 0 - d {
            prev_k = k + 1;
        } else if k == d {
            prev_k = k - 1;
        } else {
            i32 left = git_trace[pb + (k - 1 + pd) / 2];
            i32 up = git_trace[pb + (k + 1 + pd) / 2];
            if left < up { prev_k = k + 1; } else { prev_k = k - 1; }
        }
        i32 prev_x = git_trace[pb + (prev_k + pd) / 2];
        i32 prev_y = prev_x - prev_k;
        // the diagonal run between here and the previous step is text
        // that matched on both sides
        while x > prev_x && y > prev_y {
            x--;
            y--;
            am[x] = 1;
            bm[y] = 1;
        }
        x = prev_x;
        y = prev_y;
    }
    while x > 0 && y > 0 {
        x--;
        y--;
        am[x] = 1;
        bm[y] = 1;
    }
    return true;
}

// --- marks ------------------------------------------------------------

private u8* git_grow_b(u8* p, i32* cap, i32 need) {
    if need <= *cap { return p; }
    i32 n = *cap * 2 + 256;
    if n < need { n = need; }
    if p != null { free(p); }
    *cap = n;
    return alloc<u8>(n);
}

// Turn the matched flags into one mark per buffer line. A run of added
// lines next to a run of deleted ones reads as modification, which is
// what an editor shows: the deletion wedge is only for lines that went
// away with nothing put in their place.
// `base` is where the trimmed region starts in buffer line numbers, so
// the marks land on the real lines without a second pass.
private void git_marks_from(u8* am, i32 na, u8* bm, i32 nb, i32 base) {
    i32 i = 0;
    i32 j = 0;
    while i < na || j < nb {
        if i < na && j < nb && am[i] == 1 && bm[j] == 1 {
            i++;
            j++;
            continue;
        }
        i32 da = 0;
        while i + da < na && am[i + da] == 0 { da++; }
        i32 db = 0;
        while j + db < nb && bm[j + db] == 0 { db++; }
        i32 mod = da;
        if db < mod { mod = db; }
        for i32 k = 0; k < mod; k++ { git_marks[base + j + k] = GIT_MOD; }
        for i32 k = mod; k < db; k++ { git_marks[base + j + k] = GIT_ADD; }
        if da > db {
            // the surplus went away with nothing put in its place: the
            // wedge goes on the line that now follows the gap
            i32 at = base + j + db;
            if at >= git_mn { at = git_mn - 1; }
            if at >= 0 && git_marks[at] == GIT_NONE { git_marks[at] = GIT_DEL; }
        }
        i += da;
        j += db;
    }
}

// --- diff rows --------------------------------------------------------
// The two sides paired, one entry per row of a side-by-side view. A row
// names a line of the baseline, a line of the buffer, or both; -1 is a
// filler, where one side has nothing to put against the other. This is
// the same walk the marks come from, kept as pairs instead of collapsed
// onto the buffer's lines.
//
// Built only while a diff is open. It is O(file), as clearing the marks
// already is, but a buffer with no diff on screen has no use for it.

struct GitRow {
    i32 a;     // baseline line, -1 when the buffer added this one
    i32 b;     // buffer line, -1 when the baseline lost this one
    u8 kind;   // GIT_NONE, GIT_ADD, GIT_MOD, GIT_DEL
}

private GitRow* git_rows = null;
private i32 git_rn = 0;
private i32 git_rcap = 0;
private bool git_rows_want = false;
// The rows are one buffer's, the diff's file, and are kept here rather
// than in GitState because the diff's other pane reads them too. A
// buffer's GitState carries the generation it was loaded with; only the
// buffer holding the current one recomputes the rows. Any other buffer
// recomputes its marks and leaves the rows alone, so a baseline landing
// for it, or an edit in a pane beside the diff, cannot pair the rows
// against the wrong file.
private i32 git_rows_gen = 0;        // bumped each time the rows are asked for
private i32 git_rows_loaded = 0;     // the generation of the loaded buffer

// the loaded buffer is the one the rows belong to
private bool git_rows_mine() {
    return git_rows_want && git_rows_gen != 0 && git_rows_loaded == git_rows_gen;
}
private i32* git_lrow = null;      // buffer line to its row
private i32 git_lrowcap = 0;
// The maps' lengths when they were filled: the buffer's and the
// baseline's line counts at the last recompute. An edit changes
// git_bn at once and the maps only on the next recompute, so a lookup
// is bounded by these, not by git_bn; past them the map holds nothing
// that was written.
private i32 git_lrow_n = 0;
private i32 git_arow_n = 0;
private i32* git_arow = null;      // baseline line to its row
private i32 git_arowcap = 0;

// a diff view is open: pair the sides on every recompute
void git_rows_enable(bool on) {
    git_rows_want = on;
    if on {
        git_rows_gen++;
        git_rows_loaded = git_rows_gen;
    }
    if !on {
        if git_rows != null { free(git_rows); }
        if git_lrow != null { free(git_lrow); }
        if git_arow != null { free(git_arow); }
        git_rows = null;
        git_rcap = 0;
        git_lrow = null;
        git_lrowcap = 0;
        git_lrow_n = 0;
        git_arow = null;
        git_arowcap = 0;
        git_arow_n = 0;
        git_rn = 0;
        return;
    }
    git_recompute();
}

bool git_rows_on() {
    return git_rows_want && git_rn > 0;
}

i32 git_row_count() {
    return git_rn;
}

i32 git_row_a(i32 r) {
    if r < 0 || r >= git_rn { return -1; }
    return git_rows[r].a;
}

i32 git_row_b(i32 r) {
    if r < 0 || r >= git_rn { return -1; }
    return git_rows[r].b;
}

i32 git_row_kind(i32 r) {
    if r < 0 || r >= git_rn { return GIT_NONE; }
    return cast(i32, git_rows[r].kind);
}

// the row showing a buffer line; every line has exactly one
i32 git_row_of_line(i32 b) {
    if git_rn == 0 || b < 0 || b >= git_lrow_n { return -1; }
    return git_lrow[b];
}

// the same for the baseline's lines, which the left side of a diff
// counts in
i32 git_row_of_base(i32 a) {
    if git_rn == 0 || a < 0 || a >= git_arow_n { return -1; }
    return git_arow[a];
}

i32 git_base_lines() {
    return git_an;
}

u8* git_base_bytes() {
    return git_base;
}

i64 git_base_size() {
    return git_base_len;
}

// the next row that starts a changed block, walking down from `at`; -1
// when there is none below. A block is a run of rows that are not
// GIT_NONE, so the run's first row is what a jump lands on.
i32 git_row_next_change(i32 at) {
    i32 r = at;
    if r < 0 { r = -1; }
    // out of the block the caller is standing in
    while r + 1 < git_rn && git_rows[r + 1].kind != GIT_NONE
        && r >= 0 && git_rows[r].kind != GIT_NONE { r++; }
    for i32 i = r + 1; i < git_rn; i++ {
        if git_rows[i].kind != GIT_NONE { return i; }
    }
    return -1;
}

i32 git_row_prev_change(i32 at) {
    i32 r = at;
    if r > git_rn { r = git_rn; }
    while r - 1 >= 0 && git_rows[r - 1].kind != GIT_NONE
        && r < git_rn && git_rows[r].kind != GIT_NONE { r--; }
    i32 i = r - 1;
    while i >= 0 && git_rows[i].kind == GIT_NONE { i--; }
    if i < 0 { return -1; }
    // to the top of the block it lands in
    while i - 1 >= 0 && git_rows[i - 1].kind != GIT_NONE { i--; }
    return i;
}

private void git_row_push(i32 a, i32 b, i32 kind) {
    if git_rn >= git_rcap {
        i32 ncap = git_rcap * 2 + 1024;
        GitRow* nr = alloc<GitRow>(ncap);
        if git_rows != null {
            memcpy(nr, git_rows, git_rn * sizeof(GitRow));
            free(git_rows);
        }
        git_rows = nr;
        git_rcap = ncap;
    }
    git_rows[git_rn] = GitRow{ a, b, cast(u8, kind) };
    if b >= 0 && b < git_bn { git_lrow[b] = git_rn; }
    if a >= 0 && a < git_an { git_arow[a] = git_rn; }
    git_rn++;
}

// the same walk as git_marks_from, paired rather than collapsed. `lo`
// and `hi` are the runs trimmed off either end, which match by
// definition and pair one to one.
private void git_rows_from(u8* am, i32 na, u8* bm, i32 nb, i32 lo, i32 hi) {
    git_rn = 0;
    git_lrow_n = git_bn;
    git_arow_n = git_an;
    if git_bn > git_lrowcap {
        if git_lrow != null { free(git_lrow); }
        git_lrowcap = git_bn + 1024;
        git_lrow = alloc<i32>(git_lrowcap);
    }
    if git_an > git_arowcap {
        if git_arow != null { free(git_arow); }
        git_arowcap = git_an + 1024;
        git_arow = alloc<i32>(git_arowcap);
    }
    for i32 i = 0; i < lo; i++ { git_row_push(i, i, GIT_NONE); }
    i32 i = 0;
    i32 j = 0;
    while i < na || j < nb {
        if i < na && j < nb && am[i] == 1 && bm[j] == 1 {
            git_row_push(lo + i, lo + j, GIT_NONE);
            i++;
            j++;
            continue;
        }
        i32 da = 0;
        while i + da < na && am[i + da] == 0 { da++; }
        i32 db = 0;
        while j + db < nb && bm[j + db] == 0 { db++; }
        i32 mod = da;
        if db < mod { mod = db; }
        for i32 k = 0; k < mod; k++ { git_row_push(lo + i + k, lo + j + k, GIT_MOD); }
        for i32 k = mod; k < db; k++ { git_row_push(-1, lo + j + k, GIT_ADD); }
        for i32 k = mod; k < da; k++ { git_row_push(lo + i + k, -1, GIT_DEL); }
        i += da;
        j += db;
    }
    for i32 k = 0; k < hi; k++ {
        git_row_push(git_an - hi + k, git_bn - hi + k, GIT_NONE);
    }
}

// --- baseline ---------------------------------------------------------

// --- asking git ---------------------------------------------------------
// Two facts are asked for once per session (whether this is a repo at
// all, and where its root is relative to us) and the blob is asked for
// per open and per save. Nothing here runs while typing.

private i32 git_repo = -1;          // -1 not probed, 0 no repo, 1 repo
private u8[PATH_MAX] git_root;
private i32 git_root_len = 0;
private u8[PATH_MAX] git_prefix;    // cwd relative to the root, may be ""
private i32 git_prefix_len = 0;

private bool git_is_sep(u8 c) {
    return c == '/' || c == 92;
}

// "C:\x" and "/x" are absolute; anything else is read against the cwd
private bool git_abs(str p) {
    if p.len > 0 && git_is_sep(p.data[0]) { return true; }
    return p.len > 1 && p.data[1] == ':';
}

private u8 git_fold(u8 c) {
    if c >= 'A' && c <= 'Z' { return cast(u8, c + 32); }
    if c == 92 { return '/'; }
    return c;
}

private void git_probe() {
    if git_repo >= 0 { return; }
    git_repo = 0;
    noinit str[4] argv;
    argv[0] = "git";
    argv[1] = "rev-parse";
    argv[2] = "--show-toplevel";
    argv[3] = "--show-prefix";
    i64 n = 0;
    i32 code = 0;
    u8* out = plat_run_capture(&argv[0], 4, &n, &code);
    if out == null { return; }
    if code != 0 {
        free(out);
        return;
    }
    // two lines: the root, then our prefix inside it (possibly empty)
    i32 line = 0;
    i64 s = 0;
    for i64 i = 0; i <= n; i++ {
        if i == n || out[i] == '\n' {
            i64 e = i;
            if e > s && out[e - 1] == '\r' { e--; }
            i32 len = cast(i32, e - s);
            if len > PATH_MAX { len = PATH_MAX; }
            if line == 0 && len > 0 {
                memcpy(&git_root[0], out + s, len);
                git_root_len = len;
            } else if line == 1 {
                if len > 0 { memcpy(&git_prefix[0], out + s, len); }
                git_prefix_len = len;
            }
            line++;
            s = i + 1;
            if line > 1 { break; }
        }
    }
    free(out);
    if git_root_len > 0 { git_repo = 1; }
}

// The path git wants: relative to the repo root, forward slashes.
// False when the file is outside the repo, which is also how a file
// with no repo at all lands here.
private bool git_rel(str path, u8* out, i32* out_len) {
    i32 o = 0;
    if git_abs(path) {
        if path.len <= git_root_len { return false; }
        for i32 i = 0; i < git_root_len; i++ {
            if git_fold(path.data[i]) != git_fold(git_root[i]) { return false; }
        }
        i32 i = git_root_len;
        if i < path.len && git_is_sep(path.data[i]) { i++; }
        for i32 k = i; k < path.len; k++ {
            out[o] = path.data[k];
            if out[o] == 92 { out[o] = '/'; }
            o++;
        }
    } else {
        for i32 i = 0; i < git_prefix_len; i++ {
            out[o] = git_prefix[i];
            if out[o] == 92 { out[o] = '/'; }
            o++;
        }
        for i32 i = 0; i < path.len; i++ {
            out[o] = path.data[i];
            if out[o] == 92 { out[o] = '/'; }
            o++;
        }
    }
    if o == 0 { return false; }
    *out_len = o;
    return true;
}

// Running git costs more than opening the file does, so it happens on
// a worker and the gutter appears a moment after the text. The worker
// touches nothing the main thread reads while a fetch is in flight;
// the result is handed over in git_poll, after the join.
private Thread git_thr;
private bool git_thr_on = false;
private bool git_thr_done = false;
private u8[PATH_MAX] git_req;
private i32 git_req_len = 0;
private u8* git_out = null;
private i64 git_out_len = 0;

// what the worker is doing: one file's baseline, or the whole tree's
// status for the decorations. One thread at a time either way, so the
// probe and the handover stay single-threaded.
private const i32 GIT_JOB_BASE = 0;
private const i32 GIT_JOB_STATUS = 1;
private i32 git_job = GIT_JOB_BASE;
private bool git_reprobe = false;   // the root changed under a running worker

private void git_worker(void* arg) {
    git_out = null;
    git_out_len = 0;
    git_probe();
    if git_job == GIT_JOB_STATUS {
        gd_fetch();
    } else if git_repo == 1 {
        noinit u8[PATH_MAX + 8] rel;
        i32 rn = 0;
        str spec = "HEAD:";
        memcpy(&rel[0], spec.data, spec.len);
        i32 base = spec.len;
        if git_rel(str_from(&git_req[0], git_req_len), &rel[base], &rn) {
            noinit str[3] argv;
            argv[0] = "git";
            argv[1] = "show";
            argv[2] = str_from(&rel[0], base + rn);
            i64 n = 0;
            i32 code = 0;
            u8* out = plat_run_capture(&argv[0], 3, &n, &code);
            if out != null {
                if code == 0 {
                    git_out = out;
                    git_out_len = n;
                } else {
                    free(out);
                }
            }
        }
    }
    git_thr_done = true;
    plat_wake();
}

// the file a fetch was asked for while one was already running
private u8[PATH_MAX] git_pend;
private i32 git_pend_len = 0;
private bool git_pend_on = false;

private void git_start(str path) {
    memcpy(&git_req[0], path.data, path.len);
    git_req_len = path.len;
    git_job = GIT_JOB_BASE;
    git_launch();
}

private void git_start_status() {
    git_job = GIT_JOB_STATUS;
    git_launch();
}

// false: a job runs inline on the caller's thread, as it does in a
// browser. The fuzzer sets it, so a job's result is there at the next
// wake in every run instead of whenever the thread happened to finish.
bool git_threaded = true;

private void git_launch() {
    git_thr_done = false;
    when os(wasm) {
        // no workers in a browser: the fetch runs inline (the page's
        // plat_run_capture answers at once) and the handover still
        // waits for the wake, as it does everywhere
        git_worker(null);
    } else {
        if git_threaded {
            thread_create(&git_thr, git_worker, null);
        } else {
            git_worker(null);
        }
    }
    git_thr_on = true;
}

// Fetch the file's content at HEAD. A non-zero exit means git has no
// such blob (untracked, or added since HEAD), and then there is no
// baseline to compare against and no gutter.
//
// This runs on the UI thread, when a file is opened, so it must never
// wait for anything. One fetch runs at a time and a request made while
// one is in flight is remembered, not waited for: git can take as long
// as it likes, and the worst that owes the editor is a late gutter.
// Joining here instead froze the editor, since a worker that never
// finishes then never lets the open finish either.
void git_reload(str path) {
    git_clear();
    g_git_fetched = false;
    if path.len == 0 || path.len > PATH_MAX { return; }
    if git_thr_on {
        memcpy(&git_pend[0], path.data, path.len);
        git_pend_len = path.len;
        git_pend_on = true;
        return;
    }
    git_start(path);
}

// A baseline fetch for a buffer whose file is already loaded, after
// HEAD moved: the baseline stays on screen until the reply replaces it.
// Refused while a job runs, and the caller asks again after it.
bool git_request(str path) {
    if git_thr_on { return false; }
    if path.len == 0 || path.len > PATH_MAX { return false; }
    git_start(path);
    return true;
}

// the loaded buffer's baseline is out of date: HEAD moved
void git_mark_stale() {
    g_git_fetched = false;
}

// The main thread's side of the handover: called on wake, adopts the
// bytes only if the buffer that asked for them is still the one loaded.
// The join here cannot block: the worker has set its flag and is on its
// way out.
void git_poll(str path) {
    if !git_thr_on || !git_thr_done { return; }
    git_take(path);
}

// Same, but waits. Headless one-shot rendering wants the final state,
// not the state before the fetch lands. Not for the UI thread.
void git_settle(str path) {
    while git_thr_on {
        git_take(path);
    }
}

private void git_take(str path) {
    when !os(wasm) {
        if git_threaded { thread_join(&git_thr); }
    }
    git_thr_on = false;
    git_thr_done = false;
    u8* out = git_out;
    i64 n = git_out_len;
    git_out = null;
    git_out_len = 0;
    if git_job == GIT_JOB_STATUS {
        gd_adopt();
        tree_note_status();
    } else {
        // the baseline belongs to the buffer that asked for it, which
        // may be shown in another window now, not the one loaded here
        ed_git_adopt(str_from(&git_req[0], git_req_len), out, n);
    }
    if out != null { free(out); }
    if git_reprobe {
        git_reprobe = false;
        git_forget_repo();
    }
    // a file opened while that one was running still wants its
    // baseline, and comes first; the tree's status after it
    if git_pend_on {
        git_pend_on = false;
        git_start(str_from(&git_pend[0], git_pend_len));
    } else if gd_pend {
        gd_pend = false;
        git_start_status();
    }
}

// Another project: the root and prefix are found again on the next
// job, and the old tree's decorations go. Deferred while a worker
// runs, since it is the one writing the root.
void git_forget_repo() {
    gd_drop(&gd_live);
    gd_have = false;
    if git_thr_on {
        git_reprobe = true;
        return;
    }
    git_repo = -1;
    git_root_len = 0;
    git_prefix_len = 0;
}

// Everything the gutter knows about one buffer. It belongs to the
// buffer, like the undo journal, and moves with it: a pane swap runs
// per frame, so it must not re-diff, and asking git again would be
// worse still. The hash and scratch arrays are working memory and
// stay global.
struct GitState {
    bool fetched;
    i32 rows_gen;
    u8* base;
    i64 base_len;
    u8* marks;
    i32 mn;
    i32 mcap;
}

void git_detach(GitState* s) {
    s.fetched = g_git_fetched;
    s.rows_gen = git_rows_loaded;
    git_rows_loaded = 0;
    g_git_fetched = false;
    s.base = git_base;
    s.base_len = git_base_len;
    s.marks = git_marks;
    s.mn = git_mn;
    s.mcap = git_mcap;
    git_base = null;
    git_base_len = 0;
    git_marks = null;
    git_mn = 0;
    git_mcap = 0;
    g_git_on = false;
}

void git_attach(GitState* s) {
    git_free();
    // the hash caches are the loaded buffer's; this one rebuilds them
    git_ah_ok = false;
    git_bh_ok = false;
    git_span = 0;
    g_git_fetched = s.fetched;
    git_rows_loaded = s.rows_gen;
    git_base = s.base;
    git_base_len = s.base_len;
    git_marks = s.marks;
    git_mn = s.mn;
    git_mcap = s.mcap;
    g_git_on = git_base != null;
    s.base = null;
    s.marks = null;
    s.mn = 0;
    s.mcap = 0;
}

// drop what is loaded, buffers included; git_clear keeps the marks
// array for the next diff, this one gives it back
private void git_free() {
    if git_base != null { free(git_base); }
    if git_marks != null { free(git_marks); }
    git_base = null;
    git_base_len = 0;
    git_marks = null;
    git_mn = 0;
    git_mcap = 0;
    g_git_on = false;
}

void git_clear() {
    git_ah_ok = false;
    git_bh_ok = false;
    git_span = 0;
    if git_base != null {
        free(git_base);
        git_base = null;
    }
    git_base_len = 0;
    g_git_on = false;
    git_mn = 0;
}

// Takes a copy; the caller keeps ownership of `p`. CR before LF is
// dropped, because tb_load does the same to the working file: without
// it a CRLF checkout would report every line as modified.
void git_set_baseline(u8* p, i64 n) {
    git_clear();
    if p == null { return; }
    git_base = alloc<u8>(n + 1);
    i64 w = 0;
    for i64 i = 0; i < n; i++ {
        if p[i] == '\r' && i + 1 < n && p[i + 1] == '\n' { continue; }
        git_base[w] = p[i];
        w++;
    }
    git_base_len = w;
    g_git_on = true;
    git_recompute();
}

// Diff the baseline against the buffer as it stands. Cheap enough to
// run on a debounce, not per keystroke: it hashes every line.
void git_recompute() {
    if !g_git_on { return; }
    if !git_ah_ok {
        git_an = git_hash_lines(git_base, git_base_len, &git_ah, &git_acap);
        git_ah_ok = true;
    }
    if !git_bh_ok {
        // the whole buffer once; the edits keep it current after
        i64 n = tb_len();
        git_buf_reserve(n);
        if n > 0 { tb_copy(0, git_buf, n); }
        git_bn = git_hash_lines(git_buf, n, &git_bh, &git_bcap);
        git_bh_ok = true;
    }
    git_marks = git_grow_b(git_marks, &git_mcap, git_bn);
    git_mn = git_bn;

    // A run that matches at the top or the bottom cannot be part of any
    // edit, and trimming it is what keeps the walk short on a big file.
    i32 lo = 0;
    while lo < git_an && lo < git_bn && git_ah[lo] == git_bh[lo] { lo++; }
    i32 hi = 0;
    while hi < git_an - lo && hi < git_bn - lo
        && git_ah[git_an - 1 - hi] == git_bh[git_bn - 1 - hi] { hi++; }
    i32 na = git_an - lo - hi;
    i32 nb = git_bn - lo - hi;
    git_span = na + nb;

    for i32 i = 0; i < git_bn; i++ { git_marks[i] = GIT_NONE; }
    if na == 0 && nb == 0 {
        // identical: lo and hi cover the file between them
        if git_rows_mine() { git_rows_from(null, 0, null, 0, lo, hi); }
        return;
    }

    i32 need = na;
    if nb > need { need = nb; }
    if need > git_matchcap {
        if git_amatch != null { free(git_amatch); }
        if git_bmatch != null { free(git_bmatch); }
        git_matchcap = need + 256;
        git_amatch = alloc<u8>(git_matchcap);
        git_bmatch = alloc<u8>(git_matchcap);
    }
    bool ok = git_myers(git_ah + lo, na, git_bh + lo, nb,
        git_amatch, git_bmatch);
    if !ok {
        // Past the bound. Report the region as changed rather than
        // spending the time, and rather than claiming it is unchanged:
        // nothing matched means every line of it gets a mark.
        for i32 i = 0; i < na; i++ { git_amatch[i] = 0; }
        for i32 i = 0; i < nb; i++ { git_bmatch[i] = 0; }
    }
    git_marks_from(git_amatch, na, git_bmatch, nb, lo);
    if git_rows_mine() { git_rows_from(git_amatch, na, git_bmatch, nb, lo, hi); }
}

// --- decorations: the tree's colors from `git status` ------------------
// One state per path, in a table keyed by the hash of the root-relative
// path, built on the worker and swapped in whole on the wake. A folder
// carries the strongest state of anything under it, which is how the
// reference tints a folder and marks it with a dot.

const i32 DEC_NONE = 0;
const i32 DEC_MOD = 1;         // M: changed in the index or the tree
const i32 DEC_RENAME = 2;      // R: renamed in the index
const i32 DEC_ADD = 3;         // A: added to the index
const i32 DEC_UNTRACKED = 4;   // U: not in the index
const i32 DEC_DEL = 5;         // D: deleted in the index or the tree
const i32 DEC_CONFLICT = 6;    // C: unmerged

struct GdSlot {
    u64 h;
    i32 st;
}

// a changed path, as the list shows it: relative to this folder, since
// that is what opens it. Anything in the repo but outside the folder is
// left out, as it is left out of the tree.
struct GdFile {
    i32 off;    // into the table's path arena
    i32 len;
    i32 st;
    bool staged;   // the index column's state, not the tree's
}

struct GdTable {
    GdSlot* slots;   // open addressing, a power of two
    i32 cap;
    i32 n;
    u64 prefix_h;    // the hash of git's prefix for this directory
    // the same paths as a list. The table answers "what state is this
    // path in"; the list answers "which paths are there at all", which
    // a hash of the path cannot.
    u8* arena;
    i32 arena_n;
    i32 arena_cap;
    GdFile* files;
    i32 nfiles;
    i32 fcap;
}

private const i32 GD_MAX_SLOTS = 262144;
private const i64 GD_PATH_MAX = 4096;   // longer is junk
private GdTable gd_live;   // the tree's, read on the UI thread
private GdTable gd_new;    // the worker's, adopted on the wake
private bool gd_pend = false;
private bool gd_have = false;

private u64 gd_hash_seed() {
    return FNV_BASIS;
}

private u64 gd_hash_byte(u64 h, u8 c) {
    if c == 92 { c = '/'; }
    return (h ^ cast(u64, c)) * FNV_PRIME;
}

// the order a folder takes: the state that says the most wins
private void gd_drop(GdTable* t) {
    if t.slots != null { free(t.slots); }
    if t.arena != null { free(t.arena); }
    if t.files != null { free(t.files); }
    t.slots = null;
    t.cap = 0;
    t.n = 0;
    t.prefix_h = gd_hash_seed();
    t.arena = null;
    t.arena_n = 0;
    t.arena_cap = 0;
    t.files = null;
    t.nfiles = 0;
    t.fcap = 0;
}

// the path as this folder sees it: git reports from the repo root, and
// the editor opens relative to the working directory. False when the
// path is outside the folder, which the list does not show.
private bool gd_under_prefix(u8* p, i32 len, i32* off, i32* out_len) {
    i32 k = git_prefix_len;
    if k > 0 {
        if len <= k { return false; }
        for i32 i = 0; i < k; i++ {
            if git_fold(p[i]) != git_fold(git_prefix[i]) { return false; }
        }
        if p[k] != '/' && p[k] != 92 { return false; }
        k++;
    }
    *off = k;
    *out_len = len - k;
    return *out_len > 0;
}

private void gd_add_file(GdTable* t, u8* p, i32 len, i32 st, bool staged) {
    i32 off = 0;
    i32 n = 0;
    if !gd_under_prefix(p, len, &off, &n) { return; }
    if t.nfiles >= t.fcap {
        i32 ncap = t.fcap * 2 + 64;
        GdFile* nf = alloc<GdFile>(ncap);
        if t.files != null {
            memcpy(nf, t.files, t.nfiles * sizeof(GdFile));
            free(t.files);
        }
        t.files = nf;
        t.fcap = ncap;
    }
    if t.arena_n + n > t.arena_cap {
        i32 ncap = t.arena_cap * 2 + n + 1024;
        u8* na = alloc<u8>(ncap);
        if t.arena != null {
            memcpy(na, t.arena, t.arena_n);
            free(t.arena);
        }
        t.arena = na;
        t.arena_cap = ncap;
    }
    for i32 i = 0; i < n; i++ {
        u8 c = p[off + i];
        if c == 92 { c = '/'; }
        t.arena[t.arena_n + i] = c;
    }
    t.files[t.nfiles] = GdFile{ t.arena_n, n, st, staged };
    t.arena_n += n;
    t.nfiles++;
}

private void gd_put(GdTable* t, u64 h, i32 st) {
    if t.cap == 0 { return; }
    i32 i = cast(i32, h & cast(u64, t.cap - 1));
    for i32 k = 0; k < t.cap; k++ {
        if t.slots[i].st == DEC_NONE {
            if t.n + 1 >= t.cap / 2 { return; }   // full enough; the rest go undecorated
            t.slots[i] = GdSlot{ h, st };
            t.n++;
            return;
        }
        if t.slots[i].h == h {
            if st > t.slots[i].st { t.slots[i].st = st; }   // the DEC_ order is the rank
            return;
        }
        i = (i + 1) & (t.cap - 1);
    }
}

private i32 gd_find(GdTable* t, u64 h) {
    if t.cap == 0 { return DEC_NONE; }
    i32 i = cast(i32, h & cast(u64, t.cap - 1));
    for i32 k = 0; k < t.cap; k++ {
        if t.slots[i].st == DEC_NONE { return DEC_NONE; }
        if t.slots[i].h == h { return t.slots[i].st; }
        i = (i + 1) & (t.cap - 1);
    }
    return DEC_NONE;
}

// the index column alone: what is staged for the next commit
// porcelain's unmerged states: U on either side, or both added or
// both deleted
private bool gd_conflict(u8 x, u8 y) {
    return x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D');
}

private i32 gd_state_x(u8 x, u8 y) {
    if x == '?' || x == '!' { return DEC_NONE; }
    if gd_conflict(x, y) { return DEC_NONE; }
    if x == 'R' { return DEC_RENAME; }
    if x == 'A' || x == 'C' { return DEC_ADD; }
    if x == 'D' { return DEC_DEL; }
    if x == 'M' || x == 'T' { return DEC_MOD; }
    return DEC_NONE;
}

// the working tree column alone: what is changed but not staged. A
// conflict is neither side's, and shows here as the one thing to do
// about it.
private i32 gd_state_y(u8 x, u8 y) {
    if x == '?' && y == '?' { return DEC_UNTRACKED; }
    if x == '!' { return DEC_NONE; }
    if gd_conflict(x, y) { return DEC_CONFLICT; }
    if y == 'D' { return DEC_DEL; }
    if y == 'M' || y == 'T' { return DEC_MOD; }
    return DEC_NONE;
}

// porcelain's two columns: the index, then the tree
private i32 gd_state_of(u8 x, u8 y) {
    if x == '?' && y == '?' { return DEC_UNTRACKED; }
    if x == '!' { return DEC_NONE; }
    if gd_conflict(x, y) { return DEC_CONFLICT; }
    if x == 'D' || y == 'D' { return DEC_DEL; }
    if x == 'R' { return DEC_RENAME; }
    if x == 'A' || x == 'C' { return DEC_ADD; }
    if x == 'M' || y == 'M' || x == 'T' || y == 'T' { return DEC_MOD; }
    return DEC_NONE;
}

// the path and every folder above it
private void gd_insert_path(GdTable* t, u8* p, i32 len, i32 st) {
    u64 h = gd_hash_seed();
    for i32 i = 0; i < len; i++ {
        if p[i] == '/' && i > 0 { gd_put(t, h, st); }
        h = gd_hash_byte(h, p[i]);
    }
    gd_put(t, h, st);
}

// `git status --porcelain -z`: records of two state letters, a space,
// the path, NUL; a rename or copy carries the old name as a field of
// its own after that. Anything shorter than a record is skipped, and a
// missing final NUL is the end of the output.
private void gd_build(GdTable* t, u8* out, i64 n) {
    gd_drop(t);
    if out == null || n <= 0 { return; }
    i64 recs = 1;
    for i64 i = 0; i < n; i++ {
        if out[i] == 0 { recs++; }
    }
    i64 want = recs * 8 + 64;   // the folders above each path, at half load
    i32 cap = 64;
    while cast(i64, cap) < want && cap < GD_MAX_SLOTS { cap = cap * 2; }
    t.slots = alloc<GdSlot>(cap);
    memset(t.slots, 0, cast(i64, cap) * cast(i64, sizeof(GdSlot)));
    t.cap = cap;
    t.n = 0;
    i64 i = 0;
    while i < n {
        i64 e = i;
        while e < n && out[e] != 0 { e++; }
        i64 len = e - i;
        if len >= 4 && out[i + 2] == ' ' && len - 3 <= GD_PATH_MAX {
            u8 x = out[i];
            u8 y = out[i + 1];
            i32 st = gd_state_of(x, y);
            if st != DEC_NONE { gd_insert_path(t, out + i + 3, cast(i32, len - 3), st); }
            // the list keeps the columns apart: one record can be both
            // a staged change and an unstaged one
            i32 sx = gd_state_x(x, y);
            i32 sy = gd_state_y(x, y);
            if sx != DEC_NONE { gd_add_file(t, out + i + 3, cast(i32, len - 3), sx, true); }
            if sy != DEC_NONE { gd_add_file(t, out + i + 3, cast(i32, len - 3), sy, false); }
            if x == 'R' || x == 'C' {
                i64 e2 = e + 1;
                while e2 < n && out[e2] != 0 { e2++; }
                e = e2;
            }
        }
        i = e + 1;
    }
}

// on the worker: the whole tree's status, into the table the wake adopts
private void gd_fetch() {
    gd_drop(&gd_new);
    if git_repo != 1 { return; }
    noinit str[5] argv;
    argv[0] = "git";
    argv[1] = "status";
    argv[2] = "--porcelain";
    argv[3] = "-z";
    argv[4] = "--untracked-files=all";
    i64 n = 0;
    i32 code = 0;
    u8* out = plat_run_capture(&argv[0], 5, &n, &code);
    if out != null && code == 0 { gd_build(&gd_new, out, n); }
    if out != null { free(out); }
    u64 h = gd_hash_seed();
    for i32 i = 0; i < git_prefix_len; i++ { h = gd_hash_byte(h, git_prefix[i]); }
    gd_new.prefix_h = h;
}

// on the UI thread, after the join: the new table is the tree's now
private void gd_adopt() {
    gd_drop(&gd_live);
    gd_live = gd_new;
    gd_new.slots = null;
    gd_new.cap = 0;
    gd_new.n = 0;
    gd_new.arena = null;
    gd_new.arena_n = 0;
    gd_new.arena_cap = 0;
    gd_new.files = null;
    gd_new.nfiles = 0;
    gd_new.fcap = 0;
    gd_have = true;
    plat_damage();
}

// Ask for the tree's status: at start, after a save, after a folder
// switch. Never waited for; one run at a time, and a request made
// while one is in flight runs once after it.
void git_status_touch() {
    if git_thr_on {
        gd_pend = true;
        return;
    }
    git_start_status();
}

// a tree path (relative to the working directory, either slash) to its
// state; a folder answers for what it holds
i32 git_dec_state(str path) {
    if gd_live.n == 0 { return DEC_NONE; }
    u64 h = gd_live.prefix_h;
    for i32 i = 0; i < path.len; i++ { h = gd_hash_byte(h, path.data[i]); }
    return gd_find(&gd_live, h);
}

// --- the changed files, as a list -------------------------------------
// The same `git status` the decorations come from, kept as paths. The
// order is git's own: it reports the tracked changes sorted, then the
// untracked ones, which is the grouping a list wants anyway.

i32 git_changed_count() {
    return gd_live.nfiles;
}

str git_changed_path(i32 i) {
    if i < 0 || i >= gd_live.nfiles { return ""; }
    return str_from(gd_live.arena + gd_live.files[i].off, gd_live.files[i].len);
}

i32 git_changed_state(i32 i) {
    if i < 0 || i >= gd_live.nfiles { return DEC_NONE; }
    return gd_live.files[i].st;
}

// whether entry `i` is the index's side of the record or the tree's
bool git_changed_staged(i32 i) {
    if i < 0 || i >= gd_live.nfiles { return false; }
    return gd_live.files[i].staged;
}

// the status has been asked for at least once and come back
bool git_changed_ready() {
    return gd_have;
}

str git_dec_badge(i32 st) {
    if st == DEC_MOD { return "M"; }
    if st == DEC_RENAME { return "R"; }
    if st == DEC_ADD { return "A"; }
    if st == DEC_UNTRACKED { return "U"; }
    if st == DEC_DEL { return "D"; }
    if st == DEC_CONFLICT { return "C"; }
    return "";
}

bool git_dec_have() {
    return gd_have;
}

i32 git_dec_count() {
    return gd_live.n;
}
