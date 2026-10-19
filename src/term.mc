// term.mc - the terminal: a VT emulator over a screen grid, and the
// byte plumbing that feeds it.
//
// Three things live here. The plumbing is one pseudo-terminal per
// handle, a reader thread filling a queue and posting the wake, and a
// writer thread so a key press never waits on a full pipe; its shape
// is src/lsp.mc's, which already solved both directions. The screen is
// a grid of cells with a scrollback ring and an alternate screen, not
// a text buffer: a terminal overwrites cells in place and nothing but
// the grid is state. The parser is the DEC state machine over the
// bytes, so a sequence split across two reads parses the same as one
// that arrives whole.
//
// A burst of output is many reads and one frame: the queue coalesces
// because the main thread drains it when the loop gets to it, not per
// chunk, which is what keeps one-frame latency under a fast child.
//
// What is modelled is the sequence set today's shells, vim, less, git
// and Claude Code emit, and nothing older (doc/TECH_DOC.md,
// "Terminal"). Everything unrecognized is parsed to completion and dropped,
// never left half-consumed: a program outside the set loses a feature,
// not the screen.

// Test seam: the harnesses stub the platform, so a real thread would
// take their bytes off the synchronous path. They set this false and
// read and write inline, as lsp_threaded does. The browser has no
// threads and no pty either, so it never reaches any of it.
bool term_threaded = true;

private const i32 TERM_READ_CAP = 65536;
// The reference keeps a thousand lines; this keeps two thousand. A
// ring, so the memory is bounded: at 200 columns that is 6.4 MB, and a
// real pane is narrower. It is allocated when the first line scrolls
// off, not before.
const i32 TERM_SCROLLBACK = 2000;

private const i32 TERM_PARAM_MAX = 16;
private const i32 TERM_STR_MAX = 512;   // an OSC string, past that it is dropped
private const i32 TERM_TITLE_MAX = 256;

// cell attributes
const u16 TA_BOLD = 1;
const u16 TA_DIM = 2;
const u16 TA_ITALIC = 4;
const u16 TA_UNDER = 8;
const u16 TA_BLINK = 16;      // kept, never drawn: a blinking cell would
                              // wake the idle editor twice a second
const u16 TA_INVERSE = 32;
const u16 TA_HIDDEN = 64;
const u16 TA_STRIKE = 128;
const u16 TA_WIDE = 256;      // left half of a two-cell glyph
const u16 TA_TAIL = 512;      // its right half, which draws nothing
const u16 TA_WRAP = 1024;     // on a row's last cell: the line goes on in the next row

// A cell's color, when the child has not named one. Alpha zero is not
// a color any palette entry or truecolor sequence can produce, so the
// frame builder can tell "default" from "black" and put the editor's
// own foreground and background there.
const u32 TERM_DEFAULT = 0;

// cursor shapes, DECSCUSR
const i32 TERM_CUR_BLOCK = 0;
const i32 TERM_CUR_UNDER = 1;
const i32 TERM_CUR_BAR = 2;

struct TermCell {
    u32 cp;      // the codepoint, 0 for blank; a cluster's first one
    u32 fg;
    u32 bg;
    u16 attr;
    u16 ext;     // 1 + the slot of the cell's cluster bytes, 0 for a lone codepoint
}

// A cell's grapheme cluster (an emoji with a variation selector, a skin
// tone, a keycap, a flag's two indicators, a ZWJ sequence, a combining
// mark on a letter) is kept as bytes in a slot table per terminal, the
// cell pointing at its slot: the cell stays four words and a cluster
// stays whole for the shaper, the copy and the dump. The slots rotate,
// so the oldest cluster goes when the table is full, which is a line
// long since scrolled away.
private const i32 TERM_CLUS_MAX = 4096;
private const i32 TERM_CLUS_BYTES = 48;   // one length byte, then the bytes

// parser states, the DEC-compatible machine
private const i32 TS_GROUND = 0;
private const i32 TS_ESC = 1;
private const i32 TS_ESC_INT = 2;
private const i32 TS_CSI = 3;
private const i32 TS_CSI_IGNORE = 4;
private const i32 TS_OSC = 5;
private const i32 TS_OSC_ESC = 6;
private const i32 TS_STR = 7;        // DCS/APC/PM/SOS: swallowed to ST
private const i32 TS_STR_ESC = 8;

private struct Term {
    bool used;
    i32 pty;           // the platform's handle, -1 for a screen with no child

    // --- the screen
    i32 cols;
    i32 rows;
    TermCell* cells;   // rows * cols, the screen in use
    TermCell* other;   // the one not in use (primary while alt is up)
    TermCell* ring;    // TERM_SCROLLBACK * cols, allocated on the first scroll
    i32 ring_head;     // where the next line goes
    i32 ring_n;        // lines in it
    i64 pushed;        // lines ever pushed into it: the screen's top row is absolute line `pushed`
    i32 view;          // lines scrolled up into the ring, 0 = live

    i32 cx;
    i32 cy;
    bool wrap_next;    // the cursor is past the last column, waiting to wrap
    u16 attr;
    u32 fg;
    u32 bg;

    i32 scr_top;       // scroll region, inclusive, 0-based
    i32 scr_bot;

    // saved cursor (DECSC / DECRC), and the primary's while alt is up
    i32 sv_x;
    i32 sv_y;
    u16 sv_attr;
    u32 sv_fg;
    u32 sv_bg;
    i32 alt_x;
    i32 alt_y;

    bool m_wrap;       // 7, on by default
    bool m_origin;     // 6
    bool m_appcursor;  // 1
    bool m_appkeypad;  // keypad application mode, ESC = / ESC >
    bool m_alt;        // 1049
    bool m_bracket;    // 2004
    bool m_focus;      // 1004
    bool m_cur_vis;    // 25
    i32 m_mouse;       // 0 none, 1000 click, 1002 drag
    bool m_sgr_mouse;  // 1006
    i32 cur_shape;

    bool* tabs;        // cols wide

    u8* clus;          // TERM_CLUS_MAX slots of TERM_CLUS_BYTES, on the first cluster
    i32 clus_next;

    u8[TERM_TITLE_MAX] title;
    i32 title_len;
    i32 num;           // the shell's running number, from 1; 0 for a command's

    // --- the parser
    i32 state;
    i32[TERM_PARAM_MAX] param;
    bool[TERM_PARAM_MAX] psub;   // the parameter came after a colon: a sub-parameter of the one before
    i32 nparam;
    bool priv;         // the sequence carried ? < = or >
    u8 inter;          // the last intermediate byte, 0 for none
    u8[TERM_STR_MAX] strbuf;
    i32 str_len;
    u8[4] utf;         // a codepoint split across two feeds
    i32 utf_len;

    // --- the channel
    Mutex mx;          // the inbound queue and the flags
    u8* q;
    i64 q_len;
    i64 q_cap;
    bool exited;
    i32 code;
    Semaphore rsem;    // one signal per queue append and at the exit, for a headless wait

    // the child's bytes kept aside, raw, for a reader other than the
    // screen (the build's problems parser); main thread only
    bool tap;
    u8* tapq;
    i64 tapq_len;
    i64 tapq_cap;

    Mutex wmx;         // the outbound queue
    Semaphore wsem;
    u8* wq;
    i64 wq_len;
    i64 wq_cap;
    bool wstop;

    Thread rthread;
    Thread wthread;
    bool rthread_up;
    bool wthread_up;
}

private Term[TERM_MAX] g_t;
// a thread entry takes a void*, so each one points at its own index
private i32[TERM_MAX] g_t_idx;
private bool g_t_ready = false;
private i32 g_t_seq = 0;   // shells opened so far: the next one's number

private void tc_init() {
    if g_t_ready { return; }
    g_t_ready = true;
    for i32 i = 0; i < TERM_MAX; i++ {
        mutex_init(&g_t[i].mx);
        mutex_init(&g_t[i].wmx);
        g_t_idx[i] = i;
        when !os(wasm) {
            sem_init(&g_t[i].wsem, 0);
            sem_init(&g_t[i].rsem, 0);
        }
    }
}

private bool term_has(i32 t) {
    return t >= 0 && t < TERM_MAX && g_t[t].used;
}

// --- the channel ------------------------------------------------------

// caller holds the matching mutex
private void tc_grow(u8** q, i64* len, i64* cap, u8* p, i64 n) {
    if *len + n > *cap {
        i64 ncap = *cap * 2 + n + 65536;
        u8* nq = alloc<u8>(ncap);
        if *q != null {
            memcpy(nq, *q, *len);
            free(*q);
        }
        *q = nq;
        *cap = ncap;
    }
    memcpy(*q + *len, p, n);
    *len += n;
}

when !os(wasm) {

private void term_reader(void* arg) {
    i32 t = *cast(i32*, arg);
    noinit u8[TERM_READ_CAP] buf;
    while true {
        i64 n = plat_term_read(g_t[t].pty, &buf[0], cast(i64, TERM_READ_CAP));
        if n <= 0 { break; }
        mutex_lock(&g_t[t].mx);
        tc_grow(&g_t[t].q, &g_t[t].q_len, &g_t[t].q_cap, &buf[0], n);
        mutex_unlock(&g_t[t].mx);
        sem_signal(&g_t[t].rsem);
        plat_wake();
    }
    mutex_lock(&g_t[t].mx);
    g_t[t].exited = true;
    mutex_unlock(&g_t[t].mx);
    sem_signal(&g_t[t].rsem);
    plat_wake();
}

private void term_writer(void* arg) {
    i32 t = *cast(i32*, arg);
    while true {
        sem_wait(&g_t[t].wsem);
        mutex_lock(&g_t[t].wmx);
        u8* q = g_t[t].wq;
        i64 n = g_t[t].wq_len;
        g_t[t].wq = null;
        g_t[t].wq_len = 0;
        g_t[t].wq_cap = 0;
        bool stop = g_t[t].wstop;
        mutex_unlock(&g_t[t].wmx);
        if q != null {
            // blocking is what this thread is for
            ignore plat_term_write(g_t[t].pty, q, n);
            free(q);
        }
        if stop { break; }
    }
}

}

// Bytes to the child, through the writer thread: a key press never
// waits on a full pipe.
void term_send(i32 t, u8* p, i64 n) {
    if !term_has(t) || n <= 0 { return; }
    if g_t[t].pty < 0 { return; }
    when !os(wasm) {
        if term_threaded {
            mutex_lock(&g_t[t].wmx);
            tc_grow(&g_t[t].wq, &g_t[t].wq_len, &g_t[t].wq_cap, p, n);
            mutex_unlock(&g_t[t].wmx);
            sem_signal(&g_t[t].wsem);
            return;
        }
    }
    ignore plat_term_write(g_t[t].pty, p, n);
}

private void term_send_str(i32 t, str s) {
    term_send(t, s.data, cast(i64, s.len));
}

// --- the grid ---------------------------------------------------------

private TermCell term_blank(i32 t) {
    TermCell c;
    c.cp = 0;
    c.fg = g_t[t].fg;
    c.bg = g_t[t].bg;
    c.attr = 0;
    c.ext = 0;
    return c;
}

// --- clusters -------------------------------------------------------------

// the cell's bytes: its cluster, else its codepoint alone; the count
private i32 term_clus_bytes(i32 t, TermCell* c, u8* out) {
    if c.ext != 0 && g_t[t].clus != null {
        u8* slot = g_t[t].clus + cast(i64, c.ext - 1) * cast(i64, TERM_CLUS_BYTES);
        i32 n = cast(i32, slot[0]);
        if n > 0 && n < TERM_CLUS_BYTES {
            memcpy(out, slot + 1, n);
            return n;
        }
    }
    u32 cp = c.cp;
    if cp == 0 { cp = 32; }
    return utf8_encode(cp, out);
}

private void term_clus_set(i32 t, TermCell* c, u8* bytes, i32 n) {
    if n <= 0 || n >= TERM_CLUS_BYTES { return; }
    if g_t[t].clus == null {
        g_t[t].clus = alloc<u8>(cast(i64, TERM_CLUS_MAX) * cast(i64, TERM_CLUS_BYTES));
        g_t[t].clus_next = 0;
    }
    i32 slot = g_t[t].clus_next;
    g_t[t].clus_next = (slot + 1) % TERM_CLUS_MAX;
    u8* p = g_t[t].clus + cast(i64, slot) * cast(i64, TERM_CLUS_BYTES);
    p[0] = cast(u8, n);
    memcpy(p + 1, bytes, n);
    c.ext = cast(u16, slot + 1);
}

// a combining mark: it rides on the cell before it
private bool term_cp_combining(u32 cp) {
    return (cp >= 0x0300 && cp <= 0x036F) || (cp >= 0x1AB0 && cp <= 0x1AFF)
        || (cp >= 0x1DC0 && cp <= 0x1DFF) || (cp >= 0x20D0 && cp <= 0x20FF)
        || (cp >= 0xFE20 && cp <= 0xFE2F);
}

// A codepoint that continues the cluster in the cell just written: a
// variation selector, a ZWJ and what follows one, a skin tone, a keycap,
// a tag, a flag's second indicator, a combining mark. The cell's bytes
// grow, its width follows the editor's cluster rules, and a cell that
// turns wide takes the next cell as its tail. False when the codepoint
// is a cell of its own.
private bool term_extend(i32 t, u32 cp) {
    bool joiner = cp == CP_VS16 || cp == CP_VS15 || cp == CP_ZWJ || cp == CP_KEYCAP
        || cp_emoji_mod(cp) || cp_tag(cp) || cp_ri(cp) || term_cp_combining(cp)
        || cp_emoji_base(cp);   // only after a ZWJ, checked below
    if !joiner { return false; }
    i32 cols = g_t[t].cols;
    i32 x = g_t[t].cx - 1;
    if g_t[t].wrap_next { x = g_t[t].cx; }
    if x < 0 { return false; }
    TermCell* row = &g_t[t].cells[g_t[t].cy * cols];
    if (row[x].attr & TA_TAIL) != 0 { x--; }
    if x < 0 || row[x].cp == 0 { return false; }
    noinit u8[TERM_CLUS_BYTES + 8] b;
    i32 n = term_clus_bytes(t, &row[x], &b[0]);
    if n + 4 >= TERM_CLUS_BYTES { return false; }
    // a joiner joins only what it may: a ZWJ must follow an emoji, a
    // follower must follow a ZWJ, a second indicator a lone first one
    u32 last = 0;
    i32 lscan = 0;
    while lscan < n { last = utf8_next(&b[0], n, &lscan); }
    bool base_emoji = cp_emoji_base(row[x].cp) || cp_ri(row[x].cp);
    if cp_emoji_mod(cp) {
        if !base_emoji { return false; }              // a skin tone needs an emoji
    } else if cp_ri(cp) {
        if !(cp_ri(row[x].cp) && row[x].ext == 0) { return false; }   // only a lone indicator takes a second
    } else if cp == CP_ZWJ {
        if !base_emoji { return false; }
    } else if cp_emoji_base(cp) {
        if last != CP_ZWJ { return false; }           // an emoji after no joiner is its own cell
    }
    i32 enc = utf8_encode(cp, &b[n]);
    i32 total = n + enc;
    i32 i = 0;
    i32 w = grapheme_next_w(&b[0], total, &i);
    i32 have = 1;
    if (row[x].attr & TA_WIDE) != 0 { have = 2; }
    if i != total {
        // not one cluster by the rules: a joiner waiting for its
        // follower, or a mark on a plain letter, still rides along
        if cp == CP_ZWJ || cp == CP_VS16 || cp == CP_VS15 || term_cp_combining(cp) { w = have; }
        else { return false; }
    }
    term_clus_set(t, &row[x], &b[0], total);
    if w == 2 && have == 1 && x + 1 < cols {
        // the cell turns wide: the next cell is its tail, and a cursor
        // sitting there steps past it
        row[x].attr = row[x].attr | TA_WIDE;
        TermCell tail = row[x];
        tail.cp = 0;
        tail.ext = 0;
        tail.attr = (row[x].attr & ~TA_WIDE) | TA_TAIL;
        if (row[x + 1].attr & TA_WIDE) != 0 && x + 2 < cols {
            row[x + 2].attr = row[x + 2].attr & ~TA_TAIL;
            row[x + 2].cp = 0;
        }
        row[x + 1] = tail;
        if !g_t[t].wrap_next && g_t[t].cx == x + 1 {
            g_t[t].cx = x + 2;
            if g_t[t].cx >= cols {
                g_t[t].cx = cols - 1;
                g_t[t].wrap_next = true;
            }
        }
    }
    return true;
}

// a decoded codepoint: onto the cell before it when it continues that
// cell's cluster, else a cell of its own
private void term_put_cp(i32 t, u32 cp) {
    if term_extend(t, cp) { return; }
    term_put(t, cp, cp_width(cp));
}

// A two-cell glyph is two cells, and anything that moves or clears one
// of them leaves the other half of a glyph that is no longer there.
// Every operation that can break a pair ends here, which is what keeps
// the pair invariant true whatever the child sent.
private void term_row_fix(i32 t, TermCell* row) {
    i32 cols = g_t[t].cols;
    for i32 x = 0; x < cols; x++ {
        if (row[x].attr & TA_WIDE) != 0 {
            if x + 1 >= cols || (row[x + 1].attr & TA_TAIL) == 0 {
                row[x].attr = row[x].attr & ~TA_WIDE;
            }
        }
        if (row[x].attr & TA_TAIL) != 0 {
            if x == 0 || (row[x - 1].attr & TA_WIDE) == 0 {
                row[x].attr = row[x].attr & ~TA_TAIL;
                row[x].cp = 0;
            }
        }
        // the wrap flag names the row's last cell; a cell moved away
        // from there (a padded row, an inserted cell) is not one
        if x < cols - 1 && (row[x].attr & TA_WRAP) != 0 {
            row[x].attr = row[x].attr & ~TA_WRAP;
        }
    }
}

private void term_clear_row(i32 t, TermCell* row, i32 x0, i32 x1) {
    TermCell b = term_blank(t);
    for i32 x = x0; x <= x1; x++ { row[x] = b; }
    term_row_fix(t, row);
}

private void term_clear_rows(i32 t, i32 y0, i32 y1) {
    for i32 y = y0; y <= y1; y++ {
        term_clear_row(t, &g_t[t].cells[y * g_t[t].cols], 0, g_t[t].cols - 1);
    }
}

// One line into the scrollback. Only the primary screen has one, and
// only when the whole screen is scrolling: a program that set a scroll
// region is animating inside it, and those lines are not history.
private void term_ring_push(i32 t, TermCell* row) {
    if g_t[t].m_alt { return; }
    if g_t[t].ring == null {
        g_t[t].ring = alloc<TermCell>(cast(i64, TERM_SCROLLBACK) * cast(i64, g_t[t].cols));
        g_t[t].ring_head = 0;
        g_t[t].ring_n = 0;
    }
    memcpy(&g_t[t].ring[g_t[t].ring_head * g_t[t].cols], row,
        cast(i64, g_t[t].cols) * cast(i64, sizeof(TermCell)));
    g_t[t].ring_head = (g_t[t].ring_head + 1) % TERM_SCROLLBACK;
    if g_t[t].ring_n < TERM_SCROLLBACK { g_t[t].ring_n++; }
    g_t[t].pushed++;
    // the view is an offset into history, so it moves with the history
    if g_t[t].view > 0 && g_t[t].view < g_t[t].ring_n { g_t[t].view++; }
}

// screen row `src` over row `dst`
private void term_row_copy(i32 t, i32 dst, i32 src) {
    memcpy(&g_t[t].cells[dst * g_t[t].cols], &g_t[t].cells[src * g_t[t].cols],
        cast(i64, g_t[t].cols) * cast(i64, sizeof(TermCell)));
}

// Scroll the region up by n, which is what a newline at the bottom
// does; the lines leaving the top go to the scrollback when the region
// is the whole screen.
private void term_scroll_up(i32 t, i32 n) {
    i32 top = g_t[t].scr_top;
    i32 bot = g_t[t].scr_bot;
    i32 h = bot - top + 1;
    if n > h { n = h; }
    if n <= 0 { return; }
    bool whole = top == 0 && bot == g_t[t].rows - 1;
    for i32 i = 0; i < n; i++ {
        if whole { term_ring_push(t, &g_t[t].cells[(top + i) * g_t[t].cols]); }
    }
    for i32 y = top; y <= bot - n; y++ {
        term_row_copy(t, y, y + n);
    }
    term_clear_rows(t, bot - n + 1, bot);
}

private void term_scroll_down(i32 t, i32 n) {
    i32 top = g_t[t].scr_top;
    i32 bot = g_t[t].scr_bot;
    i32 h = bot - top + 1;
    if n > h { n = h; }
    if n <= 0 { return; }
    for i32 y = bot; y >= top + n; y-- {
        term_row_copy(t, y, y - n);
    }
    term_clear_rows(t, top, top + n - 1);
}

private void term_tabs_reset(i32 t) {
    for i32 i = 0; i < g_t[t].cols; i++ { g_t[t].tabs[i] = (i % 8) == 0 && i > 0; }
}

// --- lifecycle --------------------------------------------------------

private void term_reset(i32 t, i32 cols, i32 rows) {
    g_t[t].cols = cols;
    g_t[t].rows = rows;
    g_t[t].cx = 0;
    g_t[t].cy = 0;
    g_t[t].wrap_next = false;
    g_t[t].attr = 0;
    g_t[t].fg = TERM_DEFAULT;
    g_t[t].bg = TERM_DEFAULT;
    g_t[t].scr_top = 0;
    g_t[t].scr_bot = rows - 1;
    g_t[t].sv_x = 0;
    g_t[t].sv_y = 0;
    g_t[t].sv_attr = 0;
    g_t[t].sv_fg = TERM_DEFAULT;
    g_t[t].sv_bg = TERM_DEFAULT;
    g_t[t].m_wrap = true;
    g_t[t].m_origin = false;
    g_t[t].m_appcursor = false;
    g_t[t].m_appkeypad = false;
    g_t[t].m_bracket = false;
    g_t[t].m_focus = false;
    g_t[t].m_cur_vis = true;
    g_t[t].m_mouse = 0;
    g_t[t].m_sgr_mouse = false;
    g_t[t].cur_shape = TERM_CUR_BLOCK;
    g_t[t].state = TS_GROUND;
    g_t[t].nparam = 0;
    g_t[t].priv = false;
    g_t[t].inter = 0;
    g_t[t].str_len = 0;
    g_t[t].utf_len = 0;
    g_t[t].view = 0;
}

// A screen with no child behind it: the harness drives one of these
// through term_feed, and every check in ed_test is one.
i32 term_new(i32 cols, i32 rows) {
    tc_init();
    if cols < 1 { cols = 1; }
    if rows < 1 { rows = 1; }
    i32 t = -1;
    for i32 i = 0; i < TERM_MAX; i++ {
        if !g_t[i].used {
            t = i;
            break;
        }
    }
    if t < 0 { return -1; }
    g_t[t].used = true;
    g_t[t].pty = -1;
    g_t[t].exited = false;
    g_t[t].code = -1;
    g_t[t].title_len = 0;
    g_t[t].m_alt = false;
    g_t[t].ring = null;
    g_t[t].ring_head = 0;
    g_t[t].ring_n = 0;
    g_t[t].pushed = 0;
    i64 n = cast(i64, cols) * cast(i64, rows);
    g_t[t].cells = alloc<TermCell>(n);
    g_t[t].other = alloc<TermCell>(n);
    g_t[t].tabs = alloc<bool>(cast(i64, cols));
    term_reset(t, cols, rows);
    term_tabs_reset(t);
    term_clear_rows(t, 0, rows - 1);
    for i64 i = 0; i < n; i++ { g_t[t].other[i] = term_blank(t); }
    return t;
}

// Open a shell behind a pty of that cell size. The handle, or -1 when
// the platform has none: the browser, a Windows without ConPTY, no
// pwsh installed. The caller says so in the pane rather than retrying.
i32 term_open(i32 cols, i32 rows) {
    return term_spawn_in(cols, rows, null, 0, false);
}

// The same on a screen that already holds text, which is a restart that
// could not hand the old shell over: the new one comes up under what
// the old one said instead of clearing it away. The text goes in after
// this call and before the first pump, so the host's question about the
// cursor is answered with the line under the text.
i32 term_open_under(i32 cols, i32 rows) {
    return term_spawn_in(cols, rows, null, 0, true);
}

// The same with a command instead of the shell (the build): the words
// become the title, since nothing in a compiler sets one.
i32 term_open_cmd(i32 cols, i32 rows, str* argv, i32 argc) {
    return term_spawn_in(cols, rows, argv, argc, false);
}

// terminal t over pty handle h, its writer and tap state fresh
private void term_attach(i32 t, i32 h) {
    g_t[t].pty = h;
    g_t[t].wstop = false;
    g_t[t].tap = false;
    g_t[t].tapq = null;
    g_t[t].tapq_len = 0;
    g_t[t].tapq_cap = 0;
    g_t[t].title_len = 0;
}

// the reader and writer threads for terminal t's pty
private void term_threads_start(i32 t) {
    when !os(wasm) {
        if term_threaded {
            thread_create(&g_t[t].wthread, term_writer, cast(void*, &g_t_idx[t]));
            g_t[t].wthread_up = true;
            thread_create(&g_t[t].rthread, term_reader, cast(void*, &g_t_idx[t]));
            g_t[t].rthread_up = true;
        }
    }
}

private i32 term_spawn_in(i32 cols, i32 rows, str* argv, i32 argc, bool under) {
    i32 t = term_new(cols, rows);
    if t < 0 { return -1; }
    i32 h = plat_term_spawn(cols, rows, argv, argc, under);
    if h < 0 {
        term_close(t);
        return -1;
    }
    term_attach(t, h);
    g_t[t].num = 0;
    if argc == 0 {
        g_t_seq++;
        g_t[t].num = g_t_seq;
    }
    for i32 i = 0; i < argc; i++ {
        if g_t[t].title_len > 0 && g_t[t].title_len < TERM_TITLE_MAX {
            g_t[t].title[g_t[t].title_len] = ' ';
            g_t[t].title_len++;
        }
        i64 n = argv[i].len;
        if g_t[t].title_len + n > TERM_TITLE_MAX { n = TERM_TITLE_MAX - g_t[t].title_len; }
        memcpy(&g_t[t].title[g_t[t].title_len], argv[i].data, n);
        g_t[t].title_len += cast(i32, n);
    }
    term_threads_start(t);
    return t;
}

// A terminal over a pty and child the previous process handed over (the
// restart): the screen is new, the child is the one that was there.
i32 term_adopt(i64 fd, i32 pid, i32 cols, i32 rows) {
    i32 t = term_new(cols, rows);
    if t < 0 { return -1; }
    i32 h = plat_term_adopt(fd, pid);
    if h < 0 {
        term_close(t);
        return -1;
    }
    term_attach(t, h);
    g_t_seq++;
    g_t[t].num = g_t_seq;
    term_threads_start(t);
    return t;
}

// the pty end and child of a terminal, made to survive the exec
bool term_export(i32 t, i64* fd, i32* pid) {
    if !term_has(t) || g_t[t].pty < 0 { return false; }
    return plat_term_export(g_t[t].pty, fd, pid);
}

// a size change and back: a full-screen child repaints on it, which
// is how it comes back whole after a handover (the screen's text was
// re-fed, its colors were not)
void term_nudge(i32 t) {
    if !term_has(t) || g_t[t].pty < 0 { return; }
    plat_term_resize(g_t[t].pty, g_t[t].cols + 1, g_t[t].rows);
    plat_term_resize(g_t[t].pty, g_t[t].cols, g_t[t].rows);
}

// The child, and on Windows every process it started, end now. The
// terminal and its screen stay: the reader gets its end of file and
// the terminal shows as exited. A later close kills again, which the
// platforms take as nothing more to do.
void term_stop(i32 t) {
    if !term_has(t) || g_t[t].pty < 0 { return; }
    plat_term_kill(g_t[t].pty);
}

void term_close(i32 t) {
    if !term_has(t) { return; }
    g_t[t].used = false;
    if g_t[t].pty >= 0 {
        // the kill ends the child and the pty, which gives the reader its
        // end of file and fails the writer out of a blocked write; the
        // handle itself is released after both threads have gone
        plat_term_kill(g_t[t].pty);
        when !os(wasm) {
            if g_t[t].wthread_up {
                g_t[t].wthread_up = false;
                mutex_lock(&g_t[t].wmx);
                g_t[t].wstop = true;
                mutex_unlock(&g_t[t].wmx);
                sem_signal(&g_t[t].wsem);
                thread_join(&g_t[t].wthread);
            }
            if g_t[t].rthread_up {
                thread_join(&g_t[t].rthread);
                g_t[t].rthread_up = false;
            }
        }
        plat_term_free(g_t[t].pty);
        g_t[t].pty = -1;
    }
    mutex_lock(&g_t[t].wmx);
    if g_t[t].wq != null {
        free(g_t[t].wq);
        g_t[t].wq = null;
    }
    g_t[t].wq_len = 0;
    g_t[t].wq_cap = 0;
    mutex_unlock(&g_t[t].wmx);
    mutex_lock(&g_t[t].mx);
    if g_t[t].q != null {
        free(g_t[t].q);
        g_t[t].q = null;
    }
    g_t[t].q_len = 0;
    g_t[t].q_cap = 0;
    mutex_unlock(&g_t[t].mx);
    if g_t[t].tapq != null {
        free(g_t[t].tapq);
        g_t[t].tapq = null;
    }
    g_t[t].tapq_len = 0;
    g_t[t].tapq_cap = 0;
    g_t[t].tap = false;
    if g_t[t].cells != null {
        free(g_t[t].cells);
        g_t[t].cells = null;
    }
    if g_t[t].other != null {
        free(g_t[t].other);
        g_t[t].other = null;
    }
    if g_t[t].ring != null {
        free(g_t[t].ring);
        g_t[t].ring = null;
    }
    if g_t[t].tabs != null {
        free(g_t[t].tabs);
        g_t[t].tabs = null;
    }
    if g_t[t].clus != null {
        free(g_t[t].clus);
        g_t[t].clus = null;
    }
    g_t[t].clus_next = 0;
}

void term_close_all() {
    if !g_t_ready { return; }
    for i32 i = 0; i < TERM_MAX; i++ { term_close(i); }
}

// Copy a grid into one of another size: rows keep their place from the
// bottom, longer lines are cut and shorter ones padded.
private void term_regrid(i32 t, TermCell* src, i32 ocols, i32 orows,
    TermCell* dst, i32 ncols, i32 nrows, i32 drop) {
    TermCell b = term_blank(t);
    i32 save = g_t[t].cols;
    g_t[t].cols = ncols;
    for i32 y = 0; y < nrows; y++ {
        i32 sy = y + drop;
        for i32 x = 0; x < ncols; x++ {
            if sy >= 0 && sy < orows && x < ocols {
                dst[y * ncols + x] = src[sy * ocols + x];
            } else {
                dst[y * ncols + x] = b;
            }
        }
        term_row_fix(t, &dst[y * ncols]);
    }
    g_t[t].cols = save;
}

// Whether a cell shows anything: a glyph, a colored background, or a
// line drawn through where a glyph would be.
private bool term_cell_ink(TermCell* c) {
    if c.cp != 0 && c.cp != 32 { return true; }
    if c.bg != TERM_DEFAULT { return true; }
    return (c.attr & (TA_UNDER | TA_STRIKE | TA_INVERSE)) != 0;
}

// The primary's history and screen as one sequence of rows: the ring's
// lines oldest first, then the screen's rows.
private TermCell* term_seq_row(i32 t, i32 i) {
    if i < g_t[t].ring_n {
        i32 idx = g_t[t].ring_head - g_t[t].ring_n + i;
        while idx < 0 { idx += TERM_SCROLLBACK; }
        return &g_t[t].ring[idx * g_t[t].cols];
    }
    return &g_t[t].cells[(i - g_t[t].ring_n) * g_t[t].cols];
}

// the rows a reflow builds, one open at the end being filled
private struct Reflow {
    TermCell* rows;
    i32 n;        // rows closed; row n is the open one
    i32 cap;
    i32 col;      // the fill position in the open row
    i32 ncols;
    TermCell blank;
}

private TermCell* rf_open(Reflow* rf) {
    if rf.n >= rf.cap {
        i32 cap = rf.cap * 2;
        if cap < 64 { cap = 64; }
        TermCell* nr = alloc<TermCell>(cast(i64, cap) * cast(i64, rf.ncols));
        if rf.rows != null {
            memcpy(nr, rf.rows, cast(i64, rf.n) * cast(i64, rf.ncols) * cast(i64, sizeof(TermCell)));
            free(rf.rows);
        }
        rf.rows = nr;
        rf.cap = cap;
    }
    return &rf.rows[rf.n * rf.ncols];
}

// close the open row: blank to the end, the wrap flag when the line
// goes on in the next one
private void rf_close(Reflow* rf, bool wrap) {
    TermCell* row = rf_open(rf);
    for i32 x = rf.col; x < rf.ncols; x++ { row[x] = rf.blank; }
    if wrap { row[rf.ncols - 1].attr = row[rf.ncols - 1].attr | TA_WRAP; }
    rf.n++;
    rf.col = 0;
}

// Re-wrap the primary screen and its history to a new width: the rows
// a line was wrapped into (TA_WRAP) are joined and cut again at the
// new edge, a wide glyph never split. The screen's empty bottom (the
// rows below the cursor and below the last ink) is kept out of the
// sequence and given back as far as the screen has room, so a prompt
// near the top stays near the top; what does not fit goes to the ring,
// and a taller screen takes lines back out of it. The cursor follows
// the cell it was on.
private void term_reflow(i32 t, i32 ncols, i32 nrows) {
    i32 ocols = g_t[t].cols;
    i32 orows = g_t[t].rows;
    i32 oring = g_t[t].ring_n;
    i32 total = oring + orows;
    i32 crow = oring + g_t[t].cy;
    i32 last = crow;
    for i32 i = total - 1; i > last; i-- {
        TermCell* r = term_seq_row(t, i);
        bool ink = false;
        for i32 x = 0; x < ocols; x++ { if term_cell_ink(&r[x]) { ink = true; break; } }
        if ink { last = i; break; }
    }
    i32 trailing = total - 1 - last;

    Reflow rf;
    rf.rows = null;
    rf.n = 0;
    rf.cap = 0;
    rf.col = 0;
    rf.ncols = ncols;
    rf.blank = term_blank(t);
    i32 cur_row = 0;
    i32 cur_col = 0;
    bool placed = false;
    i32 screen_row = -1;
    for i32 i = 0; i <= last; i++ {
        TermCell* src = term_seq_row(t, i);
        if i == oring { screen_row = rf.n; }
        bool wrapped = i < last && (src[ocols - 1].attr & TA_WRAP) != 0;
        i32 n = ocols;
        if !wrapped {
            n = 0;
            for i32 x = 0; x < ocols; x++ { if term_cell_ink(&src[x]) { n = x + 1; } }
        } else if !term_cell_ink(&src[ocols - 1])
            && (term_seq_row(t, i + 1)[0].attr & TA_WIDE) != 0 {
            n = ocols - 1;   // the blank a wide glyph left when it would not fit
        }
        for i32 x = 0; x < n; x++ {
            TermCell c = src[x];
            if (c.attr & TA_TAIL) != 0 { continue; }
            i32 w = 1;
            if (c.attr & TA_WIDE) != 0 { w = 2; }
            if w == 2 && ncols < 2 {
                w = 1;
                c.attr = c.attr & ~TA_WIDE;
            }
            if rf.col + w > ncols { rf_close(&rf, true); }
            bool here = i == crow && !placed
                && (x == g_t[t].cx || (x + 1 == g_t[t].cx && (src[g_t[t].cx].attr & TA_TAIL) != 0));
            if here {
                cur_row = rf.n;
                cur_col = rf.col;
                placed = true;
            }
            c.attr = c.attr & ~TA_WRAP;
            TermCell* out = rf_open(&rf);
            out[rf.col] = c;
            if w == 2 {
                out[rf.col + 1] = c;
                out[rf.col + 1].cp = 0;
                out[rf.col + 1].ext = 0;
                out[rf.col + 1].attr = (c.attr & ~TA_WIDE) | TA_TAIL;
            }
            rf.col += w;
            // a cursor waiting to wrap sits after its cell
            if here && g_t[t].wrap_next { cur_col = rf.col; }
        }
        if i == crow && !placed {
            // the cursor is past the row's ink
            i32 extra = g_t[t].cx - n;
            if extra < 0 { extra = 0; }
            cur_row = rf.n;
            cur_col = rf.col + extra;
            placed = true;
        }
        if !wrapped { rf_close(&rf, false); }
    }
    if rf.col > 0 { rf_close(&rf, false); }
    if screen_row < 0 { screen_row = rf.n; }
    i32 give = nrows - (rf.n - screen_row);
    if give > trailing { give = trailing; }
    for i32 i = 0; i < give; i++ { rf_close(&rf, false); }

    i32 len = rf.n;
    i32 top = len - nrows;
    if top < 0 { top = 0; }
    i32 nring = top;
    if nring > TERM_SCROLLBACK { nring = TERM_SCROLLBACK; }

    i64 cells = cast(i64, ncols) * cast(i64, nrows);
    TermCell* nc = alloc<TermCell>(cells);
    TermCell* no = alloc<TermCell>(cells);
    for i64 i = 0; i < cells; i++ {
        nc[i] = rf.blank;
        no[i] = rf.blank;
    }
    i32 onscreen = len - top;
    if onscreen > 0 {
        memcpy(nc, &rf.rows[top * ncols], cast(i64, onscreen) * cast(i64, ncols) * cast(i64, sizeof(TermCell)));
    }
    if g_t[t].ring != null || nring > 0 {
        TermCell* nr = alloc<TermCell>(cast(i64, TERM_SCROLLBACK) * cast(i64, ncols));
        if nring > 0 {
            memcpy(nr, &rf.rows[(top - nring) * ncols], cast(i64, nring) * cast(i64, ncols) * cast(i64, sizeof(TermCell)));
        }
        if g_t[t].ring != null { free(g_t[t].ring); }
        g_t[t].ring = nr;
    }
    g_t[t].ring_head = nring % TERM_SCROLLBACK;
    g_t[t].ring_n = nring;
    // the oldest line keeps its number
    g_t[t].pushed = g_t[t].pushed - cast(i64, oring) + cast(i64, nring);
    free(g_t[t].cells);
    free(g_t[t].other);
    g_t[t].cells = nc;
    g_t[t].other = no;
    free(rf.rows);

    i32 cy = cur_row - top;
    if cy < 0 { cy = 0; }
    if cy >= nrows { cy = nrows - 1; }
    bool past = cur_col >= ncols;
    if past { cur_col = ncols - 1; }
    g_t[t].cy = cy;
    g_t[t].cx = cur_col;
    g_t[t].wrap_next = past;
}

// The alternate screen is a program's own layout, which it repaints on
// the size change: it is cut or padded in place, rows keeping their
// place from the bottom, and the primary behind it the same way.
private void term_regrid_all(i32 t, i32 cols, i32 rows) {
    i32 ocols = g_t[t].cols;
    i32 orows = g_t[t].rows;
    i32 drop = 0;
    if rows < orows { drop = orows - rows; }
    i64 n = cast(i64, cols) * cast(i64, rows);
    TermCell* nc = alloc<TermCell>(n);
    TermCell* no = alloc<TermCell>(n);
    term_regrid(t, g_t[t].cells, ocols, orows, nc, cols, rows, drop);
    term_regrid(t, g_t[t].other, ocols, orows, no, cols, rows, drop);
    free(g_t[t].cells);
    free(g_t[t].other);
    g_t[t].cells = nc;
    g_t[t].other = no;

    if g_t[t].ring != null && cols != ocols {
        // the ring is a fixed width too, so it is cut or padded the
        // same way rather than thrown away
        TermCell* nr = alloc<TermCell>(cast(i64, TERM_SCROLLBACK) * cast(i64, cols));
        TermCell b = term_blank(t);
        for i32 y = 0; y < TERM_SCROLLBACK; y++ {
            for i32 x = 0; x < cols; x++ {
                if x < ocols {
                    nr[y * cols + x] = g_t[t].ring[y * ocols + x];
                } else {
                    nr[y * cols + x] = b;
                }
            }
        }
        free(g_t[t].ring);
        g_t[t].ring = nr;
        g_t[t].cols = cols;
        for i32 y = 0; y < TERM_SCROLLBACK; y++ { term_row_fix(t, &nr[y * cols]); }
        g_t[t].cols = ocols;
    }
    g_t[t].cy = g_t[t].cy - drop;
    g_t[t].wrap_next = false;
}

void term_resize(i32 t, i32 cols, i32 rows) {
    if !term_has(t) { return; }
    if cols < 1 { cols = 1; }
    if rows < 1 { rows = 1; }
    if cols == g_t[t].cols && rows == g_t[t].rows { return; }
    if g_t[t].m_alt {
        term_regrid_all(t, cols, rows);
    } else {
        term_reflow(t, cols, rows);
    }

    free(g_t[t].tabs);
    g_t[t].tabs = alloc<bool>(cast(i64, cols));
    g_t[t].cols = cols;
    g_t[t].rows = rows;
    term_tabs_reset(t);

    g_t[t].scr_top = 0;
    g_t[t].scr_bot = rows - 1;
    if g_t[t].cy < 0 { g_t[t].cy = 0; }
    if g_t[t].cy >= rows { g_t[t].cy = rows - 1; }
    if g_t[t].cx >= cols { g_t[t].cx = cols - 1; }
    // a resize brings a scrolled-back view to the live screen: the
    // child repaints that on the size change, and a reflow has moved
    // the history's rows under a view that stayed in it
    g_t[t].view = 0;
    if g_t[t].pty >= 0 { plat_term_resize(g_t[t].pty, cols, rows); }
}

// --- writing a codepoint ---------------------------------------------

private void term_newline(i32 t) {
    if g_t[t].cy == g_t[t].scr_bot {
        term_scroll_up(t, 1);
    } else if g_t[t].cy < g_t[t].rows - 1 {
        g_t[t].cy++;
    }
}

// The cursor's row goes on in the next one: the flag a reflow reads.
// It sits on the last cell, so it travels with the row and goes when
// the child rewrites that cell.
private void term_wrap_mark(i32 t) {
    TermCell* row = &g_t[t].cells[g_t[t].cy * g_t[t].cols];
    row[g_t[t].cols - 1].attr = row[g_t[t].cols - 1].attr | TA_WRAP;
}

private void term_put(i32 t, u32 cp, i32 w) {
    if w <= 0 { return; }   // a combining mark; the first cut drops it
    i32 cols = g_t[t].cols;
    if g_t[t].wrap_next {
        g_t[t].wrap_next = false;
        if g_t[t].m_wrap {
            term_wrap_mark(t);
            g_t[t].cx = 0;
            term_newline(t);
        }
    }
    if w == 2 && cols < 2 { w = 1; }   // a one-column screen: the cell it has, and no tail
    if w == 2 && g_t[t].cx + 2 > cols {
        // a wide glyph never straddles the edge
        if g_t[t].m_wrap {
            term_wrap_mark(t);
            g_t[t].cx = 0;
            term_newline(t);
        } else {
            return;
        }
    }
    if g_t[t].cx >= cols { g_t[t].cx = cols - 1; }
    TermCell* row = &g_t[t].cells[g_t[t].cy * cols];
    TermCell* c = &row[g_t[t].cx];
    // writing over half a two-cell glyph leaves the other half behind
    if (c.attr & TA_TAIL) != 0 && g_t[t].cx > 0 {
        row[g_t[t].cx - 1].attr = row[g_t[t].cx - 1].attr & ~TA_WIDE;
    }
    if (c.attr & TA_WIDE) != 0 && g_t[t].cx + 1 < cols {
        row[g_t[t].cx + 1].attr = row[g_t[t].cx + 1].attr & ~TA_TAIL;
        row[g_t[t].cx + 1].cp = 0;
    }
    c.cp = cp;
    c.fg = g_t[t].fg;
    c.bg = g_t[t].bg;
    c.attr = g_t[t].attr;
    if w == 2 {
        c.attr = c.attr | TA_WIDE;
        TermCell* r = &row[g_t[t].cx + 1];
        if (r.attr & TA_WIDE) != 0 && g_t[t].cx + 2 < cols {
            row[g_t[t].cx + 2].attr = row[g_t[t].cx + 2].attr & ~TA_TAIL;
            row[g_t[t].cx + 2].cp = 0;
        }
        r.cp = 0;
        r.fg = g_t[t].fg;
        r.bg = g_t[t].bg;
        r.attr = g_t[t].attr | TA_TAIL;
    }
    g_t[t].cx += w;
    if g_t[t].cx >= cols {
        // the wrap waits for the next character, so a line filled to
        // the last column does not scroll until there is more to write
        g_t[t].cx = cols - 1;
        g_t[t].wrap_next = true;
    }
}

// --- the C0 controls --------------------------------------------------

private void term_c0(i32 t, u8 c) {
    if c == 7 { return; }        // BEL: nothing to ring
    if c == 8 {                  // BS
        if g_t[t].wrap_next {
            g_t[t].wrap_next = false;
        } else if g_t[t].cx > 0 {
            g_t[t].cx--;
        }
        return;
    }
    if c == 9 {                  // HT: the next stop, or the last column
        i32 x = g_t[t].cx + 1;
        while x < g_t[t].cols - 1 && !g_t[t].tabs[x] { x++; }
        if x > g_t[t].cols - 1 { x = g_t[t].cols - 1; }
        g_t[t].cx = x;
        g_t[t].wrap_next = false;
        return;
    }
    if c == 10 || c == 11 || c == 12 {   // LF VT FF
        term_newline(t);
        g_t[t].wrap_next = false;
        return;
    }
    if c == 13 {                 // CR
        g_t[t].cx = 0;
        g_t[t].wrap_next = false;
        return;
    }
}

// --- the parser -------------------------------------------------------

private i32 term_p(i32 t, i32 i, i32 dflt) {
    if i >= g_t[t].nparam { return dflt; }
    i32 v = g_t[t].param[i];
    if v == 0 { return dflt; }
    return v;
}

// a parameter as written, where zero means zero (SGR, DECSET)
private i32 term_praw(i32 t, i32 i) {
    if i >= g_t[t].nparam { return 0; }
    return g_t[t].param[i];
}

private void term_goto(i32 t, i32 y, i32 x) {
    if g_t[t].m_origin {
        y += g_t[t].scr_top;
        if y > g_t[t].scr_bot { y = g_t[t].scr_bot; }
        if y < g_t[t].scr_top { y = g_t[t].scr_top; }
    }
    if y < 0 { y = 0; }
    if y >= g_t[t].rows { y = g_t[t].rows - 1; }
    if x < 0 { x = 0; }
    if x >= g_t[t].cols { x = g_t[t].cols - 1; }
    g_t[t].cy = y;
    g_t[t].cx = x;
    g_t[t].wrap_next = false;
}

// --- the pane's colors --------------------------------------------------

// Slots: text, background, bold text, the cursor, the selection, then
// the sixteen ANSI entries. The defaults are green on black (the shape
// of Terminal.app's Homebrew profile) with the theme's ANSI set; the
// platform overlays what the user gave their own terminal, and a
// settings file will carry a chosen scheme one day.
const i32 TP_FG = 0;
const i32 TP_BG = 1;
const i32 TP_BOLD = 2;
const i32 TP_CURSOR = 3;
const i32 TP_SEL = 4;
const i32 TP_ANSI = 5;
const i32 TP_N = 21;

private u32[TP_N] g_tpal;
private bool g_tpal_ready = false;

void term_palette_reset() {
    g_tpal[TP_FG] = T_TERM_FG;
    g_tpal[TP_BG] = T_TERM_BG;
    g_tpal[TP_BOLD] = T_TERM_BOLD;
    g_tpal[TP_CURSOR] = T_TERM_CURSOR;
    g_tpal[TP_SEL] = T_TERM_SEL;
    for i32 i = 0; i < 16; i++ { g_tpal[TP_ANSI + i] = theme_ansi(i); }
    g_tpal_ready = true;
}

// opaque always: alpha zero is the emulator's "no color"
void term_palette_set(i32 slot, u32 color) {
    if !g_tpal_ready { term_palette_reset(); }
    if slot < 0 || slot >= TP_N { return; }
    g_tpal[slot] = color | 0xFF000000;
}

u32 term_palette(i32 slot) {
    if !g_tpal_ready { term_palette_reset(); }
    if slot < 0 || slot >= TP_N { return g_tpal[TP_FG]; }
    return g_tpal[slot];
}

// Where the palette came from: the colors the user gave the platform's
// own terminal, or the built-in ones. A pane shows one or the other
// whole, never a mix, so the two can be told apart by looking.
private bool g_tpal_theirs = false;
private bool g_tpal_have = false;

// the defaults, then whatever the platform's own terminal was given
void term_palette_init() {
    term_palette_reset();
    u32[TP_N] c;
    u32 have = plat_term_palette(&c[0], TP_N);
    for i32 i = 0; i < TP_N; i++ {
        if ((have >> cast(u32, i)) & 1) != 0 { term_palette_set(i, c[i]); }
    }
    g_tpal_have = have != 0;
    g_tpal_theirs = g_tpal_have;
}

// true when the pane is showing the user's own terminal colors
bool term_palette_theirs() { return g_tpal_theirs; }

// The theme changed. The built-in scheme follows it; the user's own
// terminal colors, when they are the ones showing, stay.
void term_palette_theme() {
    if g_tpal_theirs {
        term_palette_init();
    } else {
        term_palette_reset();
    }
}

// true when the platform had colors to give at all
bool term_palette_have() { return g_tpal_have; }

// Swap between the two, for looking at one against the other. There is
// no third state yet; naming a scheme is what a settings file will do.
void term_palette_toggle() {
    if !g_tpal_have || g_tpal_theirs {
        term_palette_reset();
        g_tpal_theirs = false;
        return;
    }
    term_palette_init();
}

// 256-color index to a color: the sixteen of the palette, then the
// 6x6x6 cube, then the grays.
private u32 term_color256(i32 i) {
    if i < 0 { i = 0; }
    if i < 16 { return term_palette(TP_ANSI + i); }
    if i < 232 {
        i32 v = i - 16;
        i32 r = v / 36;
        i32 g = (v / 6) % 6;
        i32 b = v % 6;
        return 0xFF000000 | cast(u32, term_cube(r)) | (cast(u32, term_cube(g)) << 8)
            | (cast(u32, term_cube(b)) << 16);
    }
    if i > 255 { i = 255; }
    i32 l = 8 + (i - 232) * 10;
    return 0xFF000000 | cast(u32, l) | (cast(u32, l) << 8) | (cast(u32, l) << 16);
}

private i32 term_cube(i32 v) {
    if v <= 0 { return 0; }
    return 55 + v * 40;
}

private u32 term_rgb(i32 r, i32 g, i32 b) {
    if r < 0 { r = 0; }
    if r > 255 { r = 255; }
    if g < 0 { g = 0; }
    if g > 255 { g = 255; }
    if b < 0 { b = 0; }
    if b > 255 { b = 255; }
    return 0xFF000000 | cast(u32, r) | (cast(u32, g) << 8) | (cast(u32, b) << 16);
}

// SGR. The extended forms take their arguments from the parameters
// that follow, in either the semicolon or the colon spelling, since
// both arrive flattened into the same list.
private void term_sgr(i32 t) {
    if g_t[t].nparam == 0 {
        g_t[t].attr = 0;
        g_t[t].fg = TERM_DEFAULT;
        g_t[t].bg = TERM_DEFAULT;
        return;
    }
    i32 i = 0;
    while i < g_t[t].nparam {
        i32 v = g_t[t].param[i];
        if g_t[t].psub[i] {
            // a sub-parameter of one already taken (4:3's style, an
            // underline color's channels): never an attribute of its own
            i++;
            continue;
        }
        bool has_sub = i + 1 < g_t[t].nparam && g_t[t].psub[i + 1];
        if v == 0 {
            g_t[t].attr = 0;
            g_t[t].fg = TERM_DEFAULT;
            g_t[t].bg = TERM_DEFAULT;
        } else if v == 1 { g_t[t].attr = g_t[t].attr | TA_BOLD;
        } else if v == 2 { g_t[t].attr = g_t[t].attr | TA_DIM;
        } else if v == 3 { g_t[t].attr = g_t[t].attr | TA_ITALIC;
        } else if v == 4 {
            // 4:0 is no underline, 4:1 to 4:5 are styles this cell
            // draws all as the one underline
            if has_sub && g_t[t].param[i + 1] == 0 { g_t[t].attr = g_t[t].attr & ~TA_UNDER; }
            else { g_t[t].attr = g_t[t].attr | TA_UNDER; }
        } else if v == 5 || v == 6 { g_t[t].attr = g_t[t].attr | TA_BLINK;
        } else if v == 7 { g_t[t].attr = g_t[t].attr | TA_INVERSE;
        } else if v == 8 { g_t[t].attr = g_t[t].attr | TA_HIDDEN;
        } else if v == 9 { g_t[t].attr = g_t[t].attr | TA_STRIKE;
        } else if v == 22 { g_t[t].attr = g_t[t].attr & ~(TA_BOLD | TA_DIM);
        } else if v == 23 { g_t[t].attr = g_t[t].attr & ~TA_ITALIC;
        } else if v == 24 { g_t[t].attr = g_t[t].attr & ~TA_UNDER;
        } else if v == 25 { g_t[t].attr = g_t[t].attr & ~TA_BLINK;
        } else if v == 27 { g_t[t].attr = g_t[t].attr & ~TA_INVERSE;
        } else if v == 28 { g_t[t].attr = g_t[t].attr & ~TA_HIDDEN;
        } else if v == 29 { g_t[t].attr = g_t[t].attr & ~TA_STRIKE;
        } else if v >= 30 && v <= 37 { g_t[t].fg = term_palette(TP_ANSI + v - 30);
        } else if v == 39 { g_t[t].fg = TERM_DEFAULT;
        } else if v >= 40 && v <= 47 { g_t[t].bg = term_palette(TP_ANSI + v - 40);
        } else if v == 49 { g_t[t].bg = TERM_DEFAULT;
        } else if v >= 90 && v <= 97 { g_t[t].fg = term_palette(TP_ANSI + v - 90 + 8);
        } else if v >= 100 && v <= 107 { g_t[t].bg = term_palette(TP_ANSI + v - 100 + 8);
        } else if v == 38 || v == 48 || v == 58 {
            // 38;5;n and 38;2;r;g;b, and the colon forms 38:5:n,
            // 38:2:r:g:b and 38:2::r:g:b (a colorspace slot, empty);
            // 58 is the underline color, which this cell has no room
            // for, so its channels are only stepped over
            i32 kind = term_praw(t, i + 1);
            u32 col = TERM_DEFAULT;
            i32 used = 0;
            i32 subs = 0;
            while i + 1 + subs < g_t[t].nparam && g_t[t].psub[i + 1 + subs] { subs++; }
            if kind == 5 {
                col = term_color256(term_praw(t, i + 2));
                used = 2;
            } else if kind == 2 {
                i32 at = i + 2;
                if has_sub && subs >= 5 { at = i + 3; }
                col = term_rgb(term_praw(t, at), term_praw(t, at + 1), term_praw(t, at + 2));
                used = at + 2 - i;
            } else {
                // neither form: the rest of this parameter run is not
                // ours to guess at, so stop here
                return;
            }
            if v == 38 { g_t[t].fg = col; } else if v == 48 { g_t[t].bg = col; }
            i += used;
        }
        i++;
    }
}

private void term_set_mode(i32 t, i32 m, bool on) {
    if !g_t[t].priv {
        // the ANSI modes; only insert/replace would matter and no
        // program in the set uses it
        return;
    }
    if m == 1 { g_t[t].m_appcursor = on; return; }
    if m == 6 {
        g_t[t].m_origin = on;
        term_goto(t, 0, 0);
        return;
    }
    if m == 7 { g_t[t].m_wrap = on; return; }
    if m == 25 { g_t[t].m_cur_vis = on; return; }
    if m == 1000 || m == 1002 || m == 1003 {
        if on { g_t[t].m_mouse = m; } else { g_t[t].m_mouse = 0; }
        return;
    }
    if m == 1004 { g_t[t].m_focus = on; return; }
    if m == 1006 { g_t[t].m_sgr_mouse = on; return; }
    if m == 2004 { g_t[t].m_bracket = on; return; }
    if m == 47 || m == 1047 || m == 1049 {
        if on == g_t[t].m_alt { return; }
        if on {
            g_t[t].alt_x = g_t[t].cx;
            g_t[t].alt_y = g_t[t].cy;
        }
        TermCell* tmp = g_t[t].cells;
        g_t[t].cells = g_t[t].other;
        g_t[t].other = tmp;
        g_t[t].m_alt = on;
        g_t[t].view = 0;
        if on {
            // the alternate screen starts empty and keeps no history
            term_clear_rows(t, 0, g_t[t].rows - 1);
            g_t[t].cx = 0;
            g_t[t].cy = 0;
        } else {
            g_t[t].cx = g_t[t].alt_x;
            g_t[t].cy = g_t[t].alt_y;
            if g_t[t].cx >= g_t[t].cols { g_t[t].cx = g_t[t].cols - 1; }
            if g_t[t].cy >= g_t[t].rows { g_t[t].cy = g_t[t].rows - 1; }
        }
        g_t[t].wrap_next = false;
        return;
    }
    // 12 (cursor blink), 9001 (win32 input mode) and everything else:
    // recognized as a mode and dropped
}

private void term_erase_display(i32 t, i32 how) {
    i32 cols = g_t[t].cols;
    if how == 0 {
        term_clear_row(t, &g_t[t].cells[g_t[t].cy * cols], g_t[t].cx, cols - 1);
        if g_t[t].cy + 1 <= g_t[t].rows - 1 {
            term_clear_rows(t, g_t[t].cy + 1, g_t[t].rows - 1);
        }
    } else if how == 1 {
        if g_t[t].cy > 0 { term_clear_rows(t, 0, g_t[t].cy - 1); }
        term_clear_row(t, &g_t[t].cells[g_t[t].cy * cols], 0, g_t[t].cx);
    } else if how == 2 {
        term_clear_rows(t, 0, g_t[t].rows - 1);
    } else if how == 3 {
        g_t[t].ring_n = 0;
        g_t[t].ring_head = 0;
        g_t[t].view = 0;
    }
    g_t[t].wrap_next = false;
}

private void term_erase_line(i32 t, i32 how) {
    TermCell* row = &g_t[t].cells[g_t[t].cy * g_t[t].cols];
    if how == 0 {
        term_clear_row(t, row, g_t[t].cx, g_t[t].cols - 1);
    } else if how == 1 {
        term_clear_row(t, row, 0, g_t[t].cx);
    } else {
        term_clear_row(t, row, 0, g_t[t].cols - 1);
    }
    g_t[t].wrap_next = false;
}

// insert or delete cells inside the cursor's line
// the wrap flag is the row's, not the cell's: it stays on the last
// cell while the cells shift under it
private void term_ins_cells(i32 t, i32 n) {
    i32 cols = g_t[t].cols;
    TermCell* row = &g_t[t].cells[g_t[t].cy * cols];
    if n > cols - g_t[t].cx { n = cols - g_t[t].cx; }
    u16 wrap = row[cols - 1].attr & TA_WRAP;
    for i32 x = cols - 1; x >= g_t[t].cx + n; x-- { row[x] = row[x - n]; }
    term_clear_row(t, row, g_t[t].cx, g_t[t].cx + n - 1);
    row[cols - 1].attr = row[cols - 1].attr | wrap;
    term_row_fix(t, row);
}

private void term_del_cells(i32 t, i32 n) {
    i32 cols = g_t[t].cols;
    TermCell* row = &g_t[t].cells[g_t[t].cy * cols];
    if n > cols - g_t[t].cx { n = cols - g_t[t].cx; }
    u16 wrap = row[cols - 1].attr & TA_WRAP;
    for i32 x = g_t[t].cx; x <= cols - 1 - n; x++ { row[x] = row[x + n]; }
    term_clear_row(t, row, cols - n, cols - 1);
    row[cols - 1].attr = row[cols - 1].attr | wrap;
    term_row_fix(t, row);
}

// insert or delete lines at the cursor, inside the scroll region
private void term_ins_lines(i32 t, i32 n) {
    if g_t[t].cy < g_t[t].scr_top || g_t[t].cy > g_t[t].scr_bot { return; }
    i32 save = g_t[t].scr_top;
    g_t[t].scr_top = g_t[t].cy;
    term_scroll_down(t, n);
    g_t[t].scr_top = save;
}

private void term_del_lines(i32 t, i32 n) {
    if g_t[t].cy < g_t[t].scr_top || g_t[t].cy > g_t[t].scr_bot { return; }
    i32 save = g_t[t].scr_top;
    g_t[t].scr_top = g_t[t].cy;
    term_scroll_up(t, n);
    g_t[t].scr_top = save;
}

private void term_report_cursor(i32 t, bool priv) {
    noinit u8[32] b;
    i32 o = 0;
    b[o] = 27; o++;
    b[o] = '['; o++;
    if priv { b[o] = '?'; o++; }
    o += term_put_num(&b[0], o, g_t[t].cy + 1);
    b[o] = ';'; o++;
    o += term_put_num(&b[0], o, g_t[t].cx + 1);
    b[o] = 'R'; o++;
    term_send(t, &b[0], cast(i64, o));
}

// a parameter into a report, never negative
private i32 term_put_num(u8* b, i32 o, i32 v) {
    if v < 0 { v = 0; }
    return fmt_i32(b + o, v);
}

private void term_csi(i32 t, u8 f) {
    i32 n = term_p(t, 0, 1);
    if f == 'A' {                                  // CUU
        g_t[t].cy -= n;
        if g_t[t].cy < 0 { g_t[t].cy = 0; }
        g_t[t].wrap_next = false;
    } else if f == 'B' || f == 'e' {               // CUD
        g_t[t].cy += n;
        if g_t[t].cy >= g_t[t].rows { g_t[t].cy = g_t[t].rows - 1; }
        g_t[t].wrap_next = false;
    } else if f == 'C' || f == 'a' {               // CUF
        g_t[t].cx += n;
        if g_t[t].cx >= g_t[t].cols { g_t[t].cx = g_t[t].cols - 1; }
        g_t[t].wrap_next = false;
    } else if f == 'D' {                           // CUB
        g_t[t].cx -= n;
        if g_t[t].cx < 0 { g_t[t].cx = 0; }
        g_t[t].wrap_next = false;
    } else if f == 'E' {                           // CNL
        term_goto(t, g_t[t].cy + n, 0);
    } else if f == 'F' {                           // CPL
        term_goto(t, g_t[t].cy - n, 0);
    } else if f == 'G' || f == '`' {               // CHA
        g_t[t].cx = n - 1;
        if g_t[t].cx >= g_t[t].cols { g_t[t].cx = g_t[t].cols - 1; }
        if g_t[t].cx < 0 { g_t[t].cx = 0; }
        g_t[t].wrap_next = false;
    } else if f == 'H' || f == 'f' {               // CUP, HVP
        term_goto(t, term_p(t, 0, 1) - 1, term_p(t, 1, 1) - 1);
    } else if f == 'd' {                           // VPA
        term_goto(t, n - 1, g_t[t].cx);
    } else if f == 'J' {
        term_erase_display(t, term_praw(t, 0));
    } else if f == 'K' {
        term_erase_line(t, term_praw(t, 0));
    } else if f == 'X' {                           // ECH
        i32 cols = g_t[t].cols;
        i32 to = g_t[t].cx + n - 1;
        if to > cols - 1 { to = cols - 1; }
        term_clear_row(t, &g_t[t].cells[g_t[t].cy * cols], g_t[t].cx, to);
    } else if f == '@' {                           // ICH
        term_ins_cells(t, n);
    } else if f == 'P' {                           // DCH
        term_del_cells(t, n);
    } else if f == 'L' {                           // IL
        term_ins_lines(t, n);
    } else if f == 'M' {                           // DL
        term_del_lines(t, n);
    } else if f == 'S' {                           // SU
        term_scroll_up(t, n);
    } else if f == 'T' {                           // SD
        term_scroll_down(t, n);
    } else if f == 'm' {
        // CSI > Pm m is xterm's modifyOtherKeys setting, not SGR; a
        // private marker means none of these are attributes
        if !g_t[t].priv { term_sgr(t); }
    } else if f == 'h' {
        for i32 i = 0; i < g_t[t].nparam; i++ { term_set_mode(t, g_t[t].param[i], true); }
    } else if f == 'l' {
        for i32 i = 0; i < g_t[t].nparam; i++ { term_set_mode(t, g_t[t].param[i], false); }
    } else if f == 'r' && !g_t[t].priv {           // DECSTBM
        // CSI ? Pm r is XTRESTORE, which names private modes, not rows
        i32 top = term_p(t, 0, 1) - 1;
        i32 bot = term_p(t, 1, g_t[t].rows) - 1;
        if bot >= g_t[t].rows { bot = g_t[t].rows - 1; }
        if top < 0 { top = 0; }
        if top < bot {
            g_t[t].scr_top = top;
            g_t[t].scr_bot = bot;
            term_goto(t, 0, 0);
        }
    } else if f == 's' && !g_t[t].priv {           // save cursor
        term_cursor_save(t);
    } else if f == 'u' && !g_t[t].priv {           // restore cursor
        // CSI < u, CSI > Pm u, CSI = Pm u and CSI ? u are the kitty
        // keyboard protocol's push, pop and query, which say nothing
        // about the cursor: Claude Code sends them on every redraw,
        // and taking them for DECRC walks the cursor to the corner
        term_cursor_restore(t);
    } else if f == 'g' {                           // TBC
        if term_praw(t, 0) == 3 {
            for i32 i = 0; i < g_t[t].cols; i++ { g_t[t].tabs[i] = false; }
        } else if g_t[t].cx < g_t[t].cols {
            g_t[t].tabs[g_t[t].cx] = false;
        }
    } else if f == 'n' {                           // DSR
        // CSI ? 6 n is DECXCPR: the same report, marked private
        if term_praw(t, 0) == 6 { term_report_cursor(t, g_t[t].priv); }
    } else if f == 'c' && !g_t[t].priv {           // DA, one fixed identity
        // the secondary and tertiary forms (CSI > c, CSI = c) ask a
        // different question and go unanswered
        noinit u8[8] b;
        b[0] = 27;
        b[1] = '[';
        b[2] = '?';
        b[3] = '6';
        b[4] = 'c';
        term_send(t, &b[0], 5);
    } else if f == 'q' && g_t[t].inter == ' ' {    // DECSCUSR
        i32 s = term_praw(t, 0);
        if s == 3 || s == 4 { g_t[t].cur_shape = TERM_CUR_UNDER; }
        else if s == 5 || s == 6 { g_t[t].cur_shape = TERM_CUR_BAR; }
        else { g_t[t].cur_shape = TERM_CUR_BLOCK; }
    }
    // everything else, the host's own window reports (CSI 8 ; h ; w t)
    // among them, is parsed to completion and dropped
}

private void term_osc(i32 t) {
    // <number> ; <text>
    i32 i = 0;
    i32 num = 0;
    bool have = false;
    while i < g_t[t].str_len && g_t[t].strbuf[i] >= '0' && g_t[t].strbuf[i] <= '9' {
        num = num * 10 + cast(i32, g_t[t].strbuf[i] - '0');
        i++;
        have = true;
    }
    if !have || i >= g_t[t].str_len || g_t[t].strbuf[i] != ';' { return; }
    i++;
    if num == 0 || num == 2 {
        i32 n = g_t[t].str_len - i;
        if n > TERM_TITLE_MAX { n = TERM_TITLE_MAX; }
        if n > 0 { memcpy(&g_t[t].title[0], &g_t[t].strbuf[i], n); }
        g_t[t].title_len = n;
    }
    // 52 (clipboard) and the rest are dropped: a program that can set
    // the clipboard from inside a pane is not something the first cut
    // hands out
}

private void term_esc(i32 t, u8 c) {
    if c == 'M' {                       // RI, reverse index
        if g_t[t].cy == g_t[t].scr_top {
            term_scroll_down(t, 1);
        } else if g_t[t].cy > 0 {
            g_t[t].cy--;
        }
        g_t[t].wrap_next = false;
    } else if c == 'D' {                // IND
        term_newline(t);
        g_t[t].wrap_next = false;
    } else if c == 'E' {                // NEL
        g_t[t].cx = 0;
        term_newline(t);
        g_t[t].wrap_next = false;
    } else if c == 'H' {                // HTS
        if g_t[t].cx < g_t[t].cols { g_t[t].tabs[g_t[t].cx] = true; }
    } else if c == '7' {                // DECSC
        term_cursor_save(t);
    } else if c == '8' {                // DECRC
        term_cursor_restore(t);
    } else if c == 'c' {                // RIS, a full reset
        bool alt = g_t[t].m_alt;
        term_reset(t, g_t[t].cols, g_t[t].rows);
        g_t[t].m_alt = alt;
        term_tabs_reset(t);
        term_clear_rows(t, 0, g_t[t].rows - 1);
    } else if c == '=' {
        g_t[t].m_appkeypad = true;
    } else if c == '>' {
        g_t[t].m_appkeypad = false;
    }
    // ESC ( B and the other charset designators land here and are
    // dropped: every program in the set draws its boxes in Unicode
}

private void term_param_digit(i32 t, u8 c) {
    if g_t[t].nparam == 0 { g_t[t].nparam = 1; }
    i32 i = g_t[t].nparam - 1;
    if i < TERM_PARAM_MAX {
        i32 v = g_t[t].param[i] * 10 + cast(i32, c - '0');
        if v > 65535 { v = 65535; }
        g_t[t].param[i] = v;
    }
}

private void term_param_next(i32 t, bool sub) {
    if g_t[t].nparam == 0 { g_t[t].nparam = 1; }
    if g_t[t].nparam < TERM_PARAM_MAX {
        g_t[t].nparam++;
        g_t[t].param[g_t[t].nparam - 1] = 0;
        g_t[t].psub[g_t[t].nparam - 1] = sub;
    }
}

private void term_csi_begin(i32 t) {
    for i32 k = 0; k < TERM_PARAM_MAX; k++ { g_t[t].psub[k] = false; }
    g_t[t].nparam = 0;
    for i32 i = 0; i < TERM_PARAM_MAX; i++ { g_t[t].param[i] = 0; }
    g_t[t].priv = false;
    g_t[t].inter = 0;
    g_t[t].state = TS_CSI;
}

// One byte through the machine. Every state ends a sequence cleanly,
// so a split feed and a whole one are the same, and an unknown
// sequence is consumed rather than left to corrupt the next one.
private void term_byte(i32 t, u8 c) {
    i32 st = g_t[t].state;

    // ESC, CAN and SUB abandon whatever was in progress, from any state
    if c == 27 {
        if st == TS_OSC { g_t[t].state = TS_OSC_ESC; return; }
        if st == TS_STR { g_t[t].state = TS_STR_ESC; return; }
        g_t[t].state = TS_ESC;
        return;
    }
    if c == 24 || c == 26 {
        g_t[t].state = TS_GROUND;
        return;
    }

    if st == TS_GROUND {
        if c < 0x20 {
            term_c0(t, c);
            return;
        }
        if c == 0x7F { return; }
        term_utf8(t, c);
        return;
    }

    if st == TS_ESC {
        if c == '[' {
            term_csi_begin(t);
            return;
        }
        if c == ']' {
            g_t[t].str_len = 0;
            g_t[t].state = TS_OSC;
            return;
        }
        if c == 'P' || c == '_' || c == '^' || c == 'X' {
            g_t[t].state = TS_STR;
            return;
        }
        if c >= 0x20 && c <= 0x2F {
            g_t[t].state = TS_ESC_INT;
            return;
        }
        g_t[t].state = TS_GROUND;
        term_esc(t, c);
        return;
    }

    if st == TS_ESC_INT {
        // the second byte of a two-byte escape: a charset designator,
        // all of which are dropped
        if c >= 0x20 && c <= 0x2F { return; }
        g_t[t].state = TS_GROUND;
        return;
    }

    if st == TS_CSI {
        if c >= '0' && c <= '9' {
            term_param_digit(t, c);
            return;
        }
        if c == ';' || c == ':' {
            term_param_next(t, c == ':');
            return;
        }
        if c == '?' || c == '<' || c == '=' || c == '>' {
            g_t[t].priv = true;
            return;
        }
        if c >= 0x20 && c <= 0x2F {
            g_t[t].inter = c;
            return;
        }
        if c >= 0x40 && c <= 0x7E {
            g_t[t].state = TS_GROUND;
            term_csi(t, c);
            return;
        }
        if c < 0x20 {
            term_c0(t, c);
            return;
        }
        g_t[t].state = TS_CSI_IGNORE;
        return;
    }

    if st == TS_CSI_IGNORE {
        if c >= 0x40 && c <= 0x7E { g_t[t].state = TS_GROUND; }
        return;
    }

    if st == TS_OSC {
        if c == 7 {
            g_t[t].state = TS_GROUND;
            term_osc(t);
            return;
        }
        if g_t[t].str_len < TERM_STR_MAX {
            g_t[t].strbuf[g_t[t].str_len] = c;
            g_t[t].str_len++;
        }
        return;
    }

    if st == TS_OSC_ESC {
        // ESC \ is the other terminator; anything else was an escape
        // that cut the string short, and is taken as one
        g_t[t].state = TS_GROUND;
        if c == 92 {
            term_osc(t);
            return;
        }
        term_esc(t, c);
        return;
    }

    if st == TS_STR {
        return;
    }

    if st == TS_STR_ESC {
        g_t[t].state = TS_GROUND;
        if c != 92 { term_esc(t, c); }
        return;
    }
    g_t[t].state = TS_GROUND;
}

// UTF-8 in the ground state, with the same decoder the editor uses. A
// codepoint split across two reads is held here until the rest of it
// arrives; a malformed one becomes U+FFFD rather than moving the grid.
private void term_utf8(i32 t, u8 c) {
    if g_t[t].utf_len == 0 {
        if c < 0x80 {
            term_put(t, cast(u32, c), 1);
            return;
        }
        g_t[t].utf[0] = c;
        g_t[t].utf_len = 1;
    } else {
        if (c & 0xC0) != 0x80 {
            // not a continuation: the held bytes were malformed
            term_put(t, 0xFFFD, 1);
            g_t[t].utf_len = 0;
            term_utf8(t, c);
            return;
        }
        g_t[t].utf[g_t[t].utf_len] = c;
        g_t[t].utf_len++;
    }
    i32 need = 2;
    u8 b0 = g_t[t].utf[0];
    if b0 >= 0xF8 {
        // no utf-8 sequence starts here, so there is nothing to wait
        // for: the byte is the error
        term_put(t, 0xFFFD, 1);
        g_t[t].utf_len = 0;
        return;
    }
    if b0 >= 0xF0 { need = 4; }
    else if b0 >= 0xE0 { need = 3; }
    else if b0 >= 0xC0 { need = 2; }
    else {
        // a continuation byte with nothing in front of it
        term_put(t, 0xFFFD, 1);
        g_t[t].utf_len = 0;
        return;
    }
    if g_t[t].utf_len < need { return; }
    i32 i = 0;
    u32 cp = utf8_next(&g_t[t].utf[0], g_t[t].utf_len, &i);
    g_t[t].utf_len = 0;
    term_put_cp(t, cp);
}

// The child's bytes. The reader thread queues them and the main thread
// hands them here; a test hands them here directly.
void term_feed(i32 t, u8* p, i64 n) {
    if !term_has(t) { return; }
    // output leaves the view where it is: the history it is on moves
    // with the ring (term_ring_push), so the text stays under the
    // reader's eyes while the child prints. A key snaps it back.
    if g_t[t].tap && n > 0 { tc_grow(&g_t[t].tapq, &g_t[t].tapq_len, &g_t[t].tapq_cap, p, n); }
    for i64 i = 0; i < n; i++ { term_byte(t, p[i]); }
}

// keep the child's raw bytes aside as they are fed, for term_tap_take
void term_tap(i32 t, bool on) {
    if !term_has(t) { return; }
    g_t[t].tap = on;
}

// the bytes kept since the last take, or null; the caller frees
u8* term_tap_take(i32 t, i64* n) {
    *n = 0;
    if !term_has(t) || g_t[t].tapq == null { return null; }
    u8* q = g_t[t].tapq;
    *n = g_t[t].tapq_len;
    g_t[t].tapq = null;
    g_t[t].tapq_len = 0;
    g_t[t].tapq_cap = 0;
    return q;
}

// Block until the child has sent more, or exited: the headless settle
// (a build before a --shot) and nothing on the UI thread. With no
// reader thread the pump reads on its own and there is nothing to wait for.
void term_wait(i32 t) {
    if !term_has(t) || g_t[t].pty < 0 { return; }
    when !os(wasm) {
        if term_threaded && g_t[t].rthread_up { sem_wait(&g_t[t].rsem); }
    }
}

// The queue as raw bytes, before the emulator sees them. The terminal
// probe is the only caller: it records what the host sends, and the
// terminal it opens is never pumped. The caller owns the block.
u8* term_take(i32 t, i64* out_n) {
    *out_n = 0;
    if !term_has(t) || g_t[t].pty < 0 { return null; }
    when !os(wasm) {
        if term_threaded {
            mutex_lock(&g_t[t].mx);
            u8* q = g_t[t].q;
            i64 qn = g_t[t].q_len;
            g_t[t].q = null;
            g_t[t].q_len = 0;
            g_t[t].q_cap = 0;
            mutex_unlock(&g_t[t].mx);
            *out_n = qn;
            return q;
        }
    }
    u8* buf = alloc<u8>(cast(i64, TERM_READ_CAP));
    i64 n = plat_term_read(g_t[t].pty, buf, cast(i64, TERM_READ_CAP));
    if n <= 0 {
        free(buf);
        g_t[t].exited = true;
        return null;
    }
    *out_n = n;
    return buf;
}

// Every terminal's queue into its emulator, once per wake: a burst is
// many reads and one frame.
// The terminals that took bytes, a bit per handle, so the caller can
// tell whether anything it draws has changed: a shell running behind a
// pane nobody is looking at moves no pixels, and asking for a frame on
// its output alone repainted the window at the child's own rate.
i32 term_pump() {
    if !g_t_ready { return 0; }
    i32 any = 0;
    for i32 t = 0; t < TERM_MAX; t++ {
        if !g_t[t].used || g_t[t].pty < 0 { continue; }
        when !os(wasm) {
            if term_threaded {
                mutex_lock(&g_t[t].mx);
                u8* q = g_t[t].q;
                i64 qn = g_t[t].q_len;
                g_t[t].q = null;
                g_t[t].q_len = 0;
                g_t[t].q_cap = 0;
                bool ex = g_t[t].exited;
                mutex_unlock(&g_t[t].mx);
                if q != null {
                    term_feed(t, q, qn);
                    free(q);
                    any = any | (1 << cast(u32, t));
                }
                if ex && g_t[t].code < 0 {
                    g_t[t].code = plat_term_code(g_t[t].pty);
                    if g_t[t].code < 0 { g_t[t].code = 0; }
                    any = any | (1 << cast(u32, t));
                }
                continue;
            }
        }
        // no reader thread: read here, which is what the harness wants
        u8* buf = alloc<u8>(cast(i64, TERM_READ_CAP));
        i64 n = plat_term_read(g_t[t].pty, buf, cast(i64, TERM_READ_CAP));
        if n > 0 {
            term_feed(t, buf, n);
            any = any | (1 << cast(u32, t));
        } else if !g_t[t].exited {
            g_t[t].exited = true;
            g_t[t].code = plat_term_code(g_t[t].pty);
            if g_t[t].code < 0 { g_t[t].code = 0; }
            any = any | (1 << cast(u32, t));
        }
        free(buf);
    }
    return any;
}


// What has to be true of a screen whatever the child sent. The fuzzer
// asks after every step and the tests after every case; an empty
// answer is a sound screen. It is here rather than in the harness
// because these are the module's own invariants, and half of them are
// over state nothing outside can see.
str term_check(i32 t) {
    if !term_has(t) { return ""; }
    if g_t[t].cols < 1 || g_t[t].rows < 1 { return "the screen has no size"; }
    if g_t[t].cx < 0 || g_t[t].cx >= g_t[t].cols {
        return "the cursor is outside the columns";
    }
    if g_t[t].cy < 0 || g_t[t].cy >= g_t[t].rows {
        return "the cursor is outside the rows";
    }
    if g_t[t].scr_top < 0 || g_t[t].scr_bot >= g_t[t].rows
        || g_t[t].scr_top > g_t[t].scr_bot {
        return "the scroll region is outside the screen";
    }
    if g_t[t].ring_n < 0 || g_t[t].ring_n > TERM_SCROLLBACK {
        return "the scrollback is past the end of the ring";
    }
    if g_t[t].view < 0 || g_t[t].view > g_t[t].ring_n {
        return "the view is past the history";
    }
    if g_t[t].nparam < 0 || g_t[t].nparam > TERM_PARAM_MAX {
        return "the parameter list overran";
    }
    if g_t[t].str_len < 0 || g_t[t].str_len > TERM_STR_MAX {
        return "the string buffer overran";
    }
    if g_t[t].utf_len < 0 || g_t[t].utf_len > 4 {
        return "the held utf-8 bytes overran";
    }
    if g_t[t].title_len < 0 || g_t[t].title_len > TERM_TITLE_MAX {
        return "the title overran";
    }
    if g_t[t].state < TS_GROUND || g_t[t].state > TS_STR_ESC {
        return "the parser is in no state at all";
    }
    for i32 y = 0; y < g_t[t].rows; y++ {
        TermCell* row = &g_t[t].cells[y * g_t[t].cols];
        for i32 x = 0; x < g_t[t].cols; x++ {
            if (row[x].attr & TA_WIDE) != 0 {
                if x + 1 >= g_t[t].cols { return "a wide glyph has no room for its tail"; }
                if (row[x + 1].attr & TA_TAIL) == 0 { return "a wide glyph lost its tail"; }
            }
            if row[x].ext != 0 && (g_t[t].clus == null || cast(i32, row[x].ext) > TERM_CLUS_MAX) {
                return "a cell points at no cluster";
            }
            if (row[x].attr & TA_TAIL) != 0 {
                if x == 0 || (row[x - 1].attr & TA_WIDE) == 0 {
                    return "a tail has no glyph in front of it";
                }
            }
            if (row[x].attr & TA_WRAP) != 0 && x != g_t[t].cols - 1 {
                return "a wrap flag is not on the row's last cell";
            }
        }
    }
    return "";
}

// --- what the frame builder and the tests read ------------------------

bool term_live(i32 t) { return term_has(t); }
// a terminal with a child behind it (a screen the tests or the fuzzer
// feed on its own has none), which is what the switcher lists
bool term_has_child(i32 t) { return term_has(t) && g_t[t].pty >= 0; }
i32 term_cols(i32 t) { if !term_has(t) { return 0; } return g_t[t].cols; }
i32 term_rows(i32 t) { if !term_has(t) { return 0; } return g_t[t].rows; }
i32 term_cx(i32 t) { if !term_has(t) { return 0; } return g_t[t].cx; }
i32 term_cy(i32 t) { if !term_has(t) { return 0; } return g_t[t].cy; }
i32 term_cursor_shape(i32 t) { if !term_has(t) { return 0; } return g_t[t].cur_shape; }
bool term_alt(i32 t) { if !term_has(t) { return false; } return g_t[t].m_alt; }
bool term_bracketed(i32 t) { if !term_has(t) { return false; } return g_t[t].m_bracket; }
i32 term_mouse_mode(i32 t) { if !term_has(t) { return 0; } return g_t[t].m_mouse; }
i32 term_scrollback(i32 t) { if !term_has(t) { return 0; } return g_t[t].ring_n; }
i32 term_view(i32 t) { if !term_has(t) { return 0; } return g_t[t].view; }

// The cursor is not drawn while the view is scrolled back, and not
// while the child has hidden it.
bool term_cursor_vis(i32 t) {
    if !term_has(t) { return false; }
    return g_t[t].m_cur_vis && g_t[t].view == 0;
}

void term_view_set(i32 t, i32 off) {
    if !term_has(t) { return; }
    if off < 0 { off = 0; }
    if off > g_t[t].ring_n { off = g_t[t].ring_n; }
    g_t[t].view = off;
}

str term_title(i32 t) {
    if !term_has(t) { return ""; }
    return str_from(&g_t[t].title[0], g_t[t].title_len);
}

bool term_exited(i32 t) {
    if !term_has(t) { return false; }
    if g_t[t].pty < 0 { return false; }
    mutex_lock(&g_t[t].mx);
    bool e = g_t[t].exited;
    mutex_unlock(&g_t[t].mx);
    return e;
}

i32 term_num(i32 t) {
    if !term_has(t) { return 0; }
    return g_t[t].num;
}

// What a terminal is called in the switcher, the banner and the window
// title: "terminal N" for a shell, with the title its program set after
// a colon; a command's terminal is the command. The buffer is shared,
// so the name is for immediate use.
private u8[TERM_TITLE_MAX + 32] g_t_label;
str term_label(i32 t) {
    if !term_has(t) { return "terminal"; }
    i32 o = 0;
    if g_t[t].num > 0 {
        str s = "terminal ";
        memcpy(&g_t_label[o], s.data, s.len);
        o += s.len;
        o += fmt_i32(&g_t_label[o], g_t[t].num);
        if g_t[t].title_len > 0 {
            g_t_label[o] = ':';
            g_t_label[o + 1] = ' ';
            o += 2;
        }
    }
    if g_t[t].title_len > 0 {
        memcpy(&g_t_label[o], &g_t[t].title[0], g_t[t].title_len);
        o += g_t[t].title_len;
    }
    if o == 0 { return "terminal"; }
    return str_from(&g_t_label[0], o);
}

i32 term_code(i32 t) {
    if !term_has(t) { return -1; }
    return g_t[t].code;
}

// A displayed row: the rows above the screen come out of the ring when
// the view is scrolled back. null when the row is not on screen.
private TermCell* term_row(i32 t, i32 row) {
    if row < 0 || row >= g_t[t].rows { return null; }
    i32 v = g_t[t].view;
    if v > 0 && row < v {
        // counting back from the newest line in the ring
        i32 age = v - row;
        i32 idx = g_t[t].ring_head - age;
        while idx < 0 { idx += TERM_SCROLLBACK; }
        return &g_t[t].ring[idx * g_t[t].cols];
    }
    return &g_t[t].cells[(row - v) * g_t[t].cols];
}

// --- absolute lines: what a selection is anchored to ---------------------
// Lines are numbered from the first one ever pushed into the scrollback:
// the screen's top row is `pushed`, the newest ring line is pushed - 1.
// A selection kept in these survives the output scrolling under it.

// the absolute line of displayed row 0
i64 term_abs_top(i32 t) {
    if !term_has(t) { return 0; }
    return g_t[t].pushed - cast(i64, g_t[t].view);
}

// the oldest line still held, and one past the screen's last row
i64 term_abs_first(i32 t) {
    if !term_has(t) { return 0; }
    return g_t[t].pushed - cast(i64, g_t[t].ring_n);
}

i64 term_abs_end(i32 t) {
    if !term_has(t) { return 0; }
    return g_t[t].pushed + cast(i64, g_t[t].rows);
}

private TermCell* term_abs_row(i32 t, i64 abs) {
    if abs >= g_t[t].pushed {
        i64 r = abs - g_t[t].pushed;
        if r >= cast(i64, g_t[t].rows) { return null; }
        return &g_t[t].cells[cast(i32, r) * g_t[t].cols];
    }
    i64 age = g_t[t].pushed - abs;   // 1 = the newest ring line
    if age > cast(i64, g_t[t].ring_n) || g_t[t].ring == null { return null; }
    i32 idx = g_t[t].ring_head - cast(i32, age);
    while idx < 0 { idx += TERM_SCROLLBACK; }
    return &g_t[t].ring[idx * g_t[t].cols];
}

// cells [c0, c1) of absolute line `abs` as UTF-8, a blank as a space;
// trailing blanks go when the range reaches the line's end. 0 for a
// line not held.
i32 term_abs_text(i32 t, i64 abs, i32 c0, i32 c1, u8* out, i32 cap) {
    if !term_has(t) { return 0; }
    TermCell* r = term_abs_row(t, abs);
    if r == null { return 0; }
    if c0 < 0 { c0 = 0; }
    if c1 > g_t[t].cols { c1 = g_t[t].cols; }
    if c1 <= c0 { return 0; }
    return term_cells_text(t, r, c0, c1, c1 >= g_t[t].cols, out, cap);
}

// cells [c0, c1) of row r as UTF-8, a blank as a space; with `trim` the
// blanks after the last inked cell are left out
private i32 term_cells_text(i32 t, TermCell* r, i32 c0, i32 c1, bool trim, u8* out, i32 cap) {
    i32 last = c1 - 1;
    if trim {
        last = c0 - 1;
        for i32 x = c0; x < c1; x++ {
            if r[x].cp != 0 && r[x].cp != 32 { last = x; }
        }
    }
    i32 o = 0;
    for i32 x = c0; x <= last; x++ {
        if (r[x].attr & TA_TAIL) != 0 { continue; }
        if o + TERM_CLUS_BYTES > cap { return o; }
        o += term_clus_bytes(t, &r[x], out + o);
    }
    return o;
}

// DECSC and DECRC, which CSI s and CSI u are the other spelling of
private void term_cursor_save(i32 t) {
    g_t[t].sv_x = g_t[t].cx;
    g_t[t].sv_y = g_t[t].cy;
    g_t[t].sv_attr = g_t[t].attr;
    g_t[t].sv_fg = g_t[t].fg;
    g_t[t].sv_bg = g_t[t].bg;
}

private void term_cursor_restore(i32 t) {
    term_goto(t, g_t[t].sv_y, g_t[t].sv_x);
    g_t[t].attr = g_t[t].sv_attr;
    g_t[t].fg = g_t[t].sv_fg;
    g_t[t].bg = g_t[t].sv_bg;
}

// the cluster bytes of a displayed cell, 0 for a lone codepoint; `out`
// takes TERM_CLUS_BYTES
i32 term_cell_cluster(i32 t, i32 row, i32 col, u8* out) {
    if !term_has(t) || col < 0 || col >= g_t[t].cols { return 0; }
    TermCell* r = term_row(t, row);
    if r == null || r[col].ext == 0 { return 0; }
    return term_clus_bytes(t, &r[col], out);
}

u32 term_cell_cp(i32 t, i32 row, i32 col) {
    if !term_has(t) || col < 0 || col >= g_t[t].cols { return 0; }
    TermCell* r = term_row(t, row);
    if r == null { return 0; }
    return r[col].cp;
}

u32 term_cell_fg(i32 t, i32 row, i32 col) {
    if !term_has(t) || col < 0 || col >= g_t[t].cols { return TERM_DEFAULT; }
    TermCell* r = term_row(t, row);
    if r == null { return TERM_DEFAULT; }
    return r[col].fg;
}

u32 term_cell_bg(i32 t, i32 row, i32 col) {
    if !term_has(t) || col < 0 || col >= g_t[t].cols { return TERM_DEFAULT; }
    TermCell* r = term_row(t, row);
    if r == null { return TERM_DEFAULT; }
    return r[col].bg;
}

i32 term_cell_attr(i32 t, i32 row, i32 col) {
    if !term_has(t) || col < 0 || col >= g_t[t].cols { return 0; }
    TermCell* r = term_row(t, row);
    if r == null { return 0; }
    return cast(i32, r[col].attr);
}

// The screen as text, rows joined by newlines with the trailing blanks
// of each row cut. What --dump-term writes and what the ed_test cases
// are written against.
// one displayed row as UTF-8, trailing blanks dropped; 0 off the screen
i32 term_row_text(i32 t, i32 row, u8* out, i32 cap) {
    if !term_has(t) || row < 0 || row >= g_t[t].rows { return 0; }
    TermCell* r = term_row(t, row);
    if r == null { return 0; }
    return term_cells_text(t, r, 0, g_t[t].cols, true, out, cap);
}

i32 term_dump(i32 t, u8* out, i32 cap) {
    if !term_has(t) { return 0; }
    // trailing blank rows are not content: an empty screen dumps as
    // nothing rather than as a column of newlines
    i32 last_row = -1;
    for i32 y = 0; y < g_t[t].rows; y++ {
        TermCell* r = term_row(t, y);
        for i32 x = 0; x < g_t[t].cols; x++ {
            if r[x].cp != 0 && r[x].cp != 32 { last_row = y; }
        }
    }
    i32 o = 0;
    for i32 y = 0; y <= last_row; y++ {
        o += term_row_text(t, y, out + o, cap - o);
        if y < last_row {
            if o + 1 > cap { return o; }
            out[o] = 10;
            o++;
        }
    }
    return o;
}

// --- keys to the child ------------------------------------------------

// The modifier suffix xterm gives a key: 1 = none, and the bits are
// shift 1, alt 2, ctrl 4, one above the editor's own.
private i32 term_modcode(i32 mods) {
    i32 m = 1;
    if (mods & MOD_SHIFT) != 0 { m += 1; }
    if (mods & MOD_ALT) != 0 { m += 2; }
    if (mods & MOD_CTRL) != 0 { m += 4; }
    return m;
}

// CSI <n> ~ for the editing keys, CSI/SS3 <letter> for the arrows and
// Home/End, each with the modifier suffix when there is one.
private void term_key_seq(i32 t, u8 f, i32 num, i32 mods, bool ss3_ok) {
    noinit u8[32] b;
    i32 o = 0;
    i32 m = term_modcode(mods);
    b[o] = 27; o++;
    if ss3_ok && g_t[t].m_appcursor && m == 1 {
        b[o] = 'O'; o++;
        b[o] = f; o++;
        term_send(t, &b[0], cast(i64, o));
        return;
    }
    b[o] = '['; o++;
    if num > 0 {
        o += term_put_num(&b[0], o, num);
        if m != 1 {
            b[o] = ';'; o++;
            o += term_put_num(&b[0], o, m);
        }
        b[o] = '~'; o++;
    } else {
        if m != 1 {
            b[o] = '1'; o++;
            b[o] = ';'; o++;
            o += term_put_num(&b[0], o, m);
        }
        b[o] = f; o++;
    }
    term_send(t, &b[0], cast(i64, o));
}

// F1 to F4: SS3 with the letter whatever the cursor-key mode, the CSI
// form only to carry a modifier.
private void term_key_fn(i32 t, u8 f, i32 mods) {
    noinit u8[8] b;
    if term_modcode(mods) == 1 {
        b[0] = 27;
        b[1] = 'O';
        b[2] = f;
        term_send(t, &b[0], 3);
        return;
    }
    term_key_seq(t, f, 0, mods, false);
}

// A key press for the focused terminal. True when it was the child's;
// the caller keeps what this leaves alone.
bool term_key(i32 t, i32 key, i32 mods) {
    if !term_has(t) { return false; }
    noinit u8[8] b;
    // a key for the child snaps the view back to the live screen, as
    // every terminal does: what the child answers is what the reader
    // wants to see. A key the terminal leaves alone (the editor's own)
    // does not.
    i32 view = g_t[t].view;
    g_t[t].view = 0;
    if key == K_UP { term_key_seq(t, 'A', 0, mods, true); return true; }
    if key == K_DOWN { term_key_seq(t, 'B', 0, mods, true); return true; }
    if key == K_RIGHT { term_key_seq(t, 'C', 0, mods, true); return true; }
    if key == K_LEFT { term_key_seq(t, 'D', 0, mods, true); return true; }
    if key == K_HOME { term_key_seq(t, 'H', 0, mods, true); return true; }
    if key == K_END { term_key_seq(t, 'F', 0, mods, true); return true; }
    if key == K_PGUP { term_key_seq(t, 0, 5, mods, false); return true; }
    if key == K_PGDN { term_key_seq(t, 0, 6, mods, false); return true; }
    if key == K_DELETE { term_key_seq(t, 0, 3, mods, false); return true; }
    // The function keys in xterm's forms: F1 to F4 are SS3 P to S,
    // CSI 1;m P to S with a modifier; the rest are numbered.
    if key == K_F1 { term_key_fn(t, 'P', mods); return true; }
    if key == K_F2 { term_key_fn(t, 'Q', mods); return true; }
    if key == K_F3 { term_key_fn(t, 'R', mods); return true; }
    if key == K_F4 { term_key_fn(t, 'S', mods); return true; }
    if key == K_F5 { term_key_seq(t, 0, 15, mods, false); return true; }
    if key == K_F6 { term_key_seq(t, 0, 17, mods, false); return true; }
    if key == K_F7 { term_key_seq(t, 0, 18, mods, false); return true; }
    if key == K_F8 { term_key_seq(t, 0, 19, mods, false); return true; }
    if key == K_F9 { term_key_seq(t, 0, 20, mods, false); return true; }
    if key == K_F10 { term_key_seq(t, 0, 21, mods, false); return true; }
    if key == K_F11 { term_key_seq(t, 0, 23, mods, false); return true; }
    if key == K_F12 { term_key_seq(t, 0, 24, mods, false); return true; }
    if key == K_TAB {
        if (mods & MOD_SHIFT) != 0 {
            b[0] = 27;
            b[1] = '[';
            b[2] = 'Z';
            term_send(t, &b[0], 3);
            return true;
        }
        b[0] = 9;
        term_send(t, &b[0], 1);
        return true;
    }
    if key == K_ESCAPE {
        b[0] = 27;
        term_send(t, &b[0], 1);
        return true;
    }
    // Ctrl with a letter or one of the few punctuation keys is the
    // control code itself; the shell reads Ctrl+C, not a key name.
    if (mods & MOD_CTRL) != 0 && (mods & MOD_ALT) == 0 {
        i32 c = -1;
        if key >= 'A' && key <= 'Z' { c = key - 'A' + 1; }
        else if key == ' ' { c = 0; }
        else if key == '[' { c = 27; }
        else if key == 92 { c = 28; }
        else if key == ']' { c = 29; }
        else if key == '-' { c = 31; }
        if c >= 0 {
            b[0] = cast(u8, c);
            term_send(t, &b[0], 1);
            return true;
        }
    }
    g_t[t].view = view;
    return false;
}

// Committed text. Enter, Tab and Backspace arrive here as codepoints
// 13, 9 and 8 rather than as keys (plat.mc, app_char): Enter goes as
// the carriage return a shell reads for a line, and Backspace as DEL,
// which is what the reference sends and what every shell in the set
// expects. Alt is the escape prefix, which a shell reads as Meta.
void term_char(i32 t, u32 cp, i32 mods) {
    if !term_has(t) { return; }
    g_t[t].view = 0;
    noinit u8[8] b;
    i32 o = 0;
    if (mods & MOD_ALT) != 0 {
        b[o] = 27;
        o++;
    }
    if cp == 8 {
        b[o] = 127;
        o++;
    } else {
        o += utf8_encode(cp, &b[0] + o);
    }
    term_send(t, &b[0], cast(i64, o));
}

// A paste, wrapped the way the child asked for it. Without bracketed
// paste the newlines go as carriage returns, which is what a shell
// takes for a line.
void term_paste(i32 t, u8* p, i64 n) {
    if !term_has(t) || n <= 0 { return; }
    g_t[t].view = 0;
    noinit u8[8] b;
    if g_t[t].m_bracket {
        b[0] = 27; b[1] = '['; b[2] = '2'; b[3] = '0'; b[4] = '0'; b[5] = '~';
        term_send(t, &b[0], 6);
    }
    i64 start = 0;
    for i64 i = 0; i < n; i++ {
        if p[i] == 10 {
            if i > start { term_send(t, p + start, i - start); }
            b[0] = 13;
            term_send(t, &b[0], 1);
            start = i + 1;
        }
    }
    if n > start { term_send(t, p + start, n - start); }
    if g_t[t].m_bracket {
        b[0] = 27; b[1] = '['; b[2] = '2'; b[3] = '0'; b[4] = '1'; b[5] = '~';
        term_send(t, &b[0], 6);
    }
}

// A mouse event in the SGR encoding, the only one the first cut emits:
// every program that asks for a mouse asks for 1006 as well.
void term_mouse(i32 t, i32 col, i32 row, i32 btn, bool down, i32 mods) {
    if !term_has(t) || g_t[t].m_mouse == 0 { return; }
    noinit u8[32] b;
    i32 o = 0;
    i32 code = btn;
    if (mods & MOD_SHIFT) != 0 { code += 4; }
    if (mods & MOD_ALT) != 0 { code += 8; }
    if (mods & MOD_CTRL) != 0 { code += 16; }
    b[o] = 27; o++;
    b[o] = '['; o++;
    b[o] = '<'; o++;
    o += term_put_num(&b[0], o, code);
    b[o] = ';'; o++;
    o += term_put_num(&b[0], o, col + 1);
    b[o] = ';'; o++;
    o += term_put_num(&b[0], o, row + 1);
    if down { b[o] = 'M'; } else { b[o] = 'm'; }
    o++;
    term_send(t, &b[0], cast(i64, o));
}
