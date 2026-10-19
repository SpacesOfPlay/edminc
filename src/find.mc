// find.mc - find and replace in the file (the ctrl+f / ctrl+h widget).
// The query lives in the widget; matches select through ed_set_sel.
// Search is a chunked case-insensitive scan over the buffer via
// tb_copy, so the gap never shows. Enter/Down = next, Up or Shift+Enter
// = previous, Esc = close. The query and the replacement are UiFields,
// so the line's own keys edit them; the page keys and the chords the
// widget does not take close it and fall through. In the replacement,
// Enter replaces the match and selects the next one; Ctrl+Enter (Cmd+
// Enter on macOS) in either field replaces them all as one edit.

const i32 FIND_QUERY_MAX = 256;
private const i32 FIND_CHUNK = 65536;
private const i32 FIND_COLS = 30;        // query cells in the widget

bool find_on = false;

private u8[FIND_QUERY_MAX] fq;
private u8[FIND_QUERY_MAX] fq_low;   // query folded to lower case
private i32 fq_len = 0;
private UiField fq_field;

private UiField* find_field() {
    ui_field_bind(&fq_field, &fq[0], &fq_len, FIND_QUERY_MAX);
    return &fq_field;
}

// the replace row: shown, and whether its field has the keyboard
bool find_replace_on = false;
bool find_in_replace = false;
private u8[FIND_QUERY_MAX] rq;
private i32 rq_len = 0;
private UiField rq_field;

private UiField* find_rfield() {
    ui_field_bind(&rq_field, &rq[0], &rq_len, FIND_QUERY_MAX);
    return &rq_field;
}

// the field that has the keyboard
private UiField* find_active_field() {
    if find_replace_on && find_in_replace { return find_rfield(); }
    return find_field();
}

// the query changed under the field: refold and rescan
private void find_query_changed() {
    for i32 i = 0; i < fq_len; i++ { fq_low[i] = ascii_lower(fq[i]); }
    find_refresh();
}
private i64 find_base = 0;      // search origin: caret at open
private i64 find_total = 0;
private i64 find_idx = 0;       // 1-based position of the current match
private u8* fs_buf = null;

// --- scan ------------------------------------------------------------

// first match at offset i in s[0, n), or -1
private i32 find_in_mem(u8* s, i32 n, i32 at) {
    i32 last = n - fq_len;
    for i32 i = at; i <= last; i++ {
        i32 k = 0;
        while k < fq_len && ascii_lower(s[i + k]) == fq_low[k] { k++; }
        if k == fq_len { return i; }
    }
    return -1;
}

// the chunk at pos into fs_buf: FIND_CHUNK bytes plus the qlen-1
// overlap that lets a match straddle the edge; its length
private i64 find_chunk(i64 pos, i64 len) {
    if fs_buf == null { fs_buf = alloc<u8>(FIND_CHUNK + FIND_QUERY_MAX); }
    i64 n = len - pos;
    if n > FIND_CHUNK + fq_len - 1 { n = FIND_CHUNK + fq_len - 1; }
    tb_copy(pos, fs_buf, n);
    return n;
}

// first match at start or later, or -1; chunks overlap by qlen-1 so
// matches straddling a chunk edge are seen
private i64 find_scan_next(i64 start) {
    if fq_len == 0 { return -1; }
    i64 len = tb_len();
    i64 pos = start;
    if pos < 0 { pos = 0; }
    while pos + fq_len <= len {
        i64 n = find_chunk(pos, len);
        i32 hit = find_in_mem(fs_buf, cast(i32, n), 0);
        if hit >= 0 { return pos + hit; }
        pos += FIND_CHUNK;
    }
    return -1;
}

// last match before `before`, or -1
private i64 find_scan_prev(i64 before) {
    if fq_len == 0 { return -1; }
    i64 len = tb_len();
    if before > len { before = len; }
    i64 best = -1;
    i64 pos = 0;
    while pos + fq_len <= len {
        i64 n = find_chunk(pos, len);
        i32 i = 0;
        while true {
            i32 hit = find_in_mem(fs_buf, cast(i32, n), i);
            if hit < 0 { break; }
            if pos + hit >= before { return best; }
            best = pos + hit;
            i = hit + 1;
        }
        pos += FIND_CHUNK;
    }
    return best;
}

// non-overlapping total, and the 1-based index of the match at mpos.
// Each chunk counts only matches STARTING inside it; the qlen-1
// overlap lets them extend past the edge.
private void find_count(i64 mpos) {
    find_total = 0;
    find_idx = 0;
    if fq_len == 0 { return; }
    i64 len = tb_len();
    i64 pos = 0;
    while pos + fq_len <= len {
        i64 n = find_chunk(pos, len);
        i32 n32 = cast(i32, n);
        i32 start_lim = FIND_CHUNK;
        if n32 < start_lim { start_lim = n32; }
        i32 i = 0;
        while true {
            i32 hit = find_in_mem(fs_buf, n32, i);
            if hit < 0 || hit >= start_lim { break; }
            find_total++;
            if mpos >= 0 && pos + hit <= mpos { find_idx = find_total; }
            i = hit + fq_len;
        }
        pos += FIND_CHUNK;
    }
}

i32 find_qlen() {
    return fq_len;
}

// match starts within s[0, n), for line highlighting; returns count
i32 find_marks(u8* s, i32 n, i32* out, i32 cap) {
    if !find_on || fq_len == 0 { return 0; }
    i32 c = 0;
    i32 i = 0;
    while c < cap {
        i32 hit = find_in_mem(s, n, i);
        if hit < 0 { break; }
        out[c] = hit;
        c++;
        i = hit + fq_len;
    }
    return c;
}

// --- navigation ------------------------------------------------------

private void find_refresh() {
    if fq_len == 0 {
        find_total = 0;
        find_idx = 0;
        plat_damage();
        return;
    }
    i64 m = find_scan_next(find_base);
    if m < 0 { m = find_scan_next(0); }
    find_count(m);
    if m >= 0 { ed_set_sel(m, m + fq_len); }
    plat_damage();
}

private void find_next() {
    if find_total == 0 { return; }
    i64 m = find_scan_next(ed_caret_abs());
    if m < 0 { m = find_scan_next(0); }
    if m < 0 { return; }
    find_idx++;
    if find_idx > find_total { find_idx = 1; }
    ed_set_sel(m, m + fq_len);
    plat_damage();
}

private void find_prev() {
    if find_total == 0 { return; }
    i64 a = ed_caret_abs() - fq_len;
    i64 sa = 0;
    i64 sb = 0;
    if ed_sel_range(&sa, &sb) { a = sa; }
    i64 m = find_scan_prev(a);
    if m < 0 { m = find_scan_prev(tb_len() + 1); }
    if m < 0 { return; }
    find_idx--;
    if find_idx < 1 { find_idx = find_total; }
    ed_set_sel(m, m + fq_len);
    plat_damage();
}

// --- replace -------------------------------------------------------

private const i64 FIND_ALL_MAX = 0x3FFFFFFF;

// the query matches at pos, ignoring case
private bool find_is_match(i64 pos) {
    if fq_len == 0 || pos < 0 || pos + fq_len > tb_len() { return false; }
    noinit u8[FIND_QUERY_MAX] m;
    tb_copy(pos, &m[0], fq_len);
    for i32 i = 0; i < fq_len; i++ {
        if ascii_lower(m[i]) != fq_low[i] { return false; }
    }
    return true;
}

// The selected match becomes the replacement and the next match is
// selected. A selection that is not a match only moves to the next
// one, as the reference does, so the first press shows what the
// second replaces.
void find_replace_one() {
    if fq_len == 0 { return; }
    i64 a = 0;
    i64 b = 0;
    if ed_sel_range(&a, &b) && b - a == fq_len && find_is_match(a) {
        if !ed_find_replace(a, fq_len, &rq[0], rq_len) {
            ed_status("this buffer is read-only");
            plat_damage();
            return;
        }
    }
    // from the caret, which is after the replacement, so a replacement
    // that contains the query is not found again
    i64 m = find_scan_next(ed_caret_abs());
    if m < 0 { m = find_scan_next(0); }
    find_count(m);
    if m >= 0 { ed_set_sel(m, m + fq_len); }
    plat_damage();
}

private void find_out_put(u8** buf, i32* len, i32* cap, u8* p, i32 n) {
    if n <= 0 { return; }
    if *len + n > *cap {
        i32 ncap = (*len + n) * 2 + 256;
        u8* nb = alloc<u8>(ncap);
        if *buf != null {
            memcpy(nb, *buf, *len);
            free(*buf);
        }
        *buf = nb;
        *cap = ncap;
    }
    memcpy(*buf + *len, p, n);
    *len += n;
}

// Every match, in one edit from the first match to the end of the
// last, so one undo puts them all back.
void find_replace_all() {
    if fq_len == 0 { return; }
    i64 len = tb_len();
    if len > FIND_ALL_MAX {
        ed_status("the file is too large to replace in at once");
        plat_damage();
        return;
    }
    i32 n = cast(i32, len);
    u8* src = alloc<u8>(len + 1);
    if n > 0 { tb_copy(0, src, len); }
    u8* out = null;
    i32 on = 0;
    i32 ocap = 0;
    i32 first = -1;
    i32 end = 0;
    i32 count = 0;
    i32 i = 0;
    while true {
        i32 hit = find_in_mem(src, n, i);
        if hit < 0 { break; }
        if first < 0 {
            first = hit;
            end = hit;
        }
        find_out_put(&out, &on, &ocap, src + end, hit - end);
        find_out_put(&out, &on, &ocap, &rq[0], rq_len);
        end = hit + fq_len;
        i = end;
        count++;
    }
    free(src);
    if count == 0 { return; }
    bool ok = ed_find_replace(first, end - first, out, on);
    if out != null { free(out); }
    if !ok {
        ed_status("this buffer is read-only");
        plat_damage();
        return;
    }
    ed_set_sel(first, first);
    find_count(-1);
    noinit u8[64] msg;
    str pre = "replaced ";
    memcpy(&msg[0], pre.data, pre.len);
    i32 mn = pre.len + fmt_i32(&msg[pre.len], count);
    str post = " occurrences";
    if count == 1 { post = " occurrence"; }
    memcpy(&msg[mn], post.data, post.len);
    mn += post.len;
    ed_status(str_from(&msg[0], mn));
    plat_damage();
}

// --- open/close + input ----------------------------------------------

// the query persists across close; a selection re-seeds it
void find_open() {
    i64 a = 0;
    i64 b = 0;
    if ed_sel_range(&a, &b) && b - a <= FIND_QUERY_MAX
        && tb_line_of(a) == tb_line_of(b) {
        fq_len = cast(i32, b - a);
        tb_copy(a, &fq[0], fq_len);
        for i32 i = 0; i < fq_len; i++ { fq_low[i] = ascii_lower(fq[i]); }
        find_base = a;
    } else {
        find_base = ed_caret_abs();
    }
    find_on = true;
    find_replace_on = false;
    find_in_replace = false;
    // one line has the keyboard: the search box and the tree let go
    search_focus = false;
    tree_focus = false;
    ui_field_end(find_field());
    find_refresh();
}

// Ctrl+H: the widget with its replace row. The replacement has the
// keyboard when there is a query to replace, the query otherwise.
void find_open_replace() {
    find_open();
    find_replace_on = true;
    find_in_replace = fq_len > 0;
    ui_field_end(find_rfield());
    plat_damage();
}

void find_close() {
    if !find_on { return; }
    find_on = false;
    plat_damage();
}

private void find_toggle_replace() {
    find_replace_on = !find_replace_on;
    find_in_replace = find_replace_on && fq_len > 0;
    if find_in_replace { ui_field_end(find_rfield()); }
    plat_damage();
}

// the replacement changed, or the query did and the matches follow it
private void find_field_changed() {
    if find_replace_on && find_in_replace {
        plat_damage();
    } else {
        find_query_changed();
    }
}

void find_char(u32 cp) {
    if cp == 13 || cp == 10 {
        // Enter carries no modifiers of its own; the ones held decide.
        // Ctrl+Enter arrives as a line feed on Windows, and Ctrl+Alt+Enter
        // not at all, so the primary modifier alone is replace-all.
        i32 held = ed_mods_held();
        if find_replace_on && (cp == 10 || (held & MOD_CTRL) != 0) {
            find_replace_all();
        } else if find_replace_on && find_in_replace {
            find_replace_one();
        } else if (held & MOD_SHIFT) != 0 {
            find_prev();
        } else {
            find_next();
        }
        return;
    }
    if ui_field_char(find_active_field(), cp) { find_field_changed(); }
}

// true = consumed; false = the widget closed and the key falls
// through. Only the page keys and foreign chords fall through: every
// printable keydown precedes a char event that belongs to the query,
// so unknown keys must be consumed, not treated as leave-the-widget.
bool find_key(i32 key, i32 mods) {
    if key == 'F' && mods == MOD_CTRL { find_open(); return true; }
    if (key == 'H' && mods == MOD_CTRL) || (key == 'F' && mods == (MOD_CTRL | MOD_ALT)) {
        find_toggle_replace();
        return true;
    }
    if key == '1' && mods == (MOD_CTRL | MOD_SHIFT) && find_replace_on {
        find_replace_one();
        return true;
    }
    // undo and redo take back a replacement and keep the widget, as
    // the reference does; the count follows the text
    if (key == 'Z' && (mods == MOD_CTRL || mods == (MOD_CTRL | MOD_SHIFT))) || (key == 'Y' && mods == MOD_CTRL) {
        ed_find_undo(key == 'Y' || (mods & MOD_SHIFT) != 0);
        find_count(ed_caret_abs() - fq_len);
        plat_damage();
        return true;
    }
    if key == K_TAB && find_replace_on {
        find_in_replace = !find_in_replace;
        ui_field_end(find_active_field());
        plat_damage();
        return true;
    }
    bool changed = false;
    if ui_field_key(find_active_field(), key, mods, &changed) {
        if changed { find_field_changed(); } else { plat_damage(); }
        return true;
    }
    if (mods & MOD_CTRL) != 0 {
        find_close();
        return false;
    }
    if key == K_ESCAPE { find_close(); return true; }
    if key == K_UP { find_prev(); return true; }
    if key == K_DOWN { find_next(); return true; }
    if key == K_PGUP || key == K_PGDN {
        find_close();
        return false;
    }
    return true;
}

// --- layout and the pointer -------------------------------------------
// The geometry derives from the line height so it scales with DPI; the
// fractions come from capture measurements of the reference widget
// (doc/TECH_DOC.md "UI system"): input inner height lh + 2*(lh/6), text
// inset lh/3, panel gaps lh/5 above / lh/4 below the focus ring, right
// offset 1.5*lh from the window edge. The renderer and the click test
// read the same layout.

private const u32 ICO_FIND_CHEV_RIGHT = 0xEAB6;
private const u32 ICO_FIND_CHEV_DOWN = 0xEAB4;
private const u32 ICO_FIND_REPLACE = 0xEB3D;
private const u32 ICO_FIND_REPLACE_ALL = 0xEB3C;

private struct FindLayout {
    i32 x;
    i32 w;
    i32 h;
    i32 chev_w;     // the replace toggle's column, the panel's height
    i32 ring_w;     // each input's outer width
    i32 row1;       // the query's top
    i32 row2;       // the replacement's top
    i32 btn_w;      // the replace buttons, square, right of the replacement
    bool btns;      // the buttons fit
}

private FindLayout find_layout() {
    FindLayout L;
    i32 cw = font_cell_w;
    i32 lh = font_line_h;
    i32 ip = ui_inset();
    i32 ih = ui_input_h();
    i32 gap_top = lh / 5;
    i32 gap_bot = lh / 4;
    i32 margin = lh / 3;             // ring to count text, and right edge
    i32 right = lh + lh / 2;         // gap from the window's right edge
    L.chev_w = lh * 4 / 3;
    L.btn_w = ih;
    // The count column and the input ring are the elastic parts. A
    // window too narrow for the whole widget takes the count column
    // back first, then the ring; clamping only the panel would leave
    // the ring at full width and draw it past the window edge.
    i32 count_w = 12 * cw;
    i32 ring_w = FIND_COLS * cw + 2 * ip + 4;
    i32 fixed = L.chev_w + ip + margin;
    i32 w = fixed + ring_w + count_w;
    i32 max_w = g_w - right - 16;
    if w > max_w {
        i32 over = w - max_w;
        i32 give = count_w;
        if give > over { give = over; }
        count_w -= give;
        over -= give;
        if over > ring_w { ring_w = 0; } else { ring_w -= over; }
        w = fixed + ring_w + count_w;
    }
    if w > g_w - 4 { w = g_w - 4; }
    if w < 0 { w = 0; }
    if L.chev_w + ring_w > w {
        ring_w = w - L.chev_w;
        if ring_w < 0 { ring_w = 0; }
    }
    L.w = w;
    L.ring_w = ring_w;
    L.row1 = gap_top;
    L.row2 = gap_top + ih + gap_top;
    L.h = gap_top + ih + gap_bot;
    if find_replace_on { L.h = L.row2 + ih + gap_bot; }
    L.x = g_w - w - right;
    if L.x < 0 { L.x = 0; }
    L.btns = L.chev_w + ring_w + ip + 2 * L.btn_w <= w;
    return L;
}

// A press on the widget: the toggle, a field, a button. True when the
// press was the widget's; a press anywhere else closes it.
bool find_mouse(i32 x, i32 y) {
    if !find_on { return false; }
    FindLayout L = find_layout();
    if x < L.x || x >= L.x + L.w || y < 0 || y >= L.h { return false; }
    i32 ih = ui_input_h();
    i32 rx = L.x + L.chev_w;
    if x < rx {
        find_toggle_replace();
        return true;
    }
    if x < rx + L.ring_w {
        if y >= L.row1 && y < L.row1 + ih {
            find_in_replace = false;
            plat_damage();
        } else if find_replace_on && y >= L.row2 && y < L.row2 + ih {
            find_in_replace = true;
            plat_damage();
        }
        return true;
    }
    if find_replace_on && L.btns && y >= L.row2 && y < L.row2 + ih {
        i32 bx = rx + L.ring_w + ui_inset();
        if x >= bx && x < bx + L.btn_w {
            find_replace_one();
        } else if x >= bx + L.btn_w && x < bx + 2 * L.btn_w {
            find_replace_all();
        }
    }
    return true;
}

// an icon glyph centered on its ink in a w x h box
private void find_icon(u32 cp, i32 x, i32 y, i32 w, i32 h, u32 col) {
    i32 gw = 0;
    i32 gh = 0;
    i32 gx = 0;
    i32 gy = 0;
    font_glyph_box(cp, &gw, &gh, &gx, &gy);
    font_draw(cp, cast(f32, x + (w - gw) / 2 - gx), cast(f32, y + (h - gh) / 2 - gy), col);
}

// --- render ----------------------------------------------------------

void find_render() {
    if !find_on { return; }
    FindLayout L = find_layout();
    i32 ip = ui_inset();
    i32 ih = ui_input_h();
    i32 x = L.x;
    i32 rx = x + L.chev_w;

    ui_panel_top(x, L.w, L.h);
    bool in_q = !(find_replace_on && find_in_replace);
    ui_input_ex(rx, L.row1, L.ring_w, find_field(), "Find", caret_on && in_q, in_q);
    // the replace toggle, a column the panel's height
    u32 chev = ICO_FIND_CHEV_RIGHT;
    if find_replace_on { chev = ICO_FIND_CHEV_DOWN; }
    find_icon(chev, x, 0, L.chev_w, L.h, T_FG);

    noinit u8[48] cb;
    i32 cn = 0;
    if fq_len == 0 || find_total == 0 {
        str nr = "No results";
        memcpy(&cb[0], nr.data, nr.len);
        cn = nr.len;
    } else {
        cn = fmt_i32(&cb[0], cast(i32, find_idx));
        str mid = " of ";
        memcpy(&cb[cn], mid.data, mid.len);
        cn += mid.len;
        cn += fmt_i32(&cb[cn], cast(i32, find_total));
    }
    if cn > 0 {
        // left-aligned right after the input, in full foreground
        f32 cx = cast(f32, rx + L.ring_w + ip);
        f32 qy = cast(f32, ui_input_text_y(L.row1));
        ignore font_draw_ui_text(str_from(&cb[0], cn), cx, qy, cast(f32, g_w), T_FG);
    }

    if !find_replace_on { return; }
    ui_input_ex(rx, L.row2, L.ring_w, find_rfield(), "Replace", caret_on && !in_q, !in_q);
    if L.btns {
        // dimmed while there is nothing to replace
        u32 bc = T_FG;
        if find_total == 0 { bc = T_DIM; }
        i32 bx = rx + L.ring_w + ip;
        find_icon(ICO_FIND_REPLACE, bx, L.row2, L.btn_w, ih, bc);
        find_icon(ICO_FIND_REPLACE_ALL, bx + L.btn_w, L.row2, L.btn_w, ih, bc);
    }
}
