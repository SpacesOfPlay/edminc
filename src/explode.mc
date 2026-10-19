// explode.mc - the explode view: every open buffer and terminal at
// once, zoomed out in a grid over the window, to see them side by side
// and pick one.
// Ctrl+M toggles it. Arrows move, typing filters by name, Enter or a
// click opens the tile in the active pane, and Escape returns. This
// file holds the state, the input and the grid's layout; view.mc draws
// it (explode_render).

bool explode_on = false;

private const i32 EX_MAX = 128;
private const i32 EX_QUERY_MAX = 64;

// A tile is a buffer or a terminal: the buffers in slot order, then the
// terminals that have a child, as the switcher lists them.
const i32 EX_BUF = 0;
const i32 EX_TERM = 1;
private i32[EX_MAX] ex_kind;
private i32[EX_MAX] ex_id;    // a buffer slot or a terminal handle
private i32 ex_n = 0;
private i32 ex_sel = 0;
private u8[EX_QUERY_MAX] ex_q;
private i32 ex_qlen = 0;
private UiField ex_field;

// the grid as last laid out, for the keys and the mouse
private i32 ex_cols = 1;
private i32[EX_MAX] ex_tx;
private i32[EX_MAX] ex_ty;
private i32[EX_MAX] ex_tw;
private i32[EX_MAX] ex_th;

UiField* ex_field_at() {
    ui_field_bind(&ex_field, &ex_q[0], &ex_qlen, EX_QUERY_MAX);
    return &ex_field;
}

private u8 ex_lower(u8 c) {
    if c >= 'A' && c <= 'Z' { return cast(u8, c + 32); }
    return c;
}

// the query as a substring of the name, ignoring case
private bool ex_match(str name) {
    if ex_qlen == 0 { return true; }
    for i32 s = 0; s + ex_qlen <= name.len; s++ {
        bool m = true;
        for i32 k = 0; k < ex_qlen; k++ {
            if ex_lower(name.data[s + k]) != ex_lower(ex_q[k]) {
                m = false;
                break;
            }
        }
        if m { return true; }
    }
    return false;
}

// the tile's name: the buffer's file name, or the terminal's label
str explode_title(i32 i) {
    if i < 0 || i >= ex_n { return ""; }
    if ex_kind[i] == EX_TERM { return term_label(ex_id[i]); }
    return ed_buf_title(ex_id[i]);
}

private void ex_add(i32 kind, i32 id) {
    if ex_n == EX_MAX { return; }
    str name = ed_buf_title(id);
    if kind == EX_TERM { name = term_label(id); }
    if !ex_match(name) { return; }
    ex_kind[ex_n] = kind;
    ex_id[ex_n] = id;
    ex_n++;
}

private void ex_filter() {
    i32 wk = -1;
    i32 wi = -1;
    if ex_sel >= 0 && ex_sel < ex_n {
        wk = ex_kind[ex_sel];
        wi = ex_id[ex_sel];
    }
    ex_n = 0;
    for i32 b = 0; b < ed_buf_count(); b++ { ex_add(EX_BUF, b); }
    for i32 t = 0; t < TERM_MAX; t++ {
        if term_has_child(t) { ex_add(EX_TERM, t); }
    }
    ex_sel = 0;
    for i32 i = 0; i < ex_n; i++ {
        if ex_kind[i] == wk && ex_id[i] == wi { ex_sel = i; }
    }
}

// open on what the active pane shows: its terminal, or the buffer
void explode_open() {
    ex_qlen = 0;
    ex_sel = -1;
    ex_n = 0;
    ex_filter();
    if ex_n == 0 { return; }
    i32 wk = EX_BUF;
    i32 wi = ed_buf_active();
    if ed_term_active() >= 0 {
        wk = EX_TERM;
        wi = ed_term_active();
    }
    for i32 i = 0; i < ex_n; i++ {
        if ex_kind[i] == wk && ex_id[i] == wi { ex_sel = i; }
    }
    explode_on = true;
    plat_damage();
}

void explode_close() {
    if !explode_on { return; }
    explode_on = false;
    plat_damage();
}

void explode_toggle() {
    if explode_on {
        explode_close();
    } else {
        explode_open();
    }
}

// the selected buffer or terminal into the active pane
private void ex_pick() {
    if ex_n == 0 { return; }
    i32 k = ex_kind[ex_sel];
    i32 id = ex_id[ex_sel];
    explode_close();
    if k == EX_TERM {
        ed_show_term(id);
    } else {
        ed_show_buf(id);
    }
}

private void ex_move(i32 d) {
    if ex_n == 0 { return; }
    i32 s = ex_sel + d;
    if s < 0 { s = 0; }
    if s >= ex_n { s = ex_n - 1; }
    ex_sel = s;
    ed_damage();
}

// The arrows, Home and End move over the grid, ahead of the filter
// field, which keeps the typing and its editing keys.
void explode_key(i32 key, i32 mods) {
    if mods == 0 {
        if key == K_ESCAPE { explode_close(); return; }
        if key == K_LEFT { ex_move(-1); return; }
        if key == K_RIGHT { ex_move(1); return; }
        if key == K_UP { ex_move(0 - ex_cols); return; }
        if key == K_DOWN { ex_move(ex_cols); return; }
        if key == K_HOME { ex_move(0 - ex_n); return; }
        if key == K_END { ex_move(ex_n); return; }
    }
    bool changed = false;
    if ui_field_key(ex_field_at(), key, mods, &changed) {
        if changed { ex_filter(); }
        ed_damage();
    }
}

void explode_char(u32 cp) {
    if cp == 13 { ex_pick(); return; }
    if !ui_field_char(ex_field_at(), cp) { return; }
    ex_filter();
    ed_damage();
}

// the pointer over a tile selects it, as the arrows do; between the
// tiles the selection stays where it is
void explode_hover(i32 x, i32 y) {
    for i32 i = 0; i < ex_n; i++ {
        if x >= ex_tx[i] && x < ex_tx[i] + ex_tw[i] && y >= ex_ty[i] && y < ex_ty[i] + ex_th[i] {
            if i != ex_sel {
                ex_sel = i;
                ed_damage();
            }
            return;
        }
    }
}

// The wheel or the touchpad scrolls the buffer of the tile under the
// pointer, which it also selects, or the selected tile's between the
// tiles. By the same lines it would scroll in the editor, whatever the
// tile's scale; the buffer opens where it was scrolled to. Fractions of
// a pixel carry over, as in a pane.
// A terminal scrolls its history by whole lines, the fractions of a line
// carried over.
private f32 ex_scroll_accum = 0.0f;

void explode_scroll(f32 dy, i32 x, i32 y) {
    if ex_n == 0 { return; }
    explode_hover(x, y);
    ex_scroll_accum += dy;
    if ex_kind[ex_sel] == EX_TERM {
        i32 lines = cast(i32, ex_scroll_accum) / font_line_h;
        if lines == 0 { return; }
        ex_scroll_accum -= cast(f32, lines * font_line_h);
        i32 t = ex_id[ex_sel];
        term_view_set(t, term_view(t) - lines);
        ed_damage();
        return;
    }
    i32 step = cast(i32, ex_scroll_accum);
    if step == 0 { return; }
    ex_scroll_accum -= cast(f32, step);
    ed_buf_scroll(ex_id[ex_sel], step);
    ed_damage();
}

// a press on a tile opens its buffer or terminal; anywhere else returns
void explode_mouse(i32 x, i32 y) {
    for i32 i = 0; i < ex_n; i++ {
        if x >= ex_tx[i] && x < ex_tx[i] + ex_tw[i] && y >= ex_ty[i] && y < ex_ty[i] + ex_th[i] {
            ex_sel = i;
            ex_pick();
            return;
        }
    }
    explode_close();
}

// tests read these back
i32 explode_count() { return ex_n; }
// the selected tile's buffer, or -1 for a terminal (explode_selected_term)
i32 explode_selected() {
    if ex_sel < 0 || ex_sel >= ex_n || ex_kind[ex_sel] != EX_BUF { return -1; }
    return ex_id[ex_sel];
}
i32 explode_selected_term() {
    if ex_sel < 0 || ex_sel >= ex_n || ex_kind[ex_sel] != EX_TERM { return -1; }
    return ex_id[ex_sel];
}
bool explode_tile_rect(i32 i, i32* x, i32* y, i32* w, i32* h) {
    if i < 0 || i >= ex_n { return false; }
    *x = ex_tx[i];
    *y = ex_ty[i];
    *w = ex_tw[i];
    *h = ex_th[i];
    return true;
}

// --- the grid -----------------------------------------------------------------

// The tiles over the area x0, y0, w, h: the column count that gives the
// largest scale, each tile a vw by vh pane scaled under a header row hh
// tall, the block centered. Returns the scale; the tiles' rects are
// kept for the keys and the mouse.
f32 explode_layout(i32 x0, i32 y0, i32 w, i32 h, i32 vw, i32 vh, i32 hh, i32 gap) {
    f32 best = 0.0f;
    i32 bc = 1;
    for i32 c = 1; c <= ex_n; c++ {
        i32 r = (ex_n + c - 1) / c;
        f32 cw = cast(f32, w - (c + 1) * gap) / cast(f32, c);
        f32 ch = cast(f32, h - (r + 1) * gap) / cast(f32, r) - cast(f32, hh);
        if cw <= 0.0f || ch <= 0.0f { continue; }
        f32 s = cw / cast(f32, vw);
        if ch / cast(f32, vh) < s { s = ch / cast(f32, vh); }
        if s > best {
            best = s;
            bc = c;
        }
    }
    ex_cols = bc;
    // a window too small for any tile shows none
    if best <= 0.0f {
        for i32 i = 0; i < ex_n; i++ {
            ex_tw[i] = 0;
            ex_th[i] = 0;
        }
        return 0.0f;
    }
    i32 rows = (ex_n + bc - 1) / bc;
    i32 tw = cast(i32, cast(f32, vw) * best);
    i32 th = cast(i32, cast(f32, vh) * best) + hh;
    i32 gw = bc * tw + (bc - 1) * gap;
    i32 gh = rows * th + (rows - 1) * gap;
    i32 ox = x0 + (w - gw) / 2;
    i32 oy = y0 + (h - gh) / 2;
    if ox < x0 { ox = x0; }
    if oy < y0 { oy = y0; }
    for i32 i = 0; i < ex_n; i++ {
        ex_tx[i] = ox + (i % bc) * (tw + gap);
        ex_ty[i] = oy + (i / bc) * (th + gap);
        ex_tw[i] = tw;
        ex_th[i] = th;
    }
    return best;
}

// the i-th tile's buffer, or -1 for a terminal; its terminal, or -1
i32 explode_buf(i32 i) {
    if i < 0 || i >= ex_n || ex_kind[i] != EX_BUF { return -1; }
    return ex_id[i];
}
i32 explode_term(i32 i) {
    if i < 0 || i >= ex_n || ex_kind[i] != EX_TERM { return -1; }
    return ex_id[i];
}
bool explode_is_sel(i32 i) { return i == ex_sel; }
