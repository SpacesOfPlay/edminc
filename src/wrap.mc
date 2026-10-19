// wrap.mc - word wrap: a line wider than its pane continues on the rows
// under it (Alt+Z, "editor.wordWrap"). A row break goes after the last
// space or tab that fits, or inside a word that does not fit a row on
// its own. A continuation row is indented as far as the line's own
// indent, unless that leaves less than half the width.
//
// The view counts rows rather than lines while wrap is on, so a row
// count per line and the rows above each line are kept per buffer and
// per width (two widths, for one buffer in two panes). An edit marks
// the lines it touched (wrap_note_edit, from the text buffer) and moves
// the counts under them; only those lines are counted again. The rows
// above a line are summed again from the first edited line on, lazily,
// when a position is asked for. The break positions of one line at a
// time are kept for the renderer, which draws a line's rows in a row.

const i32 WRAP_SLOTS = 2;
private const i32 WRAP_MIN_COLS = 8;

bool g_wrap = false;   // the setting; Alt+Z toggles it

struct WrapCache {
    i32 cols;     // the width it counts for; 0 when unused
    i32* cnt;     // rows of each line; 0 when not counted yet
    i32* pre;     // pre[l]: the rows above line l, through pre_ok
    i32 n;        // the lines it covers
    i32 cap;
    i32 pre_ok;   // pre[0..pre_ok] are right
    i64 used;     // when last asked for; the older slot is replaced
}

// the loaded buffer's caches; the buffer table parks and restores them
WrapCache[WRAP_SLOTS] g_wrap_c;
private i64 wrap_tick = 0;

// one line's rows, for the renderer and the caret: the byte offset and
// the visual column each row starts at, and the continuation indent
private i32 wl_line = -1;
private i32 wl_cols = 0;
private i32 wl_n = 0;
private i32 wl_ind = 0;
private i32* wl_start = null;
private i32* wl_v0 = null;
private i32 wl_cap = 0;
private i64 wl_stamp = 0;     // wrap_gen when computed
private i64 wrap_gen = 1;     // moves on every edit and every reset

// the loaded buffer's caches are released (a buffer closing)
void wrap_free() {
    for i32 s = 0; s < WRAP_SLOTS; s++ {
        if g_wrap_c[s].cnt != null { free(g_wrap_c[s].cnt); }
        if g_wrap_c[s].pre != null { free(g_wrap_c[s].pre); }
        WrapCache z;
        g_wrap_c[s] = z;
    }
    wrap_gen++;
}

// the loaded buffer's text changed as a whole: count every line again
void wrap_reset() {
    for i32 s = 0; s < WRAP_SLOTS; s++ { g_wrap_c[s].n = -1; }
    wrap_gen++;
}

// another buffer was loaded into the globals: the line cache was not its
void wrap_switched() {
    wrap_gen++;
}

// The rows of a line of n bytes at p, at `cols` cells. With `out`, the
// byte offset and the visual column each row after the first starts at
// go to starts[1..] and v0s[1..]. The continuation indent goes to *ind.
private i32 wrap_scan(u8* p, i32 n, i32 cols, i32* starts, i32* v0s, i32 max, i32* ind) {
    // fast path: short and plain, one row
    if n <= cols {
        bool plain = true;
        for i32 i = 0; i < n; i++ {
            if p[i] == '\t' || p[i] >= 0x80 {
                plain = false;
                break;
            }
        }
        if plain {
            *ind = 0;
            return 1;
        }
    }
    // the indent, in cells
    i32 iv = 0;
    i32 ii = 0;
    while ii < n && (p[ii] == ' ' || p[ii] == '\t') {
        if p[ii] == '\t' { iv = (iv / TABW + 1) * TABW; } else { iv++; }
        ii++;
    }
    if iv * 2 > cols { iv = 0; }
    *ind = iv;
    i32 rows = 1;
    i32 rs = 0;        // the row's first byte
    i32 rv = 0;        // its visual column
    i32 lead = 0;      // cells before it on screen: the indent after the first row
    i32 bk = -1;       // the byte after the last space or tab in this row
    i32 bv = 0;        // the visual column there
    i32 v = 0;
    i32 i = 0;
    while i < n {
        i32 st = i;
        i32 w = 0;
        bool space = p[i] == ' ' || p[i] == '\t';
        if p[i] == '\t' {
            w = (v / TABW + 1) * TABW - v;
            i++;
        } else {
            w = grapheme_next_w(p, n, &i);
        }
        if lead + v + w - rv > cols && st > rs && !space {
            // the row is full: break after the last space in it, or here
            i32 at = st;
            i32 av = v;
            if bk > rs {
                at = bk;
                av = bv;
            }
            if rows < max {
                starts[rows] = at;
                v0s[rows] = av;
            }
            rows++;
            rs = at;
            rv = av;
            lead = iv;
            bk = -1;
        }
        v += w;
        if space {
            bk = i;
            bv = v;
        }
    }
    return rows;
}

// the width the loaded pane wraps at: its text columns, less one for the
// caret after the last character
i32 wrap_cols() {
    i32 c = text_cols() - 1;
    if c < WRAP_MIN_COLS { c = WRAP_MIN_COLS; }
    return c;
}

// the loaded buffer's cache for `cols`, made or reset to fit the buffer
private WrapCache* wrap_slot(i32 cols) {
    wrap_tick++;
    i32 pick = -1;
    for i32 s = 0; s < WRAP_SLOTS; s++ {
        if g_wrap_c[s].cols == cols { pick = s; }
    }
    if pick < 0 {
        pick = 0;
        for i32 s = 1; s < WRAP_SLOTS; s++ {
            if g_wrap_c[s].used < g_wrap_c[pick].used { pick = s; }
        }
        g_wrap_c[pick].cols = cols;
        g_wrap_c[pick].n = -1;
    }
    WrapCache* c = &g_wrap_c[pick];
    c.used = wrap_tick;
    i32 nl = tb.nlines;
    if c.n != nl {
        // made new, or the buffer changed in a way no edit reported
        if nl + 1 > c.cap {
            if c.cnt != null { free(c.cnt); }
            if c.pre != null { free(c.pre); }
            c.cap = nl + nl / 2 + 64;
            c.cnt = alloc<i32>(c.cap);
            c.pre = alloc<i32>(c.cap + 1);
        }
        memset(c.cnt, 0, nl * sizeof(i32));
        c.n = nl;
        c.pre[0] = 0;
        c.pre_ok = 0;
    }
    return c;
}

private i32 wrap_count(WrapCache* c, i32 l) {
    if c.cnt[l] == 0 {
        i32 n = line_bytes(l);
        i32 ind = 0;
        c.cnt[l] = wrap_scan(g_linebuf, n, c.cols, null, null, 0, &ind);
    }
    return c.cnt[l];
}

// pre[0..upto] made right
private void wrap_sum(WrapCache* c, i32 upto) {
    if upto > c.n { upto = c.n; }
    while c.pre_ok < upto {
        i32 l = c.pre_ok;
        c.pre[l + 1] = c.pre[l] + wrap_count(c, l);
        c.pre_ok++;
    }
}

// the first row of line l
i32 wrap_row_of_line(i32 l) {
    return wrap_row_of_line_at(wrap_cols(), l);
}

// the same at another width, which the scroll may have been set at
i32 wrap_row_of_line_at(i32 cols, i32 l) {
    WrapCache* c = wrap_slot(cols);
    if l < 0 { return 0; }
    if l > c.n { l = c.n; }
    wrap_sum(c, l);
    return c.pre[l];
}

// every row of the buffer
i32 wrap_total() {
    WrapCache* c = wrap_slot(wrap_cols());
    wrap_sum(c, c.n);
    return c.pre[c.n];
}

// the line row r is on
i32 wrap_line_of_row(i32 r) {
    return wrap_line_of_row_at(wrap_cols(), r);
}

i32 wrap_line_of_row_at(i32 cols, i32 r) {
    WrapCache* c = wrap_slot(cols);
    wrap_sum(c, c.n);
    if c.n == 0 { return 0; }
    if r < 0 { return 0; }
    if r >= c.pre[c.n] { return c.n - 1; }
    i32 lo = 0;
    i32 hi = c.n - 1;
    while lo < hi {
        i32 mid = (lo + hi + 1) / 2;
        if c.pre[mid] <= r { lo = mid; } else { hi = mid - 1; }
    }
    return lo;
}

// Line l's rows, made current in the line cache: the row count. Read
// them with wrap_row_start, wrap_row_v0 and wrap_indent.
i32 wrap_line(i32 l) {
    i32 cols = wrap_cols();
    if wl_line == l && wl_cols == cols && wl_stamp == wrap_gen { return wl_n; }
    i32 n = line_bytes(l);
    i32 ind = 0;
    i32 rows = wrap_scan(g_linebuf, n, cols, null, null, 0, &ind);
    if rows + 1 > wl_cap {
        if wl_start != null { free(wl_start); }
        if wl_v0 != null { free(wl_v0); }
        wl_cap = rows + 64;
        wl_start = alloc<i32>(wl_cap);
        wl_v0 = alloc<i32>(wl_cap);
    }
    wl_start[0] = 0;
    wl_v0[0] = 0;
    if rows > 1 { ignore wrap_scan(g_linebuf, n, cols, wl_start, wl_v0, rows, &ind); }
    wl_start[rows] = n;
    wl_n = rows;
    wl_ind = ind;
    wl_line = l;
    wl_cols = cols;
    wl_stamp = wrap_gen;
    return rows;
}

// after wrap_line: the byte row k starts at; k == rows gives the end
i32 wrap_row_start(i32 k) {
    if k < 0 { return 0; }
    if k >= wl_n { return wl_start[wl_n]; }
    return wl_start[k];
}

// after wrap_line: the visual column row k starts at
i32 wrap_row_v0(i32 k) {
    if k <= 0 { return 0; }
    if k >= wl_n { k = wl_n - 1; }
    return wl_v0[k];
}

// after wrap_line: the cells before row k's text, its indent
i32 wrap_row_lead(i32 k) {
    if k <= 0 { return 0; }
    return wl_ind;
}

// after wrap_line: the row byte column col is on. A column at a break is
// on the row the break starts.
i32 wrap_row_of_col(i32 col) {
    i32 k = 0;
    while k + 1 < wl_n && wl_start[k + 1] <= col { k++; }
    return k;
}

// The cached rows against a count from scratch, for the harnesses: true
// when every line's count and every sum is what the text gives now.
bool wrap_verify() {
    WrapCache* c = wrap_slot(wrap_cols());
    wrap_sum(c, c.n);
    i32 acc = 0;
    for i32 l = 0; l < c.n; l++ {
        if c.pre[l] != acc { return false; }
        i32 n = line_bytes(l);
        i32 ind = 0;
        i32 rows = wrap_scan(g_linebuf, n, c.cols, null, null, 0, &ind);
        if c.cnt[l] != rows { return false; }
        acc += rows;
    }
    return c.pre[c.n] == acc;
}

// The text buffer's edit report for the loaded buffer: at line `at`,
// `removed` lines went and `added` came. The counts under the edit move
// with their lines, and the edited lines are counted again when asked.
void wrap_note_edit(i32 at, i32 removed, i32 added) {
    wrap_gen++;
    for i32 s = 0; s < WRAP_SLOTS; s++ {
        WrapCache* c = &g_wrap_c[s];
        if c.cols == 0 || c.n < 0 { continue; }
        i32 nn = c.n - removed + added;
        if at < 0 || at >= c.n || at + removed >= c.n + 1 || nn != tb.nlines {
            c.n = -1;
            continue;
        }
        if nn + 1 > c.cap {
            i32 ncap = nn + nn / 2 + 64;
            i32* nc = alloc<i32>(ncap);
            memcpy(nc, c.cnt, c.n * sizeof(i32));
            free(c.cnt);
            free(c.pre);
            c.cnt = nc;
            c.pre = alloc<i32>(ncap + 1);
            c.cap = ncap;
            c.pre[0] = 0;
            c.pre_ok = 0;
        }
        i32 old_i = at + 1 + removed;   // the first line after the edit, as it was
        i32 new_i = at + 1 + added;     // where it is now
        i32 tail = c.n - old_i;
        if new_i > old_i {
            for i32 i = tail - 1; i >= 0; i-- { c.cnt[new_i + i] = c.cnt[old_i + i]; }
        } else if new_i < old_i {
            for i32 i = 0; i < tail; i++ { c.cnt[new_i + i] = c.cnt[old_i + i]; }
        }
        c.n = nn;
        for i32 l = at; l <= at + added && l < nn; l++ { c.cnt[l] = 0; }
        if c.pre_ok > at { c.pre_ok = at; }
    }
}
