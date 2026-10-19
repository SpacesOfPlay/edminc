// ed.mc - portable editor core: state, selection, editing, the
// undo journal, movement, and the app_* entry points from
// plat.mc. Talks to the OS only through the plat_* services.

const i32 TABW = 4;

// The reference's defaults differ by platform, and so do these (the
// word modifier is MOD_WORD in plat.mc). The navigation history:
// Ctrl+- and Ctrl+Shift+- on macOS (Cmd+arrows there is line start
// and end), Alt+Left/Right elsewhere. The chords are constants so the
// tests and the fuzzer press the same keys the driver sends.
when os(macos) {
    const i32 NAV_BACK_KEY = '-';
    const i32 NAV_BACK_MODS = MOD_SUPER;          // the Ctrl key on macOS
    const i32 NAV_FWD_KEY = '-';
    const i32 NAV_FWD_MODS = MOD_SUPER | MOD_SHIFT;
}
when !os(macos) {
    const i32 NAV_BACK_KEY = K_LEFT;
    const i32 NAV_BACK_MODS = MOD_ALT;
    const i32 NAV_FWD_KEY = K_RIGHT;
    const i32 NAV_FWD_MODS = MOD_ALT;
}
const i32 LINEBUF_CAP = 65536;

const i32 BLINK_TIMER = 1;
// Edits debounce onto this before the buffer is pushed to the server.
// Public because a headless caller has to fire it by hand.
const i32 LSP_SYNC_TIMER = 2;
private const i32 LSP_SYNC_MS = 300;
// resting on a word before asking what it is
const i32 HOVER_TIMER = 3;
private const i32 HOVER_MS = 350;
// typing settles before asking what could come next
const i32 CMP_TIMER = 4;
private const i32 CMP_MS = 150;
// the change gutter re-diffs after edits settle: it hashes every line,
// which is fine on a timer and not fine per keystroke
const i32 GIT_TIMER = 5;
const i32 SEM_TIMER = 6;   // full-document semantic tokens, reset on each edit
private const i32 GIT_MS = 100;
// full-document semantic tokens are O(file) to fetch and parse, so ask
// only after typing pauses; the lexer colors instantly meanwhile
private const i32 SEM_MS = 400;
private bool git_timer_on = false;
private const i32 BLINK_MS = 500;
private const i32 BLINK_TOGGLES = 14;
private const i32 INDENT_MAX = 256;

// One journal entry: at `pos`, `del` bytes were removed and `ins`
// bytes were inserted. Undo inverts it, redo replays it. `cont` means
// this entry continues the one before it, which is how one keystroke
// at N cursors undoes as one step.
struct UndoOp {
    i64 pos;
    i64 caret_before;
    u8* ins;
    i32 ins_len;
    u8* del;
    i32 del_len;
    bool cont;
}

i32 g_w = 0;
i32 g_h = 0;
bool g_focused = false;
private i32 g_dpi = DPI_BASE;

i32 cur_line = 0;
i64 cur_col = 0;      // byte offset within the line
i32 top_line = 0;     // derived: scroll_y / font_line_h
i32 scroll_off = 0;   // derived: scroll_y % font_line_h (pixels)
i32 left_vcol = 0;
private i32 scroll_y = 0;     // viewport top in document pixels
// The wrap width scroll_y counts rows at, 0 when it counts lines (or a
// diff's rows). A pane that is wider or narrower now wraps into other
// rows, and wrap_refit converts the scroll through the line at the top.
private i32 g_scroll_cols = 0;
private i32 goal_vcol = -1;   // preferred visual column for up/down
private f32 g_scroll_accum = 0.0f;   // sub-pixel scroll remainder
private f32 g_term_scroll_accum = 0.0f;   // the terminal pane's, in pixels short of a line

private bool sel_active = false;
private i64 sel_anchor = 0;   // absolute offset; caret is the other end

// Secondary cursors. The primary one stays in cur_line/cur_col and
// sel_*, so every path that predates multi-cursor still reads one
// caret; these are the extra ones, kept sorted by offset and never
// overlapping (cur_install enforces both).
const i32 CUR_MAX = 128;

struct EdCursor {
    i64 caret;
    i64 anchor;
    bool sel;
    bool prim;    // survives a sort, so the primary stays the primary
}

private EdCursor[CUR_MAX] g_cur;
private i32 g_ncur = 0;       // secondaries only; the total is this + 1

private UndoOp* undo_ops = null;
private i32 undo_cap = 0;
private i32 undo_len = 0;      // [0, undo_len) undoable
private i32 undo_total = 0;    // [undo_len, undo_total) redoable
private i32 undo_saved = 0;    // undo_len at the last save; -1 = unreachable
private bool undo_break = true;
// set while the second and later cursors of one action are editing, so
// the entries they push undo together with the first
private bool undo_cont = false;

bool caret_on = true;
private i32 blink_count = 0;
private bool timer_on = false;

u8[PATH_MAX] g_path;
i32 g_path_len = 0;
bool g_has_path = false;
private bool g_title_dirty = false;

// project folder name for the title, from plat_cwd
private u8[256] g_proj;
private i32 g_proj_len = 0;

// the composed window title; the self-drawn caption renders it too
u8[2300] g_title;
i32 g_title_len = 0;

bool g_lex_on = true;         // known files (lex_lang_of) and untitled highlight
i32 g_lex_lang = LANG_MINC;   // the language the buffer lexes in

// transient status-bar message, cleared by the next key
u8[128] g_status_msg;
i32 g_status_len = 0;

// a refused close arms the next one; any edit or save disarms
private bool g_close_armed = false;

// A second left press soon after the first, on the same spot, selects
// the word under it, and a third the line. Detected here rather than
// taken from the OS, so every shell gets it through the same app_mouse.
const i64 DBLCLICK_US = 400000;
private const i32 DBLCLICK_PX = 4;
private i64 g_click_us = 0;
private i32 g_click_x = -100000;
private i32 g_click_y = -100000;
private i32 g_click_n = 0;   // presses in the run so far
u8* g_linebuf = null;
u8* g_clsbuf = null;
u8* g_lexstate = null;  // lex state at the START of each line
private i32 g_lex_cap = 0;
private i32 g_lex_valid = 0;  // entries [0, valid) are computed

// --- small helpers ---------------------------------------------------

i32 fmt_i32(u8* dst, i32 v) {
    if v == 0 {
        dst[0] = '0';
        return 1;
    }
    u8[16] tmp;
    i32 n = 0;
    while v > 0 {
        tmp[n] = cast(u8, '0' + v % 10);
        v /= 10;
        n++;
    }
    for i32 i = 0; i < n; i++ {
        dst[i] = tmp[n - 1 - i];
    }
    return n;
}

// --- line access + lex cache -----------------------------------------

// copies line l into g_linebuf, truncated at LINEBUF_CAP
i32 line_bytes(i32 l) {
    i64 s = tb_line_start(l);
    i64 n = tb_line_end(l) - s;
    if n > LINEBUF_CAP { n = LINEBUF_CAP; }
    tb_copy(s, g_linebuf, n);
    return cast(i32, n);
}

private i64 line_len(i32 l) {
    return tb_line_end(l) - tb_line_start(l);
}

private void lex_invalidate(i32 line) {
    if line < g_lex_valid { g_lex_valid = line; }
    if g_lex_valid < 1 { g_lex_valid = 0; }
}

// the language a file lexes in, by extension; -1 means no highlighting
i32 lex_lang_of(str p) {
    if str_ends_with(p, ".mc") { return LANG_MINC; }
    if str_ends_with(p, ".md") { return LANG_MD; }
    if str_ends_with(p, ".js") { return LANG_JS; }
    if str_ends_with(p, ".mjs") { return LANG_JS; }
    if str_ends_with(p, ".py") { return LANG_PY; }
    if str_ends_with(p, ".ps1") { return LANG_SH; }
    if str_ends_with(p, ".sh") { return LANG_SH; }
    if str_ends_with(p, ".html") { return LANG_HTML; }
    if str_ends_with(p, ".htm") { return LANG_HTML; }
    if str_ends_with(p, ".css") { return LANG_CSS; }
    if str_ends_with(p, ".gml") { return LANG_GML; }
    if str_ends_with(p, ".c") || str_ends_with(p, ".h") { return LANG_C; }
    if str_ends_with(p, ".cpp") || str_ends_with(p, ".hpp") { return LANG_C; }
    if str_ends_with(p, ".cc") || str_ends_with(p, ".cxx") || str_ends_with(p, ".hh") { return LANG_C; }
    if str_ends_with(p, ".json") { return LANG_JSON; }
    if str_ends_with(p, ".yy") { return LANG_JSON; }
    if str_ends_with(p, ".yyp") { return LANG_JSON; }
    if str_ends_with(p, ".yml") { return LANG_YAML; }
    if str_ends_with(p, ".yaml") { return LANG_YAML; }
    return -1;
}

// set the highlighting flag and language for a path, on open and save-as
private void lex_set_for(str p) {
    i32 lang = lex_lang_of(p);
    g_lex_on = lang >= 0;
    if lang >= 0 { g_lex_lang = lang; } else { g_lex_lang = LANG_MINC; }
    ed_lsp_follow();
}

// one line's classes in the buffer's language
i32 lex_row(u8* s, i32 n, i32 state, u8* cls) {
    if g_lex_lang == LANG_MD { return lex_md_line(s, n, state, cls); }
    if g_lex_lang == LANG_JS { return lex_js_line(s, n, state, cls); }
    if g_lex_lang == LANG_PY { return lex_py_line(s, n, state, cls); }
    if g_lex_lang == LANG_SH { return lex_sh_line(s, n, state, cls); }
    if g_lex_lang == LANG_HTML { return lex_html_line(s, n, state, cls); }
    if g_lex_lang == LANG_JSON { return lex_json_line(s, n, state, cls); }
    if g_lex_lang == LANG_YAML { return lex_yaml_line(s, n, state, cls); }
    if g_lex_lang == LANG_CSS { return lex_css_line(s, n, state, cls); }
    if g_lex_lang == LANG_GML { return lex_gml_line(s, n, state, cls); }
    if g_lex_lang == LANG_C { return lex_c_line(s, n, state, cls); }
    return lex_line(s, n, state, cls);
}

// lines [0, ed_lex_valid()) hold a computed start state; the fuzzer
// compares them against a full relex
i32 ed_lex_valid() {
    return g_lex_valid;
}

void lex_ensure(i32 line) {
    if g_lex_cap < tb.nlines + 1 {
        i32 ncap = tb.nlines + 1024;
        u8* ns = alloc<u8>(ncap);
        if g_lexstate != null {
            memcpy(ns, g_lexstate, g_lex_valid);
            free(g_lexstate);
        }
        g_lexstate = ns;
        g_lex_cap = ncap;
    }
    if g_lex_valid == 0 {
        g_lexstate[0] = 0;
        g_lex_valid = 1;
    }
    while g_lex_valid <= line {
        i32 l = g_lex_valid - 1;
        i32 n = line_bytes(l);
        i32 st = lex_row(g_linebuf, n, cast(i32, g_lexstate[l]), g_clsbuf);
        g_lexstate[l + 1] = cast(u8, st);
        g_lex_valid++;
    }
}

// --- geometry --------------------------------------------------------

// the status bar hides on a toggle (Ctrl+K S)
bool g_statusbar_on = true;

// what the window holds below the loaded pane: the status bar, and the
// build's pane under a column (see "the bottom pane")
i32 chrome_bottom_h() {
    return g_h - ed_pane_y1(g_pane_loaded);
}

// --- the bottom pane -------------------------------------------------
// The build's terminal sits below the columns, across the editor's
// width, the way VS Code's panel does. It is a pane like any other, so
// the terminal pane's keys, selection and mouse are its own; it is kept
// last in the list and laid out under the columns, with its top edge
// dragged to size it. g_bottom says the last pane is it, and the panes
// before it are the columns: the splits, Ctrl+1..3, the pane moves and
// the diff count those.
private bool g_bottom = false;
private f32 g_bottom_frac = 0.33f;     // of the height above the status bar
private const i32 BOTTOM_MIN_LINES = 4;
private i32 g_col_last = 0;            // the column focused last, for leaving it
const i32 COL_MAX = 3;
const i32 DIV_BOTTOM = 1000;          // g_div_drag for the bottom pane's top edge

i32 pane_cols() {
    if g_bottom { return g_npanes - 1; }
    return g_npanes;
}

bool pane_is_bottom(i32 p) {
    return g_bottom && p == g_npanes - 1;
}

// the band's height were it up: its share of the area, keeping a few
// lines for it and for the columns above
private i32 bottom_band_h() {
    i32 area = g_h - status_h();
    if area < 2 { return 0; }
    i32 h = cast(i32, cast(f32, area) * g_bottom_frac + 0.5f);
    i32 lo = banner_h() + BOTTOM_MIN_LINES * font_line_h;
    i32 hi = area - banner_h() - BOTTOM_MIN_LINES * font_line_h;
    if lo <= hi {
        if h > hi { h = hi; }
        if h < lo { h = lo; }
        return h;
    }
    // a window too short for both: the share, kept to the middle half,
    // so the columns never lose all their height
    if h < area / 4 { h = area / 4; }
    if h > area - area / 4 { h = area - area / 4; }
    return h;
}

private i32 bottom_h() {
    if !g_bottom { return 0; }
    return bottom_band_h();
}

i32 panel_top() {
    return g_h - status_h() - bottom_h();
}

// pane p's top and bottom edges, in window pixels
i32 ed_pane_y0(i32 p) {
    if pane_is_bottom(p) { return panel_top(); }
    return 0;
}

i32 ed_pane_y1(i32 p) {
    if pane_is_bottom(p) { return g_h - status_h(); }
    return g_h - status_h() - bottom_h();
}

// where pane p's text or grid starts: below its banner, which a split
// layout gives every pane
i32 pane_doc_top(i32 p) {
    i32 y = ed_pane_y0(p);
    if g_npanes > 1 { y += banner_h(); }
    return y;
}

// the loaded pane's top edge, for the banner the view draws there
i32 ed_pane_top() {
    return ed_pane_y0(g_pane_loaded);
}

// The sidebar (tree, search) runs the full height above the status bar.
i32 sidebar_bottom() {
    return g_h - status_h();
}

i32 status_h() {
    if !g_statusbar_on { return 0; }
    // the reference status bar is a 22-css-px band, same metric as
    // list rows; the mono-derived fallback covers stubs
    if font_ui_row > 0 { return font_ui_row; }
    return font_line_h + 8;
}

// each text pane carries a one-line banner with its file name; the
// document starts below it. Same 22-css-px band as the status bar.
i32 banner_h() {
    if font_ui_row > 0 { return font_ui_row; }
    return font_line_h + 8;
}

// the document's top edge inside a pane. The banner, and the space it
// takes, appear only when the layout is split; a lone pane has none and
// the window title carries its name instead.
i32 doc_top() {
    return pane_doc_top(g_pane_loaded);
}

// self-drawn caption metrics (used only where g_caption_h > 0); the
// the driver sets g_caption_h = caption_default_h(dpi) after font
// init, before app_init has told the core its dpi, so the dpi is an
// argument here
i32 caption_default_h(i32 dpi) {
    return CAPTION_H_PX * dpi / DPI_BASE;
}

i32 caption_btn_w() {
    return CAPTION_BTN_PX * g_dpi / DPI_BASE;
}

// pointer shape at (x, y) in core space: text gets the I-beam, the
// chrome (sidebar, status bar) the arrow. The caption band is the
// driver's own.
i32 app_cursor_kind(i32 x, i32 y) {
    if g_div_drag == DIV_BOTTOM { return CURSOR_RESIZE_V; }
    if g_div_drag >= 0 { return CURSOR_RESIZE_H; }
    if x < content_left() { return CURSOR_ARROW; }
    if y >= g_h - status_h() { return CURSOR_ARROW; }
    // a diff's revert arrow sits on the divider's grab band and wins it
    if ed_diff_revert_hit(x, y) >= 0 { return CURSOR_HAND; }
    i32 dv = pane_div_at(x, y);
    if dv == DIV_BOTTOM { return CURSOR_RESIZE_V; }
    if dv >= 0 { return CURSOR_RESIZE_H; }
    i32 pp = pane_at(x, y);
    if y < pane_doc_top(pp) { return CURSOR_ARROW; }   // the pane's banner is chrome
    if g_panes[pp].kind == PANE_TERM { return CURSOR_ARROW; }
    i32 lx0 = 0;
    i32 ly0 = 0;
    i32 lx1 = 0;
    i32 ly1 = 0;
    if ed_link_rect(&lx0, &ly0, &lx1, &ly1)
        && x >= lx0 && x < lx1 && y >= ly0 && y < ly1 {
        return CURSOR_HAND;
    }
    return CURSOR_IBEAM;
}

i32 visible_lines() {
    i32 v = (g_h - chrome_bottom_h() - doc_top()) / font_line_h;
    if v < 1 { v = 1; }
    return v;
}

i32 gutter_digits() {
    i32 d = 1;
    i32 n = tb.nlines;
    while n >= 10 {
        n /= 10;
        d++;
    }
    if d < 3 { d = 3; }
    return d;
}

i32 gutter_w() {
    return ed_diff_margin_w() + (gutter_digits() + 2) * font_cell_w;
}

i32 text_cols() {
    i32 c = (pane_x1() - pane_x0() - gutter_w()) / font_cell_w;
    if c < 1 { c = 1; }
    return c;
}

// The one write path for the scroll position; keeps the derived
// top_line/scroll_off pair in step. Wheel input lands on arbitrary
// pixels; caret-driven scrolling passes line multiples.
private void scroll_set(i32 y) {
    g_scroll_cols = scroll_units();
    i32 max = (ed_row_count() - 1) * font_line_h;
    if y > max { y = max; }
    if y < 0 { y = 0; }
    scroll_y = y;
    top_line = scroll_y / font_line_h;
    scroll_off = scroll_y % font_line_h;
}

// what the loaded pane's scroll counts in: its wrap width, or 0 for lines
private i32 scroll_units() {
    if ed_wrap_on() { return wrap_cols(); }
    return 0;
}

// A scroll kept by a pane or a buffer, with the units it was kept in,
// into the globals: converted to the pane's width now, then clamped.
private void scroll_load(i32 y, i32 cols) {
    scroll_y = y;
    g_scroll_cols = cols;
    wrap_refit();
    scroll_set(scroll_y);
}

// The loaded pane's scroll was set at another wrap width, or before wrap
// went on or off: the line at the top, and the row of it, stay at the
// top in the rows the pane has now.
private void wrap_refit() {
    i32 now = scroll_units();
    if now == g_scroll_cols { return; }
    i32 lh = font_line_h;
    i32 r = scroll_y / lh;
    i32 px = scroll_y % lh;
    i32 l = r;
    i32 sub = 0;
    if g_scroll_cols > 0 {
        l = wrap_line_of_row_at(g_scroll_cols, r);
        sub = r - wrap_row_of_line_at(g_scroll_cols, l);
    } else if diff_here() {
        l = ed_line_of_row(r);
        if l < 0 { l = 0; }
    }
    g_scroll_cols = now;
    l = clamp_line(l);
    i32 nr = ed_row_of_line(l);
    if nr < 0 { nr = l; }
    if now > 0 {
        i32 rows = wrap_line(l);
        if sub >= rows { sub = rows - 1; }
        nr += sub;
    } else {
        px = 0;
    }
    i32 y = nr * lh + px;
    i32 max = (ed_row_count() - 1) * lh;
    if y > max { y = max; }
    if y < 0 { y = 0; }
    scroll_y = y;
    top_line = scroll_y / lh;
    scroll_off = scroll_y % lh;
}

// the loaded pane's scroll in the rows it has now, before a frame or a
// check reads top_line
void ed_view_refit() {
    wrap_refit();
}

// visual column of byte offset `col` in line l (tabs, utf8, wide)
i32 vcol_of_col(i32 l, i64 col) {
    i32 n = line_bytes(l);
    i32 v = 0;
    i32 i = 0;
    while i < n && i < cast(i32, col) {
        if g_linebuf[i] == '\t' {
            v = (v / TABW + 1) * TABW;
            i++;
        } else {
            v += grapheme_next_w(g_linebuf, n, &i);
        }
    }
    return v;
}

// byte offset in line l closest to visual column `want`; landing
// inside a tab or a wide character steps past it
private i64 col_of_vcol(i32 l, i32 want) {
    i32 n = line_bytes(l);
    i32 v = 0;
    i32 i = 0;
    while i < n && v < want {
        if g_linebuf[i] == '\t' {
            v = (v / TABW + 1) * TABW;
            i++;
        } else {
            v += grapheme_next_w(g_linebuf, n, &i);
        }
    }
    return i;
}

// --- LSP position conversion ------------------------------------------
// A position on the wire counts UTF-16 code units; the buffer counts
// UTF-8 bytes. They agree only on the ASCII subset: an astral
// codepoint is one four-byte sequence here and a surrogate pair there,
// so past one the two drift by one unit each time. When the server
// agreed to utf-8 both are byte offsets and these pass straight
// through. Both clamp, since one end of this is the server's.

i32 lsp_col_of_byte(i32 l, i64 col) {
    if l < 0 || l >= tb.nlines { return 0; }
    if !lsp_pos_utf16 { return cast(i32, col); }
    i32 n = line_bytes(l);
    i32 u = 0;
    i32 i = 0;
    while i < n && i < cast(i32, col) {
        u32 cp = utf8_next(g_linebuf, n, &i);
        u++;
        if cp >= SURR_BASE { u++; }
    }
    return u;
}

i64 lsp_byte_of_col(i32 l, i32 want) {
    if l < 0 || l >= tb.nlines || want <= 0 { return 0; }
    i32 n = line_bytes(l);
    if !lsp_pos_utf16 {
        if want > n { return cast(i64, n); }
        return cast(i64, want);
    }
    i32 u = 0;
    i32 i = 0;
    while i < n && u < want {
        u32 cp = utf8_next(g_linebuf, n, &i);
        u++;
        if cp >= SURR_BASE { u++; }
    }
    return cast(i64, i);
}

// A stored byte column put back into text that has since changed can
// land inside a codepoint: the line is clamped for length but nothing
// says the offset is a boundary. Snap it back to the start of the
// sequence it fell into. Every path that restores a remembered caret
// goes through here.
private i64 col_snap(i32 l, i64 col) {
    if col <= 0 { return 0; }
    // an out-of-range line is someone else's bug to report; do not
    // quietly move the caret to the start of the buffer over it
    if l < 0 || l >= tb.nlines { return col; }
    i32 n = line_bytes(l);
    if col >= cast(i64, n) { return cast(i64, n); }
    // Where decoding the line lands, which is where movement can put
    // the caret. utf8_next steps a single byte over a malformed one, so
    // this stays meaningful in a buffer holding bytes that are not
    // valid utf-8 at all.
    i32 i = 0;
    i32 prev = 0;
    while i < n && cast(i64, i) < col {
        prev = i;
        ignore grapheme_next_w(g_linebuf, n, &i);
    }
    if cast(i64, i) == col { return col; }
    return cast(i64, prev);
}

// --- caret + title ---------------------------------------------------

// A redraw request. While a navigation input runs (scrolling, the caret
// and selection keys, a drag in a document, hover) it covers the window
// the input went to: scroll positions, carets and selections are per
// window. Every other request redraws every window, and a text change
// always does (after_edit), since another window may show the buffer.
private i32 g_damage_win = -1;

void ed_damage() {
    if g_damage_win >= 0 {
        plat_damage_window(g_damage_win);
        return;
    }
    plat_damage();
}

private void reset_blink() {
    caret_on = true;
    blink_count = 0;
    if g_focused {
        plat_set_timer(BLINK_TIMER, BLINK_MS);
        timer_on = true;
    }
}

// "<basename> — <project folder>", a leading '*' while dirty
private void update_title() {
    i32 n = 0;
    i32 cap = 2300 - 320;   // room kept for the " -- <project>" tail
    // the files shown in the panes, in pane order, each dirty one
    // starred; a buffer shown in two panes appears once. A lone pane
    // yields one name, which is why closing a split drops the other.
    i32 shown = 0;
    for i32 p = 0; p < g_npanes; p++ {
        if g_panes[p].kind == PANE_TERM {
            // "terminal N" with the shell's title; never starred
            str tname = term_label(g_panes[p].term);
            if shown > 0 && n + 2 <= cap { g_title[n] = ','; n++; g_title[n] = ' '; n++; }
            i32 tk = 0;
            while tk < tname.len && n < cap { g_title[n] = tname.data[tk]; n++; tk++; }
            shown++;
            continue;
        }
        i32 b = g_panes[p].buf;
        if b < 0 || b >= g_nbufs { continue; }
        bool dup = false;
        for i32 q = 0; q < p; q++ {
            if g_panes[q].buf == b { dup = true; break; }
        }
        if dup { continue; }
        if shown > 0 && n + 2 <= cap { g_title[n] = ','; n++; g_title[n] = ' '; n++; }
        bool d = g_bufs[b].tb.dirty;
        if b == g_buf_active { d = tb.dirty; }
        if d && n < cap { g_title[n] = '*'; n++; }
        str name = ed_buf_title(b);
        i32 k = 0;
        while k < name.len && n < cap { g_title[n] = name.data[k]; n++; k++; }
        shown++;
    }
    if g_proj_len > 0 {
        g_title[n] = ' ';
        n++;
        g_title[n] = 0xE2;   // em dash
        n++;
        g_title[n] = 0x80;
        n++;
        g_title[n] = 0x94;
        n++;
        g_title[n] = ' ';
        n++;
        memcpy(&g_title[n], &g_proj[0], g_proj_len);
        n += g_proj_len;
    }
    g_title_len = n;
    plat_set_title(str_from(&g_title[0], n));
    g_title_dirty = tb.dirty;
    plat_damage();
}

// --- smooth scrolling ------------------------------------------------
// A held caret key scrolls a line per key repeat, and a wheel's notch
// scrolls several lines at once. The logical scroll (scroll_y) still
// moves at once, so the caret, hit-testing and every later input see
// the new position immediately. Only the frame build draws the view
// trailing it, and the trail shrinks at a steady rate, so the text
// moves one refresh at a time instead of a step at a time.
//
// For a held key the rate is a line per repeat period, the period a
// running mean of the gaps between repeats. The view keeps half a line
// of trail in reserve when the next repeat is due, so a repeat up to
// half a period late finds it still moving. A repeat that comes early
// adds to the trail, and the rate rises to restore the reserve. The
// trail is two lines at most, and runs out at the same rate once the
// key is released. A lone key step, a caret jump of more than a line
// and the diff's shared scroll snap.
//
// A notch keeps no reserve: its trail runs out over the gap since the
// previous notch, or over GLIDE_NOTCH_US for a lone one. Touchpad
// deltas are already fine and never glide.
bool g_smooth_scroll = true;
// the problem underlines in the text: errors, warnings, information and
// hints alike (Ctrl+K D, "editor.renderValidationDecorations"). The
// gutter marks, the ruler and the hover messages stay.
bool g_squiggles = true;
private const i64 GLIDE_REPEAT_US = 150000;   // steps this close are a held key
private const i64 GLIDE_MIN_US = 8000;
private const i64 GLIDE_MAX_US = 50000;
private const i64 GLIDE_NOTCH_US = 30000;
private const i32 GLIDE_NOTCH_LINES = 20;     // a longer notch (a page setting) snaps
private const i32 GLIDE_RESERVE_DIV = 2;      // the reserve, as a fraction of a line
private const i32 GLIDE_KEY_LINES = 2;        // a held key's trail, at most
private bool g_scroll_notch = false;          // app_scroll_notch is running
private i32 g_glide_px = 0;       // how far the drawn view trails scroll_y at g_glide_t0
private i64 g_glide_t0 = 0;
private i64 g_glide_dur = 0;      // when the trail reaches 0, from g_glide_t0
private i64 g_glide_last = 0;     // when the previous caret-driven scroll step came
private i64 g_glide_period = 0;   // the running mean of a held key's repeat gap; 0 between holds
private i32 g_glide_win = -1;     // the window, pane and buffer the glide belongs to
private i32 g_glide_pane = -1;
private i32 g_glide_buf = -1;
private bool g_glide_drawn = false;
private i32 g_glide_frame_off = 0;   // the trail the last frame drew, for --time
private i64 g_glide_frame_t = 0;     // the clock for the frame being built

// the trail at `now`, shrinking linearly to 0 over the glide
private i32 glide_at(i64 now) {
    if g_glide_px == 0 || g_glide_dur <= 0 { return 0; }
    i64 e = now - g_glide_t0;
    if e >= g_glide_dur || e < 0 {
        g_glide_px = 0;
        return 0;
    }
    return cast(i32, cast(i64, g_glide_px) * (g_glide_dur - e) / g_glide_dur);
}

// pane p, loaded in the globals, scrolled `delta` pixels: to follow the
// caret, or by a wheel's notch
private void glide_step(i32 p, i32 delta, bool notch) {
    i64 now = plat_time_us();
    i64 gap = now - g_glide_last;
    g_glide_last = now;
    i32 rem = 0;
    if g_glide_win == g_win && g_glide_pane == p && g_glide_buf == g_buf_active {
        rem = glide_at(now);
    }
    i32 lh = font_line_h;
    i32 size = delta;
    if size < 0 { size = -size; }
    i32 most = lh;
    if notch { most = GLIDE_NOTCH_LINES * lh; }
    bool lone = gap > GLIDE_REPEAT_US;
    // a diff's scroll is its file pane's: the base side's own scroll is
    // not the one drawn, so it snaps
    if !g_smooth_scroll || (diff_on && p == 0) || size > most || (lone && !notch) {
        g_glide_px = 0;
        g_glide_period = 0;
        return;
    }
    if gap < GLIDE_MIN_US { gap = GLIDE_MIN_US; }
    if gap > GLIDE_MAX_US { gap = GLIDE_MAX_US; }
    // the drawn view stays where it is; the trail is what it lacks
    i32 px = rem + delta;
    i32 cap = size;
    i32 reserve = 0;
    i64 period = gap;
    if notch {
        if size < lh { cap = lh; }
        if lone { period = GLIDE_NOTCH_US; }
        g_glide_period = 0;
    } else {
        cap = GLIDE_KEY_LINES * lh;
        reserve = lh / GLIDE_RESERVE_DIV;
        if g_glide_period != 0 { period = (3 * g_glide_period + gap) / 4; }
        g_glide_period = period;
    }
    if px > cap { px = cap; }
    if px < -cap { px = -cap; }
    // the trail runs down to the reserve over one period, and on to 0
    // at the same rate
    i32 mag = px;
    if mag < 0 { mag = -mag; }
    i64 dur = period;
    if mag > reserve { dur = period * cast(i64, mag) / cast(i64, mag - reserve); }
    g_glide_px = px;
    g_glide_t0 = now;
    g_glide_dur = dur;
    g_glide_win = g_win;
    g_glide_pane = p;
    g_glide_buf = g_buf_active;
}

// frame build, before the panes: one clock reading for every pane, so
// the two sides of a diff draw the same trail
void ed_glide_frame() {
    g_glide_frame_t = plat_time_us();
}

// frame build, after pane pi is loaded: draw it where the glide has it.
// The base side of a diff follows the file's pane, which owns the scroll.
void ed_glide_begin(i32 pi) {
    i32 owner = pi;
    if diff_on && pi == 0 { owner = 1; }
    if g_glide_px == 0 || g_glide_win != g_win || g_glide_pane != owner
        || g_panes[owner].buf != g_glide_buf {
        return;
    }
    i32 off = glide_at(g_glide_frame_t);
    if off == 0 { return; }
    g_glide_frame_off = off;
    i32 y = scroll_y - off;
    if y < 0 { y = 0; }
    top_line = y / font_line_h;
    scroll_off = y % font_line_h;
    g_glide_drawn = true;
}

// the trail the frame being built drew, and 0 once read: for the
// platform's frame log
i32 ed_glide_frame_offset() {
    i32 v = g_glide_frame_off;
    g_glide_frame_off = 0;
    return v;
}

// and back to the logical scroll once the pane is drawn
void ed_glide_end() {
    if !g_glide_drawn { return; }
    g_glide_drawn = false;
    scroll_set(scroll_y);
}

// whether this window's view is still moving, so it needs another frame
bool ed_glide_running() {
    return g_glide_win == g_win && glide_at(plat_time_us()) != 0;
}

// the trail now, for the checks
i32 ed_glide_offset() {
    return glide_at(plat_time_us());
}

private void ensure_visible() {
    i32 vis = visible_lines();
    i32 lh = font_line_h;
    // caret-driven scrolling snaps to whole rows
    i32 cr = ed_row_of_pos(cur_line, cur_col);
    if cr < 0 { cr = cur_line; }
    i32 before = scroll_y;
    if cr * lh < scroll_y {
        scroll_set(cr * lh);
    } else if (cr + 1) * lh > scroll_y + vis * lh {
        scroll_set((cr + 1 - vis) * lh);
    }
    if scroll_y != before { glide_step(g_pane_active, scroll_y - before, false); }
    // a wrapped view has nothing to the right to scroll to
    if ed_wrap_on() { return; }
    i32 cv = vcol_of_col(cur_line, cur_col);
    i32 cols = text_cols();
    if cv < left_vcol { left_vcol = cv; }
    if cv >= left_vcol + cols - 1 { left_vcol = cv - cols + 2; }
    if left_vcol < 0 { left_vcol = 0; }
}

private void after_move() {
    // Every movement and every edit ends here, so this is the one
    // place the caret has to be put back onto a position decoding can
    // reach. The line ops keep a byte column across a delete, and the
    // remembered ones come back into text that has changed.
    // The extra cursors are put back in the same one place: a jump, a
    // drag or an edit made in another pane can leave the set
    // overlapping or pointing past the end of the buffer.
    cur_reclamp();
    cur_col = col_snap(cur_line, cur_col);
    // signature help follows the call it opened: it stays while the caret
    // is past the '(' on that line, and goes when the caret leaves it
    if hover_sig && (cur_line != hover_ask_line || cast(i32, cur_col) <= hover_sig_col) {
        ed_hover_hide();
    }
    if sig_line >= 0 && (cur_line != sig_line || cast(i32, cur_col) <= sig_paren_col) {
        ed_sig_hide();
    }
    ensure_visible();
    reset_blink();
    ed_damage();
}

// The last message stays in g_status_msg, which the input box draws
// under its field and the tests read; otherwise it is a notice.
private void status_record(str m) {
    i32 n = m.len;
    if n > 128 { n = 128; }
    memcpy(&g_status_msg[0], m.data, n);
    g_status_len = n;
    plat_damage();
}

// information: a notice that goes by itself
void ed_status(str m) {
    status_record(m);
    if !ask_on { notice_show(m, NOTICE_INFO, false); }
}

// a warning: a refused action, a failed save, a file changed on disk.
// The notice stays until it is dismissed.
void ed_warn(str m) {
    status_record(m);
    if !ask_on { notice_show(m, NOTICE_WARN, true); }
}

private void status_clear() {
    if g_status_len > 0 {
        g_status_len = 0;
        plat_damage();
    }
}

private void after_edit(i32 from_line) {
    lex_invalidate(from_line);
    // every path that changes the text ends here, undo and redo
    // included, so this is where the server is owed a push
    lsp_stale = true;
    ed_lsp_touch();
    ed_sem_touch();
    ed_git_touch();
    g_close_armed = false;
    g_save_armed = false;
    after_move();
    plat_damage();
    bool was_preview = g_preview;
    g_preview = false;
    if was_preview || tb.dirty != g_title_dirty { update_title(); }
}

// --- caret + selection -----------------------------------------------

private i64 cur_abs() {
    return tb_line_start(cur_line) + cur_col;
}

private void set_caret_abs(i64 pos) {
    if pos < 0 { pos = 0; }
    i64 len = tb_len();
    if pos > len { pos = len; }
    cur_line = tb_line_of(pos);
    cur_col = pos - tb_line_start(cur_line);
}

private bool sel_nonempty() {
    return sel_active && sel_anchor != cur_abs();
}

i64 ed_caret_abs() {
    return cur_abs();
}

// caret position in client pixels, just under the caret's line; the
// platform anchors the IME composition UI here
void ed_caret_px(i32* x, i32* y) {
    ed_pos_xy(cur_line, cur_col, x, y);
    *y += font_line_h;
}

// select [a, b) and move the caret to b (find navigation)
void ed_set_sel(i64 a, i64 b) {
    sel_set_anchor(a);
    set_caret_abs(b);
    undo_break = true;
    goal_vcol = -1;
    after_move();
}

// Replace [pos, pos + ndel) with s as one undo step of its own (find
// and replace). The caret lands after the new text. False when the
// buffer takes no edits: an image, or a commit's version.
bool ed_find_replace(i64 pos, i64 ndel, u8* s, i32 n) {
    if g_img >= 0 || g_rev { return false; }
    cur_collapse();
    undo_break = true;
    ed_replace(pos, ndel, s, n);
    undo_break = true;
    return true;
}

// active selection as [a, b); false when empty
bool ed_sel_range(i64* a, i64* b) {
    if !sel_active { return false; }
    i64 c = cur_abs();
    if sel_anchor == c { return false; }
    if sel_anchor < c {
        *a = sel_anchor;
        *b = c;
    } else {
        *a = c;
        *b = sel_anchor;
    }
    return true;
}

private void sel_clear() {
    sel_active = false;
}

// The anchor is an absolute offset, like the caret, and every path
// that computes one has to keep it inside the buffer: a selection is
// the range the edit paths delete over, so an endpoint past the end
// is a wild tb_delete. set_caret_abs clamps the other end already.
private void sel_set_anchor(i64 pos) {
    if pos < 0 { pos = 0; }
    i64 len = tb_len();
    if pos > len { pos = len; }
    sel_anchor = pos;
    sel_active = true;
}

// called before every movement; extend = shift held
private void sel_move_begin(bool extend) {
    undo_break = true;
    if extend {
        if !sel_active {
            sel_anchor = cur_abs();
            sel_active = true;
        }
    } else {
        sel_active = false;
    }
}

// --- multiple cursors -------------------------------------------------
// An action runs once per cursor, with each cursor installed into the
// primary slot in turn. That is what keeps every editing and movement
// path single-caret code: none of them know this exists.

private const i32 OP_CHAR      = 0;
private const i32 OP_INSTXT    = 1;
private const i32 OP_ENTER     = 2;
private const i32 OP_TAB       = 3;
private const i32 OP_BACKSPACE = 4;
private const i32 OP_DELETE    = 5;
private const i32 OP_DELWL     = 6;
private const i32 OP_DELWR     = 7;
private const i32 OP_LEFT      = 8;
private const i32 OP_RIGHT     = 9;
private const i32 OP_UP        = 10;
private const i32 OP_DOWN      = 11;
private const i32 OP_HOME      = 12;
private const i32 OP_END       = 13;
private const i32 OP_WORDL     = 14;
private const i32 OP_WORDR     = 15;
private const i32 OP_DELSEL    = 16;

private u32 op_cp = 0;         // OP_CHAR
private u8* op_txt = null;     // OP_INSTXT
private i32 op_txt_len = 0;
private bool op_shift = false; // movement ops: shift held

i32 ed_cur_count() {
    return g_ncur + 1;
}

// cursor i as caret offset and selection [a, b); i = 0 is the primary.
// Rendering wants every cursor, in no particular order.
void ed_cur_get(i32 i, i64* caret, i64* a, i64* b) {
    if i <= 0 {
        *caret = cur_abs();
        *a = *caret;
        *b = *caret;
        if sel_active { ignore ed_sel_range(a, b); }
        return;
    }
    EdCursor* c = &g_cur[i - 1];
    *caret = c.caret;
    cur_range(c, a, b);
}

private void cur_range(EdCursor* c, i64* a, i64* b) {
    if !c.sel || c.anchor == c.caret {
        *a = c.caret;
        *b = c.caret;
    } else if c.anchor < c.caret {
        *a = c.anchor;
        *b = c.caret;
    } else {
        *a = c.caret;
        *b = c.anchor;
    }
}

// sorts and merges by where a cursor starts, not where its caret is,
// so a selection dragged backwards sits in document order
private i64 cur_key(EdCursor* c) {
    i64 a = 0;
    i64 b = 0;
    cur_range(c, &a, &b);
    return a;
}

private void cur_sort(EdCursor* c, i32 n) {
    for i32 i = 1; i < n; i++ {
        EdCursor k = c[i];
        i64 kk = cur_key(&k);
        i32 j = i - 1;
        while j >= 0 && cur_key(&c[j]) > kk {
            c[j + 1] = c[j];
            j--;
        }
        c[j + 1] = k;
    }
}

// Two cursors that overlap are one cursor. Ranges that merely touch
// stay apart unless one of them is a bare caret, which is the case of
// a caret sitting at the edge of a selection: that is the same place.
private i32 cur_merge(EdCursor* c, i32 n) {
    i32 w = 0;
    for i32 i = 0; i < n; i++ {
        if w > 0 {
            i64 pa = 0;
            i64 pb = 0;
            cur_range(&c[w - 1], &pa, &pb);
            i64 qa = 0;
            i64 qb = 0;
            cur_range(&c[i], &qa, &qb);
            bool touch = qa == pb && (pa == pb || qa == qb);
            if qa < pb || touch {
                i64 b = pb;
                if qb > b { b = qb; }
                bool prim = c[w - 1].prim || c[i].prim;
                c[w - 1] = EdCursor{ b, pa, pa != b, prim };
                continue;
            }
        }
        c[w] = c[i];
        w++;
    }
    return w;
}

// the one path that writes the cursor set: sorted, merged, clamped,
// and with the primary back in cur_line/cur_col
// carets at these byte offsets, the first the primary, installed the
// way every edit installs them; for the checks
void ed_cursors_set(i64* at, i32 n) {
    if n < 1 { return; }
    if n > CUR_MAX + 1 { n = CUR_MAX + 1; }
    noinit EdCursor[CUR_MAX + 1] c;
    for i32 i = 0; i < n; i++ { c[i] = EdCursor{ at[i], at[i], false, i == 0 }; }
    cur_install(&c[0], n);
}

// an offset put where decoding its line lands, as col_snap does a column
private i64 pos_snap(i64 pos) {
    i32 l = tb_line_of(pos);
    i64 ls = tb_line_start(l);
    return ls + col_snap(l, pos - ls);
}

private void cur_install(EdCursor* c, i32 n) {
    i64 len = tb_len();
    for i32 i = 0; i < n; i++ {
        if c[i].caret < 0 { c[i].caret = 0; }
        if c[i].caret > len { c[i].caret = len; }
        if c[i].anchor < 0 { c[i].anchor = 0; }
        if c[i].anchor > len { c[i].anchor = len; }
        // Snapped before the merge, not after: in bytes that are not
        // valid utf-8 two carets a byte apart can snap to one place,
        // and snapped after the merge they stayed two cursors there.
        c[i].caret = pos_snap(c[i].caret);
        c[i].anchor = pos_snap(c[i].anchor);
    }
    cur_sort(c, n);
    n = cur_merge(c, n);
    i32 p = 0;
    for i32 i = 0; i < n; i++ {
        if c[i].prim {
            p = i;
            break;
        }
    }
    set_caret_abs(c[p].caret);
    sel_active = c[p].sel;
    sel_anchor = c[p].anchor;
    g_ncur = 0;
    for i32 i = 0; i < n; i++ {
        if i == p || g_ncur == CUR_MAX { continue; }
        g_cur[g_ncur] = c[i];
        g_cur[g_ncur].prim = false;
        g_ncur++;
    }
}

private void cur_collapse() {
    if g_ncur == 0 { return; }
    g_ncur = 0;
    plat_damage();
}

// primary first, then the secondaries; the caller sorts if it cares
private i32 cur_gather(EdCursor* c) {
    c[0] = EdCursor{ cur_abs(), sel_anchor, sel_active, true };
    for i32 i = 0; i < g_ncur; i++ {
        c[i + 1] = g_cur[i];
        c[i + 1].prim = false;
    }
    return g_ncur + 1;
}

// A restored set can name offsets the buffer no longer has: another
// pane on the same buffer may have edited it since. cur_install is
// the path that clamps, sorts and merges, so reuse it.
private void cur_reclamp() {
    if g_ncur == 0 { return; }
    noinit EdCursor[CUR_MAX + 1] c;
    i32 n = cur_gather(&c[0]);
    cur_install(&c[0], n);
}

private void op_run(i32 op) {
    if op == OP_CHAR { ed_char(op_cp); return; }
    if op == OP_INSTXT {
        if op_txt_len > 0 { ed_insert(op_txt, op_txt_len); }
        return;
    }
    if op == OP_ENTER { ed_enter(); return; }
    if op == OP_TAB { ed_tab(); return; }
    if op == OP_BACKSPACE { ed_backspace(); return; }
    if op == OP_DELETE { ed_delete(); return; }
    if op == OP_DELWL { ed_del_word_left(); return; }
    if op == OP_DELWR { ed_del_word_right(); return; }
    if op == OP_DELSEL {
        i64 a = 0;
        i64 b = 0;
        if ed_sel_range(&a, &b) { ed_replace(a, b - a, null, 0); }
        return;
    }
    bool sh = op_shift;
    if op == OP_LEFT {
        if !sh && sel_nonempty() {
            sel_collapse(true);
            return;
        }
        sel_move_begin(sh);
        mv_left();
        return;
    }
    if op == OP_RIGHT {
        if !sh && sel_nonempty() {
            sel_collapse(false);
            return;
        }
        sel_move_begin(sh);
        mv_right();
        return;
    }
    if op == OP_UP { sel_move_begin(sh); mv_vert(-1); return; }
    if op == OP_DOWN { sel_move_begin(sh); mv_vert(1); return; }
    if op == OP_WORDL { sel_move_begin(sh); mv_word_left(); return; }
    if op == OP_WORDR { sel_move_begin(sh); mv_word_right(); return; }
    // with wrap, Home and End go to the row's edge first, and from there
    // to the line's
    if op == OP_HOME {
        sel_move_begin(sh);
        i64 to = 0;
        if ed_wrap_on() {
            ignore wrap_line(cur_line);
            i32 k = wrap_row_of_col(cast(i32, cur_col));
            if cur_col > wrap_row_start(k) { to = wrap_row_start(k); }
        }
        cur_col = to;
        goal_vcol = -1;
        after_move();
        return;
    }
    if op == OP_END {
        sel_move_begin(sh);
        i64 to = line_len(cur_line);
        if ed_wrap_on() {
            i32 rows = wrap_line(cur_line);
            i32 k = wrap_row_of_col(cast(i32, cur_col));
            if k + 1 < rows {
                i64 e = col_before(cur_line, wrap_row_start(k + 1));
                if cur_col < e { to = e; }
            }
        }
        cur_col = to;
        goal_vcol = -1;
        after_move();
    }
}

// Run one action at every cursor. Cursors run highest offset first, so
// an edit never moves a cursor that has not run yet. The ones that
// have run are a different matter: each later edit sits below them and
// shifts them, so what they recorded is in the text as it stood then,
// not in the text this ends with. The pass at the end puts that back.
// With one cursor this is the bare op, which keeps the undo coalescing
// of a normal typing run intact.
private void multi_apply(i32 op) {
    if g_ncur == 0 {
        op_run(op);
        return;
    }
    noinit EdCursor[CUR_MAX + 1] c;
    noinit i64[CUR_MAX + 1] dl;
    i32 n = cur_gather(&c[0]);
    cur_sort(&c[0], n);
    g_ncur = 0;
    i32 base = undo_len;
    for i32 i = n - 1; i >= 0; i-- {
        set_caret_abs(c[i].caret);
        sel_active = c[i].sel;
        sel_anchor = c[i].anchor;
        // no coalescing inside one action: every cursor gets its own
        // entry, and the chain below is what undoes them together
        undo_break = true;
        undo_cont = undo_len > base;
        i64 len0 = tb_len();
        op_run(op);
        dl[i] = tb_len() - len0;
        c[i].caret = cur_abs();
        c[i].anchor = sel_anchor;
        c[i].sel = sel_active;
    }
    // shift each cursor by what the edits below it added or removed
    i64 acc = 0;
    for i32 i = 0; i < n; i++ {
        c[i].caret += acc;
        c[i].anchor += acc;
        acc += dl[i];
    }
    undo_cont = false;
    undo_break = true;
    cur_install(&c[0], n);
    goal_vcol = -1;
    after_move();
}

// Add a cursor, keeping the set sorted and merged. The new one becomes
// the primary, so the view scrolls to what was just added; a merge
// carries the flag over when it lands on a cursor already there.
private void cur_add(i64 caret, i64 anchor, bool sel) {
    if g_ncur + 1 >= CUR_MAX { return; }
    noinit EdCursor[CUR_MAX + 1] c;
    i32 n = cur_gather(&c[0]);
    c[0].prim = false;
    c[n] = EdCursor{ caret, anchor, sel, true };
    n++;
    cur_install(&c[0], n);
    after_move();
}

// Ctrl+Alt+Up/Down: a cursor on the next line, in the same column.
// It grows from whichever end of the set is in that direction, so
// repeating extends the column rather than toggling.
private void cur_add_vert(i32 dir) {
    i32 v = goal_vcol;
    if v < 0 { v = vcol_of_col(cur_line, cur_col); }
    i32 edge = cur_line;
    for i32 i = 0; i < g_ncur; i++ {
        i32 l = tb_line_of(g_cur[i].caret);
        if dir < 0 && l < edge { edge = l; }
        if dir > 0 && l > edge { edge = l; }
    }
    i32 nl = edge + dir;
    if nl < 0 || nl >= tb.nlines { return; }
    i64 pos = tb_line_start(nl) + col_of_vcol(nl, v);
    cur_add(pos, pos, false);
    goal_vcol = v;   // the column survives, so the next add stays in it
}

private const i32 MATCH_MAX = 512;        // longest text Ctrl+D matches
private const i32 CUR_SCAN_CHUNK = 65536;
private u8* cur_scan_buf = null;

// Next exact occurrence of `pat` at or after `start`, wrapping once.
// Chunked through tb_copy, like the find widget, so the gap never has
// to be closed to search.
private i64 cur_find_next(u8* pat, i32 pn, i64 start) {
    i64 len = tb_len();
    if pn <= 0 || cast(i64, pn) > len { return -1; }
    if cur_scan_buf == null {
        cur_scan_buf = alloc<u8>(CUR_SCAN_CHUNK + MATCH_MAX);
    }
    i64 first = start;
    if first < 0 { first = 0; }
    for i32 pass = 0; pass < 2; pass++ {
        i64 pos = first;
        i64 stop = len;
        if pass == 1 {
            // the wrap only has to reach far enough to re-find the
            // match the search started from
            pos = 0;
            stop = first + cast(i64, pn) - 1;
            if stop > len { stop = len; }
        }
        while pos + cast(i64, pn) <= stop {
            i64 n = stop - pos;
            i64 cap = cast(i64, CUR_SCAN_CHUNK) + cast(i64, pn) - 1;
            if n > cap { n = cap; }
            tb_copy(pos, cur_scan_buf, n);
            i64 lim = n - cast(i64, pn);
            for i64 i = 0; i <= lim; i++ {
                bool m = true;
                for i32 k = 0; k < pn; k++ {
                    if cur_scan_buf[i + k] != pat[k] {
                        m = false;
                        break;
                    }
                }
                if m { return pos + i; }
            }
            pos += CUR_SCAN_CHUNK;
        }
    }
    return -1;
}

// Ctrl+D: with no selection, take the word under the caret; with one,
// add a cursor on the next occurrence of it.
private void ed_add_next_match() {
    i64 a = 0;
    i64 b = 0;
    if !ed_sel_range(&a, &b) {
        i32 s = 0;
        i32 e = 0;
        if !word_bounds(&s, &e) { return; }
        i64 ls = tb_line_start(cur_line);
        sel_set_anchor(ls + s);
        set_caret_abs(ls + e);
        undo_break = true;
        goal_vcol = -1;
        after_move();
        return;
    }
    i32 pn = cast(i32, b - a);
    if pn > MATCH_MAX {
        ed_status("selection too long to match");
        return;
    }
    noinit u8[MATCH_MAX] pat;
    tb_copy(a, &pat[0], pn);
    i64 last = b;
    for i32 i = 0; i < g_ncur; i++ {
        i64 qa = 0;
        i64 qb = 0;
        cur_range(&g_cur[i], &qa, &qb);
        if qb > last { last = qb; }
    }
    i64 at = cur_find_next(&pat[0], pn, last);
    if at < 0 { return; }
    // wrapped onto a cursor already in the set: every occurrence has
    // one, so say so rather than silently doing nothing
    bool have = at == a;
    for i32 i = 0; i < g_ncur; i++ {
        if cur_key(&g_cur[i]) == at { have = true; }
    }
    if have {
        ed_status("all occurrences selected");
        return;
    }
    cur_add(at + cast(i64, pn), at, true);
}

// Every cursor's selection, in document order, joined by newlines.
// That is the shape a paste back into the same cursor set expects.
private void multi_clip_copy() {
    noinit EdCursor[CUR_MAX + 1] c;
    i32 n = cur_gather(&c[0]);
    cur_sort(&c[0], n);
    i64 total = 0;
    for i32 i = 0; i < n; i++ {
        i64 a = 0;
        i64 b = 0;
        cur_range(&c[i], &a, &b);
        total += b - a;
    }
    if total == 0 { return; }
    total += cast(i64, n) - 1;
    u8* buf = alloc<u8>(total);
    i64 w = 0;
    for i32 i = 0; i < n; i++ {
        if i > 0 {
            buf[w] = '\n';
            w++;
        }
        i64 a = 0;
        i64 b = 0;
        cur_range(&c[i], &a, &b);
        if b > a {
            tb_copy(a, buf + w, b - a);
            w += b - a;
        }
    }
    plat_clipboard_set(buf, w);
    free(buf);
}

// --- undo journal ----------------------------------------------------

private bool undo_has_nl(u8* s, i32 n) {
    for i32 i = 0; i < n; i++ {
        if s[i] == '\n' { return true; }
    }
    return false;
}

private void undo_drop_redo() {
    for i32 i = undo_len; i < undo_total; i++ {
        UndoOp* op = undo_ops + i;
        if op.ins != null { free(op.ins); }
        if op.del != null { free(op.del); }
    }
    undo_total = undo_len;
    if undo_saved > undo_len { undo_saved = -1; }
}

private u8* undo_concat(u8* a, i32 an, u8* b, i32 bn) {
    u8* r = alloc<u8>(an + bn);
    if an > 0 { memcpy(r, a, an); }
    if bn > 0 { memcpy(r + an, b, bn); }
    return r;
}

// takes ownership of del and ins
private void undo_push(i64 pos, u8* del, i32 del_len, u8* ins, i32 ins_len, i64 caret_before) {
    undo_drop_redo();
    if !undo_break && undo_len > 0 {
        UndoOp* last = undo_ops + (undo_len - 1);
        // typing run: append to a pure insert
        if del_len == 0 && last.del_len == 0 && ins_len > 0 && last.ins_len > 0
            && pos == last.pos + last.ins_len
            && !undo_has_nl(ins, ins_len) && !undo_has_nl(last.ins, last.ins_len) {
            u8* merged = undo_concat(last.ins, last.ins_len, ins, ins_len);
            free(last.ins);
            free(ins);
            last.ins = merged;
            last.ins_len += ins_len;
            return;
        }
        // backspace run: prepend to a pure delete
        if ins_len == 0 && last.ins_len == 0 && del_len > 0 && last.del_len > 0
            && pos + cast(i64, del_len) == last.pos
            && !undo_has_nl(del, del_len) && !undo_has_nl(last.del, last.del_len) {
            u8* merged = undo_concat(del, del_len, last.del, last.del_len);
            free(last.del);
            free(del);
            last.del = merged;
            last.del_len += del_len;
            last.pos = pos;
            return;
        }
        // delete-key run: append to a pure delete at the same spot
        if ins_len == 0 && last.ins_len == 0 && del_len > 0 && last.del_len > 0
            && pos == last.pos
            && !undo_has_nl(del, del_len) && !undo_has_nl(last.del, last.del_len) {
            u8* merged = undo_concat(last.del, last.del_len, del, del_len);
            free(last.del);
            free(del);
            last.del = merged;
            last.del_len += del_len;
            return;
        }
    }
    if undo_len == undo_cap {
        i32 ncap = undo_cap * 2 + 64;
        UndoOp* no = alloc<UndoOp>(ncap);
        if undo_ops != null {
            memcpy(no, undo_ops, undo_len * sizeof(UndoOp));
            free(undo_ops);
        }
        undo_ops = no;
        undo_cap = ncap;
    }
    undo_ops[undo_len] = UndoOp{ pos, caret_before, ins, ins_len, del, del_len,
        undo_cont };
    undo_len++;
    undo_total = undo_len;
    undo_break = false;
}

// dirty = edits since the save point (undo can reach it again)
private void undo_update_dirty() {
    tb.dirty = undo_len != undo_saved;
}

// drop the whole journal (the buffer is being replaced)
private void undo_clear() {
    undo_len = 0;
    undo_drop_redo();
    undo_saved = 0;
    undo_break = true;
}

// undo_clear empties the journal but keeps its array, which is what a
// buffer being reloaded wants. A buffer going away owns the array too.
private void undo_free() {
    undo_clear();
    if undo_ops != null {
        free(undo_ops);
        undo_ops = null;
    }
    undo_cap = 0;
    undo_total = 0;
}

// --- editing ---------------------------------------------------------

// the one write path: remove ndel bytes at pos, insert nins from s
private void ed_replace(i64 pos, i64 ndel, u8* s, i32 nins) {
    if ndel <= 0 && nins <= 0 { return; }
    if g_img >= 0 || g_rev { return; }
    u8* del = null;
    if ndel > 0 {
        del = alloc<u8>(ndel);
        tb_copy(pos, del, ndel);
    }
    u8* ins = null;
    if nins > 0 {
        ins = alloc<u8>(nins);
        memcpy(ins, s, nins);
    }
    i64 caret_before = cur_abs();
    i32 edit_line = tb_line_of(pos);
    if ndel > 0 { tb_delete(pos, ndel); }
    if nins > 0 { tb_insert(pos, ins, nins); }
    undo_push(pos, del, cast(i32, ndel), ins, nins, caret_before);
    undo_update_dirty();
    set_caret_abs(pos + nins);
    sel_clear();
    goal_vcol = -1;
    after_edit(edit_line);
}

private void ed_insert(u8* s, i32 n) {
    if g_img >= 0 || g_rev { return; }
    i64 pos = cur_abs();
    i64 ndel = 0;
    i64 a = 0;
    i64 b = 0;
    if ed_sel_range(&a, &b) {
        pos = a;
        ndel = b - a;
    }
    ed_replace(pos, ndel, s, n);
}

private void ed_backspace() {
    i64 a = 0;
    i64 b = 0;
    if ed_sel_range(&a, &b) {
        ed_replace(a, b - a, null, 0);
        return;
    }
    if cur_col > 0 {
        i32 n = line_bytes(cur_line);  // fills g_linebuf
        i32 p = grapheme_prev(g_linebuf, n, cast(i32, cur_col));
        ed_replace(tb_line_start(cur_line) + p, cur_col - p, null, 0);
    } else if cur_line > 0 {
        ed_replace(tb_line_start(cur_line) - 1, 1, null, 0);
    }
}

private void ed_delete() {
    i64 a = 0;
    i64 b = 0;
    if ed_sel_range(&a, &b) {
        ed_replace(a, b - a, null, 0);
        return;
    }
    i64 llen = line_len(cur_line);
    if cur_col < llen {
        i32 n = line_bytes(cur_line);
        i32 p = cast(i32, cur_col);
        ignore grapheme_next_w(g_linebuf, n, &p);
        ed_replace(cur_abs(), p - cur_col, null, 0);
    } else if cur_line + 1 < tb.nlines {
        ed_replace(cur_abs(), 1, null, 0);
    }
}

private void ed_enter() {
    // newline + the current line's leading whitespace
    noinit u8[INDENT_MAX + 4] ins;
    ins[0] = '\n';
    i32 n = 1;
    i32 ll = line_bytes(cur_line);
    i32 i = 0;
    while i < ll && i < cast(i32, cur_col) && n < INDENT_MAX {
        u8 c = g_linebuf[i];
        if c != ' ' && c != '\t' { break; }
        ins[n] = c;
        n++;
        i++;
    }
    ed_insert(&ins[0], n);
}

private void ed_tab() {
    // the spaces reach the next tab stop from where they go: the
    // selection's start when they replace one
    i32 v = vcol_of_col(cur_line, cur_col);
    i64 sa = 0;
    i64 sb = 0;
    if ed_sel_range(&sa, &sb) {
        i32 sl = tb_line_of(sa);
        v = vcol_of_col(sl, sa - tb_line_start(sl));
    }
    i32 ns = TABW - v % TABW;
    u8[4] sp = { ' ', ' ', ' ', ' ' };
    ed_insert(&sp[0], ns);
}

private void ed_char(u32 cp) {
    noinit u8[8] enc;
    i32 n = utf8_encode(cp, &enc[0]);
    ed_insert(&enc[0], n);
}

// A save refuses once when the file on disk is no longer what the
// buffer was loaded from or last saved as, so a change made outside the
// editor is not overwritten unseen. The check reads the file, which
// also covers a platform with no watcher.
private bool g_save_armed = false;

// the file at p differs from the one the buffer was loaded from
private bool disk_differs(str p) {
    if !tb.disk_known { return false; }
    FileData fd = file_read(p);
    if fd.data == null { return false; }   // deleted: saving puts it back
    i64 n = cast(i64, fd.len);
    bool same = n == tb.disk_len && tb_hash(fd.data, n) == tb.disk_hash;
    free(fd.data);
    return !same;
}

private void ed_save() {
    // the buffer holds no text: writing it would empty the image file
    if g_img >= 0 {
        ed_status("images open read-only");
        return;
    }
    if g_rev {
        ed_status("a commit's version opens read-only");
        return;
    }
    if !g_has_path {
        // the platform's dialog in the project folder where it has one,
        // the input box otherwise
        noinit u8[PATH_MAX] cwd;
        i32 cn = plat_cwd(&cwd[0], PATH_MAX);
        if !plat_pick_save(str_from(&cwd[0], cn), "") { ask_open(); }
        return;
    }
    str p = str_from(&g_path[0], g_path_len);
    if !g_save_armed && disk_differs(p) {
        g_save_armed = true;
        ed_warn("the file changed on disk: save again to overwrite it");
        plat_damage();
        return;
    }
    g_save_armed = false;
    if tb_save(p) {
        // No baseline fetch here: HEAD does not move when a file is
        // saved, and the marks follow the edits already. The tree's
        // status does change on a save, and that runs on the worker,
        // never waited for.
        git_status_touch();
        undo_saved = undo_len;
        undo_break = true;
        g_close_armed = false;
        g_preview = false;
        update_title();
        if settings_is_path(p) { settings_load(); }
        plat_damage();
    } else {
        ed_warn("save failed");
    }
}

// --- the input box: save-as and open folder ------------------------------
// A panel at the top of the window, the shape of the picker's: a title,
// the input, and under it the last message about what was typed.

bool ask_on = false;   // the view draws the box while set
u8[PATH_MAX] ask_buf;
i32 ask_len = 0;
private UiField g_ask_field;
private bool ask_armed = false;   // Enter seen once on an existing path

// the prompt's line as a field, bound to its bytes; the view draws it
UiField* ask_field() {
    ui_field_bind(&g_ask_field, &ask_buf[0], &ask_len, PATH_MAX - 1);
    return &g_ask_field;
}
private const i32 ASK_SAVE = 0;
private const i32 ASK_FOLDER = 1;
private i32 ask_mode = ASK_SAVE;
private bool chord_k = false;     // Ctrl+K seen; the next key completes the chord
private bool chord_eat = false;   // the key that ended a chord has its character coming
// Shift+Tab outdented; Windows sends a Tab character after it, which is
// the key's and not text. Any other key or character clears it.
private bool tab_eat = false;

// what the box asks for, its title
str ask_label() {
    if ask_mode == ASK_FOLDER { return "Open Folder"; }
    return "Save As";
}

// the input's placeholder while it is empty
str ask_hint() {
    if ask_mode == ASK_FOLDER { return "a folder path"; }
    return "a file path, relative to the project folder";
}

// the message under the input: the last warning or note since it opened
str ask_message() {
    return str_from(&g_status_msg[0], g_status_len);
}

private const i32 ASK_COLS = 72;   // the box's width in cells, clamped

// The box in window pixels: x, y, width, and height. The rows are the
// title, the input, and the message.
void ask_box(i32* x, i32* y, i32* w, i32* h) {
    i32 pad = ui_list_pad();
    *w = ui_list_panel_w(ASK_COLS);
    *x = (g_w - *w) / 2;
    *y = pad;
    *h = pad + ui_list_row_h() + ui_input_h() + ui_list_row_h() + pad;
}

// a press while the box is up: outside it closes it, inside does nothing
private void ask_mouse(i32 x, i32 y) {
    i32 bx = 0;
    i32 by = 0;
    i32 bw = 0;
    i32 bh = 0;
    ask_box(&bx, &by, &bw, &bh);
    if x < bx || x >= bx + bw || y < by || y >= by + bh { ask_close(); }
}

private void ask_open_mode(i32 mode) {
    ask_mode = mode;
    ask_on = true;
    ask_len = 0;
    ask_armed = false;
    g_status_len = 0;
    g_close_armed = false;
    plat_damage();
}

private void ask_open() {
    ask_open_mode(ASK_SAVE);
}

private void ask_close() {
    ask_on = false;
    plat_damage();
}

// Another project: the working directory moves, and everything that
// was scoped to the old one goes with it. Buffers are closed, since
// their paths were relative to it; an unsaved one refuses the switch.
// The server stops and starts again in the new root on the next .mc
// file, the tree and the picker rescan, the history is dropped.
private bool bufs_dirty() {
    if tb.dirty { return true; }
    for i32 i = 0; i < g_nbufs; i++ {
        if i != g_buf_active && g_bufs[i].tb.dirty { return true; }
    }
    return false;
}

bool ed_open_folder(str dir) {
    if bufs_dirty() {
        ed_warn("save or discard the unsaved buffers first");
        plat_damage();
        return false;
    }
    bool sess = g_session_on;
    if sess { app_session_save(); }   // the old project, in the old cwd
    if !plat_chdir(dir) {
        ed_warn("not a folder");
        plat_damage();
        return false;
    }
    watch_stop();
    g_session_loading = true;   // the teardown's own saves stay quiet
    lsp_stop();
    while ed_pane_count() > 1 { ignore ed_pane_close(); }
    ed_term_close_all();   // the background ones too: they are in the old folder
    build_pane_closed();
    while ed_buf_count() > 1 { ed_buf_close(); }
    ed_buf_close();   // the last one becomes untitled
    nav_nback = 0;
    nav_nfwd = 0;
    sem_clear();
    search_close_view();
    git_forget_repo();
    hist_reset();
    tree_build();
    git_status_touch();
    tree_on = true;
    proj_refresh();
    g_session_loading = false;
    if sess { session_load(); }   // the new project's open files, if any
    watch_start();
    update_title();
    recent_note();
    ed_status("opened folder");
    plat_damage();
    return true;
}

// whether path p exists; a browser has no path query, but its file
// sizes it can answer
bool ed_path_exists(str p) {
    when os(wasm) {
        return file_size(p) >= 0;
    } else {
        return path_exists(p);
    }
}

// Creates an empty file at p, relative to the project folder, with the
// directories it names, and opens it in a kept tab. False leaves a
// warning: p names no file, or one that exists, or the write failed.
bool ed_new_file(str p) {
    if p.len == 0 || p.len >= PATH_MAX || p.data[p.len - 1] == '/' || p.data[p.len - 1] == '\\' {
        ed_warn("name the file");
        return false;
    }
    if ed_path_exists(p) {
        ed_warn("file exists");
        return false;
    }
    for i32 k = 1; k < p.len; k++ {
        if p.data[k] == '/' || p.data[k] == '\\' { ignore dir_create(str_from(p.data, k)); }
    }
    if !file_write_str(p, "") {
        ed_warn("cannot create the file");
        return false;
    }
    if tree_on { tree_reveal(p); }
    tree_focus = false;
    return ed_open_file(p);
}

// Ctrl+K F: a new file named in the tree, in the folder selected there
void ed_new_file_ask() {
    if search_on { search_close_view(); }
    noinit u8[PATH_MAX] d;
    i32 n = 0;
    if tree_on { n = tree_sel_folder(&d[0], PATH_MAX); }
    if n > 0 { n--; }   // without its '/'
    find_close();
    search_focus = false;
    tree_new_entry(str_from(&d[0], n), false);
}

// the absolute form of a project-relative path, with the platform's
// separators; an absolute path as given. Returns the length in out.
i32 ed_abs_path(str p, u8* out) {
    bool abs = p.len > 0 && (p.data[0] == '/' || p.data[0] == '\\');
    if p.len > 1 && p.data[1] == ':' { abs = true; }
    i32 n = 0;
    if !abs {
        n = plat_cwd(out, PATH_MAX);
        if n > 0 && n < PATH_MAX - 1 && out[n - 1] != '/' && out[n - 1] != '\\' {
            out[n] = '/';
            n++;
        }
    }
    if n + p.len > PATH_MAX { return n; }
    memcpy(out + n, p.data, p.len);
    n += p.len;
    when os(windows) {
        for i32 i = 0; i < n; i++ {
            if out[i] == '/' { out[i] = '\\'; }
        }
    }
    return n;
}

// A file opened in another column than the active pane's: the nearest
// document column to the right, else the nearest to the left. Only a
// layout with no other document column gets a new split, so the result
// does not depend on which of two columns has the focus.
void ed_open_to_side(str p) {
    if diff_on { ed_diff_close(); }
    i32 cols = pane_cols();
    i32 base = g_pane_active;
    if pane_is_bottom(base) { base = cols; }
    i32 target = -1;
    for i32 c = base + 1; c < cols && target < 0; c++ {
        if g_panes[c].kind == PANE_DOC { target = c; }
    }
    for i32 c = base - 1; c >= 0 && target < 0; c-- {
        if g_panes[c].kind == PANE_DOC { target = c; }
    }
    if target >= 0 {
        ed_pane_focus(target);
    } else {
        ed_pane_split();
    }
    ignore ed_open_file(p);
    tree_focus = false;
}

// the path n bytes at p becomes, when it is `old` or, for a folder,
// under it; 0 when it is neither
private i32 path_moved(u8* p, i32 n, str old, str now, bool dir, u8* out) {
    if n < old.len || !str_equal(str_from(p, old.len), old) { return 0; }
    if n > old.len && !(dir && p[old.len] == '/') { return 0; }
    i32 m = now.len + n - old.len;
    if m >= PATH_MAX { return 0; }
    memcpy(out, now.data, now.len);
    memcpy(out + now.len, p + old.len, n - old.len);
    return m;
}

// buffer i's path, or an empty one when it has none
private str buf_path_of(i32 i) {
    if i == g_buf_active {
        if !g_has_path { return str_from(&g_path[0], 0); }
        return str_from(&g_path[0], g_path_len);
    }
    if !g_bufs[i].has_path { return str_from(&g_bufs[i].path[0], 0); }
    return str_from(&g_bufs[i].path[0], g_bufs[i].path_len);
}

// A file or folder deleted from the tree: the buffers of it, or of what
// was under the folder, close. One with unsaved changes stays open, so
// the changes can still be saved somewhere; returns how many stayed.
i32 ed_paths_deleted(str p, bool dir) {
    noinit u8[PATH_MAX] scratch;
    i32 keep = g_buf_active;   // shown again afterwards, unless it closed
    bool keep_gone = false;
    i32 stayed = 0;
    for i32 i = g_nbufs - 1; i >= 0; i-- {
        str bp = buf_path_of(i);
        if bp.len == 0 || path_moved(bp.data, bp.len, p, p, dir, &scratch[0]) == 0 { continue; }
        if ed_buf_dirty(i) {
            stayed++;
            continue;
        }
        if i == keep { keep_gone = true; }
        if i < keep { keep--; }
        ed_buf_switch(i);
        g_close_armed = false;
        ed_buf_close();
    }
    if !keep_gone && keep >= 0 && keep < g_nbufs && keep != g_buf_active { ed_buf_switch(keep); }
    plat_damage();
    return stayed;
}

// A file or folder moved on disk (a rename in the tree): every buffer at
// the old path, or under the old folder, takes the new one. The server
// hears the old name close; the active buffer opens under the new one
// at once, the others when they are shown.
void ed_paths_moved(str old, str now, bool dir) {
    noinit u8[PATH_MAX] np;
    if g_has_path {
        i32 m = path_moved(&g_path[0], g_path_len, old, now, dir, &np[0]);
        if m > 0 {
            lsp_did_close(str_from(&g_path[0], g_path_len));
            memcpy(&g_path[0], &np[0], m);
            g_path_len = m;
            lex_set_for(str_from(&g_path[0], g_path_len));
            g_lex_valid = 0;
            git_reload(str_from(&g_path[0], g_path_len));
        }
    }
    for i32 i = 0; i < g_nbufs; i++ {
        if i == g_buf_active || !g_bufs[i].has_path { continue; }
        EdBuffer* b = &g_bufs[i];
        i32 m = path_moved(&b.path[0], b.path_len, old, now, dir, &np[0]);
        if m == 0 { continue; }
        lsp_did_close(str_from(&b.path[0], b.path_len));
        memcpy(&b.path[0], &np[0], m);
        b.path_len = m;
        i32 lang = lex_lang_of(str_from(&b.path[0], m));
        b.lex_on = lang >= 0;
        b.lex_lang = LANG_MINC;
        if lang >= 0 { b.lex_lang = lang; }
        b.lex_valid = 0;
    }
    update_title();
    ed_lsp_sync();
    app_session_save();
    plat_damage();
}

// an empty untitled buffer in a new tab; the active buffer is that
// already when it is untitled, clean and empty
void ed_new_untitled() {
    term_leave_for_doc();
    tree_focus = false;
    if diff_on && g_pane_active <= 1 { ed_diff_close(); }
    if !g_has_path && !g_rev && g_img < 0 && !tb.dirty && tb_len() == 0 {
        plat_damage();
        return;
    }
    ed_lsp_flush();
    buf_soft_evict();
    if g_nbufs == BUF_MAX {
        i32 v = buf_victim();
        if v < 0 {
            ed_notice("cannot open: every open buffer is unsaved or on screen. Save or close some (ctrl+s, ctrl+w) and try again.");
            return;
        }
        buf_evict(v);
    }
    buf_store(g_buf_active);
    g_buf_active = g_nbufs;
    g_nbufs++;
    buf_touch(g_buf_active);
    buf_fresh();
    tb_init_empty();
    scroll_set(0);
    pane_save(g_pane_active);
    update_title();
    after_move();
    app_session_save();
}

private void ask_commit() {
    if ask_len == 0 {
        ask_close();
        return;
    }
    str p = str_from(&ask_buf[0], ask_len);
    if ask_mode == ASK_FOLDER {
        // the prompt stays until the folder opens, or Esc
        if ed_open_folder(p) { ask_close(); }
        return;
    }
    if !ask_armed && ed_path_exists(p) {
        ask_armed = true;
        ed_warn("file exists: enter again to overwrite");
        return;
    }
    ask_close();
    ed_save_as(p);
}

// the buffer takes the path p and is saved there
private void ed_save_as(str p) {
    if p.len == 0 || p.len >= PATH_MAX { return; }
    memcpy(&g_path[0], p.data, p.len);
    g_path_len = p.len;
    g_has_path = true;
    lex_set_for(str_from(&g_path[0], g_path_len));
    g_lex_valid = 0;
    ed_save();
}

// An absolute path inside the project folder as a relative one with
// '/' separators, the form the tree and the picker use; any other path
// as given. Writes it to out and returns its length.
private i32 path_in_project(str p, u8* out) {
    noinit u8[PATH_MAX] cwd;
    i32 cn = plat_cwd(&cwd[0], PATH_MAX);
    while cn > 1 && (cwd[cn - 1] == '/' || cwd[cn - 1] == '\\') { cn--; }
    bool inside = cn > 0 && p.len > cn + 1 && (p.data[cn] == '/' || p.data[cn] == '\\');
    for i32 i = 0; inside && i < cn; i++ {
        u8 a = p.data[i];
        u8 b = cwd[i];
        if a == '\\' { a = '/'; }
        if b == '\\' { b = '/'; }
        // Windows and macOS file systems ignore case by default
        when os(windows) {
            a = ascii_lower(a);
            b = ascii_lower(b);
        }
        when os(macos) {
            a = ascii_lower(a);
            b = ascii_lower(b);
        }
        if a != b { inside = false; }
    }
    if !inside {
        memcpy(out, p.data, p.len);
        return p.len;
    }
    i32 n = p.len - cn - 1;
    for i32 i = 0; i < n; i++ {
        u8 c = p.data[cn + 1 + i];
        if c == '\\' { c = '/'; }
        out[i] = c;
    }
    return n;
}

// the platform's save dialog answered: the path, or len 0 on cancel
void app_save_picked(u8* path, i32 len) {
    if len <= 0 || len >= PATH_MAX {
        plat_damage();
        return;
    }
    noinit u8[PATH_MAX] rel;
    i32 n = path_in_project(str_from(path, len), &rel[0]);
    ed_save_as(str_from(&rel[0], n));
}

private void ask_char(u32 cp) {
    if cp == 13 { ask_commit(); return; }
    if ui_field_char(ask_field(), cp) {
        ask_armed = false;
        plat_damage();
    }
}

private void ask_key(i32 key, i32 mods) {
    bool changed = false;
    if ui_field_key(ask_field(), key, mods, &changed) {
        if changed { ask_armed = false; }
        plat_damage();
        return;
    }
    if (mods & MOD_CTRL) != 0 { return; }
    if key == K_ESCAPE { ask_close(); }
}

// --- buffer list -----------------------------------------------------
// The active buffer lives in the globals above; inactive buffers are
// parked here and swapped wholesale on switch, so the editing paths
// never indirect. Slot order is tab order. A full table gives up its
// least recently shown buffer that is saved and on no pane; only when
// every slot is unsaved or on screen does an open fail, and then the
// notice says so.

const i32 BUF_MAX = 128;

private struct EdBuffer {
    TextBuf tb;
    u8[PATH_MAX] path;
    i32 path_len;
    bool has_path;
    bool lex_on;
    i32 lex_lang;
    i32 cur_line;
    i64 cur_col;
    i32 scroll_y;
    i32 scroll_cols;   // the wrap width scroll_y counts rows at, 0 for lines
    i32 left_vcol;
    bool sel_active;
    i64 sel_anchor;
    EdCursor[CUR_MAX] cur;
    i32 ncur;
    GitState git;
    UndoOp* undo_ops;
    i32 undo_cap;
    i32 undo_len;
    i32 undo_total;
    i32 undo_saved;
    u8* lexstate;
    i32 lex_cap;
    i32 lex_valid;
    WrapCache[WRAP_SLOTS] wrap;   // its rows per line at two widths (wrap.mc)
    i64 used;     // g_buf_tick when last shown: the eviction order
    bool preview;   // merely looked at, never edited or asked to stay
    // an image the buffer shows instead of text (image.mc): its index
    // plus one, so a record never stored (zeroed) holds text
    i32 img1;
    bool rev;                    // a file as a commit had it (ed_rev_diff)
    u8[REV_NAME_MAX] rev_name;
    i32 rev_name_len;
}

private EdBuffer[BUF_MAX] g_bufs;

// The loaded buffer's image, the live copy of EdBuffer.img: -1 for text.
// An image buffer holds no text and takes none; the view draws the
// image instead (image.mc).
i32 g_img = -1;

// The loaded buffer holds a file as a commit had it, the right side of
// a commit's diff (ed_rev_diff). It has no path, so the disk, the
// session, git's fetches and the server pass it by like an untitled
// buffer. It takes no edits and is never saved. g_rev_name is its label.
const i32 REV_NAME_MAX = 320;
bool g_rev = false;
private u8[REV_NAME_MAX] g_rev_name;
private i32 g_rev_name_len = 0;

// The baseline side of a diff: what the file is at HEAD. It is not a
// slot in the table, since nothing that holds for a document holds for
// it - it is never picked, evicted, saved, restored into a session or
// asked about by the server. A pane names it with this instead of an
// index, and the swap loads it from here.
const i32 BUF_DIFF_BASE = -1;
private EdBuffer g_diff_base;
private i32 g_nbufs = 1;
private i32 g_buf_active = 0;
private i64 g_buf_tick = 0;

// The active buffer's preview flag, the live copy of EdBuffer.preview.
// A file opened by a look (the tree, a definition, a search hit, a
// build problem, the history) is a preview, and only the last few looks
// stay: a look past PREVIEW_MAX drops the one looked at longest ago
// that no pane shows, so jumping around leaves a handful of buffers,
// not a pile. An edit, a save, a double-click in the tree or Ctrl+K
// Enter keeps a buffer, and a kept one is not a look. The picker opens
// kept, as the reference's quick open does. Nothing marks a preview on
// screen; the difference is only which buffers go first.
private bool g_preview = false;
const i32 PREVIEW_MAX = 4;

// The table keeps at most this many buffers unless the rest are unsaved
// or on screen: past it an open evicts the least recently shown clean
// one, previews first. EDMINC_BUFFERS raises it, up to BUF_MAX.
const i32 BUF_SOFT_MAX = 12;
private i32 g_buf_cap = BUF_SOFT_MAX;

void ed_buf_cap_set(i32 n) {
    if n < 1 { n = 1; }
    if n > BUF_MAX { n = BUF_MAX; }
    g_buf_cap = n;
}

// slot i was just put on screen by the user
private void buf_touch(i32 i) {
    g_buf_tick++;
    g_bufs[i].used = g_buf_tick;
}

// A buffer shown to be looked at while a chord is held (the switcher's
// preview) is not "seen": the order the switcher lists buffers in
// stays what it was, so the walk ends where it would have without the
// preview.
private bool g_buf_peek = false;

private EdBuffer* buf_at(i32 i) {
    if i == BUF_DIFF_BASE { return &g_diff_base; }
    return &g_bufs[i];
}

private void buf_store(i32 i) {
    EdBuffer* b = buf_at(i);
    b.tb = tb;
    memcpy(&b.path[0], &g_path[0], g_path_len);
    b.path_len = g_path_len;
    b.has_path = g_has_path;
    b.preview = g_preview;
    b.img1 = g_img + 1;
    b.rev = g_rev;
    memcpy(&b.rev_name[0], &g_rev_name[0], g_rev_name_len);
    b.rev_name_len = g_rev_name_len;
    b.lex_on = g_lex_on;
    b.lex_lang = g_lex_lang;
    b.cur_line = cur_line;
    b.cur_col = cur_col;
    b.scroll_y = scroll_y;
    b.scroll_cols = g_scroll_cols;
    b.left_vcol = left_vcol;
    b.sel_active = sel_active;
    b.sel_anchor = sel_anchor;
    if g_ncur > 0 { memcpy(&b.cur[0], &g_cur[0], g_ncur * sizeof(EdCursor)); }
    b.ncur = g_ncur;
    git_detach(&b.git);
    b.undo_ops = undo_ops;
    b.undo_cap = undo_cap;
    b.undo_len = undo_len;
    b.undo_total = undo_total;
    b.undo_saved = undo_saved;
    b.lexstate = g_lexstate;
    b.lex_cap = g_lex_cap;
    b.lex_valid = g_lex_valid;
    for i32 s = 0; s < WRAP_SLOTS; s++ { b.wrap[s] = g_wrap_c[s]; }
}

// slot state into the globals, nothing else touched: the frame
// build swaps panes through here, so movement/undo/typing state
// (goal_vcol, coalescing, accumulators) must survive a round trip
private void buf_load(i32 i) {
    EdBuffer* b = buf_at(i);
    tb = b.tb;
    memcpy(&g_path[0], &b.path[0], b.path_len);
    g_path_len = b.path_len;
    g_has_path = b.has_path;
    g_preview = b.preview;
    g_img = b.img1 - 1;
    g_rev = b.rev;
    memcpy(&g_rev_name[0], &b.rev_name[0], b.rev_name_len);
    g_rev_name_len = b.rev_name_len;
    g_lex_on = b.lex_on;
    g_lex_lang = b.lex_lang;
    ed_lsp_follow();
    cur_line = b.cur_line;
    cur_line = clamp_line(cur_line);
    cur_col = col_snap(cur_line, b.cur_col);
    left_vcol = b.left_vcol;
    sel_active = b.sel_active;
    sel_anchor = b.sel_anchor;
    if sel_anchor > tb_len() { sel_anchor = tb_len(); }
    if sel_anchor < 0 { sel_anchor = 0; }
    g_ncur = b.ncur;
    if g_ncur > 0 { memcpy(&g_cur[0], &b.cur[0], g_ncur * sizeof(EdCursor)); }
    cur_reclamp();
    git_attach(&b.git);
    lsp_rec_invalidate();   // this buffer's edits since its push are not in the record
    undo_ops = b.undo_ops;
    undo_cap = b.undo_cap;
    undo_len = b.undo_len;
    undo_total = b.undo_total;
    undo_saved = b.undo_saved;
    g_lexstate = b.lexstate;
    g_lex_cap = b.lex_cap;
    g_lex_valid = b.lex_valid;
    for i32 s = 0; s < WRAP_SLOTS; s++ { g_wrap_c[s] = b.wrap[s]; }
    wrap_switched();
    g_buf_active = i;
    scroll_load(b.scroll_y, b.scroll_cols);
}

private void buf_restore(i32 i) {
    // A diff is one file's two sides: another buffer on screen ends it,
    // since the pairing it draws is this file's and no other's.
    if diff_on && g_pane_active <= 1 {
        bool same = g_bufs[i].has_path
            && str_equal(str_from(&g_bufs[i].path[0], g_bufs[i].path_len),
                str_from(&diff_path[0], diff_path_len));
        if !same { ed_diff_close(); }
    }
    // the popups belong to the buffer that was showing, not this one
    cmp_close();
    ed_hover_hide();
    buf_load(i);
    if !g_buf_peek { buf_touch(i); }
    // a fetch that landed while another buffer was showing was dropped;
    // ask again now that this one is the one on screen
    if g_has_path && !git_fetched() {
        git_reload(str_from(&g_path[0], g_path_len));
    }
    // the server's copy of this buffer is current: it was pushed when
    // the buffer was left, and buf_load invalidated the edit record.
    // Marking it stale here would cost this buffer its tokens, since
    // the ask below waits for a push that a switch alone never makes.
    // the token list is the buffer that was showing
    if g_has_path && !sem_is_for(str_from(&g_path[0], g_path_len)) { sem_clear(); }
    goal_vcol = -1;
    g_scroll_accum = 0.0f;
    undo_break = true;
    g_close_armed = false;
    g_save_armed = false;
    pane_save(g_pane_active);
    update_title();
    reset_blink();
    plat_damage();
    ed_lsp_sync();
}

// fresh untitled state in the globals; the caller owns slot handling
// free what the loaded buffer owns, the way a close does; the server
// hears about it when the buffer was a file of its
private void buf_free_loaded() {
    if g_has_path { lsp_did_close(str_from(&g_path[0], g_path_len)); }
    if g_img >= 0 {
        image_release(g_img);
        g_img = -1;
    }
    undo_free();
    tb_free();
    if g_lexstate != null {
        free(g_lexstate);
        g_lexstate = null;
    }
    g_lex_cap = 0;
    g_lex_valid = 0;
    wrap_free();
}

private void buf_fresh() {
    TextBuf zt;
    tb = zt;
    g_path_len = 0;
    g_has_path = false;
    g_preview = false;
    g_img = -1;
    g_rev = false;
    g_rev_name_len = 0;
    g_lex_on = true;
    g_lex_lang = LANG_MINC;
    ed_lsp_follow();
    undo_ops = null;
    undo_cap = 0;
    undo_len = 0;
    undo_total = 0;
    undo_saved = 0;
    undo_break = true;
    g_lexstate = null;
    g_lex_cap = 0;
    g_lex_valid = 0;
    for i32 s = 0; s < WRAP_SLOTS; s++ {
        WrapCache z;
        g_wrap_c[s] = z;
    }
    wrap_switched();
    sel_clear();
    git_clear();
    g_ncur = 0;      // a buffer opens with one caret, not the last one's
    cur_line = 0;
    cur_col = 0;
    goal_vcol = -1;
    left_vcol = 0;
    g_scroll_accum = 0.0f;
    g_close_armed = false;
}

// buffer b's image, or -1 when it holds text
i32 ed_buf_img(i32 b) {
    if b == g_buf_active { return g_img; }
    if b < 0 || b >= g_nbufs { return -1; }
    return g_bufs[b].img1 - 1;
}

i32 ed_buf_count() {
    return g_nbufs;
}

i32 ed_buf_active() {
    return g_buf_active;
}

// tab label: path basename, or "untitled"
str ed_buf_title(i32 i) {
    u8* p = &g_path[0];
    i32 n = g_path_len;
    bool has = g_has_path;
    if i != g_buf_active {
        p = &g_bufs[i].path[0];
        n = g_bufs[i].path_len;
        has = g_bufs[i].has_path;
    }
    if i == g_buf_active && g_rev { return str_from(&g_rev_name[0], g_rev_name_len); }
    if i != g_buf_active && i >= 0 && i < g_nbufs && g_bufs[i].rev {
        return str_from(&g_bufs[i].rev_name[0], g_bufs[i].rev_name_len);
    }
    if !has || n == 0 { return "untitled"; }
    i32 base = path_base_off(p, n);
    return str_from(p + base, n - base);
}

bool ed_buf_dirty(i32 i) {
    if i == g_buf_active { return tb.dirty; }
    return g_bufs[i].tb.dirty;
}

bool ed_buf_preview(i32 i) {
    if i == g_buf_active { return g_preview; }
    return g_bufs[i].preview;
}

// the show stamp, for a list in the order the buffers were last seen
i64 ed_buf_used(i32 i) {
    return g_bufs[i].used;
}

// whether `path` is open in any slot; the harness reads the eviction
// order through it
bool ed_buf_open(str path) {
    if g_has_path && str_equal(str_from(&g_path[0], g_path_len), path) { return true; }
    for i32 i = 0; i < g_nbufs; i++ {
        if i == g_buf_active { continue; }
        if g_bufs[i].has_path
            && str_equal(str_from(&g_bufs[i].path[0], g_bufs[i].path_len), path) {
            return true;
        }
    }
    return false;
}

void ed_buf_switch(i32 i) {
    if i < 0 || i >= g_nbufs { return; }
    term_leave_for_doc();
    if i == g_buf_active { return; }
    ed_lsp_flush();
    buf_store(g_buf_active);
    buf_restore(i);
}

// close the active buffer; a dirty one refuses once, like app_close
void ed_buf_close() {
    if tb.dirty && !g_close_armed {
        g_close_armed = true;
        ed_warn("unsaved changes: ctrl+s to save, close again to discard");
        plat_damage();
        return;
    }
    g_close_armed = false;
    // The file of a diff, from its pane or from another pane that shows
    // it: the diff ends first, while the buffer is still loaded, and
    // leaves the file in a pane of its own. The close then takes it from
    // there. Closed under the diff instead, the view drew the diff's rows
    // over a freed buffer.
    if diff_on && (g_pane_active <= 1 || g_panes[1].buf == g_buf_active) { ed_diff_close(); }
    buf_free_loaded();
    if g_nbufs == 1 {
        // last tab: back to an untitled buffer
        buf_fresh();
        tb_init_empty();
        scroll_set(0);
        pane_save(g_pane_active);
        update_title();
        after_move();
        app_session_save();
        return;
    }
    i32 dead = g_buf_active;
    for i32 j = g_buf_active; j < g_nbufs - 1; j++ {
        g_bufs[j] = g_bufs[j + 1];
    }
    g_nbufs--;
    i32 nb = g_buf_active;
    if nb >= g_nbufs { nb = g_nbufs - 1; }
    buf_restore(nb);
    // panes referencing shifted slots follow; panes that showed the
    // closed buffer land on the replacement at its position
    for i32 p = 0; p < g_npanes; p++ {
        if p == g_pane_active { continue; }
        if g_panes[p].buf == dead {
            pane_save(p);
        } else if g_panes[p].buf > dead {
            g_panes[p].buf--;
        }
    }
    // and the other windows' panes, which share the table: left pointing
    // at the old numbers they showed the wrong buffer, or a slot past the
    // end of the table
    for i32 w = 0; w < WIN_MAX; w++ {
        if w == g_win || !g_wins[w].used { continue; }
        for i32 p = 0; p < g_wins[w].npanes; p++ {
            Pane* wp = &g_wins[w].panes[p];
            if wp.buf == dead {
                wp.buf = nb;
                wp.cur_line = 0;
                wp.cur_col = 0;
                wp.scroll_y = 0;
                wp.left_vcol = 0;
                wp.sel_active = false;
                wp.ncur = 0;
            } else if wp.buf > dead {
                wp.buf--;
            }
        }
    }
    app_session_save();
}

// whether slot i is on a pane of any window, this one or a parked one
private bool buf_shown(i32 i) {
    for i32 p = 0; p < g_npanes; p++ {
        if g_panes[p].kind == PANE_DOC && g_panes[p].buf == i { return true; }
    }
    for i32 w = 0; w < WIN_MAX; w++ {
        if w == g_win || !g_wins[w].used { continue; }
        for i32 p = 0; p < g_wins[w].npanes; p++ {
            if g_wins[w].panes[p].kind == PANE_DOC && g_wins[w].panes[p].buf == i { return true; }
        }
    }
    return false;
}

// the slot a full table gives up: the least recently shown buffer
// that is saved and on no pane, a preview before a kept one, or -1
// when there is none
private i32 buf_victim() {
    i32 best = -1;
    for i32 i = 0; i < g_nbufs; i++ {
        if i == g_buf_active || g_bufs[i].tb.dirty || buf_shown(i) { continue; }
        if best < 0
            || (g_bufs[i].preview && !g_bufs[best].preview)
            || (g_bufs[i].preview == g_bufs[best].preview && g_bufs[i].used < g_bufs[best].used) {
            best = i;
        }
    }
    return best;
}

// room for one more within the cap: the clean, unshown buffers go
// oldest first until the table is under it, or none is left to give
private void buf_soft_evict() {
    while g_nbufs >= g_buf_cap {
        i32 v = buf_victim();
        if v < 0 { return; }
        buf_evict(v);
    }
}

// a look made a preview: past PREVIEW_MAX of them, the ones looked at
// longest ago go, as long as no pane shows them
private void buf_trim_previews() {
    while true {
        i32 n = 0;
        i32 oldest = -1;
        for i32 i = 0; i < g_nbufs; i++ {
            bool prev = g_bufs[i].preview;
            if i == g_buf_active { prev = g_preview; }
            if !prev { continue; }
            n++;
            if i == g_buf_active || g_bufs[i].tb.dirty || buf_shown(i) { continue; }
            if oldest < 0 || g_bufs[i].used < g_bufs[oldest].used { oldest = i; }
        }
        if n <= PREVIEW_MAX || oldest < 0 { return; }
        buf_evict(oldest);
    }
}

// drop parked slot v and close the gap. Its storage is freed through
// the globals, the way a close frees the active buffer, so the two
// paths cannot drift; the active buffer takes a store/load round
// trip, which the frame build does on every pane swap anyway. The
// git state goes when the kept buffer's is attached again.
private void buf_evict(i32 v) {
    i32 keep = g_buf_active;
    buf_store(keep);
    buf_load(v);
    buf_free_loaded();
    for i32 j = v; j < g_nbufs - 1; j++ {
        g_bufs[j] = g_bufs[j + 1];
    }
    g_nbufs--;
    if keep > v { keep--; }
    for i32 p = 0; p < g_npanes; p++ {
        if g_panes[p].buf > v { g_panes[p].buf--; }
    }
    for i32 w = 0; w < WIN_MAX; w++ {
        if w == g_win || !g_wins[w].used { continue; }
        for i32 p = 0; p < g_wins[w].npanes; p++ {
            if g_wins[w].panes[p].buf > v { g_wins[w].panes[p].buf--; }
        }
    }
    buf_load(keep);
}

// --- notice ------------------------------------------------------------
// Every message is a notice: a box the view draws at the bottom right,
// above the status bar, whether the status bar shows or not. A line in
// the status bar is too easy to miss. The kind sets the icon and how
// long it stays:
// - an error or a warning (a refused action, a failed save, a file
//   changed on disk) stays until Esc, a click on it, or the next
//   notice;
// - information (a confirmation, a toggle, a run starting) goes by
//   itself after NOTICE_MS, or on Esc or a click.
// Esc closes the notice and still reaches what has the focus.
// A one-shot timer hides it, so idle stays without wakeups. While the
// input box is open, its messages show under its field instead.

const i32 NOTICE_ERROR = 0;
const i32 NOTICE_WARN = 1;
const i32 NOTICE_INFO = 2;
const i32 NOTICE_TIMER = 11;   // 7 is the player's, 8 the terminal probe's, 9 search's, 10 the watcher's
private const i32 NOTICE_MS = 4000;

bool notice_on = false;
i32 notice_kind = NOTICE_ERROR;
bool notice_sticky = true;     // the timer does not close it
u8[256] notice_msg;
i32 notice_len = 0;
private bool notice_timer_on = false;

private void notice_show(str m, i32 kind, bool sticky) {
    i32 n = m.len;
    if n > 256 { n = 256; }
    memcpy(&notice_msg[0], m.data, n);
    notice_len = n;
    notice_on = true;
    notice_kind = kind;
    notice_sticky = sticky;
    chord_hint_up = false;
    if notice_timer_on {
        plat_kill_timer(NOTICE_TIMER);
        notice_timer_on = false;
    }
    if !sticky {
        plat_set_timer(NOTICE_TIMER, NOTICE_MS);
        notice_timer_on = true;
    }
    plat_damage();
}

// an error the user must see
void ed_notice(str m) {
    notice_show(m, NOTICE_ERROR, true);
}

// a request that was dropped on purpose, with the reason; it stays
// until the reason is gone (the caller closes it)
void ed_notice_info(str m) {
    notice_show(m, NOTICE_INFO, true);
}

void ed_notice_close() {
    if notice_timer_on {
        plat_kill_timer(NOTICE_TIMER);
        notice_timer_on = false;
    }
    if !notice_on { return; }
    notice_on = false;
    plat_damage();
}

// NOTICE_TIMER: the information has been up long enough
void notice_timer() {
    if notice_timer_on {
        plat_kill_timer(NOTICE_TIMER);
        notice_timer_on = false;
    }
    // a warning that replaced the information stays
    if notice_on && !notice_sticky { ed_notice_close(); }
}

// the Ctrl+K hint goes when the chord ends, unless a message replaced it
private bool chord_hint_up = false;

private void chord_hint_close() {
    if !chord_hint_up { return; }
    chord_hint_up = false;
    if notice_on && notice_kind == NOTICE_INFO && !notice_sticky { ed_notice_close(); }
}

// the box the view draws, in window pixels; the click test uses it
void ed_notice_rect(i32* x0, i32* y0, i32* x1, i32* y1) {
    i32 pad = font_ui_h / 2;
    i32 w = font_ui_text_w(str_from(&notice_msg[0], notice_len)) + font_ui_h + 3 * pad;
    i32 wmax = g_w - 2 * pad;
    if w > wmax { w = wmax; }
    i32 h = font_ui_h + 2 * pad;
    *x1 = g_w - pad;
    *x0 = *x1 - w;
    *y1 = g_h - chrome_bottom_h() - pad;
    *y0 = *y1 - h;
}

// another pane shows this buffer, so loading a file into it in place
// would change what that pane shows too
private bool buf_shared(i32 i) {
    for i32 p = 0; p < g_npanes; p++ {
        if p != g_pane_active && g_panes[p].buf == i { return true; }
    }
    return false;
}

// open `path` as a kept buffer: activate it if already open, else a
// new tab. A clean empty untitled buffer is reused in place.
bool ed_open_file(str path) {
    return buf_open(path, true);
}

// open `path` for a look: the same, but the buffer is a preview, and
// only the last PREVIEW_MAX looks stay
bool ed_view_file(str path) {
    return buf_open(path, false);
}

// the active buffer stays: a preview is a preview no more
void ed_buf_keep() {
    if !g_preview { return; }
    g_preview = false;
    update_title();
    plat_damage();
}

private bool buf_open(str path, bool keep) {
    if path.len == 0 || path.len >= PATH_MAX { return false; }
    term_leave_for_doc();
    if g_has_path && str_equal(str_from(&g_path[0], g_path_len), path) {
        if keep { ed_buf_keep(); }
        return true;
    }
    // a file the diff is not about ends it; a file already in a buffer
    // goes through buf_restore, which says the same thing for a switch
    // another file in one of the diff's own panes ends it: the pairing
    // it draws is this file's and no other's. A pane beside them is not
    // part of the picture and opens what it likes.
    if diff_on && g_pane_active <= 1
        && !str_equal(str_from(&diff_path[0], diff_path_len), path) {
        ed_diff_close();
    }
    ed_lsp_flush();
    for i32 i = 0; i < g_nbufs; i++ {
        if i == g_buf_active { continue; }
        if g_bufs[i].has_path
            && str_equal(str_from(&g_bufs[i].path[0], g_bufs[i].path_len), path) {
            buf_store(g_buf_active);
            buf_restore(i);
            if keep { ed_buf_keep(); }
            return true;
        }
    }
    bool reuse = !g_has_path && !g_rev && !tb.dirty && tb_len() == 0 && !buf_shared(g_buf_active);
    if !reuse {
        if !g_session_loading { buf_soft_evict(); }
        if g_nbufs == BUF_MAX {
            i32 v = buf_victim();
            if v < 0 {
                ed_notice("cannot open: every open buffer is unsaved or on screen. Save or close some (ctrl+s, ctrl+w) and try again.");
                return false;
            }
            buf_evict(v);
        }
        buf_store(g_buf_active);
        g_buf_active = g_nbufs;
        g_nbufs++;
        buf_touch(g_buf_active);
        buf_fresh();
    } else {
        undo_clear();
        tb_free();
        g_lex_valid = 0;
        wrap_reset();
    }
    g_preview = !keep;
    memcpy(&g_path[0], path.data, path.len);
    g_path_len = path.len;
    g_has_path = true;
    g_img = -1;
    if image_path(path) {
        // no text, no lexer, no baseline and no server: the pixels only
        tb_init_empty();
        g_lex_on = false;
        g_img = image_open(path);
    }
    if g_img < 0 {
        lex_set_for(path);
        if !tb_load(path) {
            ed_status("new file");
        }
        git_reload(path);
    }
    sel_clear();
    cur_line = 0;
    cur_col = 0;
    goal_vcol = -1;
    left_vcol = 0;
    scroll_set(0);
    g_scroll_accum = 0.0f;
    pane_save(g_pane_active);
    update_title();
    after_move();
    if g_img < 0 { ed_lsp_sync(); }
    if !keep && !g_session_loading { buf_trim_previews(); }
    app_session_save();
    return true;
}

// --- panes -----------------------------------------------------------
// Vertical splits: each pane is a viewport onto one buffer slot with
// its own caret, selection, and scroll. Like buffers, the active
// pane's state lives in the globals; records here are refreshed with
// pane_save and applied with pane_apply. pane_apply clamps, because
// another pane may have edited a shared buffer since this pane last
// held it. The frame build swaps every pane through the globals via
// ed_pane_swap_view; g_pane_loaded tracks whose state the globals
// hold (equal to g_pane_active outside the frame build).

// three columns, and the bottom pane under them
const i32 PANE_MAX = 4;
const i32 WIN_MAX = 8;

// A pane is a document view, or a terminal: a screen grid from
// src/term.mc with a shell behind it. A terminal pane keeps a valid
// buffer index (the one it split from) so the swap machinery and the
// title, which read every pane's buffer, have nothing to special-case;
// it never edits it. The editor's caret, selection and scroll are
// meaningless there and left as they were.
const i32 PANE_DOC = 0;
const i32 PANE_TERM = 1;
// the terminal's inset from its pane's edges, in pixels
const i32 TERM_PAD_PX = 4;

private struct Pane {
    i32 kind;
    i32 term;          // the terminal's handle in term.mc, PANE_TERM only
    i32 buf;
    i32 cur_line;
    i64 cur_col;
    i32 scroll_y;
    i32 scroll_cols;   // the wrap width scroll_y counts rows at, 0 for lines
    i32 left_vcol;
    bool sel_active;
    i64 sel_anchor;
    EdCursor[CUR_MAX] cur;
    i32 ncur;
}

private Pane[PANE_MAX] g_panes;
private i32 g_npanes = 1;
private i32 g_pane_active = 0;
private i32 g_pane_loaded = 0;

// pane boundaries as fractions of the editor area; div[0] = 0 and
// div[npanes] = 1, pane i spans [div[i], div[i+1]). Dragging a
// border moves its divider.
// --- the diff view ----------------------------------------------------
// One file in two panes: what it is at HEAD on the left, the live
// buffer on the right. git.mc pairs the sides into rows, and here a
// row, not a line, is what a screen line holds: a line the other side
// has nothing against leaves a gap opposite it.
//
// The left side is not a document. It is never the active pane, so
// g_buf_active stays a slot in the table and nothing can be typed into
// it; it carries no path, so the server and the gutter never see it.
private bool diff_on = false;
private bool diff_base_side = false;   // the loaded pane is the left one
private u8[PATH_MAX] diff_path;        // the file being diffed
private i32 diff_path_len = 0;
private bool diff_want = false;        // asked for, waiting on a baseline
// The right side is a commit's version (ed_rev_diff), not the file:
// diff_path then holds the left side's label, not a path.
private bool diff_rev = false;
// The diff borrows the two left-most panes rather than taking the
// window: it makes a second pane only when there is one, and puts the
// left one back as it was when it closes. Panes to the right of the
// two are none of its business.
private bool diff_made_pane = false;
private Pane diff_saved0;

bool ed_diff_on() {
    return diff_on;
}

bool ed_diff_base_side() {
    return diff_base_side;
}

// The loaded pane is one of the diff's two. Rows are the diff's only
// there: a pane beside the diff shows its own buffer line by line, and
// the diff's rows are another file's.
private bool diff_here() {
    return diff_on && g_pane_loaded <= 1;
}

bool ed_diff_here() {
    return diff_here();
}

// The loaded pane wraps its lines (wrap.mc): the setting is on and the
// pane shows text. A diff's two sides pair line against line, so they
// do not wrap.
bool ed_wrap_on() {
    return g_wrap && !diff_here() && g_img < 0;
}

// Word wrap on or off (Alt+Z). A row is another line after the switch;
// every pane keeps the line at its top, converted when it is next loaded
// (wrap_refit), the active one at once.
void ed_wrap_set(bool on) {
    if on == g_wrap { return; }
    g_wrap = on;
    // at start the settings come before any text is loaded
    if g_linebuf == null || tb.nlines == 0 { return; }
    wrap_refit();
    g_glide_px = 0;
    g_glide_period = 0;
    goal_vcol = -1;
    ensure_visible();
    plat_damage();
}

void ed_wrap_toggle() {
    ed_wrap_set(!g_wrap);
    if g_wrap { ed_status("word wrap on"); } else { ed_status("word wrap off"); }
}

// the first row a line sits on, for the side the globals hold; without
// a diff or wrap a row is a line
i32 ed_row_of_line(i32 l) {
    if ed_wrap_on() { return wrap_row_of_line(l); }
    if !diff_here() { return l; }
    if diff_base_side { return git_row_of_base(l); }
    return git_row_of_line(l);
}

// The line a row shows on this side, -1 for a filler. A wide edit
// recomputes the rows on the gutter's timer, so until it fires the rows
// can name a line the edit removed; that row shows nothing on this side.
i32 ed_line_of_row(i32 r) {
    if ed_wrap_on() { return wrap_line_of_row(r); }
    if !diff_here() { return r; }
    i32 l = git_row_b(r);
    if diff_base_side { l = git_row_a(r); }
    if l >= tb.nlines { return -1; }
    return l;
}

i32 ed_row_count() {
    wrap_refit();
    if ed_wrap_on() { return wrap_total(); }
    if !diff_here() { return tb.nlines; }
    return git_row_count();
}

// the row a position is on: its line's first row, plus the wrapped rows
// before its column
i32 ed_row_of_pos(i32 l, i64 col) {
    i32 r = ed_row_of_line(l);
    if r < 0 { r = l; }
    if !ed_wrap_on() { return r; }
    ignore wrap_line(l);
    return r + wrap_row_of_col(cast(i32, col));
}

// The visual column the left edge of row k of line l stands for: what
// is subtracted from a column to place it on screen. Without wrap it is
// the sideways scroll; with wrap, the row's first column less its indent.
i32 ed_row_left_vcol(i32 l, i32 k) {
    if !ed_wrap_on() { return left_vcol; }
    ignore wrap_line(l);
    return wrap_row_v0(k) - wrap_row_lead(k);
}

// A position's place on screen in the loaded pane: the window x of its
// left edge and the y of its row's top.
void ed_pos_xy(i32 l, i64 col, i32* x, i32* y) {
    i32 v = vcol_of_col(l, col);
    i32 r = ed_row_of_pos(l, col);
    i32 k = r - ed_row_of_line(l);
    *x = pane_x0() + gutter_w() + (v - ed_row_left_vcol(l, k)) * font_cell_w;
    *y = doc_top() + (r - top_line) * font_line_h - scroll_off;
}

// The position under a window point in the loaded pane, as a line and a
// byte column. `round` takes the nearer edge of the character under x,
// as a click does; without it the character x is in. With wrap a point
// past a row's end lands before the row's last character, since a column
// at the break is drawn at the start of the next row.
void ed_pos_at(i32 x, i32 y, bool round, i32* line, i64* col) {
    i32 cx = x - pane_x0() - gutter_w();
    if round { cx += font_cell_w / 2; }
    if cx < 0 { cx = 0; }
    i32 cell = cx / font_cell_w;
    if !ed_wrap_on() {
        i32 l = clamp_line(ed_line_at_y(y));
        i32 v = left_vcol + cell;
        *line = l;
        *col = col_of_vcol(l, v);
        return;
    }
    i32 r = (scroll_y + y - doc_top()) / font_line_h;
    i32 total = wrap_total();
    if r >= total { r = total - 1; }
    if r < 0 { r = 0; }
    i32 l = clamp_line(wrap_line_of_row(r));
    i32 rows = wrap_line(l);
    i32 k = r - wrap_row_of_line(l);
    if k >= rows { k = rows - 1; }
    i32 lead = wrap_row_lead(k);
    i32 v0 = wrap_row_v0(k);
    i32 v = v0 + cell - lead;
    if v < v0 { v = v0; }
    i64 c = col_of_vcol(l, v);
    if k + 1 < rows {
        i32 e = wrap_row_start(k + 1);
        if c >= e { c = col_before(l, e); }
    }
    *line = l;
    *col = c;
}

// the byte column of the character before column e in line l
private i64 col_before(i32 l, i32 e) {
    i32 n = line_bytes(l);
    i32 i = 0;
    i32 prev = 0;
    while i < n && i < e {
        prev = i;
        if g_linebuf[i] == '\t' { i++; } else { ignore grapheme_next_w(g_linebuf, n, &i); }
    }
    return prev;
}

// The y a line's top sits at, and the line a y falls on, in the loaded
// pane. Everything outside the renderer that puts something beside a
// line goes through these, since a diff moves lines down the screen by
// what the other side has.
i32 ed_line_y(i32 l) {
    i32 r = ed_row_of_line(l);
    if r < 0 { r = l; }
    return doc_top() + (r - top_line) * font_line_h - scroll_off;
}

// the y of a position's row: its line's, or a later row of it when the
// line wraps
i32 ed_pos_y(i32 l, i64 col) {
    i32 r = ed_row_of_pos(l, col);
    return doc_top() + (r - top_line) * font_line_h - scroll_off;
}

i32 ed_line_at_y(i32 y) {
    i32 r = (scroll_y + y - doc_top()) / font_line_h;
    if ed_wrap_on() {
        if r < 0 { return r; }
        return wrap_line_of_row(r);
    }
    if !diff_here() { return r; }
    i32 n = git_row_count();
    if r < 0 { r = 0; }
    if r >= n { r = n - 1; }
    // a filler row shows no line on this side: take the nearest that does
    i32 l = ed_line_of_row(r);
    i32 k = r;
    while l < 0 && k + 1 < n {
        k++;
        l = ed_line_of_row(k);
    }
    k = r;
    while l < 0 && k > 0 {
        k--;
        l = ed_line_of_row(k);
    }
    if l < 0 { l = 0; }
    return l;
}

private f32[PANE_MAX + 1] g_pane_div;
private i32 g_div_drag = -1;   // divider index while dragging, else -1

// x of divider i in window pixels
private i32 pane_div_x(i32 i) {
    i32 left = content_left();
    return left + cast(i32, cast(f32, g_w - left) * g_pane_div[i] + 0.5f);
}

// half-width of a divider's grab zone
private i32 pane_grab() {
    i32 g = font_line_h * 2 / 5;
    if g < 6 { g = 6; }
    return g;
}

// divider under x: 0 = the sidebar edge, 1.. = pane borders, -1 =
// none
private i32 pane_div_at(i32 x, i32 y) {
    if y >= g_h - status_h() { return -1; }
    // the bottom pane's top edge, across the editor
    if g_bottom && x >= content_left() {
        i32 pt = panel_top();
        if y >= pt - pane_grab() / 2 && y <= pt + pane_grab() / 2 { return DIV_BOTTOM; }
    }
    // the columns' borders run down to the bottom pane
    if !g_bottom || y < panel_top() {
        for i32 i = 1; i < pane_cols(); i++ {
            i32 dx = pane_div_x(i);
            if x >= dx - pane_grab() && x <= dx + pane_grab() { return i; }
        }
    }
    if tree_on && x >= content_left() - pane_grab() && x <= content_left() + pane_grab() {
        return 0;
    }
    return -1;
}

// pane p shows a document (its buffer) rather than a terminal
private void pane_set_doc(i32 p) {
    g_panes[p].kind = PANE_DOC;
    g_panes[p].term = -1;
}

// the kind of pane p, and the terminal handle of the active pane
// (-1 when it is a document)
i32 ed_pane_kind(i32 p) {
    if p < 0 || p >= g_npanes { return PANE_DOC; }
    return g_panes[p].kind;
}

i32 ed_term_active() {
    if g_panes[g_pane_active].kind != PANE_TERM { return -1; }
    return g_panes[g_pane_active].term;
}

i32 ed_pane_term(i32 p) {
    if p < 0 || p >= g_npanes || g_panes[p].kind != PANE_TERM { return -1; }
    return g_panes[p].term;
}

// the terminal's grid for pane p: the pane's width in cells, and the
// rows under its banner and above the bottom chrome
private void term_pane_cells(i32 p, i32* cols, i32* rows) {
    i32 x0 = 0;
    i32 x1 = 0;
    ed_pane_rect(p, &x0, &x1);
    i32 c = (x1 - x0 - TERM_PAD_PX * 2) / font_cell_w;
    i32 r = (ed_pane_y1(p) - pane_doc_top(p)) / font_line_h;
    if c < 2 { c = 2; }
    if r < 1 { r = 1; }
    *cols = c;
    *rows = r;
}

// every terminal pane's grid follows its pane. Called from the frame
// build, so a change to any of the geometry (dividers, the sidebar,
// the status bar, the window, the dpi) is caught there without each
// setter knowing; term_resize is a no-op at the same size, so a frame
// that moved nothing costs a few compares.
void ed_term_fit() {
    for i32 p = 0; p < g_npanes; p++ {
        if g_panes[p].kind != PANE_TERM { continue; }
        i32 c = 0;
        i32 r = 0;
        term_pane_cells(p, &c, &r);
        i32 t = g_panes[p].term;
        bool same = c == term_cols(t) && r == term_rows(t);
        term_resize(t, c, r);
        // a reflow renumbers the lines a selection is anchored to
        if !same && ed_term_sel_on(t) { ed_term_sel_clear(); }
    }
}

// the buffer a pane shows, for a check that wants to see it put back
i32 ed_pane_buf(i32 p) {
    if p < 0 || p >= g_npanes { return -1; }
    return g_panes[p].buf;
}

i32 ed_pane_count() {
    return g_npanes;
}

i32 ed_pane_active() {
    return g_pane_active;
}

// pane i's column bounds within the editor area
void ed_pane_rect(i32 i, i32* x0, i32* x1) {
    if pane_is_bottom(i) {
        *x0 = pane_div_x(0);
        *x1 = pane_div_x(pane_cols());
        return;
    }
    *x0 = pane_div_x(i);
    *x1 = pane_div_x(i + 1);
}

// The edges of the pane the globals hold: the active one, except while
// the frame build draws the others, which wrap at their own widths.
private i32 pane_x0() {
    i32 a = 0;
    i32 b = 0;
    ed_pane_rect(g_pane_loaded, &a, &b);
    return a;
}

private i32 pane_x1() {
    i32 a = 0;
    i32 b = 0;
    ed_pane_rect(g_pane_loaded, &a, &b);
    return b;
}

private i32 pane_at(i32 x, i32 y) {
    if x < content_left() { return g_pane_active; }
    if g_bottom && y >= panel_top() { return g_npanes - 1; }
    i32 nc = pane_cols();
    for i32 i = 0; i < nc - 1; i++ {
        if x < pane_div_x(i + 1) { return i; }
    }
    return nc - 1;
}

private void pane_save(i32 p) {
    g_panes[p].buf = g_buf_active;
    g_panes[p].cur_line = cur_line;
    g_panes[p].cur_col = cur_col;
    g_panes[p].scroll_y = scroll_y;
    g_panes[p].scroll_cols = g_scroll_cols;
    g_panes[p].left_vcol = left_vcol;
    g_panes[p].sel_active = sel_active;
    g_panes[p].sel_anchor = sel_anchor;
    if g_ncur > 0 { memcpy(&g_panes[p].cur[0], &g_cur[0], g_ncur * sizeof(EdCursor)); }
    g_panes[p].ncur = g_ncur;
}

private void pane_apply(i32 p) {
    // the globals hold pane p from here: the clamps below go through the
    // row helpers, which read the diff's rows only in the diff's panes
    g_pane_loaded = p;
    cur_line = g_panes[p].cur_line;
    cur_line = clamp_line(cur_line);
    cur_col = col_snap(cur_line, g_panes[p].cur_col);
    left_vcol = g_panes[p].left_vcol;
    sel_active = g_panes[p].sel_active;
    sel_anchor = g_panes[p].sel_anchor;
    if sel_anchor > tb_len() { sel_anchor = tb_len(); }
    if sel_anchor < 0 { sel_anchor = 0; }
    g_ncur = g_panes[p].ncur;
    if g_ncur > 0 { memcpy(&g_cur[0], &g_panes[p].cur[0], g_ncur * sizeof(EdCursor)); }
    cur_reclamp();
    // the two sides of a diff are one picture: the rows are shared, so
    // the scroll is too, and the file's pane is the one that owns it
    i32 sy = g_panes[p].scroll_y;
    i32 sc = g_panes[p].scroll_cols;
    if diff_on && p == 0 {
        sy = g_panes[1].scroll_y;
        sc = g_panes[1].scroll_cols;
    }
    scroll_load(sy, sc);
    if diff_on && p == 0 { g_panes[0].scroll_y = scroll_y; }
}

// frame-build entry: pane i's buffer and view into the globals. The
// caller iterates the panes and must finish on the active one.
void ed_pane_swap_view(i32 i) {
    if i == g_pane_loaded { return; }
    pane_save(g_pane_loaded);
    buf_store(g_buf_active);
    diff_base_side = g_panes[i].buf == BUF_DIFF_BASE;
    buf_load(g_panes[i].buf);
    pane_apply(i);
    g_pane_loaded = i;
}

void ed_pane_split() {
    // the bottom pane is not a column to split: its column is
    if pane_is_bottom(g_pane_active) { bottom_leave(); }
    if pane_cols() >= COL_MAX {
        ed_status("no more splits");
        plat_damage();
        return;
    }
    pane_save(g_pane_active);
    for i32 j = g_npanes; j > g_pane_active + 1; j-- {
        g_panes[j] = g_panes[j - 1];
    }
    g_panes[g_pane_active + 1] = g_panes[g_pane_active];
    // a split off a terminal is a document view of its buffer; the
    // shell is not shared
    pane_set_doc(g_pane_active + 1);
    for i32 j = g_npanes; j > g_pane_active; j-- {
        g_pane_div[j + 1] = g_pane_div[j];
    }
    g_pane_div[g_pane_active + 1] =
        (g_pane_div[g_pane_active] + g_pane_div[g_pane_active + 2]) / 2.0f;
    g_npanes++;
    g_pane_active++;
    g_pane_loaded = g_pane_active;
    g_div_drag = -1;   // the dividers moved under any drag in flight
    ensure_visible();
    ed_term_fit();
    plat_damage();
}

// --- the terminal pane ------------------------------------------------

private i32 term_pane_find() {
    for i32 p = 0; p < g_npanes; p++ {
        if g_panes[p].kind == PANE_TERM { return p; }
    }
    return -1;
}

// the pane showing terminal t, or -1 (in the background, or gone)
i32 ed_pane_of_term(i32 t) {
    if t < 0 { return -1; }
    for i32 p = 0; p < g_npanes; p++ {
        if g_panes[p].kind == PANE_TERM && g_panes[p].term == t { return p; }
    }
    return -1;
}

// the first document pane showing buffer b, or -1
i32 ed_pane_of_buf(i32 b) {
    for i32 p = 0; p < g_npanes; p++ {
        if g_panes[p].kind == PANE_DOC && g_panes[p].buf == b { return p; }
    }
    return -1;
}

// terminals with a child and no pane
i32 ed_term_background_count() {
    i32 n = 0;
    for i32 t = 0; t < TERM_MAX; t++ {
        if term_has_child(t) && ed_pane_of_term(t) < 0 { n++; }
    }
    return n;
}

// The bottom pane with terminal t in it, under the columns. The focus
// stays where it is: the build opens beside the work.
private void bottom_add(i32 t) {
    if g_bottom || g_npanes >= PANE_MAX { return; }
    pane_save(g_pane_active);
    i32 b = g_npanes;
    g_panes[b] = g_panes[g_pane_active];
    g_panes[b].kind = PANE_TERM;
    g_panes[b].term = t;
    g_panes[b].cur_line = 0;
    g_panes[b].cur_col = 0;
    g_panes[b].scroll_y = 0;
    g_panes[b].left_vcol = 0;
    g_panes[b].sel_active = false;
    g_panes[b].ncur = 0;
    // the dividers past the last column stay at the right edge
    for i32 j = b; j <= PANE_MAX; j++ { g_pane_div[j] = 1.0f; }
    g_npanes++;
    g_bottom = true;
    g_div_drag = -1;
    ed_term_fit();   // the grid from the band, before the child writes
    update_title();
    plat_damage();
}

// the bottom pane goes: its run ends with it (kill), or keeps going in
// the background (Ctrl+J). A focus it had goes to the column last used.
private void bottom_remove(bool kill) {
    if !g_bottom { return; }
    i32 b = g_npanes - 1;
    bool had = g_pane_active == b;
    if kill && g_panes[b].kind == PANE_TERM {
        if g_panes[b].term == build_term() { build_pane_closed(); }
        ed_term_close(g_panes[b].term);
    }
    if had { pane_save(g_pane_active); }
    g_npanes--;
    g_bottom = false;
    g_div_drag = -1;
    if had {
        i32 c = g_col_last;
        if c >= g_npanes { c = g_npanes - 1; }
        if c < 0 { c = 0; }
        if diff_on && c == 0 { c = 1; }
        pane_enter(c);
    }
    ed_term_fit();
    update_title();
    plat_damage();
}

// the focus from the bottom pane to the column used last: a file, a
// buffer or a shell asked for there goes to a column
private void bottom_leave() {
    if !pane_is_bottom(g_pane_active) { return; }
    i32 c = g_col_last;
    if c >= pane_cols() { c = pane_cols() - 1; }
    if c < 0 { c = 0; }
    if diff_on && c == 0 { c = 1; }
    ed_pane_focus(c);
}

// the bottom pane's grid: the editor's width, the band under its banner
private void bottom_cells(i32* cols, i32* rows) {
    i32 c = (g_w - content_left() - TERM_PAD_PX * 2) / font_cell_w;
    i32 r = (bottom_band_h() - banner_h()) / font_line_h;
    if c < 2 { c = 2; }
    if r < 1 { r = 1; }
    *cols = c;
    *rows = r;
}

// Ctrl+K T: a new shell in the active pane, in place of what it showed,
// the way a file opens there (a terminal there drops to the background
// and comes back through the switcher, as a buffer does). The chord
// never switches to an existing terminal, so two panes stay two panes.
void ed_term_open() {
    if pane_is_bottom(g_pane_active) { bottom_leave(); }
    i32 c = 0;
    i32 r = 0;
    term_pane_cells(g_pane_active, &c, &r);
    i32 t = term_open(c, r);
    if t < 0 {
        ed_warn("no terminal here: the platform has no pseudo-terminal, or the shell is not installed");
        plat_damage();
        return;
    }
    ed_show_term(t);
}

// Terminal t into the active pane, in place of what it showed: a
// document pane becomes a terminal pane (its buffer stays open), a
// terminal pane's own terminal drops to the background. A terminal
// already on screen gets the focus instead.
void ed_show_term(i32 t) {
    if !term_has_child(t) { return; }
    i32 p = ed_pane_of_term(t);
    if p >= 0 {
        if p != g_pane_active { ed_pane_focus(p); }
        return;
    }
    if pane_is_bottom(g_pane_active) { bottom_leave(); }
    g_panes[g_pane_active].kind = PANE_TERM;
    g_panes[g_pane_active].term = t;
    tree_focus = false;
    search_focus = false;
    ed_term_fit();
    update_title();
    reset_blink();
    plat_damage();
}

// Buffer b into the active pane: a terminal pane becomes a document
// pane again, its terminal kept in the background (ed_buf_switch).
void ed_show_buf(i32 b) {
    if b < 0 || b >= g_nbufs { return; }
    ed_buf_switch(b);
    reset_blink();
    plat_damage();
}

// the same, without counting it as seen (the switcher's preview)
void ed_show_buf_peek(i32 b) {
    g_buf_peek = true;
    ed_show_buf(b);
    g_buf_peek = false;
}

// --- the explode view's tiles ---------------------------------------------
// A tile draws buffer b where pane p draws: the frame build loads b into
// the globals in p's place, draws it scaled (explode.mc), and puts p
// back. The diff is off while a tile draws, since its pairing is one
// file's; nothing else about p changes.

private bool g_tile_diff = false;

// Scroll buffer b by dy pixels from the explode view. The loaded buffer
// scrolls its live view, which the tiles copy from; any other scrolls
// the view its slot keeps, which is where a tile draws it and where it
// opens. The caret stays where it is.
void ed_buf_scroll(i32 b, i32 dy) {
    if b < 0 || b >= g_nbufs || dy == 0 { return; }
    if b == g_buf_active {
        scroll_set(scroll_y + dy);
        return;
    }
    EdBuffer* e = &g_bufs[b];
    i32 most = (e.tb.nlines - 1) * font_line_h;
    i32 y = e.scroll_y + dy;
    if y > most { y = most; }
    if y < 0 { y = 0; }
    e.scroll_y = y;
}

// the pane a tile takes its geometry from: the active one, a terminal
// pane as well, since it keeps the buffer it showed before
i32 ed_tile_pane() {
    if g_panes[g_pane_active].buf != BUF_DIFF_BASE { return g_pane_active; }
    for i32 p = 0; p < g_npanes; p++ {
        if g_panes[p].buf != BUF_DIFF_BASE { return p; }
    }
    return -1;
}

private i32 g_tile_doc_kind = 0;

// a buffer's tile: pane p is a document pane for the one draw
void ed_tile_begin(i32 p, i32 b) {
    ed_pane_swap_view(p);
    pane_save(p);
    buf_store(g_buf_active);
    g_tile_diff = diff_on;
    diff_on = false;
    diff_base_side = false;
    g_tile_doc_kind = g_panes[p].kind;
    g_panes[p].kind = PANE_DOC;
    buf_load(b);
}

// the same for terminal t: pane p shows it for the one draw, its own
// kind and terminal put back after
private i32 g_tile_kind = 0;
private i32 g_tile_term = -1;

void ed_tile_begin_term(i32 p, i32 t) {
    ed_pane_swap_view(p);
    g_tile_kind = g_panes[p].kind;
    g_tile_term = g_panes[p].term;
    g_panes[p].kind = PANE_TERM;
    g_panes[p].term = t;
}

void ed_tile_end_term(i32 p) {
    g_panes[p].kind = g_tile_kind;
    g_panes[p].term = g_tile_term;
}

void ed_tile_end(i32 p) {
    // the lexer's progress on b stays with b
    buf_store(g_buf_active);
    diff_on = g_tile_diff;
    g_panes[p].kind = g_tile_doc_kind;
    buf_load(g_panes[p].buf);
    pane_apply(p);
}

// the active buffer counts as seen now: the preview the user settled on
void ed_buf_seen() {
    if g_buf_active >= 0 && g_buf_active < g_nbufs { buf_touch(g_buf_active); }
}

// the pane whose terminal is the build's, or -1
i32 ed_build_pane() {
    return ed_pane_of_term(build_term());
}

// The build's command in the build pane: the pane it had, with the
// previous run's terminal replaced, else a new split beside the active
// pane. The focus stays with the work. The terminal's handle, or -1.
i32 ed_build_pane_open(str* argv, i32 argc) {
    i32 bp = ed_build_pane();
    if bp < 0 {
        i32 old = build_term();
        if old >= 0 { ed_term_close(old); }   // the previous run, hidden
        i32 c = 0;
        i32 r = 0;
        bottom_cells(&c, &r);
        i32 t = term_open_cmd(c, r, argv, argc);
        if t < 0 {
            ed_warn("no terminal here: the platform has no pseudo-terminal, or the shell is not installed");
            plat_damage();
            return -1;
        }
        bottom_add(t);
        return t;
    }
    i32 c = 0;
    i32 r = 0;
    term_pane_cells(bp, &c, &r);
    ed_term_close(g_panes[bp].term);
    i32 t = term_open_cmd(c, r, argv, argc);
    if t < 0 {
        // no child: the pane goes
        bottom_remove(false);
        return -1;
    }
    g_panes[bp].term = t;
    plat_damage();
    return t;
}

// Ctrl+J with the build pane up: the pane goes, the build keeps
// running in the background
void ed_build_pane_hide() {
    if !pane_is_bottom(ed_build_pane()) { return; }
    bottom_remove(false);
}

// Ctrl+J with the build in the background: its pane comes back beside
// the work, the focus staying where it is
bool ed_build_pane_show() {
    i32 t = build_term();
    if t < 0 || !term_has_child(t) || ed_pane_of_term(t) >= 0 || g_bottom { return false; }
    bottom_add(t);
    return true;
}

// A file shown while a terminal pane has the focus takes the pane, as
// it would a document pane: the terminal drops to the background, in
// the switcher's list.
private void term_leave_for_doc() {
    if g_panes[g_pane_active].kind != PANE_TERM { return; }
    if pane_is_bottom(g_pane_active) {
        bottom_leave();
        return;
    }
    pane_set_doc(g_pane_active);
    update_title();
}

// A problem walked from the build pane's own output is a jump out of
// it: the file lands in the nearest document pane, the output staying
// on screen to walk. With no document pane the file takes the pane,
// as any open does.
private void term_leave_for_jump() {
    if g_panes[g_pane_active].kind != PANE_TERM { return; }
    if pane_is_bottom(g_pane_active) {
        bottom_leave();
        return;
    }
    for i32 d = 1; d < g_npanes; d++ {
        i32 l = g_pane_active - d;
        i32 r = g_pane_active + d;
        if l >= 0 && g_panes[l].kind == PANE_DOC {
            ed_pane_focus(l);
            return;
        }
        if r < g_npanes && g_panes[r].kind == PANE_DOC {
            ed_pane_focus(r);
            return;
        }
    }
}

// a button at a window point to terminal t, as the cell under it
private void term_mouse_at(i32 t, i32 x, i32 y, i32 btn, bool down, i32 mods) {
    i32 c = 0;
    i32 r = 0;
    ed_term_cell_at(x, y, &c, &r);
    term_mouse(t, c, r, btn, down, mods);
}

// the sidebar shown and focused on the file tree, or on the files git
// says have changed
private void sidebar_show(bool changes) {
    if search_on { search_close_view(); }
    if !tree_on { tree_toggle(); }
    if changes { tree_show_changes(); } else { tree_show_files(); }
    search_focus = false;
    find_close();
    tree_take_focus();
}

// the buffer last shown apart from b, -1 when b is the only one
private i32 buf_other_recent(i32 b) {
    i32 best = -1;
    for i32 i = 0; i < g_nbufs; i++ {
        if i == b { continue; }
        if best < 0 || g_bufs[i].used > g_bufs[best].used { best = i; }
    }
    return best;
}

// Ctrl+Alt+Left and Right: what the active pane shows moves to the pane
// on that side, which takes the focus, the way the reference moves an
// editor between groups. The pane it left shows the buffer last seen
// apart from it, or keeps it when there is no other; a terminal pane
// goes back to its document. Nothing moves at the edge or in a diff.
void ed_pane_move_shown(i32 dir) {
    if diff_on { return; }
    i32 src = g_pane_active;
    i32 dst = src + dir;
    if pane_is_bottom(src) || dst < 0 || dst >= pane_cols() { return; }
    if g_panes[src].kind == PANE_TERM {
        i32 t = g_panes[src].term;
        pane_set_doc(src);
        ed_pane_focus(dst);
        ed_show_term(t);
        return;
    }
    i32 b = g_buf_active;
    i32 other = buf_other_recent(b);
    if other >= 0 { ed_buf_switch(other); }
    ed_pane_focus(dst);
    ed_show_buf(b);
}

// the shell of every terminal pane, on quit
void ed_term_close_all() {
    ed_term_sel_clear();
    term_close_all();
}

// --- cell selection in a terminal pane ------------------------------------
// One selection, on one terminal, anchored to absolute lines so it stays
// on its text while output scrolls under it. Both ends are cells and
// both are included. A drag makes it (Shift held when the child has the
// mouse), a click or a key to the shell clears it, and the primary's
// copy chord takes it to the clipboard.
private i32 g_tsel_t = -1;
private i64 g_tsel_al = 0;   // the anchor
private i32 g_tsel_ac = 0;
private i64 g_tsel_hl = 0;   // the head, under the mouse
private i32 g_tsel_hc = 0;
private bool g_tsel_on = false;
private bool g_tsel_drag = false;

// A terminal ends: a selection on it goes too. The slot is reused by the
// next terminal opened, and a selection left behind would then sit on
// that one's text.
private void ed_term_close(i32 t) {
    if g_tsel_t == t { ed_term_sel_clear(); }
    term_close(t);
}

void ed_term_sel_clear() {
    if g_tsel_on { plat_damage(); }
    g_tsel_on = false;
    g_tsel_drag = false;
    g_tsel_t = -1;
}

// The selection on terminal t, ordered, both ends included; false with
// none. The grid can have narrowed under it (a pane resized, the
// sidebar opened), so the columns are clamped into it here.
bool ed_term_sel_get(i32 t, i64* l0, i32* c0, i64* l1, i32* c1) {
    if !g_tsel_on || t < 0 || t != g_tsel_t || !term_live(t) { return false; }
    if g_tsel_al < g_tsel_hl || (g_tsel_al == g_tsel_hl && g_tsel_ac <= g_tsel_hc) {
        *l0 = g_tsel_al; *c0 = g_tsel_ac; *l1 = g_tsel_hl; *c1 = g_tsel_hc;
    } else {
        *l0 = g_tsel_hl; *c0 = g_tsel_hc; *l1 = g_tsel_al; *c1 = g_tsel_ac;
    }
    i32 last = term_cols(t) - 1;
    if *c0 > last { *c0 = last; }
    if *c1 > last { *c1 = last; }
    return true;
}

bool ed_term_sel_on(i32 t) {
    i64 l0 = 0;
    i64 l1 = 0;
    i32 c0 = 0;
    i32 c1 = 0;
    return ed_term_sel_get(t, &l0, &c0, &l1, &c1);
}

// the cell under a window point, clamped into the grid
private void term_sel_cell(i32 t, i32 x, i32 y, i64* line, i32* col) {
    i32 c = 0;
    i32 r = 0;
    ed_term_cell_at(x, y, &c, &r);
    if c >= term_cols(t) { c = term_cols(t) - 1; }
    if r >= term_rows(t) { r = term_rows(t) - 1; }
    if c < 0 { c = 0; }
    if r < 0 { r = 0; }
    *line = term_abs_top(t) + cast(i64, r);
    *col = c;
}

private void term_sel_begin(i32 t, i32 x, i32 y) {
    ed_term_sel_clear();
    g_tsel_t = t;
    term_sel_cell(t, x, y, &g_tsel_al, &g_tsel_ac);
    g_tsel_hl = g_tsel_al;
    g_tsel_hc = g_tsel_ac;
    g_tsel_drag = true;
}

private void term_sel_drag(i32 x, i32 y) {
    if !g_tsel_drag || g_tsel_t < 0 || !term_live(g_tsel_t) { return; }
    term_sel_cell(g_tsel_t, x, y, &g_tsel_hl, &g_tsel_hc);
    g_tsel_on = g_tsel_hl != g_tsel_al || g_tsel_hc != g_tsel_ac;
    plat_damage();
}

private void term_sel_end() {
    g_tsel_drag = false;
    drag_scroll_stop();
    if !g_tsel_on { ed_term_sel_clear(); }
}

// --- a drag selection's autoscroll -----------------------------------
// A left drag that selects text in a document pane, or cells in a
// terminal pane, scrolls the view while the pointer is near or past the
// top or bottom of the text, and the selection's head follows to the
// edge row. The zone reaches half a line into the text, so a maximized
// window with no room below the text still scrolls. The speed grows
// with the distance past the zone's inner edge. A document moves by
// pixels, a terminal by whole lines. Each frame advances it by the time
// since the last step and asks for the next frame, so the platform
// paces it to the display. A timer keeps it going with the pointer at
// rest; the timer runs only while the pointer is in the zone.

const i32 DRAG_SCROLL_TIMER = 12;   // 7 the player's, 8 the terminal probe's, 9 search's, 10 the watcher's, 11 the notices'
private const i32 DRAG_SCROLL_MS = 16;
private const i32 DRAG_SCROLL_ZONE_DIV = 2;        // the zone is a line over this, inside the text
private const f32 DRAG_SCROLL_MIN_LPS = 8.0f;      // lines a second at the zone's inner edge
private const f32 DRAG_SCROLL_LPS_PER_LINE = 16.0f;  // and this many more per line past it
private const f32 DRAG_SCROLL_MAX_LPS = 240.0f;

private bool g_text_drag = false;   // a left press in a document's text, held
private bool g_dscroll_on = false;  // the timer runs
private i32 g_dscroll_x = 0;        // where the pointer was last seen
private i32 g_dscroll_y = 0;
private f32 g_dscroll_acc = 0.0f;   // lines owed short of a whole step
private i64 g_dscroll_t = 0;        // the last tick
private i32 g_dscroll_win = -1;     // the window the drag is in

// the active pane's text rows on screen, y0 to y1: the document's lines
// or the terminal's grid
private void drag_scroll_rows(i32* y0, i32* y1) {
    *y0 = doc_top();
    if g_panes[g_pane_active].kind == PANE_TERM {
        *y1 = doc_top() + term_rows(g_panes[g_pane_active].term) * font_line_h;
    } else {
        *y1 = doc_top() + visible_lines() * font_line_h;
    }
}

// y moved inside the text rows, so the head lands on the edge row
private i32 drag_scroll_clamp_y(i32 y) {
    i32 y0 = 0;
    i32 y1 = 0;
    drag_scroll_rows(&y0, &y1);
    if y < y0 { y = y0; }
    if y > y1 - 1 { y = y1 - 1; }
    return y;
}

// lines a second for a pointer at y: negative up, 0 outside the zone
private f32 drag_scroll_speed(i32 y) {
    i32 y0 = 0;
    i32 y1 = 0;
    drag_scroll_rows(&y0, &y1);
    i32 lh = font_line_h;
    i32 zone = lh / DRAG_SCROLL_ZONE_DIV;
    if y1 - y0 < 4 * lh { return 0.0f; }
    f32 past = 0.0f;
    f32 sign = 1.0f;
    if y < y0 + zone {
        past = cast(f32, y0 + zone - y);
        sign = -1.0f;
    } else if y >= y1 - zone {
        past = cast(f32, y - (y1 - zone));
    } else {
        return 0.0f;
    }
    f32 v = DRAG_SCROLL_MIN_LPS + past / cast(f32, lh) * DRAG_SCROLL_LPS_PER_LINE;
    if v > DRAG_SCROLL_MAX_LPS { v = DRAG_SCROLL_MAX_LPS; }
    return v * sign;
}

private void drag_scroll_stop() {
    if !g_dscroll_on { return; }
    g_dscroll_on = false;
    plat_kill_timer(DRAG_SCROLL_TIMER);
}

// the pointer moved during a selecting drag: the timer starts in the
// zone and stops out of it
private void drag_scroll_track(i32 x, i32 y) {
    g_dscroll_x = x;
    g_dscroll_y = y;
    bool want = drag_scroll_speed(y) != 0.0f;
    if want && !g_dscroll_on {
        g_dscroll_on = true;
        g_dscroll_acc = 0.0f;
        g_dscroll_t = plat_time_us();
        g_dscroll_win = g_win;
        plat_set_timer(DRAG_SCROLL_TIMER, DRAG_SCROLL_MS);
    } else if !want {
        drag_scroll_stop();
    }
}

// a tick: the lines owed since the last one, and the head to the edge
private void drag_scroll_tick() {
    if !g_text_drag && !g_tsel_drag {
        drag_scroll_stop();
        return;
    }
    i64 now = plat_time_us();
    i64 dt = now - g_dscroll_t;
    g_dscroll_t = now;
    if dt < 0 { dt = 0; }
    g_dscroll_acc += drag_scroll_speed(g_dscroll_y) * cast(f32, dt) / 1000000.0f;
    i32 y = drag_scroll_clamp_y(g_dscroll_y);
    if g_tsel_drag {
        i32 n = cast(i32, g_dscroll_acc);
        if n == 0 { return; }
        g_dscroll_acc -= cast(f32, n);
        i32 t = g_tsel_t;
        if t < 0 || !term_live(t) { return; }
        // the view counts lines up into the history
        term_view_set(t, term_view(t) - n);
        term_sel_drag(g_dscroll_x, y);
        return;
    }
    i32 lh = font_line_h;
    i32 px = cast(i32, g_dscroll_acc * cast(f32, lh));
    if px == 0 { return; }
    g_dscroll_acc -= cast(f32, px) / cast(f32, lh);
    scroll_set(scroll_y + px);
    // the head goes to the edge row that shows whole, so following the
    // caret does not snap the view back to a row boundary
    if scroll_off > 0 {
        i32 y0 = 0;
        i32 y1 = 0;
        drag_scroll_rows(&y0, &y1);
        if y < y0 + lh - scroll_off { y = y0 + lh - scroll_off; }
        if y >= y1 - scroll_off { y = y1 - scroll_off - 1; }
    }
    caret_to_point(g_dscroll_x, y);
    goal_vcol = -1;
    after_move();
    ed_damage();
}

// frame build, before anything is drawn: the autoscroll steps once a
// frame in the window it runs in
void ed_drag_scroll_frame() {
    if g_dscroll_on && g_dscroll_win == g_win { drag_scroll_tick(); }
}

// whether this window's autoscroll runs, so it needs another frame
bool ed_drag_scroll_running() {
    return g_dscroll_on && g_dscroll_win == g_win;
}

// the selected text, lines joined by newlines; the caller frees
u8* ed_term_sel_text(i64* n) {
    *n = 0;
    i64 l0 = 0;
    i64 l1 = 0;
    i32 c0 = 0;
    i32 c1 = 0;
    if !ed_term_sel_get(g_tsel_t, &l0, &c0, &l1, &c1) { return null; }
    i32 t = g_tsel_t;
    i64 first = term_abs_first(t);
    i64 end = term_abs_end(t);
    if l0 < first { l0 = first; c0 = 0; }
    if l1 >= end { l1 = end - 1; c1 = term_cols(t) - 1; }
    if l1 < l0 { return null; }
    i64 cap = (l1 - l0 + 1) * (cast(i64, term_cols(t)) * 4 + 1) + 1;
    u8* out = alloc<u8>(cap);
    i64 o = 0;
    for i64 l = l0; l <= l1; l++ {
        i32 a = 0;
        i32 b = term_cols(t);
        if l == l0 { a = c0; }
        if l == l1 { b = c1 + 1; }
        o += cast(i64, term_abs_text(t, l, a, b, out + o, cast(i32, cap - o - 1)));
        if l < l1 { out[o] = 10; o++; }
    }
    *n = o;
    return out;
}

// the primary's copy chord over a selection
void ed_term_copy() {
    i64 n = 0;
    u8* s = ed_term_sel_text(&n);
    if s == null { return; }
    if n > 0 { plat_clipboard_set(s, n); }
    free(s);
    ed_status("copied");
    plat_damage();
}

// what has to hold of the selection; the fuzzer asks every step
str ed_term_sel_check() {
    if !g_tsel_on { return ""; }
    if g_tsel_t < 0 || !term_live(g_tsel_t) { return "a selection on no terminal"; }
    if g_tsel_ac < 0 || g_tsel_hc < 0 { return "a selection column before the grid"; }
    return "";
}

// the terminal with the focus, else the first one on screen, else -1
i32 ed_term_shown() {
    i32 t = ed_term_active();
    if t < 0 { t = ed_pane_term(term_pane_find()); }
    return t;
}

// The screen of the terminal pane with the focus, else the first
// terminal pane, as text; 0 bytes with none. The drivers' --dump-term
// flag writes it, which is how the pane is checked without a window.
i32 ed_term_dump(u8* out, i32 cap) {
    i32 t = ed_term_shown();
    if t < 0 { return 0; }
    return term_dump(t, out, cap);
}

// the terminal cell under a window point, in the active pane
void ed_term_cell_at(i32 x, i32 y, i32* col, i32* row) {
    i32 x0 = 0;
    i32 x1 = 0;
    ed_pane_rect(g_pane_active, &x0, &x1);
    i32 c = (x - x0 - TERM_PAD_PX) / font_cell_w;
    i32 r = (y - doc_top()) / font_line_h;
    if c < 0 { c = 0; }
    if r < 0 { r = 0; }
    *col = c;
    *row = r;
}

// the editor's paste chord, into the terminal: the shell cannot see the
// editor's clipboard, so the text goes in as a paste
private void ed_term_paste() {
    i64 n = 0;
    u8* p = plat_clipboard_get(&n);
    if p == null { return; }
    term_paste(ed_term_active(), p, n);
    free(p);
    plat_damage();
}

// --- opening a diff ---------------------------------------------------

// the baseline document the left pane shows, built from the bytes git
// fetched for this buffer. Held outside the table, so it is made and
// dropped here rather than through the buffer paths.
private void diff_build_base() {
    pane_save(g_pane_active);
    diff_build_base_from_loaded();
    pane_apply(g_pane_active);
}

// the left side from the loaded buffer's baseline; the loaded buffer is
// the diff's file, and it is loaded again after
private void diff_build_base_from_loaded() {
    tb_quiet = true;
    i32 cur = g_buf_active;
    i32 lang = g_lex_lang;
    bool lex = g_lex_on;
    u8* bytes = git_base_bytes();
    i64 n = git_base_size();
    buf_store(cur);
    buf_fresh();
    tb_init_empty();
    if n > 0 { tb_insert(0, bytes, cast(i32, n)); }
    tb.dirty = false;
    g_lex_on = lex;
    g_lex_lang = lang;   // the file's language, not the default
    cur_line = 0;
    cur_col = 0;
    scroll_set(0);
    buf_store(BUF_DIFF_BASE);
    buf_load(cur);
    tb_quiet = false;
}

// A new baseline landed for the diff's file, in slot s: HEAD moved under
// the diff. The rows now pair against it, so the left side is rebuilt
// from it; left as it was, the rows name lines it does not have.
private void diff_rebase(i32 s) {
    i32 cur = g_buf_active;
    pane_save(g_pane_active);
    if cur != s {
        buf_store(cur);
        buf_load(s);
    }
    diff_free_base();
    diff_build_base_from_loaded();
    if cur != s {
        buf_store(s);
        buf_load(cur);
    }
    pane_apply(g_pane_active);
}

// slot s holds the file the diff shows
private bool diff_is_file(i32 s) {
    if !diff_on { return false; }
    str d = str_from(&diff_path[0], diff_path_len);
    if s == g_buf_active { return g_has_path && str_equal(str_from(&g_path[0], g_path_len), d); }
    return g_bufs[s].has_path && str_equal(str_from(&g_bufs[s].path[0], g_bufs[s].path_len), d);
}

private void diff_free_base() {
    tb_quiet = true;
    i32 cur = g_buf_active;
    buf_store(cur);
    buf_load(BUF_DIFF_BASE);
    buf_free_loaded();
    buf_store(BUF_DIFF_BASE);
    buf_load(cur);
    tb_quiet = false;
}

// the baseline is here: put the two panes up
private void diff_arm() {
    if !diff_want || diff_on { return; }
    if !git_on() || git_base_bytes() == null { return; }
    if diff_rev {
        if !g_rev { return; }
    } else if !g_has_path || !str_equal(str_from(&g_path[0], g_path_len),
        str_from(&diff_path[0], diff_path_len)) { return; }
    git_rows_enable(true);
    if git_row_count() == 0 { return; }
    diff_build_base();
    // a lone pane is split in half for this; two or more are used as
    // they stand, dividers and all, and the file takes the second so
    // the sides read left to right whichever pane it was opened from
    // the baseline arriving while the bottom pane has the focus: the
    // diff goes up when its file's column is active again
    if pane_is_bottom(g_pane_active) { return; }
    diff_made_pane = pane_cols() < 2;
    if diff_made_pane {
        // a second column, with the bottom pane moved along behind it
        if g_bottom { g_panes[2] = g_panes[1]; }
        g_npanes++;
        g_pane_div[0] = 0.0f;
        g_pane_div[1] = 0.5f;
        for i32 j = 2; j <= PANE_MAX; j++ { g_pane_div[j] = 1.0f; }
    }
    diff_saved0 = g_panes[0];
    Pane file_pane = g_panes[g_pane_active];
    g_panes[0] = file_pane;
    g_panes[0].buf = BUF_DIFF_BASE;
    pane_set_doc(0);
    g_panes[0].cur_line = 0;
    g_panes[0].cur_col = 0;
    g_panes[0].scroll_y = 0;
    g_panes[0].ncur = 0;
    g_panes[0].sel_active = false;
    g_panes[1] = file_pane;
    g_pane_active = 1;
    g_pane_loaded = 1;
    diff_on = true;
    diff_want = false;
    // open on the first change, as the reference does
    i32 r = git_row_next_change(-1);
    if r >= 0 {
        i32 l = git_row_b(r);
        if l < 0 { l = ed_line_at_y(doc_top()); }
        if l >= 0 {
            cur_line = l;
            cur_col = 0;
            after_move();
            diff_center_row(r);
        }
    }
    plat_damage();
}

// Show `path` against HEAD. The baseline is fetched on a worker, so
// this may only arm the view; the fetch landing finishes it.
void ed_diff_open(str path) {
    if path.len == 0 || path.len > PATH_MAX { return; }
    if diff_on { ed_diff_close(); }
    // the file belongs in the second pane, which is the side the diff
    // reads it from. Opening it into whichever pane happened to be
    // active would take a pane beside the diff along with it.
    if pane_cols() >= 2 && g_pane_active != 1 {
        ed_pane_focus(1);
    } else if pane_is_bottom(g_pane_active) {
        bottom_leave();
    }
    // copied first: the caller's str can point into the sidebar's arena,
    // which the open rebuilds
    memcpy(&diff_path[0], path.data, path.len);
    diff_path_len = path.len;
    diff_rev = false;
    if !ed_view_file(str_from(&diff_path[0], diff_path_len)) {
        diff_path_len = 0;
        return;
    }
    diff_want = true;
    diff_arm();
    if !diff_on {
        // nothing at HEAD to put beside it, or the fetch is still out
        if git_fetched() && !git_on() { ed_status("no baseline for this file"); }
    }
}

// A file as a commit had it, beside its first parent's version (hist.mc).
// A new buffer holds `right`, lexed by `lang_path`'s extension and named
// `name`, with `left` as its baseline, so the diff pairs the two as it
// pairs a file with HEAD; `left_name` heads the left side. The buffer
// is a preview: the next one looked at takes its place.
void ed_rev_diff(str lang_path, str name, str left_name, u8* right, i64 rn, u8* left, i64 ln) {
    if diff_on { ed_diff_close(); }
    if pane_cols() >= 2 && g_pane_active != 1 {
        ed_pane_focus(1);
    } else if pane_is_bottom(g_pane_active) {
        bottom_leave();
    }
    term_leave_for_doc();
    ed_lsp_flush();
    if !g_session_loading { buf_soft_evict(); }
    if g_nbufs == BUF_MAX {
        i32 v = buf_victim();
        if v < 0 {
            ed_notice("cannot open: every open buffer is unsaved or on screen. Save or close some (ctrl+s, ctrl+w) and try again.");
            return;
        }
        buf_evict(v);
    }
    buf_store(g_buf_active);
    g_buf_active = g_nbufs;
    g_nbufs++;
    buf_touch(g_buf_active);
    buf_fresh();
    g_preview = true;
    g_rev = true;
    i32 nn = name.len;
    if nn > REV_NAME_MAX { nn = REV_NAME_MAX; }
    memcpy(&g_rev_name[0], name.data, nn);
    g_rev_name_len = nn;
    lex_set_for(lang_path);
    tb_init_empty();
    if right != null && rn > 0 { tb_insert(0, right, cast(i32, rn)); }
    undo_clear();
    tb.dirty = false;
    sel_clear();
    cur_line = 0;
    cur_col = 0;
    goal_vcol = -1;
    left_vcol = 0;
    scroll_set(0);
    g_scroll_accum = 0.0f;
    // the parent's version is the baseline; an added file's is empty
    u8 none = 0;
    if left != null { git_set_baseline(left, ln); } else { git_set_baseline(&none, 0); }
    git_note_fetched();
    pane_save(g_pane_active);
    update_title();
    after_move();
    i32 ln2 = left_name.len;
    if ln2 > PATH_MAX { ln2 = PATH_MAX; }
    memcpy(&diff_path[0], left_name.data, ln2);
    diff_path_len = ln2;
    diff_rev = true;
    diff_want = true;
    diff_arm();
    if !diff_on {
        // the two versions are both empty: nothing to pair
        diff_want = false;
        diff_rev = false;
    }
    if !g_session_loading { buf_trim_previews(); }
    plat_damage();
}

// the diff on screen is a commit's, not the file against HEAD
bool ed_diff_rev() {
    return diff_rev;
}

// the loaded buffer is a commit's version
bool ed_rev_on() {
    return g_rev;
}

str ed_rev_name() {
    return str_from(&g_rev_name[0], g_rev_name_len);
}

// the file's own name, for the baseline pane's banner: that side is a
// document with no path, so it has no name of its own
str ed_diff_name() {
    if diff_path_len == 0 { return ""; }
    i32 base = path_base_off(&diff_path[0], diff_path_len);
    return str_from(&diff_path[0] + base, diff_path_len - base);
}

// The two change arrows in the diff's banner, at the right end of the
// file's pane. The geometry is here, not in the renderer, so that what
// is drawn and what is pressed are the same rect, and so a headless run
// can press them. `i` is 0 for the change above, 1 for the one below.
private const i32 DIFF_ARROW_PAD = 8;

i32 ed_diff_arrow_w() {
    return font_ui_h + font_ui_h / 2;
}

i32 ed_diff_arrow_x(i32 i) {
    i32 px0 = 0;
    i32 px1 = 0;
    ed_pane_rect(1, &px0, &px1);
    return px1 - DIFF_ARROW_PAD - (2 - i) * ed_diff_arrow_w();
}

// which arrow the pointer is over, for the renderer's hover fill
private i32 diff_arrow_hover = -1;

i32 ed_diff_arrow_hover() {
    return diff_arrow_hover;
}

i32 ed_diff_arrow_hit(i32 x, i32 y) {
    if !diff_on || y < 0 || y >= doc_top() { return -1; }
    for i32 i = 0; i < 2; i++ {
        i32 ax = ed_diff_arrow_x(i);
        if x >= ax && x < ax + ed_diff_arrow_w() { return i; }
    }
    return -1;
}

// put a row in the middle of the view rather than merely on screen
private void diff_center_row(i32 r) {
    i32 vis = visible_lines();
    i32 top = r - vis / 2;
    if top < 0 { top = 0; }
    scroll_set(top * font_line_h);
}

// F7 and Shift+F7: the caret to the top of the next changed block, or
// the one before it. A block whose rows are all on the other side (a
// deletion) has no line here, so the caret lands on the line that
// follows the gap, which is where typing would put text back.
void ed_diff_jump(bool back) {
    if !diff_here() { return; }
    i32 r = ed_row_of_line(cur_line);
    if r < 0 { r = 0; }
    // A scroll moves the view and leaves the caret behind, so a caret
    // that is not on screen is not where the reader is: walk from the
    // edge of what they are looking at instead.
    i32 vis = visible_lines();
    if r < top_line || r >= top_line + vis {
        r = top_line;
        if back { r = top_line + vis - 1; }
    }
    i32 t = git_row_next_change(r);
    if back { t = git_row_prev_change(r); }
    if t < 0 {
        ed_status("no more changes");
        plat_damage();
        return;
    }
    i32 l = git_row_b(t);
    i32 k = t;
    i32 n = git_row_count();
    while l < 0 && k + 1 < n {
        k++;
        l = git_row_b(k);
    }
    if l < 0 { l = tb.nlines - 1; }
    cur_line = l;
    cur_col = 0;
    sel_active = false;
    cur_collapse();
    after_move();
    diff_center_row(t);
    plat_damage();
}

// --- reverting a block --------------------------------------------------
// Each changed block has an arrow at its first row, in a column left of
// the file pane's line numbers, next to the baseline's side. A click
// puts the baseline's lines in place of the block's, as one edit. A
// commit's diff has none: its right side is not editable.

// the first row of the changed block row r is in, -1 when r is not in one
private i32 diff_block_top(i32 r) {
    if git_row_kind(r) == GIT_NONE { return -1; }
    while r > 0 && git_row_kind(r - 1) != GIT_NONE { r--; }
    return r;
}

// row r starts a changed block and so carries an arrow
bool ed_diff_revert_row(i32 r) {
    if !diff_on || diff_rev { return false; }
    return git_row_kind(r) != GIT_NONE && (r == 0 || git_row_kind(r - 1) == GIT_NONE);
}

private const i32 DIFF_REVERT_PAD = 2;

// the arrows' column, left of the line numbers in the file's pane
private i32 diff_margin_w() {
    return font_ui_h + 2 * DIFF_REVERT_PAD;
}

// the loaded pane's share of that column: 0 outside a diff's file pane
i32 ed_diff_margin_w() {
    if !diff_here() || diff_base_side || diff_rev { return 0; }
    return diff_margin_w();
}

// the arrows' column: x from the file pane's left edge
i32 ed_diff_revert_x() {
    i32 px0 = 0;
    i32 px1 = 0;
    ed_pane_rect(1, &px0, &px1);
    return px0;
}

// the row whose arrow is at (x, y), -1 for none
i32 ed_diff_revert_hit(i32 x, i32 y) {
    if !diff_on || diff_rev || pane_at(x, y) != 1 { return -1; }
    i32 ax = ed_diff_revert_x();
    if x < ax || x >= ax + diff_margin_w() { return -1; }
    i32 dt = pane_doc_top(1);
    if y < dt || y >= g_h - chrome_bottom_h() { return -1; }
    i32 sy = g_panes[1].scroll_y;
    if g_pane_loaded == 1 { sy = scroll_y; }
    i32 r = (sy + y - dt) / font_line_h;
    if !ed_diff_revert_row(r) { return -1; }
    return r;
}

private i32 diff_revert_hover = -1;

i32 ed_diff_revert_hover() {
    return diff_revert_hover;
}

// The byte span of lines [l0, l1] of `p`, the newline after l1 left out.
// Lines split on '\n' as git.mc splits them.
private void diff_base_span(u8* p, i64 n, i32 l0, i32 l1, i64* s, i64* e) {
    i32 l = 0;
    i64 i = 0;
    while l < l0 && i < n {
        if p[i] == '\n' { l++; }
        i++;
    }
    *s = i;
    while i < n {
        if p[i] == '\n' {
            if l == l1 { break; }
            l++;
        }
        i++;
    }
    *e = i;
}

// Put the baseline's lines back in place of the block that starts at
// row r. The file's pane is the loaded one. Lines join on '\n', so a
// side with no lines in the block takes or gives one separator.
void ed_diff_revert(i32 r) {
    if !diff_here() || diff_base_side || diff_rev { return; }
    // a wide edit leaves the rows to the timer; pair them now, since the
    // arrow was drawn from rows that may not match the text
    if git_timer_on {
        ed_git_untouch();
        git_recompute();
        plat_damage();
        return;
    }
    r = diff_block_top(r);
    if r < 0 { return; }
    i32 n = git_row_count();
    i32 a0 = -1;
    i32 a1 = -1;
    i32 b0 = -1;
    i32 b1 = -1;
    i32 k = r;
    while k < n && git_row_kind(k) != GIT_NONE {
        i32 a = git_row_a(k);
        i32 b = git_row_b(k);
        if a >= 0 {
            if a0 < 0 { a0 = a; }
            a1 = a;
        }
        if b >= 0 {
            if b0 < 0 { b0 = b; }
            b1 = b;
        }
        k++;
    }
    u8* base = git_base_bytes();
    i64 bn = git_base_size();
    if b1 >= tb.nlines || a1 >= git_base_lines() || (a0 >= 0 && base == null) { return; }
    i64 as = 0;
    i64 ae = 0;
    if a0 >= 0 { diff_base_span(base, bn, a0, a1, &as, &ae); }
    i64 pos = 0;
    i64 ndel = 0;
    u8* ins = null;
    i64 nins = 0;
    if b0 >= 0 && a0 >= 0 {
        // lines for lines
        pos = tb_line_start(b0);
        ndel = tb_line_end(b1) - pos;
        ins = base + as;
        nins = ae - as;
    } else if b0 >= 0 {
        // lines the buffer added: they go with one separator
        if b1 + 1 < tb.nlines {
            pos = tb_line_start(b0);
            ndel = tb_line_start(b1 + 1) - pos;
        } else {
            pos = tb_line_end(b0 - 1);
            ndel = tb_line_end(b1) - pos;
        }
    } else if a0 >= 0 {
        // lines the buffer lost: back before the line after the gap,
        // or after the last line
        nins = ae - as + 1;
        u8* tmp = alloc<u8>(nins);
        bool at_end = k >= n || git_row_b(k) < 0;
        if !at_end {
            pos = tb_line_start(git_row_b(k));
            memcpy(tmp, base + as, ae - as);
            tmp[nins - 1] = '\n';
        } else {
            pos = tb_len();
            tmp[0] = '\n';
            memcpy(tmp + 1, base + as, ae - as);
        }
        undo_break = true;
        ed_replace(pos, 0, tmp, cast(i32, nins));
        free(tmp);
        i32 line = tb_line_of(pos);
        if at_end { line++; }
        diff_revert_done(line);
        return;
    }
    undo_break = true;
    ed_replace(pos, ndel, ins, cast(i32, nins));
    diff_revert_done(tb_line_of(pos));
}

// the caret to the start of the reverted block, and the edit closed so
// the next keystroke is an undo step of its own
private void diff_revert_done(i32 line) {
    undo_break = true;
    cur_line = clamp_line(line);
    cur_col = 0;
    sel_clear();
    cur_collapse();
    goal_vcol = -1;
    diff_revert_hover = -1;
    after_move();
    plat_damage();
}

// a baseline landed for the buffer on screen
void ed_diff_note_baseline() {
    diff_arm();
}

// Panes right of the diff's two are not part of it: a split made during
// the diff or the build pane stay, and the focus stays where it is. The
// baseline pane is never the active one.
// --- the baseline side's selection --------------------------------------
// The left side of a diff never takes the focus: it has no buffer slot,
// and the focus puts the active pane's slot in g_buf_active. Its text
// can still be selected and copied. A press or a drag there loads it
// the way the frame build does, sets its own selection in its pane
// record, and puts the file's pane back; the view draws that selection
// as it draws any pane's. The copy chord takes it while it is the last
// selection made (g_bsel); a key or a click anywhere else clears it.
private bool g_bsel = false;
private bool g_bsel_drag = false;

// the position under a window point in the loaded baseline side
private i64 base_point(i32 x, i32 y) {
    i32 px0 = 0;
    i32 px1 = 0;
    ed_pane_rect(0, &px0, &px1);
    i32 l = clamp_line(ed_line_at_y(y));
    i32 v = left_vcol + (x - px0 - gutter_w() + font_cell_w / 2) / font_cell_w;
    if v < 0 { v = 0; }
    return tb_line_start(l) + col_of_vcol(l, v);
}

private void base_sel_press(i32 x, i32 y, i32 clicks) {
    i32 act = g_pane_active;
    ed_pane_swap_view(0);
    i64 at = base_point(x, y);
    g_ncur = 0;
    set_caret_abs(at);
    sel_anchor = at;
    sel_active = true;
    if clicks == 2 {
        // a word, as a double click selects one in any pane
        i32 ws = 0;
        i32 we = 0;
        if word_bounds(&ws, &we) {
            sel_anchor = tb_line_start(cur_line) + ws;
            cur_col = we;
        }
    } else if clicks >= 3 {
        i32 l = cur_line;
        sel_anchor = tb_line_start(l);
        if l + 1 < tb.nlines {
            cur_line = l + 1;
            cur_col = 0;
        } else {
            cur_col = line_len(l);
        }
    }
    ed_pane_swap_view(act);
    g_bsel = true;
    g_bsel_drag = clicks == 1;
    plat_damage();
}

private void base_sel_drag(i32 x, i32 y) {
    i32 act = g_pane_active;
    ed_pane_swap_view(0);
    set_caret_abs(base_point(x, y));
    ed_pane_swap_view(act);
    ed_damage();
}

private void base_sel_clear() {
    if !g_bsel && !g_bsel_drag { return; }
    g_bsel = false;
    g_bsel_drag = false;
    g_panes[0].sel_active = false;
    plat_damage();
}

// the baseline side's selection to the clipboard
private void base_copy() {
    i32 act = g_pane_active;
    ed_pane_swap_view(0);
    ed_copy();
    ed_pane_swap_view(act);
}

// what the baseline side has selected, for the checks
str ed_diff_base_selection() {
    if !diff_on || !g_bsel { return ""; }
    i32 act = g_pane_active;
    ed_pane_swap_view(0);
    i64 a = 0;
    i64 b = 0;
    str out = "";
    if ed_sel_range(&a, &b) {
        u8* buf = alloc<u8>(b - a + 1);
        tb_copy(a, buf, b - a);
        out = str_from(buf, cast(i32, b - a));
    }
    ed_pane_swap_view(act);
    return out;
}

void ed_diff_close() {
    g_bsel = false;
    g_bsel_drag = false;
    if !diff_on {
        diff_want = false;
        diff_rev = false;
        return;
    }
    diff_rev = false;
    i32 act = g_pane_active;
    if act < 1 { act = 1; }
    g_pane_active = act;
    g_pane_loaded = act;
    pane_save(act);
    diff_on = false;
    diff_base_side = false;
    diff_arrow_hover = -1;
    diff_revert_hover = -1;
    diff_free_base();
    git_rows_enable(false);
    if diff_made_pane {
        // the diff made the baseline's pane, so it takes it away again:
        // every pane moves one to the left and the file keeps its own
        for i32 j = 0; j < g_npanes - 1; j++ {
            g_panes[j] = g_panes[j + 1];
        }
        for i32 j = 1; j < g_npanes; j++ {
            g_pane_div[j] = g_pane_div[j + 1];
        }
        g_pane_div[0] = 0.0f;
        g_npanes--;
        act--;
        g_pane_active = act;
        g_pane_loaded = act;
        pane_apply(act);
    } else {
        // borrowed panes: the left one goes back to what it showed and
        // the file stays in the right, where it has been read
        g_panes[0] = diff_saved0;
    }
    diff_made_pane = false;
    diff_path_len = 0;
    plat_damage();
}

void ed_pane_focus(i32 p) {
    // the baseline is not a document to work in; a click on it leaves
    // the focus where it was
    if diff_on && p == 0 { return; }
    if p < 0 || p >= g_npanes || p == g_pane_active { return; }
    pane_save(g_pane_active);
    pane_enter(p);
}

// pane p takes the focus: its buffer into the globals, its view applied
private void pane_enter(i32 p) {
    if g_panes[p].buf != g_buf_active {
        buf_store(g_buf_active);
        buf_load(g_panes[p].buf);
        buf_touch(g_panes[p].buf);
    }
    pane_apply(p);
    g_pane_active = p;
    g_pane_loaded = p;
    if !pane_is_bottom(p) { g_col_last = p; }
    goal_vcol = -1;
    g_scroll_accum = 0.0f;
    undo_break = true;
    g_close_armed = false;
    update_title();
    reset_blink();
    plat_damage();
}

// A terminal pane gives its pane back to the document it kept: the
// shell ends (kill) or drops to the background, in the switcher's
// list, and comes back through it or through Ctrl+J for the build's.
private void term_pane_release(i32 p, bool kill) {
    if kill {
        if g_panes[p].term == build_term() { build_pane_closed(); }
        ed_term_close(g_panes[p].term);
    }
    pane_set_doc(p);
    update_title();
    reset_blink();
    plat_damage();
}

// Ctrl+W: what the active pane shows goes, the pane staying for the
// next thing, as a tab closes in a group. A terminal pane's shell
// ends and the pane shows the document it kept; a document pane's
// buffer closes (dirty ones refuse once) and every pane that showed it
// lands on the buffer after it.
void ed_close_shown() {
    // the bottom pane holds the build's run and nothing else: Ctrl+W
    // ends the run and the pane goes with it
    if pane_is_bottom(g_pane_active) {
        bottom_remove(true);
        return;
    }
    if g_panes[g_pane_active].kind == PANE_TERM {
        term_pane_release(g_pane_active, true);
        return;
    }
    // A buffer another pane or window shows stays open: Ctrl+W closes
    // this view of it, as closing an editor in one VS Code group leaves
    // it open in another. The pane shows the buffer seen before it, or
    // goes when there is none and it is not the last column.
    if buf_shown_elsewhere(g_buf_active) {
        i32 other = buf_other_recent(g_buf_active);
        if other >= 0 {
            ed_buf_switch(other);
        } else if pane_cols() > 1 {
            ignore ed_pane_hide();
        } else {
            ed_warn("this buffer is open in another window");
        }
        g_close_armed = false;
        plat_damage();
        return;
    }
    ed_buf_close();
}

// buffer b is on a document pane other than the active one, in this
// window or another
private bool buf_shown_elsewhere(i32 b) {
    for i32 p = 0; p < g_npanes; p++ {
        if p == g_pane_active { continue; }
        if g_panes[p].kind == PANE_DOC && g_panes[p].buf == b { return true; }
    }
    for i32 w = 0; w < WIN_MAX; w++ {
        if w == g_win || !g_wins[w].used { continue; }
        for i32 p = 0; p < g_wins[w].npanes; p++ {
            if g_wins[w].panes[p].kind == PANE_DOC && g_wins[w].panes[p].buf == b { return true; }
        }
    }
    return false;
}

// Close the active pane, focusing its left neighbor; false when it is
// the last pane. Close ends a terminal pane's shell with the pane;
// hide (Ctrl+Shift+W) keeps it, the terminal dropping to the
// background and a buffer staying open.
bool ed_pane_close() {
    return pane_close_impl(true);
}

bool ed_pane_hide() {
    return pane_close_impl(false);
}

private bool pane_close_impl(bool kill) {
    // The diff's panes end the diff first. Pane 0 holds the baseline,
    // which has no buffer slot, so the pane left of a closed diff pane
    // cannot take the focus while the diff is on. A pane the diff made
    // goes with it, which is the close. Borrowed panes are the user's
    // again, and the active one then closes as asked.
    if diff_on && g_pane_active <= 1 {
        bool made = diff_made_pane;
        ed_diff_close();
        if made { return true; }
    }
    // the last column stays; with the bottom pane under it, that goes,
    // so closing panes until one is left always gets there
    if pane_is_bottom(g_pane_active) || (pane_cols() <= 1 && g_bottom) {
        bottom_remove(kill);
        return true;
    }
    if pane_cols() <= 1 {
        // the only pane: a terminal gives the pane back to the document
        // it kept, rather than closing that document behind the shell
        if g_panes[g_pane_active].kind != PANE_TERM { return false; }
        term_pane_release(g_pane_active, kill);
        return true;
    }
    i32 dying = g_pane_active;
    if g_panes[dying].kind == PANE_TERM {
        if kill {
            if g_panes[dying].term == build_term() { build_pane_closed(); }
            ed_term_close(g_panes[dying].term);
        }
        pane_set_doc(dying);
    }
    for i32 j = dying; j < g_npanes - 1; j++ {
        g_panes[j] = g_panes[j + 1];
    }
    i32 dk = dying;
    if dk == 0 { dk = 1; }
    for i32 j = dk; j < g_npanes; j++ {
        g_pane_div[j] = g_pane_div[j + 1];
    }
    g_npanes--;
    g_div_drag = -1;   // the dividers moved under any drag in flight
    i32 np = 0;
    if dying > 0 { np = dying - 1; }
    pane_enter(np);
    ed_term_fit();
    return true;
}

// wheel over an inactive pane scrolls it without moving focus
private void pane_scroll(i32 p, i32 step) {
    ed_pane_swap_view(p);
    i32 before = scroll_y;
    scroll_set(scroll_y + step);
    if g_scroll_notch && scroll_y != before { glide_step(p, scroll_y - before, true); }
    ed_pane_swap_view(g_pane_active);
    ed_damage();
}

// the widest visual line among the rows pane p shows, loaded in the
// globals: how far the view can scroll right
private i32 widest_visible() {
    i32 w = 0;
    i32 last = top_line + visible_lines();
    for i32 r = top_line; r <= last; r++ {
        i32 l = ed_line_of_row(r);
        if l < 0 || l >= tb.nlines { continue; }
        i32 v = vcol_of_col(l, cast(i64, line_bytes(l)));
        if v > w { w = v; }
    }
    return w;
}

private f32 g_hscroll_accum = 0.0f;   // sideways scroll short of a column

// sideways by `dx` pixels in whole columns, the fraction carried over;
// the two sides of a diff move together
private void pane_hscroll(i32 p, f32 dx) {
    g_hscroll_accum += dx;
    i32 cols = cast(i32, g_hscroll_accum / cast(f32, font_cell_w));
    if cols == 0 { return; }
    g_hscroll_accum -= cast(f32, cols * font_cell_w);
    i32 a = p;
    i32 b = p;
    if diff_on && p <= 1 {
        a = 0;
        b = 1;
    }
    bool moved = false;
    for i32 q = a; q <= b; q++ {
        ed_pane_swap_view(q);
        if ed_wrap_on() { continue; }   // a wrapped view is as wide as its pane
        i32 most = widest_visible() - text_cols() + 2;
        if most < 0 { most = 0; }
        i32 lv = left_vcol + cols;
        if lv > most { lv = most; }
        if lv < 0 { lv = 0; }
        if lv != left_vcol {
            left_vcol = lv;
            moved = true;
        }
    }
    ed_pane_swap_view(g_pane_active);
    if moved { ed_damage(); }
}

private void ed_copy() {
    if g_ncur > 0 {
        multi_clip_copy();
        return;
    }
    i64 a = 0;
    i64 b = 0;
    if !ed_sel_range(&a, &b) { return; }
    i64 n = b - a;
    u8* buf = alloc<u8>(n);
    tb_copy(a, buf, n);
    plat_clipboard_set(buf, n);
    free(buf);
}

private void ed_cut() {
    if g_ncur > 0 {
        multi_clip_copy();
        multi_apply(OP_DELSEL);
        return;
    }
    i64 a = 0;
    i64 b = 0;
    if !ed_sel_range(&a, &b) { return; }
    ed_copy();
    ed_replace(a, b - a, null, 0);
}

private void ed_paste() {
    i64 n = 0;
    u8* s = plat_clipboard_get(&n);
    if s == null { return; }
    if n > 0 {
        undo_break = true;
        // the clipboard is read once and the same text goes in at every
        // cursor; splitting it per cursor is not what this does
        op_txt = s;
        op_txt_len = cast(i32, n);
        multi_apply(OP_INSTXT);
        op_txt = null;
        op_txt_len = 0;
        undo_break = true;
    }
    free(s);
}

// journal position: [0, depth) is undoable, [depth, total) redoable.
// The fuzzer pairs an undo run with an equal redo run, which needs the
// count that actually applied rather than the count it asked for.
i32 ed_undo_depth() {
    return undo_len;
}

i32 ed_undo_total() {
    return undo_total;
}

// One user action can be several journal entries, one per cursor, and
// the ones after the first carry `cont`. Both directions walk the
// whole run so a multi-cursor edit is a single undo step.
// Undo and redo with the find widget open: the buffer's, not the
// query's, and the widget stays (find.mc)
void ed_find_undo(bool redo) {
    if redo { ed_redo(); } else { ed_undo(); }
}

private void ed_undo() {
    if undo_len == 0 { return; }
    undo_break = true;
    i32 edit_line = tb.nlines;
    // Each entry remembers the caret that made it, so a group hands
    // back the cursor set the edit was typed with.
    noinit EdCursor[CUR_MAX + 1] cs;
    i32 nc = 0;
    while undo_len > 0 {
        undo_len--;
        UndoOp* op = undo_ops + undo_len;
        i32 l = tb_line_of(op.pos);
        if l < edit_line { edit_line = l; }
        if op.ins_len > 0 { tb_delete(op.pos, op.ins_len); }
        if op.del_len > 0 { tb_insert(op.pos, op.del, op.del_len); }
        if nc <= CUR_MAX {
            cs[nc] = EdCursor{ op.caret_before, op.caret_before, false, nc == 0 };
            nc++;
        }
        if !op.cont { break; }
    }
    undo_update_dirty();
    g_ncur = 0;
    cur_install(&cs[0], nc);
    goal_vcol = -1;
    after_edit(edit_line);
}

private void ed_redo() {
    if undo_len >= undo_total { return; }
    undo_break = true;
    i32 edit_line = tb.nlines;
    noinit EdCursor[CUR_MAX + 1] cs;
    noinit i64[CUR_MAX + 1] dl;
    i32 nc = 0;
    while undo_len < undo_total {
        UndoOp* op = undo_ops + undo_len;
        undo_len++;
        i32 l = tb_line_of(op.pos);
        if l < edit_line { edit_line = l; }
        if op.del_len > 0 { tb_delete(op.pos, op.del_len); }
        if op.ins_len > 0 { tb_insert(op.pos, op.ins, op.ins_len); }
        if nc <= CUR_MAX {
            i64 at = op.pos + cast(i64, op.ins_len);
            cs[nc] = EdCursor{ at, at, false, nc == 0 };
            dl[nc] = cast(i64, op.ins_len) - cast(i64, op.del_len);
            nc++;
        }
        if undo_len >= undo_total || !undo_ops[undo_len].cont { break; }
    }
    // A group replays highest position first, so each entry's end is in
    // the text as it stood before the lower ones ran. Shift each by what
    // the ops after it added or removed underneath. Undo needs no such
    // fixup: it walks the group the other way, so every caret_before it
    // reads is already in the text it is producing.
    i64 acc = 0;
    for i32 i = nc - 1; i >= 0; i-- {
        i64 d = dl[i];
        cs[i].caret += acc;
        cs[i].anchor += acc;
        acc += d;
    }
    undo_update_dirty();
    g_ncur = 0;
    cur_install(&cs[0], nc);
    goal_vcol = -1;
    after_edit(edit_line);
}

private void ed_select_all() {
    cur_collapse();
    undo_break = true;
    sel_anchor = 0;
    sel_active = true;
    set_caret_abs(tb_len());
    goal_vcol = -1;
    after_move();
}

// left/right on an active selection collapses to its edge
private void sel_collapse(bool to_start) {
    i64 a = 0;
    i64 b = 0;
    ignore ed_sel_range(&a, &b);
    if to_start {
        set_caret_abs(a);
    } else {
        set_caret_abs(b);
    }
    sel_clear();
    undo_break = true;
    goal_vcol = -1;
    after_move();
}

// --- movement --------------------------------------------------------

private void mv_left() {
    if cur_col > 0 {
        i32 n = line_bytes(cur_line);  // fills g_linebuf
        cur_col = grapheme_prev(g_linebuf, n, cast(i32, cur_col));
    } else if cur_line > 0 {
        cur_line--;
        cur_col = line_len(cur_line);
    }
    goal_vcol = -1;
    after_move();
}

private void mv_right() {
    if cur_col < line_len(cur_line) {
        i32 n = line_bytes(cur_line);
        i32 p = cast(i32, cur_col);
        ignore grapheme_next_w(g_linebuf, n, &p);
        cur_col = p;
    } else if cur_line + 1 < tb.nlines {
        cur_line++;
        cur_col = 0;
    }
    goal_vcol = -1;
    after_move();
}

// With wrap, the caret's screen column in its row, which is what a
// vertical move keeps: the goal column counts cells from the row's left
// edge rather than from the line's start.
private i32 wrap_caret_cell() {
    i32 k = ed_row_of_pos(cur_line, cur_col) - ed_row_of_line(cur_line);
    return vcol_of_col(cur_line, cur_col) - ed_row_left_vcol(cur_line, k);
}

// With wrap, the caret to row r, at screen cell `cell` of it or the
// row's last position before that
private void wrap_caret_to_row(i32 r, i32 cell) {
    i32 total = wrap_total();
    if r >= total { r = total - 1; }
    if r < 0 { r = 0; }
    i32 l = clamp_line(wrap_line_of_row(r));
    i32 rows = wrap_line(l);
    i32 k = r - wrap_row_of_line(l);
    if k >= rows { k = rows - 1; }
    i32 v0 = wrap_row_v0(k);
    i32 v = v0 + cell - wrap_row_lead(k);
    if v < v0 { v = v0; }
    i64 c = col_of_vcol(l, v);
    if k + 1 < rows {
        i32 e = wrap_row_start(k + 1);
        if c >= e { c = col_before(l, e); }
    }
    cur_line = l;
    cur_col = c;
}

private void mv_vert(i32 delta) {
    if ed_wrap_on() {
        if goal_vcol < 0 { goal_vcol = wrap_caret_cell(); }
        wrap_caret_to_row(ed_row_of_pos(cur_line, cur_col) + delta, goal_vcol);
        after_move();
        return;
    }
    if goal_vcol < 0 { goal_vcol = vcol_of_col(cur_line, cur_col); }
    cur_line += delta;
    if cur_line < 0 { cur_line = 0; }
    if cur_line >= tb.nlines { cur_line = tb.nlines - 1; }
    cur_col = col_of_vcol(cur_line, goal_vcol);
    after_move();
}

private void mv_page(i32 dir) {
    i32 vis = visible_lines();
    if ed_wrap_on() {
        // a page of rows, the view with it
        if goal_vcol < 0 { goal_vcol = wrap_caret_cell(); }
        wrap_caret_to_row(ed_row_of_pos(cur_line, cur_col) + dir * vis, goal_vcol);
        scroll_set((top_line + dir * vis) * font_line_h);
        after_move();
        return;
    }
    if goal_vcol < 0 { goal_vcol = vcol_of_col(cur_line, cur_col); }
    cur_line += dir * vis;
    if cur_line < 0 { cur_line = 0; }
    if cur_line >= tb.nlines { cur_line = tb.nlines - 1; }
    // page the view by whole lines, dropping any wheel offset
    scroll_set((top_line + dir * vis) * font_line_h);
    cur_col = col_of_vcol(cur_line, goal_vcol);
    after_move();
}

private void caret_to_point(i32 x, i32 y) {
    i32 l = 0;
    i64 c = 0;
    ed_pos_at(x, y, true, &l, &c);
    cur_line = l;
    cur_col = c;
}

// --- word + line ops -------------------------------------------------

private bool is_word_byte(u8 c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_' || c >= 0x80;
}

// the word the caret is in on its line, as byte columns [s, e)
// a line number kept inside the buffer
private i32 clamp_line(i32 l) {
    if l > tb.nlines - 1 { l = tb.nlines - 1; }
    if l < 0 { l = 0; }
    return l;
}

private bool word_bounds(i32* s, i32* e) {
    return word_bounds_at(line_bytes(cur_line), cast(i32, cur_col), s, e);
}

// the run of word bytes around column `col` of the line in g_linebuf,
// n bytes long; false when the column is not in one
private bool word_bounds_at(i32 n, i32 col, i32* s, i32* e) {
    i32 a = col;
    if a > n { a = n; }
    i32 b = a;
    while a > 0 && is_word_byte(g_linebuf[a - 1]) { a--; }
    while b < n && is_word_byte(g_linebuf[b]) { b++; }
    *s = a;
    *e = b;
    return b > a;
}

private bool is_space_byte(u8 c) {
    return c == ' ' || c == '\t';
}

// previous word boundary in the current line; needs cur_col > 0.
// Skips spaces, then one run of word or of punctuation bytes.
private i64 word_left_col() {
    ignore line_bytes(cur_line);  // fills g_linebuf
    i32 p = cast(i32, cur_col);
    while p > 0 && is_space_byte(g_linebuf[p - 1]) { p--; }
    if p > 0 {
        if is_word_byte(g_linebuf[p - 1]) {
            while p > 0 && is_word_byte(g_linebuf[p - 1]) { p--; }
        } else {
            while p > 0 && !is_word_byte(g_linebuf[p - 1]) && !is_space_byte(g_linebuf[p - 1]) { p--; }
        }
    }
    return p;
}

// next word boundary in the current line; needs cur_col < line_len
private i64 word_right_col() {
    i32 n = line_bytes(cur_line);
    i32 p = cast(i32, cur_col);
    while p < n && is_space_byte(g_linebuf[p]) { p++; }
    if p < n {
        if is_word_byte(g_linebuf[p]) {
            while p < n && is_word_byte(g_linebuf[p]) { p++; }
        } else {
            while p < n && !is_word_byte(g_linebuf[p]) && !is_space_byte(g_linebuf[p]) { p++; }
        }
    }
    return p;
}

private void mv_word_left() {
    if cur_col > 0 {
        cur_col = word_left_col();
    } else if cur_line > 0 {
        cur_line--;
        cur_col = line_len(cur_line);
    }
    goal_vcol = -1;
    after_move();
}

private void mv_word_right() {
    if cur_col < line_len(cur_line) {
        cur_col = word_right_col();
    } else if cur_line + 1 < tb.nlines {
        cur_line++;
        cur_col = 0;
    }
    goal_vcol = -1;
    after_move();
}

private void ed_del_word_left() {
    i64 a = 0;
    i64 b = 0;
    if ed_sel_range(&a, &b) {
        ed_replace(a, b - a, null, 0);
        return;
    }
    undo_break = true;
    if cur_col > 0 {
        i64 p = word_left_col();
        ed_replace(tb_line_start(cur_line) + p, cur_col - p, null, 0);
    } else if cur_line > 0 {
        ed_replace(tb_line_start(cur_line) - 1, 1, null, 0);
    }
}

private void ed_del_word_right() {
    i64 a = 0;
    i64 b = 0;
    if ed_sel_range(&a, &b) {
        ed_replace(a, b - a, null, 0);
        return;
    }
    undo_break = true;
    if cur_col < line_len(cur_line) {
        i64 p = word_right_col();
        ed_replace(cur_abs(), p - cur_col, null, 0);
    } else if cur_line + 1 < tb.nlines {
        ed_replace(cur_abs(), 1, null, 0);
    }
}

// selection's line range; a line touched only at column 0 by the
// selection end is excluded, matching the reference editor
private void sel_lines(i32* pa, i32* pb) {
    i64 a = 0;
    i64 b = 0;
    if ed_sel_range(&a, &b) {
        *pa = tb_line_of(a);
        i32 lb = tb_line_of(b);
        if lb > *pa && b == tb_line_start(lb) { lb--; }
        *pb = lb;
    } else {
        *pa = cur_line;
        *pb = cur_line;
    }
}

// end of the whole-line span of line b: past its newline, or the
// buffer end when b is the last line
private i64 span_end(i32 b) {
    if b >= tb.nlines - 1 { return tb_len(); }
    return tb_line_start(b + 1);
}

// swap the selected lines with the line above/below; one undo op
private void ed_move_lines(i32 dir) {
    cur_collapse();
    i32 a = 0;
    i32 b = 0;
    sel_lines(&a, &b);
    if dir < 0 && a == 0 { return; }
    if dir > 0 && b >= tb.nlines - 1 { return; }
    undo_break = true;
    bool had_sel = sel_nonempty();
    i64 anchor = sel_anchor;
    i64 caret = cur_abs();
    i64 shift = 0;
    if dir > 0 {
        i32 c = b + 1;
        i64 rs = tb_line_start(a);
        i64 cs = tb_line_start(c);
        i64 ce = tb_line_end(c);
        i64 re = span_end(c);
        i64 n = re - rs;
        i64 slen = cs - rs;          // moved lines, incl trailing newline
        i64 clen = n - slen;         // line c as stored
        u8* tmp = alloc<u8>(n);
        tb_copy(rs, tmp, n);
        u8* out = alloc<u8>(n);
        memcpy(out, tmp + slen, clen);
        if clen == ce - cs {
            // c was the last line, no newline; it gets one, the span
            // gives one up
            out[clen] = '\n';
            memcpy(out + clen + 1, tmp, slen - 1);
        } else {
            memcpy(out + clen, tmp, slen);
        }
        ed_replace(rs, n, out, cast(i32, n));
        free(tmp);
        free(out);
        shift = ce - cs + 1;
    } else {
        i64 rs = tb_line_start(a - 1);
        i64 re = span_end(b);
        i64 n = re - rs;
        i64 plen = tb_line_start(a) - rs;   // line above, incl newline
        i64 slen = n - plen;
        u8* tmp = alloc<u8>(n);
        tb_copy(rs, tmp, n);
        u8* out = alloc<u8>(n);
        memcpy(out, tmp + plen, slen);
        if b >= tb.nlines - 1 {
            // the span had no trailing newline; same exchange
            out[slen] = '\n';
            memcpy(out + slen + 1, tmp, plen - 1);
        } else {
            memcpy(out + slen, tmp, plen);
        }
        ed_replace(rs, n, out, cast(i32, n));
        free(tmp);
        free(out);
        shift = 0 - plen;
    }
    set_caret_abs(caret + shift);
    if had_sel { sel_set_anchor(anchor + shift); }
    goal_vcol = -1;
    after_move();
}

// duplicate the selected lines; dir > 0 puts the caret on the copy
private void ed_copy_lines(i32 dir) {
    cur_collapse();
    i32 a = 0;
    i32 b = 0;
    sel_lines(&a, &b);
    undo_break = true;
    bool had_sel = sel_nonempty();
    i64 anchor = sel_anchor;
    i64 caret = cur_abs();
    i64 rs = tb_line_start(a);
    i64 re = span_end(b);
    i64 n = re - rs;
    bool nl = b < tb.nlines - 1;
    i64 outn = n;
    if !nl { outn = n + 1; }
    u8* out = alloc<u8>(outn);
    tb_copy(rs, out, n);
    if !nl { out[n] = '\n'; }
    ed_replace(rs, 0, out, cast(i32, outn));
    free(out);
    i64 shift = 0;
    if dir > 0 { shift = outn; }
    set_caret_abs(caret + shift);
    if had_sel { sel_set_anchor(anchor + shift); }
    goal_vcol = -1;
    after_move();
}

private void ed_delete_lines() {
    cur_collapse();
    i32 a = 0;
    i32 b = 0;
    sel_lines(&a, &b);
    undo_break = true;
    i64 rs = tb_line_start(a);
    i64 re = span_end(b);
    if b >= tb.nlines - 1 && a > 0 { rs--; }   // eat the newline before
    if re == rs { return; }
    i64 keep = cur_col;
    ed_replace(rs, re - rs, null, 0);
    i32 l = a;
    if l > tb.nlines - 1 { l = tb.nlines - 1; }
    cur_line = l;
    i64 ll = line_len(l);
    cur_col = keep;
    if cur_col > ll { cur_col = ll; }
    goal_vcol = -1;
    after_move();
}

// comment the selected lines with //, or uncomment when every
// non-blank line already is; one undo op
private void ed_toggle_comment() {
    cur_collapse();
    if !g_lex_on { return; }
    i32 a = 0;
    i32 b = 0;
    sel_lines(&a, &b);
    undo_break = true;
    bool had_sel = sel_nonempty();
    i64 rs = tb_line_start(a);
    i64 re = span_end(b);
    i64 n = re - rs;
    u8* tmp = alloc<u8>(n + 1);
    tb_copy(rs, tmp, n);
    tmp[n] = '\n';   // sentinel: every line now ends with newline

    bool all = true;
    bool any = false;
    i64 min_w = 0;   // smallest indent over non-blank lines; // goes there
    i64 i = 0;
    while i < n {
        i64 s = i;
        while tmp[i] != '\n' { i++; }
        i64 w = s;
        while w < i && is_space_byte(tmp[w]) { w++; }
        if w < i {
            if !any || w - s < min_w { min_w = w - s; }
            any = true;
            if !(w + 1 < i && tmp[w] == '/' && tmp[w + 1] == '/') { all = false; }
        }
        i++;
    }
    if !any {
        free(tmp);
        return;
    }
    bool rem = all;

    u8* out = alloc<u8>(n + cast(i64, b - a + 1) * 3 + 1);
    i64 o = 0;
    i64 cur_delta = 0;
    i32 line = a;
    i = 0;
    while i < n {
        i64 s = i;
        while tmp[i] != '\n' { i++; }
        i64 w = s;
        while w < i && is_space_byte(tmp[w]) { w++; }
        i64 delta = 0;
        i64 at = w - s;   // column the edit happens at, for the caret
        if rem {
            memcpy(out + o, tmp + s, w - s);
            o += w - s;
            i64 t = w;
            if w + 1 < i && tmp[w] == '/' && tmp[w + 1] == '/' {
                t = w + 2;
                if t < i && tmp[t] == ' ' { t++; }
            }
            delta = 0 - (t - w);
            memcpy(out + o, tmp + t, i - t);
            o += i - t;
        } else if w < i {
            // aligned: // sits at the block's minimum indent
            memcpy(out + o, tmp + s, min_w);
            o += min_w;
            out[o] = '/';
            out[o + 1] = '/';
            out[o + 2] = ' ';
            o += 3;
            delta = 3;
            at = min_w;
            memcpy(out + o, tmp + s + min_w, i - s - min_w);
            o += i - s - min_w;
        } else {
            memcpy(out + o, tmp + s, i - s);
            o += i - s;
        }
        if line == cur_line && cur_col >= at { cur_delta = delta; }
        if i < n {
            out[o] = '\n';
            o++;
        }
        i++;
        line++;
    }

    i32 keepl = cur_line;
    i64 keepc = cur_col + cur_delta;
    ed_replace(rs, n, out, cast(i32, o));
    free(tmp);
    free(out);
    if had_sel {
        sel_set_anchor(rs);
        set_caret_abs(rs + o);
    } else {
        cur_line = keepl;
        if keepc < 0 { keepc = 0; }
        i64 ll = line_len(keepl);
        if keepc > ll { keepc = ll; }
        cur_col = keepc;
    }
    goal_vcol = -1;
    after_move();
}

// Tab over a selection that spans lines, and Shift+Tab: every line the
// selection touches (or the caret's line) moves right by an indent of
// TABW spaces, or left by one, as one edit and one undo step. Indenting
// leaves an empty line alone. Outdenting takes a leading tab, or up to
// TABW leading spaces. The selection keeps the text it covered.
private void ed_indent_lines(bool left) {
    cur_collapse();
    i32 a = 0;
    i32 b = 0;
    sel_lines(&a, &b);
    bool had_sel = sel_active;
    i64 anc = sel_anchor;
    i32 anc_l = tb_line_of(anc);
    i64 anc_c = anc - tb_line_start(anc_l);
    i32 car_l = cur_line;
    i64 car_c = cur_col;
    undo_break = true;
    i64 rs = tb_line_start(a);
    i64 n = span_end(b) - rs;
    u8* tmp = alloc<u8>(n + 1);
    tb_copy(rs, tmp, n);
    tmp[n] = '\n';   // sentinel: every line ends with a newline
    u8* out = alloc<u8>(n + cast(i64, b - a + 1) * TABW + 1);
    i64 o = 0;
    i64 i = 0;
    i32 line = a;
    bool changed = false;
    while i < n {
        i64 s = i;
        while tmp[i] != '\n' { i++; }
        // the change at the line's start: added (> 0) or removed (< 0)
        i64 d = 0;
        if !left {
            if i > s {
                for i32 k = 0; k < TABW; k++ { out[o + k] = ' '; }
                o += TABW;
                d = TABW;
            }
        } else if i > s && tmp[s] == '\t' {
            d = -1;
        } else {
            while s - d < i && 0 - d < TABW && tmp[s - d] == ' ' { d--; }
        }
        i64 keep = s;   // the line's first byte that stays
        if d < 0 { keep = s - d; }
        memcpy(out + o, tmp + keep, i - keep);
        o += i - keep;
        if d != 0 { changed = true; }
        if line == anc_l { anc_c = shift_col(anc_c, d); }
        if line == car_l { car_c = shift_col(car_c, d); }
        if i < n {
            out[o] = '\n';
            o++;
        }
        i++;
        line++;
    }
    if changed { ed_replace(rs, n, out, cast(i32, o)); }
    free(tmp);
    free(out);
    if !changed { return; }
    if had_sel {
        sel_set_anchor(tb_line_start(anc_l) + anc_c);
    }
    cur_line = car_l;
    cur_col = car_c;
    goal_vcol = -1;
    after_move();
}

// A column on a line whose start gained (d > 0) or lost (d < 0) d
// bytes. A column at the line's start stays there, so a selection made
// of whole lines still holds their indent.
private i64 shift_col(i64 c, i64 d) {
    if d >= 0 {
        if c == 0 { return 0; }
        return c + d;
    }
    c += d;
    if c < 0 { c = 0; }
    return c;
}

// a selection whose ends are on different lines, which Tab indents
private bool sel_spans_lines() {
    i64 sa = 0;
    i64 sb = 0;
    if !ed_sel_range(&sa, &sb) { return false; }
    return tb_line_of(sa) != tb_line_of(sb);
}

// --- app_* entry points ----------------------------------------------

// the title's project name: the working directory's last component
private void proj_refresh() {
    noinit u8[PATH_MAX] cwd;
    i32 cn = plat_cwd(&cwd[0], PATH_MAX);
    i32 base = path_base_off(&cwd[0], cn);
    i32 pl = cn - base;
    if pl > 256 { pl = 256; }
    g_proj_len = 0;
    if pl > 0 {
        memcpy(&g_proj[0], &cwd[base], pl);
        g_proj_len = pl;
    }
}

// the window title as last set
str ed_title() {
    return str_from(&g_title[0], g_title_len);
}

// re-set the current window's title (the driver calls this when it
// makes a new window current, so it titles that native window)
void ed_retitle() {
    update_title();
}

// --- windows: several native windows over the one shared buffer set --
// The pane layout and the window geometry are per window; g_bufs, the
// language server, git, build and the session stay shared. The live
// globals below hold the current window; another window's state parks
// in g_wins and swaps into the globals on a focus change, the way a
// pane parks in g_panes and swaps through the editing registers. The
// platform selects the window with app_use_window before any app_*.
// With one window (the harness, and until a second is opened) none of
// this runs: g_win stays 0 and the globals are that window.

private struct WinCtx {
    bool used;
    Pane[PANE_MAX] panes;
    i32 npanes;
    i32 pane_active;
    i32 pane_loaded;
    f32[PANE_MAX + 1] pane_div;
    bool bottom;
    f32 bottom_frac;
    i32 col_last;
    i32 div_drag;
    i32 w;
    i32 h;
    i32 dpi;
    bool focused;
    bool tree_on;      // the sidebar is shown per window
    bool tree_focus;
    i32 tree_sel;      // the tree's selection and scroll are per window too
    i32 tree_scroll;
    f32 tree_accum;
}

private WinCtx[WIN_MAX] g_wins;
private i32 g_win = 0;      // the current window; the globals are its state
private i32 g_nwins = 1;
// The window with the keyboard, from the platform's focus report. The
// overlays (the picker, the palette, find, the popups) are one set of
// globals, and every window's frame is built from them; they draw in
// this window only, since it is the one the keys reach.
private i32 g_win_key = 0;

// parsed window records for a session restore (kept out of the frame)
private i32[WIN_MAX] wr_x;
private i32[WIN_MAX] wr_y;
private i32[WIN_MAX] wr_w;
private i32[WIN_MAX] wr_h;
private i32[WIN_MAX] wr_maxi;
private i32[WIN_MAX] wr_active;
private i32[WIN_MAX] wr_treeon;
private i32[WIN_MAX] wr_np;
private i32[WIN_MAX * (PANE_MAX + 1)] wr_div;
private i32[WIN_MAX * PANE_MAX] wp_ord;
private i32[WIN_MAX * PANE_MAX] wp_line;
private i64[WIN_MAX * PANE_MAX] wp_col;
private i32[WIN_MAX * PANE_MAX] wp_scroll;
private i32[WIN_MAX * PANE_MAX] wp_lvcol;
private i32[WIN_MAX * PANE_MAX] wp_term;   // 1: a terminal pane, restored with a fresh shell

i32 ed_window_count() { return g_nwins; }
i32 ed_window_active() { return g_win; }

// true while the current window is the one with the keyboard
bool ed_overlay_here() { return g_win == g_win_key; }

// park the live window-scoped globals into slot i
private void win_save(i32 i) {
    WinCtx* c = &g_wins[i];
    memcpy(&c.panes[0], &g_panes[0], PANE_MAX * sizeof(Pane));
    c.npanes = g_npanes;
    c.pane_active = g_pane_active;
    c.pane_loaded = g_pane_loaded;
    for i32 j = 0; j <= PANE_MAX; j++ { c.pane_div[j] = g_pane_div[j]; }
    c.bottom = g_bottom;
    c.bottom_frac = g_bottom_frac;
    c.col_last = g_col_last;
    c.div_drag = g_div_drag;
    c.w = g_w;
    c.h = g_h;
    c.dpi = g_dpi;
    c.focused = g_focused;
    c.tree_on = tree_on;
    c.tree_focus = tree_focus;
    c.tree_sel = tr_sel;
    c.tree_scroll = tr_scroll;
    c.tree_accum = tr_scroll_accum;
}

// bring slot i into the live globals, and load its active pane's
// editing registers from the shared buffer
private void win_load(i32 i) {
    WinCtx* c = &g_wins[i];
    memcpy(&g_panes[0], &c.panes[0], PANE_MAX * sizeof(Pane));
    g_npanes = c.npanes;
    g_pane_active = c.pane_active;
    g_pane_loaded = c.pane_loaded;
    for i32 j = 0; j <= PANE_MAX; j++ { g_pane_div[j] = c.pane_div[j]; }
    g_bottom = c.bottom;
    g_bottom_frac = c.bottom_frac;
    if g_bottom_frac <= 0.0f { g_bottom_frac = 0.33f; }
    g_col_last = c.col_last;
    g_div_drag = c.div_drag;
    g_w = c.w;
    g_h = c.h;
    g_dpi = c.dpi;
    font_use(zoom_dpi(g_dpi));   // this window's dpi: its own atlas and metrics
    g_focused = c.focused;
    tree_on = c.tree_on;
    tree_focus = c.tree_focus;
    tr_sel = c.tree_sel;
    tr_scroll = c.tree_scroll;
    tr_scroll_accum = c.tree_accum;
    buf_load(g_panes[g_pane_active].buf);
    pane_apply(g_pane_active);
    g_pane_loaded = g_pane_active;
    goal_vcol = -1;
    g_scroll_accum = 0.0f;
}

// the platform calls this before dispatching an event or a frame to a
// window; the core swaps that window's state into the globals
void app_use_window(i32 i) {
    if i < 0 || i >= WIN_MAX || !g_wins[i].used || i == g_win { return; }
    pane_save(g_pane_active);
    buf_store(g_buf_active);
    win_save(g_win);
    g_win = i;
    win_load(i);
}

// open another window showing show_buf, and make it current. Returns
// the new window index, or -1 when the table is full. The platform
// pairs this with a native window; the core shares the buffer set.
i32 ed_window_new(i32 show_buf) {
    i32 nw = -1;
    for i32 i = 0; i < WIN_MAX; i++ {
        if !g_wins[i].used { nw = i; break; }
    }
    if nw < 0 { return -1; }
    if show_buf < 0 || show_buf >= g_nbufs { show_buf = g_buf_active; }
    pane_save(g_pane_active);
    buf_store(g_buf_active);
    win_save(g_win);
    g_nwins++;
    WinCtx* c = &g_wins[nw];
    c.used = true;
    // zeroed, not noinit: every field of a pane record has to be set
    // here, and a kind left on the stack is a pane that is neither a
    // document nor a terminal, which the searches for a document pane
    // then walk straight past
    Pane blank;
    blank.kind = PANE_DOC;
    blank.term = -1;
    blank.buf = show_buf;
    blank.cur_line = 0;
    blank.cur_col = 0;
    blank.scroll_y = 0;
    blank.left_vcol = 0;
    blank.sel_active = false;
    blank.sel_anchor = 0;
    blank.ncur = 0;
    c.panes[0] = blank;
    c.npanes = 1;
    c.pane_active = 0;
    c.pane_loaded = 0;
    c.pane_div[0] = 0.0f;
    for i32 j = 1; j <= PANE_MAX; j++ { c.pane_div[j] = 1.0f; }
    c.bottom = false;
    c.bottom_frac = g_bottom_frac;
    c.col_last = 0;
    c.div_drag = -1;
    c.w = g_w;
    c.h = g_h;
    c.dpi = g_dpi;
    c.focused = true;
    c.tree_on = false;    // secondary windows open without the sidebar
    c.tree_focus = false;
    c.tree_sel = -1;
    c.tree_scroll = 0;
    c.tree_accum = 0.0f;
    g_win = nw;
    win_load(nw);
    update_title();
    return nw;
}

// close the current window; its panes' buffers stay open. False when it
// is the last one (the caller quits instead).
bool ed_window_close() {
    if g_nwins <= 1 { return false; }
    // park the live buffer's registers (git baseline, undo, ...) back into
    // its slot before win_load: buffers outlive the window, and one shown
    // in a surviving window would otherwise lose them (git_attach frees the
    // live state it is replacing). The dying window's WinCtx is discarded.
    buf_store(g_buf_active);
    g_wins[g_win].used = false;
    g_nwins--;
    i32 nw = -1;
    for i32 i = 0; i < WIN_MAX; i++ {
        if g_wins[i].used { nw = i; break; }
    }
    g_win = nw;
    win_load(nw);
    // the keyboard follows the survivor when its window went
    if !g_wins[g_win_key].used { g_win_key = nw; }
    update_title();
    return true;
}

// --- session: per-folder open files and layout, in .edminc/session ---
// A workspace feature, on only when the editor is launched into a folder
// (no file argument). The drivers turn it on after app_init; the harness
// never does, so g_session_on stays false there and nothing is written.
// The file lists the open files with a path and their caret and scroll,
// then the panes referencing those files by ordinal. The active pane's
// state is flushed into the arrays before the write.

private bool g_session_on = false;
private bool g_session_loading = false;   // no save fires while restoring
private u8[PATH_MAX] g_sess_base;
private i32 g_sess_base_len = 0;

private void sess_base_default() {
    if g_sess_base_len > 0 { return; }
    str s = ".edminc";
    memcpy(&g_sess_base[0], s.data, s.len);
    g_sess_base_len = s.len;
}

// test seams (ed_test points the base at build/, and toggles the flag)
void session_set_base(str d) {
    if d.len >= PATH_MAX { return; }
    memcpy(&g_sess_base[0], d.data, d.len);
    g_sess_base_len = d.len;
}
void session_set_enabled(bool on) { g_session_on = on; }
bool session_enabled() { return g_session_on; }

private i32 sess_path(u8* out) {
    sess_base_default();
    memcpy(out, &g_sess_base[0], g_sess_base_len);
    i32 o = g_sess_base_len;
    out[o] = '/';
    o++;
    str s = "session";
    memcpy(out + o, s.data, s.len);
    o += s.len;
    return o;
}

// growable output buffer for the session text
private u8* sess_buf = null;
private i64 sess_len = 0;
private i64 sess_cap = 0;

private void sess_reset() { sess_len = 0; }

private void sess_ensure(i64 extra) {
    if sess_len + extra <= sess_cap { return; }
    i64 ncap = sess_cap * 2 + 4096;
    while ncap < sess_len + extra { ncap = ncap * 2; }
    u8* nb = alloc<u8>(ncap);
    if sess_buf != null {
        memcpy(nb, sess_buf, sess_len);
        free(sess_buf);
    }
    sess_buf = nb;
    sess_cap = ncap;
}

private void sess_putc(u8 c) {
    sess_ensure(1);
    sess_buf[sess_len] = c;
    sess_len++;
}

private void sess_put(str s) {
    sess_ensure(s.len);
    memcpy(sess_buf + sess_len, s.data, s.len);
    sess_len += s.len;
}

private void sess_puti(i64 v) {
    noinit u8[24] tmp;
    i32 n = 0;
    bool neg = v < 0;
    u64 u = neg ? cast(u64, -v) : cast(u64, v);
    if u == 0 { tmp[n] = '0'; n++; }
    while u > 0 {
        tmp[n] = cast(u8, cast(i32, '0') + cast(i32, u % 10));
        n++;
        u = u / 10;
    }
    if neg { sess_putc('-'); }
    for i32 i = n - 1; i >= 0; i-- { sess_putc(tmp[i]); }
}

void app_session_save() {
    if !g_session_on || g_session_loading { return; }
    session_write(false);
}

private i32 sess_handover_path(u8* out) {
    sess_base_default();
    memcpy(out, &g_sess_base[0], g_sess_base_len);
    i32 o = g_sess_base_len;
    str tail = "/handover";
    memcpy(out + o, tail.data, tail.len);
    return o + tail.len;
}

// The session, or the handover a restart leaves for the next process:
// the session's records plus the unsaved text of every dirty buffer and
// every terminal's pty end, child and screen text, so the next build
// takes over where this one stopped.
private void session_write(bool handover) {
    sess_base_default();
    pane_save(g_pane_active);
    buf_store(g_buf_active);
    // buf_store detaches the git state into the slot; re-attach it so the
    // live gutter is not left empty. Without this a later buf_store (a
    // window or buffer switch) would overwrite the slot's baseline with the
    // detached-empty live state, and a file shown in two windows would lose
    // its gutter in both.
    git_attach(&g_bufs[g_buf_active].git);
    win_save(g_win);   // the current window parks so g_wins is all current
    sess_reset();
    sess_put("edminc-session 2\n");
    // the shared buffer set, once
    noinit i32[BUF_MAX] ord;
    for i32 i = 0; i < g_nbufs; i++ { ord[i] = -1; }
    i32 count = 0;
    for i32 i = 0; i < g_nbufs; i++ {
        EdBuffer* b = &g_bufs[i];
        if !b.has_path { continue; }
        ord[i] = count;
        count++;
        sess_put("buf ");
        sess_puti(cast(i64, b.cur_line));
        sess_putc(' ');
        sess_puti(b.cur_col);
        sess_putc(' ');
        sess_puti(cast(i64, b.scroll_y));
        sess_putc(' ');
        sess_put(str_from(&b.path[0], b.path_len));
        sess_putc('\n');
        if b.preview {
            sess_put("preview ");
            sess_puti(cast(i64, ord[i]));
            sess_putc('\n');
        }
    }
    noinit u8[PATH_MAX] fp;
    i32 fpn = sess_path(&fp[0]);
    if handover { fpn = sess_handover_path(&fp[0]); }
    str file = str_from(&fp[0], fpn);
    if count == 0 && !handover {
        if path_exists(file) { ignore file_remove(file); }
        return;
    }
    // the tree's expanded directories, shared across windows, so the tree
    // opens to the same shape on the next launch
    for i32 ti = 0; ti < tree_open_count(); ti++ {
        sess_put("treeopen ");
        sess_put(tree_open_at(ti));
        sess_putc('\n');
    }
    // the sidebar's dragged width, in pixels, when it was dragged: the
    // panes divide what is right of it, so their widths depend on it
    if tree_w_px() > 0 {
        sess_put("sidebar ");
        sess_puti(cast(i64, tree_w_px()));
        sess_putc('\n');
    }
    // the active window as a record ordinal, not a slot index (slots
    // need not be contiguous)
    i32 aw = 0;
    i32 arn = 0;
    for i32 wj = 0; wj < WIN_MAX; wj++ {
        if !g_wins[wj].used { continue; }
        if wj == g_win { aw = arn; }
        arn++;
    }
    sess_put("active-window ");
    sess_puti(cast(i64, aw));
    sess_putc('\n');
    for i32 wi = 0; wi < WIN_MAX; wi++ {
        if !g_wins[wi].used { continue; }
        WinCtx* c = &g_wins[wi];
        i32 rx = 0;
        i32 ry = 0;
        i32 rw = 0;
        i32 rh = 0;
        i32 rmaxi = 0;
        ignore plat_window_rect(wi, &rx, &ry, &rw, &rh, &rmaxi);
        i32 ton = 0;
        if c.tree_on { ton = 1; }
        sess_put("window ");
        sess_puti(cast(i64, rx));
        sess_putc(' ');
        sess_puti(cast(i64, ry));
        sess_putc(' ');
        sess_puti(cast(i64, rw));
        sess_putc(' ');
        sess_puti(cast(i64, rh));
        sess_putc(' ');
        sess_puti(cast(i64, rmaxi));
        sess_putc(' ');
        // the columns: the build's bottom pane is a run, which is not kept
        i32 ncol = c.npanes;
        if c.bottom { ncol--; }
        i32 pact = c.pane_active;
        if pact >= ncol { pact = c.col_last; }
        if pact >= ncol || pact < 0 { pact = 0; }
        sess_puti(cast(i64, pact));
        sess_putc(' ');
        sess_puti(cast(i64, ton));
        sess_putc(' ');
        sess_puti(cast(i64, ncol));
        sess_putc('\n');
        sess_put("div");
        for i32 j = 0; j <= ncol; j++ {
            sess_putc(' ');
            sess_puti(cast(i64, c.pane_div[j] * 10000.0f + 0.5f));
        }
        sess_putc('\n');
        for i32 p = 0; p < ncol; p++ {
            Pane* pane = &c.panes[p];
            i32 o = -1;
            if pane.buf >= 0 && pane.buf < g_nbufs { o = ord[pane.buf]; }
            sess_put("pane ");
            sess_puti(cast(i64, o));
            sess_putc(' ');
            sess_puti(cast(i64, pane.cur_line));
            sess_putc(' ');
            sess_puti(pane.cur_col);
            sess_putc(' ');
            sess_puti(cast(i64, pane.scroll_y));
            sess_putc(' ');
            sess_puti(cast(i64, pane.left_vcol));
            sess_putc('\n');
            // a terminal pane, so the layout comes back with a shell in
            // it; the build's is a run, which is not kept. A line of its
            // own after the pane, which an older reader passes over.
            if pane.kind == PANE_TERM && pane.term != build_term() { sess_put("term\n"); }
        }
    }
    if handover {
        // the unsaved text of every dirty buffer, by its record ordinal
        i32 act = g_buf_active;
        for i32 i = 0; i < g_nbufs; i++ {
            if ord[i] < 0 || !g_bufs[i].tb.dirty { continue; }
            buf_load(i);
            i64 tn = tb_len();
            sess_put("htext ");
            sess_puti(cast(i64, ord[i]));
            sess_putc(' ');
            sess_puti(tn);
            sess_putc('\n');
            sess_ensure(tn + 1);
            tb_copy(0, sess_buf + sess_len, tn);
            sess_len += tn;
            sess_putc('\n');
        }
        buf_load(act);
        // every terminal with a child: its pty end and child, where it
        // shows (a window ordinal and pane, or -1 -1 in the background),
        // its size and cursor, then its lines from the oldest held
        for i32 t = 0; t < TERM_MAX; t++ {
            if !term_has_child(t) || t == build_term() { continue; }
            // A pty the platform cannot pass on (Windows hands no
            // ConPTY over) still leaves its text behind: the record
            // carries no handle, and the pane comes back with a new
            // shell under what the old one had said.
            i64 tfd = -1;
            i32 tpid = 0;
            ignore term_export(t, &tfd, &tpid);
            i32 twin = -1;
            i32 tpane = -1;
            i32 wo = 0;
            for i32 wi = 0; wi < WIN_MAX; wi++ {
                if !g_wins[wi].used { continue; }
                for i32 p = 0; p < g_wins[wi].npanes; p++ {
                    if g_wins[wi].panes[p].kind == PANE_TERM && g_wins[wi].panes[p].term == t {
                        twin = wo;
                        tpane = p;
                    }
                }
                wo++;
            }
            i64 first = term_abs_first(t);
            i64 end = term_abs_end(t);
            // trailing blank lines are not content
            noinit u8[8192] lb;
            i64 last = first - 1;
            for i64 l = first; l < end; l++ {
                if term_abs_text(t, l, 0, term_cols(t), &lb[0], 8192) > 0 { last = l; }
            }
            sess_put("hterm ");
            sess_puti(tfd);
            sess_putc(' ');
            sess_puti(cast(i64, tpid));
            sess_putc(' ');
            sess_puti(cast(i64, twin));
            sess_putc(' ');
            sess_puti(cast(i64, tpane));
            sess_putc(' ');
            sess_puti(cast(i64, term_cols(t)));
            sess_putc(' ');
            sess_puti(cast(i64, term_rows(t)));
            sess_putc(' ');
            sess_puti(cast(i64, term_cx(t)));
            sess_putc(' ');
            sess_puti(cast(i64, term_cy(t)));
            sess_putc(' ');
            sess_puti(last - first + 1);
            sess_putc('\n');
            for i64 l = first; l <= last; l++ {
                i32 ln = term_abs_text(t, l, 0, term_cols(t), &lb[0], 8192);
                sess_put(str_from(&lb[0], ln));
                sess_putc('\n');
            }
        }
    }
    ignore dir_create(str_from(&g_sess_base[0], g_sess_base_len));
    FileData fd = FileData{ sess_buf, sess_len };
    ignore file_write(file, fd);
}

// the handover file, for the harness's round trip
void app_handover_write() {
    session_write(true);
}

private bool sess_line_is(u8* d, i64 ls, i64 le, str pre) {
    if le - ls < pre.len { return false; }
    for i32 k = 0; k < pre.len; k++ {
        if d[ls + k] != pre.data[k] { return false; }
    }
    return true;
}

// parse an i64 from *ip up to le, skipping leading spaces
// a saved window smaller than this is not restored to its rect
private const i32 SESS_WIN_MIN_W = 320;
private const i32 SESS_WIN_MIN_H = 200;

private i64 sess_geti(u8* d, i64 le, i64* ip) {
    i64 i = *ip;
    while i < le && d[i] == ' ' { i++; }
    bool neg = false;
    if i < le && d[i] == '-' { neg = true; i++; }
    i64 v = 0;
    while i < le && d[i] >= '0' && d[i] <= '9' {
        v = v * 10 + cast(i64, cast(i32, d[i]) - cast(i32, '0'));
        i++;
    }
    *ip = i;
    if neg { return -v; }
    return v;
}

private bool session_load() {
    sess_base_default();
    noinit u8[PATH_MAX] fp;
    i32 fpn = sess_path(&fp[0]);
    str file = str_from(&fp[0], fpn);
    if !path_exists(file) { return false; }
    FileData fd = file_read(file);
    if fd.data == null { return false; }
    u8* d = fd.data;
    i64 n = fd.len;
    i64 vl = 0;
    while vl < n && d[vl] != 10 { vl++; }
    bool ok = false;
    if sess_line_is(d, 0, vl, "edminc-session 2") {
        ok = session_load_v2(d, n, false);
    } else {
        ok = session_load_v1(d, n);
    }
    free(d);
    return ok;
}

// The next process, started by a restart: the handover in place of the
// session, then the file goes. The session is on from here as it is on
// a folder launch.
bool app_handover_restore(str path) {
    settings_load();
    sess_base_default();
    g_session_on = true;
    if !path_exists(path) { return session_load(); }
    FileData fd = file_read(path);
    ignore file_remove(path);
    if fd.data == null { return false; }
    bool ok = false;
    i64 vl = 0;
    while vl < fd.len && fd.data[vl] != 10 { vl++; }
    if sess_line_is(fd.data, 0, vl, "edminc-session 2") { ok = session_load_v2(fd.data, fd.len, true); }
    free(fd.data);
    return ok;
}

private bool session_load_v1(u8* d, i64 n) {
    i32 active = 0;
    i32 npanes = 1;
    noinit i32[PANE_MAX + 1] pdiv;
    i32 ndiv = 0;
    noinit i32[BUF_MAX] be_line;
    noinit i64[BUF_MAX] be_col;
    noinit i32[BUF_MAX] be_scroll;
    noinit i64[BUF_MAX] be_poff;
    noinit i32[BUF_MAX] be_plen;
    i32 nbe = 0;
    noinit i32[PANE_MAX] pe_ord;
    noinit i32[PANE_MAX] pe_line;
    noinit i64[PANE_MAX] pe_col;
    noinit i32[PANE_MAX] pe_scroll;
    noinit i32[PANE_MAX] pe_lvcol;
    i32 npe = 0;

    i64 i = 0;
    while i < n {
        i64 ls = i;
        while i < n && d[i] != 10 { i++; }
        i64 le = i;
        if i < n { i++; }
        i64 c = ls;
        if sess_line_is(d, ls, le, "buf ") {
            c = ls + 4;
            i32 cl = cast(i32, sess_geti(d, le, &c));
            i64 cc = sess_geti(d, le, &c);
            i32 sy = cast(i32, sess_geti(d, le, &c));
            if c < le && d[c] == ' ' { c++; }
            if nbe < BUF_MAX {
                be_line[nbe] = cl;
                be_col[nbe] = cc;
                be_scroll[nbe] = sy;
                be_poff[nbe] = c;
                be_plen[nbe] = cast(i32, le - c);
                nbe++;
            }
        } else if sess_line_is(d, ls, le, "pane ") {
            c = ls + 5;
            i32 po = cast(i32, sess_geti(d, le, &c));
            i32 pl = cast(i32, sess_geti(d, le, &c));
            i64 pc = sess_geti(d, le, &c);
            i32 ps = cast(i32, sess_geti(d, le, &c));
            i32 lv = cast(i32, sess_geti(d, le, &c));
            if npe < PANE_MAX {
                pe_ord[npe] = po;
                pe_line[npe] = pl;
                pe_col[npe] = pc;
                pe_scroll[npe] = ps;
                pe_lvcol[npe] = lv;
                npe++;
            }
        } else if sess_line_is(d, ls, le, "active ") {
            c = ls + 7;
            active = cast(i32, sess_geti(d, le, &c));
        } else if sess_line_is(d, ls, le, "panes ") {
            c = ls + 6;
            npanes = cast(i32, sess_geti(d, le, &c));
        } else if sess_line_is(d, ls, le, "div") {
            c = ls + 3;
            while c < le && ndiv <= PANE_MAX {
                while c < le && d[c] == ' ' { c++; }
                if c >= le { break; }
                pdiv[ndiv] = cast(i32, sess_geti(d, le, &c));
                ndiv++;
            }
        }
    }

    if nbe == 0 { return false; }

    g_session_loading = true;
    noinit i32[BUF_MAX] slot_of;
    for i32 k = 0; k < nbe; k++ {
        slot_of[k] = -1;
        str path = str_from(d + be_poff[k], be_plen[k]);
        if path.len == 0 || path.len >= PATH_MAX { continue; }
        if !path_exists(path) || path_is_dir(path) { continue; }
        if !ed_open_file(path) { continue; }
        i32 sl = g_buf_active;
        i32 cl = be_line[k];
        cl = clamp_line(cl);
        cur_line = cl;
        cur_col = col_snap(cl, be_col[k]);
        goal_vcol = -1;
        left_vcol = 0;
        scroll_set(be_scroll[k]);
        buf_store(sl);
        slot_of[k] = sl;
    }
    i32 opened = 0;
    i32 fallback = -1;
    for i32 k = 0; k < nbe; k++ {
        if slot_of[k] >= 0 {
            opened++;
            if fallback < 0 { fallback = slot_of[k]; }
        }
    }
    if opened == 0 {
        g_session_loading = false;
        return false;
    }

    if npanes < 1 { npanes = 1; }
    if npanes > COL_MAX { npanes = COL_MAX; }
    if ndiv == npanes + 1 {
        for i32 j = 0; j <= npanes; j++ { g_pane_div[j] = cast(f32, pdiv[j]) / 10000.0f; }
    } else {
        for i32 j = 0; j <= npanes; j++ { g_pane_div[j] = cast(f32, j) / cast(f32, npanes); }
    }
    for i32 j = npanes + 1; j <= PANE_MAX; j++ { g_pane_div[j] = 1.0f; }
    g_npanes = npanes;
    g_bottom = false;   // the columns come back; the build's pane is a run
    for i32 p = 0; p < npanes; p++ {
        i32 sl = fallback;
        if p < npe {
            i32 po = pe_ord[p];
            if po >= 0 && po < nbe && slot_of[po] >= 0 { sl = slot_of[po]; }
        }
        if sl < 0 { sl = 0; }
        g_panes[p].buf = sl;
        g_panes[p].sel_active = false;
        g_panes[p].sel_anchor = 0;
        g_panes[p].ncur = 0;
        if p < npe {
            g_panes[p].cur_line = pe_line[p];
            g_panes[p].cur_col = pe_col[p];
            g_panes[p].scroll_y = pe_scroll[p];
            g_panes[p].left_vcol = pe_lvcol[p];
        } else {
            g_panes[p].cur_line = 0;
            g_panes[p].cur_col = 0;
            g_panes[p].scroll_y = 0;
            g_panes[p].left_vcol = 0;
        }
    }
    if active < 0 { active = 0; }
    if active >= npanes { active = npanes - 1; }
    g_pane_active = active;
    buf_load(g_panes[active].buf);
    pane_apply(active);
    g_pane_loaded = active;
    g_session_loading = false;
    goal_vcol = -1;
    ensure_visible();
    update_title();
    reset_blink();
    ed_lsp_sync();
    plat_damage();
    return true;
}

// A terminal on screen somewhere: in this window's panes, or in the
// parked panes of another. One that no pane shows draws nothing, so
// its output is no reason to ask for a frame.
private bool term_is_shown(i32 t) {
    if t < 0 { return false; }
    if ed_pane_of_term(t) >= 0 { return true; }
    for i32 w = 0; w < WIN_MAX; w++ {
        if w == g_win || !g_wins[w].used { continue; }
        for i32 p = 0; p < g_wins[w].npanes; p++ {
            if g_wins[w].panes[p].kind == PANE_TERM
                && g_wins[w].panes[p].term == t { return true; }
        }
    }
    return false;
}

// a handover's terminal records
private i64[TERM_MAX] ht_fd;
private i32[TERM_MAX] ht_pid;
private i32[TERM_MAX] ht_win;
private i32[TERM_MAX] ht_pane;
private i32[TERM_MAX] ht_cols;
private i32[TERM_MAX] ht_rows;
private i32[TERM_MAX] ht_cx;
private i32[TERM_MAX] ht_cy;
private i64[TERM_MAX] ht_off;     // the first of its lines
private i32[TERM_MAX] ht_nlines;
private bool[TERM_MAX] ht_taken;

// Feed a terminal what it had on it, its scrollback included, as text.
// One that was handed over gets its cursor put back where it was; one
// that could not be (Windows passes no pty on) is a new shell under the
// same text, and its cursor goes to a fresh line instead, so the first
// prompt prints under the history rather than over the last line of it.
private void handover_feed(i32 t, u8* d, i64 n, i32 k, bool adopted) {
    i64 i = ht_off[k];
    for i32 l = 0; l < ht_nlines[k] && i < n; l++ {
        i64 ls = i;
        while i < n && d[i] != 10 { i++; }
        term_feed(t, d + ls, i - ls);
        if i < n { i++; }
        if l + 1 < ht_nlines[k] {
            noinit u8[2] crlf;
            crlf[0] = 13;
            crlf[1] = 10;
            term_feed(t, &crlf[0], 2);
        }
    }
    if !adopted {
        noinit u8[2] nl;
        nl[0] = 13;
        nl[1] = 10;
        term_feed(t, &nl[0], 2);
        return;
    }
    noinit u8[32] cup;
    i32 o = 0;
    cup[o] = 27; o++;
    cup[o] = '['; o++;
    o += fmt_i32(&cup[o], ht_cy[k] + 1);
    cup[o] = ';'; o++;
    o += fmt_i32(&cup[o], ht_cx[k] + 1);
    cup[o] = 'H'; o++;
    term_feed(t, &cup[0], cast(i64, o));
}

// the multi-window format: a shared buffer list, then a block per window
// with its native rect, sidebar, active pane and panes. On a driver that
// cannot make windows (linux and the browser) the extra windows are
// skipped and only the first is restored.
private bool session_load_v2(u8* d, i64 n, bool handover) {
    noinit i32[BUF_MAX] be_line;
    noinit i64[BUF_MAX] be_col;
    noinit i32[BUF_MAX] be_scroll;
    noinit i64[BUF_MAX] be_poff;
    noinit i32[BUF_MAX] be_plen;
    noinit bool[BUF_MAX] be_prev;   // a "preview" line names its record
    for i32 k = 0; k < BUF_MAX; k++ { be_prev[k] = false; }
    i32 nbe = 0;
    i32 active_window = 0;
    i32 nwr = 0;
    i32 cw = -1;
    i32 cwp = 0;
    noinit i64[128] to_off;   // the tree's saved expanded directories
    noinit i32[128] to_len;
    i32 nto = 0;
    i32 sidebar_px = 0;
    noinit i64[BUF_MAX] hx_off;   // a handover's unsaved texts, by record ordinal
    noinit i64[BUF_MAX] hx_len;
    for i32 k = 0; k < BUF_MAX; k++ { hx_len[k] = -1; }
    i32 nht = 0;
    i64 i = 0;
    while i < n {
        i64 ls = i;
        while i < n && d[i] != 10 { i++; }
        i64 le = i;
        if i < n { i++; }
        i64 c = ls;
        if handover && sess_line_is(d, ls, le, "htext ") {
            c = ls + 6;
            i32 o = cast(i32, sess_geti(d, le, &c));
            i64 tn = sess_geti(d, le, &c);
            if o >= 0 && o < BUF_MAX && tn >= 0 && i + tn <= n {
                hx_off[o] = i;
                hx_len[o] = tn;
            }
            i += tn + 1;   // the bytes and the newline after them
        } else if handover && sess_line_is(d, ls, le, "hterm ") {
            c = ls + 6;
            i64 tfd = sess_geti(d, le, &c);
            i32 tpid = cast(i32, sess_geti(d, le, &c));
            i32 twin = cast(i32, sess_geti(d, le, &c));
            i32 tpane = cast(i32, sess_geti(d, le, &c));
            i32 tcols = cast(i32, sess_geti(d, le, &c));
            i32 trows = cast(i32, sess_geti(d, le, &c));
            i32 tcx = cast(i32, sess_geti(d, le, &c));
            i32 tcy = cast(i32, sess_geti(d, le, &c));
            i32 tl = cast(i32, sess_geti(d, le, &c));
            if nht < TERM_MAX {
                ht_fd[nht] = tfd;
                ht_pid[nht] = tpid;
                ht_win[nht] = twin;
                ht_pane[nht] = tpane;
                ht_cols[nht] = tcols;
                ht_rows[nht] = trows;
                ht_cx[nht] = tcx;
                ht_cy[nht] = tcy;
                ht_off[nht] = i;
                ht_nlines[nht] = tl;
                ht_taken[nht] = false;
                nht++;
            }
            for i32 l = 0; l < tl && i < n; l++ {
                while i < n && d[i] != 10 { i++; }
                if i < n { i++; }
            }
        } else if sess_line_is(d, ls, le, "buf ") {
            c = ls + 4;
            i32 cl = cast(i32, sess_geti(d, le, &c));
            i64 cc = sess_geti(d, le, &c);
            i32 sy = cast(i32, sess_geti(d, le, &c));
            if c < le && d[c] == ' ' { c++; }
            if nbe < BUF_MAX {
                be_line[nbe] = cl;
                be_col[nbe] = cc;
                be_scroll[nbe] = sy;
                be_poff[nbe] = c;
                be_plen[nbe] = cast(i32, le - c);
                nbe++;
            }
        } else if sess_line_is(d, ls, le, "preview ") {
            c = ls + 8;
            i64 k = sess_geti(d, le, &c);
            if k >= 0 && k < BUF_MAX { be_prev[k] = true; }
        } else if sess_line_is(d, ls, le, "active-window ") {
            c = ls + 14;
            active_window = cast(i32, sess_geti(d, le, &c));
        } else if sess_line_is(d, ls, le, "window ") {
            if nwr < WIN_MAX {
                c = ls + 7;
                wr_x[nwr] = cast(i32, sess_geti(d, le, &c));
                wr_y[nwr] = cast(i32, sess_geti(d, le, &c));
                wr_w[nwr] = cast(i32, sess_geti(d, le, &c));
                wr_h[nwr] = cast(i32, sess_geti(d, le, &c));
                wr_maxi[nwr] = cast(i32, sess_geti(d, le, &c));
                wr_active[nwr] = cast(i32, sess_geti(d, le, &c));
                wr_treeon[nwr] = cast(i32, sess_geti(d, le, &c));
                wr_np[nwr] = cast(i32, sess_geti(d, le, &c));
                for i32 j = 0; j <= PANE_MAX; j++ { wr_div[nwr * (PANE_MAX + 1) + j] = 0; }
                cw = nwr;
                cwp = 0;
                nwr++;
            } else {
                cw = -1;
            }
        } else if sess_line_is(d, ls, le, "div") {
            if cw >= 0 {
                c = ls + 3;
                i32 j = 0;
                while c < le && j <= PANE_MAX {
                    while c < le && d[c] == ' ' { c++; }
                    if c >= le { break; }
                    wr_div[cw * (PANE_MAX + 1) + j] = cast(i32, sess_geti(d, le, &c));
                    j++;
                }
            }
        } else if sess_line_is(d, ls, le, "pane ") {
            if cw >= 0 && cwp < PANE_MAX {
                c = ls + 5;
                i32 idx = cw * PANE_MAX + cwp;
                wp_ord[idx] = cast(i32, sess_geti(d, le, &c));
                wp_line[idx] = cast(i32, sess_geti(d, le, &c));
                wp_col[idx] = sess_geti(d, le, &c);
                wp_scroll[idx] = cast(i32, sess_geti(d, le, &c));
                wp_lvcol[idx] = cast(i32, sess_geti(d, le, &c));
                wp_term[idx] = 0;
                cwp++;
            }
        } else if sess_line_is(d, ls, le, "term") {
            if cw >= 0 && cwp > 0 { wp_term[cw * PANE_MAX + cwp - 1] = 1; }
        } else if sess_line_is(d, ls, le, "sidebar ") {
            c = ls + 8;
            sidebar_px = cast(i32, sess_geti(d, le, &c));
        } else if sess_line_is(d, ls, le, "treeopen ") {
            if nto < 128 {
                i64 tp = ls + 9;
                to_off[nto] = tp;
                to_len[nto] = cast(i32, le - tp);
                nto++;
            }
        }
    }
    // a handover carries terminals whether or not a file is open, so
    // a folder with nothing but a shell in it still comes back
    if nwr == 0 || (nbe == 0 && nht == 0) { return false; }

    g_session_loading = true;
    noinit i32[BUF_MAX] slot_of;
    for i32 k = 0; k < nbe; k++ {
        slot_of[k] = -1;
        str path = str_from(d + be_poff[k], be_plen[k]);
        if path.len == 0 || path.len >= PATH_MAX { continue; }
        if !path_exists(path) || path_is_dir(path) { continue; }
        if !ed_open_file(path) { continue; }
        i32 sl = g_buf_active;
        g_preview = be_prev[k];
        if handover && hx_len[k] >= 0 {
            // the unsaved text takes the file's place; the undo history
            // does not cross a restart
            tb_delete(0, tb_len());
            if hx_len[k] > 0 { tb_insert(0, d + hx_off[k], cast(i32, hx_len[k])); }
            undo_clear();
            tb.dirty = true;
            g_preview = false;
        }
        i32 cl = be_line[k];
        cl = clamp_line(cl);
        cur_line = cl;
        cur_col = col_snap(cl, be_col[k]);
        goal_vcol = -1;
        left_vcol = 0;
        scroll_set(be_scroll[k]);
        buf_store(sl);
        slot_of[k] = sl;
    }
    i32 opened = 0;
    i32 fallback = -1;
    for i32 k = 0; k < nbe; k++ {
        if slot_of[k] >= 0 {
            opened++;
            if fallback < 0 { fallback = slot_of[k]; }
        }
    }
    if opened == 0 && nht == 0 {
        g_session_loading = false;
        return false;
    }
    if opened == 0 {
        // nothing named a file, so the panes fall back to the buffer
        // that is live. Its slot is stale until it is stored: the live
        // globals are the truth between a store and a load, and loading
        // the slot over them would install a freed buffer.
        fallback = g_buf_active;
        buf_store(fallback);
    }

    noinit i32[WIN_MAX] made;
    for i32 wr = 0; wr < nwr; wr++ {
        made[wr] = -1;
        i32 target = -1;
        // a rect too small to use, such as a minimized window's, gives
        // the launch default: the first window maximized, another at
        // the default place and size
        bool usable = wr_w[wr] >= SESS_WIN_MIN_W && wr_h[wr] >= SESS_WIN_MIN_H;
        if wr == 0 {
            target = g_win;
            if usable {
                plat_window_set_rect(target, wr_x[0], wr_y[0], wr_w[0], wr_h[0], wr_maxi[0]);
            } else {
                plat_window_set_rect(target, 0, 0, 0, 0, 1);
            }
        } else if usable {
            target = plat_window_open_at(wr_x[wr], wr_y[wr], wr_w[wr], wr_h[wr], wr_maxi[wr]);
            if target < 0 { continue; }
        } else {
            target = plat_window_open();
            if target < 0 { continue; }
        }
        made[wr] = target;
        if g_win != target { app_use_window(target); }
        i32 np = wr_np[wr];
        if np < 1 { np = 1; }
        if np > COL_MAX { np = COL_MAX; }
        bool even = wr_div[wr * (PANE_MAX + 1) + np] == 0;
        for i32 j = 0; j <= np; j++ {
            if even { g_pane_div[j] = cast(f32, j) / cast(f32, np); }
            else { g_pane_div[j] = cast(f32, wr_div[wr * (PANE_MAX + 1) + j]) / 10000.0f; }
        }
        for i32 j = np + 1; j <= PANE_MAX; j++ { g_pane_div[j] = 1.0f; }
        g_npanes = np;
        g_bottom = false;   // the columns come back; the build's pane is a run
        for i32 pp = 0; pp < np; pp++ {
            i32 idx = wr * PANE_MAX + pp;
            i32 sl = fallback;
            i32 po = wp_ord[idx];
            if po >= 0 && po < nbe && slot_of[po] >= 0 { sl = slot_of[po]; }
            if sl < 0 { sl = 0; }
            g_panes[pp].buf = sl;
            g_panes[pp].sel_active = false;
            g_panes[pp].sel_anchor = 0;
            g_panes[pp].ncur = 0;
            g_panes[pp].cur_line = wp_line[idx];
            g_panes[pp].cur_col = wp_col[idx];
            g_panes[pp].scroll_y = wp_scroll[idx];
            g_panes[pp].left_vcol = wp_lvcol[idx];
            pane_set_doc(pp);
            if wp_term[idx] != 0 {
                // a handed-over terminal when there is one for this pane,
                // else a fresh shell; the grid is refit from the first
                // frame, and a pane the platform can start no shell for
                // shows its document instead
                i32 tt = -1;
                i32 hk = -1;
                if handover {
                    for i32 k = 0; k < nht && hk < 0; k++ {
                        if ht_taken[k] || ht_win[k] != wr || ht_pane[k] != pp { continue; }
                        ht_taken[k] = true;
                        hk = k;
                        if ht_fd[k] >= 0 {
                            tt = term_adopt(ht_fd[k], ht_pid[k], ht_cols[k], ht_rows[k]);
                        }
                        if tt >= 0 {
                            handover_feed(tt, d, n, k, true);
                            term_nudge(tt);
                        }
                    }
                }
                if tt < 0 {
                    i32 tc = 0;
                    i32 tr = 0;
                    term_pane_cells(pp, &tc, &tr);
                    // no pty came across, so a new shell stands in it
                    // with what the old one said still above the prompt.
                    // It is opened under that text, and the text is in
                    // before the host asks where the cursor is.
                    if hk >= 0 { tt = term_open_under(tc, tr); }
                    else { tt = term_open(tc, tr); }
                    if tt >= 0 && hk >= 0 { handover_feed(tt, d, n, hk, false); }
                }
                if tt >= 0 {
                    g_panes[pp].kind = PANE_TERM;
                    g_panes[pp].term = tt;
                }
            }
        }
        i32 pa = wr_active[wr];
        if pa < 0 { pa = 0; }
        if pa >= np { pa = np - 1; }
        g_pane_active = pa;
        tree_on = wr_treeon[wr] != 0;
        tree_focus = false;
        buf_load(g_panes[pa].buf);
        pane_apply(pa);
        g_pane_loaded = pa;
    }
    g_session_loading = false;
    if active_window >= 0 && active_window < nwr && made[active_window] >= 0 {
        app_use_window(made[active_window]);
    }
    // the handed-over terminals no pane showed, and any a pane could not
    // take: they come back in the background
    if handover {
        for i32 k = 0; k < nht; k++ {
            if ht_taken[k] { continue; }
            ht_taken[k] = true;
            i32 tt = -1;
            if ht_fd[k] >= 0 { tt = term_adopt(ht_fd[k], ht_pid[k], ht_cols[k], ht_rows[k]); }
            if tt >= 0 {
                handover_feed(tt, d, n, k, true);
                term_nudge(tt);
            } else {
                // no pty came across, so this one is a new shell too,
                // under the text it had: the switcher lists it where it
                // was, with what it said still on it
                tt = term_open_under(ht_cols[k], ht_rows[k]);
                if tt >= 0 { handover_feed(tt, d, n, k, false); }
            }
        }
    }
    if sidebar_px > 0 { tree_set_w(sidebar_px); }
    // restore the tree's expanded directories and rebuild it to that shape
    if nto > 0 {
        tree_open_clear();
        for i32 k = 0; k < nto; k++ {
            tree_open_add_path(str_from(d + to_off[k], to_len[k]));
        }
        tree_build();
    }
    goal_vcol = -1;
    ensure_visible();
    update_title();
    reset_blink();
    ed_lsp_sync();
    plat_damage();
    return true;
}

// --- the restart: the next build takes over --------------------------
// Ctrl+K X, or `edmc --restart` typed into a terminal pane, replaces
// this process with the executable named (this one's own path from the
// chord: the build has rewritten it) after writing the handover: the
// session's records, every dirty buffer's text, and every terminal's
// pty end, child and screen. The terminals' children never notice; the
// build pane's run does not come along, and neither does the undo
// history.

bool ed_restart(str exe) {
    if exe.len == 0 || !path_exists(exe) {
        ed_warn("restart: no executable to restart into");
        plat_damage();
        return false;
    }
    app_session_save();   // the plain session too, should the new build not come up
    lsp_stop();
    i32 bt = build_term();
    if bt >= 0 {
        i32 bp = ed_build_pane();
        if bp >= 0 {
            pane_set_doc(bp);
        }
        build_pane_closed();
        ed_term_close(bt);
    }
    session_write(true);
    noinit u8[PATH_MAX] cwd;
    i32 cn = plat_cwd(&cwd[0], PATH_MAX);
    noinit u8[PATH_MAX] hp;
    i32 hn = sess_handover_path(&hp[0]);
    noinit str[3] argv;
    argv[0] = str_from(&cwd[0], cn);
    argv[1] = "--handover";
    argv[2] = str_from(&hp[0], hn);
    i32 argc = 3;
    if cn == 0 {
        argv[0] = "--handover";
        argv[1] = str_from(&hp[0], hn);
        argc = 2;
    }
    if !plat_exec_self(exe, &argv[0], argc) {
        ignore file_remove(str_from(&hp[0], hn));
        ed_warn("restart: the new process could not be started");
        plat_damage();
        return false;
    }
    return true;
}

// Ctrl+K X: into this executable's path, which the build has rewritten
void ed_restart_self() {
    noinit u8[PATH_MAX] ep;
    i32 en = plat_exe_path(&ep[0], PATH_MAX);
    ignore ed_restart(str_from(&ep[0], en));
}

// a request left by `edmc --restart` in a terminal pane: the file names
// the executable; read on a wake, which its prompt's return is
private void restart_poll() {
    str req = ".edminc/restart";
    if !path_exists(req) { return; }
    FileData fd = file_read(req);
    ignore file_remove(req);
    if fd.data == null { return; }
    i64 n = fd.len;
    while n > 0 && (fd.data[n - 1] == 10 || fd.data[n - 1] == 13 || fd.data[n - 1] == ' ') { n--; }
    noinit u8[PATH_MAX] ep;
    i32 en = cast(i32, n);
    if en >= PATH_MAX { en = PATH_MAX - 1; }
    memcpy(&ep[0], fd.data, en);
    free(fd.data);
    ignore ed_restart(str_from(&ep[0], en));
}

// the drivers call this once after app_init, on the interactive path,
// and so it is where the user's settings are read as well.
// A file argument means the user asked for that file, not the workspace,
// so the session is left untouched then. A launch that names no folder
// opens the most recent one (recent.mc). A folder with no session opens
// its README.md, as the web page does. True only when the session placed
// the windows.
bool app_session_restore() {
    // the user's settings apply to a file argument as to a folder
    settings_load();
    if g_has_path { return false; }
    // before the session is on, so the folder left behind gets no session
    if recent_launch() { g_status_len = 0; }
    recent_note();
    sess_base_default();
    g_session_on = true;
    if session_load() { return true; }
    str readme = "README.md";
    if path_exists(readme) && !path_is_dir(readme) { ignore ed_open_file(readme); }
    return false;
}

void app_init(str path, i32 dpi) {
    g_pane_div[0] = 0.0f;
    g_pane_div[1] = 1.0f;
    term_palette_init();
    proj_refresh();
    g_dpi = dpi;
    string capv = env_get("EDMINC_BUFFERS");
    if capv.len > 0 {
        i32 cap = 0;
        for i32 i = 0; i < capv.len; i++ {
            if capv.data[i] < '0' || capv.data[i] > '9' { break; }
            cap = cap * 10 + cast(i32, capv.data[i] - '0');
        }
        if cap > 0 { ed_buf_cap_set(cap); }
    }
    free(capv);
    g_linebuf = alloc<u8>(LINEBUF_CAP + 8);
    g_clsbuf = alloc<u8>(LINEBUF_CAP + 8);
    if path.len > 0 && path.len < PATH_MAX {
        memcpy(&g_path[0], path.data, path.len);
        g_path_len = path.len;
        g_has_path = true;
        lex_set_for(path);
        ed_lsp_sync();
    }
    if g_has_path && image_path(str_from(&g_path[0], g_path_len)) {
        // an image named on the command line: pixels, no text
        tb_init_empty();
        g_lex_on = false;
        g_img = image_open(str_from(&g_path[0], g_path_len));
    } else if g_has_path {
        // the file named on the command line is loaded here rather
        // than through ed_open_file, so the baseline is fetched here too
        if !tb_load(str_from(&g_path[0], g_path_len)) {
            print("edminc: new file {}\n", str_from(&g_path[0], g_path_len));
        }
        git_reload(str_from(&g_path[0], g_path_len));
    } else {
        tb_init_empty();
    }
    g_wins[0].used = true;   // the initial window occupies slot 0
    update_title();
    if tree_on { tree_build(); }
    git_status_touch();
    watch_start();
}

// an overlay input owns typing while any of these are open
bool overlay_active() {
    return find_on || pick_on || ask_on || sym_on || switcher_on || palette_on || explode_on || calls_on || menu_on;
}

// center the caret's line unless it already sits in the middle
// third of the viewport; a hit at the viewport edge is easy to miss
void ed_center_caret() {
    i32 vis = visible_lines();
    i32 cr = ed_row_of_pos(cur_line, cur_col);
    if cr >= top_line + vis / 3 && cr < top_line + vis - vis / 3
        && scroll_off == 0 {
        return;
    }
    scroll_set((cr - vis / 2) * font_line_h);
    plat_damage();
}

// Waits for background work to land. A headless one-shot render wants
// the final state, not the state before the git fetch arrives.
void app_settle() {
    git_settle(str_from(&g_path[0], g_path_len));
    // a baseline refetch after HEAD moved is a run of fetches, one
    // started per wake; here they run to the end
    while g_git_sweep {
        ed_git_sweep_step();
        if !git_busy() { break; }
        git_settle(str_from(&g_path[0], g_path_len));
    }
    build_settle();
    hist_settle();
    // the watcher's records, and the refresh they are due
    watch_pump();
    watch_settle();
}

// A baseline fetch has come back. It belongs to the buffer that asked
// for it, named by path, which may be shown in a window that is not the
// active one now (several windows, and a repaint switches the active one
// under the worker). Deposit it into that buffer wherever it is rather
// than only when it is the one loaded, so its gutter appears. `bytes`
// may be null (no baseline: untracked, or added since HEAD), and that
// still marks the buffer fetched so it is not asked again.
void ed_git_adopt(str reqpath, u8* bytes, i64 n) {
    i32 s = -1;
    for i32 i = 0; i < g_nbufs; i++ {
        bool match = false;
        if i == g_buf_active {
            match = g_has_path && str_equal(str_from(&g_path[0], g_path_len), reqpath);
        } else {
            match = g_bufs[i].has_path
                && str_equal(str_from(&g_bufs[i].path[0], g_bufs[i].path_len), reqpath);
        }
        if match { s = i; break; }
    }
    if s < 0 { return; }   // the buffer was closed while the fetch ran
    if s == g_buf_active {
        git_note_fetched();
        if bytes != null { git_set_baseline(bytes, n); } else { git_clear(); }
        ed_diff_took_baseline(s, bytes != null);
        ed_diff_note_baseline();
        plat_damage();   // the marks changed; nothing else asks for a frame
        return;
    }
    // a background buffer: load it long enough to set the baseline and
    // diff it, then restore the one on screen. Runs on a fetch handover,
    // never while typing.
    i32 cur = g_buf_active;
    buf_store(cur);
    buf_load(s);
    git_note_fetched();
    if bytes != null { git_set_baseline(bytes, n); } else { git_clear(); }
    buf_store(s);
    buf_load(cur);
    ed_diff_took_baseline(s, bytes != null);
    ed_diff_note_baseline();
    plat_damage();   // another pane may show that buffer
}

// a reply for the diff's file while the diff is up: the left side
// follows the new baseline, and with no baseline left the diff ends
private void ed_diff_took_baseline(i32 s, bool have) {
    if !diff_is_file(s) { return; }
    if have {
        diff_rebase(s);
    } else {
        ed_diff_close();
    }
}

// --- files changed on disk -------------------------------------------
// The watcher (src/watch.mc) calls these after a burst of changes.

// HEAD moved: every open buffer's baseline is out of date. Each keeps
// its baseline on screen until its reply replaces it, and the fetches
// run one at a time from the wake, the loaded buffer first, then the
// ones on a pane.
private bool g_git_sweep = false;

bool ed_git_sweeping() {
    return g_git_sweep;
}

void ed_git_refetch_all() {
    if g_has_path { git_mark_stale(); }
    for i32 i = 0; i < g_nbufs; i++ {
        if i != g_buf_active && g_bufs[i].has_path { g_bufs[i].git.fetched = false; }
    }
    g_git_sweep = true;
    ed_git_sweep_step();
}

private void ed_git_sweep_step() {
    if !g_git_sweep || git_busy() { return; }
    if g_has_path && !git_fetched() {
        ignore git_request(str_from(&g_path[0], g_path_len));
        return;
    }
    i32 pick = -1;
    for i32 i = 0; i < g_nbufs; i++ {
        if i == g_buf_active || !g_bufs[i].has_path || g_bufs[i].git.fetched { continue; }
        if pick < 0 || (buf_shown(i) && !buf_shown(pick)) { pick = i; }
    }
    if pick < 0 {
        g_git_sweep = false;
        return;
    }
    ignore git_request(str_from(&g_bufs[pick].path[0], g_bufs[pick].path_len));
}

// The loaded buffer takes the file's bytes as one edit over the span
// that differs, so undo, the server's incremental sync and the gutter
// see a normal edit. The buffer is then clean, and undo makes it dirty
// again. The caret, the extra cursors and the scroll stay where they
// were. The preview flag is kept: a reload is not the user's edit.
private void ed_reload_text(u8* raw, i64 rawn) {
    bool crlf = false;
    for i64 i = 0; i < rawn; i++ {
        if raw[i] == '\r' { crlf = true; break; }
    }
    // tb_load drops every CR of a CRLF file; the same here
    u8* p = raw;
    i64 n = rawn;
    if crlf {
        p = alloc<u8>(rawn + 1);
        n = 0;
        for i64 i = 0; i < rawn; i++ {
            if raw[i] != '\r' {
                p[n] = raw[i];
                n++;
            }
        }
    }
    i64 old = tb_len();
    i64 pre = tb_common_prefix(p, n);
    i64 lim = old - pre;
    if n - pre < lim { lim = n - pre; }
    i64 suf = tb_common_suffix(p, n, lim);
    i32 line = cur_line;
    i64 col = cur_col;
    i32 sy = scroll_y;
    bool prev = g_preview;
    undo_break = true;
    ed_replace(pre, old - pre - suf, p + pre, cast(i32, n - pre - suf));
    undo_break = true;
    undo_saved = undo_len;
    undo_update_dirty();
    tb.crlf = crlf;
    g_preview = prev;
    cur_line = clamp_line(line);
    cur_col = col_snap(cur_line, col);
    after_move();
    scroll_set(sy);
    if crlf { free(p); }
}

// a warning that names a file
private void ed_warn_file(str name, str tail) {
    noinit u8[256] mb;
    i32 nn = name.len;
    if nn > 256 - tail.len { nn = 256 - tail.len; }
    memcpy(&mb[0], name.data, nn);
    memcpy(&mb[nn], tail.data, tail.len);
    ed_warn(str_from(&mb[0], nn + tail.len));
}

// Buffer i against its file. A clean buffer takes the new bytes. One
// with unsaved changes keeps them, and the status says the file moved
// under it, once per version on disk; its next save asks first. A
// deleted file leaves the buffer as it is.
private void ed_disk_check(i32 i) {
    bool live = i == g_buf_active;
    EdBuffer* b = &g_bufs[i];
    i32 im = b.img1 - 1;
    if live { im = g_img; }
    if im >= 0 {
        image_disk_check(im);
        return;
    }
    bool has = b.has_path;
    str path = str_from(&b.path[0], b.path_len);
    TextBuf* t = &b.tb;
    if live {
        has = g_has_path;
        path = str_from(&g_path[0], g_path_len);
        t = &tb;
    }
    if !has { return; }
    FileData fd = file_read(path);
    if fd.data == null {
        if t.disk_known && !t.disk_gone {
            t.disk_gone = true;
            ed_warn_file(ed_buf_title(i), " was deleted on disk");
        }
        return;
    }
    i64 n = cast(i64, fd.len);
    u64 h = tb_hash(fd.data, n);
    t.disk_gone = false;
    if t.disk_known && h == t.disk_hash && n == t.disk_len {
        free(fd.data);
        return;
    }
    if t.dirty {
        if h != t.disk_noted {
            t.disk_noted = h;
            ed_warn_file(ed_buf_title(i), " changed on disk; the buffer has unsaved changes");
        }
        free(fd.data);
        return;
    }
    if live {
        ed_reload_text(fd.data, n);
        tb.disk_known = true;
        tb.disk_hash = h;
        tb.disk_len = n;
        tb.disk_noted = h;
        update_title();
    } else {
        // parked: load it long enough to reload and push it, the way a
        // baseline reply reaches a background buffer
        ed_lsp_flush();
        i32 cur = g_buf_active;
        buf_store(cur);
        buf_load(i);
        ed_reload_text(fd.data, n);
        tb.disk_known = true;
        tb.disk_hash = h;
        tb.disk_len = n;
        tb.disk_noted = h;
        ed_lsp_flush();
        buf_store(i);
        buf_load(cur);
        update_title();
    }
    free(fd.data);
}

void ed_disk_check_all() {
    for i32 i = 0; i < g_nbufs; i++ { ed_disk_check(i); }
    plat_damage();
}

// The slowest step of the last wake and its time, which a driver's
// --time log names when a wake holds the UI thread.
str g_wake_slow_step = "";
i64 g_wake_slow_us = 0;
private i64 g_wake_t = 0;

private void wake_step(str name) {
    i64 now = plat_time_us();
    if now - g_wake_t > g_wake_slow_us {
        g_wake_slow_us = now - g_wake_t;
        g_wake_slow_step = name;
    }
    g_wake_t = now;
}

void app_wake() {
    g_wake_slow_us = 0;
    g_wake_slow_step = "";
    g_wake_t = plat_time_us();
    git_poll(str_from(&g_path[0], g_path_len));
    wake_step("git");
    ed_git_sweep_step();
    wake_step("git sweep");
    watch_pump();
    wake_step("watch");
    image_pump();
    wake_step("image");
    hist_pump();
    wake_step("history");
    search_wake();
    wake_step("search");
    lsp_pump();
    wake_step("lsp");
    // every terminal's queue into its screen, once per wake: a burst is
    // many reads and one frame; the build reads what its tap kept
    i32 fed = term_pump();
    if fed != 0 {
        build_poll();
        // only what is on screen is worth a frame: a build put aside, a
        // watcher, a shell switched away from, all keep running and
        // their screens stay current without one. The switcher lists
        // the terminals, so a title arriving while it is open counts.
        bool seen = switcher_on;
        for i32 t = 0; t < TERM_MAX && !seen; t++ {
            if (fed & (1 << cast(u32, t))) != 0 && term_is_shown(t) { seen = true; }
        }
        if seen { plat_damage(); }
    }
    wake_step("terminals");
    restart_poll();
    // A burst of opens (a session restore, or a run of picker opens)
    // keeps only one pending git fetch, so the file on screen can be left
    // without its baseline and its gutter. Ask for it once the worker is
    // free and it still has none; a fetched buffer (even one with no
    // baseline at HEAD) never re-asks.
    if g_has_path && !git_fetched() && !git_busy() {
        git_reload(str_from(&g_path[0], g_path_len));
    }
    wake_step("git reload");
}

// the server's copy of the active buffer needs a refresh
private bool lsp_stale = true;

// push the live buffer to the server (didOpen once, didChange when
// edits happened since the last push)
private void ed_lsp_push() {
    if !lsp_ready || !lsp_applies() { return; }
    i64 n = tb_len();
    if n > 2 * 1024 * 1024 { return; }
    u8* text = alloc<u8>(n + 1);
    tb_copy(0, text, n);
    str p = str_from(&g_path[0], g_path_len);
    if lsp_did_open(p, text, n) {
        // the open carried the text as it is; the record predates it
        lsp_rec_reset();
    } else if lsp_stale {
        lsp_did_change(p, text, n);
    }
    lsp_stale = false;
    free(text);
}

// the caret's line, and its column as the server counts it
i32 ed_cur_line() { return cur_line; }
i32 ed_cur_lsp_col() { return lsp_col_of_byte(cur_line, cur_col); }

str ed_path() {
    if !g_has_path { return ""; }
    return str_from(&g_path[0], g_path_len);
}

// An edit happened: arm the timer rather than pushing now. The sync
// mode is full text, so a push per keystroke would send the whole
// buffer every time; this throttles continuous typing to one push per
// interval, and a single edit costs one push a moment later. Already
// armed means leave it alone. The timer kills itself when it fires, so
// idle stays at zero wakeups.
private bool lsp_timer_on = false;

private void ed_git_touch() {
    if !git_on() { return; }
    // the line hashes followed the edit, so the recompute is a diff of
    // the edited span and runs here, on the edit; a wide span waits
    // for the timer instead
    if git_sync_ok() {
        git_recompute();
        return;
    }
    if git_timer_on { return; }
    plat_set_timer(GIT_TIMER, GIT_MS);
    git_timer_on = true;
}

private void ed_git_untouch() {
    if !git_timer_on { return; }
    plat_kill_timer(GIT_TIMER);
    git_timer_on = false;
}

private void ed_lsp_touch() {
    if !lsp_ready || !lsp_applies() { return; }
    if lsp_timer_on { return; }
    plat_set_timer(LSP_SYNC_TIMER, LSP_SYNC_MS);
    lsp_timer_on = true;
}

private bool sem_timer_on = false;

// reset on each edit, so the (O(file)) semantic request fires once,
// after typing pauses, rather than on every push
private void ed_sem_touch() {
    if !lsp_ready || !lsp_applies() { return; }
    if sem_timer_on { plat_kill_timer(SEM_TIMER); }
    plat_set_timer(SEM_TIMER, SEM_MS);
    sem_timer_on = true;
}

private void ed_sem_untouch() {
    if !sem_timer_on { return; }
    plat_kill_timer(SEM_TIMER);
    sem_timer_on = false;
}

private void ed_lsp_untouch() {
    if !lsp_timer_on { return; }
    plat_kill_timer(LSP_SYNC_TIMER);
    lsp_timer_on = false;
}

// Leaving a buffer with an edit still pending: push it now, or its
// diagnostics stay describing text the server never saw.
private void ed_lsp_flush() {
    if !lsp_timer_on { return; }
    ed_lsp_untouch();
    ed_lsp_push();
}

// cmd+hover: the word under the pointer renders as a link while
// the primary modifier is held (view.mc draws it); clicking is the
// existing primary+click goto definition
bool hover_link_on = false;
bool hover_link_ok = false;   // resolves to a definition (or no server)
i32 hover_link_line = 0;
i32 hover_link_c0 = 0;   // byte columns within the line
i32 hover_link_c1 = 0;
private i32 hover_req_line = -1;   // span awaiting server confirmation
private i32 hover_req_c0 = -1;

// the async definition probe's verdict for the pending span
void ed_link_confirm(bool ok) {
    if hover_link_on && hover_link_line == hover_req_line
        && hover_link_c0 == hover_req_c0 {
        hover_link_ok = ok;
        plat_damage();
    }
}

// window-space rect of the hover link, for the pointer shape
bool ed_link_rect(i32* x0, i32* y0, i32* x1, i32* y1) {
    if !hover_link_on || !hover_link_ok { return false; }
    i32 l = hover_link_line;
    i32 r = ed_row_of_pos(l, hover_link_c0);
    if r < top_line || r >= top_line + visible_lines() + 1 { return false; }
    i32 ey = 0;
    ed_pos_xy(l, hover_link_c0, x0, y0);
    ed_pos_xy(l, hover_link_c1, x1, &ey);
    // a link across a row break: its first row, to the row's end
    if ey != *y0 { *x1 = pane_x1(); }
    *y1 = *y0 + font_line_h;
    return true;
}

void app_hover(i32 x, i32 y, i32 mods) {
    g_damage_win = g_win;
    app_hover_run(x, y, mods);
    g_damage_win = -1;
}

private void app_hover_run(i32 x, i32 y, i32 mods) {
    g_mods_held = mods;
    // the platforms report a modifier-only change here, which is how
    // the buffer cycle learns its chord was let go
    switcher_mods(mods);
    if explode_on {
        explode_hover(x, y);
        return;
    }
    if calls_on {
        calls_hover(x, y);
        return;
    }
    if menu_on {
        menu_hover(x, y);
        return;
    }
    // the banner's change arrows light up under the pointer, the way
    // the caption's buttons do. Only a change repaints, so a pointer
    // crossing the text costs nothing.
    i32 ah = ed_diff_arrow_hit(x, y);
    if ah != diff_arrow_hover {
        diff_arrow_hover = ah;
        ed_damage();
    }
    i32 rh = ed_diff_revert_hit(x, y);
    if rh != diff_revert_hover {
        diff_revert_hover = rh;
        ed_damage();
    }
    // the word under the pointer, whatever modifier is held: the link
    // needs the primary one, the popup needs none
    bool want = !overlay_active()
        && lsp_lang_ok()
        && g_panes[pane_at(x, y)].kind == PANE_DOC   // a terminal pane shows no document
        && x >= pane_x0() + gutter_w() && x < pane_x1()
        && y >= doc_top() && y < g_h - chrome_bottom_h();
    bool on = false;
    i32 hl = 0;
    i32 c0 = 0;
    i32 c1 = 0;
    i32 word_line = -1;
    i32 word_c0 = 0;
    i32 word_c1 = 0;
    i32 pl = -1;     // the line and byte column under the pointer
    i32 pcol = 0;
    if want {
        i32 l = ed_line_at_y(y);
        if l >= 0 && l <= tb.nlines - 1 {
            i64 pc = 0;
            ed_pos_at(x, y, false, &l, &pc);
            i32 col = cast(i32, pc);
            i32 n = line_bytes(l);
            pl = l;
            pcol = col;
            if col < n && is_word_byte(g_linebuf[col]) {
                ignore word_bounds_at(n, col, &c0, &c1);
                hl = l;
                on = true;
                // only identifier-ish classes can be links: keywords,
                // comments, strings, numbers never navigate
                lex_ensure(l);
                n = line_bytes(l);   // lex_ensure moved the line buffer
                ignore lex_row(g_linebuf, n, cast(i32, g_lexstate[l]), g_clsbuf);
                u8 k = g_clsbuf[c0];
                if k != LEX_DEF && k != LEX_VAR && k != LEX_FN && k != LEX_TYPE {
                    on = false;
                }
                word_line = l;
                word_c0 = c0;
                word_c1 = c1;
            }
        }
    }
    // The popup follows what is under the pointer, not the link: a
    // word, which the server describes, or a diagnostic range, whose
    // message needs no server; both when they overlap. It needs no
    // modifier and does not care what the lexer made of the token.
    i32 dc0 = 0;
    i32 dc1 = 0;
    i32 di = -1;
    if pl >= 0 { di = ed_diag_at(pl, pcol, &dc0, &dc1); }
    i32 pop_line = word_line;
    i32 pop_c0 = word_c0;
    bool is_word = word_line >= 0;
    if !is_word && di >= 0 {
        pop_line = pl;
        pop_c0 = dc0;
    }
    if pop_line != hover_ask_line || pop_c0 != hover_ask_c0 {
        ed_hover_hide();
        bool server = is_word && lsp_ready;
        if pop_line >= 0 && g_has_path && (server || di >= 0) {
            hover_ask_line = pop_line;
            hover_ask_c0 = pop_c0;
            hover_ask_pcol = pcol;
            hover_ask_word = server;
            ed_pos_xy(pop_line, cast(i64, pop_c0), &hover_pop_x, &hover_pop_y);
            plat_set_timer(HOVER_TIMER, HOVER_MS);
            hover_timer_on = true;
        }
    }
    // the link needs the primary modifier. With no link, the range is
    // cleared too: the view draws it only for a link, so a pointer
    // crossing words without the modifier repaints nothing.
    if (mods & MOD_CTRL) == 0 { on = false; }
    if !on {
        hl = 0;
        c0 = 0;
        c1 = 0;
    }
    if on != hover_link_on || hl != hover_link_line
        || c0 != hover_link_c0 || c1 != hover_link_c1 {
        hover_link_on = on;
        hover_link_line = hl;
        hover_link_c0 = c0;
        hover_link_c1 = c1;
        // server-confirmed links only; without a server the class
        // filter is the best signal available
        hover_link_ok = !lsp_ready || !g_has_path;
        if on && !hover_link_ok {
            hover_req_line = hl;
            hover_req_c0 = c0;
            ed_lsp_push();
            lsp_request_hoverdef(str_from(&g_path[0], g_path_len), hl,
                lsp_col_of_byte(hl, c0));
        }
        ed_damage();
    }
}

// --- hover documentation ----------------------------------------------
// Resting the pointer on a word asks the server what it is. The reply
// is held against the word it was asked about, so a pointer that has
// moved on since does not get a popup describing somewhere else.

bool hover_pop_on = false;
u8[HOVER_TEXT_MAX] hover_pop_text;
i32 hover_pop_len = 0;
// one flag per line of the text: 1 marks a line that came from a code
// fence, which the panel colors as the editor does
u8[HOVER_LINES_MAX] hover_pop_code;
i32 hover_pop_x = 0;        // window pixels of the word's left edge
i32 hover_pop_y = 0;        // top of the word's line
bool hover_sig = false;     // signature help: render above the line
private i32 hover_ask_line = -1;
private i32 hover_ask_c0 = -1;
private i32 hover_ask_pcol = 0;         // the pointer's column, for the diagnostic
private bool hover_ask_word = false;    // the anchor is a word the server can describe
private i32 hover_sig_col = -1;         // the '(' column signature help follows
private i32 hover_pop_diag_len = 0;     // the diagnostic's message at the top of the text
private bool hover_timer_on = false;

void ed_hover_hide() {
    hover_ask_line = -1;
    hover_ask_c0 = -1;
    hover_ask_word = false;
    hover_sig = false;
    if hover_timer_on {
        plat_kill_timer(HOVER_TIMER);
        hover_timer_on = false;
    }
    if !hover_pop_on { return; }
    hover_pop_on = false;
    hover_pop_len = 0;
    hover_pop_diag_len = 0;
    plat_damage();
}

// the reply; ignored unless the pointer is still on the word it asked
// about, and an empty one just leaves the popup closed. A diagnostic
// already showing keeps the top, and the reply joins below a blank
// line. `code` flags the reply's lines that were fenced code.
void ed_hover_show(str text, u8* code) {
    if hover_ask_line < 0 || text.len == 0 { return; }
    i32 at = 0;
    i32 first = 0;   // the panel line the reply starts on
    if hover_pop_on && hover_pop_diag_len > 0 && hover_pop_diag_len + 2 < HOVER_TEXT_MAX {
        at = hover_pop_diag_len;
        hover_pop_text[at] = 10;
        hover_pop_text[at + 1] = 10;
        at += 2;
        first = 2;   // the blank line, and the last diagnostic line
        for i32 i = 0; i < hover_pop_diag_len; i++ {
            if hover_pop_text[i] == 10 { first++; }
        }
    }
    i32 n = text.len;
    if at + n > HOVER_TEXT_MAX { n = HOVER_TEXT_MAX - at; }
    memcpy(&hover_pop_text[at], text.data, n);
    hover_pop_len = at + n;
    for i32 i = first; i < HOVER_LINES_MAX; i++ {
        hover_pop_code[i] = 0;
        if code != null && i - first < HOVER_LINES_MAX { hover_pop_code[i] = code[i - first]; }
    }
    hover_pop_on = true;
    plat_damage();
}

// Signature help for the call the caret sits in. The server answers with
// the signature as one string and the active argument as a span into it,
// so the popup can mark the argument being typed. Asked at the caret,
// which is what decides that argument: typing a comma moves it on. It
// never waits; the reply arrives through ed_sig_show.
const i32 SIG_TEXT_MAX = 512;

bool sig_on = false;
u8[SIG_TEXT_MAX] sig_text;
i32 sig_len = 0;
i32 sig_p0 = 0;             // active argument, byte span within sig_text
i32 sig_p1 = 0;
i32 sig_x = 0;              // caret x in window pixels; the panel's right edge
i32 sig_y = 0;              // top of the caret's line
private i32 sig_line = -1;
private i32 sig_paren_col = -1;

void ed_sig_hide() {
    if !sig_on && sig_line < 0 { return; }
    sig_on = false;
    sig_line = -1;
    sig_paren_col = -1;
    plat_damage();
}

// column of the innermost unclosed '(' before the caret on this line,
// or -1. One line only, which is where a call being typed lives.
private i32 sig_open_paren() {
    i32 n = line_bytes(cur_line);
    i32 c = cast(i32, cur_col);
    if c > n { c = n; }
    i32 depth = 0;
    for i32 i = c - 1; i >= 0; i-- {
        u8 ch = g_linebuf[i];
        if ch == ')' {
            depth++;
        } else if ch == '(' {
            if depth == 0 { return i; }
            depth--;
        }
    }
    return -1;
}

private void ed_sig_help() {
    if !lsp_ready || !lsp_applies() { return; }
    i32 op = sig_open_paren();
    // a call, not a parenthesised expression: a name right before it
    if op <= 0 || !is_word_byte(g_linebuf[op - 1]) {
        ed_sig_hide();
        return;
    }
    sig_line = cur_line;
    sig_paren_col = op;
    ed_lsp_push();
    lsp_request_sig(str_from(&g_path[0], g_path_len), cur_line,
        lsp_col_of_byte(cur_line, cur_col));
}

// the reply; ignored when the caret has left the call it was asked for
void ed_sig_show(str label, i32 p0, i32 p1) {
    if sig_line != cur_line || label.len == 0 { return; }
    i32 n = label.len;
    if n > SIG_TEXT_MAX { n = SIG_TEXT_MAX; }
    memcpy(&sig_text[0], label.data, n);
    sig_len = n;
    if p0 < 0 { p0 = 0; }
    if p1 > n { p1 = n; }
    if p1 < p0 { p1 = p0; }
    sig_p0 = p0;
    sig_p1 = p1;
    ed_pos_xy(cur_line, cur_col, &sig_x, &sig_y);
    sig_on = true;
    plat_damage();
}


// the diagnostic under the pointer opens the panel on its own
private void ed_hover_show_diag(str msg) {
    if hover_ask_line < 0 || msg.len == 0 { return; }
    i32 n = msg.len;
    if n > HOVER_TEXT_MAX { n = HOVER_TEXT_MAX; }
    memcpy(&hover_pop_text[0], msg.data, n);
    hover_pop_len = n;
    hover_pop_diag_len = n;
    for i32 i = 0; i < HOVER_LINES_MAX; i++ { hover_pop_code[i] = 0; }   // prose
    hover_pop_on = true;
    plat_damage();
}

private void ed_hover_ask() {
    if hover_ask_line < 0 || !g_has_path { return; }
    // looked up now rather than when the timer was armed: a publish in
    // between renumbers the diagnostics
    i32 dc0 = 0;
    i32 dc1 = 0;
    i32 di = ed_diag_at(hover_ask_line, hover_ask_pcol, &dc0, &dc1);
    if di >= 0 { ed_hover_show_diag(ed_diag_msg(di)); }
    if !hover_ask_word || !lsp_ready { return; }
    ed_lsp_push();
    lsp_request_hover(str_from(&g_path[0], g_path_len), hover_ask_line,
        lsp_col_of_byte(hover_ask_line, cast(i64, hover_ask_c0)));
}

// --- completion --------------------------------------------------------
// Typing an identifier arms a timer; the timer asks once for the word
// being typed, and the popup narrows itself as more is typed. Asking
// again per keystroke would be a full-text push plus a round trip
// between characters.

private bool cmp_timer_on = false;

private void ed_cmp_untouch() {
    if !cmp_timer_on { return; }
    plat_kill_timer(CMP_TIMER);
    cmp_timer_on = false;
}

// byte column where the identifier under the caret starts
private i32 ed_word_start() {
    i32 s = 0;
    i32 e = 0;
    ignore word_bounds(&s, &e);
    return s;
}

// true when the caret sits in a comment or string literal, where a
// symbol completion would offer code that cannot go. Reads the lexer's
// own per-byte class for the current line, so it follows the same rules
// the highlighter draws.
private bool ed_caret_in_comment() {
    if !lsp_lang_ok() { return false; }
    i64 c = cur_col;
    if c <= 0 { return false; }
    lex_ensure(cur_line);
    i32 n = line_bytes(cur_line);
    ignore lex_row(g_linebuf, n, cast(i32, g_lexstate[cur_line]), g_clsbuf);
    i32 idx = cast(i32, c) - 1;
    if idx >= n { idx = n - 1; }
    if idx < 0 { return false; }
    u8 k = g_clsbuf[idx];
    return k == LEX_COM || k == LEX_STR || k == LEX_ESC;
}

// --- the matching bracket ---------------------------------------------------
// A typed ), ] or } marks the bracket it closes: its glyph in the
// theme's accent (list.highlightForeground) until BRACE_MS, on a cell
// in the text color for the first BRACE_FLASH_MS. The scan runs back from the closer through the lexer's
// classes, so a bracket in a string or a comment does not count, and
// a closer of the wrong kind on the way ends it with no match. Only
// the primary caret is followed, and only in a file the lexer colors
// as code. An edit at or before the closer moves the pair, so it ends
// the mark; the timer ends it otherwise and stops itself.

const i32 BRACE_TIMER = 13;   // 7 the player's, 8 the terminal probe's, 9 search's, 10 the watcher's, 11 the notices', 12 the drag scroll's
private const i32 BRACE_MS = 1000;
private const i32 BRACE_FLASH_MS = 150;
private const i32 BRACE_SCAN_LINES = 5000;
private const i32 BRACE_DEPTH_MAX = 256;
private bool brace_on = false;
private bool brace_flash = false;   // the first part: the cell filled
private i32 brace_buf = -1;
private i64[2] brace_pos;   // the opener and the closer, as byte offsets

void brace_clear() {
    if !brace_on { return; }
    brace_on = false;
    brace_flash = false;
    plat_kill_timer(BRACE_TIMER);
    plat_damage();
}

// BRACE_TIMER: the flash ends and the colored glyph stays, then that ends
private void brace_timer() {
    if !brace_flash {
        brace_clear();
        return;
    }
    brace_flash = false;
    plat_kill_timer(BRACE_TIMER);
    plat_set_timer(BRACE_TIMER, BRACE_MS - BRACE_FLASH_MS);
    plat_damage();
}

// tb_insert and tb_delete at pos
void brace_note_edit(i64 pos) {
    if brace_on && pos <= brace_pos[1] { brace_clear(); }
}

private u8 brace_opener_of(u8 c) {
    if c == ')' { return '('; }
    if c == ']' { return '['; }
    if c == '}' { return '{'; }
    return 0;
}

// the closer just typed sits before the caret
private void brace_after_type() {
    brace_clear();
    if !g_lex_on || g_lex_lang == LANG_MD || g_ncur > 0 || cur_col <= 0 { return; }
    i32 line = cur_line;
    i32 col = cast(i32, cur_col) - 1;
    noinit u8[BRACE_DEPTH_MAX] want;   // the openers still to find, innermost last
    i32 sp = 0;
    lex_ensure(line);
    for i32 l = line; l >= 0 && line - l < BRACE_SCAN_LINES; l-- {
        i32 n = line_bytes(l);
        ignore lex_row(g_linebuf, n, cast(i32, g_lexstate[l]), g_clsbuf);
        i32 i = n - 1;
        if l == line {
            if col >= n { return; }
            u8 k0 = g_clsbuf[col];
            u8 o0 = brace_opener_of(g_linebuf[col]);
            if o0 == 0 || k0 == LEX_COM || k0 == LEX_STR || k0 == LEX_ESC { return; }
            want[0] = o0;
            sp = 1;
            i = col - 1;
        }
        while i >= 0 {
            u8 k = g_clsbuf[i];
            u8 c = g_linebuf[i];
            i--;
            if k == LEX_COM || k == LEX_STR || k == LEX_ESC { continue; }
            u8 o = brace_opener_of(c);
            if o != 0 {
                if sp >= BRACE_DEPTH_MAX { return; }
                want[sp] = o;
                sp++;
                continue;
            }
            if c != '(' && c != '[' && c != '{' { continue; }
            if c != want[sp - 1] { return; }   // the wrong kind: no pair
            sp--;
            if sp == 0 {
                brace_pos[0] = tb_line_start(l) + cast(i64, i + 1);
                brace_pos[1] = tb_line_start(line) + cast(i64, col);
                brace_buf = g_buf_active;
                brace_on = true;
                brace_flash = true;
                plat_set_timer(BRACE_TIMER, BRACE_FLASH_MS);
                plat_damage();
                return;
            }
        }
    }
}

// The matched opener when it is on line l of the loaded pane: its byte
// column into *col, and whether the cell is filled into *flash.
bool ed_brace_mark(i32 l, i64* col, bool* flash) {
    if !brace_on || g_panes[g_pane_loaded].buf != brace_buf || l < 0 || l >= tb.nlines { return false; }
    i64 ls = tb_line_start(l);
    if brace_pos[0] < ls || brace_pos[0] >= tb_line_end(l) { return false; }
    *col = brace_pos[0] - ls;
    *flash = brace_flash;
    return true;
}

private void ed_cmp_touch() {
    if !lsp_ready || !lsp_applies() { return; }
    if cmp_on || cmp_timer_on { return; }
    if ed_caret_in_comment() { return; }
    plat_set_timer(CMP_TIMER, CMP_MS);
    cmp_timer_on = true;
}

private void ed_cmp_ask() {
    if !lsp_ready || !g_has_path { return; }
    i32 w0 = ed_word_start();
    if cast(i64, w0) == cur_col { return; }   // nothing typed to complete
    ed_lsp_push();
    ed_cmp_line = cur_line;
    ed_cmp_word0 = w0;
    lsp_request_complete(str_from(&g_path[0], g_path_len), cur_line,
        lsp_col_of_byte(cur_line, cur_col));
}

// The list is built against the word that was asked for, so a reply
// arriving after the caret moved on is thrown away rather than
// completing something else.
private i32 ed_cmp_line = 0;
private i32 ed_cmp_word0 = 0;

void ed_complete_begin(bool builtins, bool incomplete) {
    cmp_begin(ed_cmp_line, ed_cmp_word0, builtins);
    cmp_incomplete = incomplete;
}

// The list was cut short: ask again once typing pauses. The list on
// screen narrows meanwhile, and the reply replaces it.
private void ed_cmp_more() {
    if !cmp_on || !cmp_incomplete || cmp_timer_on { return; }
    plat_set_timer(CMP_TIMER, CMP_MS);
    cmp_timer_on = true;
}

// Ctrl+Space: ask now, wherever the caret is
void ed_complete_now() {
    ed_cmp_untouch();
    ed_cmp_ask();
}

// the one edit path a completion needs: replace the word being typed
void ed_replace_word(i32 line, i32 c0, str text) {
    if line != cur_line { return; }
    i64 ls = tb_line_start(line);
    i64 at = ls + cast(i64, c0);
    i64 end = ls + cur_col;
    if end < at { return; }
    ed_replace(at, end - at, text.data, text.len);
    set_caret_abs(at + cast(i64, text.len));
    sel_clear();
    goal_vcol = -1;
    after_edit(line);
}

// goto definition at the caret: push the live text, then ask.
// The response navigates through ed_lsp_goto.
void ed_goto_def() {
    if !lsp_applies() { return; }
    if !lsp_ready {
        ed_status(ed_lsp_not_ready());
        plat_damage();
        return;
    }
    ed_lsp_push();
    lsp_request_def(str_from(&g_path[0], g_path_len), cur_line,
        lsp_col_of_byte(cur_line, cur_col));
}

// references for the symbol at the caret, shown in the search view
void ed_find_refs() {
    if !lsp_applies() { return; }
    if !lsp_ready {
        ed_status(ed_lsp_not_ready());
        plat_damage();
        return;
    }
    i32 c0 = 0;
    i32 c1 = 0;
    if !word_bounds(&c0, &c1) {
        ed_status("no symbol at the caret");
        plat_damage();
        return;
    }
    memcpy(&g_refs_word[0], g_linebuf + c0, c1 - c0);
    g_refs_word_len = c1 - c0;
    ed_lsp_push();
    lsp_request_refs(str_from(&g_path[0], g_path_len), cur_line,
        lsp_col_of_byte(cur_line, cur_col));
}

private u8[256] g_refs_word;
private i32 g_refs_word_len = 0;

// the reply is in; the results view takes it from here
void ed_refs_done() {
    search_refs_end(str_from(&g_refs_word[0], g_refs_word_len));
}

// --- navigation history ----------------------------------------------
// Jump destinations (goto definition) push the departure point;
// primary+Left walks back, primary+Right forward.

private const i32 NAV_MAX = 32;

private struct NavLoc {
    u8[PATH_MAX] path;
    i32 path_len;
    i32 line;
    i64 col;
}

private NavLoc[NAV_MAX] nav_back;
private i32 nav_nback = 0;
private NavLoc[NAV_MAX] nav_fwd;
private i32 nav_nfwd = 0;

private void nav_capture(NavLoc* o) {
    memcpy(&o.path[0], &g_path[0], g_path_len);
    o.path_len = g_path_len;
    o.line = cur_line;
    o.col = cur_col;
}

private void nav_append(NavLoc* stack, i32* n) {
    if *n == NAV_MAX {
        for i32 i = 0; i < NAV_MAX - 1; i++ { stack[i] = stack[i + 1]; }
        *n = NAV_MAX - 1;
    }
    nav_capture(&stack[*n]);
    *n = *n + 1;
}

private void nav_land(NavLoc* t) {
    if !ed_view_file(str_from(&t.path[0], t.path_len)) { return; }
    i32 l = clamp_line(t.line);
    land_at(l, col_snap(l, t.col));
}

// the caret to a line and byte column, both clamped, centred in the
// view: where every jump ends
private void land_at(i32 line, i64 col) {
    line = clamp_line(line);
    cur_line = line;
    i64 ll = line_len(line);
    if col > ll { col = ll; }
    if col < 0 { col = 0; }
    cur_col = col;
    sel_clear();
    goal_vcol = -1;
    after_move();
    ed_center_caret();
    plat_damage();
}

// a departure point for a jump that is not a definition response
void ed_nav_mark() {
    if !g_has_path { return; }
    nav_append(&nav_back[0], &nav_nback);
    nav_nfwd = 0;
}

void ed_nav_back() {
    if nav_nback == 0 {
        ed_status("no earlier location");
        plat_damage();
        return;
    }
    nav_append(&nav_fwd[0], &nav_nfwd);
    nav_nback--;
    NavLoc t = nav_back[nav_nback];
    nav_land(&t);
}

void ed_nav_fwd() {
    if nav_nfwd == 0 {
        ed_status("no later location");
        plat_damage();
        return;
    }
    nav_append(&nav_back[0], &nav_nback);
    nav_nfwd--;
    NavLoc t = nav_fwd[nav_nfwd];
    nav_land(&t);
}

// the caret to a line and byte column in `path`, through the
// navigation history: what a build problem names
void ed_goto_bytes(str path, i32 line, i64 bcol) {
    ed_nav_mark();
    term_leave_for_jump();
    if !ed_view_file(path) {
        ed_warn("cannot open the file the problem names");
        return;
    }
    land_at(line, bcol);
}

// a definition response: open the target and land on it, centered.
// `col` is an LSP character offset, converted to a byte column below.
void ed_lsp_goto(str path, i32 line, i32 col) {
    if lsp_trace { print("lsp: goto {}:{}:{}\n", path, line, col); }
    // The server can answer with a file that is not on disk, for a
    // symbol whose source the toolchain ships no copy of. Opening one
    // would invent an empty buffer and call it that file, so say so and
    // stay put; this is ahead of the history push, which a jump that
    // does not happen must not touch.
    // file_size, not path_exists: the latter goes through file_stamp,
    // which has no wasm arm and answers false for every path there,
    // which would refuse every jump on the page.
    if file_size(path) < 0 {
        noinit u8[192] mb;
        str pre = "no source on disk: ";
        memcpy(&mb[0], pre.data, pre.len);
        i32 mn = pre.len;
        i32 pn = path.len;
        if pn > 192 - mn { pn = 192 - mn; }
        memcpy(&mb[mn], path.data, pn);
        mn += pn;
        ed_status(str_from(&mb[0], mn));
        plat_damage();
        return;
    }
    ed_nav_mark();
    if !ed_view_file(path) { return; }
    // the character offset is the server's, so it is converted from
    // utf-16 units on the line the caret lands on
    line = clamp_line(line);
    land_at(line, lsp_byte_of_col(line, col));
}

// a language a server knows: minc, and C and C++ (clangd)
private bool lsp_lang_ok() {
    return g_lex_on && (g_lex_lang == LANG_MINC || g_lex_lang == LANG_C);
}

// the server has a say in this buffer: a file with a path, in a
// language a server knows
private bool lsp_applies() {
    return g_has_path && lsp_lang_ok();
}

// Makes the current server the one for the buffer in the globals. Runs
// wherever the globals take another buffer's language, so the position
// encoding and the opened table that the LSP code reads are that
// server's.
void ed_lsp_follow() {
    lsp_use(lsp_server_of(g_lex_lang));
}

// why a request on this buffer did not go out
str ed_lsp_not_ready() {
    if lsp_absent() { return "clangd was not found: put it on PATH or name it in EDMINC_CLANGD"; }
    return "language server is not ready";
}

// --- diagnostics on the active buffer ---------------------------------
// The store is keyed by path, so the lookup follows whichever buffer
// is swapped into the globals: each pane gets its own file's marks.

i32 ed_diag_count() {
    if !g_has_path { return 0; }
    return lsp_diag_count(str_from(&g_path[0], g_path_len));
}

LspDiag* ed_diag(i32 i) {
    if !g_has_path { return null; }
    return lsp_diag(str_from(&g_path[0], g_path_len), i);
}

str ed_diag_msg(i32 i) {
    if !g_has_path { return ""; }
    return lsp_diag_msg(str_from(&g_path[0], g_path_len), i);
}

// index of the first diagnostic whose range covers `line`, or -1. A
// range can span lines, so both ends are compared.
i32 ed_diag_on_line(i32 line) {
    i32 n = ed_diag_count();
    for i32 i = 0; i < n; i++ {
        LspDiag* d = ed_diag(i);
        if d == null { continue; }
        if line >= d.line && line <= d.line1 { return i; }
    }
    return -1;
}

// index of the diagnostic whose drawn span on `line` covers byte
// column `col`, with that span, or -1
i32 ed_diag_at(i32 line, i32 col, i32* c0, i32* c1) {
    i32 n = ed_diag_count();
    if n == 0 { return -1; }
    i32 len = line_bytes(line);
    for i32 i = 0; i < n; i++ {
        LspDiag* d = ed_diag(i);
        if d == null || line < d.line || line > d.line1 { continue; }
        i32 a = 0;
        i32 b = 0;
        ed_diag_span(d, line, len, &a, &b);
        if col >= a && col < b {
            *c0 = a;
            *c1 = b;
            return i;
        }
    }
    return -1;
}

// the byte columns a diagnostic covers on `line`, clamped to it.
// A zero-width range still marks one cell, as the reference does.
void ed_diag_span(LspDiag* d, i32 line, i32 n, i32* c0, i32* c1) {
    i32 a = 0;
    i32 b = n;
    if line == d.line { a = cast(i32, lsp_byte_of_col(line, d.col0)); }
    if line == d.line1 { b = cast(i32, lsp_byte_of_col(line, d.col1)); }
    if a < 0 { a = 0; }
    if b > n { b = n; }
    if a > n { a = n; }
    if b <= a { b = a + 1; }
    *c0 = a;
    *c1 = b;
}

// tell the language server about the active buffer. Starts the
// buffer's server on its first file; lsp calls back in when the
// initialize round-trip completes, with that server current, so the
// active buffer's is made current again first.
void ed_lsp_sync() {
    ed_lsp_follow();
    if !lsp_applies() { return; }
    if !lsp_on {
        lsp_start();
        return;
    }
    if !lsp_ready { return; }
    i64 n = tb_len();
    if n > 2 * 1024 * 1024 { return; }
    u8* text = alloc<u8>(n + 1);
    tb_copy(0, text, n);
    if lsp_did_open(str_from(&g_path[0], g_path_len), text, n) {
        lsp_rec_reset();
        lsp_stale = false;
    }
    free(text);
    // a buffer shown again keeps no token list; ask for this one's
    if !lsp_stale && !sem_is_for(str_from(&g_path[0], g_path_len)) {
        lsp_request_semantic(str_from(&g_path[0], g_path_len));
    }
}

void app_char(u32 cp) {
    if chord_eat {
        chord_eat = false;
        return;
    }
    if tab_eat {
        tab_eat = false;
        if cp == 9 { return; }
    }
    // Ctrl+K Enter: the chord's second key arrives as text, since Enter
    // is one of the two controls the platform delivers that way
    if chord_k && cp == 13 {
        chord_k = false;
        chord_hint_close();
        ed_buf_keep();
        return;
    }
    status_clear();
    if !hover_sig { ed_hover_hide(); }   // signature help survives typing
    if ask_on { ask_char(cp); return; }
    if menu_on { menu_char(cp); return; }
    if explode_on { explode_char(cp); return; }
    if calls_on { calls_char(cp); return; }
    if palette_on { palette_char(cp); return; }
    if pick_on { pick_char(cp); return; }
    if sym_on { sym_char(cp); return; }
    if switcher_on { switcher_char(cp); return; }
    if find_on { find_char(cp); return; }
    if search_on && search_char(cp) { return; }
    if tree_edit_on() { tree_edit_char(cp); return; }
    if tree_focus && tree_char(cp) { return; }
    if cmp_char(cp) { return; }
    // an image takes no text: + - 0 1 zoom it, anything else does nothing
    if g_img >= 0 && ed_term_active() < 0 {
        image_char(g_img, cp);
        return;
    }
    if ed_term_active() >= 0 {
        // A chord's control character arrives here as well as through
        // app_key, and the key path has already dealt with it: the
        // encoder turned Ctrl+letter into its control code, or the
        // editor kept the chord for itself. Letting it through as well
        // is what pasted twice on Ctrl+V, interrupted the shell while
        // copying on Ctrl+C, and put the second key of a chord into the
        // shell. Enter and Backspace are the two the platform delivers
        // as text and not as a key (plat.mc, app_char), so they are the
        // two that go on; Tab and Escape arrive as K_TAB and K_ESCAPE.
        if cp < 32 && cp != 13 && cp != 8 { return; }
        if cp == 127 { return; }
        term_char(ed_term_active(), cp, 0);
        ed_term_sel_clear();
        plat_damage();
        return;
    }
    if cp == 13 { multi_apply(OP_ENTER); return; }
    // Tab over a selection across lines indents them
    if cp == 9 && g_ncur == 0 && sel_spans_lines() {
        ed_indent_lines(false);
        return;
    }
    if cp == 9 { multi_apply(OP_TAB); return; }
    if cp == 8 {
        multi_apply(OP_BACKSPACE);
        cmp_after_type();
        ed_cmp_more();
        return;
    }
    if cp == 127 { multi_apply(OP_DELWL); return; }   // Ctrl+Backspace
    if cp >= 32 {
        op_cp = cp;
        multi_apply(OP_CHAR);
        if cmp_on {
            cmp_after_type();
            ed_cmp_more();
        } else if is_word_byte(cast(u8, cp)) {
            ed_cmp_touch();
        }
        // '(' opens the call, ',' moves to the next argument; both ask
        // again, since the caret is what decides which argument it is
        if cp == '(' || cp == ',' { ed_sig_help(); }
        if cp == ')' { ed_sig_hide(); }
        if cp == ')' || cp == ']' || cp == '}' { brace_after_type(); }
    }
}

// Ctrl+K Ctrl+O: the platform's dialog when it has one, the input box
// otherwise. An unsaved buffer refuses before either.
private void ed_open_folder_ask() {
    if bufs_dirty() {
        ed_warn("save or discard the unsaved buffers first");
        plat_damage();
        return;
    }
    if plat_pick_folder() { return; }
    ask_open_mode(ASK_FOLDER);
}

void app_folder_picked(u8* path, i32 len) {
    if len <= 0 {
        plat_damage();
        return;
    }
    ignore ed_open_folder(str_from(path, len));
}

// The keys a focused terminal pane leaves to the editor: its own
// chords, the group commands, the new window, the picker and palette,
// the sidebar, the build and run keys, and Ctrl+W, which closes the
// pane as it closes every pane (the shell's kill-word is
// Ctrl+Backspace there). Everything else is the shell's, Ctrl+C
// included: while it has the focus the shell wins, as in the
// reference. Ctrl+R is the exception: the run, not the shell's
// history search, so a run works from wherever the focus is.
private bool term_editor_key(i32 key, i32 mods) {
    bool prim = (mods & MOD_CTRL) != 0;
    if key == 'W' && prim { return true; }                      // close the shell, or the pane
    if switcher_chord_hold(key, mods) != 0 { return true; }    // buffer cycle
    if key == 92 && prim { return true; }                       // split
    if key >= '1' && key <= '3' && prim { return true; }        // pane focus
    if key == 'K' && mods == MOD_CTRL { return true; }          // the chord prefix
    if chord_k { return true; }                                 // ...and its second key
    if key == 'P' && prim { return true; }                      // picker, palette
    if key == 'M' && prim && (mods & MOD_SHIFT) == 0 { return true; }   // the explode view
    if key == 'M' && mods == (MOD_CTRL | MOD_SHIFT) { return true; }     // the call graph
    if key == 'B' && (mods & (MOD_CTRL | MOD_SUPER)) != 0 { return true; }   // sidebar, build
    if key == 'Q' && prim { return true; }                      // quit
    if key == 'J' && prim { return true; }                      // the build pane
    if key == K_F5 || key == K_F8 { return true; }              // run, the problems walk
    if key == 'R' && prim { return true; }                      // run, over the shell's history search
    if key == '.' && mods == MOD_CTRL { return true; }          // stop the build or run
    if (key == '=' || key == '-' || key == '0') && (mods & ~MOD_SHIFT) == MOD_CTRL { return true; }   // zoom
    if (key == K_LEFT || key == K_RIGHT) && (mods & MOD_ALT) != 0
        && (mods & (MOD_CTRL | MOD_SUPER)) != 0 { return true; }   // the pane's content moves
    return false;
}

// A key sent by the editor itself (the command palette runs a row this
// way). No character follows it, so the chord path must not wait for
// one and swallow the next typed character.
void ed_key_synth(i32 key, i32 mods) {
    app_key(key, mods);
    chord_eat = false;
}

// a key that only moves the caret, the selection or a list's cursor in
// this window. With Alt the arrows move lines; the completion list, the
// search panel and a terminal are shared by the windows.
private bool key_navigates(i32 key, i32 mods) {
    if (mods & MOD_ALT) != 0 { return false; }
    if cmp_on || search_focus || ed_term_active() >= 0 { return false; }
    return key == K_LEFT || key == K_RIGHT || key == K_UP || key == K_DOWN
        || key == K_HOME || key == K_END || key == K_PGUP || key == K_PGDN;
}

void app_key(i32 key, i32 mods) {
    if key_navigates(key, mods) { g_damage_win = g_win; }
    app_key_run(key, mods);
    g_damage_win = -1;
}

// The modifiers held as of the last key or pointer report. Enter
// arrives as text with no modifiers, so a widget that binds a chord on
// it reads them here.
private i32 g_mods_held = 0;

i32 ed_mods_held() {
    return g_mods_held;
}

private void app_key_run(i32 key, i32 mods) {
    g_mods_held = mods;
    chord_eat = false;
    tab_eat = false;
    status_clear();
    // a selection on a diff's baseline side lasts until the copy chord
    // takes it or another key goes to the file
    if g_bsel && !(key == 'C' && (mods & MOD_CTRL) != 0) { base_sel_clear(); }
    // a plain hover goes on any key; signature help persists while the
    // call is typed and is dismissed by Escape or the caret leaving it
    if !hover_sig { ed_hover_hide(); }
    else if key == K_ESCAPE { ed_hover_hide(); }
    // a focused terminal pane: the key goes to the shell unless it is
    // one the editor keeps. The overlays above it (the picker, find, an
    // input line) still come first, since they took the keyboard.
    if ed_term_active() >= 0 && !overlay_active() && !tree_focus && !search_focus
        && !term_editor_key(key, mods) {
        i32 t = ed_term_active();
        // MOD_CTRL is the primary; the shell reads real Ctrl, which is
        // MOD_SUPER on macOS and MOD_CTRL elsewhere. Map to the encoder's
        // MOD_CTRL either way, so Ctrl+C is 0x03 on every platform.
        // the primary's copy chord takes a selection to the clipboard
        // (with Shift it is copy whatever the selection); without one,
        // Ctrl+C is the shell's interrupt as ever
        if key == 'C' && (mods & MOD_CTRL) != 0
            && ((mods & MOD_SHIFT) != 0 || ed_term_sel_on(t)) {
            ed_term_copy();
            return;
        }
        // and the paste chord puts the clipboard into the shell, as a
        // paste (bracketed when the child asked); real Ctrl+V on macOS
        // still reaches the shell as 0x16
        if key == 'V' && (mods & MOD_CTRL) != 0 {
            ed_term_sel_clear();
            ed_term_paste();
            return;
        }
        i32 km = mods;
        when os(macos) {
            km = mods & ~(MOD_CTRL | MOD_SUPER);
            if (mods & MOD_SUPER) != 0 { km = km | MOD_CTRL; }
        }
        if term_key(t, key, km) {
            ed_term_sel_clear();
            chord_eat = key < 128 && (km & (MOD_CTRL | MOD_ALT)) == 0;
            plat_damage();
            return;
        }
        // a printable key with no editor meaning arrives again as a
        // character through app_char, which is where text goes
        return;
    }
    if chord_k {
        // a printable key without ctrl or alt is followed by its
        // character, which belongs to the chord, not the text
        chord_k = false;
        chord_hint_close();
        chord_eat = key < 128 && (mods & (MOD_CTRL | MOD_ALT)) == 0;
        if key == 'O' && (mods == 0 || mods == MOD_CTRL) {
            ed_open_folder_ask();
            return;
        }
        if key == 'N' && (mods == 0 || mods == MOD_CTRL) {
            ignore plat_window_open();   // a new window over the shared buffers
            return;
        }
        if key == 'F' && (mods == 0 || mods == MOD_CTRL) {
            ed_new_file_ask();
            return;
        }
        if key == 'W' && (mods == 0 || mods == MOD_CTRL) {
            switcher_open();
            return;
        }
        if key == 'R' && (mods == 0 || mods == MOD_CTRL) {
            palette_open_recent();
            return;
        }
        if key == 'X' && (mods == 0 || mods == MOD_CTRL) {
            ed_restart_self();
            return;
        }
        if key == 'T' && (mods & ~(MOD_CTRL | MOD_SHIFT)) == 0 {
            ed_term_open();
            return;
        }
        if key == 'S' && (mods == 0 || mods == MOD_CTRL) {
            g_statusbar_on = !g_statusbar_on;
            plat_damage();
            return;
        }
        if key == 'D' && (mods == 0 || mods == MOD_CTRL) {
            g_squiggles = !g_squiggles;
            if g_squiggles { ed_status("problem underlines on"); } else { ed_status("problem underlines off"); }
            plat_damage();
            return;
        }
        if key == 'M' && (mods == 0 || mods == MOD_CTRL) {
            g_smooth_scroll = !g_smooth_scroll;
            g_glide_px = 0;
            g_glide_period = 0;
            if g_smooth_scroll { ed_status("smooth scrolling on"); } else { ed_status("smooth scrolling off"); }
            return;
        }
        // Ctrl+K P: the terminal's colors, the user's own against the
        // built-in ones, for looking at one after the other
        if key == 'P' && (mods == 0 || mods == MOD_CTRL) {
            term_palette_toggle();
            if !term_palette_have() {
                ed_status("terminal colors: built-in (this machine's terminal names none)");
            } else if term_palette_theirs() {
                ed_status("terminal colors: yours");
            } else {
                ed_status("terminal colors: built-in");
            }
            plat_damage();
            return;
        }
        if key == K_ESCAPE { return; }
        ed_warn("no such chord");
        plat_damage();
        return;
    }
    // Esc dismisses a notice and still does what it does: one press
    // closes the message and the find widget, the list, the cursors
    if notice_on && key == K_ESCAPE { ed_notice_close(); }
    if ask_on { ask_key(key, mods); return; }
    if menu_on { menu_key(key, mods); return; }
    if explode_on {
        if key == 'M' && mods == MOD_CTRL {
            explode_toggle();
            chord_eat = true;   // Ctrl+M's character is 13, Enter's
            return;
        }
        explode_key(key, mods);
        return;
    }
    if calls_on {
        if key == 'M' && mods == (MOD_CTRL | MOD_SHIFT) {
            calls_close();
            chord_eat = true;   // Ctrl+Shift+M's character is 13, Enter's
            return;
        }
        calls_key(key, mods);
        return;
    }
    if palette_on { palette_key(key, mods); return; }
    if pick_on { pick_key(key, mods); return; }
    if sym_on { sym_key(key, mods); return; }
    if switcher_on { switcher_key(key, mods); return; }
    if find_on && find_key(key, mods) { return; }
    if search_on && search_key(key, mods) { return; }
    if tree_edit_on() { tree_edit_key(key, mods); return; }
    if tree_focus && tree_key(key, mods) { return; }
    if cmp_key(key, mods) { return; }
    if build_key(key, mods) { return; }
    // an image pane: the arrows pan it
    if g_img >= 0 && g_panes[g_pane_active].kind == PANE_DOC && image_key(g_img, key, mods) { return; }
    bool shift = (mods & MOD_SHIFT) != 0;
    // Ctrl+B: the sidebar
    if key == 'B' && (mods & (MOD_CTRL | MOD_SUPER)) != 0 && !shift {
        tree_toggle();
        return;
    }
    // F7 and Shift+F7: the diff's next and previous change
    if key == K_F7 {
        ed_diff_jump(shift);
        return;
    }
    // the buffer cycle is the switcher's list, opened one step along:
    // what is open is on screen while it is walked, and Enter accepts.
    // Ctrl+K W opens the same list to type at.
    i32 sw_hold = switcher_chord_hold(key, mods);
    if sw_hold != 0 {
        i32 d = 1;
        if shift { d = -1; }
        // the modifier goes with it: letting it go accepts the row, so
        // the chord is hold-and-tab, not tab-then-enter
        switcher_open_at(d, sw_hold);
        return;
    }
    // arrows with the word modifier walk words (shift extends); with the
    // history modifier they walk the navigation history. Ahead of the
    // primary-modifier block, since on Windows the word modifier is Ctrl.
    // the pane's content to the neighbour: Ctrl+Alt with an arrow, and
    // the same with the real Ctrl on macOS, where it arrives as super
    if (key == K_LEFT || key == K_RIGHT) && (mods & MOD_ALT) != 0
        && (mods & (MOD_CTRL | MOD_SUPER)) != 0 && (mods & MOD_SHIFT) == 0 {
        i32 d = 1;
        if key == K_LEFT { d = -1; }
        ed_pane_move_shown(d);
        return;
    }
    if (mods & MOD_WORD) != 0 && key == K_LEFT {
        op_shift = shift;
        multi_apply(OP_WORDL);
        return;
    }
    if (mods & MOD_WORD) != 0 && key == K_RIGHT {
        op_shift = shift;
        multi_apply(OP_WORDR);
        return;
    }
    if key == NAV_BACK_KEY && mods == NAV_BACK_MODS { ed_nav_back(); return; }
    if key == NAV_FWD_KEY && mods == NAV_FWD_MODS { ed_nav_fwd(); return; }
    when os(macos) {
        // Cmd+arrows is line start and end, as it is everywhere on the
        // platform; shift extends
        if (mods & MOD_CTRL) != 0 && key == K_LEFT {
            op_shift = shift;
            multi_apply(OP_HOME);
            return;
        }
        if (mods & MOD_CTRL) != 0 && key == K_RIGHT {
            op_shift = shift;
            multi_apply(OP_END);
            return;
        }
    }
    // Shift+Tab: the caret's line, or the selected lines, one indent left
    if key == K_TAB && mods == MOD_SHIFT && g_img < 0 && !tree_focus && !search_focus {
        ed_indent_lines(true);
        tab_eat = true;
        return;
    }
    // Alt+Z: word wrap. The Option chord types a character on macOS,
    // which is the chord's.
    if key == 'Z' && mods == MOD_ALT {
        ed_wrap_toggle();
        when os(macos) { chord_eat = true; }
        return;
    }
    // Ctrl+Shift+M: the call graph of the function at the caret. Like
    // Ctrl+M, the key types a carriage return; the 13 that follows is
    // the chord's, not an Enter for the view.
    if key == 'M' && mods == (MOD_CTRL | MOD_SHIFT) {
        calls_open();
        chord_eat = true;
        return;
    }
    if (mods & MOD_CTRL) != 0 {
        if (mods & MOD_ALT) != 0 && (key == K_UP || key == K_DOWN) {
            i32 cd = 1;
            if key == K_UP { cd = -1; }
            cur_add_vert(cd);
            return;
        }
        // in a diff the arrows with the primary modifier walk the
        // changes, the way the banner's two arrows do. Only there:
        // elsewhere the chord is not the editor's to take.
        if diff_here() && (key == K_UP || key == K_DOWN) {
            ed_diff_jump(key == K_UP);
            return;
        }
        if key == 'D' { ed_add_next_match(); return; }
        if key == 'M' && !shift {
            // Ctrl+M types a carriage return on most platforms: the 13
            // that follows is the chord's, not an Enter for the view
            explode_toggle();
            chord_eat = true;
            return;
        }
        if key == ' ' {
            ed_complete_now();
            ed_sig_help();   // inside a call it comes back too
            return;
        }
        if key == 'P' && shift { palette_open(); return; }
        if key == 'P' { pick_open(); return; }
        if key == 'N' && mods == MOD_CTRL {
            ed_new_untitled();
            return;
        }
        if key == ',' && !shift { settings_open(); return; }
        if key == 'T' { sym_open(); return; }
        if key == 'F' && shift {
            // a selection on one line is the query, like Ctrl+F
            i64 qa = 0;
            i64 qb = 0;
            if ed_sel_range(&qa, &qb) && tb_line_of(qa) == tb_line_of(qb)
                && qb - qa <= SEARCH_QUERY_MAX {
                noinit u8[SEARCH_QUERY_MAX] qbuf;
                tb_copy(qa, &qbuf[0], qb - qa);
                search_open_with(str_from(&qbuf[0], cast(i32, qb - qa)));
            } else {
                search_open_view();
            }
            return;
        }
        // the sidebar's two views, on VS Code's shortcuts: the file tree
        // (Ctrl+E, and Ctrl+Shift+E, VS Code's Explorer chord) and the
        // files git says have changed. Either tree chord closes the
        // project search view first.
        if key == 'E' { sidebar_show(false); return; }
        if key == 'G' && shift { sidebar_show(true); return; }
        // replace: the reference's Ctrl+H, and its Cmd+Option+F on macOS,
        // where Cmd+H hides the application
        if (key == 'H' && mods == MOD_CTRL) || (key == 'F' && mods == (MOD_CTRL | MOD_ALT)) {
            find_open_replace();
            return;
        }
        if key == 'F' { find_open(); return; }
        // zoom; Ctrl++ is the same key as Ctrl+= with Shift on most layouts
        if key == '=' && (mods == MOD_CTRL || mods == (MOD_CTRL | MOD_SHIFT)) { ed_zoom_key(g_zoom + 1); return; }
        if mods == MOD_CTRL && key == '-' { ed_zoom_key(g_zoom - 1); return; }
        if mods == MOD_CTRL && key == '0' { ed_zoom_key(0); return; }
        if key == 'S' { ed_save(); return; }
        if key == 'K' && mods == MOD_CTRL {
            // the reference's chord prefix: the next key completes it
            chord_k = true;
            ed_status("(ctrl+k) o folder, r recent, f new file, n window, w switcher, x restart, t terminal, p colors, s status bar, d problem underlines, m smooth scrolling, enter keep");
            chord_hint_up = true;
            plat_damage();
            return;
        }
        if key == 'Q' {
            if app_close() {
                lsp_stop();
                plat_quit();
            }
            return;
        }
        if key == 'A' { ed_select_all(); return; }
        if key == 'C' {
            if g_bsel && diff_on {
                base_copy();
                return;
            }
            ed_copy();
            return;
        }
        if key == 'X' { ed_cut(); return; }
        if key == 'V' {
            if ed_term_active() >= 0 { ed_term_paste(); return; }
            ed_paste();
            return;
        }
        if key == 'Z' {
            if shift { ed_redo(); } else { ed_undo(); }
            return;
        }
        if key == 'Y' { ed_redo(); return; }
        if key == 'K' && shift { ed_delete_lines(); return; }
        // ctrl+w closes what the pane shows, the buffer or the shell,
        // and the pane stays for the next thing; ctrl+shift+w closes
        // the pane, what it showed staying open
        if key == 'W' {
            if shift {
                if !ed_pane_hide() {
                    ed_warn("the last pane stays: ctrl+w closes what it shows");
                    plat_damage();
                }
                return;
            }
            ed_close_shown();
            return;
        }
        // the group commands take the keyboard back to the editor, as the
        // reference's do: a tree or search view that had it lets go,
        // even when the pane asked for is the active one already
        if key == 92 {   // backslash
            tree_focus = false;
            search_focus = false;
            ed_pane_split();
            return;
        }
        if key >= '1' && key <= '3' {
            tree_focus = false;
            search_focus = false;
            if key - '1' < pane_cols() { ed_pane_focus(key - '1'); }
            plat_damage();
            return;
        }
        if key == '/' || key == '7' { ed_toggle_comment(); return; }
        if key == K_DELETE { multi_apply(OP_DELWR); return; }
        if key == K_HOME {
            cur_collapse();
            sel_move_begin(shift);
            cur_line = 0;
            cur_col = 0;
            goal_vcol = -1;
            after_move();
            return;
        }
        if key == K_END {
            cur_collapse();
            sel_move_begin(shift);
            cur_line = tb.nlines - 1;
            cur_col = line_len(cur_line);
            goal_vcol = -1;
            after_move();
            return;
        }
        return;
    }
    if (mods & MOD_ALT) != 0 && (key == K_UP || key == K_DOWN) {
        i32 dir = 1;
        if key == K_UP { dir = -1; }
        if shift { ed_copy_lines(dir); } else { ed_move_lines(dir); }
        return;
    }
    if key == K_LEFT {
        op_shift = shift;
        multi_apply(OP_LEFT);
        return;
    }
    if key == K_RIGHT {
        op_shift = shift;
        multi_apply(OP_RIGHT);
        return;
    }
    if key == K_F12 {
        if shift { ed_find_refs(); } else { ed_goto_def(); }
        return;
    }
    if key == K_F1 && mods == 0 { palette_open(); return; }
    if key == K_UP {
        op_shift = shift;
        multi_apply(OP_UP);
        return;
    }
    if key == K_DOWN {
        op_shift = shift;
        multi_apply(OP_DOWN);
        return;
    }
    if key == K_PGUP { cur_collapse(); sel_move_begin(shift); mv_page(-1); return; }
    if key == K_PGDN { cur_collapse(); sel_move_begin(shift); mv_page(1); return; }
    if key == K_HOME {
        op_shift = shift;
        multi_apply(OP_HOME);
        return;
    }
    if key == K_END {
        op_shift = shift;
        multi_apply(OP_END);
        return;
    }
    if key == K_DELETE { multi_apply(OP_DELETE); return; }
    if key == K_ESCAPE {
        // one Escape drops the extra cursors, the next drops the
        // selection, so neither is lost by reflex. Signature help goes
        // first, as the completion list did before this. A request still
        // in flight is dropped too, so its reply does not reopen it.
        bool sig_was_on = sig_on;
        ed_sig_hide();
        if sig_was_on { return; }
        if g_ncur > 0 {
            cur_collapse();
            return;
        }
        sel_clear();
        plat_damage();
    }
}

void app_mouse(i32 x, i32 y, i32 btn, bool down, i32 mods) {
    // the explode view takes every press while it is up: a tile opens,
    // anywhere else returns
    if explode_on {
        if down && btn == 0 { explode_mouse(x, y); }
        return;
    }
    if calls_on {
        if down && btn == 0 { calls_mouse(x, y); }
        return;
    }
    ed_hover_hide();
    cmp_close();
    if !down {
        if btn == 0 {
            g_div_drag = -1;
            g_text_drag = false;
            drag_scroll_stop();
        }
        if image_dragging() {
            image_drag_end();
            return;
        }
        if g_tsel_drag {
            term_sel_end();
            plat_damage();
            return;
        }
        if g_bsel_drag {
            g_bsel_drag = false;
            return;
        }
        if g_panes[g_pane_active].kind == PANE_TERM && x >= content_left()
            && y >= pane_doc_top(g_pane_active) && y < ed_pane_y1(g_pane_active) {
            term_mouse_at(g_panes[g_pane_active].term, x, y, btn, false, mods);
        }
        return;
    }
    // the context menu: a press on an entry runs it, any other closes
    // the menu, and only a right press goes on to open the next one
    if menu_on {
        if menu_press(x, y) || btn != 1 { return; }
    }
    // a name being typed in the tree: a press anywhere else commits it
    if tree_edit_on() {
        if tree_edit_hit(x, y) { return; }
        tree_edit_blur();
    }
    // The right button in a terminal pane is the console's: it copies
    // the selection when there is one and clears it, and pastes when
    // there is none, which is what conhost's quick edit and Windows
    // Terminal both do. A child that asked for the mouse gets the click
    // instead, unless Shift is held, the rule the drag already follows.
    if btn == 1 && x >= content_left() && y < g_h - status_h() {
        i32 rp = pane_at(x, y);
        if g_panes[rp].kind == PANE_TERM && y >= pane_doc_top(rp) {
            if rp != g_pane_active { ed_pane_focus(rp); }
            i32 rt = g_panes[rp].term;
            if term_mouse_mode(rt) != 0 && (mods & MOD_SHIFT) == 0 {
                term_mouse_at(rt, x, y, btn, true, mods);
            } else if ed_term_sel_on(rt) {
                ed_term_copy();
                ed_term_sel_clear();
            } else {
                ed_term_paste();
            }
            plat_damage();
            return;
        }
    }
    // the right button on the file tree: the context menu of the row
    // under it
    if btn == 1 && tree_on && !search_on && x < content_left() && pane_div_at(x, y) < 0 {
        find_close();
        if !overlay_active() { ignore tree_right_click(x, y); }
        return;
    }
    if btn != 0 { return; }
    if ask_on {
        ask_mouse(x, y);
        return;
    }
    if notice_on {
        i32 nx0 = 0;
        i32 ny0 = 0;
        i32 nx1 = 0;
        i32 ny1 = 0;
        ed_notice_rect(&nx0, &ny0, &nx1, &ny1);
        if x >= nx0 && x < nx1 && y >= ny0 && y < ny1 {
            ed_notice_close();
            return;
        }
    }
    if palette_on { palette_mouse(x, y); return; }
    if pick_on { pick_mouse(x, y); return; }
    if sym_on { sym_mouse(x, y); return; }
    if switcher_on { switcher_mouse(x, y); return; }
    if find_mouse(x, y) { return; }
    i32 dv = -1;
    if ed_diff_revert_hit(x, y) < 0 { dv = pane_div_at(x, y); }
    if dv >= 0 {
        g_div_drag = dv;
        return;
    }
    if x < content_left() {
        find_close();
        if search_on {
            search_mouse(x, y);
        } else {
            tree_mouse(x, y);
        }
        return;
    }
    search_focus = false;
    tree_focus = false;
    find_close();
    i32 mp = pane_at(x, y);
    if diff_on && mp == 0 {
        if y >= pane_doc_top(0) {
            i64 bnow = plat_time_us();
            bool bagain = (mods & MOD_SHIFT) == 0 && bnow - g_click_us < DBLCLICK_US
                && x - g_click_x <= DBLCLICK_PX && g_click_x - x <= DBLCLICK_PX
                && y - g_click_y <= DBLCLICK_PX && g_click_y - y <= DBLCLICK_PX;
            g_click_us = bnow;
            g_click_x = x;
            g_click_y = y;
            if bagain { g_click_n++; } else { g_click_n = 1; }
            i32 clicks = g_click_n;
            if clicks >= 3 { g_click_n = 0; }
            base_sel_press(x, y, clicks);
        }
        plat_damage();
        return;
    }
    base_sel_clear();
    i32 rv = ed_diff_revert_hit(x, y);
    if rv >= 0 {
        if mp != g_pane_active { ed_pane_focus(mp); }
        ed_diff_revert(rv);
        return;
    }
    if mp != g_pane_active { ed_pane_focus(mp); }
    if g_panes[g_pane_active].kind == PANE_TERM {
        if y >= doc_top() {
            i32 tc = 0;
            i32 tr = 0;
            ed_term_cell_at(x, y, &tc, &tr);
            // a problem row in the build pane opens its place
            if g_panes[g_pane_active].term == build_term() && build_click_row(tr) { return; }
            i32 pt = g_panes[g_pane_active].term;
            if term_mouse_mode(pt) != 0 && (mods & MOD_SHIFT) == 0 {
                term_mouse(pt, tc, tr, btn, true, mods);
            } else {
                // a selection starts here; a click without a drag only clears
                term_sel_begin(pt, x, y);
            }
        }
        plat_damage();
        return;
    }
    if g_img >= 0 {
        if y >= doc_top() { image_drag_begin(g_img, x, y); }
        plat_damage();
        return;
    }
    if y < doc_top() {
        // the pane's banner: focus it, do not move the caret. The diff's
        // change arrows live there and are the exception.
        i32 ar = ed_diff_arrow_hit(x, y);
        if ar >= 0 { ed_diff_jump(ar == 0); }
        plat_damage();
        return;
    }
    if (mods & MOD_CTRL) != 0 {
        caret_to_point(x, y);
        sel_clear();
        goal_vcol = -1;
        after_move();
        ed_goto_def();
        return;
    }
    if (mods & MOD_ALT) != 0 {
        // alt+click drops another cursor where it lands
        i32 kl = cur_line;
        i64 kc = cur_col;
        bool ks = sel_active;
        i64 ka = sel_anchor;
        caret_to_point(x, y);
        i64 at = cur_abs();
        cur_line = kl;
        cur_col = kc;
        sel_active = ks;
        sel_anchor = ka;
        cur_add(at, at, false);
        return;
    }
    undo_break = true;
    g_text_drag = true;
    bool extend = (mods & MOD_SHIFT) != 0;
    i64 now = plat_time_us();
    bool again = !extend && now - g_click_us < DBLCLICK_US
        && x - g_click_x <= DBLCLICK_PX && g_click_x - x <= DBLCLICK_PX
        && y - g_click_y <= DBLCLICK_PX && g_click_y - y <= DBLCLICK_PX;
    g_click_us = now;
    g_click_x = x;
    g_click_y = y;
    if again { g_click_n++; } else { g_click_n = 1; }
    if g_click_n == 2 {
        cur_collapse();
        caret_to_point(x, y);
        i32 ws = 0;
        i32 we = 0;
        if word_bounds(&ws, &we) {
            sel_set_anchor(tb_line_start(cur_line) + ws);
            cur_col = we;
        } else {
            sel_clear();
        }
        goal_vcol = -1;
        after_move();
        return;
    }
    if g_click_n == 3 {
        // the whole line with its break, the caret at the next line's
        // start; a fourth press starts over
        g_click_n = 0;
        cur_collapse();
        caret_to_point(x, y);
        i32 l = cur_line;
        sel_set_anchor(tb_line_start(l));
        if l + 1 < tb.nlines {
            cur_line = l + 1;
            cur_col = 0;
        } else {
            cur_col = line_len(l);
        }
        goal_vcol = -1;
        after_move();
        return;
    }
    if extend && !sel_active {
        sel_anchor = cur_abs();
        sel_active = true;
    }
    cur_collapse();
    caret_to_point(x, y);
    if !extend {
        // empty selection armed for dragging
        sel_anchor = cur_abs();
        sel_active = true;
    }
    goal_vcol = -1;
    after_move();
}

void app_mouse_move(i32 x, i32 y) {
    g_damage_win = g_win;
    app_mouse_move_run(x, y);
    g_damage_win = -1;
}

private void app_mouse_move_run(i32 x, i32 y) {
    if pick_on || palette_on { return; }
    if g_div_drag == 0 {
        tree_set_w(x);
        plat_damage();
        return;
    }
    // the bottom pane's top edge: its share of the height follows
    if g_div_drag == DIV_BOTTOM {
        i32 area = g_h - status_h();
        if !g_bottom || area < 1 {
            g_div_drag = -1;
            return;
        }
        f32 f = cast(f32, area - y) / cast(f32, area);
        if f < 0.05f { f = 0.05f; }
        if f > 0.95f { f = 0.95f; }
        if f != g_bottom_frac {
            g_bottom_frac = f;
            ed_term_fit();
            plat_damage();
        }
        return;
    }
    // g_pane_div[pane_cols()] is the terminator and must stay 1.0, so a
    // drag that outlived its divider (the pane count changed under it)
    // has nothing left to move
    if g_div_drag >= pane_cols() {
        g_div_drag = -1;
        return;
    }
    if g_div_drag > 0 {
        i32 left = content_left();
        f32 w = cast(f32, g_w - left);
        if w < 1.0f { return; }
        f32 minw = cast(f32, 8 * font_cell_w) / w;
        f32 d = cast(f32, x - left) / w;
        f32 lo = g_pane_div[g_div_drag - 1] + minw;
        f32 hi = g_pane_div[g_div_drag + 1] - minw;
        // Too narrow for both neighbours to keep the minimum: the two
        // clamps would disagree and the second would win, putting the
        // divider left of its own neighbour and inverting the pane.
        // Halve what there is instead.
        if lo > hi {
            lo = (g_pane_div[g_div_drag - 1] + g_pane_div[g_div_drag + 1]) / 2.0f;
            hi = lo;
        }
        if d < lo { d = lo; }
        if d > hi { d = hi; }
        if d != g_pane_div[g_div_drag] {
            g_pane_div[g_div_drag] = d;
            ed_term_fit();
            plat_damage();
        }
        return;
    }
    if g_tsel_drag {
        drag_scroll_track(x, y);
        term_sel_drag(x, y);
        return;
    }
    if g_bsel_drag {
        base_sel_drag(x, y);
        return;
    }
    if image_dragging() {
        image_drag_to(x, y);
        return;
    }
    if g_panes[g_pane_active].kind == PANE_TERM {
        // a drag inside a terminal pane: the child gets it when it asked
        // for motion
        i32 t = g_panes[g_pane_active].term;
        if term_mouse_mode(t) == 1002 || term_mouse_mode(t) == 1003 {
            term_mouse_at(t, x, y, 32, true, 0);
        }
        return;
    }
    if g_text_drag {
        // the timer scrolls; the head stays on the rows in view
        drag_scroll_track(x, y);
        y = drag_scroll_clamp_y(y);
    }
    caret_to_point(x, y);
    goal_vcol = -1;
    after_move();
}

// pixel deltas applied directly; only sub-pixel fractions accumulate
void app_scroll(f32 dx, f32 dy, i32 x, i32 y) {
    g_damage_win = g_win;
    app_scroll_run(dx, dy, x, y);
    g_damage_win = -1;
}

// a wheel's notch: the same scroll, drawn gliding under smooth scrolling
void app_scroll_notch(f32 dx, f32 dy, i32 x, i32 y) {
    g_scroll_notch = true;
    app_scroll(dx, dy, x, y);
    g_scroll_notch = false;
}

private void app_scroll_run(f32 dx, f32 dy, i32 x, i32 y) {
    ed_hover_hide();
    cmp_close();
    if explode_on {
        explode_scroll(dy, x, y);
        return;
    }
    if calls_on { return; }
    if palette_on { palette_scroll(dy); return; }
    if pick_on { pick_scroll(dy); return; }
    if sym_on { sym_scroll(dy); return; }
    if switcher_on { switcher_scroll(dy); return; }
    menu_close();
    if x < content_left() {
        if search_on {
            search_scroll_by(dy);
        } else {
            tree_scroll_at(dy, y);
        }
        return;
    }
    i32 sp = pane_at(x, y);
    if g_panes[sp].kind == PANE_DOC && y >= pane_doc_top(sp) {
        i32 im = ed_buf_img(g_panes[sp].buf);
        if im >= 0 {
            image_scroll(im, dx, dy, x, y, g_scroll_notch);
            return;
        }
    }
    if g_panes[sp].kind == PANE_TERM {
        i32 t = g_panes[sp].term;
        // a terminal scrolls by whole lines; the fractions of a line a
        // trackpad sends carry over to the next event rather than each
        // moving a line of their own
        g_term_scroll_accum += dy;
        i32 lines = cast(i32, g_term_scroll_accum) / font_line_h;
        if lines == 0 { return; }
        g_term_scroll_accum -= cast(f32, lines * font_line_h);
        // up into the history; a child that asked for the mouse gets
        // the wheel as button 4/5 presses instead
        if term_mouse_mode(t) != 0 {
            i32 b = 4;
            if lines > 0 { b = 5; }
            term_mouse_at(t, x, y, b, true, 0);
        } else {
                term_view_set(t, term_view(t) - lines);
        }
        plat_damage();
        return;
    }
    if dx != 0.0f { pane_hscroll(sp, dx); }
    g_scroll_accum += dy;
    i32 step = cast(i32, g_scroll_accum);
    if step == 0 { return; }
    g_scroll_accum -= cast(f32, step);
    // the two sides of a diff are one view: the wheel over either of
    // them moves the pane that owns the scroll
    if diff_on && sp == 0 { sp = 1; }
    if sp != g_pane_active {
        pane_scroll(sp, step);
        return;
    }
    i32 before = scroll_y;
    scroll_set(scroll_y + step);
    if scroll_y != before {
        if g_scroll_notch { glide_step(g_pane_active, scroll_y - before, true); }
        ed_damage();
    }
}

void app_resize(i32 w, i32 h) {
    g_w = w;
    g_h = h;
    tree_viewport_changed();
    ed_term_fit();
    plat_damage();
}

void app_scale(i32 dpi) {
    if dpi == g_dpi || dpi <= 0 { return; }
    g_dpi = dpi;
    font_rescale();
}

// The fonts at the window's dpi times the zoom. The line height
// changes, so every scroll kept in pixels is converted to keep its top
// line: the loaded pane's, the other panes', and the buffers'.
private void font_rescale() {
    i32 old_lh = font_line_h;
    font_use(zoom_dpi(g_dpi));
    i32 lh = font_line_h;
    if old_lh > 0 && lh != old_lh {
        for i32 p = 0; p < g_npanes; p++ {
            if p == g_pane_loaded { continue; }
            g_panes[p].scroll_y = g_panes[p].scroll_y / old_lh * lh;
        }
        for i32 b = 0; b < g_nbufs; b++ {
            if b == g_buf_active { continue; }
            g_bufs[b].scroll_y = g_bufs[b].scroll_y / old_lh * lh;
        }
    }
    scroll_set(top_line * font_line_h);
    g_scroll_accum = 0.0f;
    ensure_visible();
    tree_viewport_changed();
    ed_term_fit();
    plat_damage();
}

// --- zoom ---------------------------------------------------------------
// The reference's window zoom: each level is 20% larger or smaller, and
// everything drawn grows with it, since every size derives from the
// dpi. The window's own dpi stays as the platform reports it; the fonts
// use the zoomed one. The level is window.zoomLevel in the settings.

const i32 ZOOM_MIN = -5;
const i32 ZOOM_MAX = 8;
private const f32 ZOOM_STEP = 1.2f;
private i32 g_zoom = 0;

i32 ed_zoom() {
    return g_zoom;
}

private i32 zoom_dpi(i32 dpi) {
    f32 f = 1.0f;
    for i32 i = 0; i < g_zoom; i++ { f = f * ZOOM_STEP; }
    for i32 i = 0; i > g_zoom; i-- { f = f / ZOOM_STEP; }
    i32 d = cast(i32, cast(f32, dpi) * f + 0.5f);
    if d < 1 { d = 1; }
    return d;
}

// the level from the settings, or from a key through them
void ed_zoom_set(i32 z) {
    if z < ZOOM_MIN { z = ZOOM_MIN; }
    if z > ZOOM_MAX { z = ZOOM_MAX; }
    if z == g_zoom { return; }
    g_zoom = z;
    font_rescale();
}

// Ctrl+= / Ctrl+- / Ctrl+0: the level is written to the settings file,
// which applies it, as the theme picker does
private void ed_zoom_key(i32 z) {
    if z < ZOOM_MIN { z = ZOOM_MIN; }
    if z > ZOOM_MAX { z = ZOOM_MAX; }
    settings_set_zoom(z);
    noinit u8[32] m;
    str pre = "zoom ";
    memcpy(&m[0], pre.data, pre.len);
    i32 n = pre.len;
    i32 pct = cast(i32, cast(f32, zoom_dpi(DPI_BASE)) * 100.0f / cast(f32, DPI_BASE) + 0.5f);
    n += fmt_i32(&m[n], pct);
    m[n] = '%';
    n++;
    ed_status(str_from(&m[0], n));
}

void app_focus(bool on) {
    g_focused = on;
    if on {
        g_win_key = g_win;   // the driver routed the window before the report
        reset_blink();
    } else {
        if timer_on {
            plat_kill_timer(BLINK_TIMER);
            timer_on = false;
        }
        caret_on = false;
        // a drag the window no longer sees the end of
        g_text_drag = false;
        drag_scroll_stop();
        // a menu closes when the window loses the focus, as the system's do
        menu_close();
        app_session_save();
    }
    plat_damage();
}

void app_timer(i32 id) {
    if id == NOTICE_TIMER {
        notice_timer();
        return;
    }
    if id == BRACE_TIMER {
        brace_timer();
        return;
    }
    if id == WATCH_TIMER {
        watch_timer();
        return;
    }
    if id == DRAG_SCROLL_TIMER {
        drag_scroll_tick();
        return;
    }
    if id == CMP_TIMER {
        ed_cmp_untouch();
        // typing may have carried the caret into a comment or string
        // before the timer settled; the automatic ask stops there
        if !ed_caret_in_comment() { ed_cmp_ask(); }
        return;
    }
    if id == HOVER_TIMER {
        plat_kill_timer(HOVER_TIMER);
        hover_timer_on = false;
        ed_hover_ask();
        return;
    }
    if id == GIT_TIMER {
        ed_git_untouch();
        git_recompute();
        plat_damage();
        return;
    }
    if id == LSP_SYNC_TIMER {
        // one shot: disarm first, so a push that starts nothing new
        // leaves no timer behind
        ed_lsp_untouch();
        ed_lsp_push();
        return;
    }
    if id == SEARCH_TIMER {
        search_timer();
        return;
    }
    if id == SEM_TIMER {
        // typing paused: push any pending edit, then ask for tokens once
        ed_sem_untouch();
        ed_lsp_flush();
        if g_has_path && g_lex_on && g_lex_lang == LANG_MINC {
            lsp_request_semantic(str_from(&g_path[0], g_path_len));
        }
        return;
    }
    if id != BLINK_TIMER { return; }
    caret_on = !caret_on;
    blink_count++;
    if blink_count > BLINK_TOGGLES {
        // idle: stop blinking, stop waking up
        plat_kill_timer(BLINK_TIMER);
        timer_on = false;
        caret_on = true;
    }
    // only the focused window draws a blinking caret
    plat_damage_window(g_win_key);
}

// the platform asks before closing; any dirty buffer refuses once
bool app_close() {
    bool dirty = bufs_dirty();
    if !dirty || g_close_armed {
        // No git_wait here. Waiting for a worker that may never finish
        // would make quitting hang exactly as opening a file did; the
        // process is going anyway. The shells go with it: a running
        // child is not a dirty buffer, and the first cut does not ask.
        app_session_save();
        ed_term_close_all();
        watch_stop();
        return true;
    }
    g_close_armed = true;
    ed_warn("unsaved changes: ctrl+s to save, close again to discard");
    return false;
}
